;;; -*- Package: C; Log: C.Log -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the Spice Lisp project at
;;; Carnegie-Mellon University, and has been placed in the public domain.
;;; If you want to use this code or any part of Spice Lisp, please contact
;;; Scott Fahlman (FAHLMAN@CMUC). 
;;; **********************************************************************
;;;
;;;    This file contains the virtual machine independent parts of the code
;;; which does the actual translation of nodes to VOPs.
;;;
;;; Written by Rob MacLachlan
;;;
(in-package 'c)


;;;; Random utilities:


;;; Block-Label  --  Interface
;;;
;;;    Return the label marking the start of Block, assigning one if necessary.
;;;
(defun block-label (block)
  (declare (type cblock block))
  (let ((2block (block-info block)))
    (or (ir2-block-%label 2block)
	(setf (ir2-block-%label 2block) (gen-label)))))


;;; Drop-Thru-P  --  Interface
;;;
;;;    Return true if Block is emitted immediately after the block ended by
;;; Node.
;;;
(defun drop-thru-p (node block)
  (declare (type node node) (type cblock block))
  (let ((next-block (ir2-block-next (block-info (node-block node)))))
    (assert (eq node (block-last (node-block node))))
    (eq next-block (block-info block))))


;;; Flush-Tail-Transfer  --  Interface
;;;
;;;    Annotate Node and Block to indicate that the Node is being
;;; compiled in a way that exploits its tail-recursive position: Block ends
;;; with a return or TR call, and will never transfer to the block containing
;;; the return node.
;;;
;;;    For now, we just flush the link between the IR1 blocks, but we might
;;; want to do something else someday.  If the return is is the same block as
;;; Node, then we don't do any anything.  This works, since this can only
;;; happen when there node is the sole use of the return continuation.  Since
;;; Node is TR, LTN will annotate Cont as :Unused, and no return code will be
;;; emitted.
;;;
(defun flush-tail-transfer (node block)
  (declare (type node node) (type ir2-block block) (ignore block))
  (let* ((cont (node-cont node))
	 (ret (continuation-dest cont))
	 (b1 (node-block node))
	 (b2 (node-block ret)))
    (assert (return-p ret))
    (if (eq b1 b2)
	(assert (eq (ir2-continuation-kind (continuation-info cont)) :unused))
	(unlink-blocks b1 b2)))
  (undefined-value))


;;; Insert-VOP-Sequence  --  Interface
;;;
;;;    Link a list of VOPs from First to Last into Block, Before the specified
;;; VOP.  If Before is NIL, insert at the end.
;;;
(defun insert-vop-sequence (first last block before)
  (declare (type vop first last) (type ir2-block block)
	   (type (or vop null) before))
  (if before
      (let ((prev (vop-prev before)))
	(setf (vop-prev first) prev)
	(if prev
	    (setf (vop-next prev) first)
	    (setf (ir2-block-start-vop block) first))
	(setf (vop-next last) before)
	(setf (vop-prev before) last))
      (let ((current (ir2-block-last-vop block)))
	(setf (vop-prev first) current)
	(setf (ir2-block-last-vop block) last)
	(if current
	    (setf (vop-next current) first)
	    (setf (ir2-block-start-vop block) first))))
  (undefined-value))


;;;; Moves and type checks:

;;; Emit-Move-Template  --  Internal
;;;
;;;    Emit a move-like template determined at run-time, with X as the argument
;;; and Y as the result.  If Template is null, then just use the Move VOP.
;;; Useful for move, coerce and type-check templates.  If supplied, then insert
;;; before VOP, otherwise insert at then end of the block.
;;;
(defun emit-move-template (node block template x y &optional before)
  (declare (type node node) (type ir2-block block)
	   (type (or template null) template) (type tn x y))
  (let ((template (or template (template-or-lose 'move)))
	(arg (reference-tn x nil))
	(result (reference-tn y t)))
    (multiple-value-bind
	(first last)
	(funcall (template-emit-function template) node block template arg
		 result)
      (insert-vop-sequence first last block before)))
  (undefined-value))


;;; Emit-Move  --  Internal
;;;
;;;    Move X to Y, emitting the appropriate move/coerce VOP.  If the primitive
;;; types don't overlap, there there must be a type error.  In this case, we
;;; coerce the source object to T, emit an error call, then emit ILLEGAL-MOVE
;;; to make properly start the destination's lifetime.
;;;
(defun emit-move (node block x y)
  (declare (type node node) (type ir2-block block) (type tn x y))
  (let ((x-type (tn-primitive-type x))
	(y-type (tn-primitive-type y)))
    (cond ((eq x-type y-type)
	   (emit-move-template node block (primitive-type-move x-type) x y))
	  ((eq y-type *any-primitive-type*)
	   (emit-move-template node block (primitive-type-coerce-to-t x-type)
			       x y))
	  ((eq x-type *any-primitive-type*)
	   (emit-move-template node block (primitive-type-coerce-from-t y-type)
			       x y))
	  (t
	   (let* ((c-to-t (primitive-type-coerce-to-t x-type))
		  (src (if c-to-t
			   (make-normal-tn *any-primitive-type*)
			   x))
		  (err (emit-constant clc::error-object-not-type))
		  (y-type (emit-constant
			   (type-specifier
			    (primitive-type-type
			     (tn-primitive-type y))))))
	     (when c-to-t
	       (emit-move-template node block c-to-t x src))
	     (vop error2 node block err src y-type)
	     (vop illegal-move node block y))))))

  (undefined-value))


;;; Maybe-Coerce  --  Internal
;;;
;;;    If TN is of the specified type, or doesn't require a coercion to be of
;;; that type, then return TN, otherwise convert the value into a temporary and
;;; return the temporary.
;;;
(defun maybe-coerce (node block tn ptype)
  (declare (type node node) (type ir2-block block)
	   (type tn tn) (type primitive-type ptype))
  (let ((tn-ptype (tn-primitive-type tn)))
    (if (or (eq tn-ptype ptype)
	    (not (or (primitive-type-coerce-to-t tn-ptype)
		     (primitive-type-coerce-from-t ptype))))
	tn
	(let ((temp (make-normal-tn ptype)))
	  (emit-move node block tn temp)
	  temp))))


;;; Get-Result-TN  --  Internal
;;;
;;;    Used together with Move-Result to handle any coercion necessary to
;;; compute a value of the primitive-type PType in TN.  This is called before
;;; computation of the result to get a TN to compute the result in.  If a
;;; coercion is necessary, then we create a temporary and return it, otherwise
;;; we return TN.
;;;
(defun get-result-tn (tn ptype)
  (declare (type tn tn) (type primitive-type ptype))
    (if (ok-result-tn tn ptype)
	tn
	(make-normal-tn ptype)))


;;; OK-Result-TN  --  Internal
;;;
;;;    Return true if TN is an ok location to compute a result of the specified
;;; primitive type in, i.e. no implicit coercion is needed.  This is true when
;;; either the primitive types are the same or when no coercion is needed
;;; to/from T.
;;;
(defun ok-result-tn (tn ptype)
  (declare (type tn tn) (type primitive-type ptype))
  (let ((tn-ptype (tn-primitive-type tn)))
    (cond ((eq tn-ptype ptype))
	  ((eq tn-ptype *any-primitive-type*)
	   (not (primitive-type-coerce-to-t ptype)))
	  (t
	   (assert (eq ptype *any-primitive-type*))
	   (not (primitive-type-coerce-from-t tn-ptype))))))


;;; Move-Result  --  Internal
;;;
;;;    Used with Get-Result-TN to handle result type coercions.  This is called
;;; after the result is actually computed in order actually do the coercion.
;;; If TN isn't EQ to Dest, then have Emit-Move figure out what to do.
;;;
(proclaim '(inline move-result))
(defun move-result (node block tn dest)
  (declare (type node node) (type ir2-block block) (type tn tn dest))
  (unless (eq tn dest)
    (emit-move node block tn dest))
  (undefined-value))


;;; Type-Check-Template  --  Interface
;;;
;;;    If there is any CHECK-xxx template for Type, then return it, otherwise
;;; return NIL.
;;;
(defun type-check-template (type)
  (declare (type ctype type))
  (multiple-value-bind (check-ptype exact)
		       (primitive-type type)
    (if exact
	(primitive-type-check check-ptype)
	(let ((name (hairy-type-check-template type)))
	  (if name
	      (template-or-lose name)
	      nil)))))


;;; Emit-Type-Check  --  Internal
;;;
;;;    Emit code in Block to check that Value is of the specified Type,
;;; yielding the checked result in Result.  Value and result may be of any
;;; primitive type.  There must be CHECK-xxx VOP for Type.  Any other type
;;; checks should have been converted to an explicit type test.
;;;
(defun emit-type-check (node block value result type)
  (declare (type tn value result) (type node node) (type ir2-block block)
	   (type ctype type))
  (let ((check (type-check-template type)))
    (assert check)
    (let ((src (maybe-coerce node block value *any-primitive-type*))
	  (dest (get-result-tn result *any-primitive-type*)))
      (emit-move-template node block check src dest)
      (move-result node block dest result)))
  (undefined-value))


;;; Move-From-Frame, Move-To-Frame  --  Internal
;;;
;;;    Move a value out of or into a different frame.  This is used during
;;; function call/return to move an argument or return value into the
;;; appropriate passing location.
;;;
;;; [### For now, we always use the same VOPs, and passing locations are always
;;; in a descriptor representation.  To allow passing of non-descriptor
;;; arguments or results, we will have to have type-specific argument/value
;;; moving VOPs.]
;;;
(defun move-from-frame (node block src dest frame)
  (declare (type node node) (type ir2-block block) (type tn src dest frame))
  (let* ((dtype (tn-primitive-type dest))
	 (temp (if (primitive-type-coerce-from-t dtype)
		   (make-normal-tn *any-primitive-type*)
		   dest)))
    (vop move-argument node block src frame temp)
    (unless (eq temp dest)
      (emit-move node block temp dest)))
  (undefined-value))
;;;
(defun move-to-frame (node block src dest frame)
  (declare (type node node) (type ir2-block block) (type tn src dest frame))
  (let* ((stype (tn-primitive-type src))
	 (temp (if (primitive-type-coerce-to-t stype)
		   (make-normal-tn *any-primitive-type*)
		   src)))
    (unless (eq src temp)
      (emit-move node block src temp))
    (vop move-value node block temp frame dest))
  (undefined-value))


;;;; Leaf reference:

;;; Find-In-Environment  --  Internal
;;;
;;;    Return the TN that holds the value of Thing in the environment Env.
;;;
(defun find-in-environment (thing env)
  (declare (type (or nlx-info lambda-var) thing) (type environment env))
  (or (cdr (assoc thing (ir2-environment-environment (environment-info env))))
      (etypecase thing
	(lambda-var
	 (assert (eq env (lambda-environment (lambda-var-home thing))))
	 (leaf-info thing))
	(nlx-info
	 (assert (eq env
		     (lambda-environment
		      (block-lambda
		       (continuation-block (nlx-info-continuation thing))))))
	 (ir2-nlx-info-home (nlx-info-info thing))))))


;;; Constant-TN  --  Internal
;;;
;;;    If Leaf already has a constant TN, return that, otherwise make a TN for
;;; it.
;;;
(defun constant-tn (leaf)
  (declare (type constant leaf))
  (or (leaf-info leaf)
      (setf (leaf-info leaf)
	    (make-constant-tn leaf))))

  
;;; Leaf-TN  --  Internal
;;;
;;;    Return a TN that represents the value of Leaf, or NIL if Leaf isn't
;;; directly represented by a TN.  Env is the environment that the reference is
;;; done in.
;;;
(defun leaf-tn (leaf env)
  (declare (type leaf leaf) (type environment env))
  (typecase leaf
    (lambda-var
     (unless (lambda-var-indirect leaf)
       (find-in-environment leaf env)))
    (constant (constant-tn leaf))
    (t nil)))


;;; Emit-Constant  --  Internal
;;;
;;;    Used to conveniently get a handle on a constant TN during IR2
;;; conversion.  Returns a constant TN representing the Lisp object Value.
;;;
(defun emit-constant (value)
  (constant-tn (find-constant value)))


;;; IR2-Convert-Hairy-Function-Ref  --  Internal
;;;
;;;    Handle a function Ref that can't be converted to a symbol access.  We
;;; convert a call to FDEFINITION with Name as the argument.
;;;
(defun ir2-convert-hairy-function-ref (node block name)
  (declare (type ref node) (type ir2-block block) (type tn name))
  (when (policy node (> speed brevity))
    (let ((*compiler-error-context* node))
      (compiler-note "Compiling a full call to FDEFINITION.")))
  (let ((arg (standard-argument-location 0))
	(res (standard-argument-location 0))
	(fun (emit-constant 'fdefinition)))
    (emit-move node block name arg)
    (vop* call-named node block (fun arg nil) (res nil) "<save info>" 1 1)
    (move-continuation-result node block (list res) (node-cont node)))
  (undefined-value))


;;; IR2-Convert-Ref  --  Internal
;;;
;;;    Convert a Ref node.  The reference must not be delayed.
;;;
(defun ir2-convert-ref (node block)
  (declare (type ref node) (type ir2-block block))
  (let* ((cont (node-cont node))
	 (leaf (ref-leaf node))
	 (name (leaf-name leaf))
	 (locs (continuation-result-tns
		cont (list (primitive-type (leaf-type leaf)))))
	 (res (first locs)))
    (etypecase leaf
      (lambda-var
       (let ((tn (find-in-environment leaf (node-environment node))))
	 (if (lambda-var-indirect leaf)
	     (vop value-cell-ref node block tn res)
	     (emit-move node block tn res))))
      (constant
       (emit-move node block (constant-tn leaf) res))
      (functional
       (ir2-convert-closure node block leaf res))
      (global-var
       (let ((name-tn (emit-constant name))
	     (unsafe (policy node (> speed safety))))
	 (ecase (global-var-kind leaf)
	   ((:special :global :constant)
	    (assert (symbolp name))
	    (if unsafe
		(vop fast-symbol-value node block name-tn res)
		(vop symbol-value node block name-tn res)))
	   (:global-function
	    (unless (symbolp name)
	      (ir2-convert-hairy-function-ref node block name-tn)
	      (return-from ir2-convert-ref (undefined-value)))

	    (if unsafe
		(vop fast-symbol-function node block name-tn res)
		(vop symbol-function node block name-tn res)))))))

    (move-continuation-result node block locs cont))
  (undefined-value))


;;; IR2-Convert-Closure  --  Internal
;;;
;;;    Emit code to load a function object representing Leaf into Res.  This
;;; gets interesting when the referenced function is a closure: we must make
;;; the closure and move the closed over values into it.
;;;
;;; Leaf is the XEP lambda for the called function, since local call analysis
;;; converts all closure references.
;;;
(defun ir2-convert-closure (node block leaf res)
  (declare (type ref node) (type ir2-block block)
	   (type clambda leaf) (type tn res))
  (let ((entry (make-load-time-constant-tn :entry leaf))
	(this-env (node-environment node))
	(leaf-closure (environment-closure (lambda-environment leaf))))
    (cond (leaf-closure
	   (vop make-closure node block (emit-constant (length leaf-closure))
		entry res)
	   (let ((n (1- system:%function-closure-variables-offset)))
	     (dolist (what leaf-closure)
	       (vop closure-init node block
		    res (find-in-environment what this-env)
		    (incf n)))))
	  (t
	   (emit-move node block entry res))))
  (undefined-value))


;;; IR2-Convert-Set  --  Internal
;;;
;;;    Convert a Set node.  If the node's cont is annotated, then we also
;;; deliver the value to that continuation.  If the var is a lexical variable
;;; with no refs, then we don't actually set anything, since the variable has
;;; been deleted.
;;;
(defun ir2-convert-set (node block)
  (declare (type cset node) (type ir2-block block))
  (let* ((cont (node-cont node))
	 (leaf (set-var node))
	 (val (continuation-tn node block (set-value node)))
	 (locs (if (continuation-info cont)
		   (continuation-result-tns
		    cont (list (primitive-type (leaf-type leaf))))
		   nil)))
    (etypecase leaf
      (lambda-var
       (when (leaf-refs leaf)
	 (let ((tn (find-in-environment leaf (node-environment node))))
	   (if (lambda-var-indirect leaf)
	       (vop value-cell-set node block tn val)
	       (emit-move node block val tn)))))
      (global-var
       (ecase (global-var-kind leaf)
	 ((:special :global)
	  (assert (symbolp (leaf-name leaf)))
	  (vop set node block (emit-constant (leaf-name leaf)) val
	       (make-normal-tn *any-primitive-type*))))))

    (when locs
      (emit-move node block val (first locs))
      (move-continuation-result node block locs cont)))
  (undefined-value))


;;;; Utilities for receiving single values:

;;; Continuation-TN  --  Internal
;;;
;;;    Return a TN that can be referenced to get the value of Cont.  Cont must
;;; be LTN-Annotated either as a delayed leaf ref or as a fixed, single-value
;;; continuation.
;;;
(defun continuation-tn (node block cont)
  (declare (type node node) (type ir2-block block) (type continuation cont))
  (let ((2cont (continuation-info cont)))
    (ecase (ir2-continuation-kind 2cont)
      (:delayed
       (let* ((ref (continuation-use cont))
	      (tn (leaf-tn (ref-leaf ref) (node-environment ref)))
	      (ptype (ir2-continuation-primitive-type 2cont)))
	 (assert tn)
	 (if (eq (continuation-type-check cont) t)
	     (let ((temp (make-normal-tn ptype)))
	       (emit-type-check node block tn temp
				(continuation-asserted-type cont))
	       temp)
	     (maybe-coerce node block tn ptype))))
      (:fixed
       (assert (= (length (ir2-continuation-locs 2cont)) 1))
       (first (ir2-continuation-locs 2cont))))))


;;; Reference-Arguments  --  Internal
;;;
;;;    Build a TN-Refs list that represents access to the values of the
;;; specified list of continuations Args.  Node and Block provide the context
;;; for emitting any necessary coercion or type-checking code.
;;;
(defun reference-arguments (node block args)
  (declare (type node node) (type ir2-block block) (list args))
  (let ((last nil)
	(first nil))
    (dolist (arg args)
      (let ((ref (reference-tn (continuation-tn node block arg)
			       nil)))
	(if last
	    (setf (tn-ref-across last) ref)
	    (setf first ref))
	(setq last ref)))
    (the (or tn-ref null) first)))


;;;; Utilities for delivering values to continuations:

;;; Continuation-Result-TNs  --  Internal
;;;
;;;    Return a list of TNs that can be used as result TNs to evaluate an
;;; expression with fixed result types specified by RTypes into the
;;; continuation Cont.  This is used together with Move-Continuation-Result to
;;; deliver a fixed values of to a continuation.
;;;
;;;    If the continuation isn't annotated (meaning the values are discarded),
;;; or wants a type check, then we make temporaries for each supplied value.
;;; This provides a place to compute the result until we figure out what (if
;;; anything) to do with it.
;;;
;;;    If the continuation is fixed-values, wants the same number of values as
;;; the user wants to deliver, and requires no implicit coercion, then we just
;;; return the IR2-Continuation-Locs.  If coercions are required, then we make
;;; any necessary temporaries and return them.
;;;
;;;    If the continuation is unknown-values, then we make a boxed TN to
;;; compute each desired result in.
;;;
;;;    If the continuation is :Unused (a tail-recursive result), then we look
;;; at the return-info for the function being returned from.  If the return
;;; convention is fixed, then we make result temporaries as specified by
;;; rtypes, otherwise we make the same number of boxed temporaries.
;;;
(defun continuation-result-tns (cont rtypes)
  (declare (type continuation cont) (list rtypes))
  (let ((2cont (continuation-info cont)))
    (if (or (not 2cont) (eq (continuation-type-check cont) t))
	(mapcar #'make-normal-tn rtypes)
	(ecase (ir2-continuation-kind 2cont)
	  (:fixed
	   (let ((locs (ir2-continuation-locs 2cont)))
	     (if (and (= (length locs) (length rtypes))
		      (every #'ok-result-tn locs rtypes))
		 locs
		 (collect ((res))
		   (do ((loc locs (cdr loc))
			(rtype rtypes (cdr rtype)))
		       ((null rtype))
		     (if loc
			 (res (get-result-tn (car loc) (car rtype)))
			 (res (make-normal-tn (car rtype)))))
		   (res)))))
	  ((:unknown :unused)
	   (mapcar #'make-normal-tn rtypes))))))

#|
	  (:unknown
	   (make-n-tns (length rtypes) *any-primitive-type*))
	  (:unused
	   (let ((returns (tail-set-info
			   (lambda-tail-set
			    (return-lambda
			     (continuation-dest cont))))))
	     (if (eq (return-info-kind returns) :fixed)
		 (mapcar #'make-normal-tn rtypes)
		 (make-n-tns (length rtypes) *any-primitive-type*))))
|#

;;; Make-Standard-Value-Tns  --  Internal
;;;
;;;    Make the first N standard value TNs, returning them in a list.
;;;
(defun make-standard-value-tns (n)
  (declare (type unsigned-byte n))
  (collect ((res))
    (dotimes (i n)
      (res (standard-argument-location i)))
    (res)))


;;; Standard-Result-TNs  --  Internal
;;;
;;;    Return a list of TNs wired to the standard value passing conventions
;;; that can be used to receive values according to the unknown-values
;;; convention.  This is used with together Move-Continuation-Result for
;;; delivering unknown values to a fixed values continuation.
;;;
;;;    If the continuation isn't annotated, then we treat as 0-values,
;;; returning an empty list of temporaries.
;;;
;;;    If the continuation is annotated, then it must either be :Fixed or be
;;; :Unused with the Return-Info-Kind being :Fixed.
;;;
(defun standard-result-tns (cont)
  (declare (type continuation cont))
  (let ((2cont (continuation-info cont)))
    (if 2cont
	(ecase (ir2-continuation-kind 2cont)
	  (:fixed
	   (make-standard-value-tns (length (ir2-continuation-locs 2cont))))
	  (:unused
	   (let ((returns (tail-set-info
			   (lambda-tail-set
			    (return-lambda
			     (continuation-dest cont))))))
	     (assert (eq (return-info-kind returns) :fixed))
	     (make-standard-value-tns
	      (length (return-info-types returns))))))
	())))


;;; Move-Results-Checked  --  Internal
;;;
;;;    Move the values in the list of TNs Src to the list of TNs Dest, checking
;;; that the types of the values match the Asserted-Type in Cont.  What we do
;;; is look at the number of values supplied, desired and asserted, padding out
;;; shorter lists appropriately.
;;;
;;;    Missing supplied values are defaulted to NIL.  Undesired supplied values
;;; are just checked against the asserted type.  If more values are computed
;;; than the type assertion expects, then we don't check these values.  We
;;; ignore assertions on values neither supplied nor received.  So if there is
;;; an assertion for an unsupplied value, it will be checked against NIL.  This
;;; will cause a wrong-type error (if any) rather than a wrong number of values
;;; error.  This is consistent with our general policy of not checking values
;;; count.
;;;
(defun move-results-checked (node block src dest cont)
  (declare (type node node) (type ir2-block block)
	   (list src dest) (type ctype type))
  (multiple-value-bind (check types)
		       (continuation-check-types cont)
    (assert (eq check :simple))
    (let* ((count (length types))
	   (nsrc (length src))
	   (ndest (length dest))
	   (nmax (max ndest nsrc)))
      (mapc #'(lambda (from to assertion)
		(if assertion
		    (emit-type-check node block from to assertion)
		    (emit-move node block from to)))
	    (if (> ndest nsrc)
		(append src (make-list (- ndest nsrc)
				       :initial-element (emit-constant nil)))
		src)
	    (if (< ndest nsrc)
		(append dest (nthcdr ndest src))
		dest)
	    (if (< count nmax)
		(append types (make-list (- nmax count) :initial-element nil))
		types))))
  (undefined-value))


;;; Move-Results-Coerced  --  Internal
;;;
;;;    Just move each Src TN into the corresponding Dest TN, defaulting any
;;; unsupplied source values to NIL.  We let Emit-Move worry about doing the
;;; appropriate coercions.
;;;
(defun move-results-coerced (node block src dest)
  (declare (type node node) (type ir2-block block) (list src dest))
  (let ((nsrc (length src))
	(ndest (length dest)))
    (mapc #'(lambda (from to)
	      (unless (eq from to)
		(emit-move node block from to)))
	  (if (> ndest nsrc)
	      (append src (make-list (- ndest nsrc)
				     :initial-element (emit-constant nil)))
	      src)
	  dest))
  (undefined-value))


;;; Move-Continuation-Result  --  Internal
;;;
;;;    If necessary, emit type-checking/coercion code needed to deliver the
;;; Results to the specified continuation.  Node and block provide context for
;;; emitting code.  Although usually obtained from Standard-Result-TNs or
;;; Continuation-Result-TNs, Results my be a list of any type or number of TNs.
;;;
;;;    If the continuation is fixed values, then move the results into the
;;; continuation locations, doing type checks and defaulting unsupplied values.
;;;
;;;    If the continuation is unknown values, then do the moves/checks into the
;;; standard value locations, and use Push-Values to put the values on the
;;; stack.
;;;
;;;    If the continuation is :Unused, then this use is tail-recursive.  We
;;; emit code that returns the values out of the current function.  Type
;;; checking is done in-place in the Results, since we don't know where
;;; Emit-Return-For-Locs is going to want to pass the values.  In this case, we
;;; also flush the control transfer to the tail return.
;;;
(defun move-continuation-result (node block results cont)
  (declare (type node node) (type ir2-block block)
	   (list results) (type continuation cont))
  (let* ((2cont (continuation-info cont))
	 (check (eq (continuation-type-check cont) t)))
    (when 2cont
      (ecase (ir2-continuation-kind 2cont)
	(:fixed
	 (let ((locs (ir2-continuation-locs 2cont)))
	   (cond ((eq locs results))
		 (check
		  (move-results-checked node block results locs cont))
		 (t
		  (move-results-coerced node block results locs)))))
	(:unknown
	 (let* ((nvals (length results))
		(locs (make-standard-value-tns nvals)))
	   (if check
	       (move-results-checked node block results locs cont)
	       (move-results-coerced node block results locs))
	   (vop* push-values node block
		 ((reference-tn-list locs nil))
		 ((reference-tn-list (ir2-continuation-locs 2cont) t))
		 nvals)))
	(:unused
	 (when check
	   (move-results-checked node block results results cont))
	 (emit-return-for-locs (continuation-dest cont) block :fixed results)
	 (flush-tail-transfer node block)))))
  (undefined-value))


;;;; Template conversion:


;;; IR2-Convert-Conditional  --  Internal
;;;
;;;    Convert a conditional template.  We try to exploit any drop-through, but
;;; emit an unconditional branch afterward if we fail.  Not-P is true if the
;;; sense of the Template's test should be negated.
;;;
(defun ir2-convert-conditional (node block template args if not-p)
  (declare (type node node) (type ir2-block block)
	   (type template template) (type (or tn-ref null) args)
	   (type cif if) (type boolean not-p))
  (assert (= (template-info-arg-count template) 2))
  (let ((consequent (if-consequent if))
	(alternative (if-alternative if)))
    (cond ((drop-thru-p if consequent)
	   (emit-template node block template args nil
			  (list (block-label alternative) (not not-p))))
	  (t
	   (emit-template node block template args nil
			  (list (block-label consequent) not-p))
	   (unless (drop-thru-p if alternative)
	     (vop branch node block (block-label alternative)))))))


;;; IR2-Convert-IF  --  Internal
;;;
;;;    Convert an IF that isn't the DEST of a conditional template.
;;;
(defun ir2-convert-if (node block)
  (declare (type (ir2-block block)) (type cif node))
  (let* ((test (if-test node))
	 (test-ref (reference-tn (continuation-tn node block test) nil))
	 (nil-ref (reference-tn (emit-constant nil) nil)))
    (setf (tn-ref-across test-ref) nil-ref)
    (ir2-convert-conditional node block (template-or-lose 'if-eq)
			     test-ref node t)))


;;; IR2-Convert-Template  --  Internal
;;;
;;;    Get the operands into TNs, make TN-Refs for them, and then call the
;;; template emit function. 
;;;
(defun ir2-convert-template (call block)
  (declare (type combination call) (type ir2-block block))
  (let* ((template (combination-info call))
	 (cont (node-cont call))
	 (args (reference-arguments call block (combination-args call)))
	 (rtypes (template-result-types template)))
    (assert (not (template-more-results-type template)))
    (if (eq rtypes :conditional)
	(ir2-convert-conditional call block template args
				 (continuation-dest cont) nil)
	(let ((results (continuation-result-tns cont rtypes)))
	  (assert (zerop (template-info-arg-count template)))
	  (emit-template call block template args
			 (reference-tn-list results t))
	  (move-continuation-result call block results cont))))
  (undefined-value))


;;; %%Primitive IR2 Convert  --  Internal
;;;
;;;    We don't have to do much because operand count checking is done by IR1
;;; conversion.  The only difference between this and the function case of
;;; IR2-Convert-Template is that there can be codegen-info arguments.
;;;
(defoptimizer (%%primitive ir2-convert) ((template info &rest args) call block)
  (let* ((template (continuation-value template))
	 (info (continuation-value info))
	 (cont (node-cont call))
	 (args (reference-arguments call block (cddr (combination-args call))))
	 (rtypes (template-result-types template))
	 (results (continuation-result-tns cont rtypes))
	 (r-refs (reference-tn-list results t)))
    (assert (not (template-more-results-type template)))
    (assert (not (eq rtypes :conditional)))

    (if info
	(emit-template call block template args r-refs info)
	(emit-template call block template args r-refs))

    (move-continuation-result call block results cont))
  (undefined-value))


;;;; Local call:

;;; IR2-Convert-Let  --  Internal
;;;
;;;    Convert a let by moving the argument values into the variables.  Since a
;;; a let doesn't have any passing locations, we move the arguments directly
;;; into the variables.  We must also allocate any indirect value cells, since
;;; there is no function prologue to do this.
;;;
(defun ir2-convert-let (node block fun)
  (declare (type combination node) (type ir2-block block) (type clambda fun))
  (mapc #'(lambda (var arg)
	    (when arg
	      (let ((src (continuation-tn node block arg))
		    (dest (leaf-info var)))
		(if (lambda-var-indirect var)
		    (vop make-value-cell node block src dest)
		    (emit-move node block src dest)))))
	(lambda-vars fun) (basic-combination-args node))
  (undefined-value))


;;; Move-Local-Call-Args  --  Internal
;;;
;;;    Set up the arguments for a local call.  This involves moving the actual
;;; arguments into the passing locations (doing any type checking) and
;;; computing the environment arguments for the called function.
;;;
(defun move-local-call-args (node block fun)
  (declare (type combination node) (type ir2-block block) (type clambda fun))
  (let* ((called-env (environment-info (lambda-environment fun)))
	 (arg-locs (ir2-environment-arg-locs called-env))
	 (1env (node-environment node)))
    (dolist (arg (basic-combination-args node))
      (when arg
	(emit-move node block (continuation-tn node block arg)
		   (pop arg-locs))))
    
    (dolist (thing (ir2-environment-environment called-env))
      (emit-move node block (find-in-environment (car thing) 1env)
		 (pop arg-locs))))

  (undefined-value))


;;; IR2-Convert-Tail-Local-Call   --  Internal
;;;
;;;    A tail-recursive local call is done by emitting moves of stuff into the
;;; appropriate passing locations.  After setting up the args and environment,
;;; we just move our return-pc and old-cont into the called function's passing
;;; locations.  The Current-Cont VOP is used to set the arg pointer to point
;;; to the current frame.
;;;
;;;    The Tail-Call-Local VOP's only purpose is to get the argument lifetimes
;;; right.  We flush the tail control transfer for similar reasons.
;;;
(defun ir2-convert-tail-local-call (node block fun)
  (declare (type combination node) (type ir2-block block) (type clambda fun))
  (move-local-call-args node block fun)
    
  (let* ((this-env (environment-info (node-environment node)))
	 (call-env (environment-info (lambda-environment fun)))
	 (old-cont (ir2-environment-old-cont-pass call-env))
	 (return-pc (ir2-environment-return-pc-pass call-env))
	 (args (ir2-environment-argument-pointer call-env))
	 (target (node-block (lambda-bind fun))))

    (emit-move node block (ir2-environment-old-cont this-env) old-cont)
    (emit-move node block (ir2-environment-return-pc this-env) return-pc)
    (vop current-cont node block args)

    (vop* tail-call-local node block
	  (old-cont return-pc args
		    (reference-tn-list (ir2-environment-arg-locs call-env)
				       nil))
	  (nil)
	  (unless (drop-thru-p (block-last (node-block node)) target)
	    (block-label target))))

  (flush-tail-transfer node block)

  (undefined-value))


;;; IR2-Convert-Local-Known-Call  --  Internal
;;;
;;;    Handle a non-TR known-values local call.  We Emit the call, then move
;;; the results to the continuation's destination.
;;;
(defun ir2-convert-local-known-call (node block env returns cont start)
  (declare (type node node) (type ir2-block block) (type ir2-environment env)
	   (type return-info returns) (type continuation cont)
	   (type label start))
  (let* ((locs (return-info-locations returns))
	 (temps (continuation-result-tns
		 cont (mapcar #'tn-primitive-type locs))))
    (vop* known-call-local node block
	  ((ir2-environment-old-cont-pass env)
	   (ir2-environment-argument-pointer env)
	   (reference-tn-list (ir2-environment-arg-locs env) nil))
	  ((reference-tn-list locs t))
	  "<save info>"
	  (ir2-environment-return-pc-pass env)
	  start)
    (mapc #'(lambda (from to)
	      (unless (eq from to)
		(emit-move node block from to)))
	  locs temps)
    (move-continuation-result node block temps cont))
  (undefined-value))


;;; IR2-Convert-Local-Unknown-Call  --  Internal
;;;
;;;    Handle a non-TR unknown-values local call.  We do different things
;;; depending on what kind of values the continuation wants.
;;;
;;;    If Cont is :Unkown, then we use the "Multiple-" variant, directly
;;; specifying the continuation's Locs as the VOP results so that we don't have
;;; to do anything after the call.
;;;
;;;    Otherwise, we use Standard-Result-Tns to get wired result TNs, and
;;; then call Move-Continuation-Result to do any necessary type checks or
;;; coercions.
;;;
(defun ir2-convert-local-unknown-call (node block env cont start)
  (declare (type node node) (type ir2-block block) (type ir2-environment env)
	   (type continuation cont) (type label start))
  (let ((2cont (continuation-info cont))
	(old-cont (ir2-environment-old-cont-pass env))
	(argp (ir2-environment-argument-pointer env))
	(return-pc (ir2-environment-return-pc-pass env))
	(arg-locs (reference-tn-list (ir2-environment-arg-locs env) nil)))
    (if (and 2cont (eq (ir2-continuation-kind 2cont) :unknown))
	(vop* multiple-call-local node block (old-cont argp arg-locs)
	      ((reference-tn-list (ir2-continuation-locs 2cont) t))
	      "<save info>" return-pc start)
	(let ((temps (standard-result-tns cont)))
	  (vop* call-local node block
		(old-cont argp arg-locs)
		((reference-tn-list temps t))
		"<save info>" return-pc start (length temps))
	  (move-continuation-result node block temps cont))))
  (undefined-value))


;;; IR2-Convert-Local-Normal-Call  --  Internal
;;;
;;;    This function handles non-tail-recursive local call.  We move the
;;; arguments into the passing locations and then look at return conventions
;;; and think about how we are going to get the values back.
;;;
(defun ir2-convert-local-normal-call (node block fun)
  (let* ((env (environment-info (lambda-environment fun)))
	 (start (block-label (node-block (lambda-bind fun))))
	 (returns (tail-set-info (lambda-tail-set fun)))
	 (cont (node-cont node)))
    (move-local-call-args node block fun)
    (vop current-cont node block (ir2-environment-old-cont-pass env))
    (vop current-cont node block (ir2-environment-argument-pointer env))
    (ecase (return-info-kind returns)
      (:unknown
       (ir2-convert-local-unknown-call node block env cont start))
      (:fixed
       (ir2-convert-local-known-call node block env returns cont start))))
  (undefined-value))


;;; IR2-Convert-Local-Call  --  Internal
;;;
;;;    Dispatch to the appropriate function, depending on whether we have a
;;; let, tail or normal call.
;;;
(defun ir2-convert-local-call (node block)
  (declare (type combination node) (type ir2-block block))
  (let ((fun (ref-leaf (continuation-use (basic-combination-fun node)))))
    (cond ((eq (functional-kind fun) :let)
	   (ir2-convert-let node block fun))
	  ((node-tail-p node)
	   (ir2-convert-tail-local-call node block fun))
	  (t
	   (ir2-convert-local-normal-call node block fun))))
  (undefined-value))


;;;; Full call:


;;; Function-Continuation-TN  --  Internal
;;;
;;;    Given a function continuation Fun, return as values a TN holding the
;;; thing that we call and true if the thing is a symbol (false if it is a
;;; function).
;;;
(defun function-continuation-tn (node block cont)
  (declare (type continuation cont))
  (let* ((2cont (continuation-info cont))
	 (name (if (eq (ir2-continuation-kind 2cont) :delayed)
		   (let ((res (continuation-function-name cont)))
		     (assert res)
		     res)
		   nil)))
    (if name
	(values (emit-constant name) t)
	(let ((locs (ir2-continuation-locs 2cont))
	      (type (ir2-continuation-primitive-type 2cont)))
	  (assert (and (eq (ir2-continuation-kind 2cont) :fixed)
		       (= (length locs) 1)))
	  (if (eq (primitive-type-name type) 'function)
	      (values (first locs) nil)
	      (let ((temp (make-normal-tn *any-primitive-type*)))
		(when (policy node (> speed brevity))
		  (let ((*compiler-error-context* node))
		    (compiler-note "Called function might be a symbol, so ~
		                    must coerce at run-time.")))
		(vop coerce-to-function node block (first locs) temp)
		(values temp nil)))))))


;;; Move-Full-Call-Args  --  Internal
;;;
;;;    Set up the arguments to a full call in the appropriate passing
;;; locations.  Returns the head of a TN-Ref list to the passing locations.
;;;
(defun move-full-call-args (node block)
  (declare (type combination node) (type ir2-block block))
  (let ((args (basic-combination-args node))
	(last nil)
	(first nil))
    (dotimes (num (length args))
      (let ((loc (standard-argument-location num)))
	(emit-move node block (continuation-tn node block (elt args num)) loc)
	(let ((ref (reference-tn loc nil)))
	  (if last
	      (setf (tn-ref-across last) ref)
	      (setf first ref))
	  (setq last ref))))
      first))


;;; IR2-Convert-Tail-Full-Call  --  Internal
;;;
;;;    Move the arguments into the passing locations and do a (possibly named)
;;; tail call.  We flush the tail control transfer so that nobody thinks that
;;; we return.
;;;
(defun ir2-convert-tail-full-call (node block)
  (declare (type combination node) (type ir2-block block))
  (let* ((pass-refs (move-full-call-args node block))
	 (env (environment-info (node-environment node)))
	 (old-cont (ir2-environment-old-cont env))
	 (return-pc (ir2-environment-return-pc env))
	 (nargs (length (basic-combination-args node))))
    (multiple-value-bind
	(fun-tn named)
	(function-continuation-tn node block (basic-combination-fun node))
      (if named
	  (vop* tail-call-named node block
		(fun-tn old-cont return-pc pass-refs)
		(nil)
		nargs)
	  (vop* tail-call node block
		(fun-tn old-cont return-pc pass-refs)
		(nil)
		nargs))))
  (flush-tail-transfer node block)
  (undefined-value))


;;; IR2-Convert-Fixed-Full-Call  --  Internal
;;;
;;;    Do full call when a fixed number of values are desired.  We make
;;; Standard-Result-TNs for our continuation, then deliver the result using
;;; Move-Continuation-Result.  We do named or normal call, as appropriate.
;;;
(defun ir2-convert-fixed-full-call (node block)
  (declare (type combination node) (type ir2-block block))
  (let* ((nargs (length (basic-combination-args node)))
	 (pass-refs (move-full-call-args node block))
	 (cont (node-cont node))
	 (locs (standard-result-tns cont))
	 (loc-refs (reference-tn-list locs t))
	 (nvals (length locs)))
    (multiple-value-bind
	(fun-tn named)
	(function-continuation-tn node block (basic-combination-fun node))
      (if named
	  (vop* call-named node block (fun-tn pass-refs) (loc-refs)
		"<save info>" nargs nvals)
	  (vop* call node block (fun-tn pass-refs) (loc-refs)
		"<save info>" nargs nvals))
      (move-continuation-result node block locs cont)))
  (undefined-value))


;;; IR2-Convert-Multiple-Full-Call  --  Internal
;;;
;;;    Do full call when unknown values are desired.
;;;
(defun ir2-convert-multiple-full-call (node block)
  (declare (type combination node) (type ir2-block block))
  (let* ((nargs (length (basic-combination-args node)))
	 (pass-refs (move-full-call-args node block))
	 (cont (node-cont node))
	 (locs (ir2-continuation-locs (continuation-info cont)))
	 (loc-refs (reference-tn-list locs t)))
    (multiple-value-bind
	(fun-tn named)
	(function-continuation-tn node block (basic-combination-fun node))
      (if named
	  (vop* multiple-call-named node block (fun-tn pass-refs) (loc-refs)
		"<save info>" nargs)
	  (vop* multiple-call node block (fun-tn pass-refs) (loc-refs)
		"<save info>" nargs))))
  (undefined-value))


;;; IR2-Convert-Full-Call  --  Internal
;;;
;;;    If the call is in a TR position and the return convention is standard,
;;; then do a full call.  If one or fewer values are desired, then use a
;;; single-value call, otherwise use a multiple-values call.
;;;
(defun ir2-convert-full-call (node block)
  (declare (type combination node) (type ir2-block block))
  (let ((2cont (continuation-info (node-cont node))))
    (cond ((let ((tails (node-tail-p node)))
	     (and tails
		  (eq (return-info-kind (tail-set-info tails)) :unknown)))
	   (ir2-convert-tail-full-call node block))
	  ((and 2cont
		(eq (ir2-continuation-kind 2cont) :unknown))
	   (ir2-convert-multiple-full-call node block))
	  (t
	   (ir2-convert-fixed-full-call node block))))
  (undefined-value))


;;;; Function entry:


;;; Convert these funny functions into a %Primitive use, letting %Primitive
;;; deal with evaluating the "Fixed" codegen-info arguments.
;;;
(def-source-transform %more-arg-context (&rest foo)
  `(%primitive more-arg-context ,@foo))
;;;
(def-source-transform %verify-argument-count (&rest foo)
  `(%primitive verify-argument-count ,@foo))

  
;;; Init-XEP-Environment  --  Internal
;;;
;;;    Do all the stuff that needs to be done on XEP entry:
;;; -- Create frame
;;; -- Copy any more arg
;;; -- Set up the environment, accessing any closure variables
;;; 
(defun init-xep-environment (node block fun)
  (declare (type bind node) (type ir2-block block) (type clambda fun))
  (vop allocate-frame node block)
  (let ((ef (functional-entry-function fun)))
    (when (and (optional-dispatch-p ef)
	       (optional-dispatch-more-entry ef))
      (vop copy-more-arg node block (optional-dispatch-max-args ef))))

  (let ((env (environment-info (node-environment node))))
    (if (ir2-environment-environment env)
	(let ((closure (make-normal-tn *any-primitive-type*)))
	  (vop setup-closure-environment node block closure)
	  (let ((n (1- system:%function-closure-variables-offset)))
	    (dolist (loc (ir2-environment-environment env))
	      (vop closure-ref node block closure (incf n) (cdr loc)))))
	(vop setup-environment node block)))

  (undefined-value))


;;; IR2-Convert-Bind  --  Internal
;;;
;;;    Emit moves from the passing locations to the internal locations.  This
;;; is only called on bind nodes for functions that allocate environments.  All
;;; semantics of let calls are handled by IR2-Convert-Let.
;;;
;;;    We special-case XEPs by calling Init-XEP-Environment before moving the
;;; arguments.  Init-XEP-Environment accesses any environment values from the
;;; closure, so initialization of the environment from implicit arguments is
;;; suppressed.
;;;
(defun ir2-convert-bind (node block)
  (declare (type bind node) (type ir2-block block))
  (let* ((fun (bind-lambda node))
	 (xep-p (external-entry-point-p fun))
	 (env (environment-info (lambda-environment fun)))
	 (argp (ir2-environment-argument-pointer env))
	 (args (ir2-environment-arg-locs env)))
    (assert (member (functional-kind fun)
		    '(nil :external :optional :top-level :cleanup)))

    (when xep-p
      (init-xep-environment node block fun))

    (dolist (arg (lambda-vars fun))
      (when (leaf-refs arg)
	(let ((pass (pop args))
	      (home (leaf-info arg)))
	  (if (lambda-var-indirect arg)
	      (let ((temp (make-normal-tn *any-primitive-type*)))
		(move-from-frame node block pass temp argp)
		(vop make-value-cell node block temp home))
	      (move-from-frame node block pass home argp)))))

    (unless xep-p
      (dolist (loc (ir2-environment-environment env))
	(move-from-frame node block (pop args) (cdr loc) argp)))
    
    (when (ir2-environment-old-cont env)
      (move-from-frame node block (ir2-environment-old-cont-pass env)
		       (ir2-environment-old-cont env) argp))
    
    (when (ir2-environment-return-pc env)
      (move-from-frame node block (ir2-environment-return-pc-pass env)
		       (ir2-environment-return-pc env) argp)))
  
  (undefined-value))


;;;; Function return:

;;; IR2-Convert-Return  --  Internal
;;;
(defun ir2-convert-return (node block)
  (let ((cont (continuation-info (return-result node))))
    (unless (eq (ir2-continuation-kind cont) :unused)
      (emit-return-for-locs node block
			    (ir2-continuation-kind cont)
			    (ir2-continuation-locs cont))))
  (undefined-value))


;;; Emit-Return-For-Locs  --  Internal
;;;
;;;    Do stuff to return from a function with the specified values and
;;; convention.  Node must the Return node that we are doing a return for.
;;; The reason that this is broken off from IR2-Convert-Return in this curious
;;; way is that when all uses of the result are tail-recursive, we annotate the
;;; result continuation as :Unused and then emit a return at each use of the
;;; result.
;;;
;;;    If the return convention is :Fixed and we aren't returning from an XEP,
;;; then we move the return values to the passing locs and do a Known-Return.
;;; Otherwise, we use the unknown-values convention.  If there is a fixed
;;; number of return values, then use Return, otherwise use Return-Multiple.
;;;
(defun emit-return-for-locs (node block cont-kind cont-locs)
  (declare (type creturn node) (type ir2-block block)
	   (type (member :fixed :unknown) cont-kind)
	   (list cont-locs))
  (let* ((fun (return-lambda node))
	 (env (environment-info (lambda-environment fun)))
	 (old-cont (ir2-environment-old-cont env))
	 (return-pc (ir2-environment-return-pc env))
	 (returns (tail-set-info (lambda-tail-set fun))))
    (cond
     ((and (eq (return-info-kind returns) :fixed)
	   (not (external-entry-point-p fun)))
      (let ((locs (return-info-locations returns)))
	(mapc #'(lambda (from to)
		  (move-to-frame node block from to old-cont))
	      cont-locs locs)
	(vop* known-return node block
	      (old-cont return-pc (reference-tn-list locs nil))
	      (nil))))
     ((eq cont-kind :fixed)
      (let* ((nvals (length cont-locs))
	     (locs (make-standard-value-tns nvals)))
	(mapc #'(lambda (val loc)
		  (emit-move node block val loc))
	      cont-locs
	      locs)
	(vop* return node block
	      (old-cont return-pc (reference-tn-list locs nil))
	      (nil)
	      nvals)))
     (t
      (assert (eq cont-kind :unknown))
      (vop* return-multiple node block
	    (old-cont return-pc (reference-tn-list cont-locs nil))
	    (nil)))))

  (undefined-value))


;;;; Multiple values:

;;; IR2-Convert-MV-Bind  --  Internal
;;;
;;;    Almost identical to IR2-Convert-Let.  Since LTN annotates the
;;; continuation for the correct number of values (with the continuation user
;;; responsible for defaulting), we can just pick them up from the
;;; continuation.
;;;
(defun ir2-convert-mv-bind (node block)
  (declare (type mv-combination node) (type ir2-block block))
  (let ((cont (continuation-info (first (basic-combination-args node))))
	(fun (ref-leaf (continuation-use (basic-combination-fun node)))))
    (assert (eq (functional-kind fun) :mv-let))
  (mapc #'(lambda (src var)
	    (when (leaf-refs var)
	      (let ((dest (leaf-info var)))
		(if (lambda-var-indirect var)
		    (vop make-value-cell node block src dest)
		    (emit-move node block src dest)))))
	(ir2-continuation-locs cont) (lambda-vars fun)))
  (undefined-value))


;;; IR2-Convert-MV-Call  --  Internal
;;;
;;;    Emit the appropriate fixed value, unknown value or tail variant of
;;; Call-Variable.  Note that we only need to pass the values start for the
;;; first argument: all the other argument continuation TNs are ignored.  This
;;; is because we require all of the values globs to be contiguous and on stack
;;; top. 
;;;
(defun ir2-convert-mv-call (node block)
  (declare (type mv-combination node) (type ir2-block block))
  (assert (basic-combination-args node))
  (let* ((start-cont (continuation-info (first (basic-combination-args node))))
	 (start (first (ir2-continuation-locs start-cont)))
	 (tails (node-tail-p node))
	 (cont (node-cont node))
	 (2cont (continuation-info cont)))
    (multiple-value-bind
	(fun named)
	(function-continuation-tn node block (basic-combination-fun node))
      (assert (and (not named)
		   (eq (ir2-continuation-kind start-cont) :unknown)))
      (cond
       ((and tails
	     (eq (return-info-kind (tail-set-info tails)) :unknown))
	(let ((env (environment-info (node-environment node))))
	  (vop tail-call-variable node block fun
	       (ir2-environment-old-cont env)
	       (ir2-environment-return-pc env)
	       start))
	(flush-tail-transfer node block))
       ((and 2cont
	     (eq (ir2-continuation-kind 2cont) :unknown))
	(vop* multiple-call-variable node block (fun start nil)
	      ((reference-tn-list (ir2-continuation-locs 2cont) t))
	      "<save info>"))
       (t
	(let ((locs (standard-result-tns cont)))
	  (vop* call-variable node block (fun start nil)
		((reference-tn-list locs t))
		"<save info>" (length locs))
	  (move-continuation-result node block locs cont)))))))


;;; %Pop-Values IR2 convert  --  Internal
;;;
;;;    Reset the stack pointer to the start of the specified unknown-values
;;; continuation (discarding it and all values globs on top of it.)
;;;
(defoptimizer (%pop-values ir2-convert) ((continuation) node block)
  (let ((2cont (continuation-info (continuation-value continuation))))
    (assert (eq (ir2-continuation-kind 2cont) :unknown))
    (vop reset-stack-pointer node block
	 (first (ir2-continuation-locs 2cont)))))


;;; Values IR2 convert  --  Internal
;;;
;;;    Deliver the values TNs to Cont using Move-Continuation-Result.
;;;
(defoptimizer (values ir2-convert) ((&rest values) node block)
  (let ((tns (mapcar #'(lambda (x)
			 (continuation-tn node block x))
		     values)))
    (move-continuation-result node block tns (node-cont node))))


;;; Values-List IR2 convert  --  Internal
;;;
;;;    In the normal case where unknown values are desired, we use the
;;; Values-List VOP.  If the continuation is :Unused (a TR result
;;; continuation), then we must compute the values into temporaries and then do
;;; an Emit-Return-For-Locs and flush the tail control transfer.
;;;
;;;    In the relatively unimportant case of Values-List for a fixed number of
;;; values, we punt by doing a full call to the Values-List function.  This
;;; gets the full call VOP to deal with defaulting any unsupplied values.  It
;;; seems unworthwhile to optimize this case.
;;;
(defoptimizer (values-list ir2-convert) ((list) node block)
  (let* ((cont (node-cont node))
	 (2cont (continuation-info cont)))
    (when 2cont
      (let ((kind (ir2-continuation-kind 2cont)))
	(if (eq kind :fixed)
	    (ir2-convert-full-call node block)
	    (let ((locs (ecase kind
			  (:unknown (ir2-continuation-locs 2cont))
			  (:unused (make-unknown-values-locations)))))
	      (vop* values-list node block
		    ((continuation-tn node block list) nil)
		    ((reference-tn-list locs t)))
	      (when (eq kind :unused)
		(emit-return-for-locs (continuation-dest cont) block :unknown
				      locs)
		(flush-tail-transfer node block))))))))


;;;; Special binding:

;;; %Special-Bind, %Special-Unbind IR2 convert  --  Internal
;;;
;;;    Trivial, given our assumption of a shallow-binding implementation.
;;;
(defoptimizer (%special-bind ir2-convert) ((var value) node block)
  (let ((name (leaf-name (continuation-value var))))
    (vop bind node block (continuation-tn node block value)
	 (emit-constant name))))
;;;
(defoptimizer (%special-unbind ir2-convert) ((var) node block)
  (vop unbind node block (emit-constant 1)))


;;; PROGV IR1 convert  --  Internal
;;;
;;; ### Not clear that this really belongs in this file, or should really be
;;; done this way, but this is the least violation of abstraction in the
;;; current setup.  We don't want to wire shallow-binding assumptions into
;;; IR1tran.
;;;
(def-ir1-translator progv ((vars vals &body body) start cont)
  (ir1-convert
   start cont
   (if *converting-for-interpreter*
       `(%progv ,vars ,vals #'(lambda () ,@body))
       (once-only ((n-save-bs '(%primitive current-binding-pointer)))
	 `(unwind-protect
	      (progn
		(mapc #'(lambda (var val)
			  (%primitive bind val var))
		      ,vars
		      ,vals)
		,@body)
	    (%primitive unbind-to-here ,n-save-bs))))))


;;;; Non-local exit:

;;; IR2-Convert-Exit  --  Internal
;;;
;;;    Convert a non-local lexical exit.  First find the NLX-Info in our
;;; environment.  After indirecting the value cell, we invalidate the exit by
;;; setting the cell to 0.  Note that this is never called on the escape exits
;;; for Catch and Unwind-Protect, since the escape functions aren't IR2
;;; converted.
;;;
(defun ir2-convert-exit (node block)
  (declare (type exit node) (type ir2-block block))
  (let ((loc (find-in-environment (find-nlx-info (exit-entry node)
						 (node-cont node))
				  (node-environment node)))
	(temp (make-normal-tn *any-primitive-type*))
	(value (exit-value node)))
    (vop value-cell-ref node block loc temp)
    (vop value-cell-set node block loc (emit-constant 0))
    (if value
	(let ((locs (ir2-continuation-locs (continuation-info value))))
	  (vop unwind node block temp (first locs) (second locs)))
	(let ((0-tn (emit-constant 0)))
	  (vop unwind node block temp 0-tn 0-tn))))

  (undefined-value))


;;; This function invalidates a lexical exit on exiting from the dynamic
;;; extent.  This is done by storing 0 into the indirect value cell that holds
;;; the closed unwind block.
;;;
(defoptimizer (%lexical-exit-breakup ir2-convert) ((info) node block)
  (vop value-cell-set node block
       (find-in-environment (continuation-value info) (node-environment node))
       (emit-constant 0)))


;;; IR2-Convert-Throw  --  Internal
;;;
;;;    We have to do a spurious move of no values to the result continuation so
;;; that lifetime analysis won't get confused.
;;;
(defun ir2-convert-throw (node block)
  (declare (type mv-combination node) (type ir2-block block))
  (let ((args (basic-combination-args node)))
    (vop* throw node block
	  ((continuation-tn node block (first args))
	   (reference-tn-list
	    (ir2-continuation-locs (continuation-info (second args)))
	    nil))
	  (nil)))

  (move-continuation-result node block () (node-cont node))
  (undefined-value))


;;; Emit-NLX-Start  --  Internal
;;;
;;;    Emit code to set up a non-local-exit.  Info is the NLX-Info for the
;;; exit, and Tag is the continuation for the catch tag (if any.)  We get at
;;; the entry PC by making a :Label load-time constant TN.  This is a
;;; non-immediate constant TN that is initialized to the offset of the
;;; specified label.
;;;
(defun emit-nlx-start (node block info tag)
  (declare (type node node) (type ir2-block block) (type nlx-info info)
	   (type (or continuation null) tag))
  (let* ((2info (nlx-info-info info))
	 (kind (cleanup-kind (nlx-info-cleanup info)))
	 (block-tn (make-environment-tn (primitive-type-or-lose 'catch-block)
					(node-environment node)))
	 (res (make-normal-tn *any-primitive-type*))
	 (target-tn
	  (make-load-time-constant-tn
	   :label
	   (block-label (nlx-info-target info)))))

    (vop* save-dynamic-state node block
	  (nil)
	  ((reference-tn-list (ir2-nlx-info-dynamic-state 2info) t)))
    (vop current-stack-pointer node block (ir2-nlx-info-save-sp 2info))

    (ecase kind
      (:catch
       (vop make-catch-block node block block-tn
	    (continuation-tn node block tag) target-tn res))
      ((:unwind-protect :entry)
       (vop make-unwind-block node block block-tn target-tn res)))

    (ecase kind
      (:entry
       (vop make-value-cell node block res (ir2-nlx-info-home 2info)))
      (:unwind-protect
       (vop set-unwind-protect node block block-tn))
      (:catch)))

  (undefined-value))


;;; IR2-Convert-Entry  --  Internal
;;;
;;;    Scan each of Entry's exits, setting up the exit for each lexical exit.
;;;
(defun ir2-convert-entry (node block)
  (declare (type entry node) (type ir2-block block))
  (dolist (exit (entry-exits node))
    (let ((info (find-nlx-info node exit)))
      (when (and info (eq (cleanup-kind (nlx-info-cleanup info)) :entry))
	(emit-nlx-start node block info nil)
	(return))))
  (undefined-value))


;;; %Catch, %Unwind-Protect IR2 convert  --  Internal
;;;
;;;    Set up the unwind block for these guys.
;;;
(defoptimizer (%catch ir2-convert) ((info-cont tag) node block)
  (emit-nlx-start node block (continuation-value info-cont) tag))
;;;
(defoptimizer (%unwind-protect ir2-convert) ((info-cont cleanup) node block)
  (emit-nlx-start node block (continuation-value info-cont) nil))


;;; %NLX-Entry IR2 convert  --  Internal
;;;
;;; Emit the entry code for a non-local exit.  We receive values and restore
;;; dynamic state.
;;;
;;; In the case of a lexical exit or Catch, we look at the exit continuation's
;;; kind to determine which flavor of entry VOP to emit.  If unknown values,
;;; emit the xxx-MULTIPLE variant to the continuation locs.  If fixed values,
;;; make the appropriate number of temps in the standard values locations and
;;; use the other variant, delivering the temps to the continuation using
;;; Move-Continuation-Result.
;;;
;;; In the Unwind-Protect case, we deliver move the first register argument,
;;; the argument count and the argument pointer to our continuation as multiple
;;; values.  These values are the block exited to and the values start and
;;; count.
;;;
;;; After receiving values, we restore dynamic state.  Except in the
;;; Unwind-Protect case, the values receiving restores the stack pointer.  In
;;; an Unwind-Protect cleanup, we want to leave the stack pointer alone, since
;;; the thrown values are still out there.
;;;
(defoptimizer (%nlx-entry ir2-convert) ((info-cont) node block)
  (let* ((info (continuation-value info-cont))
	 (cont (nlx-info-continuation info))
	 (2cont (continuation-info cont))
	 (2info (nlx-info-info info))
	 (top-loc (ir2-nlx-info-save-sp 2info))
	 (start-loc (make-argument-pointer-location t))
	 (count-loc (make-argument-count-location)))

    (ecase (cleanup-kind (nlx-info-cleanup info))
      ((:catch :entry)
       (if (and 2cont (eq (ir2-continuation-kind 2cont) :unknown))
	   (vop* nlx-entry-multiple node block
		 (top-loc start-loc count-loc nil)
		 ((reference-tn-list (ir2-continuation-locs 2cont) t)))
	   (let ((locs (standard-result-tns cont)))
	     (vop* nlx-entry node block
		   (top-loc start-loc count-loc nil)
		   ((reference-tn-list locs t))
		   (length locs))
	     (move-continuation-result node block locs cont))))
      (:unwind-protect
       (let ((block-loc (standard-argument-location 0)))
	 (vop uwp-entry node block block-loc start-loc count-loc)
	 (move-continuation-result
	  node block
	  (list block-loc start-loc count-loc)
	  cont))))

    (vop* restore-dynamic-state node block
	  ((reference-tn-list (ir2-nlx-info-dynamic-state 2info) nil))
	  (nil))))
	    

;;;; Error funny functions:
;;;
;;; Mark these as as not returning by using TRULY-THE NIL.

(def-source-transform %type-check-error (obj type)
  `(truly-the nil (%primitive error2 clc::error-object-not-type ,obj ,type)))

(def-source-transform %odd-keyword-arguments-error ()
  '(truly-the nil (%primitive error0 clc::error-odd-keyword-arguments)))

(def-source-transform %unknown-keyword-argument-error (key)
  `(truly-the nil (%primitive error1 clc::error-unknown-keyword-argument ,key)))

(def-source-transform %argument-count-error (&rest foo)
  `(truly-the nil (%primitive argument-count-error ,@foo)))


;;;; N-arg functions:

(macrolet ((frob (name)
	     `(defoptimizer (,name ir2-convert) ((&rest args) node block)
		(let* ((refs (move-full-call-args node block))
		       (cont (node-cont node))
		       (res (continuation-result-tns
			     cont
			     (list (primitive-type (specifier-type 'list))))))
		  (vop* ,name node block
			(refs)
			((first res) nil)
			(length args))
		  (move-continuation-result node block res cont)))))
  (frob list)
  (frob list*))

(def-primitive-translator syscall (&rest args) `(%syscall ,@args))
(defknown %syscall (&rest t) *)

(defoptimizer (%syscall ir2-convert) ((&rest args) node block)
  (let* ((refs (move-full-call-args node block))
	 (cont (node-cont node))
	 (res (continuation-result-tns
	       cont
	       (list *any-primitive-type* *any-primitive-type*))))
    (vop* syscall node block
	  (refs)
	  ((first res) (second res) nil)
	  (length args))
    (move-continuation-result node block res cont)))  


;;;; Structure accessors:
;;;
;;;    These guys have to bizarrely determine the slot offset by looking at the
;;; called function.

(defoptimizer (%slot-accessor ir2-convert) ((str) node block)
  (let* ((cont (node-cont node))
	 (res (continuation-result-tns cont (list *any-primitive-type*))))
    (vop structure-ref node block
	 (continuation-tn node block str)
	 (dsd-index
	  (slot-accessor-slot
	   (ref-leaf
	    (continuation-use
	     (combination-fun node)))))
	 (first res))
    (move-continuation-result node block res cont)))

(defoptimizer (%slot-setter ir2-convert) ((str value) node block)
  (let ((val (continuation-tn node block value)))
    (vop structure-set node block
	 (continuation-tn node block str)
	 val
	 (dsd-index
	  (slot-accessor-slot
	   (ref-leaf
	    (continuation-use
	     (combination-fun node))))))
  
    (move-continuation-result node block (list val) (node-cont node))))


;;; IR2-Convert  --  Interface
;;;
;;;    Convert the code in a component into VOPs.
;;;
(defun ir2-convert (component)
  (declare (type component component))
  (do-blocks (block component)
    (ir2-convert-block block))
  (undefined-value))


;;; Finish-IR2-Block  --  Internal
;;;
;;;    If necessary, emit a terminal unconditional branch to go to the
;;; successor block.  When there is a deleted tail control transfer, no branch
;;; is necessary.
;;;
(defun finish-ir2-block (block)
  (declare (type cblock block))
  (let* ((2block (block-info block))
	 (last (block-last block))
	 (succ (block-succ block)))
    (unless (or (if-p last) (return-p last)
		(and (null succ)
		     (or (node-tail-p last)
			 (exit-p last))))
      (assert (and succ (null (rest succ))))
      (let ((target (first succ)))
	(unless (eq (ir2-block-next 2block) (block-info target))
	  (vop branch last 2block (block-label target))))))
  (undefined-value))


;;; IR2-Convert-Block  --  Internal
;;;
;;;    Convert the code in a block into VOPs.
;;;
(defun ir2-convert-block (block)
  (declare (type cblock block))
  (let ((2block (block-info block)))
    (do-nodes (node cont block)
      (etypecase node
	(ref
	 (let ((2cont (continuation-info cont)))
	   (when (and 2cont
		      (not (eq (ir2-continuation-kind 2cont) :delayed)))
	     (ir2-convert-ref node 2block))))
	(combination
	 (let ((kind (basic-combination-kind node)))
	   (case kind
	     (:local
	      (ir2-convert-local-call node 2block))
	     (:full
	      (ir2-convert-full-call node 2block))
	     (t
	      (let ((fun (function-info-ir2-convert kind)))
		(cond (fun
		       (funcall fun node 2block))
		      ((basic-combination-info node)
		       (ir2-convert-template node 2block))
		      (t
		       (ir2-convert-full-call node 2block))))))))
	(cif
	 (when (continuation-info (if-test node))
	   (ir2-convert-if node 2block)))
	(bind
	 (let ((fun (bind-lambda node)))
	   (when (eq (lambda-home fun) fun)
	     (ir2-convert-bind node 2block))))
	(creturn
	 (ir2-convert-return node 2block))
	(cset
	 (ir2-convert-set node 2block))
	(mv-combination
	 (cond
	  ((eq (basic-combination-kind node) :local)
	   (ir2-convert-mv-bind node 2block))
	  ((eq (continuation-function-name (basic-combination-fun node))
	       '%throw)
	   (ir2-convert-throw node 2block))
	  (t
	   (ir2-convert-mv-call node 2block))))
	(exit
	 (when (exit-entry node)
	   (ir2-convert-exit node 2block)))
	(entry
	 (ir2-convert-entry node 2block)))))

  (finish-ir2-block block)

  (undefined-value))
