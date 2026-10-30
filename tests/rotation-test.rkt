#lang racket/base

;; Rotation runbook tests — stage (generate-next), verify, promote, cancel.
;; Pairs are generated in-process; the vault is a scratch fixture.

(require net/base64
         rackunit
         racket/file
         racket/list
         racket/string
         "../app/backend.rkt"
         "../app/core/keymeta.rkt"
         "../app/core/store.rkt")

(define (b64 btes) (bytes->string/utf-8 (base64-encode btes "")))

;; A fresh vault with one product holding a real active Ed25519 pair in the
;; family names, plus its key id.
(define (make-vault!)
  (define path (make-temporary-file "keyward-rotation~a.ini"))
  (define-values (priv-der spki) (generate-keypair!))
  (define raw32 (subbytes spki 12))
  (store-set-entry! path "alpha" "UPDATE_ED25519_PRIVATE_KEY_B64" (b64 priv-der) "fixture")
  (store-set-entry! path "alpha" "UPDATE_ED25519_PUBLIC_KEY_SPKI_B64" (b64 spki) "fixture")
  (store-set-entry! path "alpha" "UPDATE_ED25519_PUBLIC_KEY_RAW_TAIL32_B64" (b64 raw32) "fixture")
  (store-set-entry! path "alpha" "RIVET_UPDATE_KEY_ID" "alpha-2026-10" "fixture")
  path)

;; ---- status before staging ------------------------------------------------------
;; status row = (next-present next-paired next-fingerprint next-key-id
;;                active-fingerprint active-key-id)

(define p (make-vault!))
(select-store! (path->string p))

(define s0 (rotation-status "alpha"))
(check-equal? (list-ref s0 0) "no")     ; next-present
(check-equal? (list-ref s0 1) "-")      ; next-paired
(check-equal? (list-ref s0 3) "-")      ; next-key-id absent
(check-equal? (list-ref s0 5) "alpha-2026-10") ; active key id survives

;; the active fingerprint is a 16-hex fingerprint
(check-equal? (string-length (list-ref s0 4)) 16)

;; status rows never carry values: every field is short and safe
(for ([field (in-list s0)])
  (check-true (< (string-length field) 200) "status fields must stay small"))

;; ---- guard: promote/cancel with nothing staged -----------------------------------

(check-exn exn:fail? (lambda () (rotation-promote "alpha")))
(check-exn exn:fail? (lambda () (rotation-cancel "alpha")))

;; ---- stage (phase 1 of the runbook) ----------------------------------------------

(define staged (rotation-start "alpha"))
;; (key-id fingerprint spki-b64 raw32-b64)
(check-equal? (string-length (list-ref staged 0)) (string-length "alpha-2026-10"))
(check-equal? (string-length (list-ref staged 1)) 16)
(check-equal? (bytes-length (base64-decode (string->bytes/utf-8 (list-ref staged 2)))) 44)
(check-equal? (bytes-length (base64-decode (string->bytes/utf-8 (list-ref staged 3)))) 32)

;; active entries untouched by staging — CI keeps signing with the old key
(check-equal? (store-entry-ref p "alpha" "RIVET_UPDATE_KEY_ID") "alpha-2026-10")

;; the staged pair is present and paired under the NEXT names
(define s1 (rotation-status "alpha"))
(check-equal? (list-ref s1 0) "yes")
(check-equal? (list-ref s1 1) "ok")
(check-equal? (list-ref s1 2) (list-ref staged 1)) ; next fingerprint matches
(check-equal? (list-ref s1 5) "alpha-2026-10")     ; active key id untouched

;; Deep Check sees the staged pair too: the section must stay green only when
;; BOTH the active and the next key pair (purpose-anchored publics)
(define summary (key-summary (store-section-entries p "alpha")))
(check-equal? (cdr (assq 'status summary)) "ok")

;; ---- corrupted staging refuses to promote ----------------------------------------

(store-set-entry! p "alpha" "UPDATE_ED25519_NEXT_PUBLIC_KEY_SPKI_B64"
                  (b64 (subbytes (base64-decode
                                  (string->bytes/utf-8 (list-ref staged 2))) 1))
                  "corrupt the staged spki on purpose")
(check-equal? (list-ref (rotation-status "alpha") 1) "pair-mismatch")
(check-exn exn:fail? (lambda () (rotation-promote "alpha")))

;; discard the corrupt staging and confirm a clean slate
(check-true (rotation-cancel "alpha"))
(check-false (store-entry-ref p "alpha" "UPDATE_ED25519_NEXT_PRIVATE_KEY_B64"))
(check-equal? (list-ref (rotation-status "alpha") 0) "no")

;; ---- promote (phase 2 of the runbook) --------------------------------------------

(define staged2 (rotation-start "alpha"))
(define promoted (rotation-promote "alpha"))
;; the staged key is now the active key: same key id and fingerprint
(check-equal? (car promoted) (list-ref staged2 0))
(check-equal? (cadr promoted) (list-ref staged2 1))
;; and the NEXT entries are gone
(check-false (store-entry-ref p "alpha" "UPDATE_ED25519_NEXT_PRIVATE_KEY_B64"))
(check-false (store-entry-ref p "alpha" "UPDATE_ED25519_NEXT_KEY_ID"))
(check-equal? (list-ref (rotation-status "alpha") 0) "no")
(check-equal? (store-entry-ref p "alpha" "RIVET_UPDATE_KEY_ID") (list-ref staged2 0))
(check-equal? (store-entry-ref p "alpha" "UPDATE_ED25519_PUBLIC_KEY_SPKI_B64")
              (list-ref staged2 2))

;; the promoted section still deep-checks green
(define summary2 (key-summary (store-section-entries p "alpha")))
(check-equal? (cdr (assq 'status summary2)) "ok")

;; the pre-promote snapshot holds the old active key (rollback path)
(check-true (>= (length (store-snapshots p)) 10))
