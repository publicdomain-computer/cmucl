;;;-*-Mode:LISP; Package: PCL -*-
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

(ext:file-comment
  "$Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/pcl/low.lisp,v 1.22 2003/03/22 16:15:16 gerd Exp $")

;;; 
;;; This file contains optimized low-level constructs for PCL.
;;; 

(in-package :pcl)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *optimize-speed* '(optimize (speed 3) (safety 0)
			     (ext:inhibit-warnings 3) #+small (debug 0.5))))

;;; Various macros that include necessary declarations for maximum
;;; performance.

(defmacro %svref (vector index)
  `(locally (declare #.*optimize-speed*
		     (inline svref))
	    (svref (the simple-vector ,vector) (the fixnum ,index))))

(defsetf %svref %set-svref)

(defmacro %set-svref (vector index new-value)
  ;; Do it this way so that the evaluation of NEW-VALUE doesn't fall
  ;; under the *OPTIMIZE-SPEED*.
  (ext:once-only ((value new-value))
    `(locally (declare #.*optimize-speed* (inline svref))
       (setf (svref (the simple-vector ,vector) (the fixnum ,index))
	     ,value))))

;;;
;;; With-Pcl-Lock
;;;
;;; Evaluate the body in such a way that no other code that is
;;; running PCL can be run during that evaluation.
;;;
;;; Note that the MP version, which uses a PCL-specific lock
;;; is rather experimental, in that it is not currently clear
;;; if the code inside with-pcl-lock only has to prevent other
;;; threads from entering such sections, or if it really has to
;;; prevent _ALL_ other PCL code (e.g. GF invocations, etc.)
;;; from running.  If the latter then we really need to identify
;;; all places that need to acquire the PCL lock, if we are going to
;;; support multiple concurrent threads/processes on SMP machines.
;;; 
;;; For the moment we do the experimental thing, and fix any bugs
;;; that occur as a result of this.             -- PRM 2002-09-06
;;;

#-MP
(defmacro with-pcl-lock (&body body)
  `(sys:without-interrupts ,@body))

#+MP
(defvar *global-pcl-lock* (mp:make-lock "Global PCL Lock"))

#+MP
(defmacro with-pcl-lock (&body body)
  `(mp:with-lock-held (*global-pcl-lock*)
     ,@body))



;;;
;;; set-function-name
;;; When given a function should give this function the name <new-name>.
;;; Note that <new-name> is sometimes a list. 
;;;
;;; When given a funcallable instance, set-function-name MUST side-effect
;;; that FIN to give it the name.  When given any other kind of function
;;; set-function-name is allowed to return new function which is the 'same'
;;; except that it has the name.
;;;
;;; In all cases, set-function-name must return the new (or same) function.
;;; 
(defun set-function-name (function new-name)
  "Set the name of a compiled function object and return the function."
  (declare (special *boot-state* *the-class-standard-generic-function*))
  (when (ext:valid-function-name-p function)
    (setq function (fdefinition function)))
  (when (funcallable-instance-p function)
    (if (if (eq *boot-state* 'complete)
	    (typep function 'generic-function)
	    (eq (class-of function) *the-class-standard-generic-function*))
	(setf (kernel:%funcallable-instance-info function 1) new-name)
	(typecase function
	  (kernel:byte-closure
	   (set-function-name (kernel:byte-closure-function function)
			      new-name))
	  (kernel:byte-function
	   (setf (kernel:byte-function-name function) new-name))
	  (eval:interpreted-function
	   (setf (eval:interpreted-function-name function) new-name)))))
  (when (memq (car-safe new-name) '(method fast-method slot-accessor))
    (setf (fdefinition new-name) function))
  function)
	
(defun symbolicate (pkg &rest things)
  (let ((*package* pkg))
    (apply #'ext:symbolicate things)))


;;;
;;; COMPILE-LAMBDA
;;;
;;; This is called by PCL to compile generated code (i.e. lambda
;;; forms).
;;;
(defvar *compile-lambda-break-p* nil
  "PCL debugging aid that breaks into the debugger each time
`compile-lambda' is invoked.")

(defvar *compile-lambda-silent-p* t
  "If true (the default), then `compile-lambda' will try to silence
the compiler as completely as possible.  Currently this means that
`*compile-print*' will be bound to nil during compilation.")

(defun compile-lambda (lambda-form)
  (when *compile-lambda-break-p* (break))
  (let ((*compile-print* (if *compile-lambda-silent-p* nil *compile-print*)))
    (compile nil lambda-form)))

;;;
;;; This macro will precompile various PCL-generated code fragments,
;;; so that those won't have to be compiled lazily at run-time.  For
;;; correct usage the invocation of `precompile-random-code-segments'
;;; needs to be put in a file, which is compiled via `compile-file',
;;; and then loaded.
;;;

(defmacro precompile-random-code-segments (&optional system)
  `(progn
     (eval-when (:compile-toplevel)
       (update-dispatch-dfuns))
     (precompile-function-generators ,system)
     (precompile-dfun-constructors ,system)
     (precompile-ctors)))


;;;; STD-INSTANCE

;;; Under CMU17 conditional, STD-INSTANCE-P is only used to discriminate
;;; between functions (including FINs) and normal instances, so we can return
;;; true on structures also.  A few uses of (or std-instance-p fsc-instance-p)
;;; are changed to pcl-instance-p.
;;;
(defmacro std-instance-p (x)
  `(kernel:%instancep ,x))

;;; PCL-INSTANCE-P is implemented via a compiler transform so that the
;;; test can be optimised away when the result is known, such as is
;;; typically the case during slot access within methods, see
;;; get-slots-or-nil below.

(in-package "C")

(defknown pcl::pcl-instance-p (t) boolean
  (movable foldable flushable explicit-check))

(deftransform pcl::pcl-instance-p ((object))
  (let* ((otype (continuation-type object))
	 (std-obj (specifier-type 'pcl::std-object)))
    ;; Flush tests whose result is known at compile time.
    (cond ((csubtypep otype std-obj)
	   't)
	  ((not (types-intersect otype std-obj))
	   'nil)
	  ((and (kernel::standard-class-p otype)
		(pcl::info-std-class-p (kernel:%class-name otype)))
	   't)
	  (t
	   `(typep (kernel:layout-of object) 'pcl::wrapper)))))

(in-package "PCL")

;;; Definition for interpreted code.
(defun pcl-instance-p (x)
  (typep (kernel:layout-of x) 'wrapper))

(let ((hash-code 0))
  (declare (fixnum hash-code))
  (defun get-instance-hash-code ()
    (if (< hash-code most-positive-fixnum)
	(incf hash-code)
	(setq hash-code 0))))

;;;
;;; We define this as STANDARD-INSTANCE, since we're going to clobber the
;;; layout with some standard-instance layout as soon as we make it, and we
;;; want the accesor to still be type-correct.
;;;
(defstruct (standard-instance
	    (:predicate nil)
	    (:constructor %%allocate-instance--class ())
	    (:alternate-metaclass kernel:instance kernel::standard-class
				  kernel:make-standard-class))
  (slots nil)
  (hash-code (get-instance-hash-code) :type fixnum))


;;; Both of these operations "work" on structures, which allows the above
;;; weakening of std-instance-p.
;;;
(defmacro std-instance-slots (x) `(kernel:%instance-ref ,x 1))
(defmacro std-instance-hash (x) `(kernel:%instance-ref ,x 2))
(defmacro std-instance-wrapper (x) `(kernel:%instance-layout ,x))

(defmacro built-in-or-structure-wrapper (x) `(kernel:layout-of ,x))

(defmacro get-wrapper (inst)
  (ext:once-only ((wrapper `(wrapper-of ,inst)))
    `(progn
       (assert (typep ,wrapper 'wrapper) () "What kind of instance is this?")
       ,wrapper)))

(defmacro get-instance-wrapper-or-nil (inst)
  (ext:once-only ((wrapper `(wrapper-of ,inst)))
    `(if (typep ,wrapper 'wrapper)
	 ,wrapper
	 nil)))

(defmacro get-hash (instance)
  `(cond ((std-instance-p ,instance) (std-instance-hash ,instance))
	 ((fsc-instance-p ,instance) (fsc-instance-hash ,instance))
	 (t (internal-error "What kind of instance is this?"))))

(defmacro get-slots (inst)
  `(cond ((std-instance-p ,inst) (std-instance-slots ,inst))
	 ((fsc-instance-p ,inst) (fsc-instance-slots ,inst))
	 (t (internal-error "What kind of instance is this?"))))

(defmacro get-slots-or-nil (inst)
  (ext:once-only ((n-inst inst))
    `(when (pcl-instance-p ,n-inst)
       (if (std-instance-p ,n-inst)
	   (std-instance-slots ,n-inst)
	   (fsc-instance-slots ,n-inst)))))

(defun print-std-instance (instance stream depth) ;A temporary definition used
  (declare (ignore depth))		          ;for debugging the bootstrap
  (printing-random-thing (instance stream)        ;code of PCL (See high.lisp).
    (let ((class (class-of instance)))
      (if (or (eq class (find-class 'standard-class nil))
	      (eq class (find-class 'funcallable-standard-class nil))
	      (eq class (find-class 'built-in-class nil)))
	  (format stream "~a ~a" (early-class-name class)
		  (early-class-name instance))
	  (format stream "~a" (early-class-name class))))))

;;; Slot access itself

(defmacro %slot-ref (slots index)
  `(%svref ,slots ,index))

(defmacro slot-ref (slots index)
  `(svref ,slots ,index))

;;;
;;; The problem with unbound markers is that they cannot be dumped to
;;; fasl files.  So, we need to create unbound markers in some way,
;;; which can be done by returning one from a compiled function.  The
;;; problem with that is that it's awefully slow, and inlining the
;;; function creating the unbound marker doesn't work with interpreted
;;; code, because C::%%PRIMITIVE, which is used to create the unbound
;;; marker isn't defined when inlining happens.  Using LOAD-TIME-VALUE
;;; and a symbol macro is relatively fast, but not fast enough.
;;;
;;; Maybe one should support dumping unbound markers to fasl files?
;;;
#+nil
(progn
  (defun make-unbound-marker ()
    (lisp::%primitive c:make-other-immediate-type 0 vm:unbound-marker-type))
  (define-symbol-macro +slot-unbound+
      (load-time-value (make-unbound-marker) t)))

#-nil
(defconstant +slot-unbound+ '..slot-unbound..)

(defun internal-error (format-control &rest format-args)
  (error (format nil "~~@<Internal error: ~?~~@:>"
		 format-control format-args)))


;;;; Structure-instance stuff:

(defun structure-instance-p (x)
  (typep x 'lisp:structure-object))

(defun structurep (x)
  (typep x 'lisp:structure-object))

(defun structure-type (x)
  (kernel:%class-name (kernel:layout-class (kernel:%instance-layout x))))

;;;
;;; Return true if TYPE is the name of a structure.  Note that we
;;; return false for conditions, which aren't "real" structures.
;;;
(defun structure-type-p (type)
  (and (symbolp type)
       (not (condition-type-p type))
       (let ((class (kernel::find-class type nil)))
	 (and class
	      ;; class may not be complete if created by
	      ;; inform-type-system-aboutd-std-class
	      (kernel:%class-layout class)
	      (typep (kernel:layout-info (kernel:%class-layout class))
		     'kernel:defstruct-description)))))

;;;
;;; Returne true if TYPE is the name of a condition.
;;;
(defun condition-type-p (type)
  (and (symbolp type)
       (conditions::condition-class-p (kernel::find-class type nil))))

(defun get-structure-dd (type)
  (kernel:layout-info (kernel:%class-layout (kernel::find-class type))))

(defun structure-type-included-type-name (type)
  (let ((include (kernel::dd-include (get-structure-dd type))))
    (if (consp include)
	(car include)
	include)))

(defun structure-type-slot-description-list (type)
  (nthcdr (length (let ((include (structure-type-included-type-name type)))
		    (and include (kernel:dd-slots (get-structure-dd include)))))
	  (kernel:dd-slots (get-structure-dd type))))

(defun structure-slotd-name (slotd)
  (kernel:dsd-name slotd))

(defun structure-slotd-accessor-symbol (slotd)
  (kernel:dsd-accessor slotd))

(defun structure-slotd-reader-function (slotd)
  (fdefinition (kernel:dsd-accessor slotd)))

(defun structure-slotd-writer-function (slotd)
  (unless (kernel:dsd-read-only slotd)
    (fdefinition `(setf ,(kernel:dsd-accessor slotd)))))

(defun structure-slotd-type (slotd)
  (kernel:dsd-type slotd))

(defun structure-slotd-init-form (slotd)
  (kernel::dsd-default slotd))


;;;
;;; Extractor for source context information, which is used by the
;;; compiler to indicate progress and context information for error
;;; reporting.
;;;

(defun kernel::kernel-class-of-pcl-class (class)
  (kernel::find-class (class-name class)))

(in-package "C")

(def-source-context pcl:defmethod (name &rest stuff)
  (let ((arg-pos (position-if #'listp stuff)))
    (if arg-pos
	`(pcl:defmethod ,name ,@(subseq stuff 0 arg-pos)
	   ,(nth-value 2 (pcl::parse-specialized-lambda-list
			  (elt stuff arg-pos))))
	`(pcl:defmethod ,name "<illegal syntax>"))))

(in-package "PCL")

(defun early-pcl-init ()
  ;; defsys
  (setq *the-pcl-package* (find-package "PCL"))
  (setq *boot-state* nil)
  (setq *dfun-constructors* nil)
  ;;
  ;; Show us when we use the compiler.
  (setq *compile-lambda-silent-p* nil)
  ;;
  ;; Wait with installing optimized constructors until we can
  ;; invoke the compiler.
  (setq *cold-boot-state* t))

(defun final-pcl-init ()
  (setq *cold-boot-state* nil)
  (setq *compile-lambda-silent-p* t)
  (dolist (ctor *all-ctors*)
    (install-optimized-constructor ctor)))

;;; end of low.lisp
