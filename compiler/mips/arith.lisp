;;; -*- Package: C; Log: C.Log -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the Spice Lisp project at
;;; Carnegie-Mellon University, and has been placed in the public domain.
;;; If you want to use this code or any part of Spice Lisp, please contact
;;; Scott Fahlman (FAHLMAN@CMUC). 
;;; **********************************************************************
;;;
;;; $Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/compiler/mips/arith.lisp,v 1.12 1990/04/24 02:55:38 wlott Exp $
;;;
;;;    This file contains the VM definition arithmetic VOPs for the MIPS.
;;;
;;; Written by Rob MacLachlan
;;;
;;; Converted by William Lott.
;;; 

(in-package "C")



;;;; Unary operations.

(define-vop (fixnum-unop)
  (:args (x :scs (any-reg descriptor-reg)))
  (:results (res :scs (any-reg descriptor-reg)))
  (:note "inline fixnum arithmetic")
  (:arg-types fixnum)
  (:result-types fixnum)
  (:policy :fast-safe))

(define-vop (fast-negate/fixnum fixnum-unop)
  (:translate %negate)
  (:generator 1
    (inst subu res zero-tn x)))

(define-vop (fast-lognot/fixnum fixnum-unop)
  (:temporary (:scs (any-reg) :type fixnum :to (:result 0))
	      temp)
  (:translate lognot)
  (:generator 1
    (inst li temp (fixnum -1))
    (inst xor res x temp)))



;;;; Binary operations.

;;; Assume that any constant operand is the second arg...

(define-vop (fast-binop)
  (:args (x :target r
	    :scs (any-reg descriptor-reg))
	 (y :target r
	    :scs (any-reg descriptor-reg)))
  (:arg-types fixnum fixnum)
  (:results (r :scs (any-reg descriptor-reg)))
  (:effects)
  (:affected)
  (:policy :fast-safe))

(defmacro define-fixnum-binop (name translate cost result-type op
				    &optional unsigned)
  `(define-vop (,name fast-binop)
     (:args (x :target r
	       :scs (any-reg descriptor-reg))
	    (y :target r
	       :scs (any-reg descriptor-reg immediate zero
			     ,(if unsigned
				  'unsigned-immediate
				  'negative-immediate))))
     (:translate ,translate)
     (:result-types ,result-type)
     (:note ,(if (eq result-type '*) "inline fixnum arithmetic"))
     (:generator ,cost
       (sc-case y
	 ((any-reg descriptor-reg)
	  (inst ,op r x y))
	 (zero
	  (inst ,op r x zero-tn))
	 ((immediate
	   ,(if unsigned 'unsigned-immediate 'negative-immediate))
	  (inst ,op r x
		(fixnum (tn-value y))))))))

;;; Plus and minus.

(define-fixnum-binop fast-+/fixnum=>fixnum + 1 fixnum addu)
(define-fixnum-binop fast-+/fixnum + 2 * add)

(define-fixnum-binop fast--/fixnum=>fixnum - 1 fixnum subu)
(define-fixnum-binop fast--/fixnum - 2 * sub)


;;; Logical operatons.

(define-fixnum-binop fast-logior/fixnum logior 1 * or t)
(define-fixnum-binop fast-logand/fixnum logand 1 * and t)
(define-fixnum-binop fast-logxor/fixnum logxor 1 * xor t)


;;; Shifting

(define-vop (fast-ash/fixnum=>fixnum)
  (:note "inline fixnum arithmetic")
  (:args (number :scs (any-reg descriptor-reg) :target num)
	 (amount :scs (any-reg descriptor-reg immediate negative-immediate zero)
		 :target ndesc))
  (:arg-types fixnum fixnum)
  (:results (result :scs (any-reg descriptor-reg)))
  (:result-types fixnum)
  (:translate ash)
  (:policy :fast-safe)
  (:temporary (:scs (any-reg) :type fixnum :from (:argument 0))
	      num)
  (:temporary (:scs (non-descriptor-reg) :type random :from (:argument 1))
	      ndesc foo)
  (:generator 3
    (sc-case amount
      ((any-reg descriptor-reg)
       (let ((negative (gen-label))
	     (very-negative (gen-label))
	     (done (gen-label)))
	 (move num number)
	 (inst bltz amount negative)
	 (inst sra ndesc amount 2)

	 ;; The fixnum result-type assures us that this shift will not overflow.
	 (inst sll result num ndesc)
	 (emit-label done)

	 (assemble (*elsewhere*)
	   (emit-label negative)
	   (inst nor ndesc ndesc ndesc)
	   (inst addu ndesc ndesc 3)
	   (inst and foo ndesc #x1f)
	   (inst beq foo ndesc very-negative)
	   
	   (inst sra ndesc num ndesc)
	   (inst b done)
	   (inst sll result ndesc 2)
	   
	   (emit-label very-negative)
	   (inst sra ndesc num 31)
	   (inst b done)
	   (inst sll result ndesc 2))))
      (immediate
       (inst sll result number (tn-value amount)))
      (negative-immediate
       (inst sra ndesc number (min 31 (+ 2 (abs (tn-value amount)))))
       (inst sll result ndesc 2))
      (zero
       ;; Someone should have optimized this away.
       (move result number)))))



;;; Multiply and Divide.

(define-vop (fast-*/fixnum=>fixnum fast-binop)
  (:temporary (:scs (non-descriptor-reg) :type random) temp)
  (:result-types fixnum)
  (:translate *)
  (:generator 4
    (inst sra temp y 2)
    (inst mult x temp)
    (inst mflo r)))

(define-vop (fast-*/fixnum fast-binop)
  (:temporary (:scs (non-descriptor-reg) :type random) temp)
  (:translate *)
  (:generator 4
    (let ((fixnum (gen-label)))
      (inst sra temp y 2)
      (inst mult x temp)
      (inst mfhi temp)
      (inst beq temp zero-tn fixnum)
      (inst mflo r)
      ;; ### Need to make a bignum out of the high and low regs.

      (emit-label fixnum))))

(define-vop (fast-truncate/fixnum fast-binop)
  (:translate truncate)
  (:temporary (:scs (non-descriptor-reg) :type random) t1 t2)
  (:results (q :scs (any-reg descriptor-reg))
	    (r :scs (any-reg descriptor-reg)))
  (:generator 5
    (let ((zero (generate-error-code di:division-by-zero-error x y)))
      (inst beq y zero-tn zero))
    (inst sra t1 x 2)
    (inst sra t2 y 2)
    (inst div t1 t2)
    (inst mflo t1)
    (inst sll q t1 2)
    (inst mfhi t1)
    (inst sll r t1 2)))

(define-vop (fast-rem/fixnum fast-binop)
  (:temporary (:scs (non-descriptor-reg) :type random) t1 t2)
  (:translate rem)
  (:generator 4
    (let ((zero (generate-error-code di:division-by-zero-error x y)))
      (inst beq y zero-tn zero))
    (inst sra t1 x 2)
    (inst sra t2 y 2)
    (inst div t1 t2)
    (inst mfhi t1)
    (inst sll r t1 2)))




;;;; Binary conditional VOPs:

(define-vop (fast-conditional/fixnum)
  (:args (x :scs (any-reg descriptor-reg))
	 (y :scs (any-reg descriptor-reg negative-immediate immediate zero)))
  (:arg-types fixnum fixnum)
  (:conditional)
  (:info target not-p)
  (:effects)
  (:affected)
  (:policy :fast-safe)
  (:note "inline fixnum comparison"))


(define-vop (fast-if-</fixnum fast-conditional/fixnum)
  (:temporary (:type fixnum :scs (any-reg) :from (:argument 0)) temp)
  (:translate <)
  (:generator 3
    (sc-case y
      (zero
       (if not-p
	   (inst bgez x target)
	   (inst bltz x target)))
      ((negative-immediate immediate)
       (inst slt temp x (fixnum (tn-value y)))
       (if not-p
	   (inst beq temp zero-tn target)
	   (inst bne temp zero-tn target)))
      ((any-reg descriptor-reg)
       (inst slt temp x y)
       (if not-p
	   (inst beq temp zero-tn target)
	   (inst bne temp zero-tn target))))
    (inst nop)))

(define-vop (fast-if->/fixnum fast-conditional/fixnum)
  (:temporary (:type fixnum :scs (any-reg) :from (:argument 0)) temp)
  (:translate >)
  (:generator 3
    (sc-case y
      (zero
       (if not-p
	   (inst blez x target)
	   (inst bgtz x target)))
      ((negative-immediate immediate)
       (inst slt temp x (fixnum (1+ (tn-value y))))
       (if not-p
	   (inst bne temp zero-tn target)
	   (inst beq temp zero-tn target)))
      ((any-reg descriptor-reg)
       (inst slt temp y x)
       (if not-p
	   (inst beq temp zero-tn target)
	   (inst bne temp zero-tn target))))
    (inst nop)))

(define-vop (fast-if-=/fixnum fast-conditional/fixnum)
  (:args (x :scs (any-reg descriptor-reg))
	 (y :scs (any-reg descriptor-reg zero)))
  (:translate =)
  (:generator 2
    (let ((foo (sc-case y
		 (zero zero-tn)
		 ((any-reg descriptor-reg) y))))
      (if not-p
	  (inst bne x foo target)
	  (inst beq x foo target)))
    (inst nop)))




;;;; Static functions.

(define-static-function two-arg-+ (x y) :translate +)
(define-static-function two-arg-- (x y) :translate -)
(define-static-function two-arg-* (x y) :translate *)
(define-static-function two-arg-/ (x y) :translate /)

(define-static-function two-arg-< (x y) :translate <)
(define-static-function two-arg-<= (x y) :translate <=)
(define-static-function two-arg-> (x y) :translate >)
(define-static-function two-arg->= (x y) :translate >=)
(define-static-function two-arg-= (x y) :translate =)
(define-static-function two-arg-/= (x y) :translate /=)

(define-static-function %negate (x) :translate %negate)

(define-static-function two-arg-and (x y) :translate logand)
(define-static-function two-arg-ior (x y) :translate logior)
(define-static-function two-arg-xor (x y) :translate logxor)

