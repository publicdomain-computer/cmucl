;;; -*- Package: C -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the Spice Lisp project at
;;; Carnegie-Mellon University, and has been placed in the public domain.
;;; If you want to use this code or any part of Spice Lisp, please contact
;;; Scott Fahlman (FAHLMAN@CMUC). 
;;; **********************************************************************
;;;
;;; $Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/compiler/mips/alloc.lisp,v 1.4 1990/04/24 02:55:22 wlott Exp $
;;;
;;; Allocation VOPs for the MIPS port.
;;;
;;; Written by William Lott.
;;; 

(in-package "C")


(define-vop (list-or-list*)
  (:args (things :more t))
  (:temporary (:scs (descriptor-reg) :type list) ptr)
  (:temporary (:scs (descriptor-reg)) temp)
  (:temporary (:scs (descriptor-reg) :type list :to (:result 0) :target result)
	      res)
  (:temporary (:scs (non-descriptor-reg) :type random) ndescr)
  (:info num)
  (:results (result :scs (descriptor-reg)))
  (:variant-vars star)
  (:policy :safe)
  (:generator 0
    (cond ((zerop num)
	   (move result null-tn))
	  ((and star (= num 1))
	   (move result (tn-ref-tn things)))
	  (t
	   (macrolet
	       ((store-car (tn list &optional (slot vm:cons-car-slot))
		  `(let ((reg
			  (sc-case ,tn
			    ((any-reg descriptor-reg) ,tn)
			    (zero zero-tn)
			    (null null-tn)
			    (control-stack
			     (load-stack-tn temp ,tn)
			     temp))))
		     (storew reg ,list ,slot vm:list-pointer-type))))
	     (let ((cons-cells (if star (1- num) num)))
	       (pseudo-atomic (ndescr)
		 (inst addu res alloc-tn vm:list-pointer-type)
		 (inst addu alloc-tn alloc-tn
		       (* (vm:pad-data-block vm:cons-size) cons-cells))
		 (move ptr res)
		 (dotimes (i (1- cons-cells))
		   (store-car (tn-ref-tn things) ptr)
		   (setf things (tn-ref-across things))
		   (inst addu ptr ptr (vm:pad-data-block vm:cons-size))
		   (storew ptr ptr
			   (- vm:cons-cdr-slot vm:cons-size)
			   vm:list-pointer-type))
		 (store-car (tn-ref-tn things) ptr)
		 (cond (star
			(setf things (tn-ref-across things))
			(store-car (tn-ref-tn things) ptr vm:cons-cdr-slot))
		       (t
			(storew null-tn ptr
				vm:cons-cdr-slot vm:list-pointer-type)))
		 (assert (null (tn-ref-across things)))
		 (move result res))))))))

(define-vop (list list-or-list*)
  (:variant nil))

(define-vop (list* list-or-list*)
  (:variant t))
