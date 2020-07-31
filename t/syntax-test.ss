(export syntax-test)

(import
  :gerbil/gambit/exceptions
  :std/misc/string :std/srfi/13
  :std/test
  ../base ../number ../syntax)

(defrules defrule ()
  ((_ (name args ...) body ...)
   (defrules name () ((name args ...) body ...))))

(def syntax-test
  (test-suite "test suite for clan/syntax"
    (test-case "with-id"
      (def mem (make-vector 5 0))
      (defrule (defvar name n)
        (with-id defvar ((@ #'name "@") (get #'name) (set #'name "-set!"))
          (begin (def @ n) (def (get) (vector-ref mem @)) (def (set x) (vector-set! mem @ x)))))
      (defvar A 0)
      (defvar B 1)
      (defvar C 2)
      (defvar D 3)
      (A-set! 42) (B-set! (+ (A) 27)) (increment! (C) 5) (D-set! (post-increment! (C) 18))
      (check-equal? mem #(42 69 23 5 0)))))