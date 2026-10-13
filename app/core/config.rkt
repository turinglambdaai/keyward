#lang racket/base

;; Keyward's own tiny config (~/.keyward/config.json) — currently one
;; setting: which vault the user chose. No secrets live here, ever; the
;; config records a path, nothing else. Writes are atomic.

(require json
         racket/file
         racket/path)

(provide config-dir
         config-path
         config-load
         config-get
         config-set!)

;; the config directory: ~/.keyward, or the KEYWARD_CONFIG_DIR override
;; (tests point it at a scratch directory)
(define (config-dir)
  (define env (getenv "KEYWARD_CONFIG_DIR"))
  (if (and env (not (string=? env "")))
      (expand-user-path env)
      (build-path (find-system-path 'home-dir) ".keyward")))

(define (config-path)
  (build-path (config-dir) "config.json"))

;; the stored JSON object as a hash, or an empty hash when absent/broken
(define (config-load)
  (define p (config-path))
  (if (file-exists? p)
      (with-handlers ([exn:fail? (lambda (_) (hasheq))])
        (define v (with-input-from-file p read-json))
        (if (hash? v) v (hasheq)))
      (hasheq)))

;; string values only; #f when unset
(define (config-get key)
  (define v (hash-ref (config-load) key #f))
  (and (string? v) (not (string=? v "")) v))

(define (config-set! key value)
  (make-directory* (config-dir))
  (define h (hash-set (config-load) key value))
  (define tmp (make-temporary-file "keyward-cfg~a.json" #f (config-dir)))
  (with-output-to-file tmp
    (lambda () (write-json h) (newline))
    #:exists 'replace)
  (rename-file-or-directory tmp (config-path) #t)
  #t)
