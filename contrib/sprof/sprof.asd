;;;; -*- Mode: LISP; Syntax: ANSI-Common-Lisp; Base: 10 -*-

(in-package :asdf)

(defsystem :sprof
  :name "demos"
  :author "Gerd Moellmann"
  :license "BSD-like"
  :description "Statistical profiler"
  :components
  ((:file "sprof")))


