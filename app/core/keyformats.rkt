#lang racket/base

;; Updater-native key format conversions for the family vault.
;;
;; Keyward stores Ed25519 material in the family forms — base64(PKCS#8 DER)
;; for private keys, base64(SPKI DER) / base64(raw 32B) for public anchors.
;; Two update ecosystems natively speak different shapes:
;;
;;   Sparkle (macOS):  private file = base64(seed || pubkey)  [64 raw bytes]
;;                     public  file = base64(pubkey)          [32 raw bytes]
;;   Tauri/minisign:   .pub   = comment line + base64("Ed" || keynum || pubkey)
;;                     .key   = comment line + base64(blob), encrypted with
;;                              scrypt when a password is set; the unencrypted
;;                              (empty-password / minisign -W) blob is
;;                              "Ed" 00 00 "B2" salt(32) ops(8) mem(8)
;;                              keynum(8) sk(64=seed||pub) chk(32) with
;;                              chk = BLAKE2b-256("Ed" || keynum || sk)
;;
;; Import normalizes native files into the family forms; export renders
;; vault entries back into native shapes. The minisign keynum is derived
;; deterministically from the public key (first 8 bytes of
;; SHA-256("keyward-minisign-keynum" || pubkey)), so exported .pub and .key
;; always agree — minisign refuses signatures whose keynum mismatches the
;; verifying public key. Password-protected minisign secret keys are
;; rejected with a clear error: the SENSITIVE scrypt parameters (1 GiB)
;; are not tractable in-process, and no target platform ships libsodium.
;;
;; Values are only ever converted, never logged: nothing here returns raw
;; key material except the conversion results themselves.

(require crypto
         (only-in crypto/libcrypto libcrypto-factory)
         net/base64
         racket/format
         racket/list
         racket/match
         racket/string
         "blake2b.rkt"
         (only-in "keymeta.rkt"
                  value->der private-key-from-der))

(crypto-factories (list libcrypto-factory))

(provide sniff-import
         export-conversion
         export-formats
         minisign-keynum
         ed25519-spki-prefix
         ed25519-from-seed-pub)

;; ---- byte helpers ---------------------------------------------------------------

(define (hex->bytes s)
  (list->bytes
   (for/list ([i (in-range 0 (string-length s) 2)])
     (string->number (substring s i (+ i 2)) 16))))

(define ed25519-spki-prefix (hex->bytes "302a300506032b6570032100"))

(define (b64-decode* s)
  (base64-decode (string->bytes/utf-8 (string-replace (string-replace s "\n" "") "\r" ""))))

(define (b64-encode* bs) (bytes->string/utf-8 (base64-encode bs "")))

(define (le64 n)
  (for/list ([i (in-range 8)]) (bitwise-and (arithmetic-shift n (- (* 8 i))) #xFF)))

;; ---- ed25519 seed <-> key objects ----------------------------------------------

;; racket crypto's rkt-private datum is (eddsa private ed25519 PUB SEED) —
;; the public half comes FIRST; keep that order straight here so native
;; files always carry seed||pub
(define (ed25519-from-seed-pub seed pub)
  (datum->pk-key (list 'eddsa 'private 'ed25519 pub seed)
                 'rkt-private (list libcrypto-factory)))

(define (key->seed-pub priv)
  (define d (pk-key->datum priv 'rkt-private))
  (values (list-ref d 4) (list-ref d 3)))

(define (raw32->spki raw32) (bytes-append ed25519-spki-prefix raw32))
(define (spki->raw32 spki) (subbytes spki 12))

;; ---- minisign -------------------------------------------------------------------

;; deterministic keynum so exported .pub and .key always agree; minisign
;; refuses signatures whose keynum differs from the verifying public key
(define (minisign-keynum pub32)
  (subbytes (digest 'sha256 (bytes-append #"keyward-minisign-keynum" pub32)) 0 8))

(define (minisign-chk keynum sk64)
  (blake2b-256 (bytes-append #"Ed" keynum sk64)))

(define (minisign-public-text pub32)
  (string-append "untrusted comment: keyward minisign public key\n"
                 (b64-encode* (bytes-append #"Ed" (minisign-keynum pub32) pub32))
                 "\n"))

(define (minisign-secret-text priv)
  (define-values (seed pub) (key->seed-pub priv))
  (define keynum (minisign-keynum pub))
  (define sk64 (bytes-append seed pub))
  (define blob
    (bytes-append #"Ed" #"\0\0" #"B2"
                  (make-bytes 32 0)        ; kdf salt (unused unencrypted)
                  (make-bytes 8 0)         ; opslimit (unused unencrypted)
                  (make-bytes 8 0)         ; memlimit (unused unencrypted)
                  keynum sk64 (minisign-chk keynum sk64)))
  (string-append "untrusted comment: keyward minisign secret key (UNENCRYPTED)\n"
                 (b64-encode* blob)
                 "\n"))

;; parse a minisign public blob -> raw 32-byte public key
(define (minisign-public->raw32 blob)
  (unless (and (= (bytes-length blob) 42) (equal? (subbytes blob 0 2) #"Ed"))
    (error 'keyformats "not a minisign public key blob"))
  (subbytes blob 10))

;; parse an unencrypted minisign secret blob -> private key object
(define (minisign-secret->key blob)
  (unless (and (= (bytes-length blob) 158) (equal? (subbytes blob 0 2) #"Ed"))
    (error 'keyformats "not a minisign secret key blob"))
  (define kdf (subbytes blob 2 4))
  (cond [(equal? kdf #"Sc")
         (error 'keyformats
                "password-protected minisign key — regenerate it with an empty password (tauri signer / minisign -W) before importing")]
        [(not (equal? kdf #"\0\0"))
         (error 'keyformats "unsupported minisign kdf algorithm")]
        [else
         (define keynum (subbytes blob 54 62))
         (define sk64 (subbytes blob 62 126))
         (define chk (subbytes blob 126 158))
         (unless (equal? (minisign-chk keynum sk64) chk)
           (error 'keyformats "minisign secret key checksum mismatch — file corrupted"))
         (ed25519-from-seed-pub (subbytes sk64 0 32) (subbytes sk64 32 64))]))

;; ---- PEM rendering ---------------------------------------------------------------

(define (der->pem label der)
  (define b64 (b64-encode* der))
  (string-append "-----BEGIN " label "-----\n"
                 (let loop ([s b64] [acc '()])
                   (if (<= (string-length s) 64)
                       (string-join (reverse (cons s acc)) "\n")
                       (loop (substring s 64) (cons (substring s 0 64) acc))))
                 "\n-----END " label "-----\n"))

;; ---- import sniffing --------------------------------------------------------------
;; text -> (cons kind normalized-family-value); raises on unsupported input.
;; target-name steers public-anchor normalization: a *_RAW_TAIL32_* entry
;; stores base64(raw 32B), anything else stores base64(SPKI DER).

(define (sniff-import text [target-name ""])
  (define trimmed (string-trim text))
  (cond
    [(string-prefix? trimmed "-----BEGIN")
     (define der (value->der trimmed))
     (unless der (error 'keyformats "unreadable PEM"))
     (cons "pem" (b64-encode* der))]
    [(string-prefix? trimmed "untrusted comment:")
     (define blob (b64-decode* (car (reverse (string-split trimmed "\n")))))
     (cond
       [(and (= (bytes-length blob) 42) (equal? (subbytes blob 0 2) #"Ed"))
        (cons "minisign-public" (public-value-for (minisign-public->raw32 blob) target-name))]
       [(= (bytes-length blob) 158)
        (cons "minisign-secret" (b64-encode* (pk-key->datum (minisign-secret->key blob) 'PrivateKeyInfo)))]
       [else (error 'keyformats "unrecognized minisign key blob")])]
    [else
     (define raw
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (and (not (string=? trimmed "")) (b64-decode* trimmed))))
     (or (and raw (= (bytes-length raw) 64)
              ;; 64 bytes only mean "Sparkle private" when seed||pub
              ;; actually validates as an Ed25519 pair
              (let ([key (sparkle-private->key raw)])
                (and key
                     (cons "sparkle-private"
                           (b64-encode* (pk-key->datum key 'PrivateKeyInfo))))))
         (and raw (= (bytes-length raw) 32)
              (cons "sparkle-public" (public-value-for raw target-name)))
         (and raw (>= (bytes-length raw) 2) (= (bytes-ref raw 0) 48)
              (cons "der" (b64-encode* raw)))
         (error 'keyformats
                "unrecognized key file — expected PEM, base64(DER), Sparkle or minisign key"))]))

(define (sparkle-private->key raw)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (ed25519-from-seed-pub (subbytes raw 0 32) (subbytes raw 32 64))))

(define (public-value-for raw32 target-name)
  (if (string-contains? (string-upcase target-name) "RAW_TAIL32")
      (b64-encode* raw32)
      (b64-encode* (raw32->spki raw32))))

;; ---- export -----------------------------------------------------------------------
;; (source-entry-name value format) -> string; the value crosses to the
;; clipboard at the host, never to a file, matching entry-get's discipline.

(define (export-formats)
  '(("sparkle-private" "Sparkle private key file (base64 seed+pub)")
    ("sparkle-public" "Sparkle SUPublicEDKey (base64 raw 32B)")
    ("pem-private" "PKCS#8 PEM (BEGIN PRIVATE KEY)")
    ("pem-public" "SPKI PEM (BEGIN PUBLIC KEY)")
    ("tauri-pub" "minisign .pub file text")
    ("tauri-pub-b64" "base64 of the .pub text — tauri.conf.json pubkey value")
    ("tauri-key" "minisign secret key file text (unencrypted) — TAURI_SIGNING_PRIVATE_KEY")
    ("b64" "the stored single-line base64 value unchanged")))

(define (export-conversion source-name value format)
  (define trimmed (string-trim value))
  (cond
    [(string=? format "b64") trimmed]
    [(string=? format "pem-private")
     (define der (require-private-der source-name trimmed))
     (der->pem "PRIVATE KEY" der)]
    [(string=? format "sparkle-private")
     (define-values (seed pub) (key->seed-pub (require-private-key source-name trimmed)))
     (b64-encode* (bytes-append seed pub))]
    [(string=? format "tauri-key")
     (minisign-secret-text (require-private-key source-name trimmed))]
    [(member format '("sparkle-public" "tauri-pub" "tauri-pub-b64" "pem-public"))
     (define pub32 (source->raw32 source-name trimmed))
     (case format
       [("sparkle-public") (b64-encode* pub32)]
       [("tauri-pub") (minisign-public-text pub32)]
       [("tauri-pub-b64") (b64-encode* (string->bytes/utf-8 (minisign-public-text pub32)))]
       [("pem-public") (der->pem "PUBLIC KEY" (raw32->spki pub32))])]
    [else
     (error 'keyformats "unknown export format: ~a" format)]))

(define (require-private-der source-name v)
  (define der (value->der v))
  (unless der (error 'keyformats "~a does not hold a DER key" source-name))
  (unless (private-key-from-der der)
    (error 'keyformats "~a does not hold a private key" source-name))
  der)

(define (require-private-key source-name v)
  (define der (value->der v))
  (define key (and der (private-key-from-der der)))
  (unless key (error 'keyformats "~a does not hold a private key" source-name))
  key)

;; public anchors are stored either as base64(SPKI) or base64(raw 32B)
(define (source->raw32 source-name v)
  (define d (with-handlers ([exn:fail? (lambda (_) #f)]) (b64-decode* (string-trim v))))
  (cond
    [(and d (= (bytes-length d) 44) (equal? (subbytes d 0 12) ed25519-spki-prefix))
     (spki->raw32 d)]
    [(and d (= (bytes-length d) 32)) d]
    [else
     (error 'keyformats "~a does not hold a base64(SPKI) or base64(raw 32B) public anchor"
            source-name)]))
