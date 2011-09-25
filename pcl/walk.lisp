;;;-*- Mode:LISP; Package:WALKER -*-
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
;;;

(file-comment
  "$Header: src/pcl/walk.lisp $")
;;;
;;; A simple code walker, based IN PART on: (roll the credits)
;;;   Larry Masinter's Masterscope
;;;   Moon's Common Lisp code walker
;;;   Gary Drescher's code walker
;;;   Larry Masinter's simple code walker
;;;   .
;;;   .
;;;   boy, thats fair (I hope).
;;;
;;; For now at least, this code walker really only does what PCL needs it to
;;; do.  Maybe it will grow up someday.
;;;

;;;
;;; This code walker used to be completely portable.  Now it is just "Real
;;; easy to port".  This change had to happen because the hack that made it
;;; completely portable kept breaking in different releases of different
;;; Common Lisps, and in addition it never worked entirely anyways.  So,
;;; its now easy to port.  To port this walker, all you have to write is one
;;; simple macro and two simple functions.  These macros and functions are
;;; used by the walker to manipluate the macroexpansion environments of
;;; the Common Lisp it is running in.
;;;
;;; The code which implements the macroexpansion environment manipulation
;;; mechanisms is in the first part of the file, the real walker follows it.
;;; 

(in-package :walker)
(intl:textdomain "cmucl")

;;;
;;; The user entry points are walk-form and nested-walked-form.  In addition,
;;; it is legal for user code to call the variable information functions:
;;; variable-lexical-p, variable-special-p and variable-class.  Some users
;;; will need to call define-walker-template, they will have to figure that
;;; out for themselves.
;;; 
(export '(define-walker-template
	  walk-form
	  walk-form-expand-macros-p
	  nested-walk-form
	  variable-lexical-p
	  variable-special-p
	  variable-globally-special-p
	  *variable-declarations*
	  variable-declaration
	  macroexpand-all
	  ))



;;;
;;; On the following pages are implementations of the implementation specific
;;; environment hacking functions for each of the implementations this walker
;;; has been ported to.  If you add a new one, so this walker can run in a new
;;; implementation of Common Lisp, please send the changes back to us so that
;;; others can also use this walker in that implementation of Common Lisp.
;;;
;;; This code just hacks 'macroexpansion environments'.  That is, it is only
;;; concerned with the function binding of symbols in the environment.  The
;;; walker needs to be able to tell if the symbol names a lexical macro or
;;; function, and it needs to be able to build environments which contain
;;; lexical macro or function bindings.  It must be able, when walking a
;;; macrolet, flet or labels form to construct an environment which reflects
;;; the bindings created by that form.  Note that the environment created
;;; does NOT have to be sufficient to evaluate the body, merely to walk its
;;; body.  This means that definitions do not have to be supplied for lexical
;;; functions, only the fact that that function is bound is important.  For
;;; macros, the macroexpansion function must be supplied.
;;;
;;; This code is organized in a way that lets it work in implementations that
;;; stack cons their environments.  That is reflected in the fact that the
;;; only operation that lets a user build a new environment is a with-body
;;; macro which executes its body with the specified symbol bound to the new
;;; environment.  No code in this walker or in PCL will hold a pointer to
;;; these environments after the body returns.  Other user code is free to do
;;; so in implementations where it works, but that code is not considered
;;; portable.
;;;
;;; There are 3 environment hacking tools.  One macro which is used for
;;; creating new environments, and two functions which are used to access the
;;; bindings of existing environments.
;;;
;;; WITH-AUGMENTED-ENVIRONMENT
;;;
;;; ENVIRONMENT-FUNCTION
;;;
;;; ENVIRONMENT-MACRO
;;; 

(defun unbound-lexical-function (&rest args)
  (declare (ignore args))
  (error _"~@<The evaluator was called to evaluate a form in a macroexpansion ~
          environment constructed by the PCL portable code walker.  These ~
          environments are only useful for macroexpansion, they cannot be ~
          used for evaluation.  ~
          This error should never occur when using PCL.  ~
          This most likely source of this error is a program which tries to ~
          to use the PCL portable code walker to build its own evaluator.~@:>"))




;;;; CMU Common Lisp version of environment frobbing stuff.

;;; In CMU Common Lisp, the environment is represented with a structure
;;; that holds alists for the functional things, variables, blocks, etc.
;;; Except for symbol-macrolet, only the c::lexenv-functions slot is
;;; relevent.  It holds:
;;; Alist (name . what), where What is either a Functional (a local function)
;;; or a list (MACRO . <function>) (a local macro, with the specifier
;;; expander.)    Note that Name may be a (SETF <name>) function.

;;; If WITH-AUGMENTED-ENVIRONMENT is called from WALKER-ENVIRONMENT-BIND
;;; this code hides the WALKER version of an environment
;;; inside the C::LEXENV structure. It makes a list of lists of form
;;; (<gensym-name> MACRO . #<interpreted-function>) which makes up
;;; the :functions slot in a c::lexenv. This seems to be a form that
;;; the compiler guts will accept as valid and otherwise ignore it.
;;; The <interpreted-function> is used as a structure to hold the
;;; bits of interest, {function, form, declarations, lexical-variables}.
;;; and is otherwise not a valid interpreted-function, eg describe will
;;; barf on it. Accessors are defined below, eg (env-walk-function env)
;;;
;;; MACROEXPAND-1 is the only cmucl function that gets called with the
;;; constructed environment argument.

(defmacro with-augmented-environment
	  ((new-env old-env &key functions macros) &body body)
  `(let ((,new-env (with-augmented-environment-internal ,old-env
							,functions
							,macros)))
     ,@body))

(defvar *key-to-walker-environment*) ; Initialized below.

(defun with-augmented-environment-internal (env functions macros)
  ;; Note: In order to record the correct function definition, we would
  ;; have to create an interpreted closure, but the with-new-definition
  ;; macro down below makes no distinction between flet and labels, so
  ;; we have no idea what to use for the environment.  So we just blow it
  ;; off, 'cause anything real we do would be wrong.  We still have to
  ;; make an entry so we can tell functions from macros.

  (let* ((env (or env (c::make-null-environment)))
	 (tem (first macros))
	 ;; A symbol-macro spec suitable for macroexpand-1
	 (variables (when (eql (first tem) *key-to-walker-environment*)
		      (copy-list (fourth (cadr tem))))))
    (c::make-lexenv 
      :default env
      :variables variables
      :functions
      (append (mapcar (lambda (f)
			(cons (car f) (c::make-functional :lexenv env)))
		      functions)
	      (mapcar (lambda (m)
			(list* (car m) 'c::macro
			       (coerce (cadr m) 'function)))
		      macros)))))

(defun environment-function (env fn)
  (when env
    (flet ((test (x y)
	     (or (equal x y)
		 (and (consp y)
		      (member (car y) '(flet labels))
		      (equal x (cadr y))))))
      (let ((entry (assoc fn (c::lexenv-functions env) :test #'test)))
	(and entry
	     (c::functional-p (cdr entry))
	     (cdr entry))))))

(defun environment-macro (env macro)
  (when env
    (let ((entry (assoc macro (c::lexenv-functions env) :test #'eq)))
      (and entry 
	   (eq (cadr entry) 'c::macro)
	   (values (function-lambda-expression (cddr entry)))))))

;;; End of CMUCL specific environment hacking.


(defmacro with-new-definition-in-environment
	  ((new-env old-env macrolet/flet/labels-form) &body body)
  (let ((functions (make-symbol "Functions"))
	(macros (make-symbol "Macros")))
    `(let ((,functions ())
	   (,macros ()))
       (ecase (car ,macrolet/flet/labels-form)
	 ((flet labels)
	  (dolist (fn (cadr ,macrolet/flet/labels-form))
	    (push fn ,functions)))
	 ((macrolet)
	  (dolist (mac (cadr ,macrolet/flet/labels-form))
	    (push (list (car mac)
			(convert-macro-to-lambda ,old-env (cadr mac)
						 (cddr mac)
						 (string (car mac))))
		  ,macros))))
       (with-augmented-environment
	      (,new-env ,old-env :functions ,functions :macros ,macros)
	 ,@body))))

(defun eval-in-environment (form env)
  (eval:internal-eval (macroexpand form env) t env))

(defun convert-macro-to-lambda (env llist body &optional (name "dummy"))
  (let ((gensym (make-symbol name)))
    (eval-in-environment `(defmacro ,gensym ,llist ,@body)
			 (c::make-macrolet-environment env))
    (macro-function gensym)))


;;;
;;; Now comes the real walker.
;;;
;;; As the walker walks over the code, it communicates information to itself
;;; about the walk.  This information includes the walk function, variable
;;; bindings, declarations in effect etc.  This information is inherently
;;; lexical, so the walker passes it around in the actual environment the
;;; walker passes to macroexpansion functions.  This is what makes the
;;; nested-walk-form facility work properly.
;;;
(defmacro walker-environment-bind ((var env &rest key-args)
				      &body body)
  `(with-augmented-environment
     (,var ,env :macros (walker-environment-bind-1 ,env ,.key-args))
     .,body))

(defvar *key-to-walker-environment* (gensym))

(defun env-lock (env)
  (environment-macro env *key-to-walker-environment*))

(defun walker-environment-bind-1 (env &key (walk-function nil wfnp)
					   (walk-form nil wfop)
					   (declarations nil decp)
					   (lexical-variables nil lexp))
  (let ((lock (environment-macro env *key-to-walker-environment*)))
    (list
      (list *key-to-walker-environment*
	    (list (if wfnp walk-function     (car lock))
		  (if wfop walk-form         (cadr lock))
		  (if decp declarations      (caddr lock))
		  (if lexp lexical-variables (cadddr lock)))))))
		  
(defun env-walk-function (env)
  (car (env-lock env)))

(defun env-walk-form (env)
  (cadr (env-lock env)))

(defun env-declarations (env)
  (caddr (env-lock env)))

(defun env-lexical-variables (env)
  (cadddr (env-lock env)))


(defun note-declaration (declaration env)
  (push declaration (caddr (env-lock env))))

(defun note-lexical-binding (thing env)
  (push (list thing :lexical-var) (cadddr (env-lock env))))


(defun VARIABLE-LEXICAL-P (var env)
  (let ((entry (member var (env-lexical-variables env) :key #'car)))
    (when (eq (cadar entry) :lexical-var)
      entry)))

(defun variable-symbol-macro-p (var env)
  (let ((entry (member var (env-lexical-variables env) :key #'car)))
    (when (eq (cadar entry) 'c::macro)
      entry)))


(defvar *VARIABLE-DECLARATIONS* '(special))

(defun variable-declaration (declaration var env)
  (if (not (member declaration *variable-declarations*))
      (error _"~@<~S is not a recognized variable declaration.~@:>" declaration)
      (let ((id (or (variable-lexical-p var env) var)))
	(dolist (decl (env-declarations env))
	  (when (and (eq (car decl) declaration)
		     (eq (cadr decl) id))
	    (return decl))))))

(defun variable-special-p (var env)
  (or (not (null (variable-declaration 'special var env)))
      (variable-globally-special-p var)))

;;;
;;; VARIABLE-GLOBALLY-SPECIAL-P is used to ask if a variable has been
;;; declared globally special.  Any particular CommonLisp implementation
;;; should customize this function accordingly and send their customization
;;; back.
;;;
;;; The default version of variable-globally-special-p is probably pretty
;;; slow, so it uses *globally-special-variables* as a cache to remember
;;; variables that it has already figured out are globally special.
;;;
;;; This would need to be reworked if an unspecial declaration got added to
;;; Common Lisp.
;;;
;;; Common Lisp nit:
;;;   variable-globally-special-p should be defined in Common Lisp.
;;;

(defun variable-globally-special-p (symbol)
  (eq (info variable kind symbol) :special))


  ;;   
;;;;;; Handling of special forms (the infamous 24).
  ;;
;;;
;;; and I quote...
;;; 
;;;     The set of special forms is purposely kept very small because
;;;     any program analyzing program (read code walker) must have
;;;     special knowledge about every type of special form. Such a
;;;     program needs no special knowledge about macros...
;;;
;;; So all we have to do here is a define a way to store and retrieve
;;; templates which describe how to walk the 24 special forms and we are all
;;; set...
;;;
;;; Well, its a nice concept, and I have to admit to being naive enough that
;;; I believed it for a while, but not everyone takes having only 24 special
;;; forms as seriously as might be nice.  There are (at least) 3 ways to
;;; lose:
;;
;;;   1 - Implementation x implements a Common Lisp special form as a macro
;;;       which expands into a special form which:
;;;         - Is a common lisp special form (not likely)
;;;         - Is not a common lisp special form (on the 3600 IF --> COND).
;;;
;;;     * We can safe ourselves from this case (second subcase really) by
;;;       checking to see if there is a template defined for something
;;;       before we check to see if we we can macroexpand it.
;;;
;;;   2 - Implementation x implements a Common Lisp macro as a special form.
;;;
;;;     * This is a screw, but not so bad, we save ourselves from it by
;;;       defining extra templates for the macros which are *likely* to
;;;       be implemented as special forms.  (DO, DO* ...)
;;;
;;;   3 - Implementation x has a special form which is not on the list of
;;;       Common Lisp special forms.
;;;
;;;     * This is a bad sort of a screw and happens more than I would like
;;;       to think, especially in the implementations which provide more
;;;       than just Common Lisp (3600, Xerox etc.).
;;;       The fix is not terribly staisfactory, but will have to do for
;;;       now.  There is a hook in get walker-template which can get a
;;;       template from the implementation's own walker.  That template
;;;       has to be converted, and so it may be that the right way to do
;;;       this would actually be for that implementation to provide an
;;;       interface to its walker which looks like the interface to this
;;;       walker.
;;;

(eval-when (:compile-toplevel :load-toplevel :execute)

(defmacro get-walker-template-internal (x) ;Has to be inside eval-when because
  `(get ,x 'walker-template))		   ;Golden Common Lisp doesn't hack
					   ;compile time definition of macros
					   ;right for setf.

(defmacro define-walker-template
	  (name &optional (template '(nil repeat (eval))))
  `(eval-when (:load-toplevel :execute)
     (setf (get-walker-template-internal ',name) ',template)))
)

(defun get-walker-template (x)
  (cond ((symbolp x)
	 (or (get-walker-template-internal x)
	     (get-implementation-dependent-walker-template x)))
	((and (listp x) (eq (car x) 'lambda))
	 '(lambda repeat (eval)))
	(t
	 (error _"~@<Can't get template for ~S.~@:>" x))))

(defun get-implementation-dependent-walker-template (x)
  (declare (ignore x))
  ())


  ;;   
;;;;;; The actual templates
  ;;   

(define-walker-template BLOCK                (NIL NIL REPEAT (EVAL)))
(define-walker-template CATCH                (NIL EVAL REPEAT (EVAL)))
(define-walker-template COMPILER-LET         walk-compiler-let)
(define-walker-template DECLARE              walk-unexpected-declare)
(define-walker-template EVAL-WHEN            (NIL QUOTE REPEAT (EVAL)))
(define-walker-template FLET                 walk-flet)
(define-walker-template FUNCTION             (NIL CALL))
(define-walker-template GO                   (NIL QUOTE))
(define-walker-template IF                   walk-if)
(define-walker-template LABELS               walk-labels)
(define-walker-template LAMBDA               walk-lambda)
(define-walker-template LET                  walk-let)
(define-walker-template LET*                 walk-let*)
(define-walker-template LOCALLY              walk-locally)
(define-walker-template MACROLET             walk-macrolet)
(define-walker-template MULTIPLE-VALUE-CALL  (NIL EVAL REPEAT (EVAL)))
(define-walker-template MULTIPLE-VALUE-PROG1 (NIL RETURN REPEAT (EVAL)))
(define-walker-template MULTIPLE-VALUE-SETQ  walk-multiple-value-setq)
(define-walker-template MULTIPLE-VALUE-BIND  walk-multiple-value-bind)
(define-walker-template PROGN                (NIL REPEAT (EVAL)))
(define-walker-template PROGV                (NIL EVAL EVAL REPEAT (EVAL)))
(define-walker-template QUOTE                (NIL QUOTE))
(define-walker-template RETURN-FROM          (NIL QUOTE REPEAT (RETURN)))
(define-walker-template SETQ                 walk-setq)
(define-walker-template SYMBOL-MACROLET      walk-symbol-macrolet)
(define-walker-template TAGBODY              walk-tagbody)
(define-walker-template THE                  (NIL QUOTE EVAL))
(define-walker-template TRULY-THE            (NIL QUOTE EVAL))
(define-walker-template THROW                (NIL EVAL EVAL))
(define-walker-template UNWIND-PROTECT       (NIL RETURN REPEAT (EVAL)))

;;; The new special form.
;(define-walker-template pcl::LOAD-TIME-EVAL       (NIL EVAL))

;;;
;;; And the extra templates...
;;;
#|| These are macros in CMUCL
(define-walker-template DO      walk-do)
(define-walker-template DO*     walk-do*)
(define-walker-template PROG    walk-prog)
(define-walker-template PROG*   walk-prog*)
(define-walker-template COND    (NIL REPEAT ((TEST REPEAT (EVAL)))))
||#


(defvar walk-form-expand-macros-p nil)

(defun macroexpand-all (form &optional environment)
  (let ((walk-form-expand-macros-p t))
    (walk-form form environment)))

(defun WALK-FORM (form
		  &optional environment
			    (walk-function
			      (lambda (subform context env)
				(declare (ignore context env))
				subform)))
  (walker-environment-bind (new-env environment :walk-function walk-function)
    (walk-form-internal form :eval new-env)))

;;;
;;; nested-walk-form provides an interface that allows nested macros, each
;;; of which must walk their body to just do one walk of the body of the
;;; inner macro.  That inner walk is done with a walk function which is the
;;; composition of the two walk functions.
;;;
;;; This facility works by having the walker annotate the environment that
;;; it passes to macroexpand-1 to know which form is being macroexpanded.
;;; If then the &whole argument to the macroexpansion function is eq to
;;; the env-walk-form of the environment, nested-walk-form can be certain
;;; that there are no intervening layers and that a nested walk is alright.
;;;
;;; There are some semantic problems with this facility.  In particular, if
;;; the outer walk function returns T as its walk-no-more-p value, this will
;;; prevent the inner walk function from getting a chance to walk the subforms
;;; of the form.  This is almost never what you want, since it destroys the
;;; equivalence between this nested-walk-form function and two seperate
;;; walk-forms.
;;;
(defun NESTED-WALK-FORM (whole
			 form
			 &optional environment
				   (walk-function
				     (lambda (subform context env)
				       (declare (ignore context env))
				       subform)))
  (if (eq whole (env-walk-form environment))
      (let ((outer-walk-function (env-walk-function environment)))
	(throw whole
	  (walk-form
	    form
	    environment
	    (lambda (f c e)
	      ;; First loop to make sure the inner walk function
	      ;; has done all it wants to do with this form.
	      ;; Basically, what we are doing here is providing
	      ;; the same contract walk-form-internal normally
	      ;; provides to the inner walk function.
	      (let ((inner-result nil)
		    (inner-no-more-p nil)
		    (outer-result nil)
		    (outer-no-more-p nil))
		(loop
		 (multiple-value-setq (inner-result inner-no-more-p)
		   (funcall walk-function f c e))
		 (cond (inner-no-more-p (return))
		       ((not (eq inner-result f)))
		       ((not (consp inner-result)) (return))
		       ((get-walker-template (car inner-result)) (return))
		       (t
			(multiple-value-bind (expansion macrop)
			    (walker-environment-bind
			     (new-env e :walk-form inner-result)
			     (macroexpand-1 inner-result new-env))
			  (if macrop
			      (setq inner-result expansion)
			      (return)))))
		 (setq f inner-result))
		(multiple-value-setq (outer-result outer-no-more-p)
		  (funcall outer-walk-function
			   inner-result
			   c
			   e))
		(values outer-result
			(and inner-no-more-p outer-no-more-p)))))))
      (walk-form form environment walk-function)))

;;;
;;; WALK-FORM-INTERNAL is the main driving function for the code walker. It
;;; takes a form and the current context and walks the form calling itself or
;;; the appropriate template recursively.
;;;
;;;   "It is recommended that a program-analyzing-program process a form
;;;    that is a list whose car is a symbol as follows:
;;;
;;;     1. If the program has particular knowledge about the symbol,
;;;        process the form using special-purpose code.  All of the
;;;        standard special forms should fall into this category.
;;;     2. Otherwise, if macro-function is true of the symbol apply
;;;        either macroexpand or macroexpand-1 and start over.
;;;     3. Otherwise, assume it is a function call. "
;;;     

(defun walk-form-internal (form context env)
  ;; First apply the walk-function to perform whatever translation
  ;; the user wants to this form.  If the second value returned
  ;; by walk-function is T then we don't recurse...
  (catch form
    (multiple-value-bind (newform walk-no-more-p)
      (funcall (env-walk-function env) form context env)
      (catch newform
	(cond
	 (walk-no-more-p newform)
	 ((not (eq form newform))
	  (walk-form-internal newform context env))
	 ((not (consp newform))
	  (let ((symmac (car (variable-symbol-macro-p newform env))))
	    (if symmac
		(let ((newnewform (walk-form-internal (cddr symmac)
						      context env)))
		  (if (eq newnewform (cddr symmac))
		      (if walk-form-expand-macros-p newnewform newform)
		      newnewform))
		newform)))
	 (t
	  (let* ((fn (car newform))
		 (template (get-walker-template fn)))
	    (if template
		(if (symbolp template)
		    (funcall template newform context env)
		    (walk-template newform template context env))
		(multiple-value-bind
		    (newnewform macrop)
		    (walker-environment-bind
			(new-env env :walk-form newform)
		      (macroexpand-1 newform new-env))
		  (cond
		   (macrop
		    (let ((newnewnewform (walk-form-internal newnewform context
							     env)))
		      (if (eq newnewnewform newnewform)
			  (if walk-form-expand-macros-p newnewform newform)
			  newnewnewform)))
		   ((and (symbolp fn)
			 (not (fboundp fn))
			 (special-operator-p fn))
		    (error
		     _"~@<~S is a special form, not defined in the CommonLisp ~
		      manual.  This code walker doesn't know how to walk it.  ~
		      Define a template for this special form and try again.~@:>"
		     fn))
		   (t
		    ;; Otherwise, walk the form as if its just a standard 
		    ;; functioncall using a template for standard function
		    ;; call.
		    (walk-template
		     newnewform '(call repeat (eval)) context env))))))))))))

(defun walk-template (form template context env)
  (if (atom template)
      (ecase template
        ((EVAL FUNCTION TEST EFFECT RETURN)
         (walk-form-internal form :EVAL env))
        ((QUOTE NIL) form)
        (SET
          (walk-form-internal form :SET env))
        ((LAMBDA CALL)
	 (cond ((valid-function-name-p form) form)
	       (t (walk-form-internal form context env)))))
      (case (car template)
        (REPEAT
          (walk-template-handle-repeat form
                                       (cdr template)
				       ;; For the case where nothing happens
				       ;; after the repeat optimize out the
				       ;; call to length.
				       (if (null (cddr template))
					   ()
					   (nthcdr (- (length form)
						      (length
							(cddr template)))
						   form))
                                       context
				       env))
        (IF
	  (walk-template form
			 (if (if (listp (cadr template))
				 (eval (cadr template))
				 (funcall (cadr template) form))
			     (caddr template)
			     (cadddr template))
			 context
			 env))
        (REMOTE
          (walk-template form (cadr template) context env))
        (otherwise
          (cond ((atom form) form)
                (t (recons form
                           (walk-template
			     (car form) (car template) context env)
                           (walk-template
			     (cdr form) (cdr template) context env))))))))

(defun walk-template-handle-repeat (form template stop-form context env)
  (if (eq form stop-form)
      (walk-template form (cdr template) context env)
      (walk-template-handle-repeat-1 form
				     template
				     (car template)
				     stop-form
				     context
				     env)))

(defun walk-template-handle-repeat-1 (form template repeat-template
					   stop-form context env)
  (cond ((null form) ())
        ((eq form stop-form)
         (if (null repeat-template)
             (walk-template stop-form (cdr template) context env)       
             (error _"~@<While handling repeat: ~
                     Ran into stop while still in repeat template.~@:>")))
        ((null repeat-template)
         (walk-template-handle-repeat-1
	   form template (car template) stop-form context env))
        (t
         (recons form
                 (walk-template (car form) (car repeat-template) context env)
                 (walk-template-handle-repeat-1 (cdr form)
						template
						(cdr repeat-template)
						stop-form
						context
						env)))))

(defun walk-repeat-eval (form env)
  (and form
       (recons form
	       (walk-form-internal (car form) :eval env)
	       (walk-repeat-eval (cdr form) env))))

(defun recons (x car cdr)
  (if (or (not (eq (car x) car))
          (not (eq (cdr x) cdr)))
      (cons car cdr)
      x))

(defun relist (x &rest args)
  (if (null args)
      nil
      (relist-internal x args nil)))

(defun relist* (x &rest args)
  (relist-internal x args t))

(defun relist-internal (x args *p)
  (if (null (cdr args))
      (if *p
	  (car args)
	  (recons x (car args) nil))
      (recons x
	      (car args)
	      (relist-internal (cdr x) (cdr args) *p))))


  ;;   
;;;;;; Special walkers
  ;;

(defun walk-declarations (body fn env
			       &optional doc-string-p declarations old-body
			       &aux (form (car body)) macrop new-form)
  (cond ((and (stringp form)			;might be a doc string
              (cdr body)			;isn't the returned value
              (null doc-string-p)		;no doc string yet
              (null declarations))		;no declarations yet
         (recons body
                 form
                 (walk-declarations (cdr body) fn env t)))
        ((and (listp form) (eq (car form) 'declare))
         ;; Got ourselves a real live declaration.  Record it, look for more.
         (dolist (declaration (cdr form))
	   (let ((type (car declaration))
		 (name (cadr declaration))
		 (args (cddr declaration)))
	     (if (member type *variable-declarations*)
		 (note-declaration `(,type
				     ,(or (variable-lexical-p name env) name)
				     ,.args)
				   env)
		 (note-declaration declaration env))
	     (push declaration declarations)))
         (recons body
                 form
                 (walk-declarations
		   (cdr body) fn env doc-string-p declarations)))
        ((and form
	      (listp form)
	      (null (get-walker-template (car form)))
	      (progn
		(multiple-value-setq (new-form macrop)
				     (macroexpand-1 form env))
		macrop))
	 ;; This form was a call to a macro.  Maybe it expanded
	 ;; into a declare?  Recurse to find out.
	 (walk-declarations (recons body new-form (cdr body))
			    fn env doc-string-p declarations
			    (or old-body body)))
	(t
	 ;; Now that we have walked and recorded the declarations,
	 ;; call the function our caller provided to expand the body.
	 ;; We call that function rather than passing the real-body
	 ;; back, because we are RECONSING up the new body.
	 (funcall fn (or old-body body) env))))


(defun walk-unexpected-declare (form context env)
  (declare (ignore context env))
  (warn _"~@<Encountered declare ~S in a place where a ~
         declare was not expected.~@:>"
	form)
  form)

(defun walk-arglist (arglist context env &optional (destructuringp nil)
					 &aux arg)
  (cond ((null arglist) ())
        ((symbolp (setq arg (car arglist)))
         (or (member arg lambda-list-keywords)
             (note-lexical-binding arg env))
         (recons arglist
                 arg
                 (walk-arglist (cdr arglist)
                               context
			       env
                               (and destructuringp
				    (not (member arg
						 lambda-list-keywords))))))
        ((consp arg)
         (prog1 (recons arglist
			(if destructuringp
			    (walk-arglist arg context env destructuringp)
			    (relist* arg
				     (car arg)
				     (walk-form-internal (cadr arg) :eval env)
				     (cddr arg)))
			(walk-arglist (cdr arglist) context env nil))
                (if (symbolp (car arg))
                    (note-lexical-binding (car arg) env)
                    (note-lexical-binding (cadar arg) env))
                (or (null (cddr arg))
                    (not (symbolp (caddr arg)))
                    (note-lexical-binding (caddr arg) env))))
          (t
	   (error _"~@<Can't understand something in the arglist ~S.~@:>" arglist))))

(defun walk-let (form context env)
  (walk-let/let* form context env nil))

(defun walk-let* (form context env)
  (walk-let/let* form context env t))

(defun walk-prog (form context env)
  (walk-prog/prog* form context env nil))

(defun walk-prog* (form context env)
  (walk-prog/prog* form context env t))

(defun walk-do (form context env)
  (walk-do/do* form context env nil))

(defun walk-do* (form context env)
  (walk-do/do* form context env t))

(defun walk-let/let* (form context old-env sequentialp)
  (walker-environment-bind (new-env old-env)
    (let* ((let/let* (car form))
	   (bindings (cadr form))
	   (body (cddr form))
	   (walked-bindings 
	     (walk-bindings-1 bindings
			      old-env
			      new-env
			      context
			      sequentialp))
	   (walked-body
	     (walk-declarations body #'walk-repeat-eval new-env)))
      (relist*
	form let/let* walked-bindings walked-body))))

(defun walk-locally (form context env)
  (declare (ignore context))
  (let* ((locally (car form))
	 (body (cdr form))
	 (walked-body
	  (walk-declarations body #'walk-repeat-eval env)))
    (relist*
     form locally walked-body)))

(defun walk-prog/prog* (form context old-env sequentialp)
  (walker-environment-bind (new-env old-env)
    (let* ((possible-block-name (second form))
	   (blocked-prog (and (symbolp possible-block-name)
			      (not (eq possible-block-name 'nil)))))
      (multiple-value-bind (let/let* block-name bindings body)
	  (if blocked-prog
	      (values (car form) (cadr form) (caddr form) (cdddr form))
	      (values (car form) nil	     (cadr  form) (cddr  form)))
	(let* ((walked-bindings 
		 (walk-bindings-1 bindings
				  old-env
				  new-env
				  context
				  sequentialp))
	       (walked-body
		 (walk-declarations 
		   body
		   (lambda (real-body real-env)
		     (walk-tagbody-1 real-body context real-env))
		   new-env)))
	  (if block-name
	      (relist*
		form let/let* block-name walked-bindings walked-body)
	      (relist*
		form let/let* walked-bindings walked-body)))))))

(defun walk-do/do* (form context old-env sequentialp)
  (walker-environment-bind (new-env old-env)
    (let* ((do/do* (car form))
	   (bindings (cadr form))
	   (end-test (caddr form))
	   (body (cdddr form))
	   (walked-bindings (walk-bindings-1 bindings
					     old-env
					     new-env
					     context
					     sequentialp))
	   (walked-body
	     (walk-declarations body #'walk-repeat-eval new-env)))
      (relist* form
	       do/do*
	       (walk-bindings-2 bindings walked-bindings context new-env)
	       (walk-template end-test '(test repeat (eval)) context new-env)
	       walked-body))))

(defun walk-let-if (form context env)
  (let ((test (cadr form))
	(bindings (caddr form))
	(body (cdddr form)))
    (walk-form-internal
      `(let ()
	 (declare (special ,@(mapcar (lambda (x) (if (listp x) (car x) x))
				     bindings)))
	 (flet ((.let-if-dummy. () ,@body))
	   (if ,test
	       (let ,bindings (.let-if-dummy.))
	       (.let-if-dummy.))))
      context
      env)))

(defun walk-multiple-value-setq (form context env)
  (let ((vars (cadr form)))
    (if (some (lambda (var)
		(variable-symbol-macro-p var env))
	      vars)
	(let* ((temps (mapcar (lambda (var) (declare (ignore var)) (gensym)) vars))
	       (sets (mapcar (lambda (var temp) `(setq ,var ,temp)) vars temps))
	       (expanded `(multiple-value-bind ,temps 
			       ,(caddr form)
			     ,@sets))
	       (walked (walk-form-internal expanded context env)))
	  (if (eq walked expanded)
	      form
	      walked))
	(walk-template form '(nil (repeat (set)) eval) context env))))

(defun walk-multiple-value-bind (form context old-env)
  (walker-environment-bind (new-env old-env)
    (let* ((mvb (car form))
	   (bindings (cadr form))
	   (mv-form (walk-template (caddr form) 'eval context old-env))
	   (body (cdddr form))
	   walked-bindings
	   (walked-body
	     (walk-declarations 
	       body
	       (lambda (real-body real-env)
		 (setq walked-bindings
		       (walk-bindings-1 bindings
					old-env
					new-env
					context
					nil))
		 (walk-repeat-eval real-body real-env))
	       new-env)))
      (relist* form mvb walked-bindings mv-form walked-body))))

(defun walk-bindings-1 (bindings old-env new-env context sequentialp)
  (and bindings
       (let ((binding (car bindings)))
         (recons bindings
                 (if (symbolp binding)
                     (prog1 binding
                            (note-lexical-binding binding new-env))
                     (prog1 (relist* binding
				     (car binding)
				     (walk-form-internal (cadr binding)
							 context
							 (if sequentialp
							     new-env
							     old-env))
				     (cddr binding))	;save cddr for DO/DO*
						        ;it is the next value
						        ;form. Don't walk it
						        ;now though.
                            (note-lexical-binding (car binding) new-env)))
                 (walk-bindings-1 (cdr bindings)
				  old-env
				  new-env
				  context
				  sequentialp)))))

(defun walk-bindings-2 (bindings walked-bindings context env)
  (and bindings
       (let ((binding (car bindings))
             (walked-binding (car walked-bindings)))
         (recons bindings
		 (if (symbolp binding)
		     binding
		     (relist* binding
			      (car walked-binding)
			      (cadr walked-binding)
			      (walk-template (cddr binding)
					     '(eval)
					     context
					     env)))		 
                 (walk-bindings-2 (cdr bindings)
				  (cdr walked-bindings)
				  context
				  env)))))

(defun walk-lambda (form context old-env)
  (walker-environment-bind (new-env old-env)
    (let* ((arglist (cadr form))
           (body (cddr form))
           (walked-arglist (walk-arglist arglist context new-env))
           (walked-body
             (walk-declarations body #'walk-repeat-eval new-env)))
      (relist* form
               (car form)
	       walked-arglist
               walked-body))))

(defun walk-named-lambda (form context old-env)
  (walker-environment-bind (new-env old-env)
    (let* ((name (cadr form))
	   (arglist (caddr form))
           (body (cdddr form))
           (walked-arglist (walk-arglist arglist context new-env))
           (walked-body
             (walk-declarations body #'walk-repeat-eval new-env)))
      (relist* form
               (car form)
	       name
	       walked-arglist
               walked-body))))  

(defun walk-setq (form context env)
  (if (cdddr form)
      (let* ((expanded (let ((rforms nil)
			     (tail (cdr form)))
			 (loop (when (null tail) (return (nreverse rforms)))
			       (let ((var (pop tail)) (val (pop tail)))
				 (push `(setq ,var ,val) rforms)))))
	     (walked (walk-repeat-eval expanded env)))
	(if (eq expanded walked)
	    form
	    `(progn ,@walked)))
      (let* ((var (cadr form))
	     (val (caddr form))
	     (symmac (car (variable-symbol-macro-p var env))))
	(if symmac
	    (let* ((expanded `(setf ,(cddr symmac) ,val))
		   (walked (walk-form-internal expanded context env)))
	      (if (eq expanded walked)
		  form
		  walked))
	    (relist form 'setq
		    (walk-form-internal var :set env)
		    (walk-form-internal val :eval env))))))

(defun walk-symbol-macrolet (form context old-env)
  (declare (ignore context))
  (let* ((bindings (cadr form))
	 (body (cddr form)))
    (walker-environment-bind
	(new-env old-env
		 :lexical-variables
		 (append (mapcar (lambda (binding)
				   `(,(car binding)
				     c::macro . ,(cadr binding)))
				 bindings)
			 (env-lexical-variables old-env)))
      (relist* form 'symbol-macrolet bindings
	       (walk-declarations body #'walk-repeat-eval new-env)))))

(defun walk-tagbody (form context env)
  (recons form (car form) (walk-tagbody-1 (cdr form) context env)))

(defun walk-tagbody-1 (form context env)
  (and form
       (recons form
               (walk-form-internal (car form)
				   (if (symbolp (car form)) 'quote context)
				   env)
               (walk-tagbody-1 (cdr form) context env))))

(defun walk-compiler-let (form context old-env)
  (declare (ignore context))
  (let ((vars ())
	(vals ()))
    (dolist (binding (cadr form))
      (cond ((symbolp binding) (push binding vars) (push nil vals))
	    (t
	     (push (car binding) vars)
	     (push (eval (cadr binding)) vals))))
    (relist* form
	     (car form)
	     (cadr form)
	     (progv vars vals (walk-repeat-eval (cddr form) old-env)))))

(defun walk-macrolet (form context old-env)
  (walker-environment-bind (macro-env
			    nil
			    :walk-function (env-walk-function old-env))
    (labels ((walk-definitions (definitions)
	       (and definitions
		    (let ((definition (car definitions)))
		      (recons definitions
                              (relist* definition
                                       (car definition)
                                       (walk-arglist (cadr definition)
						     context
						     macro-env
						     t)
                                       (walk-declarations (cddr definition)
							  #'walk-repeat-eval
							  macro-env))
			      (walk-definitions (cdr definitions)))))))
      (with-new-definition-in-environment (new-env old-env form)
	(relist* form
		 (car form)
		 (walk-definitions (cadr form))
		 (walk-declarations (cddr form)
				    #'walk-repeat-eval
				    new-env))))))

(defun walk-flet (form context old-env)
  (labels ((walk-definitions (definitions)
	     (if (null definitions)
		 ()
		 (recons definitions
			 (walk-lambda (car definitions) context old-env)
			 (walk-definitions (cdr definitions))))))
    (recons form
	    (car form)
	    (recons (cdr form)
		    (walk-definitions (cadr form))
		    (with-new-definition-in-environment (new-env old-env form)
		      (walk-declarations (cddr form)
					 #'walk-repeat-eval
					 new-env))))))

(defun walk-labels (form context old-env)
  (with-new-definition-in-environment (new-env old-env form)
    (labels ((walk-definitions (definitions)
	       (if (null definitions)
		   ()
		   (recons definitions
			   (walk-lambda (car definitions) context new-env)
			   (walk-definitions (cdr definitions))))))
      (recons form
	      (car form)
	      (recons (cdr form)
		      (walk-definitions (cadr form))
		      (walk-declarations (cddr form)
					 #'walk-repeat-eval
					 new-env))))))

(defun walk-if (form context env)
  (let ((predicate (cadr form))
	(arm1 (caddr form))
	(arm2 
	  (if (cddddr form)
	      (progn
		(warn _"~@<In the form ~S: ~
                       IF only accepts three arguments, you are using ~D. ~
                       It is true that some Common Lisps support this, but ~
                       it is not truly legal Common Lisp.  For now, this code ~
                       walker is interpreting the extra arguments as extra else clauses. ~
                       Even if this is what you intended, you should fix your source code.~@:>"
		      form
		      (length (cdr form)))
		(cons 'progn (cdddr form)))
	      (cadddr form))))
    (relist form
	    'if
	    (walk-form-internal predicate context env)
	    (walk-form-internal arm1 context env)
	    (walk-form-internal arm2 context env))))


;;;
;;; Tests tests tests
;;;

#|
;;; 
;;; Here are some examples of the kinds of things you should be able to do
;;; with your implementation of the macroexpansion environment hacking
;;; mechanism.
;;; 
;;; with-lexical-macros is kind of like macrolet, but it only takes names
;;; of the macros and actual macroexpansion functions to use to macroexpand
;;; them.  The win about that is that for macros which want to wrap several
;;; macrolets around their body, they can do this but have the macroexpansion
;;; functions be compiled.  See the WITH-RPUSH example.
;;;
;;; If the implementation had a special way of communicating the augmented
;;; environment back to the evaluator that would be totally great.  It would
;;; mean that we could just augment the environment then pass control back
;;; to the implementations own compiler or interpreter.  We wouldn't have
;;; to call the actual walker.  That would make this much faster.  Since the
;;; principal client of this is defmethod it would make compiling defmethods
;;; faster and that would certainly be a win.
;;;
(defmacro with-lexical-macros (macros &body body &environment old-env)
  (with-augmented-environment (new-env old-env :macros macros)
    (walk-form (cons 'progn body) :environment new-env)))

(defun expand-rpush (form env)
  `(push ,(caddr form) ,(cadr form)))

(defmacro with-rpush (&body body)
  `(with-lexical-macros ,(list (list 'rpush #'expand-rpush)) ,@body))


;;;
;;; Unfortunately, I don't have an automatic tester for the walker.  
;;; Instead there is this set of test cases with a description of
;;; how each one should go.
;;; 
(defmacro take-it-out-for-a-test-walk (form)
  `(take-it-out-for-a-test-walk-1 ',form))

(defun take-it-out-for-a-test-walk-1 (form)
  (terpri)
  (terpri)
  (let ((copy-of-form (copy-tree form))
	(result (walk-form form nil
		  (lambda (x y env)
		    (format t "~&Form: ~S ~3T Context: ~A" x y)
		    (when (symbolp x)
		      (let ((lexical (variable-lexical-p x env))
			    (special (variable-special-p x env)))
			(when lexical
			  (format t ";~3T")
			  (format t "lexically bound"))
			(when special
			  (format t ";~3T")
			  (format t "declared special"))
			(when (boundp x)
			  (format t ";~3T")
			  (format t "bound: ~S " (eval x)))))
		    x))))
    (cond ((not (equal result copy-of-form))
	   (format t "~%Warning: Result not EQUAL to copy of start."))
	  ((not (eq result form))
	   (format t "~%Warning: Result not EQ to copy of start.")))
    (pprint result)
    result))

(defmacro foo (&rest ignore) ''global-foo)

(defmacro bar (&rest ignore) ''global-bar)

(take-it-out-for-a-test-walk (list arg1 arg2 arg3))
(take-it-out-for-a-test-walk (list (cons 1 2) (list 3 4 5)))

(take-it-out-for-a-test-walk (progn (foo) (bar 1)))

(take-it-out-for-a-test-walk (block block-name a b c))
(take-it-out-for-a-test-walk (block block-name (list a) b c))

(take-it-out-for-a-test-walk (catch catch-tag (list a) b c))
;;;
;;; This is a fairly simple macrolet case.  While walking the body of the
;;; macro, x should be lexically bound. In the body of the macrolet form
;;; itself, x should not be bound.
;;; 
(take-it-out-for-a-test-walk
  (macrolet ((foo (x) (list x) ''inner))
    x
    (foo 1)))

;;;
;;; A slightly more complex macrolet case.  In the body of the macro x
;;; should not be lexically bound.  In the body of the macrolet form itself
;;; x should be bound.  Note that THIS CASE WILL CAUSE AN ERROR when it
;;; tries to macroexpand the call to foo.
;;; 
(take-it-out-for-a-test-walk
     (let ((x 1))
       (macrolet ((foo () (list x) ''inner))
	 x
	 (foo))))

;;;
;;; A truly hairy use of compiler-let and macrolet.  In the body of the
;;; macro x should not be lexically bound.  In the body of the macrolet
;;; itself x should not be lexically bound.  But the macro should expand
;;; into 1.
;;; 
(take-it-out-for-a-test-walk
  (compiler-let ((x 1))
    (let ((x 2))
      (macrolet ((foo () x))
	x
	(foo)))))


(take-it-out-for-a-test-walk
  (flet ((foo (x) (list x y))
	 (bar (x) (list x y)))
    (foo 1)))

(take-it-out-for-a-test-walk
  (let ((y 2))
    (flet ((foo (x) (list x y))
	   (bar (x) (list x y)))
      (foo 1))))

(take-it-out-for-a-test-walk
  (labels ((foo (x) (bar x))
	   (bar (x) (foo x)))
    (foo 1)))

(take-it-out-for-a-test-walk
  (flet ((foo (x) (foo x)))
    (foo 1)))

(take-it-out-for-a-test-walk
  (flet ((foo (x) (foo x)))
    (flet ((bar (x) (foo x)))
      (bar 1))))

(take-it-out-for-a-test-walk (compiler-let ((a 1) (b 2)) (foo a) b))
(take-it-out-for-a-test-walk (prog () (declare (special a b))))
(take-it-out-for-a-test-walk (let (a b c)
                               (declare (special a b))
                               (foo a) b c))
(take-it-out-for-a-test-walk (let (a b c)
                               (declare (special a) (special b))
                               (foo a) b c))
(take-it-out-for-a-test-walk (let (a b c)
                               (declare (special a))
                               (declare (special b))
                               (foo a) b c))
(take-it-out-for-a-test-walk (let (a b c)
                               (declare (special a))
                               (declare (special b))
                               (let ((a 1))
                                 (foo a) b c)))
(take-it-out-for-a-test-walk (eval-when ()
                               a
                               (foo a)))
(take-it-out-for-a-test-walk (eval-when (eval when load)
                               a
                               (foo a)))

(take-it-out-for-a-test-walk (multiple-value-bind (a b) (foo a b) (list a b)))
(take-it-out-for-a-test-walk (multiple-value-bind (a b)
				 (foo a b)
			       (declare (special a))
			       (list a b)))
(take-it-out-for-a-test-walk (progn (function foo)))
(take-it-out-for-a-test-walk (progn a b (go a)))
(take-it-out-for-a-test-walk (if a b c))
(take-it-out-for-a-test-walk (if a b))
(take-it-out-for-a-test-walk ((lambda (a b) (list a b)) 1 2))
(take-it-out-for-a-test-walk ((lambda (a b) (declare (special a)) (list a b))
			      1 2))
(take-it-out-for-a-test-walk (let ((a a) (b a) (c b)) (list a b c)))
(take-it-out-for-a-test-walk (let* ((a a) (b a) (c b)) (list a b c)))
(take-it-out-for-a-test-walk (let ((a a) (b a) (c b))
                               (declare (special a b))
                               (list a b c)))
(take-it-out-for-a-test-walk (let* ((a a) (b a) (c b))
                               (declare (special a b))
                               (list a b c)))
(take-it-out-for-a-test-walk (let ((a 1) (b 2))
                               (foo bar)
                               (declare (special a))
                               (foo a b)))
(take-it-out-for-a-test-walk (multiple-value-call #'foo a b c))
(take-it-out-for-a-test-walk (multiple-value-prog1 a b c))
(take-it-out-for-a-test-walk (progn a b c))
(take-it-out-for-a-test-walk (progv vars vals a b c))
(take-it-out-for-a-test-walk (quote a))
(take-it-out-for-a-test-walk (return-from block-name a b c))
(take-it-out-for-a-test-walk (setq a 1))
(take-it-out-for-a-test-walk (setq a (foo 1) b (bar 2) c 3))
(take-it-out-for-a-test-walk (tagbody a b c (go a)))
(take-it-out-for-a-test-walk (the foo (foo-form a b c)))
(take-it-out-for-a-test-walk (throw tag-form a))
(take-it-out-for-a-test-walk (unwind-protect (foo a b) d e f))

(defmacro flet-1 (a b) ''outer)
(defmacro labels-1 (a b) ''outer)

(take-it-out-for-a-test-walk
  (flet ((flet-1 (a b) () (flet-1 a b) (list a b)))
    (flet-1 1 2)
    (foo 1 2)))
(take-it-out-for-a-test-walk
  (labels ((label-1 (a b) () (label-1 a b)(list a b)))
    (label-1 1 2)
    (foo 1 2)))
(take-it-out-for-a-test-walk (macrolet ((macrolet-1 (a b) (list a b)))
                               (macrolet-1 a b)
                               (foo 1 2)))

(take-it-out-for-a-test-walk (macrolet ((foo (a) `(inner-foo-expanded ,a)))
                               (foo 1)))

(take-it-out-for-a-test-walk (progn (bar 1)
                                    (macrolet ((bar (a)
						 `(inner-bar-expanded ,a)))
                                      (bar 2))))

(take-it-out-for-a-test-walk (progn (bar 1)
                                    (macrolet ((bar (s)
						 (bar s)
						 `(inner-bar-expanded ,s)))
                                      (bar 2))))

(take-it-out-for-a-test-walk (cond (a b)
                                   ((foo bar) a (foo a))))


(let ((the-lexical-variables ()))
  (walk-form '(let ((a 1) (b 2))
		(lambda (x) (list a b x y)))
	     ()
	     (lambda (form context env)
	       (when (and (symbolp form)
			  (variable-lexical-p form env))
		 (push form the-lexical-variables))
	       form))
  (or (and (= (length the-lexical-variables) 3)
	   (member 'a the-lexical-variables)
	   (member 'b the-lexical-variables)
	   (member 'x the-lexical-variables))
      (error "~@<Walker didn't do lexical variables of a closure properly.~@:>")))
    
|#

()

