;;; -*- Mode: LISP; Syntax: Common-Lisp; Base: 10; Package: x86 -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the CMU Common Lisp project at
;;; Carnegie Mellon University, and has been placed in the public domain.
;;; If you want to use this code or any part of CMU Common Lisp, please contact
;;; Scott Fahlman or slisp-group@cs.cmu.edu.
;;;
(ext:file-comment
 "$Header: src/compiler/amd64/alloc.lisp $")
;;;
;;; **********************************************************************
;;;
;;; Allocation VOPs for the amd64 port.
;;;
;;; Written by William Lott.
;;;
;;; Debugged by Paul F. Werkowski Spring/Summer 1995.
;;; Enhancements/debugging by Douglas T. Crosher 1996,1996.
;;; 

(in-package :amd64)


;;;; Dynamic-Extent

;;;
;;; Take an arg where to move the stack pointer instead of returning
;;; it via :results, because the former generates a single move.
;;;
(define-vop (%dynamic-extent-start)
  (:args (saved-stack-pointer :scs (any-reg control-stack)))
  (:results)
  (:policy :safe)
  (:generator 0 (inst mov saved-stack-pointer rsp-tn)))

(define-vop (%dynamic-extent-end)
  (:args (saved-stack-pointer :scs (any-reg control-stack)))
  (:results)
  (:policy :safe)
  (:generator 0 (inst mov rsp-tn saved-stack-pointer)))


;;;; LIST and LIST*

(define-vop (list-or-list*)
  (:args (things :more t))
  (:temporary (:sc unsigned-reg) ptr)
  (:temporary (:sc unsigned-reg :offset r11-offset) temp)
  (:temporary (:sc unsigned-reg :to (:result 0) :target result) res)
  (:info num dynamic-extent)
  (:results (result :scs (descriptor-reg)))
  (:variant-vars star)
  (:policy :safe)
  (:node-var node)
  (:generator 0
    (cond ((zerop num)
	   ;; (move result nil-value)
	   (inst mov result nil-value))
	  ((and star (= num 1))
	   (move result (tn-ref-tn things)))
	  (t
	   (macrolet
	       ((store-car (tn list &optional (slot vm:cons-car-slot))
		  `(let ((reg
			  (sc-case ,tn
			    ((any-reg descriptor-reg) ,tn)
			    ((control-stack)
			     (move temp ,tn)
			     temp))))
		     (storew reg ,list ,slot vm:list-pointer-type))))
	     (let ((cons-cells (if star (1- num) num))
		   (*enable-pseudo-atomic* (unless dynamic-extent
					     *enable-pseudo-atomic*)))
	       (pseudo-atomic
		(allocation res (* (pad-data-block cons-size) cons-cells) temp node
			    dynamic-extent)
		(inst lea res
		      (make-ea :byte :base res :disp list-pointer-type))
		(move ptr res)
		(dotimes (i (1- cons-cells))
		  (store-car (tn-ref-tn things) ptr)
		  (setf things (tn-ref-across things))
		  (inst add ptr (pad-data-block cons-size))
		  (storew ptr ptr (- cons-cdr-slot cons-size)
			  list-pointer-type))
		(store-car (tn-ref-tn things) ptr)
		(cond (star
		       (setf things (tn-ref-across things))
		       (store-car (tn-ref-tn things) ptr cons-cdr-slot))
		      (t
		       (storew nil-value ptr cons-cdr-slot
			       list-pointer-type)))
		(assert (null (tn-ref-across things)))))
	     (move result res))))))

(define-vop (list list-or-list*)
  (:variant nil))

(define-vop (list* list-or-list*)
  (:variant t))


;;;; Special purpose inline allocators.

(define-vop (allocate-code-object)
  (:args (boxed-arg :scs (any-reg) :target boxed)
	 (unboxed-arg :scs (any-reg) :target unboxed))
  (:results (result :scs (descriptor-reg)))
  (:temporary (:sc unsigned-reg :from :eval) temp)
  (:temporary (:sc unsigned-reg :from (:argument 0)) boxed)
  (:temporary (:sc unsigned-reg :from (:argument 1)) unboxed)
  (:generator 100
    (move boxed boxed-arg)
    (inst add boxed (fixnumize (1+ code-trace-table-offset-slot)))
    (inst and boxed (lognot lowtag-mask))
    (move unboxed unboxed-arg)
    (inst shr unboxed word-shift)
    (inst add unboxed lowtag-mask)
    (inst and unboxed (lognot lowtag-mask))
    (pseudo-atomic
     ;; now loading code into static space cause it can't move
     (load-symbol-value temp lisp::*static-space-free-pointer*)
     (inst lea result (make-ea :byte :base temp :disp other-pointer-type))
     (inst add temp boxed)
     (inst add temp unboxed)
     (store-symbol-value temp lisp::*static-space-free-pointer*)
     (inst shl boxed (- type-bits word-shift))
     (inst or boxed code-header-type)
     (storew boxed result 0 other-pointer-type)
     (storew unboxed result code-code-size-slot other-pointer-type)
     (inst mov temp nil-value)
     (storew temp result code-entry-points-slot other-pointer-type))
    (storew temp result code-debug-info-slot other-pointer-type)))


(define-vop (allocate-dynamic-code-object)
  (:args (boxed-arg :scs (any-reg) :target boxed) ; fixnum, number of words
	 (unboxed-arg :scs (any-reg) :target unboxed)) ; fixnum, number of bytes
  (:results (result :scs (descriptor-reg) :from :eval))
  (:temporary (:sc unsigned-reg :from (:argument 0)) boxed)
  (:temporary (:sc unsigned-reg :from (:argument 1)) unboxed)
  (:temporary (:sc any-reg :offset r11-offset) temp)
  (:node-var node)
  (:generator 100
    (move boxed boxed-arg)
    ;; the compiled code assumes it's dual word aligned
    (inst lea boxed (make-ea :byte :base boxed :index boxed
			     :disp (* 8 (1+ code-trace-table-offset-slot))))
    (inst and boxed (lognot 15))
    (move unboxed unboxed-arg)
    (inst shr unboxed 2)
    (inst add unboxed 15)
    (inst and unboxed (lognot 15)) ; alignment
    (inst mov result boxed)
    (inst add result unboxed) ; total number of bytes
    (pseudo-atomic
     (allocation result result temp node)
     (inst lea result (make-ea :byte :base result :disp other-pointer-type))
     (inst shl boxed (- type-bits word-shift))
     (inst or boxed code-header-type)
     (storew boxed result 0 other-pointer-type)
     (inst shr unboxed 1) ; number of code words (fixnum tag)
     (storew unboxed result code-code-size-slot other-pointer-type)
     (storew nil-value result code-entry-points-slot other-pointer-type))
    (storew nil-value result code-debug-info-slot other-pointer-type)))


(define-vop (make-fdefn)
  (:policy :fast-safe)
  (:translate make-fdefn)
  (:args (name :scs (descriptor-reg) :to :eval))
  (:results (result :scs (descriptor-reg) :from :argument))
  (:temporary (:sc any-reg :offset r11-offset) temp)
  (:node-var node)
  (:generator 37
    (with-fixed-allocation (result fdefn-type fdefn-size temp node)
      (storew name result fdefn-name-slot other-pointer-type)
      (storew nil-value result fdefn-function-slot other-pointer-type)
      (inst mov-imm temp
	    (make-fixup (extern-alien-name "undefined_tramp") :foreign))
      (storew temp result fdefn-raw-addr-slot other-pointer-type))))


(define-vop (make-closure)
  (:args (function :to :save :scs (descriptor-reg)))
  (:info length dynamic-extent)
  (:temporary (:sc any-reg :offset r11-offset) temp)
  (:results (result :scs (descriptor-reg)))
  (:node-var node)
  (:generator 10
   (let ((*enable-pseudo-atomic* (unless dynamic-extent
				   *enable-pseudo-atomic*)))
     (pseudo-atomic
      (let ((size (+ length closure-info-offset)))
	(allocation result (pad-data-block size) temp node dynamic-extent)
	(inst lea result
	      (make-ea :byte :base result :disp function-pointer-type))
	(storew (logior (ash (1- size) type-bits) closure-header-type)
		result 0 function-pointer-type))
      (loadw temp function closure-function-slot function-pointer-type)
      (storew temp result closure-function-slot function-pointer-type)))))

;;; The compiler likes to be able to directly make value cells.
;;; 
(define-vop (make-value-cell)
  (:args (value :scs (descriptor-reg any-reg) :to :result))
  (:results (result :scs (descriptor-reg) :from :eval))
  (:temporary (:sc any-reg :offset r11-offset) temp)
  (:node-var node)
  (:generator 10
    (with-fixed-allocation
	(result value-cell-header-type value-cell-size temp node))
    (storew value result value-cell-value-slot other-pointer-type)))



;;;; Automatic allocators for primitive objects.

(define-vop (make-unbound-marker)
  (:args)
  (:results (result :scs (any-reg)))
  (:generator 1
    (inst mov result unbound-marker-type)))

(define-vop (fixed-alloc)
  (:args)
  (:info name words type lowtag dynamic-extent)
  (:ignore name)
  (:results (result :scs (descriptor-reg)))
  (:temporary (:sc any-reg :offset r11-offset) temp)
  (:node-var node)
  (:generator 50
    (let ((*enable-pseudo-atomic* (unless dynamic-extent
				    *enable-pseudo-atomic*)))
      (pseudo-atomic
       (allocation result (pad-data-block words) temp node dynamic-extent)
       (inst lea result (make-ea :byte :base result :disp lowtag))
       (when type
	 (storew (logior (ash (1- words) type-bits) type) result 0 lowtag))))))

(define-vop (var-alloc)
  (:args (extra :scs (any-reg)))
  (:arg-types positive-fixnum)
  (:info name words type lowtag)
  (:ignore name)
  (:results (result :scs (descriptor-reg) :from (:eval 1)))
  (:temporary (:sc any-reg :from :eval :to (:eval 1)) bytes)
  (:temporary (:sc any-reg :from :eval :to :result) header)
  (:temporary (:sc any-reg :offset r11-offset) temp)
  (:node-var node)
  (:generator 50
    (inst lea bytes
	  (make-ea :qword :index extra :scale 2 :disp (* (1+ words) word-bytes)))
    (inst mov header bytes)
    (inst shl header (- type-bits 3))	; w+1 to length field
    
    (inst lea header			; (w-1 << 8) | type
	  (make-ea :qword :base header :disp (+ (ash -2 type-bits) type)))
    (inst and bytes (lognot 15)) ; alignment
    (pseudo-atomic
     (allocation result bytes temp node)
     (inst lea result (make-ea :byte :base result :disp lowtag))
     (storew header result 0 lowtag))))
