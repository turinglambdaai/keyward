#lang racket/base

;; Ed25519/PKCS8 key handling for the keyward engine, on the same audited
;; libcrypto provider rivet/distribution pins (the gmp/openssl factories
;; drag FFI loads at import time and kill embedded hosts without libgmp —
;; see rivet/distribution/crypto.rkt for that war story).
;;
;; Values never survive into the summaries this module returns: names,
;; algorithm kinds, fingerprints and match booleans only.

(require crypto
         (only-in crypto/libcrypto libcrypto-factory)
         net/base64
         racket/format
         racket/list
         racket/match
         racket/string)

(crypto-factories (list libcrypto-factory))

(provide key-summaries
         key-summary
         value->der
         private-key-from-der
         public-key-of
         spki-der
         fingerprint-of-der
         bytes->hex-string
         generate-keypair!)

;; ---- decoding ----------------------------------------------------------------

(define (b64-decode* s)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (base64-decode (string->bytes/utf-8 (string-replace (string-replace s "\n" "") "\r" "")))))

(define (pem-body->der text)
  (define m (regexp-match #px"-----BEGIN [^-]+-----([^-]*)-----END" text))
  (and m (b64-decode* (list-ref m 1))))

;; entry value -> DER bytes. Accepts the family's three storage forms:
;; base64(PKCS#8 DER), base64(PEM), and bare PEM text.
;; entry value -> bytes in any stored form (base64(DER), base64(PEM), PEM)
(define (value->bytes v)
  (and (string? v)
       (not (string=? v ""))
       (let ([trimmed (string-trim v)])
         (cond
           [(string-prefix? trimmed "-----BEGIN") (pem-body->der trimmed)]
           [else
            (define decoded (b64-decode* v))
            (and decoded
                 (let ([text (bytes->string/latin-1 decoded)])
                   (if (string-prefix? text "-----BEGIN")
                       (pem-body->der text)
                       decoded)))]))))

;; like value->bytes, but additionally requires a plausible DER SEQUENCE —
;; private keys are DER; raw 32-byte public anchors are not and would fail
(define (value->der v)
  (define raw (value->bytes v))
  (and raw (>= (bytes-length raw) 2) (= (bytes-ref raw 0) 48) raw))

(define (private-key-from-der der)
  (for/or ([format (in-list '(PrivateKeyInfo OneAsymmetricKey rkt-private))])
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (datum->pk-key der format (list libcrypto-factory)))))

(define (public-key-of priv)
  (pk-key->public-only-key priv))

(define (spki-der pub)
  (pk-key->datum pub 'SubjectPublicKeyInfo))

(define (bytes->hex-string btes)
  (apply string-append
         (for/list ([b (in-bytes btes)])
           (~r b #:base 16 #:min-width 2 #:pad-string "0"))))

(define (fingerprint-of-der der)
  (substring (bytes->hex-string (digest 'sha256 der)) 0 16))

(define (kind-of key)
  (define datum (pk-key->datum key 'rkt-public))
  (and (pair? datum)
       (match (car datum)
         ['eddsa (if (member 'ed25519 datum) "ed25519" "eddsa")]
         [(or 'rsa 'rsassa-pss) "rsa"]
         ['ecdsa "ecdsa"]
         [other (format "~a" other)])))

(define (generate-keypair!)
  (define priv (generate-private-key 'eddsa '((curve ed25519))))
  (values (pk-key->datum priv 'PrivateKeyInfo)
          (spki-der (public-key-of priv))))

;; ---- summaries ----------------------------------------------------------------

;; Analyze every private entry, including empty/malformed values. Public anchors
;; are selected by the same purpose prefix (UPDATE_ED25519_, LICENSE_, ...).
;; A valid key from another trust domain must never make a section look paired.
(define private-name-rx #px"PRIVATE")

(define (summary kind fingerprint paired status)
  (list (cons 'kind kind) (cons 'fingerprint fingerprint)
        (cons 'paired paired) (cons 'status status)))

(define (summary-ref value key)
  (cdr (assq key value)))

(define (private-entry-summary priv-entry entries)
  (define der (value->der (cdr priv-entry)))
  (define key (and der (private-key-from-der der)))
  (cond
    [(not key) (summary "?" "-" "-" "key-unreadable")]
    [else
     (define kind (or (kind-of key) "unknown"))
     (define spki (spki-der (public-key-of key)))
     (define fp (fingerprint-of-der spki))
     (define raw32 (and (string=? kind "ed25519") (= (bytes-length spki) 44)
                       (subbytes spki 12)))
     (define purpose (cadr (regexp-match #px"^(.*?)PRIVATE" (car priv-entry))))
     (define pub-entries
       (for/list ([e (in-list entries)]
                  #:when (and (string-prefix? (car e) purpose)
                              (string-prefix? (substring (car e) (string-length purpose))
                                              "PUBLIC")
                              (not (string=? (cdr e) ""))))
         e))
     (define (matches? entry)
       (define name (car entry))
       (define value (cdr entry))
       (cond
         [(regexp-match? #px"_FPR$" name)
          (string=? (string-downcase (string-trim value)) fp)]
         [else
          (define stored (value->bytes value))
          (and stored
               (or (equal? stored spki)
                   (and raw32 (= (bytes-length stored) 32)
                        (equal? stored raw32))))]))
     ;; Every declared anchor must agree, not merely one of several forms.
     (define paired (cond [(null? pub-entries) "missing-public"]
                          [(andmap matches? pub-entries) "yes"]
                          [else "no"]))
     (summary kind fp paired
              (cond [(string=? paired "yes") "ok"]
                    [(string=? paired "missing-public") "missing-public"]
                    [else "pair-mismatch"]))]))

;; Safe per-entry results for diagnostics; values never leave this module.
(define (key-summaries entries)
  (for/list ([e (in-list entries)]
             #:when (regexp-match? private-name-rx (car e)))
    (cons (car e) (private-entry-summary e entries))))

;; Preserve the product's existing row layout and status vocabulary. A section
;; is green only if every private key and each of its public anchors is green.
;; Multiple fingerprints are labelled by entry name instead of showing only the
;; first one; native hosts can display the result without an RPC/schema change.
(define (key-summary entries)
  (define per-key (key-summaries entries))
  (cond
    [(null? per-key) (summary "-" "-" "-" "no-key")]
    [(null? (cdr per-key)) (cdar per-key)]
    [else
     (define states (map (lambda (entry) (summary-ref (cdr entry) 'status)) per-key))
     (define status
       (or (for/first ([failure (in-list '("key-unreadable" "pair-mismatch" "missing-public"))]
                       #:when (member failure states))
             failure)
           "ok"))
     (summary
      (string-join (remove-duplicates
                    (map (lambda (entry) (summary-ref (cdr entry) 'kind)) per-key)) ", ")
      (string-join
       (map (lambda (entry)
              (format "~a=~a" (car entry) (summary-ref (cdr entry) 'fingerprint))) per-key)
       "; ")
      (cond [(string=? status "ok") "yes"]
            [(string=? status "missing-public") "missing-public"]
            [else "no"])
      status)]))
