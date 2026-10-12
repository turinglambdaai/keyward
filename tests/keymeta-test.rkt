#lang racket/base

;; Key metadata tests — generate, parse, pair, fingerprint, summarize.
;; No real key material involved: pairs are generated in-process.

(require net/base64
         rackunit
         racket/format
         racket/list
         "../app/core/keymeta.rkt")

(define (b64 btes) (bytes->string/utf-8 (base64-encode btes "")))

(define (hex s)
  (list->bytes
   (for/list ([i (in-range 0 (string-length s) 2)])
     (string->number (substring s i (+ i 2)) 16))))

;; ---- generate + parse round trip -----------------------------------------------

(define-values (priv-der spki) (generate-keypair!))
;; libcrypto emits the v2 OneAsymmetricKey form (public embedded); the
;; family's older keys are v1 (48 B) — both are valid PKCS#8
(check-not-false (memq (bytes-length priv-der) '(48 83)))
(check-equal? (bytes-length spki) 44)              ; Ed25519 SPKI
(check-equal? (subbytes spki 0 12) (hex "302a300506032b6570032100"))

(check-not-false (private-key-from-der priv-der))
(check-equal? (spki-der (public-key-of (private-key-from-der priv-der))) spki)

;; fingerprints are 16 hex chars and stable
(define fp (fingerprint-of-der spki))
(check-equal? (string-length fp) 16)
(check-equal? fp (fingerprint-of-der spki))

;; ---- value->der forms ------------------------------------------------------------

;; form 1: base64(DER)
(check-equal? (value->der (b64 priv-der)) priv-der)
;; form 2: bare PEM text
(define pem
  (string-append "-----BEGIN PRIVATE KEY-----\n"
                 (b64 priv-der) "\n"
                 "-----END PRIVATE KEY-----\n"))
(check-equal? (value->der pem) priv-der)
;; form 3: base64(PEM)
(check-equal? (value->der (b64 (string->bytes/utf-8 pem))) priv-der)
;; junk -> #f
(check-false (value->der "not a key"))
(check-false (value->der ""))

;; ---- key-summary: pairing -------------------------------------------------------

;; paired via SPKI form
(check-equal?
 (key-summary (list (cons "UPDATE_ED25519_PRIVATE_KEY_B64" (b64 priv-der))
                    (cons "UPDATE_ED25519_PUBLIC_KEY_SPKI_B64" (b64 spki))))
 (list (cons 'kind "ed25519") (cons 'fingerprint fp)
       (cons 'paired "yes") (cons 'status "ok")))

;; paired via raw tail32 form (podlens anchor style)
(check-equal?
 (cdr (assoc 'paired
             (key-summary (list (cons "UPDATE_ED25519_PRIVATE_KEY_B64" (b64 priv-der))
                                (cons "UPDATE_ED25519_PUBLIC_KEY_B64" (b64 (subbytes spki 12)))))))
 "yes")

;; mismatched public key
(define-values (other-priv other-spki) (generate-keypair!))
(check-equal?
 (cdr (assoc 'status
             (key-summary (list (cons "UPDATE_ED25519_PRIVATE_KEY_B64" (b64 priv-der))
                                (cons "UPDATE_ED25519_PUBLIC_KEY_SPKI_B64" (b64 other-spki))))))
 "pair-mismatch")

;; no public stored at all
(check-equal?
 (cdr (assoc 'status
             (key-summary (list (cons "UPDATE_ED25519_PRIVATE_KEY_B64" (b64 priv-der))))))
 "missing-public")

;; no private at all
(check-equal?
 (cdr (assoc 'status (key-summary (list (cons "NOTE" "hello")))))
 "no-key")

;; unreadable private value
(check-equal?
 (cdr (assoc 'status
             (key-summary (list (cons "UPDATE_ED25519_PRIVATE_KEY_B64" "!!!garbage!!!")))))
 "key-unreadable")

;; summaries never leak values: every field is a short safe string
(for ([e (in-list (key-summary (list (cons "UPDATE_ED25519_PRIVATE_KEY_B64" (b64 priv-der))
                                     (cons "UPDATE_ED25519_PUBLIC_KEY_SPKI_B64" (b64 spki)))))])
  (check-true (<= (string-length (cdr e)) 64)))
