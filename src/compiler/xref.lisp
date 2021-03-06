;;; xref.lisp -- a cross-reference facility for CMUCL
;;;
;;; Author: Eric Marsden <emarsden@laas.fr>
;;;
(ext:file-comment
  "$Header: src/compiler/xref.lisp $")
;;
;; This code was written as part of the CMUCL project and has been
;; placed in the public domain.
;;
;;
;; The cross-referencing facility provides the ability to discover
;; information such as which functions call which other functions and
;; in which program contexts a given global variables may be used. The
;; cross-referencer maintains a database of cross-reference
;; information which can be queried by the user to provide answers to
;; questions like:
;;
;;  - the program contexts where a given function may be called,
;;    either directly or indirectly (via its function-object).
;;
;;  - the program contexts where a global variable (ie a dynamic
;;    variable or a constant variable -- something declared with
;;    DEFVAR or DEFPARAMETER or DEFCONSTANT) may be read, or bound, or
;;    modified.
;;
;; More details are available in "Cross-Referencing Facility" chapter
;; of the CMUCL User's Manual.
;;
;;
;; Missing functionality:
;;
;;   - maybe add macros EXT:WITH-XREF.
;;
;;   - in (defun foo (x) (flet ((bar (y) (+ x y))) (bar 3))), we want to see
;;     FOO calling (:internal BAR FOO)
;;
;; The cross-reference facility is implemented by walking the IR1
;; representation that is generated by CMUCL when compiling (for both
;; native and byte-compiled code, and irrespective of whether you're
;; compiling from a file, from a stream, or interactively from the
;; listener).


(in-package :xref)
(intl:textdomain "cmucl")

(export '(init-xref-database
          register-xref
          who-calls
          who-references
          who-binds
          who-sets
          who-macroexpands
          who-subclasses
          who-superclasses
          who-specializes
          make-xref-context
          xref-context-name
          xref-context-file
          xref-context-source-path
	  invalidate-xrefs-for-namestring
	  find-xrefs-for-pathname))


(defstruct (xref-context
             (:print-function %print-xref-context)
             (:make-load-form-fun :just-dump-it-normally))
  name
  (file *compile-file-truename*)
  (source-path nil))

(defun %print-xref-context (s stream d)
  (declare (ignore d))
  (cond (*print-readably*
         (format stream "#S(xref::xref-context :name '~S ~_ :file ~S ~_ :source-path '~A)"
                 (xref-context-name s)
                 (xref-context-file s)
                 (xref-context-source-path s)))
        (t
         (format stream "#<xref-context ~S~@[ in ~S~]>"
                 (xref-context-name s)
                 (xref-context-file s)))))


;; program contexts where a globally-defined function may be called at runtime
(defvar *who-calls* (make-hash-table :test #'eq))

(defvar *who-is-called* (make-hash-table :test #'eq))

;; program contexts where a global variable may be referenced
(defvar *who-references* (make-hash-table :test #'eq))

;; program contexts where a global variable may be bound
(defvar *who-binds* (make-hash-table :test #'eq))

;; program contexts where a global variable may be set
(defvar *who-sets* (make-hash-table :test #'eq))

;; program contexts where a global variable may be set
(defvar *who-macroexpands* (make-hash-table :test #'eq))

;; you can print these conveniently with code like
;; (maphash (lambda (k v) (format t "~S <-~{ ~S~^,~}~%" k v)) xref::*who-sets*)
;; or
;; (maphash (lambda (k v) (format t "~S <-~%   ~@<~@;~S~^~%~:>~%" k v)) xref::*who-calls*)


(defun register-xref (type target context)
  (declare (type xref-context context))
  (let ((database (ecase type
                    (:calls *who-calls*)
                    (:called *who-is-called*)
                    (:references *who-references*)
                    (:binds *who-binds*)
                    (:sets *who-sets*)
                    (:macroexpands *who-macroexpands*))))
    (if (gethash target database)
        (pushnew context (gethash target database) :test 'equalp)
        (setf (gethash target database) (list context)))
    context))

;; INIT-XREF-DATABASE -- interface
;;
(defun init-xref-database ()
  "Reinitialize the cross-reference database."
  (setf *who-calls* (make-hash-table :test #'eq))
  (setf *who-is-called* (make-hash-table :test #'eq))
  (setf *who-references* (make-hash-table :test #'eq))
  (setf *who-binds* (make-hash-table :test #'eq))
  (setf *who-sets* (make-hash-table :test #'eq))
  (setf *who-macroexpands* (make-hash-table :test #'eq))
  (values))


;; WHO-CALLS -- interface
;;
(defun who-calls (function-name &key (reverse nil))
  "Return a list of those program contexts where a globally-defined
function may be called at runtime."
  (if reverse
      (gethash function-name *who-is-called*)
      (gethash function-name *who-calls*)))

;; WHO-REFERENCES -- interface
;;
(defun who-references (global-variable)
  "Return a list of those program contexts where GLOBAL-VARIABLE
may be referenced at runtime."
  (declare (type symbol global-variable))
  (gethash global-variable *who-references*))

;; WHO-BINDS -- interface
;;
(defun who-binds (global-variable)
  "Return a list of those program contexts where GLOBAL-VARIABLE may
be bound at runtime."
  (declare (type symbol global-variable))
  (gethash global-variable *who-binds*))

;; WHO-SETS -- interface
;;
(defun who-sets (global-variable)
  "Return a list of those program contexts where GLOBAL-VARIABLE may
be set at runtime."
  (declare (type symbol global-variable))
  (gethash global-variable *who-sets*))


(defun who-macroexpands (macro)
  (declare (type symbol macro))
  (gethash macro *who-macroexpands*))


;; introspection functions from the CLOS metaobject protocol

;; WHO-SUBCLASSES -- interface
;;
(defun who-subclasses (class)
  (pcl::class-direct-subclasses class))

;; WHO-SUPERCLASSES -- interface
;;
(defun who-superclasses (class)
  (pcl::class-direct-superclasses class))

;; WHO-SPECIALIZES -- interface
;;
;; generic functions defined for this class
(defun who-specializes (class)
  (pcl::specializer-direct-methods class))

;; Go through all the databases and remove entries from that that
;; reference the given Namestring.
(defun invalidate-xrefs-for-namestring (namestring)
  (labels ((matching-context (ctx)
	     (equal namestring (if (pathnamep (xref-context-file ctx))
				   (namestring (xref-context-file ctx))
				   (xref-context-file ctx))))
	   (invalidate-for-database (db)
	     (maphash (lambda (target contexts)
			(let ((valid-contexts (remove-if #'matching-context contexts)))
			  (if (null valid-contexts)
			      (remhash target db)
			      (setf (gethash target db) valid-contexts))))
		      db)))
    (dolist (db (list *who-calls* *who-is-called* *who-references* *who-binds*
		      *who-sets* *who-macroexpands*))
      (invalidate-for-database db))))

;; Look in Db for entries that reference the supplied Pathname and
;; return a list of all the matches.  Each element of the list is a
;; list of the target followed by the entries.
(defun find-xrefs-for-pathname (db pathname)
  (let ((entries '()))
    (maphash #'(lambda (target contexts)
		 (let ((matches '()))
		   (dolist (ctx contexts)
		     (when (equal pathname (xref-context-file ctx))
		       (push ctx matches)))
		   (push (list target matches) entries)))
	     (ecase db
	       (:calls *who-calls*)
	       (:called *who-is-called*)
	       (:references *who-references*)
	       (:binds *who-binds*)
	       (:sets *who-sets*)
	       (:macroexpands *who-macroexpands*)))
    entries))

(in-package :compiler)

(defun lambda-contains-calls-p (clambda)
  (declare (type clambda clambda))
  (some #'lambda-p (lambda-dfo-dependencies clambda)))

(defun prettiest-caller-name (lambda-node toplevel-name)
  (cond
    ((not lambda-node)
     (list :anonymous toplevel-name))

    ;; LET and FLET bindings introduce new unnamed LAMBDA nodes.
    ;; If the home slot contains a lambda with a nice name, we use
    ;; that; otherwise fall back on the toplevel-name.
    ((or (not (eq (lambda-home lambda-node) lambda-node))
         (lambda-contains-calls-p lambda-node))
     (let ((home (lambda-name (lambda-home lambda-node)))
           (here (lambda-name lambda-node)))
       (cond ((and home here)
              (list :internal home here))
             ((symbolp here) here)
             ((symbolp home) home)
             (t
              (or here home toplevel-name)))))

    ((and (listp (lambda-name lambda-node))
          (eq :macro (first (lambda-name lambda-node))))
     (lambda-name lambda-node))

    ;; a reference from a macro is named (:macro name)
    #+nil
    ((eql 0 (search "defmacro" toplevel-name :test 'char-equal))
     (list :macro (subseq toplevel-name 9)))

    ;; probably "Top-Level Form"
    ((stringp (lambda-name lambda-node))
     (lambda-name lambda-node))

    ;; probably (setf foo)
    ((listp (lambda-name lambda-node))
     (lambda-name lambda-node))

    (t
     ;; distinguish between nested functions (FLET/LABELS) and
     ;; global functions by checking whether the node has a HOME
     ;; slot that is different from itself. Furthermore, a LABELS
     ;; node at the first level inside a lambda may have a
     ;; self-referential home slot, but still be internal. 
     (cond ((not (eq (lambda-home lambda-node) lambda-node))
            (list :internal
                  (lambda-name (lambda-home lambda-node))
                  (lambda-name lambda-node)))
           ((lambda-contains-calls-p lambda-node)
            (list :internal/calls
                  (lambda-name (lambda-home lambda-node))
                  (lambda-name lambda-node)))
           (t (lambda-name lambda-node))))))


;; RECORD-NODE-XREFS -- internal
;;
;; TOPLEVEL-NAME is an indication of the name of the COMPONENT that
;; contains this node, or NIL if it was really "Top-Level Form". 
(defun record-node-xrefs (node toplevel-name)
  (declare (type node node))
  (let ((context (xref:make-xref-context)))
    (when *compile-file-truename*
      (setf (xref:xref-context-source-path context)
            (reverse
             (source-path-original-source
              (node-source-path node)))))
    (typecase node
      (ref
       (let* ((leaf (ref-leaf node))
              (lexenv (ref-lexenv node))
              (lambda (lexenv-lambda lexenv))
              (home (node-home-lambda node))
              (caller (or (and home (lambda-name home))
                          (prettiest-caller-name lambda toplevel-name))))

         (setf (xref:xref-context-name context) caller)
         (typecase leaf
           ;; a reference to a LEAF of type GLOBAL-VAR
           (global-var
            (let ((called (global-var-name leaf)))
              ;; a reference to #'C::%SPECIAL-BIND means that we are
              ;; binding a special variable. The information on which
              ;; variable is being bound, and within which function, is
              ;; available in the ref's LEXENV object.
              (cond ((eq called 'c::%special-bind)
                     (setf (xref:xref-context-name context) (caar (lexenv-blocks lexenv)))
                     (xref:register-xref :binds (caar (lexenv-variables lexenv)) context))
                    ;; we're not interested in lexical environments
                    ;; that have no name; they are mostly due to code
                    ;; inserted by the compiler (eg calls to %VERIFY-ARGUMENT-COUNT)
                    ((not caller)
                     :no-caller)
                    ;; we're not interested in lexical environments
                    ;; named "Top-Level Form".
                    ((and (stringp caller)
                          (string= "Top-Level Form" caller))
                     :top-level-form)
                    ((not (eq 'original-source-start (first (node-source-path node))))
                     #+nil
                     (format *debug-io* "~&Ignoring compiler-generated call with source-path ~A~%"
                             (node-source-path node))
                     :compiler-generated)
                    ((not called)
                     :no-called)
                    ((eq :global-function (global-var-kind leaf))
                     (xref:register-xref :calls called context)
                     (xref:register-xref :called caller context))
                    ((eq :special (global-var-kind leaf))
                     (xref:register-xref :references called context)))))
           ;; a reference to a LEAF of type CONSTANT
           (constant
            (let ((called (constant-name leaf)))
              (and called
                   (not (eq called t))    ; ignore references to trivial variables
                   caller
                   (not (and (stringp caller) (string= "Top-Level Form" caller)))
                   (xref:register-xref :references called context)))))))

      ;; a variable is being set
      (cset
       (let* ((variable (set-var node))
              (lexenv (set-lexenv node)))
         (and (global-var-p variable)
              (eq :special (global-var-kind variable))
              (let* ((lblock (first (lexenv-blocks lexenv)))
                     (user (or (and lblock (car lblock)) toplevel-name))
                     (used (global-var-name variable)))
                (setf (xref:xref-context-name context) user)
                (and user used (xref:register-xref :sets used context))))))

      ;; nodes of type BIND are used to bind symbols to LAMBDA objects
      ;; (including for macros), but apparently not for bindings of
      ;; variables.
      (bind
       t))))


;; RECORD-COMPONENT-XREFS -- internal
;;
(defun record-component-xrefs (component)
  (declare (type component component))
  (do ((block (block-next (component-head component)) (block-next block)))
      ((null (block-next block)))
    (let ((fun (block-home-lambda block))
          (name (component-name component))
          (this-cont (block-start block))
          (last (block-last block)))
      (unless (eq :deleted (functional-kind fun))
        (loop
         (let ((node (continuation-next this-cont)))
           (record-node-xrefs node name)
           (let ((cont (node-cont node)))
             (when (eq node last) (return))
             (setq this-cont cont))))))))

;; EOF
