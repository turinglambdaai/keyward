#lang racket/base

;; Keyward backend — the single RVT1 surface shared by the native hosts.
;; Everything declared here is the wire contract: changing an RPC name or a
;; row layout is a cross-platform release, not a local edit.
;;
;;   product row     = (name entries empty key-id kind fingerprint paired status)
;;   info row        = (name entries key-id fingerprint status)   [light, no crypto]
;;   entry row       = (name state)        state = "set" | "empty"
;;   snapshot row    = (stamp size)
;;   generated row   = (key-id fingerprint spki-b64 raw32-b64)
;;
;; Values are only ever returned by the explicit `entry-get` RPC (hosts use
;; it for copy-to-clipboard); every listing/check RPC carries names, counts
;; and fingerprints exclusively.

(require net/base64
         racket/file
         racket/format
         racket/list
         racket/path
         racket/string
         rivet/backend
         "core/keymeta.rkt"
         "core/store.rkt")

(provide start)

(define current-store
  (make-parameter (store-path-default)))

;; ---- store -----------------------------------------------------------------

(define-rpc (store-path : String)
  (path->string (current-store)))

(define-rpc (store-open [path String] : String)
  (define p (simple-form-path (string-trim path)))
  (unless (file-exists? p) (error 'store-open "no such store: ~a" p))
  (current-store p)
  (path->string p))

;; light listing: emptiness only, no crypto — cheap enough for the sidebar
(define-rpc (store-info : (List (List String)))
  (define path (current-store))
  (for/list ([section (in-list (store-sections path))])
    (define entries (store-section-entries path section))
    (define empties (length (filter (lambda (e) (string=? (cdr e) "")) entries)))
    (list section
          (~a (length entries))
          (or (store-entry-ref path section "RIVET_UPDATE_KEY_ID") "")
          (entry-fingerprint path section)
          (cond [(zero? (length entries)) "empty-section"]
                [(positive? empties) (format "empty:~a" empties)]
                [else "ok"]))))

(define (entry-fingerprint path section)
  (with-handlers ([exn:fail? (lambda (_) "-")])
    (define summary (key-summary (store-section-entries path section)))
    (define hit (assoc 'fingerprint summary))
    (if hit (cdr hit) "-")))

;; deep check: parses every key, verifies pairs, counts orphans
(define-rpc (check-store : (List (List String)))
  (define path (current-store))
  (append
   (for/list ([row (in-list (store-check path key-summary))])
     (list (car row)
           (row-ref row 'entries)
           (row-ref row 'empty)
           (row-ref row 'key-id)
           (row-ref row 'kind)
           (row-ref row 'fingerprint)
           (row-ref row 'paired)
           (row-ref row 'status)))
   (list
    (list "(file)"
          ""
          (format "~a orphans" (length (store-orphan-lines path)))
          ""
          ""
          ""
          ""
          (store-file-status path)))))

(define (row-ref row key)
  (define hit (assoc key (cdr row)))
  (if hit (cdr hit) ""))

(define (store-file-status path)
  (define orphans (length (store-orphan-lines path)))
  (define writable (and (memq 'write (file-or-directory-permissions path)) #t))
  (string-join
   (append (if (zero? orphans) '() (list (format "~a orphan lines" orphans)))
           (if writable '() (list "store not writable")))
   (if (and (zero? orphans) writable) "clean" "; ")))

;; ---- entries -----------------------------------------------------------------

(define-rpc (entry-list [product String] : (List (List String)))
  (for/list ([e (in-list (store-section-entries (current-store) product))])
    (list (car e) (if (string=? (cdr e) "") "empty" "set"))))

;; explicit demand only — hosts wire this to copy-to-clipboard
(define-rpc (entry-get [product String] [name String] : String)
  (or (store-entry-ref (current-store) product name)
      (error 'entry-get "no such entry: ~a/~a" product name)))

(define-rpc (entry-set [product String] [name String] [value String] : String)
  (store-set-entry! (current-store) product name value "set via keyward")
  (fingerprint-if-key (current-store) product name))

(define-rpc (entry-delete [product String] [name String] : Bool)
  (store-delete-entry! (current-store) product name "delete via keyward"))

;; collect a PEM file into the store as a single-line base64(PEM) value —
;; 散件即到即收: the import path never leaves a stray copy behind
(define-rpc (entry-import-file [product String] [name String] [file-path String] : String)
  (define text (string-trim (bytes->string/utf-8 (file->bytes file-path))))
  (unless (string-prefix? text "-----BEGIN")
    (error 'entry-import-file "not a PEM file: ~a" file-path))
  (define der (value->der text))
  (unless der (error 'entry-import-file "unreadable PEM: ~a" file-path))
  (define value (bytes->string/utf-8 (base64-encode der "")))
  (store-set-entry! (current-store) product name value "import via keyward")
  (fingerprint-if-key (current-store) product name))

(define (fingerprint-if-key path product name)
  (define summary (key-summary (store-section-entries path product)))
  (define hit (assoc 'fingerprint summary))
  (if (and hit (not (string=? (cdr hit) "-"))) (cdr hit) "ok"))

;; ---- key generation ----------------------------------------------------------

;; Generates an Ed25519 pair and collects it straight into the store under
;; the rivet-family update-key names — no stray key file ever exists, even
;; momentarily. Returns the safe identifiers for the UI to display.
(define-rpc (keypair-generate [product String] : (List String))
  (define-values (priv-der spki) (generate-keypair!))
  (define raw32 (subbytes spki (- (bytes-length spki) 32)))
  (define (b64 b) (bytes->string/utf-8 (base64-encode b "")))
  (define key-id (or (store-entry-ref (current-store) product "RIVET_UPDATE_KEY_ID")
                     (make-key-id product)))
  (define reason (format "generate update key ~a" key-id))
  (store-set-entry! (current-store) product "UPDATE_ED25519_PRIVATE_KEY_B64" (b64 priv-der) reason)
  (store-set-entry! (current-store) product "UPDATE_ED25519_PUBLIC_KEY_SPKI_B64" (b64 spki) reason)
  (store-set-entry! (current-store) product "UPDATE_ED25519_PUBLIC_KEY_RAW_TAIL32_B64" (b64 raw32) reason)
  (store-set-entry! (current-store) product "RIVET_UPDATE_KEY_ID" key-id reason)
  (list key-id (fingerprint-of-der spki) (b64 spki) (b64 raw32)))

;; ---- snapshots ----------------------------------------------------------------

(define-rpc (snapshot-list : (List (List String)))
  (for/list ([s (in-list (store-snapshots (current-store)))])
    (list (car s) (cdr s))))

(define-rpc (snapshot-restore [stamp String] : Bool)
  (store-restore-snapshot! (current-store) stamp))

;; ---- lifecycle ----------------------------------------------------------------

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
