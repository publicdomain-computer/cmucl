;;;-*-Mode:LISP; Package: PCL; Base:10; Syntax:Common-lisp -*-
;;;
;;; *************************************************************************
;;; Copyright (c) 1985, 1986, 1987, 1988, 1989, 1990 Xerox Corporation.
;;; All rights reserved.
;;;
;;; Use and copying of this software and preparation of derivative works
;;; based upon this software are permitted.  Any distribution of this
;;; software or derivative works must comply with all applicable United
;;; States export control laws.
;;; 
;;; This software is made available AS IS, and Xerox Corporation makes no
;;; warranty about the software, its performance or its conformity to any
;;; specification.
;;; 
;;; Any person obtaining a copy of this software is requested to send their
;;; name and post office or electronic mail address to:
;;;   CommonLoops Coordinator
;;;   Xerox PARC
;;;   3333 Coyote Hill Rd.
;;;   Palo Alto, CA 94304
;;; (or send Arpanet mail to CommonLoops-Coordinator.pa@Xerox.arpa)
;;;
;;; Suggestions, comments and requests for improvements are also welcome.
;;; *************************************************************************

(ext:file-comment
  "$Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/pcl/combin.lisp,v 1.14 2003/03/22 16:15:17 gerd Exp $")

(in-package "PCL")

;;;
;;; In the following:
;;;
;;; Something "callable" is either a function, a FAST-METHOD-CALL or
;;; a METHOD-CALL instance, which can all be "invoked" by PCL.
;;;
;;; A generator for a "callable" is a function (closure) taking two
;;; arguments METHOD-ALIST and WRAPPERS and returning a callable.
;;; 


;;; *********************************************
;;; The STANDARD method combination type  *******
;;; *********************************************
;;;
;;; This is coded by hand (rather than with DEFINE-METHOD-COMBINATION)
;;; for bootstrapping and efficiency reasons.  Note that the
;;; definition of the find-method-combination-method appears in the
;;; file defcombin.lisp, this is because EQL methods can't appear in
;;; the bootstrap.
;;;
;;; This code must conform to the code in the file defcombin, look
;;; there for more details.
;;;

;;;
;;; When adding a method to COMPUTE-EFFECTIVE-METHOD for the standard
;;; method combination, COMPUTE-EFFECTIVE-METHOD is called for
;;; determining the effective method of COMPUTE-EFFECTIVE-METHOD.
;;; That's a chicken and egg problem.  It's solved in dfun.lisp by
;;; always calling STANDARD-COMPUTE-EFFECTIVE-METHOD for the case of
;;; COMPUTE-EFFECTIVE-METHOD.
;;;
;;; A similar problem occurs with all generic functions used to compute
;;; an effective method.  For example, if a method for METHOD-QUALIFIERS
;;; is performed, the generic function METHOD-QUALIFIERS will be called,
;;; and it's not ready for use.
;;;
;;; That's actually the well-known meta-circularity of PCL.
;;;
;;; Can we use an existing definition in the compiling PCL, if any,
;;; until the effective method is ready?
;;;
#+loadable-pcl
(defmethod compute-effective-method ((gf generic-function)
				     (combin standard-method-combination)
				     applicable-methods)
  (standard-compute-effective-method gf combin applicable-methods))
  
#-loadable-pcl
(defun compute-effective-method (gf combin applicable-methods)
  (standard-compute-effective-method gf combin applicable-methods))

(defun standard-compute-effective-method (gf combin applicable-methods)
  (declare (ignore combin))
  (let ((before ())
	(primary ())
	(after ())
	(around ()))
    (flet ((lose (method why)
	     (invalid-method-error
	      method
	      "~@<The method ~S ~A.  ~
               Standard method combination requires all methods to have one ~
               of the single qualifiers ~s, ~s and ~s or to have no qualifier ~
               at all.~@:>"
	      method why :around :before :after)))
      (dolist (m applicable-methods)
	(let ((qualifiers (if (listp m)
			      (early-method-qualifiers m)
			      (method-qualifiers m))))
	  (cond ((null qualifiers)
		 (push m primary))
		((cdr qualifiers)
		 (lose m "has more than one qualifier"))
		((eq (car qualifiers) :around)
		 (push m around))
		((eq (car qualifiers) :before)
		 (push m before))
		((eq (car qualifiers) :after)
		 (push m after))
		(t
		 (lose m "has an illegal qualifier"))))))
    (setq before  (reverse before)
	  after   (reverse after)
	  primary (reverse primary)
	  around  (reverse around))
    (cond ((null primary)
	   `(%no-primary-method ',gf .args.))
	  ((and (null before) (null after) (null around))
	   ;;
	   ;; By returning a single CALL-METHOD form here, we enable an
	   ;; important implementation-specific optimization.
	   `(call-method ,(first primary) ,(rest primary)))
	  (t
	   (let ((main-effective-method
		   (if (or before after)
		       `(multiple-value-prog1
			  (progn
			    ,(make-call-methods before)
			    (call-method ,(first primary) ,(rest primary)))
			  ,(make-call-methods (reverse after)))
		       `(call-method ,(first primary) ,(rest primary)))))
	     (if around
		 `(call-method ,(first around)
			       (,@(rest around)
				  (make-method ,main-effective-method)))
		 main-effective-method))))))

(defvar *invalid-method-error*
	(lambda (&rest args)
	  (declare (ignore args))
	  (error
	   "~@<~s was called outside the dynamic scope ~
            of a method combination function (inside the body of ~
            ~s or a method on the generic function ~s).~@:>"
	   'invalid-method-error 'define-method-combination
	   'compute-effective-method)))

(defvar *method-combination-error*
	(lambda (&rest args)
	  (declare (ignore args))
	  (error
	   "~@<~s was called outside the dynamic scope ~
            of a method combination function (inside the body of ~
            ~s or a method on the generic function ~s).~@:>"
	   'method-combination-error 'define-method-combination
	   'compute-effective-method)))

(defun invalid-method-error (&rest args)
  (apply *invalid-method-error* args))

(defun method-combination-error (&rest args)
  (apply *method-combination-error* args))

(defmacro call-method (&rest args)
  (declare (ignore args))
  `(error "~@<~S used outsize of a effective method form.~@:>" 'call-method))

(defmacro call-method-list (&rest calls)
  `(progn ,@calls))

(defun make-call-methods (methods)
  `(call-method-list
    ,@(mapcar (lambda (method) `(call-method ,method ())) methods)))


;;; ****************************************************
;;; Translating effective method bodies to Code  *******
;;; ****************************************************

(defun get-callable (gf form method-alist wrappers)
  (funcall (callable-generator gf form method-alist wrappers)
	   method-alist wrappers))

(defun callable-generator (gf form method-alist-p wrappers-p)
  (if (eq 'call-method (car-safe form))
      (callable-generator-for-call-method gf form)
      (callable-generator-for-emf gf form method-alist-p wrappers-p)))

;;;
;;; If the effective method is just a call to CALL-METHOD, this opens
;;; up the possibility of just using the method function of the method
;;; as the effective method function.
;;;
;;; But we have to be careful.  If that method function will ask for
;;; the next methods we have to provide them.  We do not look to see
;;; if there are next methods, we look at whether the method function
;;; asks about them.  If it does, we must tell it whether there are
;;; or aren't to prevent the leaky next methods bug.
;;; 
(defun callable-generator-for-call-method (gf form)
  (let* ((cm-args (cdr form))
	 (fmf-p (and (or (not (eq *boot-state* 'complete))
			 (gf-fast-method-function-p gf))
		     (null (cddr cm-args))))
	 (method (car cm-args))
	 (cm-args1 (cdr cm-args)))
    (lambda (method-alist wrappers)
      (callable-for-call-method gf method cm-args1 fmf-p method-alist
				wrappers))))

(defun callable-for-call-method (gf method cm-args fmf-p method-alist wrappers)
  (cond ((null method)
	 nil)
	((if (listp method)
	     (eq (car method) :early-method)
	     (method-p method))
	 (get-method-callable method cm-args gf fmf-p method-alist wrappers))
	((eq 'make-method (car-safe method))
	 (get-callable gf (cadr method) method-alist wrappers))
	(t
	 method)))

;;;
;;; Return a FAST-METHOD-CALL structure, a METHOD-CALL structure, or a
;;; method function for calling METHOD.
;;;
(defun get-method-callable (method cm-args gf fmf-p method-alist wrappers)
  (multiple-value-bind (mf real-mf-p fmf pv-cell)
      (get-method-function method method-alist wrappers)
    (cond (fmf
	   (let* ((next-methods (car cm-args))
		  (next (callable-for-call-method gf (car next-methods)
						  (list* (cdr next-methods)
							 (cdr cm-args))
						  fmf-p method-alist wrappers))
		  (arg-info (method-function-get fmf :arg-info)))
	     (make-fast-method-call :function fmf
				    :pv-cell pv-cell
				    :next-method-call next
				    :arg-info arg-info)))
	  (real-mf-p
	   (make-method-call :function mf :call-method-args cm-args))
	  (t mf))))

(defun get-method-function (method method-alist wrappers)
  (let ((fn (cadr (assoc method method-alist))))
    (if fn
	(values fn nil nil nil)
	(multiple-value-bind (mf fmf)
	    (if (listp method)
		(early-method-function method)
		(values nil (method-fast-function method)))
	  (let ((pv-table (and fmf (method-function-pv-table fmf))))
	    (if (and fmf
		     (not (and pv-table (pv-table-computing-cache-p pv-table)))
		     (or (null pv-table) wrappers))
		(let* ((pv-wrappers (when pv-table 
				      (pv-wrappers-from-all-wrappers
				       pv-table wrappers)))
		       (pv-cell (when (and pv-table pv-wrappers)
				  (pv-table-lookup pv-table pv-wrappers))))
		  (values mf t fmf pv-cell))
		(values 
		 (or mf (if (listp method)
			    (setf (cadr method)
				  (method-function-from-fast-function fmf))
			    (method-function method)))
		 t nil nil)))))))


;;;
;;; Return a closure returning a FAST-METHOD-CALL instance for the
;;; call of the effective method of generic function GF with body
;;; BODY.
;;;
(defun callable-generator-for-emf (gf body method-alist-p wrappers-p)
  (multiple-value-bind (nreq applyp metatypes nkeys arg-info)
      (get-generic-function-info gf)
    (declare (ignore nkeys arg-info))
    (let* ((name (if (early-gf-p gf)
		     (early-gf-name gf)
		     (generic-function-name gf)))
	   (arg-info (cons nreq applyp))
	   (effective-method-lambda (make-effective-method-lambda gf body)))
      (multiple-value-bind (cfunction constants)
	  (get-function1 effective-method-lambda
			 (lambda (form)
			   (memf-test-converter form gf method-alist-p
						wrappers-p))
			 (lambda (form)
			   (memf-code-converter form gf metatypes applyp
						method-alist-p wrappers-p))
			 (lambda (form)
			   (memf-constant-converter form gf)))
	(lambda (method-alist wrappers)
	  (let* ((constants 
		  (mapcar (lambda (constant)
			    (case (car-safe constant)
			      (.meth.
			       (funcall (cdr constant) method-alist wrappers))
			      (.meth-list.
			       (mapcar (lambda (fn)
					 (funcall fn method-alist wrappers))
				       (cdr constant)))
			      (t constant)))
			  constants))
		 (function (set-function-name (apply cfunction constants)
					      `(effective-method ,name))))
	    (make-fast-method-call :function function
				   :arg-info arg-info)))))))

;;;
;;; Return a lambda-form for an effective method of generic function
;;; GF with body BODY.
;;;
(defun make-effective-method-lambda (gf body)
  (multiple-value-bind (nreq applyp metatypes nkeys arg-info)
      (get-generic-function-info gf)
    (declare (ignore nreq nkeys arg-info))
    (let ((ll (make-fast-method-call-lambda-list metatypes applyp))
	  (error-p (eq (first body) '%no-primary-method))
	  (mc-args-p
	   (when (eq *boot-state* 'complete)
	     ;; Otherwise the METHOD-COMBINATION slot is not bound.
	     (let ((combin (generic-function-method-combination gf)))
	       (and (long-method-combination-p combin)
		    (long-method-combination-args-lambda-list combin))))))
      (cond (error-p
	     `(lambda (.pv-cell. .next-method-call. &rest .args.)
		(declare (ignore .pv-cell. .next-method-call.))
		,body))
	    (mc-args-p
	     (let* ((required (dfun-arg-symbol-list metatypes))
		    (gf-args (if applyp
				 `(list* ,@required .dfun-rest-arg.)
				 `(list ,@required))))
	       `(lambda ,ll
		  (declare (ignore .pv-cell. .next-method-call.))
		  (let ((.gf-args. ,gf-args))
		    (declare (ignorable .gf-args.))
		    ,body))))
	    (t
	     `(lambda ,ll
		(declare (ignore .pv-cell. .next-method-call.))
		,body))))))

(defun memf-test-converter (form gf method-alist-p wrappers-p)
  (case (car-safe form)
    (call-method
     (case (get-method-call-type gf form method-alist-p wrappers-p)
       (fast-method-call '.fast-call-method.)
       (t '.call-method.)))
    (call-method-list
     (case (get-method-list-call-type gf form method-alist-p wrappers-p)
       (fast-method-call '.fast-call-method-list.)
       (t '.call-method-list.)))
    (t
     (default-test-converter form))))

(defun memf-code-converter (form gf metatypes applyp method-alist-p
			    wrappers-p)
  (case (car-safe form)
    (call-method
     (let ((gensym (gensym "MEMF")))
       (values (make-emf-call metatypes applyp gensym
			      (get-method-call-type gf form method-alist-p
						    wrappers-p))
	       (list gensym))))
    (call-method-list
     (let ((gensym (gensym "MEMF"))
	   (type (get-method-list-call-type gf form method-alist-p
					    wrappers-p)))
       (values `(dolist (emf ,gensym nil)
		  ,(make-emf-call metatypes applyp 'emf type))
	       (list gensym))))
    (t
     (default-code-converter form))))

(defun memf-constant-converter (form gf)
  (case (car-safe form)
    (call-method
     (list (cons '.meth.
		 (callable-generator-for-call-method gf form))))
    (call-method-list
     (list (cons '.meth-list.
		 (mapcar (lambda (form)
			   (callable-generator-for-call-method gf form))
			 (cdr form)))))
    (t
     (default-constant-converter form))))

(defun get-method-list-call-type (gf form method-alist-p wrappers-p)
  (if (every (lambda (form)
	       (eq 'fast-method-call
		   (get-method-call-type gf form method-alist-p wrappers-p)))
	     (cdr form))
      'fast-method-call
      t))

(defun get-method-call-type (gf form method-alist-p wrappers-p)
  (if (eq 'call-method (car-safe form))
      (destructuring-bind (method &rest cm-args) (cdr form)
	(declare (ignore cm-args))
	(when method
	  (if (if (listp method)
		  (eq (car method) :early-method)
		  (method-p method))
	      (if method-alist-p
		  t
		  (multiple-value-bind (mf fmf)
		      (if (listp method)
			  (early-method-function method)
			  (values nil (method-fast-function method)))
		    (declare (ignore mf))
		    (let ((pv-table (and fmf (method-function-pv-table fmf))))
		      (if (and fmf (or (null pv-table) wrappers-p))
			  'fast-method-call
			  'method-call))))
	      (if (eq 'make-method (car-safe method))
		  (get-method-call-type gf (cadr method) method-alist-p
					wrappers-p)
		  (type-of method)))))
      'fast-method-call))


;;; **************************************
;;; Generating Callables for EMFs  *******
;;; **************************************

;;;
;;; Turned off until problems with method tracing caused by it are
;;; solved (reason unknown).  Will be needed once inlining of methods
;;; in effective methods and inlining of effective method in callers
;;; gets accute.
;;; 
(defvar *named-emfs-p* nil)

;;;
;;; Return a callable object for an emf of generic function GF, with
;;; applicable methods METHODS.  GENERATOR is a function returned from
;;; CALLABLE-GENERATOR.  Call it with two args METHOD-ALIST and
;;; WRAPPERS to obtain the actual callable.
;;;
(defun make-callable (gf methods generator method-alist wrappers)
  (let ((callable (function-funcall generator method-alist wrappers)))
    (set-emf-name gf methods callable)))

;;;
;;; When *NAME-EMFS-P* is true, give the effective method represented
;;; by CALLABLE a suitable global name of the form (EFFECTIVE-METHOD
;;; ...).  GF is the generic function the effective method is for, and
;;; METHODS is the list of applicable methods.
;;;
(defun set-emf-name (gf methods callable)
  (when *named-emfs-p*
    (let ((function (typecase callable
		      (fast-method-call (fast-method-call-function callable))
		      (method-call (method-call-function callable))
		      (t callable)))
	  (name (make-emf-name gf methods)))
      (setf (fdefinition name) function)
      (set-function-name function name)))
  callable)

;;;
;;; Return a name for an effective method of generic function GF,
;;; composed of applicable methods METHODS.
;;;
;;; In general, the name cannot be based on the methods alone, because
;;; that doesn't take method combination arguments into account.
;;;
;;; It is possible to do better for the standard method combination,
;;; though.  The current name format is
;;;
;;;  (EFFECTIVE-METHOD gf-name around-methods before-methods
;;;       primary-method after-methods)
;;;
;;; where each method is a list (METHOD qualifiers specializers).
;;;
(defvar *emf-name-table* (make-hash-table :test 'equal))

(defun make-emf-name (gf methods)
  (let* ((early-p (early-gf-p gf))
	 (gf-name (if early-p
		     (early-gf-name gf)
		     (generic-function-name gf)))
	 (emf-name
	  (if (or early-p
		  (eq (generic-function-method-combination gf)
		      *standard-method-combination*))
	      (let (primary around before after)
		(dolist (m methods)
		  (let ((qual (if early-p
				  (early-method-qualifiers m)
				  (method-qualifiers m)))
			(specl (if early-p
				   (early-method-specializers m)
				   (unparse-specializers
				    (method-specializers m)))))
		    (case (car-safe qual)
		      (:around (push `(method :around ,specl) around))
		      (:before (push `(method :before ,specl) before))
		      (:after (push `(method :after ,specl) after))
		      (t (push `(method ,specl) primary)))))
		`(effective-method ,gf-name
				   ,@(nreverse around)
				   ,@(nreverse before)
				   ,@(list (last primary))
				   ,@after))
	      `(effective-method ,gf-name ,(gensym)))))
    (or (gethash emf-name *emf-name-table*)
	(setf (gethash emf-name *emf-name-table*) emf-name))))

;;; end of combin.lisp
