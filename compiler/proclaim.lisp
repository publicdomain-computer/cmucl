;;; -*- Package: C; Log: C.Log -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the Spice Lisp project at
;;; Carnegie-Mellon University, and has been placed in the public domain.
;;; If you want to use this code or any part of Spice Lisp, please contact
;;; Scott Fahlman (FAHLMAN@CMUC). 
;;; **********************************************************************
;;;
;;;    This file contains load-time support for declaration processing.  It is
;;; split off from the compiler so that the compiler doesn'thave to be in the
;;; cold load.
;;;
;;; Written by Rob MacLachlan
;;;
(in-package "C")

(in-package "EXTENSIONS")
(export '(inhibit-warnings))
(in-package "LISP")
(export '(declaim proclaim))
(in-package "C")


;;; True if the type system has been properly initialized, and thus is o.k. to
;;; use.
;;;
(defvar *type-system-initialized* nil)

;;; The Cookie holds information about the compilation environment for a node.
;;; See the Node definition for a description of how it is used.
;;;
(defstruct cookie
  (speed nil :type (or (rational 0 3) null))
  (space nil :type (or (rational 0 3) null))
  (safety nil :type (or (rational 0 3) null))
  (cspeed nil :type (or (rational 0 3) null))
  (brevity nil :type (or (rational 0 3) null))
  (debug nil :type (or (rational 0 3) null)))


;;; The *default-cookie* represents the current global compiler policy
;;; information.  Whenever the policy is changed, we copy the structure so that
;;; old uses will still get the old values.
;;;
(proclaim '(type cookie *default-cookie*))
(defvar *default-cookie* (make-cookie :safety 1 :speed 1 :space 1 :cspeed 1
				      :brevity 1 :debug 2))


;;; Parse-Lambda-List  --  Interface
;;;
;;;    Break a lambda-list into its component parts.  We return eight values:
;;;  1] A list of the required args.
;;;  2] A list of the optional arg specs.
;;;  3] True if a rest arg was specified.
;;;  4] The rest arg.
;;;  5] A boolean indicating whether keywords args are present.
;;;  6] A list of the keyword arg specs.
;;;  7] True if &allow-other-keys was specified.
;;;  8] A list of the &aux specifiers.
;;;
;;; The top-level lambda-list syntax is checked for validity, but the arg
;;; specifiers are just passed through untouched.  If something is wrong, we
;;; use Compiler-Error, aborting compilation to the last recovery point.
;;;
;;; [Eventually this should go into the code sources, since it is used in
;;; various random places such as the function type parsing.]
;;;
(proclaim '(function parse-lambda-list (list)
		     (values list list boolean t boolean list boolean list)))
(defun parse-lambda-list (list)
  (collect ((required)
	    (optional)
	    (keys)
	    (aux))
    (let ((restp nil)
	  (rest nil)
	  (keyp nil)
	  (allowp nil)
	  (state :required))
      (dolist (arg list)
	(if (and (symbolp arg)
		 (let ((name (symbol-name arg)))
		   (and (/= (length name) 0)
			(char= (char name 0) #\&))))
	    (case arg
	      (&optional
	       (unless (eq state :required)
		 (compiler-error "Misplaced &optional in lambda-list: ~S." list))
	       (setq state '&optional))
	      (&rest
	       (unless (member state '(:required &optional))
		 (compiler-error "Misplaced &rest in lambda-list: ~S." list))
	       (setq state '&rest))
	      (&key
	       (unless (member state '(:required &optional :post-rest))
		 (compiler-error "Misplaced &key in lambda-list: ~S." list))
	       (setq keyp t)
	       (setq state '&key))
	      (&allow-other-keys
	       (unless (eq state '&key)
		 (compiler-error "Misplaced &allow-other-keys in lambda-list: ~S." list))
	       (setq allowp t  state '&allow-other-keys))
	      (&aux
	       (when (eq state '&rest)
		 (compiler-error "Misplaced &aux in lambda-list: ~S." list))
	       (setq state '&aux))
	      (t
	       (compiler-error "Unknown &keyword in lambda-list: ~S." arg)))
	    (case state
	      (:required (required arg))
	      (&optional (optional arg))
	      (&rest
	       (setq restp t  rest arg  state :post-rest))
	      (&key (keys arg))
	      (&aux (aux arg))
	      (t
	       (compiler-error "Found garbage in lambda-list when expecting a keyword: ~S." arg)))))
    (values (required) (optional) restp rest keyp (keys) allowp (aux)))))


;;; Check-Function-Name  --  Interface
;;;
;;;    Check that Name is a valid function name, returning the name if OK, and
;;; doing an error if not.  In addition to checking for basic well-formedness,
;;; we also check that symbol names are not NIL or the name of a special form.
;;;
(defun check-function-name (name)
  (typecase name
    (list
     (unless (and (consp name) (consp (cdr name))
		  (null (cddr name)) (eq (car name) 'setf)
		  (symbolp (cadr name)))
       (compiler-error "Illegal function name: ~S." name))
     name)
    (symbol
     (when (eq (info function kind name) :special-form)
       (compiler-error "Special form is an illegal function name: ~S." name))
     name)
    (t
     (compiler-error "Illegal function name: ~S." name))))


;;; Define-Function-Name  --  Interface
;;;
;;;    Check the legality of a function name that is being introduced.  If it
;;; names a macro, then give a warning and blast the macro information.
;;;
(proclaim '(function define-function-name (t) void))
(defun define-function-name (name)
  (check-function-name name)
  (ecase (info function kind name)
    (:function)
    (:special-from
     (compiler-error "~S names a special form, so cannot be a function." name))
    (:macro
     (compiler-warning "~S previously defined as a macro." name)
     (setf (info function kind name) :function)
     (setf (info function where-from name) :assumed)
     (clear-info function macro-function name))
    ((nil)
     (setf (info function kind name) :function)))
  name)


;;; Process-Optimize-Declaration  --  Interface
;;;
;;;    Return a new cookie containing the policy information represented by the
;;; optimize declaration Spec.  Any parameters not specified are defaulted from
;;; Cookie.
;;;
(proclaim '(function process-optimize-declaration (list cookie) cookie))
(defun process-optimize-declaration (spec cookie)
  (let ((res (copy-cookie cookie)))
    (dolist (quality (cdr spec))
      (let ((quality (if (atom quality) (list quality 3) quality)))
	(if (and (consp (cdr quality)) (null (cddr quality))
		 (typep (second quality) 'real) (<= 0 (second quality) 3))
	    (let ((value (rational (second quality))))
	      (case (first quality)
		(speed (setf (cookie-speed res) value))
		(space (setf (cookie-space res) value))
		(safety (setf (cookie-safety res) value))
		(compilation-speed (setf (cookie-cspeed res) value))
		((inhibit-warnings brevity) (setf (cookie-brevity res) value))
		(debug-info (setf (cookie-debug res) value))
		(t
		 (compiler-warning "Unknown optimization quality ~S in ~S."
				   (car quality) spec))))
	    (compiler-warning
	     "Malformed optimization quality specifier ~S in ~S."
	     quality spec))))
    res))


;;; DECLAIM  --  Public
;;;
;;;    For now, just PROCLAIM without any EVAL-WHEN.
;;;
(defmacro declaim (&rest specs)
  "DECLAIM Declaration*
  Do a declaration for the global environment."
  `(progn ,@(mapcar #'(lambda (x)
			`(proclaim ',x))
		    specs)))
  

;;; %Proclaim  --  Interface
;;;
;;;    This function is the guts of proclaim, since it does the global
;;; environment updating.
;;;
(defun %proclaim (form)
  (unless (consp form)
    (error "Malformed PROCLAIM spec: ~S." form))
  
  (let ((kind (first form))
	(args (rest form)))
    (case kind
      (special
       (dolist (name args)
	 (unless (symbolp name)
	   (error "Variable name is not a symbol: ~S." name))
	 (clear-info variable constant-value name)
	 (setf (info variable kind name) :special)))
      (type
       (when *type-system-initialized*
	 (let ((type (specifier-type (first args))))
	   (dolist (name (rest args))
	     (unless (symbolp name)
	       (error "Variable name is not a symbol: ~S." name))
	     (setf (info variable type name) type)
	     (setf (info variable where-from name) :declared)))))
      (ftype
       (when *type-system-initialized*
	 (let ((type (specifier-type (first args))))
	   (unless (csubtypep type (specifier-type 'function))
	     (error "Declared functional type is not a function type: ~S."
		    (first args)))
	   (dolist (name (rest args))
	     (define-function-name name)
	     (setf (info function type name) type)
	     (setf (info function where-from name) :declared)))))
      (function
       (when *type-system-initialized*
	 (%proclaim `(ftype (function . ,(rest args)) ,(first args)))))
      (optimize
       (setq *default-cookie*
	     (process-optimize-declaration form *default-cookie*)))
      ((inline notinline maybe-inline)
       (dolist (name args)
	 (define-function-name name)
	 (setf (info function inlinep name)
	       (case kind
		 (inline :inline)
		 (notinline :notinline)
		 (maybe-inline :maybe-inline)))))
      (declaration
       (dolist (decl args)
	 (unless (symbolp decl)
	   (error "Declaration to be RECOGNIZED is not a symbol: ~S." decl))
	 (setf (info declaration recognized decl) t)))
      (t
       (if (member kind type-specifier-symbols)
	   (%proclaim `(type . ,form))
	   (error "Unrecognized proclamation: ~S." form)))))
  (undefined-value))
;;;
(setf (symbol-function 'proclaim) #'%proclaim)


;;; %%Compiler-Defstruct  --  Interface
;;;
;;;    This function updates the global compiler information to represent the
;;; definition of the the structure described by Info.
;;;
(defun %%compiler-defstruct (info)
  (declare (type defstruct-description info))

  (let ((name (dd-name info)))
    (dolist (inc (dd-includes info))
      (let ((info (info type structure-info inc)))
	(unless info
	  (error "Structure type ~S is included by ~S but not defined."
		 inc name))
	(pushnew name (dd-included-by info))))

    (let ((old (info type structure-info name)))
      (when old
	(setf (dd-included-by info) (dd-included-by old))))

    (setf (info type kind name) :structure)
    (setf (info type structure-info name) info)
    (when (info type expander name)
      (setf (info type expander name) nil))
    (%note-type-defined name))

  ;;; ### Should declare arg/result types. 
  (let ((copier (dd-copier info)))
    (when copier
      (define-function-name copier)
      (setf (info function where-from copier) :defined)))

  ;;; ### Should make a known type predicate.
  (let ((predicate (dd-predicate info)))
    (when predicate
      (define-function-name predicate)
      (setf (info function where-from predicate) :defined)))

  (dolist (slot (dd-slots info))
    (let ((fun (dsd-accessor slot)))
      (define-function-name fun)
      (setf (info function accessor-for fun) info)
      ;;
      ;; ### Bootstrap hack...
      ;; This blows away any inverse that has been loaded into the bootstrap
      ;; environment.  Probably this should be more general (expanders, etc.),
      ;; and also perhaps done on other functions.
      (when (info setf inverse fun)
	(setf (info setf inverse fun) nil))
      
      (unless (dsd-read-only slot)
	(setf (info function accessor-for `(setf ,fun)) info))))
  (undefined-value))

(setf (symbol-function '%compiler-defstruct) #'%%compiler-defstruct)


;;; %NOTE-TYPE-DEFINED  --  Interface
;;;
;;;    Note that the type Name has been (re)defined, updating the undefined
;;; warnings and VALUES-SPECIFIER-TYPE cache.
;;; 
(defun %note-type-defined (name)
  (declare (symbol name))
  (when (boundp '*undefined-warnings*)
    (note-name-defined name :type))
  (when (boundp '*values-specifier-type-cache-vector*)
    (values-specifier-type-cache-clear))
  (undefined-value))


;;;; Dummy definitions of COMPILER-ERROR, etc.
;;;
;;;    Until the compiler is properly loaded, we make the compiler error
;;; functions synonyms for the obvious standard error function.
;;;

(defun compiler-error (string &rest args)
  (apply #'error string args))

(defun compiler-warning (string &rest args)
  (apply #'warn string args))

(defun compiler-note (string &rest args)
  (apply #'warn string args))

(defun compiler-error-message (string &rest args)
  (apply #'warn string args))


;;; Alien=>Lisp-Transform  --  Internal
;;;
;;;    This is the transform for alien-operators and other alien-valued
;;; things which may be evaluated normally to yield an alien-value structure.
;;;
(defun alien=>lisp-transform (form)
  (multiple-value-bind (binds stuff res)
		       (analyze-alien-expression nil form)
    `(let* ,(reverse binds)
       ,(ignore-unreferenced-vars binds)
       ,@(nreverse stuff)
       ,(if (ct-a-val-alien res)
	    (ct-a-val-alien res)
	    `(lisp::make-alien-value
	      ,(ct-a-val-sap res)
	      ,(ct-a-val-offset res)
	      ,(ct-a-val-size res)
	      ',(ct-a-val-type res))))))
