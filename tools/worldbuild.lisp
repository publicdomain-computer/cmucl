;;; -*- Mode: Lisp; Package: Lisp -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the CMU Common Lisp project at
;;; Carnegie Mellon University, and has been placed in the public domain.
;;; If you want to use this code or any part of CMU Common Lisp, please contact
;;; Scott Fahlman or slisp-group@cs.cmu.edu.
;;;
(ext:file-comment
  "$Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/tools/worldbuild.lisp,v 1.9 1992/02/13 09:10:54 ram Exp $")
;;;
;;; **********************************************************************
;;;
;;; When loaded, this file builds a core image from all the .fasl files that
;;; are part of the kernel CMU Common Lisp system.

(in-package "LISP")

(unless (fboundp 'genesis) (load "target:compiler/generic/genesis"))

(defparameter lisp-files
  `(,@(when (string= (c:backend-name c:*backend*) "PMAX")
	'("target:assembly/mips/assem-rtns.assem"
	  "target:assembly/mips/array.assem"
	  "target:assembly/mips/bit-bash.assem"
	  "target:assembly/mips/arith.assem"
	  "target:assembly/mips/alloc.assem"))
    ,@(when (string= (c:backend-name c:*backend*) "SPARC")
	'("target:assembly/sparc/assem-rtns.assem"
	  "target:assembly/sparc/array.assem"
	  "target:assembly/sparc/bit-bash.assem"
	  "target:assembly/sparc/arith.assem"
	  "target:assembly/sparc/alloc.assem"))
    ,@(when (string= (c:backend-name c:*backend*) "RT")
	'("target:assembly/rt/assem-rtns.assem"
	  "target:assembly/rt/array.assem"
	  "target:assembly/rt/arith.assem"
	  "target:assembly/rt/alloc.assem"))

    "target:code/fdefinition"
    "target:code/eval"

    "target:code/type-boot"
    "target:code/struct"
    "target:code/error"
    "target:code/salterror"
    "target:compiler/type"
    "target:compiler/generic/vm-type"
    "target:compiler/type-init"

    "target:code/defstruct"
    "target:compiler/proclaim"
    "target:compiler/globaldb"
    "target:code/pred"

    "target:code/pathname"
    "target:code/filesys"

    "target:code/kernel"
    "target:code/bit-bash"
    "target:code/array"
    "target:code/char"
    "target:code/lispinit"
    "target:code/seq"
    "target:code/numbers"
    "target:code/float"
    "target:code/float-trap"
    "target:code/irrat"
    "target:code/bignum"
    "target:code/defmacro"
    "target:code/defrecord"
    "target:code/list"
    "target:code/hash"
    "target:code/macros"
    "target:code/sysmacs"
    "target:code/symbol"
    "target:code/string"
    "target:code/mipsstrops"
    "target:code/misc"
    "target:code/gc"
    "target:code/save"
    "target:code/extensions"
    "target:code/alieneval"
    "target:code/c-call"
    "target:code/syscall"
    "target:code/vm"
    #+mach "target:code/mach-os"
    #+sunos "target:code/sunos-os"
    "target:code/serve-event"
    "target:code/stream"
    "target:code/fd-stream"
    "target:code/print"
    "target:code/pprint"
    "target:code/format"
    "target:code/package"
    "target:code/reader"
    "target:code/backq"
    "target:code/sharpm"
    "target:code/load"
    "target:code/machdef"
    ,@(when (string= (c:backend-name c:*backend*) "PMAX")
	'("target:code/pmax-vm"
	  "target:code/pmax-machdef"))
    ,@(when (string= (c:backend-name c:*backend*) "SPARC")
	'("target:code/sparc-vm"
	  "target:code/sparc-machdef"))
    ,@(when (string= (c:backend-name c:*backend*) "RT")
	'("target:code/rt-vm"
	  "target:code/rt-machdef"))

    "target:code/signal"
    "target:code/interr"
    "target:code/debug-info"
    "target:code/debug-int"
    "target:code/debug"
    ))

(setf *genesis-core-name*
      #-(and sparc mach) "target:ldb/kernel.core"
      #+(and sparc mach) "/usr/tmp/kernel.core")
(setf *genesis-c-header-name* "target:ldb/lisp.h")
(setf *genesis-map-name* "target:ldb/lisp.map")
(setf *genesis-symbol-table* "target:ldb/ldb.map")

#+sunos (setf *target-page-size* 8192)

(genesis lisp-files)
