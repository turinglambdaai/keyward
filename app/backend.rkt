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
         "core/config.rkt"
         "core/keyformats.rkt"
         "core/keymeta.rkt"
         "core/store.rkt"
         "core/strayscan.rkt")

(provide start
         ;; narrow test-facing surface: the rotation RPC bodies run as plain
         ;; functions against the process-global selection, so the runbook
         ;; stays unit-testable without standing up the wire
         select-store!
         rotation-start rotation-status rotation-promote rotation-cancel)

;; the active vault: a path string, or #f until the user picks one. This is
;; PROCESS-global state in a plain box — rivet runs every request handler in
;; a fresh thread, so a `make-parameter` write inside store-open would be
;; invisible to every later handler (live vault switching silently kept
;; serving the startup default until relaunch; the wire acceptance caught
;; it). Box reads/writes are atomic; there is a single writer at a time.
(define store-selection (box (store-path-default)))

(define (select-store! path) (set-box! store-selection path))
(define (selected-store) (unbox store-selection))

(define (active-store)
  (or (selected-store)
      (error 'keyward "no vault selected — choose a secrets.ini first")))

;; ---- store -----------------------------------------------------------------

;; the active store is kept as a plain string end to end: Racket 9.3's
;; path->string rejects strings outright ("contract violation expected:
;; path?"), so a path object must never enter the selection

(define-rpc (store-path : String)
  (define p (selected-store))
  (cond [(string? p) p]
        [(path? p) (path->string p)]
        [else ""]))

(define-rpc (store-open [path String] : String)
  (define p (simple-form-path (string-trim path)))
  (unless (file-exists? p) (error 'store-open "no such store: ~a" p))
  (define ps (path->string p))
  (select-store! ps)
  ;; remember the choice across launches — the config holds a path, never a
  ;; secret; the family path is only a fallback, never an assumption
  (config-set! "store" ps)
  ps)

;; light listing: emptiness only, no crypto — cheap enough for the sidebar
(define-rpc (store-info : (List (List String)))
  (if (selected-store)
      (let ([path (selected-store)])
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
      '()))

(define (entry-fingerprint path section)
  (with-handlers ([exn:fail? (lambda (_) "-")])
    (define summary (key-summary (store-section-entries path section)))
    (define hit (assoc 'fingerprint summary))
    (if hit (cdr hit) "-")))

;; deep check: parses every key, verifies pairs, counts orphans
(define-rpc (check-store : (List (List String)))
  (if (selected-store)
      (let ([path (selected-store)])
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
      '()))

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
  (for/list ([e (in-list (store-section-entries (active-store) product))])
    (list (car e) (if (string=? (cdr e) "") "empty" "set"))))

;; explicit demand only — hosts wire this to copy-to-clipboard
(define-rpc (entry-get [product String] [name String] : String)
  (or (store-entry-ref (active-store) product name)
      (error 'entry-get "no such entry: ~a/~a" product name)))

(define-rpc (entry-set [product String] [name String] [value String] : String)
  (store-set-entry! (active-store) product name value "set via keyward")
  (fingerprint-if-key (active-store) product name))

(define-rpc (entry-delete [product String] [name String] : Bool)
  (store-delete-entry! (active-store) product name "delete via keyward"))

;; collect a key file into the store as a single-line family value —
;; 散件即到即收: the import path never leaves a stray copy behind.
;; Sniffs the native shapes (PEM, base64(DER), Sparkle, minisign) and
;; normalizes everything to base64(DER) / base64(raw 32B).
(define-rpc (entry-import-file [product String] [name String] [file-path String] : String)
  (define text (bytes->string/utf-8 (file->bytes file-path)))
  (define sniffed (sniff-import text name))
  (store-set-entry! (active-store) product name (cdr sniffed) "import via keyward")
  (fingerprint-if-key (active-store) product name))

;; render a vault entry in an updater-native format for the clipboard —
;; the export counterpart of entry-get: explicit demand only, identifiers
;; in listings, values only here
(define-rpc (keypair-export [product String] [name String] [format String] : String)
  (define value (or (store-entry-ref (active-store) product name)
                    (error 'keypair-export "no such entry: ~a/~a" product name)))
  (export-conversion name value format))

;; ---- stray-key scan --------------------------------------------------------------

;; rows are (relative-path line kind fingerprint); the active vault and its
;; snapshot history are always excluded, values never appear
(define-rpc (stray-scan-tree [dir String] : (List (List String)))
  (define path (active-store))
  (stray-scan dir
              (list path
                    (if path
                        (path->string (snapshots-dir (string->path path)))
                        #f))))

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
  (define key-id (or (store-entry-ref (active-store) product "RIVET_UPDATE_KEY_ID")
                     (make-key-id product)))
  (define reason (format "generate update key ~a" key-id))
  (store-set-entry! (active-store) product "UPDATE_ED25519_PRIVATE_KEY_B64" (b64 priv-der) reason)
  (store-set-entry! (active-store) product "UPDATE_ED25519_PUBLIC_KEY_SPKI_B64" (b64 spki) reason)
  (store-set-entry! (active-store) product "UPDATE_ED25519_PUBLIC_KEY_RAW_TAIL32_B64" (b64 raw32) reason)
  (store-set-entry! (active-store) product "RIVET_UPDATE_KEY_ID" key-id reason)
  (list key-id (fingerprint-of-der spki) (b64 spki) (b64 raw32)))

;; ---- rotation (the two-phase runbook) ----------------------------------------
;;
;; Phase 1 (rotation-start): stage a NEXT pair under UPDATE_ED25519_NEXT_* —
;; the active signing key is untouched, so CI keeps releasing with the old
;; key while the app source embeds the NEXT public anchors.
;; Phase 2 (rotation-promote): once a phase-1 release shipped, move NEXT to
;; active and swap the key id — from here CI signs with the new private key.
;; rotation-cancel discards a staged pair; rotation-status reports the
;; staging state. All outputs are identifiers and fingerprints only.

(define active-private-name "UPDATE_ED25519_PRIVATE_KEY_B64")
(define active-spki-name "UPDATE_ED25519_PUBLIC_KEY_SPKI_B64")
(define active-raw32-name "UPDATE_ED25519_PUBLIC_KEY_RAW_TAIL32_B64")
(define active-key-id-name "RIVET_UPDATE_KEY_ID")
(define next-private-name "UPDATE_ED25519_NEXT_PRIVATE_KEY_B64")
(define next-spki-name "UPDATE_ED25519_NEXT_PUBLIC_KEY_SPKI_B64")
(define next-raw32-name "UPDATE_ED25519_NEXT_PUBLIC_KEY_RAW_TAIL32_B64")
(define next-key-id-name "UPDATE_ED25519_NEXT_KEY_ID")

(define rotation-next-names
  (list next-private-name next-spki-name next-raw32-name next-key-id-name))

(define (b64-of bs) (bytes->string/utf-8 (base64-encode bs "")))

;; Fingerprint of the private key stored under `name`, or "-" when
;; absent/unreadable.
(define (entry-fingerprint-of path product name)
  (define v (store-entry-ref path product name))
  (cond [(not v) "-"]
        [else
         (with-handlers ([exn:fail? (lambda (_) "-")])
           (define der (value->der v))
           (define key (and der (private-key-from-der der)))
           (if key
               (fingerprint-of-der (spki-der (public-key-of key)))
               "-"))]))

(define-rpc (rotation-start [product String] : (List String))
  (define-values (priv-der spki) (generate-keypair!))
  (define key-id (make-key-id product))
  (define reason (format "stage next rotation key ~a" key-id))
  (store-set-entry! (active-store) product next-private-name (b64-of priv-der) reason)
  (store-set-entry! (active-store) product next-spki-name (b64-of spki) reason)
  (store-set-entry! (active-store) product next-raw32-name
                    (b64-of (subbytes spki (- (bytes-length spki) 32))) reason)
  (store-set-entry! (active-store) product next-key-id-name key-id reason)
  (list key-id (fingerprint-of-der spki) (b64-of spki)
        (b64-of (subbytes spki (- (bytes-length spki) 32)))))

;; (next-present next-paired next-fingerprint next-key-id
;;  active-fingerprint active-key-id) — identifiers and fingerprints only
(define-rpc (rotation-status [product String] : (List String))
  (define path (active-store))
  (define next-v (store-entry-ref path product next-private-name))
  (define present (if (and next-v (not (string=? next-v ""))) "yes" "no"))
  (define next-paired
    (if (string=? present "no")
        "-"
        (let ([summary (key-summary
                        (filter (lambda (e) (string-prefix? (car e) "UPDATE_ED25519_NEXT_"))
                                (store-section-entries path product)))])
          (or (assoc-ref summary 'status) "-"))))
  (define (entry-or-dash name)
    (or (store-entry-ref path product name) "-"))
  (list present
        next-paired
        (entry-fingerprint-of path product next-private-name)
        (entry-or-dash next-key-id-name)
        (entry-fingerprint-of path product active-private-name)
        (entry-or-dash active-key-id-name)))

(define (assoc-ref assoc key)
  (define hit (assq key assoc))
  (if hit (cdr hit) #f))

(define-rpc (rotation-promote [product String] : (List String))
  (define path (active-store))
  (define next-entries
    (filter (lambda (e) (string-prefix? (car e) "UPDATE_ED25519_NEXT_"))
            (store-section-entries path product)))
  (define (required name)
    (or (store-entry-ref path product name)
        (error 'rotation-promote "staged entry missing: ~a" name)))
  (unless (member next-private-name (map car next-entries))
    (error 'rotation-promote "no staged next key for ~a — run rotation-start first" product))
  (define summary (key-summary next-entries))
  (unless (string=? (assoc-ref summary 'status) "ok")
    (error 'rotation-promote
           "staged next key for ~a is not paired (~a) — discard or re-stage it"
           product (assoc-ref summary 'status)))
  (define reason "promote next rotation key")
  (store-set-entry! path product active-private-name (required next-private-name) reason)
  (store-set-entry! path product active-spki-name (required next-spki-name) reason)
  (store-set-entry! path product active-raw32-name (required next-raw32-name) reason)
  (store-set-entry! path product active-key-id-name (required next-key-id-name) reason)
  (for ([name (in-list rotation-next-names)])
    (store-delete-entry! path product name reason))
  (list (store-entry-ref path product active-key-id-name)
        (entry-fingerprint-of path product active-private-name)))

(define-rpc (rotation-cancel [product String] : Bool)
  (define path (active-store))
  (unless (store-entry-ref path product next-private-name)
    (error 'rotation-cancel "no staged next key for ~a" product))
  (for ([name (in-list rotation-next-names)])
    (when (store-entry-ref path product name)
      (store-delete-entry! path product name "discard staged rotation key")))
  #t)

;; ---- snapshots ----------------------------------------------------------------

(define-rpc (snapshot-list : (List (List String)))
  (for/list ([s (in-list (store-snapshots (active-store)))])
    (list (car s) (cdr s))))

(define-rpc (snapshot-restore [stamp String] : Bool)
  (store-restore-snapshot! (active-store) stamp))

;; ---- lifecycle ----------------------------------------------------------------

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
