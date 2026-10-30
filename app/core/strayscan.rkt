#lang racket/base

;; Bounded stray-private-key scanner for working trees — the runbook's
;; "全机搜索旧钥散件" step, made mechanical. Walks a directory tree looking
;; for private key material that never made it into the vault:
;;
;;   - any text file containing a PEM private key header
;;     (PKCS#8 / RSA / EC / ENCRYPTED variants), with its line number
;;   - files with key-ish extensions (.pem .key .der .priv .private .keypair
;;     .p8) that decode to a parseable private key, including single-line
;;     base64(DER) and Sparkle-style base64(seed||pub)
;;
;; Rows carry path/line/kind/fingerprint only — never values. The walk is
;; hard-bounded (depth, file count, file size, row count) and skips vendored
;; trees, the vault file itself and the snapshot history (passed in as
;; excludes by the caller).

(require net/base64
         racket/file
         racket/format
         racket/list
         racket/match
         racket/path
         racket/string
         (only-in "keyformats.rkt" ed25519-from-seed-pub)
         (only-in "keymeta.rkt"
                  value->der private-key-from-der public-key-of
                  spki-der fingerprint-of-der))

(provide stray-scan
         stray-skip-dirs)

(define stray-skip-dirs
  '(".git" ".rivet" ".sync" ".history" ".build" ".venv" "venv" ".gradle" ".cargo"
    "node_modules" "build" "dist" "target" "obj" "DerivedData" "Pods"
    "__pycache__" "Generated Files"))

(define max-depth 12)
(define max-files 20000)
(define max-file-bytes (* 4 1024 1024))
(define max-rows 200)

(define key-extensions
  '(".pem" ".key" ".der" ".priv" ".private" ".keypair" ".p8"))

(define pem-private-rx
  #rx"-----BEGIN ((?:[A-Z0-9]+ )?PRIVATE KEY)-----")

;; ---- walk -----------------------------------------------------------------------

;; rows = (list (path line kind fingerprint) ...); paths relative to root
(define (stray-scan root exclude)
  (define root-path (simplify-path (path->directory-path (expand-user-path root))))
  (unless (directory-exists? root-path)
    (error 'stray-scan "not a directory: ~a" root))
  (define excludes
    (for/list ([p (in-list exclude)] #:when p)
      (simplify-path (expand-user-path p))))
  (define files-scanned (box 0))
  (define rows '())
  (define truncated (box #f))
  (let loop ([dir root-path] [rel ""] [depth 0])
    (unless (or (unbox truncated) (> depth max-depth))
      (define entries (sort (directory-list dir) string<? #:key path->string))
      (for ([entry (in-list entries)] #:break (unbox truncated))
        (define full (build-path dir entry))
        (define rel-entry
          (if (string=? rel "") (path->string entry)
              (string-append rel "/" (path->string entry))))
        (cond
          [(directory-exists? full)
           (unless (member (path->string entry) stray-skip-dirs)
             (loop full rel-entry (add1 depth)))]
          [(and (file-exists? full)
                (< (unbox files-scanned) max-files)
                (not (excluded? full excludes)))
           (set-box! files-scanned (add1 (unbox files-scanned)))
           (define hit (scan-file full rel-entry))
           (when hit
             (set! rows (cons hit rows))
             (when (>= (length rows) max-rows)
               (set-box! truncated #t)))]
          [(>= (unbox files-scanned) max-files)
           (set-box! truncated #t)]))))
  (define found (reverse rows))
  (if (unbox truncated)
      (append found (list (list "(scan truncated at limits)" "" "" "")))
      found))

(define (excluded? full excludes)
  (for/or ([x (in-list excludes)])
    (or (equal? full x)
        (let-values ([(base _name _dir?) (split-path full)])
          (equal? base x)))))

;; ---- single file -----------------------------------------------------------------

;; -> row or #f
(define (scan-file full rel)
  (define size (file-size full))
  (cond
    [(> size max-file-bytes) #f]
    [else
     (define ext (path-get-extension full))
     (define ext-s (and ext (string-downcase (bytes->string/latin-1 ext))))
     (cond
       [(text-file? full)
        (or (scan-text full rel)
            (and (member ext-s key-extensions) (scan-key-ext full rel)))]
       [(member ext-s key-extensions) (scan-key-ext full rel)]
       [else #f])]))

(define (text-file? full)
  (define bs (read-capped full))
  (not (memq 0 (bytes->list (subbytes bs 0 (min (bytes-length bs) 8192))))))

(define (read-capped full)
  (define bs (file->bytes full))
  (if (> (bytes-length bs) max-file-bytes) (subbytes bs 0 max-file-bytes) bs))

;; text files: PEM private headers anywhere in the file, with line numbers
(define (scan-text full rel)
  (let* ([text (bytes->string/utf-8 (read-capped full))]
         [pos (regexp-match-positions pem-block-rx text)])
    (and pos
         (let* ([start (car (car pos))]
                [label (substring text (car (cadr pos)) (cdr (cadr pos)))]
                ;; wire rows are all-strings: the line number travels as text
                [line (number->string (add1 (count-newlines text start)))]
                ;; fingerprint the PEM block itself — a header line inside a
                ;; larger document must not feed the whole file to the parser
                [fp (key-fingerprint-or-dash (value->der (substring text start (cdr (car pos)))))])
           (list rel line (format "pem-private(~a)" label) fp)))))

(define pem-block-rx
  #px"-----BEGIN ((?:[A-Z0-9]+ )?PRIVATE KEY)-----.*?-----END \\1-----")

(define (count-newlines text up-to)
  (for/sum ([c (in-string text)] [i (in-naturals)] #:when (and (< i up-to) (char=? c #\newline)))
    1))

;; key-ish extensions: base64(DER), base64(PEM), binary DER, Sparkle 64B
(define (scan-key-ext full rel)
  (define bs (read-capped full))
  (cond
    [(and (>= (bytes-length bs) 2) (= (bytes-ref bs 0) 48))
     (define key (private-key-or-false bs))
     (and key (list rel "0" "der-private" (public-fingerprint key)))]
    [else
     (define text (string-trim (bytes->string/latin-1 bs)))
     (cond
       [(text-file? full)
        (or (let ([der (value->der text)])
              (and der
                   (let ([key (private-key-from-der der)])
                     (and key (list rel "0" "der-private" (public-fingerprint key))))))
            (sparkle-hit text rel))]
       [else #f])]))

;; Sparkle-style base64(seed||pub): 64 bytes forming a valid Ed25519 pair
(define (sparkle-hit text rel)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define d (base64-decode (string->bytes/utf-8 (string-replace text "\n" ""))))
    (and d (= (bytes-length d) 64)
         (with-handlers ([exn:fail? (lambda (_) #f)])
           (define key (ed25519-from-seed-pub (subbytes d 0 32) (subbytes d 32 64)))
           (list rel "0" "sparkle-style-private" (public-fingerprint key))))))

(define (private-key-or-false der)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (and der (private-key-from-der der))))

(define (key-fingerprint-or-dash der)
  (define key (private-key-or-false der))
  (if key (public-fingerprint key) "-"))

(define (public-fingerprint key)
  (fingerprint-of-der (spki-der (public-key-of key))))
