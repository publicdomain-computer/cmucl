;;; -*- Package: SPARC -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the CMU Common Lisp project at
;;; Carnegie Mellon University, and has been placed in the public domain.
;;; If you want to use this code or any part of CMU Common Lisp, please contact
;;; Scott Fahlman or slisp-group@cs.cmu.edu.
;;;
(ext:file-comment
  "$Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/compiler/sparc/sap.lisp,v 1.5 1992/04/27 20:04:06 wlott Exp $")
;;;
;;; **********************************************************************
;;;
;;; This file contains the SPARC VM definition of SAP operations.
;;;
;;; Written by William Lott.
;;;
(in-package "SPARC")


;;;; Moves and coercions:

;;; Move a tagged SAP to an untagged representation.
;;;
(define-vop (move-to-sap)
  (:args (x :scs (any-reg descriptor-reg)))
  (:results (y :scs (sap-reg)))
  (:note "pointer to SAP coercion")
  (:generator 1
    (loadw y x sap-pointer-slot other-pointer-type)))

;;;
(define-move-vop move-to-sap :move
  (descriptor-reg) (sap-reg))


;;; Move an untagged SAP to a tagged representation.
;;;
(define-vop (move-from-sap)
  (:args (sap :scs (sap-reg) :to :save))
  (:temporary (:scs (non-descriptor-reg)) ndescr)
  (:results (res :scs (descriptor-reg)))
  (:note "SAP to pointer coercion") 
  (:generator 20
    (with-fixed-allocation (res ndescr sap-type sap-size)
      (storew sap res sap-pointer-slot other-pointer-type))))
;;;
(define-move-vop move-from-sap :move
  (sap-reg) (descriptor-reg))


;;; Move untagged sap values.
;;;
(define-vop (sap-move)
  (:args (x :target y
	    :scs (sap-reg)
	    :load-if (not (location= x y))))
  (:results (y :scs (sap-reg)
	       :load-if (not (location= x y))))
  (:note "SAP move")
  (:effects)
  (:affected)
  (:generator 0
    (move y x)))
;;;
(define-move-vop sap-move :move
  (sap-reg) (sap-reg))


;;; Move untagged sap arguments/return-values.
;;;
(define-vop (move-sap-argument)
  (:args (x :target y
	    :scs (sap-reg))
	 (fp :scs (any-reg)
	     :load-if (not (sc-is y sap-reg))))
  (:results (y))
  (:note "SAP argument move")
  (:generator 0
    (sc-case y
      (sap-reg
       (move y x))
      (sap-stack
       (storew x fp (tn-offset y))))))
;;;
(define-move-vop move-sap-argument :move-argument
  (descriptor-reg sap-reg) (sap-reg))


;;; Use standard MOVE-ARGUMENT + coercion to move an untagged sap to a
;;; descriptor passing location.
;;;
(define-move-vop move-argument :move-argument
  (sap-reg) (descriptor-reg))



;;;; SAP-INT and INT-SAP

(define-vop (sap-int)
  (:args (sap :scs (sap-reg) :target int))
  (:arg-types system-area-pointer)
  (:results (int :scs (unsigned-reg)))
  (:result-types unsigned-num)
  (:translate sap-int)
  (:policy :fast-safe)
  (:generator 1
    (move int sap)))

(define-vop (int-sap)
  (:args (int :scs (unsigned-reg) :target sap))
  (:arg-types unsigned-num)
  (:results (sap :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:translate int-sap)
  (:policy :fast-safe)
  (:generator 1
    (move sap int)))



;;;; POINTER+ and POINTER-

(define-vop (pointer+)
  (:translate sap+)
  (:args (ptr :scs (sap-reg))
	 (offset :scs (signed-reg)))
  (:arg-types system-area-pointer signed-num)
  (:results (res :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:policy :fast-safe)
  (:generator 2
    (inst add res ptr offset)))

(define-vop (pointer+-c)
  (:translate sap+)
  (:args (ptr :scs (sap-reg)))
  (:info offset)
  (:arg-types system-area-pointer (:constant (signed-byte 13)))
  (:results (res :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:policy :fast-safe)
  (:generator 1
    (inst add res ptr offset)))

(define-vop (pointer-)
  (:translate sap-)
  (:args (ptr1 :scs (sap-reg))
	 (ptr2 :scs (sap-reg)))
  (:arg-types system-area-pointer system-area-pointer)
  (:policy :fast-safe)
  (:results (res :scs (signed-reg)))
  (:result-types signed-num)
  (:generator 1
    (inst sub res ptr1 ptr2)))



;;;; mumble-SYSTEM-REF and mumble-SYSTEM-SET

(eval-when (compile eval)

(defmacro def-system-ref-and-set
	  (ref-name set-name sc type size &optional signed)
  (let ((ref-name-c (symbolicate ref-name "-C"))
	(set-name-c (symbolicate set-name "-C")))
    `(progn
       (define-vop (,ref-name)
	 (:translate ,ref-name)
	 (:policy :fast-safe)
	 (:args (sap :scs (sap-reg))
		(offset :scs (unsigned-reg)))
	 (:arg-types system-area-pointer unsigned-num)
	 (:results (result :scs (,sc)))
	 (:result-types ,type)
	 (:generator 5
	   (inst ,(ecase size
		    (:byte (if signed 'ldsb 'ldub))
		    (:short (if signed 'ldsh 'lduh))
		    (:long 'ld)
		    (:single 'ldf)
		    (:double 'lddf))
		 result sap offset)))
       (define-vop (,ref-name-c)
	 (:translate ,ref-name)
	 (:policy :fast-safe)
	 (:args (sap :scs (sap-reg)))
	 (:arg-types system-area-pointer (:constant (signed-byte 13)))
	 (:info offset)
	 (:results (result :scs (,sc)))
	 (:result-types ,type)
	 (:generator 4
	   (inst ,(ecase size
		    (:byte (if signed 'ldsb 'ldub))
		    (:short (if signed 'ldsh 'lduh))
		    (:long 'ld)
		    (:single 'ldf)
		    (:double 'lddf))
		 result sap offset)))
       (define-vop (,set-name)
	 (:translate ,set-name)
	 (:policy :fast-safe)
	 (:args (sap :scs (sap-reg))
		(offset :scs (unsigned-reg))
		(value :scs (,sc) :target result))
	 (:arg-types system-area-pointer unsigned-num ,type)
	 (:results (result :scs (,sc)))
	 (:result-types ,type)
	 (:generator 5
	   (inst ,(ecase size
		    (:byte 'stb)
		    (:short 'sth)
		    (:long 'st)
		    (:single 'stf)
		    (:double 'stdf))
		 value sap offset)
	   (unless (location= result value)
	     ,@(case size
		 (:single
		  '((inst fmovs result value)))
		 (:double
		  '((inst fmovs result value)
		    (inst fmovs-odd result value)))
		 (t
		  '((inst move result value)))))))
       (define-vop (,set-name-c)
	 (:translate ,set-name)
	 (:policy :fast-safe)
	 (:args (sap :scs (sap-reg))
		(value :scs (,sc) :target result))
	 (:arg-types system-area-pointer (:constant (signed-byte 13)) ,type)
	 (:info offset)
	 (:results (result :scs (,sc)))
	 (:result-types ,type)
	 (:generator 4
	   (inst ,(ecase size
		    (:byte 'stb)
		    (:short 'sth)
		    (:long 'st)
		    (:single 'stf)
		    (:double 'stdf))
		 value sap offset)
	   (unless (location= result value)
	     ,@(case size
		 (:single
		  '((inst fmovs result value)))
		 (:double
		  '((inst fmovs result value)
		    (inst fmovs-odd result value)))
		 (t
		  '((inst move result value))))))))))

); eval-when (compile eval)

(def-system-ref-and-set sap-ref-8 %set-sap-ref-8
  unsigned-reg positive-fixnum :byte nil)
(def-system-ref-and-set signed-sap-ref-8 %set-signed-sap-ref-8
  signed-reg tagged-num :byte t)
(def-system-ref-and-set sap-ref-16 %set-sap-ref-16
  unsigned-reg positive-fixnum :short nil)
(def-system-ref-and-set signed-sap-ref-16 %set-signed-sap-ref-16
  signed-reg tagged-num :short t)
(def-system-ref-and-set sap-ref-32 %set-sap-ref-32
  unsigned-reg unsigned-num :long nil)
(def-system-ref-and-set signed-sap-ref-32 %set-signed-sap-ref-32
  signed-reg signed-num :long t)
(def-system-ref-and-set sap-ref-sap %set-sap-ref-sap
  sap-reg system-area-pointer :long)
(def-system-ref-and-set sap-ref-single %set-sap-ref-single
  single-reg single-float :single)
(def-system-ref-and-set sap-ref-double %set-sap-ref-double
  double-reg double-float :double)



;;; Noise to convert normal lisp data objects into SAPs.

(define-vop (vector-sap)
  (:translate vector-sap)
  (:policy :fast-safe)
  (:args (vector :scs (descriptor-reg)))
  (:results (sap :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:generator 2
    (inst add sap vector
	  (- (* vector-data-offset word-bytes) other-pointer-type))))

