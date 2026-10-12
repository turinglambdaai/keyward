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
         racket/match
         racket/string)

(crypto-factories (list libcrypto-factory))

(provide key-summary
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
;; entries: (listof (cons NAME value)) — analyze the first readable private
;; key and report whether any stored public entry matches it.

(define private-name-rx #px"PRIVATE")
(define known-private-names
  '("UPDATE_ED25519_PRIVATE_KEY_B64"
    "UPDATE_ED25519_PRIVATE_KEY"
    "UPDATER_PRIVATE_KEY"
    "LICENSE_PRIVATE_KEY"))

(define (key-summary entries)
  (define priv-entry
    (or (for/first ([e (in-list entries)]
                    #:when (and (member (car e) known-private-names)
                                (not (string=? (cdr e) ""))))
          e)
        (for/first ([e (in-list entries)]
                    #:when (and (regexp-match? private-name-rx (car e))
                                (not (string=? (cdr e) ""))))
          e)))
  (cond
    [(not priv-entry) (list (cons 'kind "-") (cons 'fingerprint "-")
                            (cons 'paired "-") (cons 'status "no-key"))]
    [else
     (define der (value->der (cdr priv-entry)))
     (define key (and der (private-key-from-der der)))
     (cond
       [(not key) (list (cons 'kind "?") (cons 'fingerprint "-")
                        (cons 'paired "-") (cons 'status "key-unreadable"))]
       [else
        (define kind (or (kind-of key) "unknown"))
        (define spki (spki-der (public-key-of key)))
        (define fp (fingerprint-of-der spki))
        (define raw32 (and (string=? kind "ed25519") (= (bytes-length spki) 44)
                           (subbytes spki 12)))
        ;; public material may be stored two ways: as decodable key bytes
        ;; (PUBLIC_KEY entries) or as a bare fingerprint (…_FPR entries)
        (define pub-entries
          (for/list ([e (in-list entries)]
                     #:when (and (regexp-match? #px"PUBLIC" (car e))
                                 (not (string=? (cdr e) ""))))
            e))
        (define (matches? name value)
          (cond [(regexp-match? #px"_FPR$" name)
                 (and (string? value)
                      (string=? (string-downcase (string-trim value)) fp))]
                [else
                 (define der* (value->bytes value))
                 (and der*
                      (or (equal? der* spki)
                          (and raw32 (= (bytes-length der*) 32) (equal? der* raw32))))]))
        (define paired (cond [(null? pub-entries) "missing-public"]
                             [(ormap (lambda (e) (matches? (car e) (cdr e))) pub-entries) "yes"]
                             [else "no"]))
        (define status
          (cond [(string=? paired "yes") "ok"]
                [(string=? paired "missing-public") "missing-public"]
                [else "pair-mismatch"]))
        (list (cons 'kind kind)
              (cons 'fingerprint fp)
              (cons 'paired paired)
              (cons 'status status))])]))
