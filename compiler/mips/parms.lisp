;;; -*- Package: VM; Log: C.Log -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the Spice Lisp project at
;;; Carnegie-Mellon University, and has been placed in the public domain.
;;; If you want to use this code or any part of Spice Lisp, please contact
;;; Scott Fahlman (FAHLMAN@CMUC). 
;;; **********************************************************************
;;;
;;; $Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/compiler/mips/parms.lisp,v 1.65 1990/07/12 12:58:35 wlott Exp $
;;;
;;;    This file contains some parameterizations of various VM
;;; attributes for the MIPS.  This file is separate from other stuff so 
;;; that it can be compiled and loaded earlier. 
;;;
;;; Written by Rob MacLachlan
;;;
;;; Converted to MIPS by William Lott.
;;;

(in-package "VM")

(eval-when (compile load eval)


;;;; Compiler constants.

;;; Maximum number of SCs allowed.
;;;
(defconstant sc-number-limit 32)

;;; The inclusive upper bound on a cost.  We want to write cost frobbing
;;; code so that it is portable, but works on fixnums.  This constant
;;; should be defined so that adding two costs cannot result in fixnum
;;; overflow.
;;;
(defconstant most-positive-cost (1- (expt 2 20)))



;;;; Machine Architecture parameters:

(defconstant word-bits 32
  "Number of bits per word where a word holds one lisp descriptor.")

(defconstant byte-bits 8
  "Number of bits per byte where a byte is the smallest addressable object.")

(defconstant word-shift (1- (integer-length (/ word-bits byte-bits)))
  "Number of bits to shift between word addresses and byte addresses.")

(defconstant word-bytes (/ word-bits byte-bits)
  "Number of bytes in a word.")

(defparameter target-byte-order :little-endian
  "The byte order of the target machine.  Should either be :big-endian
  which has the MSB first (RT) or :little-endian which has the MSB last
  (VAX).")

(defparameter target-most-positive-fixnum (1- (ash 1 29))
  "most-positive-fixnum in the target architecture.")

(defparameter target-most-negative-fixnum (ash -1 29)
  "most-negative-fixnum in the target architecture.")

;;; ### This should be somewhere else.
#-new-compiler
(defconstant native-byte-order :big-endian
  "The byte order we are running under.")

(defconstant float-sign-shift 31)

;;; The exponent min/max values are wrong, I think.  The denorm, infinity, etc.
;;; info must go in there somewhere.

(defconstant single-float-bias 126)
(defconstant single-float-exponent-byte (byte 8 23))
(defconstant single-float-significand-byte (byte 23 0))
(defconstant single-float-normal-exponent-min 0)
(defconstant single-float-normal-exponent-max 255)
(defconstant single-float-hidden-bit (ash 1 23))

(defconstant double-float-bias 1022)
(defconstant double-float-exponent-byte (byte 11 20))
(defconstant double-float-significand-byte (byte 20 0))
(defconstant double-float-normal-exponent-min 0)
(defconstant double-float-normal-exponent-max #x7FF)
(defconstant double-float-hidden-bit (ash 1 20))

(defconstant single-float-digits
  (+ (byte-size single-float-significand-byte) 1))

(defconstant double-float-digits
  (+ (byte-size double-float-significand-byte) word-bits 1))


;;;; Description of the target address space.

;;; Where to put the different spaces.
;;; 
(defparameter target-read-only-space-start #x20000000)
(defparameter target-static-space-start #x30000000)
(defparameter target-dynamic-space-start #x40000000)


;;;; Type definitions:

(defconstant lowtag-bits 3
  "Number of bits at the low end of a pointer used for type information.")

(defconstant lowtag-mask (1- (ash 1 lowtag-bits))
  "Mask to extract the low tag bits from a pointer.")
  
(defconstant lowtag-limit (ash 1 lowtag-bits)
  "Exclusive upper bound on the value of the low tag bits from a
  pointer.")

(defconstant type-bits 8
  "Number of bits used in the header word of a data block for typeing.")

(defconstant type-mask (1- (ash 1 type-bits))
  "Mask to extract the type from a header word.")

(defmacro pad-data-block (words)
  `(logandc2 (+ (ash ,words vm:word-shift) lowtag-mask) lowtag-mask))


(defmacro defenum ((&key (prefix "") (suffix "") (start 0) (step 1))
		   &rest identifiers)
  (let ((results nil)
	(index 0)
	(start (eval start))
	(step (eval step)))
    (dolist (id identifiers)
      (when id
	(multiple-value-bind
	    (root docs)
	    (if (consp id)
		(values (car id) (cdr id))
		(values id nil))
	  (push `(defconstant ,(intern (concatenate 'simple-string
						    (string prefix)
						    (string root)
						    (string suffix)))
		   ,(+ start (* step index))
		   ,@docs)
		results)))
      (incf index))
    `(eval-when (compile load eval)
       ,@(nreverse results))))

;;; The main types.  These types are represented by the low three bits of the
;;; pointer or immeditate object.
;;; 
(defenum (:suffix -type)
  even-fixnum
  function-pointer
  other-immediate-0
  list-pointer
  odd-fixnum
  structure-pointer
  other-immediate-1
  other-pointer)

;;; The heap types.  Each of these types is in the header of objects in
;;; the heap.
;;; 
(defenum (:suffix -type
	  :start (+ (ash 1 lowtag-bits) other-immediate-0-type)
	  :step (ash 1 (1- lowtag-bits)))
  bignum
  ratio
  single-float
  double-float
  complex
  
  simple-array
  simple-string
  simple-bit-vector
  simple-vector
  simple-array-unsigned-byte-2
  simple-array-unsigned-byte-4
  simple-array-unsigned-byte-8
  simple-array-unsigned-byte-16
  simple-array-unsigned-byte-32
  simple-array-single-float
  simple-array-double-float
  complex-string
  complex-bit-vector
  complex-vector
  complex-array
  
  code-header
  function-header
  closure-function-header
  return-pc-header
  closure-header
  value-cell-header
  symbol-header
  base-character
  sap
  unbound-marker
  weak-pointer)


;;;; Other non-type constants.

(defenum (:suffix -flag)
  atomic
  interrupted)

(defenum (:suffix -trap :start 8)
  halt
  pending-interrupt
  error
  cerror)

(defenum (:prefix vector- :suffix -subtype)
  normal
  structure
  valid-hashing
  must-rehash)



;;;; Primitive data objects definition noise.


(defstruct (slot
	    (:constructor %make-slot
			  (name docs rest-p length options)))
  (name nil :type symbol)
  (docs nil :type (or null simple-string))
  (rest-p nil :type (member t nil))
  (offset 0 :type fixnum)
  (length 1 :type fixnum)
  (options nil :type list))

(defun make-slot (name &rest options
		       &key docs rest-p (length (if rest-p 0 1))
		       &allow-other-keys)
  (remf options :docs)
  (remf options :rest-p)
  (remf options :length)
  (%make-slot name docs rest-p length options))

(defstruct (primitive-object
	    )
  (name nil :type symbol)
  (header nil :type (or (member t nil) fixnum))
  (lowtag nil :type (or null fixnum))
  (options nil :type list)
  (slots nil :type list)
  (size 0 :type fixnum)
  (variable-length nil :type (member t nil)))


(defmacro define-primitive-object ((name &rest options
					 &key header lowtag
					 &allow-other-keys)
				   &rest slots)
  (setf options (copy-list options))
  (remf options :header)
  (remf options :lowtag)
  (let ((prim-obj
	 (make-primitive-object :name name
				:header header
				:lowtag lowtag
				:options options
				:slots (mapcar #'(lambda (slot)
						   (if (atom slot)
						       (make-slot slot)
						       (apply #'make-slot
							      slot)))
					       slots))))
    (collect ((forms) (exports))
      (let ((offset (if (primitive-object-header prim-obj) 1 0))
	    (variable-length nil))
	(dolist (slot (primitive-object-slots prim-obj))
	  (when variable-length
	    (error "~S is anything after a :rest-p t slot." slot))
	  (let* ((rest-p (slot-rest-p slot))
		 (offset-sym
		  (intern (concatenate 'simple-string
				       (string name)
				       "-"
				       (string (slot-name slot))
				       (if rest-p "-OFFSET" "-SLOT")))))
	    (forms `(defconstant ,offset-sym ,offset
		      ,@(when (slot-docs slot) (list (slot-docs slot)))))
	    (setf (slot-offset slot) offset)
	    (exports offset-sym)
	    (incf offset (slot-length slot))
	    (when rest-p (setf variable-length t))))
	(setf (primitive-object-variable-length prim-obj) variable-length)
	(unless variable-length
	  (let ((size (intern (concatenate 'simple-string
					   (string name)
					   "-SIZE"))))
	    (forms `(defconstant ,size ,offset
		      ,(format nil
			       "Number of slots used by each ~S~
			       ~@[~* including the header~]."
			       name header)))
	    (exports size)))
	(setf (primitive-object-size prim-obj) offset))
      `(eval-when (compile load eval)
	 (setf *primitive-objects*
	       (cons ',prim-obj
		     (delete ',name *primitive-objects*
			     :key #'primitive-object-name)))
	 (export ',(exports))
	 ,@(forms)))))


(defvar *primitive-objects* nil)

(defmacro define-for-each-primitive-object ((var) &body body)
  `(c::expand
    `(progn
       ,@(remove nil
		 (mapcar #'(lambda (,var)
			     ,@body)
			 *primitive-objects*)))))



;;;; The primitive objects themselves.


(define-primitive-object (cons :lowtag list-pointer-type
			       :alloc-trans cons)
  (car :ref-vop car :ref-trans car
       :setf-vop c::set-car :set-trans c::%rplaca
       :init :arg)
  (cdr :ref-vop cdr :ref-trans cdr
       :setf-vop c::set-cdr :set-trans c::%rplacd
       :init :arg))

(define-primitive-object (bignum :lowtag other-pointer-type
				 :header bignum-type
				 :alloc-trans bignum::%allocate-bignum)
  (digits :rest-p t :c-type "long"))

(define-primitive-object (ratio :lowtag other-pointer-type
				:header ratio-type
				:alloc-vop c::make-ratio
				:alloc-trans %make-ratio)
  (numerator :ref-vop numerator :init :arg)
  (denominator :ref-vop denominator :init :arg))

(define-primitive-object (single-float :lowtag other-pointer-type
				       :header single-float-type)
  (value :c-type "float"))

(define-primitive-object (double-float :lowtag other-pointer-type
				       :header double-float-type)
  (value :c-type "double" :length 2))

(define-primitive-object (complex :lowtag other-pointer-type
				  :header complex-type
				  :alloc-vop c::make-complex
				  :alloc-trans %make-complex)
  (real :ref-vop realpart :init :arg)
  (imag :ref-vop imagpart :init :arg))

(define-primitive-object (array :lowtag other-pointer-type
				:header t)
  (fill-pointer :type index
		:ref-trans %array-fill-pointer
		:ref-known (c::flushable c::foldable)
		:set-trans (setf %array-fill-pointer)
		:set-known (c::unsafe))
  (fill-pointer-p :type (member t nil)
		  :ref-trans %array-fill-pointer-p
		  :ref-known (c::flushable c::foldable)
		  :set-trans (setf %array-fill-pointer-p)
		  :set-known (c::unsafe))
  (elements :type index
	    :ref-trans %array-available-elements
	    :ref-known (c::flushable c::foldable)
	    :set-trans (setf %array-available-elements)
	    :set-known (c::unsafe))
  (data :type array
	:ref-trans %array-data-vector
	:ref-known (c::flushable c::foldable)
	:set-trans (setf %array-data-vector)
	:set-known (c::unsafe))
  (displacement :type (or index null)
		:ref-trans %array-displacement
		:ref-known (c::flushable c::foldable)
		:set-trans (setf %array-displacement)
		:set-known (c::unsafe))
  (displaced-p :type (member t nil)
	       :ref-trans %array-displaced-p
	       :ref-known (c::flushable c::foldable)
	       :set-trans (setf %array-displaced-p)
	       :set-known (c::unsafe))
  (dimensions :rest-p t))

(define-primitive-object (vector :lowtag other-pointer-type :header t)
  (length :ref-trans c::vector-length
	  :ref-known (c::flushable c::foldable))
  (data :rest-p t :c-type "unsigned long"))

(define-primitive-object (code :lowtag other-pointer-type :header t)
  (code-size :ref-vop c::code-code-size)
  (entry-points :ref-vop c::code-entry-points
		:set-vop c::set-code-entry-points)
  (debug-info :type t
	      :ref-trans di::code-debug-info
	      :ref-known (c::flushable)
	      :set-vop c::set-code-debug-info)
  (constants :rest-p t))

(define-primitive-object (function-header :lowtag function-pointer-type
					  :header function-header-type)
  (self :ref-vop c::function-self :set-vop c::set-function-self)
  (next :ref-vop c::function-next :set-vop c::set-function-next)
  (name :ref-vop c::function-name
	:ref-known (c::flushable)
	:ref-trans %function-header-name
	:set-vop c::set-function-name)
  (arglist :ref-vop c::function-arglist
	   :ref-known (c::flushable)
	   :ref-trans lisp::%function-header-arglist
	   :set-vop c::set-function-arglist)
  (type :ref-vop c::function-type
	:ref-known (c::flushable)
	:ref-trans lisp::%function-header-type
	:set-vop c::set-function-type)
  (code :rest-p t :c-type "unsigned char"))

(define-primitive-object (return-pc :lowtag other-pointer-type :header t)
  (return-point :c-type "unsigned char" :rest-p t))

(define-primitive-object (closure :lowtag function-pointer-type
				  :header closure-header-type
				  :alloc-vop c::make-closure)
  (function :init :arg
	    :ref-vop c::closure-function
	    :ref-known (c::flushable)
	    :ref-trans %closure-function)
  (info :rest-p t :set-vop c::closure-init :ref-vop c::closure-ref))

(define-primitive-object (value-cell :lowtag other-pointer-type
				     :header value-cell-header-type
				     :alloc-vop c::make-value-cell)
  (value :set-vop c::value-cell-set
	 :ref-vop c::value-cell-ref
	 :init :arg))

(define-primitive-object (symbol :lowtag other-pointer-type
				 :header symbol-header-type)
  (value :set-trans set
	 :setf-vop set)
  (function :setf-vop c::set-symbol-function
	    :set-trans c::%sp-set-definition)
  (plist :ref-trans symbol-plist
	 :setf-vop c::set-symbol-plist
	 :set-trans c::%sp-set-plist)
  (name :ref-trans symbol-name)
  (package :ref-trans symbol-package
	   :setf-vop c::set-package))

(define-primitive-object (sap :lowtag other-pointer-type
			      :header sap-type)
  (pointer :c-type "char *"))


(define-primitive-object (weak-pointer :lowtag other-pointer-type
				       :header weak-pointer-type
				       :alloc-trans c::%make-weak-pointer)
  (value :ref-trans c::%weak-pointer-value
	 :ref-known (c::flushable)
	 :set-trans (setf c::%weak-pointer-value)
	 :set-known (c::unsafe)
	 :init :arg)
  (broken :ref-trans c::%weak-pointer-broken
	  :ref-known (c::flushable)
	  :set-trans (setf c::%weak-pointer-broken)
	  :set-known (c::unsafe)
	  :init :arg)
  (next :c-type "struct weak_pointer *"))
  

;;; Other non-heap data blocks.

(define-primitive-object (binding)
  value
  symbol)

(define-primitive-object (unwind-block)
  (current-uwp :c-type "struct unwind_block *")
  (current-cont :c-type "lispobj *")
  current-code
  entry-pc)

(define-primitive-object (catch-block)
  (current-uwp :c-type "struct unwind_block *")
  (current-cont :c-type "lispobj *")
  current-code
  entry-pc
  tag
  (previous-catch :c-type "struct catch_block *")
  size)



;;;; Static symbols.

;;; These symbols are loaded into static space directly after NIL so
;;; that the system can compute their address by adding a constant
;;; amount to NIL.
;;;
;;; The exported static symbols are a subset of the static symbols that get
;;; exported to the C header file.
;;;
(defparameter static-symbols
  '(t

    ;; Random stuff needed for initialization.
    lisp::lisp-environment-list
    lisp::lisp-command-line-list
    lisp::*initial-symbols*
    lisp::*lisp-initialization-functions*
    lisp::%initial-function
    lisp::*the-undefined-function*

    ;; Free Pointers
    lisp::*read-only-space-free-pointer*
    lisp::*static-space-free-pointer*
    lisp::*initial-dynamic-space-free-pointer*

    ;; Things needed for non-local-exit.
    lisp::*current-catch-block*
    lisp::*current-unwind-protect-block*
    *eval-stack-top*

    ;; Interrupt Handling
    lisp::*free-interrupt-context-index*

    ;; Static functions.
    two-arg-+ two-arg-- two-arg-* two-arg-/ two-arg-< two-arg-> two-arg-=
    two-arg-<= two-arg->= two-arg-/= %negate two-arg-and two-arg-ior two-arg-xor
    length two-arg-gcd two-arg-lcm
    ))

(defparameter exported-static-symbols
  (subseq static-symbols 0 (1+ (position 'lisp::*free-interrupt-context-index*
					 static-symbols))))

(defun static-symbol-p (symbol)
  (member symbol static-symbols))

(defun static-symbol-offset (symbol)
  "Returns the byte offset of the static symbol Symbol."
  (let ((posn (position symbol static-symbols)))
    (unless posn (error "~S is not a static symbol." symbol))
    (+ (* posn (pad-data-block symbol-size))
       (pad-data-block (1- symbol-size))
       other-pointer-type
       (- list-pointer-type))))

(defun offset-static-symbol (offset)
  "Given a byte offset, Offset, returns the appropriate static symbol."
  (multiple-value-bind
      (n rem)
      (truncate (+ offset list-pointer-type (- other-pointer-type)
		   (- (pad-data-block (1- symbol-size))))
		(pad-data-block symbol-size))
    (unless (and (zerop rem) (<= 0 n (1- (length static-symbols))))
      (error "Byte offset, ~D, is not correct." offset))
    (elt static-symbols n)))



;;;; Handy routine for making fixnums:

(defun fixnum (num)
  "Make a fixnum out of NUM.  (i.e. shift by two bits if it will fit.)"
  (if (<= #x-20000000 num #x1fffffff)
      ;; ### ASH doesn't work on negative bignums in the old compiler, but
      ;; it we #-new-compiler this, the wrong defn will be used when we try
      ;; to ncompile-file it in the bootstrap env.
      (if (minusp num) (- (ash (- num) 2)) (ash num 2))
      (error "~D is too big for a fixnum." num)))



;;;; Assembler parameters:

;;; The number of bits per element in the assemblers code vector.
;;;
(defparameter *assembly-unit-length* 8)


;;;; Other parameters:

;;; The number representing the fasl-code format emit code in.
;;;
(defparameter target-fasl-code-format 7)
(defparameter target-fasl-file-type "mips-fasl")

;;; The version string for the implementation dependent code.
;;;
(defparameter vm-version "DECstation 3100/Mach 0.0")




); Eval-When (Compile Load Eval)
