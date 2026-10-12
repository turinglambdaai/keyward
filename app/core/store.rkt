#lang racket/base

;; The keyward store engine — a comment-preserving parser/writer for the
;; family secrets.ini format: `[product]` sections, `NAME = value` lines,
;; `#` comments. The synced folder (Resilio) stays the transport; keyward
;; adds discipline on top of the same single file:
;;
;;   - every mutation writes an append-only snapshot into
;;     `<folder>/.history/keyward/` BEFORE touching the store (loss
;;     protection: any bad write is one restore away)
;;   - writes are atomic (tmp + rename) and permissions are tightened to 600
;;   - values are hard-single-line: multi-line pastes are rejected at set
;;     time and multi-line residue shows up as orphan line numbers (the
;;     podlens incident class)
;;   - nothing here ever returns a raw value except an explicit ref; check
;;     output carries names, counts and fingerprints only

(require racket/date
         racket/file
         racket/format
         racket/list
         racket/match
         racket/path
         racket/string)

(provide store-path-default
         store-sections
         store-section-entries
         store-entry-names
         store-entry-ref
         store-orphan-lines
         store-set-entry!
         store-delete-entry!
         store-check
         snapshots-dir
         store-snapshots
         store-restore-snapshot!
         section-name?
         entry-name?
         make-key-id)

;; ---- naming guards (family conventions) ------------------------------------

(define (section-name? s)
  (regexp-match? #px"^[a-z0-9]+(-[a-z0-9]+)*$" s))

(define (entry-name? s)
  (regexp-match? #px"^[A-Z][A-Z0-9_]*$" s))

(define (make-key-id product)
  (define d (current-date))
  (format "~a-~a-~a" product (date-year d) (~r (date-month d) #:min-width 2 #:pad-string "0")))

(define (store-path-default)
  (define env (getenv "KEYWARD_STORE"))
  (if env
      (simple-form-path env)
      (expand-user-path "~/Sync/Keys/secrets.ini")))

;; ---- line classification ------------------------------------------------------
;;   'blank / 'comment / ('section title) / ('entry name value) / 'orphan

(define (classify line)
  (cond
    [(regexp-match? #px"^[ \t]*$" line) 'blank]
    [(regexp-match? #px"^[ \t]*#" line) 'comment]
    [(regexp-match #px"^[ \t]*\\[([^]]+)\\][ \t]*$" line)
     => (lambda (m) (list 'section (string-trim (list-ref m 1))))]
    [(string-index-of line #\=)
     => (lambda (i)
          (define name (string-trim (substring line 0 i)))
          (define value (string-trim (substring line (add1 i))))
          (if (string=? name "")
              'orphan
              (list 'entry name value)))]
    [else 'orphan]))

(define (string-index-of s ch)
  (for/first ([c (in-string s)] [i (in-naturals)] #:when (char=? c ch)) i))

(define (file-lines path)
  (if (file-exists? path) (file->lines path) '()))

;; section title governing each line index (latest header at or before it)
(define (index-sections lines)
  (for/fold ([acc '()] [cur #f] #:result (reverse acc))
            ([line (in-list lines)] [i (in-naturals)])
    (match (classify line)
      [(list 'section t) (values (cons (cons i t) acc) t)]
      [_ (values acc cur)])))

(define (index-section-of isecs i)
  ;; isecs is ascending by line number; walk it backwards so the latest
  ;; header at or before i wins
  (for/first ([p (in-list (reverse isecs))] #:when (<= (car p) i)) (cdr p)))

;; ---- structure queries ---------------------------------------------------------

;; ordered assoc: section title -> list of (name . value)
(define (store-structure path)
  (define lines (file-lines path))
  (define isecs (index-sections lines))
  (let loop ([xs lines] [is '()] [acc '()])
    (cond
      [(null? xs) (reverse acc)]
      [else
       (define i (- (length lines) (length xs)))
       (match (classify (car xs))
         [(list 'section t)
          (loop (cdr xs) (cons i is)
                (if (assoc t acc) acc (cons (cons t '()) acc)))]
         [(list 'entry name value)
          (define sec (index-section-of isecs i))
          (if (string? sec)
              (loop (cdr xs) is (add-entry acc sec name value))
              (loop (cdr xs) is acc))]
         [_ (loop (cdr xs) is acc)])])))

(define (add-entry acc section name value)
  (for/list ([p (in-list acc)])
    (if (string=? (car p) section)
        (cons section (append (cdr p) (list (cons name value))))
        p)))

(define (store-sections path)
  (map car (store-structure path)))

(define (store-section-entries path section)
  (cdr (or (assoc section (store-structure path)) (cons section '()))))

(define (store-entry-names path section)
  (map car (store-section-entries path section)))

(define (store-entry-ref path section name)
  (cond [(assoc name (store-section-entries path section)) => cdr] [else #f]))

;; line numbers (1-based) of stray content: true orphans and entries that sit
;; before any section header. Numbers only — the text is often key material.
(define (store-orphan-lines path)
  (define lines (file-lines path))
  (define isecs (index-sections lines))
  (for/list ([line (in-list lines)] [i (in-naturals)]
             #:when (let ([c (classify line)])
                      (or (eq? c 'orphan)
                          (match c
                            [(list 'entry _ _)
                             (not (string? (index-section-of isecs i)))]
                            [_ #f]))))
    (add1 i)))

;; ---- mutation --------------------------------------------------------------------

(define (store-snapshot! path reason)
  (unless (file-exists? path) (error 'store-snapshot! "store does not exist: ~a" path))
  (define dir (snapshots-dir path))
  (make-directory* dir)
  (define stamp (regexp-replace* #px"[^0-9]" (date->string (current-date) #t) ""))
  (define tag (if reason (sanitize-reason reason) "manual"))
  (define filename
    (format "~a-~a-~a.ini" stamp (~r (random 65536) #:min-width 4 #:pad-string "0") tag))
  (copy-file path (build-path dir filename) #t)
  filename)

(define (sanitize-reason reason)
  (define cleaned (regexp-replace* #px"[^A-Za-z0-9._-]" (string-trim reason) "-"))
  (substring cleaned 0 (min 40 (string-length cleaned))))

(define (snapshots-dir path)
  (define dir (path-only path))
  (build-path (or dir (current-directory)) ".history" "keyward"))

(define (store-write! path lines)
  (define tmp (make-temporary-file "keyward~a.ini" #f (or (path-only path) (current-directory))))
  (with-output-to-file tmp
    (lambda () (for ([l (in-list lines)]) (displayln l)))
    #:mode 'text
    #:exists 'replace)
  (file-or-directory-permissions tmp 384)
  (rename-file-or-directory tmp path #t))

(define (store-set-entry! path section name value [reason #f])
  (unless (section-name? section) (error 'store-set-entry! "bad section name: ~a" section))
  (unless (entry-name? name) (error 'store-set-entry! "bad entry name: ~a" name))
  (unless (and (string? value) (not (string=? value "")))
    (error 'store-set-entry! "value must be a non-empty string"))
  (when (string-contains? value "\n")
    (error 'store-set-entry! "value must be single-line; encode files as base64 first"))
  (store-snapshot! path (or reason (format "set ~a/~a" section name)))
  (define lines (file-lines path))
  (define isecs (index-sections lines))
  (define (entry-at? line i target)
    (match (classify line)
      [(list 'entry n _)
       (and (equal? (index-section-of isecs i) target) (string=? n name))]
      [_ #f]))
  (define hit-i
    (for/first ([line (in-list lines)] [i (in-naturals)] #:when (entry-at? line i section)) i))
  (define new-line (format "~a = ~a" name value))
  (define updated
    (cond
      [hit-i (list-set lines hit-i new-line)]
      [(member section (store-sections path))
       (define entry-is
         (for/list ([line (in-list lines)] [i (in-naturals)]
                    #:when (match (classify line)
                             [(list 'entry _ _)
                              (equal? (index-section-of isecs i) section)]
                             [_ #f]))
           i))
       (define header-i
         (for/first ([line (in-list lines)] [i (in-naturals)]
                     #:when (match (classify line)
                              [(list 'section t) (string=? t section)]
                              [_ #f]))
           i))
       (define at
         (if (null? entry-is)
             (add1 (or header-i 0))
             (add1 (last entry-is))))
       (list-insert lines at new-line)]
      [else (append lines (list "" (format "[~a]" section) new-line))]))
  (store-write! path updated))

(define (list-insert xs at v)
  (append (take xs at) (list v) (drop xs at)))

(define (store-delete-entry! path section name [reason #f])
  (unless (section-name? section) (error 'store-delete-entry! "bad section name: ~a" section))
  (unless (entry-name? name) (error 'store-delete-entry! "bad entry name: ~a" name))
  (define lines (file-lines path))
  (define isecs (index-sections lines))
  (define (hit? line i)
    (match (classify line)
      [(list 'entry n _)
       (and (equal? (index-section-of isecs i) section) (string=? n name))]
      [_ #f]))
  (unless (for/first ([line (in-list lines)] [i (in-naturals)] #:when (hit? line i)) i)
    (error 'store-delete-entry! "no such entry: ~a/~a" section name))
  (store-snapshot! path (or reason (format "delete ~a/~a" section name)))
  (store-write!
   path
   (for/list ([line (in-list lines)] [i (in-naturals)] #:unless (hit? line i)) line))
  #t)

;; ---- snapshots ------------------------------------------------------------------

(define (store-snapshots path)
  (define dir (snapshots-dir path))
  (if (directory-exists? dir)
      (sort
       (for/list ([f (in-list (directory-list dir))]
                  #:when (path-has-extension? f #".ini"))
         (define name (path->string f))
         (define size (file-size (build-path dir f)))
         (cons (substring name 0 (max 0 (- (string-length name) 4))) (~a size)))
       string>=?
       #:key car)
      '()))

(define (store-restore-snapshot! path filename)
  (define dir (snapshots-dir path))
  (define full (string-append filename ".ini"))
  (define src (build-path dir full))
  (unless (file-exists? src) (error 'store-restore-snapshot! "no such snapshot: ~a" full))
  (store-snapshot! path (format "pre-restore ~a" filename))
  (copy-file src path #t)
  (file-or-directory-permissions path 384)
  #t)

;; ---- deep check --------------------------------------------------------------
;; Per-section report; the key-analyze callback (provided by the backend, so
;; this module stays crypto-free) receives the section's (name . value) pairs
;; and must return an assoc of SAFE summary strings only.

(define (store-check path key-analyze)
  (for/list ([section (in-list (store-sections path))])
    (define entries (store-section-entries path section))
    (define empties (for/list ([e (in-list entries)] #:when (string=? (cdr e) "")) (car e)))
    (define summary (key-analyze entries))
    (list section
          (cons 'entries (~a (length entries)))
          (cons 'empty (string-join empties ","))
          (cons 'key-id (summary-ref summary 'key-id))
          (cons 'kind (summary-ref summary 'kind))
          (cons 'fingerprint (summary-ref summary 'fingerprint))
          (cons 'paired (summary-ref summary 'paired))
          (cons 'status (summary-ref summary 'status)))))

(define (summary-ref summary key)
  (define hit (assoc key summary))
  (if hit (cdr hit) "-"))
