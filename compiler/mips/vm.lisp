;;; -*- Package: C; Log: C.Log -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the CMU Common Lisp project at
;;; Carnegie Mellon University, and has been placed in the public
;;; domain.  If you want to use this code or any part of CMU Common
;;; Lisp, please contact Scott Fahlman (Scott.Fahlman@CS.CMU.EDU)
;;; **********************************************************************
;;;
;;; $Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/compiler/mips/vm.lisp,v 1.11 1990/02/25 18:35:05 ch Exp $
;;;
;;; This file contains the VM definition for the MIPS R2000 and the new
;;; object format.
;;;
;;; Written by Christopher Hoover and William Lott.
;;;
(in-package "C")


;;;; SB and SC definition:

(define-storage-base registers :finite :size 32)
(define-storage-base control-stack :unbounded :size 8)
(define-storage-base number-stack :unbounded :size 8)
(define-storage-base constant :non-packed)
(define-storage-base immediate-constant :non-packed)

;;;
;;; Handy macro so we don't have to keep changing all the numbers whenever
;;; we insert a new storage class.
;;; 
(defmacro define-storage-classes (&rest classes)
  `(progn
     ,@(mapcar (let ((index -1))
		 #'(lambda (class)
		     (incf index)
		     `(define-storage-class ,(car class) ,index ,@(cdr class))))
	       classes)))

(define-storage-classes
  ;; Objects that can be stored in any register (immediate objects)
  (any-reg registers
   :locations (2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 28 31))

  ;; Objects that must be seen by GC (pointer objects)
  (descriptor-reg registers
   :locations (8 9 10 11 12 13 14 15 16 17 18 19 28 31))

  ;; Objects that must not be seen by GC (unboxed objects)
  (non-descriptor-reg registers
   :locations (2 3 4 5 6 7))

  ;; Pointers to the interior of objects.
  (interior-reg registers
   :locations (1))

  ;; Unboxed string-chars
  (string-char-reg registers
   :locations (2 3 4 5 6 7))

  ;; Unboxed SAP's (arbitrary pointers into address space)
  (sap-reg registers
   :locations (2 3 4 5 6 7))

  ;; Stack for descriptor objects (scanned by GC)
  (control-stack control-stack)

  ;; Stack for non-descriptor objects (not scanned by GC)
  (number-stack number-stack)

  ;; Unboxed string-char stack
  (string-char-stack number-stack)

  ;; Unboxed SAP stack
  (sap-stack number-stack)

  ;; Non-immediate contstants in the constant pool
  (constant constant)

  ;; Immediate numeric constants.
  ;; 
  ;;   zero = (integer 0 0)
  ;; 
  ;;   negative-immediate = (integer #x-1FFF #-x0001)
  ;;        The funny lower bound guarantees that the negation of an immediate
  ;;        is still an immediate.
  ;; 
  ;;   immediate = (integer 0 #x1FFE)
  ;;	   The funny upper bound guarantees that (1+ immediate) will fit in
  ;;        16 bits.
  ;; 
  ;;   unsigned-immediate = (integer #x1FFF #x3FFE)
  ;;	   The funny upper bound guarantees that (1+ immediate) will fit in
  ;;        16 bits.
  ;;
  (zero immediate-constant)
  (negative-immediate immediate-constant)
  (immediate immediate-constant)
  (unsigned-immediate immediate-constant)

  ;; Immediate null/nil.
  (null immediate-constant)

  ;; Immediate unboxed string-chars.
  (immediate-string-char immediate-constant)

  ;; Immediate unboxed SAP's.
  (immediate-sap immediate-constant)

  ;; Objects that are easier to create using immediate loads than to fetch
  ;; from the constant pool, but which aren't directly usable as immediate
  ;; operands.  These are only recognized by move VOPs.
  (random-immediate immediate-constant))


;;;; Interfaces for stack sizes.

(defun current-frame-size ()
  (* word-bytes
     (finite-sb-current-size
      (sc-sb (svref *sc-numbers* (sc-number-or-lose 'control-stack))))))



;;;; Move costs.

;;; ### this needs work

;;;
;;; Move costs for operand loading and storing
(define-move-costs
  ((any-reg descriptor-reg non-descriptor-reg)
   (1 any-reg descriptor-reg non-descriptor-reg)
   (2 string-char-reg sap-reg)
   (5 control-stack number-stack))

  ((control-stack number-stack constant)
   (5 any-reg descriptor-reg non-descriptor-reg)
   (6 string-char-reg sap-reg))

  ((immediate zero null random-immediate)
   (1 any-reg descriptor-reg non-descriptor-reg))

  ((immediate-string-char)
   (1 string-char-reg)
   (2 any-reg descriptor-reg non-descriptor-reg))

  ((immediate-sap)
   (1 sap-reg)
   (2 any-reg descriptor-reg non-descriptor-reg))

  ((string-char-reg)
   (1 string-char-reg)
   (2 any-reg descriptor-reg non-descriptor-reg)
   (5 string-char-stack)
   (6 control-stack number-stack))

  ((sap-reg)
   (1 sap-reg)
   (2 any-reg descriptor-reg non-descriptor-reg)
   (5 sap-stack)
   (6 control-stack number-stack))

  ((string-char-stack)
   (5 string-char-reg))

  ((sap-stack)
   (5 sap-reg)))

;;;
;;; SCs which must saved on a function call.
(define-save-scs
  (control-stack any-reg descriptor-reg)
  (string-char-stack string-char-reg)
  (sap-stack sap-reg))


;;;; Primitive Type Definitions

(def-primitive-type t (descriptor-reg control-stack))
(defvar *any-primitive-type* (primitive-type-or-lose 't))

;;; 
(def-primitive-type fixnum (any-reg control-stack))
;;; ### what about character?
(def-primitive-type string-char (string-char-reg any-reg
						 string-char-stack
						 control-stack))

;;; 
(def-primitive-type function (descriptor-reg control-stack))
;;; ### what about structure?
(def-primitive-type list (descriptor-reg control-stack))

;;;
(def-primitive-type bignum (descriptor-reg control-stack))
(def-primitive-type ratio (descriptor-reg control-stack))
(def-primitive-type complex (descriptor-reg control-stack))
(def-primitive-type single-float (descriptor-reg control-stack))
(def-primitive-type double-float (descriptor-reg control-stack))

;;;
(def-primitive-type simple-string (descriptor-reg control-stack))
(def-primitive-type simple-bit-vector (descriptor-reg control-stack))
(def-primitive-type simple-vector (descriptor-reg control-stack))
(def-primitive-type simple-array-unsigned-byte-2 (descriptor-reg control-stack))
(def-primitive-type simple-array-unsigned-byte-4 (descriptor-reg control-stack))
(def-primitive-type simple-array-unsigned-byte-8 (descriptor-reg control-stack))
(def-primitive-type simple-array-unsigned-byte-16 (descriptor-reg control-stack))
(def-primitive-type simple-array-unsigned-byte-32 (descriptor-reg control-stack))
(def-primitive-type simple-array-single-float (descriptor-reg control-stack))
(def-primitive-type simple-array-double-float (descriptor-reg control-stack))

(def-primitive-type random (non-descriptor-reg))
(def-primitive-type interior (interior-reg))

;;;
#|
(def-primitive complex-string (descriptor-reg control-stack))
(def-primitive complex-bit-vector (descriptor-reg control-stack))
(def-primitive complex-vector (descriptor-reg control-stack))
|#


;;;; Primitive-type-of and friends.

;;; Primitive-Type-Of  --  Interface
;;;
;;;    Return the most restrictive primitive type that contains Object.
;;;
(defun primitive-type-of (object)
  (let ((type (ctype-of object)))
    (cond ((not (member-type-p type)) (primitive-type type))
	  ((equal (member-type-members type) '(nil))
	   (primitive-type-or-lose 'list))
	  (t
	   *any-primitive-type*))))

;;; 
(defvar *simple-array-primitive-types*
  '((string-char . simple-string)
    (bit . simple-bit-vector)
    ((unsigned-byte 2) . simple-array-unsigned-byte-2)
    ((unsigned-byte 4) . simple-array-unsigned-byte-4)
    ((unsigned-byte 8) . simple-array-unsigned-byte-8)
    ((unsigned-byte 16) . simple-array-unsigned-byte-16)
    ((unsigned-byte 32) . simple-array-unsigned-byte-32)
    (single-float . simple-array-single-float)
    (double-float . simple-array-double-float)
    (t . simple-vector))
  "An a-list for mapping simple array element types to their
  corresponding primitive types.")

;;;
;;; Return the primitive type corresponding to a type descriptor
;;; structure. The second value is true when the primitive type is
;;; exactly equivalent to the argument Lisp type.
;;;
;;; In a bootstrapping situation, we should be careful to use the
;;; correct values for the system parameters.
;;;
(defun primitive-type (type)
  (declare (type ctype type))
  (etypecase type
    (numeric-type
     (if (not (eq (numeric-type-complexp type) :real))
	 (values *any-primitive-type* nil)
	 (case (numeric-type-class type)
	   (integer
	    (let ((lo (numeric-type-low type))
		  (hi (numeric-type-high type)))
	      (if (and hi lo
		       (>= lo most-negative-fixnum)
		       (<= hi most-positive-fixnum))
		  (values (primitive-type-or-lose 'fixnum)
			  (and (= lo most-negative-fixnum)
			       (= hi most-positive-fixnum)))
		  (values *any-primitive-type* nil))))
	   (t
	    (values *any-primitive-type* nil)))))
    (array-type
       (if (array-type-complexp type)
	   (values *any-primitive-type* nil)
	   (let* ((dims (array-type-dimensions type))
		  (etype (array-type-specialized-element-type type))
		  (type-spec (type-specifier etype))
		  (ptype (cdr (assoc type-spec *simple-array-primitive-types*
				     :test #'equal))))
	     (if (and (consp dims) (null (rest dims)) ptype)
		 (values (primitive-type-or-lose ptype) (eq (first dims) '*))
		 (values *any-primitive-type* nil)))))
    (union-type
     (if (type= type (specifier-type 'list))
	 (values (primitive-type-or-lose 'list) t)
	 (let ((types (union-type-types type)))
	   (multiple-value-bind (res exact)
				(primitive-type (first types))
	     (dolist (type (rest types))
	       (multiple-value-bind (ptype ptype-exact)
				    (primitive-type type)
		 (unless ptype-exact (setq exact nil))
		 (setq res (primitive-type-union res ptype))))
	     (values res exact)))))
    (member-type
     (values (reduce #'primitive-type-union
		     (mapcar #'primitive-type-of 
			     (member-type-members type)))
	     nil))
    (named-type
     (case (named-type-name type)
       ((t bignum ratio complex string-char function)
	(values (primitive-type-or-lose (named-type-name type)) t))
       (cons
	(values (primitive-type-or-lose 'list) nil))
       (standard-char
	(values (primitive-type-or-lose 'string-char) nil))
       (t
	(values *any-primitive-type* nil))))
    (ctype
     (values *any-primitive-type* nil))))


;;;; Magical Registers

(eval-when (compile eval load)
  (defconstant zero-offset 0)
  (defconstant null-offset 20)
  (defconstant bsp-offset 21)
  (defconstant cont-offset 22)
  (defconstant csp-offset 23)
  (defconstant flags-offset 24)
  (defconstant alloc-offset 25)
  (defconstant nsp-offset 29)
  (defconstant code-offset 30))

;;; 
;;; Wired Zero
(defparameter zero-tn
  (make-random-tn :kind :normal
		  :sc (sc-or-lose 'any-reg)
		  :offset zero-offset))

;;;
;;; ``Wired'' NIL
(defparameter null-tn
  (make-random-tn :kind :normal
		  :sc (sc-or-lose 'any-reg)
		  :offset null-offset))

;;; 
;;; Binding stack pointer
(defparameter bsp-tn
  (make-random-tn :kind :normal
		  :sc (sc-or-lose 'any-reg)
		  :offset bsp-offset))

;;;
;;; Frame Pointer
(defparameter cont-tn
  (make-random-tn :kind :normal
		  :sc (sc-or-lose 'any-reg)
		  :offset cont-offset))

;;; 
;;; Control stack pointer
(defparameter csp-tn
  (make-random-tn :kind :normal
		  :sc (sc-or-lose 'any-reg)
		  :offset csp-offset))

;;;
;;; FLAGS magic register
(defparameter flags-tn
  (make-random-tn :kind :normal
		  :sc (sc-or-lose 'any-reg)
		  :offset flags-offset))

;;; 
;;; Allocation pointer
(defparameter alloc-tn
  (make-random-tn :kind :normal
		  :sc (sc-or-lose 'any-reg)
		  :offset alloc-offset))
;;; 
;;; Number stack pointer
(defparameter nsp-tn
  (make-random-tn :kind :normal
		  :sc (sc-or-lose 'any-reg)
		  :offset nsp-offset))

;;; 
;;; Code Pointer
(defparameter code-tn
  (make-random-tn :kind :normal
		  :sc (sc-or-lose 'any-reg)
		  :offset code-offset))

;;;
;;; Global Pointer (for C call-out)
(defparameter gp-tn
  (make-random-tn :kind :normal
		  :sc (sc-or-lose 'any-reg)
		  :offset 29))



;;;; Side-Effect Classes

(def-boolean-attribute vop
  any)


;;;; Constants

;;;
;;; Immediate-Constant-SC  --  Interface
;;;
;;; If value can be represented as an immediate constant, then return the
;;; appropriate SC number, otherwise return NIL.
;;;
(defun immediate-constant-sc (value)
  (typecase value
    ((integer 0 0)
     (sc-number-or-lose 'zero))
    (null
     (sc-number-or-lose 'null))
    ((integer #x-1FFF #x-0001)
     (sc-number-or-lose 'negative-immediate))
    ((integer 0 #x1FFE)
     (sc-number-or-lose 'immediate))
    ((integer #x1FFF #x3FFE)
     (sc-number-or-lose 'unsigned-immediate))
    (symbol
     (if (vm:static-symbol-p value)
	 (sc-number-or-lose 'random-immediate)
	 nil))
    (fixnum
     (sc-number-or-lose 'random-immediate))
    ;; ### what here?
    ;(sap
    ; (sc-number-or-lose 'immediate-sap))
    (t
     ;;
     ;; ### hack around bug in (typep x 'string-char)
     (if (and (characterp value) (string-char-p value))
	 (sc-number-or-lose 'immediate-string-char)
	 nil))))


;;;; Function Call Parameters

;;; The SC numbers for register and stack arguments/return values.
;;;
(defconstant register-arg-scn (sc-number-or-lose 'descriptor-reg))
(defconstant control-stack-arg-scn (sc-number-or-lose 'control-stack))

(eval-when (compile load eval)

;;; Offset of special registers used during calls
;;;
(defconstant nargs-offset 7)
(defconstant cname-offset 14)
(defconstant lexenv-offset 15)
(defconstant args-offset 16)
(defconstant oldcont-offset 17)
(defconstant lra-offset 18)

;;; Offsets of special stack frame locations
(defconstant oldcont-save-offset 0)
(defconstant lra-save-offset 1)
(defconstant lexenv-save-offset 2)

); Eval-When (Compile Load Eval)  


(defparameter nargs-tn
  (make-random-tn :kind :normal
		  :sc (sc-or-lose 'any-reg)
		  :offset nargs-offset))

(defparameter args-tn
  (make-random-tn :kind :normal
		  :sc (sc-or-lose 'descriptor-reg)
		  :offset args-offset))

(defparameter lra-tn
  (make-random-tn :kind :normal
		  :sc (sc-or-lose 'any-reg)
		  :offset lra-offset))


(eval-when (compile load eval)

;;; The number of arguments/return values passed in registers.
;;;
(defconstant register-arg-count 6)

;;; The offsets within the register-arg SC that we pass values in, first
;;; value first.
;;;
(defconstant register-arg-offsets '(8 9 10 11 12 13))

;;; Names to use for the argument registers.
;;; 
(defconstant register-arg-names '(a0 a1 a2 a3 a4 a5))

); Eval-When (Compile Load Eval)


;;; A list of TN's describing the register arguments.
;;;
(defparameter register-arg-tns
  (mapcar #'(lambda (n)
	      (make-random-tn :kind :normal
			      :sc (sc-or-lose 'descriptor-reg)
			      :offset n))
	  register-arg-offsets))
