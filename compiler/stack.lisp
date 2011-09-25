;;; -*- Package: C; Log: C.Log -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the CMU Common Lisp project at
;;; Carnegie Mellon University, and has been placed in the public domain.
;;;
(ext:file-comment
  "$Header: src/compiler/stack.lisp $")
;;;
;;; **********************************************************************
;;;
;;;    The stack analysis phase in the compiler.  We do a graph walk to
;;; determine which unknown-values continuations are on the stack at each point
;;; in the program, and then we insert cleanup code to pop off unused values.
;;;
;;; Written by Rob MacLachlan
;;;
(in-package "C")
(intl:textdomain "cmucl")


;;; Find-Pushed-Continuations  --  Internal
;;;
;;;    Scan through Block looking for uses of :Unknown continuations that have
;;; their Dest outside of the block.  We do some checking to verify the
;;; invariant that all pushes come after the last pop.
;;;
(defun find-pushed-continuations (block)
  (let* ((2block (block-info block))
	 (popped (ir2-block-popped 2block))
	 (last-pop (if popped
		       (continuation-dest (car (last popped)))
		       nil)))
    (collect ((pushed))
      (let ((saw-last nil))
	(do-nodes (node cont block)
	  (when (eq node last-pop)
	    (setq saw-last t))

	  (let ((dest (continuation-dest cont))
		(2cont (continuation-info cont)))
	    (when (and dest
		       (not (eq (node-block dest) block))
		       2cont
		       (eq (ir2-continuation-kind 2cont) :unknown))
	      (assert (or saw-last (not last-pop)))
	      (pushed cont)))))

      (setf (ir2-block-pushed 2block) (pushed))))
  (undefined-value))


;;;; Annotation graph walk:

;;; Stack-Simulation-Walk  --  Internal
;;;
;;;    Do a backward walk in the flow graph simulating the run-time stack of
;;; unknown-values continuations and annotating the blocks with the result.
;;;
;;;    Block is the block that is currently being walked and Stack is the stack
;;; of unknown-values continuations in effect immediately after block.  We
;;; simulate the stack by popping off the unknown-values generated by this
;;; block (if any) and pushing the continuations for values received by this
;;; block.  (The role of push and pop are interchanged because we are doing a
;;; backward walk.)
;;;
;;;    If we run into a values generator whose continuation isn't on stack top,
;;; then the receiver hasn't yet been reached on any walk to this use.  In this
;;; case, we ignore the push for now, counting on Annotate-Dead-Values to clean
;;; it up if we discover that it isn't reachable at all.
;;;
;;;    If our final stack isn't empty, then we walk all the predecessor blocks
;;; that don't have all the continuations that we have on our Start-Stack on
;;; their End-Stack.  This is our termination condition for the graph walk.  We
;;; put the test around the recursive call so that the initial call to this
;;; function will do something even though there isn't initially anything on
;;; the stack.
;;;
;;;    We can use the tailp test, since the only time we want to bottom out
;;; with a non-empty stack is when we intersect with another path from the same
;;; top-level call to this function that has more values receivers on that
;;; path.  When we bottom out in this way, we are counting on
;;; DISCARD-UNUSED-VALUES doing its thing.
;;;
;;;    When we do recurse, we check that predecessor's END-STACK is a
;;; subsequence of our START-STACK.  There may be extra stuff on the top
;;; of our stack because the last path to the predecessor may have discarded
;;; some values that we use.  There may be extra stuff on the bottom of our
;;; stack because this walk may be from a values receiver whose lifetime
;;; encloses that of the previous walk.
;;;
;;;    If a predecessor block is the component head, then it must be the case
;;; that this is a NLX entry stub.  If so, we just stop our walk, since the
;;; stack at the exit point doesn't have anything to do with our stack.
;;;
(defun stack-simulation-walk (block stack)
  (declare (type cblock block) (list stack))
  (let ((2block (block-info block)))
    (setf (ir2-block-end-stack 2block) stack)
    (let ((new-stack stack))
      (dolist (push (reverse (ir2-block-pushed 2block)))
	(if (eq (car new-stack) push)
	    (pop new-stack)
	    (assert (not (member push new-stack)))))
      
      (dolist (pop (reverse (ir2-block-popped 2block)))
	(push pop new-stack))
      
      (setf (ir2-block-start-stack 2block) new-stack)
      
      (when new-stack
	(dolist (pred (block-pred block))
	  (if (eq pred (component-head (block-component block)))
	      (assert (find block
			    (environment-nlx-info (block-environment block))
			    :key #'nlx-info-target))
	      (let ((pred-stack (ir2-block-end-stack (block-info pred))))
		(unless (tailp new-stack pred-stack)
		  (assert (search pred-stack new-stack))
		  (stack-simulation-walk pred new-stack))))))))

  (undefined-value))


;;; Annotate-Dead-Values  --  Internal
;;;
;;;    Do stack annotation for any values generators in Block that were
;;; unreached by all walks (i.e. the continuation isn't live at the point that
;;; it is generated.)  This will only happen when the values receiver cannot be
;;; reached from this particular generator (due to an unconditional control
;;; transfer.)
;;;
;;;    What we do is push on the End-Stack all continuations in Pushed that
;;; aren't already present in the End-Stack.  When we find any pushed
;;; continuation that isn't live, it must be the case that all continuations
;;; pushed after (on top of) it aren't live.
;;;
;;;    If we see a pushed continuation that is the CONT of a tail call, then we
;;; ignore it, since the tail call didn't actually push anything.  The tail
;;; call must always the last in the block. 
;;;
(defun annotate-dead-values (block)
  (declare (type cblock block))
  (let* ((2block (block-info block))
	 (stack (ir2-block-end-stack 2block))
	 (last (block-last block))
	 (tailp-cont (if (node-tail-p last) (node-cont last))))
    (do ((pushes (ir2-block-pushed 2block) (rest pushes))
	 (popping nil))
	((null pushes))
      (let ((push (first pushes)))
	(cond ((member push stack)
	       (assert (not popping)))
	      ((eq push tailp-cont)
	       (assert (null (rest pushes))))
	      (t
	       (push push (ir2-block-end-stack 2block))
	       (setq popping t))))))
  
  (undefined-value))


;;; Discard-Unused-Values  --  Internal
;;;
;;;    Called when we discover that the stack-top unknown-values continuation
;;; at the end of Block1 is different from that at the start of Block2 (its
;;; successor.)
;;;
;;;    We insert a call to a funny function in a new cleanup block introduced
;;; between Block1 and Block2.  Since control analysis and LTN have already
;;; run, we must do make an IR2 block, then do ADD-TO-EMIT-ORDER and
;;; LTN-ANALYZE-BLOCK on the new block.  The new block is inserted after Block1
;;; in the emit order.
;;;
;;;    If the control transfer between Block1 and Block2 represents a
;;; tail-recursive return (:Deleted IR2-continuation) or a non-local exit, then
;;; the cleanup code will never actually be executed.  It doesn't seem to be
;;; worth the risk of trying to optimize this, since this rarely happens and
;;; wastes only space.
;;;
(defun discard-unused-values (block1 block2)
  (declare (type cblock block1 block2))
  (let* ((block1-stack (ir2-block-end-stack (block-info block1)))
	 (block2-stack (ir2-block-start-stack (block-info block2)))
	 (last-popped (elt block1-stack
			   (- (length block1-stack)
			      (length block2-stack)
			      1))))
    (assert (tailp block2-stack block1-stack))

    (let* ((block (insert-cleanup-code block1 block2
				       (continuation-next (block-start block2))
				       `(%pop-values ',last-popped)))
	   (2block (make-ir2-block block)))
      (setf (block-info block) 2block)
      (add-to-emit-order 2block (block-info block1))
      (ltn-analyze-block block)))

  (undefined-value))


;;;; Stack analyze:


;;; FIND-VALUES-GENERATORS  --  Internal
;;;
;;;    Return a list of all the blocks containing genuine uses of one of the
;;; Receivers.  Exits are excluded, since they don't drop through to the
;;; receiver.
;;;
(defun find-values-generators (receivers)
  (declare (list receivers))
  (collect ((res nil adjoin))
    (dolist (rec receivers)
      (dolist (pop (ir2-block-popped (block-info rec)))
	(do-uses (use pop)
	  (unless (exit-p use)
	    (res (node-block use))))))
    (res)))


;;; Stack-Analyze  --  Interface
;;;
;;;    Analyze the use of unknown-values continuations in Component, inserting
;;; cleanup code to discard values that are generated but never received.  This
;;; phase doesn't need to be run when Values-Receivers is null, i.e. there are
;;; no unknown-values continuations used across block boundaries.
;;;
;;;    Do the backward graph walk, starting at each values receiver.  We ignore
;;; receivers that already have a non-null Start-Stack.  These are nested
;;; values receivers that have already been reached on another walk.  We don't
;;; want to clobber that result with our null initial stack. 
;;;
(defun stack-analyze (component)
  (declare (type component component))
  (let* ((2comp (component-info component))
	 (receivers (ir2-component-values-receivers 2comp))
	 (generators (find-values-generators receivers)))

    (dolist (block generators)
      (find-pushed-continuations block))
    
    (dolist (block receivers)
      (unless (ir2-block-start-stack (block-info block))
	(stack-simulation-walk block ())))
    
    (dolist (block generators)
      (annotate-dead-values block))
    
    (do-blocks (block component)
      (let ((top (car (ir2-block-end-stack (block-info block)))))
	(dolist (succ (block-succ block))
	  (when (and (block-start succ)
		     (not (eq (car (ir2-block-start-stack (block-info succ)))
			      top)))
	    (discard-unused-values block succ))))))
  
  (undefined-value))
