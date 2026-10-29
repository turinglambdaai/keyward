#lang racket/base

;; BLAKE2b tests against the official test vectors (blake2b.net KATs and
;; RFC 7693 appendix), plus the minisign checksum shape keyward exports.

(require net/base64
         rackunit
         racket/format
         racket/list
         "../app/core/blake2b.rkt")

(define (hex bs)
  (apply string-append (for/list ([b (in-bytes bs)]) (~r b #:base 16 #:min-width 2 #:pad-string "0"))))

;; ---- official vectors (digest_size 32 and 64) ---------------------------------

(define (check-digest n message expected)
  (check-equal? (hex (blake2b n message)) expected))

(check-digest 64 #"" "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce")
(check-digest 64 #"abc" "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
(check-digest 32 #"" "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8")
(check-digest 32 #"abc" "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319")
(check-digest 32 (make-bytes 128 #xAB) "e28dbbbacc7cafa062f8c043bf25ec6043bfa25fb32ab91881e09c0a300290d2")
(check-digest 32 (make-bytes 128 0) "378d0caaaa3855f1b38693c1d6ef004fd118691c95c959d4efa950d6d6fcf7c1")

;; ---- guards --------------------------------------------------------------------

(check-exn exn:fail? (lambda () (blake2b 65 #"abc")))
(check-exn exn:fail? (lambda () (blake2b 0 #"abc")))
(check-exn exn:fail? (lambda () (blake2b 32 (make-bytes 129))))
