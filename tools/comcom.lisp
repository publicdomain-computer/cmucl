;;; -*- Package: User -*-
;;;
(in-package "USER")

#+bootstrap
(copy-packages '("ASSEM" "MIPS" "C"))
#+bootstrap
(export '(assem::nop) "ASSEM")

;;; Import so that these types which appear in the globldb are the same...
#+bootstrap
(import '(old-c::approximate-function-type
	  old-c::function-info old-c::defstruct-description
	  old-c::defstruct-slot-description)
	"C")

(with-compiler-log-file ("target:compile-compiler.log")

(declaim (optimize (speed 2) (space 2) (inhibit-warnings 2)))

(comf "target:compiler/macros" :load t)
(comf "target:compiler/generic/vm-macs" :load t :proceed t)
(comf "target:compiler/backend" :load t :proceed t)

(defvar c::*target-backend* (c::make-backend))

(when (string= (old-c:backend-name old-c:*backend*) "PMAX")
  (comf "target:compiler/mips/parms" :proceed t)
  (comf "target:compiler/generic/objdef" :proceed t))
(when (string= (old-c:backend-name old-c:*backend*) "SPARC")
  (comf "target:compiler/sparc/parms" :proceed t)
  (comf "target:compiler/generic/objdef" :proceed t))

(comf "target:code/struct") ; For defstruct description structures.
(comf "target:compiler/proclaim") ; For COOKIE structure.
(comf "target:compiler/globals")

(comf "target:compiler/type")
(comf "target:compiler/generic/vm-type")
(comf "target:compiler/type-init")
(comf "target:compiler/sset")
(comf "target:compiler/node")
(comf "target:compiler/ctype")
(comf "target:compiler/vop" :proceed t)
(comf "target:compiler/vmdef" :load t :proceed t)

(comf "target:compiler/assembler" :proceed t) 
(comf "target:compiler/alloc")
(comf "target:compiler/knownfun")
(comf "target:compiler/fndb")
(comf "target:compiler/generic/vm-fndb")
(comf "target:compiler/main")

(comf "target:compiler/ir1tran")
(comf "target:compiler/ir1util")
(comf "target:compiler/ir1opt")
(comf "target:compiler/ir1final")
(comf "target:compiler/srctran")
(comf "target:compiler/array-tran")
(comf "target:compiler/seqtran")
(comf "target:compiler/typetran")
(comf "target:compiler/generic/vm-typetran")
(comf "target:compiler/float-tran")
(comf "target:compiler/locall")
(comf "target:compiler/dfo")
(comf "target:compiler/checkgen")
(comf "target:compiler/constraint")
(comf "target:compiler/envanal")

(comf "target:compiler/tn")
(comf "target:compiler/bit-util")
(comf "target:compiler/life")

(comf "target:code/debug-info")

(comf "target:compiler/debug-dump")
(comf "target:compiler/generic/utils")
(comf "target:assembly/assemfile" :load t)

(when (string= (old-c:backend-name old-c:*backend*) "PMAX")
  (comf "target:compiler/mips/mips-insts")
  (comf "target:compiler/mips/mips-macs" :load t)
  (comf "target:compiler/mips/vm")
  (comf "target:compiler/generic/primtype")
  (comf "target:assembly/mips/support" :load t)
  (comf "target:compiler/mips/move")
  (comf "target:compiler/mips/sap")
  (comf "target:compiler/mips/system")
  (comf "target:compiler/mips/char")
  (comf "target:compiler/mips/float")
  (comf "target:compiler/mips/memory")
  (comf "target:compiler/mips/static-fn")
  (comf "target:compiler/mips/arith")
  (comf "target:compiler/mips/subprim")
  (comf "target:compiler/mips/debug")
  (comf "target:compiler/mips/c-call")
  (comf "target:compiler/mips/cell")
  (comf "target:compiler/mips/values")
  (comf "target:compiler/mips/alloc")
  (comf "target:compiler/mips/call")
  (comf "target:compiler/mips/nlx")
  (comf "target:compiler/mips/print")
  (comf "target:compiler/mips/array")
  (comf "target:compiler/mips/pred")
  (comf "target:compiler/mips/type-vops")

  (comf "target:assembly/mips/assem-rtns")
  (comf "target:assembly/mips/bit-bash")
  (comf "target:assembly/mips/array")
  (comf "target:assembly/mips/arith")
  (comf "target:assembly/mips/alloc"))

(when (string= (old-c:backend-name old-c:*backend*) "SPARC")
  (comf "target:compiler/sparc/insts")
  (comf "target:compiler/sparc/macros" :load t)
  (comf "target:compiler/sparc/vm")
  (comf "target:compiler/generic/primtype")
  (comf "target:compiler/sparc/move")
  (comf "target:compiler/sparc/sap")
  (comf "target:compiler/sparc/system")
  (comf "target:compiler/sparc/char")
  (comf "target:compiler/sparc/float")
  (comf "target:compiler/sparc/memory")
  (comf "target:compiler/sparc/static-fn")
  (comf "target:compiler/sparc/arith")
  (comf "target:compiler/sparc/subprim")
  (comf "target:compiler/sparc/debug")
  (comf "target:compiler/sparc/c-call")
  (comf "target:compiler/sparc/cell")
  (comf "target:compiler/sparc/values")
  (comf "target:compiler/sparc/alloc")
  (comf "target:compiler/sparc/call")
  (comf "target:compiler/sparc/nlx")
  (comf "target:compiler/sparc/print")
  (comf "target:compiler/sparc/array")
  (comf "target:compiler/sparc/pred")
  (comf "target:compiler/sparc/type-vops")

  (comf "target:assembly/sparc/support")
  (comf "target:assembly/sparc/assem-rtns")
  (comf "target:assembly/sparc/bit-bash")
  (comf "target:assembly/sparc/array")
  (comf "target:assembly/sparc/arith")
  (comf "target:assembly/sparc/alloc"))

(comf "target:compiler/pseudo-vops")

(comf "target:compiler/aliencomp")
(comf "target:compiler/gtn")
(comf "target:compiler/ltn")
(comf "target:compiler/stack")
(comf "target:compiler/control")
(comf "target:compiler/entry")
(comf "target:compiler/ir2tran")
(comf "target:compiler/copyprop")
(comf "target:compiler/assem-opt")
(comf "target:compiler/represent")
(comf "target:compiler/generic/vm-tran")
(comf "target:compiler/pack")
(comf "target:compiler/codegen")
(comf "target:compiler/debug")
(comf "target:compiler/statcount")
(comf "target:compiler/dyncount")

(comf "target:compiler/dump")

(comf "target:compiler/generic/core")
(comf "target:compiler/generic/genesis")

(comf "target:compiler/eval-comp")
(comf "target:compiler/eval")

); with-compiler-error-log
