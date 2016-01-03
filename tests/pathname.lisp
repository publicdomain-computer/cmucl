;; Tests for pathnames

(defpackage :pathname-tests
  (:use :cl :lisp-unit))

(in-package "PATHNAME-TESTS")

;; Define "foo:" search list.  /tmp and /usr should exist on all unix
;; systems.
(setf (ext:search-list "foo:")
      '(#p"/tmp/" #p"/usr/"))

;; Define "bar:" search list.  The second entry should match the
;; second entry of the "foo:" search list.
(setf (ext:search-list "bar:")
      '(#p"/bin/" #p"/usr/"))

(define-test pathname-match-p.search-lists
    (:tag :search-list)
  ;; Basic tests where the wild path is search-list

  (assert-true (pathname-match-p "/tmp/foo.lisp" "foo:*"))
  (assert-true (pathname-match-p "/tmp/zot/foo.lisp" "foo:**/*"))
  (assert-true (pathname-match-p "/tmp/zot/foo.lisp" "foo:**/*.lisp"))
  ;; These match because the second entry of the "foo:" search list is
  ;; "/usr/".
  (assert-true (pathname-match-p "/usr/foo.lisp" "foo:*"))
  (assert-true (pathname-match-p "/usr/bin/foo" "foo:**/*"))
  (assert-true (pathname-match-p "/usr/bin/foo.lisp" "foo:**/*.lisp"))

  ;; This fails because "/bin/" doesn't match any path of the search
  ;; list.
  (assert-false (pathname-match-p "/bin/foo.lisp" "foo:*"))

  ;; Basic test where the pathname is a search-list and the wild path is not.
  (assert-true (pathname-match-p "foo:foo.lisp" "/tmp/*"))
  (assert-true (pathname-match-p "foo:foo" "/usr/*"))
  (assert-true (pathname-match-p "foo:zot/foo.lisp" "/usr/**/*.lisp"))

  (assert-false (pathname-match-p "foo:foo" "/bin/*"))
  
  ;; Tests where both args are search-lists.
  (assert-true "foo:foo.lisp" "bar:*"))
