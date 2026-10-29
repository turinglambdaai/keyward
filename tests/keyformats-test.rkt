#lang racket/base

;; Updater-native format conversion tests — Sparkle/minisign round trips.
;; Pairs are generated in-process; no real key material involved.

(require net/base64
         rackunit
         racket/format
         racket/list
         racket/string
         (only-in crypto pk-key->datum)
         "../app/core/blake2b.rkt"
         "../app/core/keyformats.rkt"
         "../app/core/keymeta.rkt")

(define (b64 btes) (bytes->string/utf-8 (base64-encode btes "")))
(define (unb64 s) (base64-decode (string->bytes/utf-8 s)))

(define-values (priv-der spki) (generate-keypair!))
(define raw32 (subbytes spki 12))
(define raw32-b64 (b64 raw32))
(define priv (private-key-from-der priv-der))
(define priv-datum (pk-key->datum priv 'rkt-private))
;; rkt-private = (eddsa private ed25519 PUB SEED) — pub first
(define pub (list-ref priv-datum 3))
(define seed (list-ref priv-datum 4))
;; the public slot really is the SPKI tail
(check-equal? pub raw32)

;; ---- Sparkle -------------------------------------------------------------------

;; the Sparkle private file is base64(seed || pub) — seed FIRST, and the
;; public half must equal the SPKI tail
(define sparkle-private-text (b64 (bytes-append seed pub)))
(check-equal? (subbytes (unb64 sparkle-private-text) 32) raw32)
(define sniffed (sniff-import sparkle-private-text))
(check-equal? (car sniffed) "sparkle-private")
;; normalization lands as base64(PKCS#8 DER), byte-identical
(check-equal? (unb64 (cdr sniffed)) priv-der)

;; a corrupted pair (pub half flipped) is rejected, never stored
(define corrupted
  (bytes-append seed
                (list->bytes (for/list ([b (in-bytes pub)]) (bitwise-xor b #xFF)))))
(check-exn exn:fail? (lambda () (sniff-import (b64 corrupted))))

;; Sparkle public: base64(raw 32B); storage form follows the target name
(define sparkle-public-text (b64 raw32))
(check-equal? (cdr (sniff-import sparkle-public-text "UPDATE_ED25519_PUBLIC_KEY_RAW_TAIL32_B64"))
              sparkle-public-text)
(check-equal? (cdr (sniff-import sparkle-public-text "UPDATE_ED25519_PUBLIC_KEY_SPKI_B64"))
              (b64 spki))

;; export paths back out of the family forms
(check-equal? (export-conversion "UPDATE_ED25519_PRIVATE_KEY_B64" (b64 priv-der) "sparkle-private")
              sparkle-private-text)
(check-equal? (export-conversion "UPDATE_ED25519_PUBLIC_KEY_RAW_TAIL32_B64" raw32-b64 "sparkle-public")
              sparkle-public-text)
(check-equal? (export-conversion "UPDATE_ED25519_PUBLIC_KEY_SPKI_B64" (b64 spki) "sparkle-public")
              sparkle-public-text)

;; ---- PEM ------------------------------------------------------------------------

(define pem-private (export-conversion "UPDATE_ED25519_PRIVATE_KEY_B64" (b64 priv-der) "pem-private"))
(check-true (string-prefix? pem-private "-----BEGIN PRIVATE KEY-----"))
(check-equal? (unb64 (cdr (sniff-import pem-private))) priv-der)

(define pem-public (export-conversion "UPDATE_ED25519_PUBLIC_KEY_SPKI_B64" (b64 spki) "pem-public"))
(check-true (string-prefix? pem-public "-----BEGIN PUBLIC KEY-----"))
(check-equal? (unb64 (cdr (sniff-import pem-public "X_PUBLIC_KEY_SPKI_B64"))) spki)

;; ---- minisign / Tauri -----------------------------------------------------------

(define pub-text (export-conversion "UPDATE_ED25519_PUBLIC_KEY_RAW_TAIL32_B64" raw32-b64 "tauri-pub"))
(check-true (string-prefix? pub-text "untrusted comment:"))
(define pub-blob (unb64 (cadr (string-split pub-text "\n"))))
(check-equal? (bytes-length pub-blob) 42)
(check-equal? (subbytes pub-blob 0 2) #"Ed")
;; deterministic keynum: the same key yields the same blob from either form
(check-equal? (unb64 (cadr (string-split
                            (export-conversion "UPDATE_ED25519_PUBLIC_KEY_SPKI_B64" (b64 spki) "tauri-pub")
                            "\n")))
              pub-blob)

;; the conf form is base64 of the file text
(check-equal? (export-conversion "UPDATE_ED25519_PUBLIC_KEY_RAW_TAIL32_B64" raw32-b64 "tauri-pub-b64")
              (b64 (string->bytes/utf-8 pub-text)))

;; the .pub file imports back to the raw anchor
(check-equal? (cdr (sniff-import pub-text "UPDATE_ED25519_PUBLIC_KEY_RAW_TAIL32_B64")) raw32-b64)

;; secret key export: unencrypted minisign blob with a verifiable checksum
(define key-text (export-conversion "UPDATE_ED25519_PRIVATE_KEY_B64" (b64 priv-der) "tauri-key"))
(check-true (string-prefix? key-text "untrusted comment:"))
(define key-blob (unb64 (cadr (string-split key-text "\n"))))
(check-equal? (bytes-length key-blob) 158)
(check-equal? (subbytes key-blob 0 2) #"Ed")     ; sig alg
(check-equal? (subbytes key-blob 2 4) #"\0\0")   ; kdf = none (unencrypted)
(check-equal? (subbytes key-blob 4 6) #"B2")     ; checksum alg
;; sk64 = seed || pub — the pub half must equal the SPKI tail
(check-equal? (subbytes key-blob 62 94) seed)
(check-equal? (subbytes key-blob 94 126) raw32)
;; the checksum covers "Ed" || keynum || sk, and the keynum matches the .pub
(check-equal? (blake2b-256 (bytes-append #"Ed" (subbytes key-blob 54 62) (subbytes key-blob 62 126)))
              (subbytes key-blob 126 158))
(check-equal? (subbytes key-blob 54 62) (subbytes pub-blob 2 10))
;; and the key material round-trips into the family form
(define reimported (sniff-import key-text))
(check-equal? (car reimported) "minisign-secret")
(check-equal? (unb64 (cdr reimported)) priv-der)

;; password-protected minisign keys are refused with a clear reason
(define encrypted (bytes-append #"Ed" #"Sc" #"B2" (make-bytes 152 1)))
(check-exn exn:fail?
           (lambda ()
             (sniff-import (string-append "untrusted comment: minisign encrypted secret key\n"
                                          (b64 encrypted) "\n"))))

;; identity export and unknown-format guard
(check-equal? (export-conversion "ANY_ENTRY" raw32-b64 "b64") raw32-b64)
(check-exn exn:fail? (lambda () (export-conversion "ANY_ENTRY" raw32-b64 "nope")))
