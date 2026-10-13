#lang racket/base

;; Config tests — isolated from the real home via KEYWARD_CONFIG_DIR.

(require json
         rackunit
         racket/file
         racket/path
         "../app/core/config.rkt")

(define scratch (make-temporary-file "kw-cfg~a" 'directory))
(define old-env (getenv "KEYWARD_CONFIG_DIR"))
(putenv "KEYWARD_CONFIG_DIR" (path->string scratch))

;; nothing saved yet
(check-false (config-get "store"))
(check-equal? (config-load) (hasheq))

;; save → read back → overwrite
(config-set! "store" "/tmp/vault.ini")
(check-equal? (config-get "store") "/tmp/vault.ini")
(config-set! "store" "/other/vault.ini")
(check-equal? (config-get "store") "/other/vault.ini")
(check-true (file-exists? (build-path scratch "config.json")))

;; the file is valid JSON with the expected single key
(define raw (with-input-from-file (build-path scratch "config.json") read-json))
(check-equal? (hash-ref raw 'store) "/other/vault.ini")

;; a corrupt file degrades to empty, never crashes
(call-with-output-file (build-path scratch "config.json")
  (lambda (out) (display "this is not json {" out))
  #:exists 'replace)
(check-equal? (config-load) (hasheq))
(check-false (config-get "store"))

(delete-directory/files scratch)
(if old-env
    (putenv "KEYWARD_CONFIG_DIR" old-env)
    (putenv "KEYWARD_CONFIG_DIR" ""))
