#lang racket/base

;; Store engine tests — fixture-driven, no real store ever touched.

(require rackunit
         racket/file
         racket/list
         racket/path
         racket/string
         "../app/core/store.rkt")

(define (make-fixture! text)
  (define path (make-temporary-file "keyward-test~a.ini"))
  (with-output-to-file path
    (lambda () (display text))
    #:mode 'text
    #:exists 'replace)
  path)

(define FIXTURE
  #<<EOF
# ============ keys 秘密库 ============
[alpha]
# update signing, rotated 2026-10
UPDATE_ED25519_PRIVATE_KEY_B64 = AAAA
UPDATE_ED25519_PUBLIC_KEY_SPKI_B64 = BBBB
RIVET_UPDATE_KEY_ID = alpha-2026-10

[beta]
EMPTY_ENTRY =
NOTE = hello
EOF
  )

(define p (make-fixture! FIXTURE))

;; ---- structure ----------------------------------------------------------------

(check-equal? (store-sections p) '("alpha" "beta"))

(check-equal? (store-entry-names p "alpha")
              '("UPDATE_ED25519_PRIVATE_KEY_B64"
                "UPDATE_ED25519_PUBLIC_KEY_SPKI_B64"
                "RIVET_UPDATE_KEY_ID"))

(check-equal? (store-entry-ref p "alpha" "RIVET_UPDATE_KEY_ID") "alpha-2026-10")
(check-equal? (store-entry-ref p "beta" "EMPTY_ENTRY") "")
(check-equal? (store-entry-ref p "beta" "NOTE") "hello")
(check-false (store-entry-ref p "nope" "NOPE"))

;; values are trimmed
(check-equal? (store-entry-ref p "alpha" "UPDATE_ED25519_PRIVATE_KEY_B64") "AAAA")

;; clean fixture has no orphans
(check-equal? (store-orphan-lines p) '())

;; ---- guards ---------------------------------------------------------------------

(check-exn exn:fail? (lambda () (store-set-entry! p "Bad_Section" "NAME" "v")))
(check-exn exn:fail? (lambda () (store-set-entry! p "alpha" "bad-name" "v")))
(check-exn exn:fail? (lambda () (store-set-entry! p "alpha" "NAME" "")))
(check-exn exn:fail? (lambda () (store-set-entry! p "alpha" "NAME" "two\nlines")))

;; ---- set: replace in place, keep comments ----------------------------------------

(store-set-entry! p "alpha" "UPDATE_ED25519_PRIVATE_KEY_B64" "CCCC" "rotate test")
(check-equal? (store-entry-ref p "alpha" "UPDATE_ED25519_PRIVATE_KEY_B64") "CCCC")
(define after-replace (string-join (file->lines p) "\n"))
;; the comment above the entry survived
(check-true (string-contains? after-replace "# update signing, rotated 2026-10"))
;; and so did the section comment header
(check-true (string-contains? after-replace "# ============ keys"))

;; ---- set: new entry into existing section lands inside it -------------------------

(store-set-entry! p "alpha" "NEW_ENTRY" "new-value")
(check-equal? (store-entry-ref p "alpha" "NEW_ENTRY") "new-value")
(define names (store-entry-names p "alpha"))
;; appended after the existing entries, not into beta
(check-true (> (index-of names "NEW_ENTRY") (index-of names "RIVET_UPDATE_KEY_ID")))

;; ---- set: brand-new section -------------------------------------------------------

(store-set-entry! p "gamma" "SOME_KEY" "some-value" "new section test")
(check-equal? (store-entry-ref p "gamma" "SOME_KEY") "some-value")
(check-equal? (store-sections p) '("alpha" "beta" "gamma"))

;; ---- delete -----------------------------------------------------------------------

(store-delete-entry! p "alpha" "NEW_ENTRY" "delete test")
(check-false (store-entry-ref p "alpha" "NEW_ENTRY"))
(check-exn exn:fail? (lambda () (store-delete-entry! p "alpha" "NEW_ENTRY")))

;; ---- orphan detection (the multi-line PEM incident class) --------------------------

(define messy
  #<<EOF
[alpha]
PRIVATE_KEY = -----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEIHohfxFKqay8sLtRBVAFFZLXXOq
-----END PRIVATE KEY-----
PUBLIC_KEY = ok
EOF
  )
(define m (make-fixture! messy))
;; the PEM body and footer lines are orphans; line numbers only
(check-equal? (store-orphan-lines m) (list 3 4))
;; and they are NOT visible as entries
(check-equal? (store-entry-ref m "alpha" "PRIVATE_KEY") "-----BEGIN PRIVATE KEY-----")

;; ---- snapshots ----------------------------------------------------------------------

(define snap-dir (snapshots-dir p))
(check-true (directory-exists? snap-dir))
;; four mutations happened above (CCCC, NEW_ENTRY, gamma, delete) — one
;; snapshot each; the failed guard calls never reach the snapshot
(define snaps-before (length (store-snapshots p)))
(check-true (>= snaps-before 4))
(store-set-entry! p "beta" "NOTE" "changed")
(check-true (= (length (store-snapshots p)) (add1 snaps-before)))

;; restore rolls the whole file back
(define before-restore (file->string p))
(define oldest (car (last (store-snapshots p))))
(store-restore-snapshot! p oldest)
(check-false (string=? before-restore (file->string p)))
;; restore snapshotted the current state first, so nothing is lost
(check-true (= (length (store-snapshots p)) (+ 2 snaps-before)))
