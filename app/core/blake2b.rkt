#lang racket/base

;; One-shot BLAKE2b (RFC 7693), unkeyed, digests up to 64 bytes.
;;
;; Only the single-block case is implemented: keyward uses this for the
;; minisign secret-key checksum over a 104-byte blob, and every other
;; caller hashes short identifiers. A general streaming implementation
;; would be dead weight here — and the pure-Racket form avoids a libb2
;; native dependency across all three hosts (the `crypto` package's
;; b2-factory needs an external libb2, which no target platform ships).

(require racket/math)

(provide blake2b-256 blake2b)

(define block-bytes 128)
(define max-out-bytes 64)

(define iv
  (vector #x6a09e667f3bcc908 #xbb67ae8584caa73b #x3c6ef372fe94f82b
          #xa54ff53a5f1d36f1 #x510e527fade682d1 #x9b05688c2b3e6c1f
          #x1f83d9abfb41bd6b #x5be0cd19137e2179))

(define sigma
  '#(#(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)
     #(14 10 4 8 9 15 13 6 1 12 0 2 11 7 5 3)
     #(11 8 12 0 5 2 15 13 10 14 3 6 7 1 9 4)
     #(7 9 3 1 13 12 11 14 2 6 5 10 4 0 15 8)
     #(9 0 5 7 2 4 10 15 14 1 11 12 6 8 3 13)
     #(2 12 6 10 0 11 8 3 4 13 7 5 15 14 1 9)
     #(12 5 1 15 14 13 4 10 0 7 6 3 9 2 8 11)
     #(13 11 7 14 12 1 3 9 5 0 15 4 8 6 2 10)
     #(6 15 14 9 11 3 0 8 12 2 13 7 1 4 10 5)
     #(10 2 8 4 7 6 1 5 15 11 9 14 3 12 13 0)))

(define (mod64 x) (bitwise-and x #xFFFFFFFFFFFFFFFF))

(define (rotr64 x n) (bitwise-ior (arithmetic-shift x (- n)) (bitwise-and (arithmetic-shift x (- 64 n)) #xFFFFFFFFFFFFFFFF)))

(define (le-bytes->word bs off)
  (for/fold ([acc 0]) ([i (in-range 7 -1 -1)])
    (bitwise-ior (arithmetic-shift acc 8) (bytes-ref bs (+ off i)))))

(define (g v a b c d x y)
  (vector-set! v a (mod64 (+ (vector-ref v a) (vector-ref v b) x)))
  (vector-set! v d (rotr64 (mod64 (bitwise-xor (vector-ref v d) (vector-ref v a))) 32))
  (vector-set! v c (mod64 (+ (vector-ref v c) (vector-ref v d))))
  (vector-set! v b (rotr64 (mod64 (bitwise-xor (vector-ref v b) (vector-ref v c))) 24))
  (vector-set! v a (mod64 (+ (vector-ref v a) (vector-ref v b) y)))
  (vector-set! v d (rotr64 (mod64 (bitwise-xor (vector-ref v d) (vector-ref v a))) 16))
  (vector-set! v c (mod64 (+ (vector-ref v c) (vector-ref v d))))
  (vector-set! v b (rotr64 (mod64 (bitwise-xor (vector-ref v b) (vector-ref v c))) 63)))

(define (compress h block t f0)
  (define m (make-vector 16))
  (for ([i (in-range 16)])
    (vector-set! m i (le-bytes->word block (* 8 i))))
  (define v (make-vector 16))
  (for ([i (in-range 8)]) (vector-set! v i (vector-ref h i)))
  (for ([i (in-range 8)]) (vector-set! v (+ 8 i) (vector-ref iv i)))
  (vector-set! v 12 (bitwise-xor (vector-ref v 12) t))
  ;; RFC 7693: the last-block flag is f0 only; f1 stays zero outside tree
  ;; hashing, so exactly one of v14/v15 is flipped
  (when f0
    (vector-set! v 14 (bitwise-xor (vector-ref v 14) #xFFFFFFFFFFFFFFFF)))
  (for ([r (in-range 12)])
    (define s (vector-ref sigma (modulo r 10)))
    (g v 0 4 8 12 (vector-ref m (vector-ref s 0)) (vector-ref m (vector-ref s 1)))
    (g v 1 5 9 13 (vector-ref m (vector-ref s 2)) (vector-ref m (vector-ref s 3)))
    (g v 2 6 10 14 (vector-ref m (vector-ref s 4)) (vector-ref m (vector-ref s 5)))
    (g v 3 7 11 15 (vector-ref m (vector-ref s 6)) (vector-ref m (vector-ref s 7)))
    (g v 0 5 10 15 (vector-ref m (vector-ref s 8)) (vector-ref m (vector-ref s 9)))
    (g v 1 6 11 12 (vector-ref m (vector-ref s 10)) (vector-ref m (vector-ref s 11)))
    (g v 2 7 8 13 (vector-ref m (vector-ref s 12)) (vector-ref m (vector-ref s 13)))
    (g v 3 4 9 14 (vector-ref m (vector-ref s 14)) (vector-ref m (vector-ref s 15))))
  (for ([i (in-range 8)])
    (vector-set! h i (bitwise-xor (bitwise-xor (vector-ref h i) (vector-ref v i))
                                  (vector-ref v (+ 8 i))))))

;; one-shot unkeyed BLAKE2b; supports messages of at most one block
(define (blake2b out-bytes message)
  (unless (and (integer? out-bytes) (<= 1 out-bytes max-out-bytes))
    (error 'blake2b "digest size must be 1..64"))
  (unless (bytes? message)
    (error 'blake2b "message must be bytes"))
  (unless (<= (bytes-length message) block-bytes)
    (error 'blake2b "message longer than one block (~a bytes)" block-bytes))
  (define h (make-vector 8))
  (for ([i (in-range 8)]) (vector-set! h i (vector-ref iv i)))
  (vector-set! h 0 (bitwise-xor (vector-ref h 0)
                                #x01010000          ; unkeyed: fanout=1 depth=1
                                (arithmetic-shift out-bytes 0)))
  (define block (make-bytes block-bytes 0))
  (bytes-copy! block 0 message)
  (compress h block (bytes-length message) #t)
  (define out (make-bytes out-bytes))
  (for ([i (in-range out-bytes)])
    (bytes-set! out i
                (bitwise-and (arithmetic-shift (vector-ref h (quotient i 8))
                                               (- (* 8 (modulo i 8))))
                             #xFF)))
  out)

(define (blake2b-256 message) (blake2b 32 message))
