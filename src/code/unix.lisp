;;; -*- Package: UNIX -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the CMU Common Lisp project at
;;; Carnegie Mellon University, and has been placed in the public domain.
;;;
(ext:file-comment
  "$Header: src/code/unix.lisp $")
;;;
;;; **********************************************************************
;;;
;;; This file contains the UNIX low-level support, just enough to run
;;; CMUCL.
;;;
(in-package "UNIX")

(intl:textdomain "cmucl-unix")

(pushnew :unix *features*)

;; Check the G_BROKEN_FILENAMES environment variable; if set the encoding
;; is locale-dependent...else use :utf-8 on Unicode Lisps.  On 8 bit Lisps
;; it must be set to :iso8859-1 (or left as NIL), making files with
;; non-Latin-1 characters "mojibake", but otherwise they'll be inaccessible.
;; Must be set to NIL initially to enable building Lisp!
(defvar *filename-encoding* nil)

(eval-when (:compile-toplevel)
  (defmacro %name->file (string)
    `(if *filename-encoding*
	 (string-encode ,string *filename-encoding*)
	 ,string))
  (defmacro %file->name (string)
    `(if *filename-encoding*
	 (string-decode ,string *filename-encoding*)
	 ,string)))


(export '())

;;;; System calls.

(defmacro %syscall ((name (&rest arg-types) result-type)
		    success-form &rest args)
  `(let* ((fn (extern-alien ,name (function ,result-type ,@arg-types)))
	  (result (alien-funcall fn ,@args)))
     (if (eql -1 result)
	 (values nil (unix-errno))
	 ,success-form)))

(defmacro syscall ((name &rest arg-types) success-form &rest args)
  `(%syscall (,name (,@arg-types) int) ,success-form ,@args))

(defmacro void-syscall ((name &rest arg-types) &rest args)
  `(syscall (,name ,@arg-types) (values t 0) ,@args))

;; Use getcwd instead of getwd.  But what should we do if the path
;; won't fit?  Try again with a larger size?  We don't do that right
;; now.
(defun unix-current-directory ()
  ;; 5120 is some randomly selected maximum size for the buffer for getcwd.
  (with-alien ((buf (array c-call:char 5120)))
    (let ((result
	   (alien-funcall 
	    (extern-alien "getcwd"
				(function (* c-call:char)
					  (* c-call:char) c-call:int))
	    (cast buf (* c-call:char))
	    5120)))
	
      (values (not (zerop
		    (sap-int (alien-sap result))))
	      (%file->name (cast buf c-call:c-string))))))

;;; Unix-chdir accepts a directory name and makes that the
;;; current working directory.

(defun unix-chdir (path)
  _N"Given a file path string, unix-chdir changes the current working 
   directory to the one specified."
  (declare (type unix-pathname path))
  (void-syscall ("chdir" c-string) (%name->file path)))

;;; Unix-lseek accepts a file descriptor, an offset, and whence value.

(defconstant l_set 0 _N"set the file pointer")
(defconstant l_incr 1 _N"increment the file pointer")
(defconstant l_xtnd 2 _N"extend the file size")

(defun unix-lseek (fd offset whence)
  _N"Unix-lseek accepts a file descriptor and moves the file pointer ahead
   a certain offset for that file.  Whence can be any of the following:

   l_set        Set the file pointer.
   l_incr       Increment the file pointer.
   l_xtnd       Extend the file size.
  _N"
  (declare (type unix-fd fd)
	   (type file-offset offset)
	   (type (integer 0 2) whence))
  (off-t-syscall ("lseek" (int off-t int)) fd offset whence))

;;; Unix-open accepts a pathname (a simple string), flags, and mode and
;;; attempts to open file with name pathname.

(defconstant o_rdonly 0 _N"Read-only flag.") 
(defconstant o_wronly 1 _N"Write-only flag.")
(defconstant o_rdwr 2   _N"Read-write flag.")
#+(or hpux linux svr4)
(defconstant o_ndelay #-linux 4 #+linux #o4000 _N"Non-blocking I/O")
(defconstant o_append #-linux #o10 #+linux #o2000   _N"Append flag.")
#+(or hpux svr4 linux)
(progn
  (defconstant o_creat #-linux #o400 #+linux #o100 _N"Create if nonexistant flag.") 
  (defconstant o_trunc #o1000  _N"Truncate flag.")
  (defconstant o_excl #-linux #o2000 #+linux #o200 _N"Error if already exists.")
  (defconstant o_noctty #+linux #o400 #+hpux #o400000 #+(or irix solaris) #x800
               _N"Don't assign controlling tty"))
#+(or hpux svr4 BSD)
(defconstant o_nonblock #+hpux #o200000 #+(or irix solaris) #x80 #+BSD #x04
  _N"Non-blocking mode")
#+BSD
(defconstant o_ndelay o_nonblock) ; compatibility
#+linux
(progn
   (defconstant o_sync #o10000 _N"Synchronous writes (on ext2)"))

#-(or hpux svr4 linux)
(progn
  (defconstant o_creat #o1000  _N"Create if nonexistant flag.") 
  (defconstant o_trunc #o2000  _N"Truncate flag.")
  (defconstant o_excl #o4000  _N"Error if already exists."))

(defun unix-open (path flags mode)
  _N"Unix-open opens the file whose pathname is specified by path
   for reading and/or writing as specified by the flags argument.
   The flags argument can be:

     o_rdonly        Read-only flag.
     o_wronly        Write-only flag.
     o_rdwr          Read-and-write flag.
     o_append        Append flag.
     o_creat         Create-if-nonexistant flag.
     o_trunc         Truncate-to-size-0 flag.

   If the o_creat flag is specified, then the file is created with
   a permission of argument mode if the file doesn't exist.  An
   integer file descriptor is returned by unix-open."
  (declare (type unix-pathname path)
	   (type fixnum flags)
	   (type unix-file-mode mode))
  (int-syscall (#+solaris "open64" #-solaris "open" c-string int int)
	       (%name->file path) flags mode))

;;; Unix-close accepts a file descriptor and attempts to close the file
;;; associated with it.

(defun unix-close (fd)
  _N"Unix-close takes an integer file descriptor as an argument and
   closes the file associated with it.  T is returned upon successful
   completion, otherwise NIL and an error number."
  (declare (type unix-fd fd))
  (void-syscall ("close" int) fd))

;;; Unix-read accepts a file descriptor, a buffer, and the length to read.
;;; It attempts to read len bytes from the device associated with fd
;;; and store them into the buffer.  It returns the actual number of
;;; bytes read.

(defun unix-read (fd buf len)
  _N"Unix-read attempts to read from the file described by fd into
   the buffer buf until it is full.  Len is the length of the buffer.
   The number of bytes actually read is returned or NIL and an error
   number if an error occured."
  (declare (type unix-fd fd)
	   (type (unsigned-byte 32) len))
  #+(or sunos gencgc)
  ;; Note: Under sunos we touch each page before doing the read to give
  ;; the segv handler a chance to fix the permissions.  Otherwise,
  ;; read will return EFAULT.  This also bypasses a bug in 4.1.1 in which
  ;; read fails with EFAULT if the page has never been touched even if
  ;; the permissions are okay.
  ;;
  ;; (Is this true for Solaris?)
  ;;
  ;; Also, with gencgc, the collector tries to keep raw objects like
  ;; strings in separate pages that are not write-protected.  However,
  ;; this isn't always true.  Thus, BUF will sometimes be
  ;; write-protected and the kernel doesn't like writing to
  ;; write-protected pages.  So go through and touch each page to give
  ;; the segv handler a chance to unprotect the pages.
  (without-gcing
   (let* ((page-size (get-page-size))
	  (1-page-size (1- page-size))
	  (sap (etypecase buf
		 (system-area-pointer buf)
		 (vector (vector-sap buf))))
	  (end (sap+ sap len)))
     (declare (type (and fixnum unsigned-byte) page-size 1-page-size)
	      (type system-area-pointer sap end)
	      (optimize (speed 3) (safety 0)))
     ;; Touch the beginning of every page
     (do ((sap (int-sap (logand (sap-int sap)
				(logxor 1-page-size (ldb (byte 32 0) -1))))
	       (sap+ sap page-size)))
	 ((sap>= sap end))
       (declare (type system-area-pointer sap))
       (setf (sap-ref-8 sap 0) (sap-ref-8 sap 0)))))
  (int-syscall ("read" int (* char) int) fd buf len))

;;; Unix-write accepts a file descriptor, a buffer, an offset, and the
;;; length to write.  It attempts to write len bytes to the device
;;; associated with fd from the buffer starting at offset.  It returns
;;; the actual number of bytes written.

(defun unix-write (fd buf offset len)
  _N"Unix-write attempts to write a character buffer (buf) of length
   len to the file described by the file descriptor fd.  NIL and an
   error is returned if the call is unsuccessful."
  (declare (type unix-fd fd)
	   (type (unsigned-byte 32) offset len))
  (int-syscall ("write" int (* char) int)
	       fd
	       (with-alien ((ptr (* char) (etypecase buf
					    ((simple-array * (*))
					     (vector-sap buf))
					    (system-area-pointer
					     buf))))
		 (addr (deref ptr offset)))
	       len))
;;; Unix-getpagesize returns the number of bytes in the system page.

(defun unix-getpagesize ()
  _N"Unix-getpagesize returns the number of bytes in a system page."
  (int-syscall ("getpagesize")))

(defun unix-gethostname ()
  _N"Unix-gethostname returns the name of the host machine as a string."
  (with-alien ((buf (array char 256)))
    (syscall* ("gethostname" (* char) int)
	      (cast buf c-string)
	      (cast buf (* char)) 256)))

;;; Unix-exit terminates a program.

(defun unix-exit (&optional (code 0))
  _N"Unix-exit terminates the current process with an optional
   error code.  If successful, the call doesn't return.  If
   unsuccessful, the call returns NIL and an error number."
  (declare (type (signed-byte 32) code))
  (void-syscall ("exit" int) code))

#+(and bsd (not netbsd))
(def-alien-type nil
  (struct stat
    (st-dev dev-t)
    (st-ino ino-t)
    (st-mode mode-t)
    (st-nlink nlink-t)
    (st-uid uid-t)
    (st-gid gid-t)
    (st-rdev dev-t)
    (st-atime (struct timespec-t))
    (st-mtime (struct timespec-t))
    (st-ctime (struct timespec-t))
    (st-size off-t)
    (st-blocks off-t)
    (st-blksize unsigned-long)
    (st-flags   unsigned-long)
    (st-gen     unsigned-long)
    (st-lspare  long)
    (st-qspare (array long 4))))

(defun unix-stat (name)
  _N"Unix-stat retrieves information about the specified
   file returning them in the form of multiple values.
   See the UNIX Programmer's Manual for a description
   of the values returned.  If the call fails, then NIL
   and an error number is returned instead."
  (declare (type unix-pathname name))
  (when (string= name "")
    (setf name "."))
  (with-alien ((buf (struct stat)))
    (syscall (#-netbsd "stat" #+netbsd "__stat50" c-string (* (struct stat)))
	     (extract-stat-results buf)
	     (%name->file name) (addr buf))))

(defun unix-lstat (name)
  _N"Unix-lstat is similar to unix-stat except the specified
   file must be a symbolic link."
  (declare (type unix-pathname name))
  (with-alien ((buf (struct stat)))
    (syscall (#-netbsd "lstat" #+netbsd "__lstat50" c-string (* (struct stat)))
	     (extract-stat-results buf)
	     (%name->file name) (addr buf))))

(defun unix-fstat (fd)
  _N"Unix-fstat is similar to unix-stat except the file is specified
   by the file descriptor fd."
  (declare (type unix-fd fd))
  (with-alien ((buf (struct stat)))
    (syscall (#-netbsd "fstat" #+netbsd "__fstat50" int (* (struct stat)))
	     (extract-stat-results buf)
	     fd (addr buf))))

;;;; Support routines for dealing with unix pathnames.

(defconstant s-ifmt   #o0170000)
(defconstant s-ifdir  #o0040000)
(defconstant s-ifchr  #o0020000)
#+linux (defconstant s-ififo #x0010000)
(defconstant s-ifblk  #o0060000)
(defconstant s-ifreg  #o0100000)
(defconstant s-iflnk  #o0120000)
(defconstant s-ifsock #o0140000)
(defconstant s-isuid #o0004000)
(defconstant s-isgid #o0002000)
(defconstant s-isvtx #o0001000)
(defconstant s-iread #o0000400)
(defconstant s-iwrite #o0000200)
(defconstant s-iexec #o0000100)

(defun unix-file-kind (name &optional check-for-links)
  _N"Returns either :file, :directory, :link, :special, or NIL."
  (declare (simple-string name))
  (multiple-value-bind (res dev ino mode)
		       (if check-for-links
			   (unix-lstat name)
			   (unix-stat name))
    (declare (type (or fixnum null) mode)
	     (ignore dev ino))
    (when res
      (let ((kind (logand mode s-ifmt)))
	(cond ((eql kind s-ifdir) :directory)
	      ((eql kind s-ifreg) :file)
	      ((eql kind s-iflnk) :link)
	      (t :special))))))

(defun unix-maybe-prepend-current-directory (name)
  (declare (simple-string name))
  (if (and (> (length name) 0) (char= (schar name 0) #\/))
      name
      (multiple-value-bind (win dir) (unix-current-directory)
	(if win
	    (concatenate 'simple-string dir "/" name)
	    name))))

(defun unix-resolve-links (pathname)
  _N"Returns the pathname with all symbolic links resolved."
  (declare (simple-string pathname))
  (let ((len (length pathname))
	(pending pathname))
    (declare (fixnum len) (simple-string pending))
    (if (zerop len)
	pathname
	(let ((result (make-string 100 :initial-element (code-char 0)))
	      (fill-ptr 0)
	      (name-start 0))
	  (loop
	    (let* ((name-end (or (position #\/ pending :start name-start) len))
		   (new-fill-ptr (+ fill-ptr (- name-end name-start))))
	      ;; grow the result string, if necessary.  the ">=" (instead of
	      ;; using ">") allows for the trailing "/" if we find this
	      ;; component is a directory.
	      (when (>= new-fill-ptr (length result))
		(let ((longer (make-string (* 3 (length result))
					   :initial-element (code-char 0))))
		  (replace longer result :end1 fill-ptr)
		  (setq result longer)))
	      (replace result pending
		       :start1 fill-ptr
		       :end1 new-fill-ptr
		       :start2 name-start
		       :end2 name-end)
	      (let ((kind (unix-file-kind (if (zerop name-end) "/" result) t)))
		(unless kind (return nil))
		(cond ((eq kind :link)
		       (multiple-value-bind (link err) (unix-readlink result)
			 (unless link
			   (error (intl:gettext "Error reading link ~S: ~S")
				  (subseq result 0 fill-ptr)
				  (get-unix-error-msg err)))
			 (cond ((or (zerop (length link))
				    (char/= (schar link 0) #\/))
				;; It's a relative link
				(fill result (code-char 0)
				      :start fill-ptr
				      :end new-fill-ptr))
			       ((string= result "/../" :end1 4)
				;; It's across the super-root.
				(let ((slash (or (position #\/ result :start 4)
						 0)))
				  (fill result (code-char 0)
					:start slash
					:end new-fill-ptr)
				  (setf fill-ptr slash)))
			       (t
				;; It's absolute.
				(and (> (length link) 0)
				     (char= (schar link 0) #\/))
				(fill result (code-char 0) :end new-fill-ptr)
				(setf fill-ptr 0)))
			 (setf pending
			       (if (= name-end len)
				   link
				   (concatenate 'simple-string
						link
						(subseq pending name-end))))
			 (setf len (length pending))
			 (setf name-start 0)))
		      ((= name-end len)
		       (when (eq kind :directory)
			 (setf (schar result new-fill-ptr) #\/)
			 (incf new-fill-ptr))
		       (return (subseq result 0 new-fill-ptr)))
		      ((eq kind :directory)
		       (setf (schar result new-fill-ptr) #\/)
		       (setf fill-ptr (1+ new-fill-ptr))
		       (setf name-start (1+ name-end)))
		      (t
		       (return nil))))))))))

(defun unix-simplify-pathname (src)
  (declare (simple-string src))
  (let* ((src-len (length src))
	 (dst (make-string src-len))
	 (dst-len 0)
	 (dots 0)
	 (last-slash nil))
    (macrolet ((deposit (char)
			`(progn
			   (setf (schar dst dst-len) ,char)
			   (incf dst-len))))
      (dotimes (src-index src-len)
	(let ((char (schar src src-index)))
	  (cond ((char= char #\.)
		 (when dots
		   (incf dots))
		 (deposit char))
		((char= char #\/)
		 (case dots
		   (0
		    ;; Either ``/...' or ``...//...'
		    (unless last-slash
		      (setf last-slash dst-len)
		      (deposit char)))
		   (1
		    ;; Either ``./...'' or ``..././...''
		    (decf dst-len))
		   (2
		    ;; We've found ..
		    (cond
		     ((and last-slash (not (zerop last-slash)))
		      ;; There is something before this ..
		      (let ((prev-prev-slash
			     (position #\/ dst :end last-slash :from-end t)))
			(cond ((and (= (+ (or prev-prev-slash 0) 2)
				       last-slash)
				    (char= (schar dst (- last-slash 2)) #\.)
				    (char= (schar dst (1- last-slash)) #\.))
			       ;; The something before this .. is another ..
			       (deposit char)
			       (setf last-slash dst-len))
			      (t
			       ;; The something is some random dir.
			       (setf dst-len
				     (if prev-prev-slash
					 (1+ prev-prev-slash)
					 0))
			       (setf last-slash prev-prev-slash)))))
		     (t
		      ;; There is nothing before this .., so we need to keep it
		      (setf last-slash dst-len)
		      (deposit char))))
		   (t
		    ;; Something other than a dot between slashes.
		    (setf last-slash dst-len)
		    (deposit char)))
		 (setf dots 0))
		(t
		 (setf dots nil)
		 (setf (schar dst dst-len) char)
		 (incf dst-len))))))
    (when (and last-slash (not (zerop last-slash)))
      (case dots
	(1
	 ;; We've got  ``foobar/.''
	 (decf dst-len))
	(2
	 ;; We've got ``foobar/..''
	 (unless (and (>= last-slash 2)
		      (char= (schar dst (1- last-slash)) #\.)
		      (char= (schar dst (- last-slash 2)) #\.)
		      (or (= last-slash 2)
			  (char= (schar dst (- last-slash 3)) #\/)))
	   (let ((prev-prev-slash
		  (position #\/ dst :end last-slash :from-end t)))
	     (if prev-prev-slash
		 (setf dst-len (1+ prev-prev-slash))
		 (return-from unix-simplify-pathname "./")))))))
    (cond ((zerop dst-len)
	   "./")
	  ((= dst-len src-len)
	   dst)
	  (t
	   (subseq dst 0 dst-len)))))

;;;; Errno stuff.

(eval-when (compile eval)

(defparameter *compiler-unix-errors* nil)

(defmacro def-unix-error (name number description)
  `(progn
     (eval-when (compile eval)
       (push (cons ,number ,description) *compiler-unix-errors*))
     (defconstant ,name ,number ,description)
     (export ',name)))

(defmacro emit-unix-errors ()
  (let* ((max (apply #'max (mapcar #'car *compiler-unix-errors*)))
	 (array (make-array (1+ max) :initial-element nil)))
    (dolist (error *compiler-unix-errors*)
      (setf (svref array (car error)) (cdr error)))
    `(progn
       (defvar *unix-errors* ',array)
       (declaim (simple-vector *unix-errors*)))))

) ;eval-when

;;; 
;;; From <errno.h>
;;; 
(def-unix-error ESUCCESS 0 _N"Successful")
(def-unix-error EPERM 1 _N"Operation not permitted")
(def-unix-error ENOENT 2 _N"No such file or directory")
(def-unix-error ESRCH 3 _N"No such process")
(def-unix-error EINTR 4 _N"Interrupted system call")
(def-unix-error EIO 5 _N"I/O error")
(def-unix-error ENXIO 6 _N"Device not configured")
(def-unix-error E2BIG 7 _N"Arg list too long")
(def-unix-error ENOEXEC 8 _N"Exec format error")
(def-unix-error EBADF 9 _N"Bad file descriptor")
(def-unix-error ECHILD 10 _N"No child process")
#+bsd(def-unix-error EDEADLK 11 _N"Resource deadlock avoided")
#-bsd(def-unix-error EAGAIN 11 #-linux _N"No more processes" #+linux _N"Try again")
(def-unix-error ENOMEM 12 _N"Out of memory")
(def-unix-error EACCES 13 _N"Permission denied")
(def-unix-error EFAULT 14 _N"Bad address")
(def-unix-error ENOTBLK 15 _N"Block device required")
(def-unix-error EBUSY 16 _N"Device or resource busy")
(def-unix-error EEXIST 17 _N"File exists")
(def-unix-error EXDEV 18 _N"Cross-device link")
(def-unix-error ENODEV 19 _N"No such device")
(def-unix-error ENOTDIR 20 _N"Not a director")
(def-unix-error EISDIR 21 _N"Is a directory")
(def-unix-error EINVAL 22 _N"Invalid argument")
(def-unix-error ENFILE 23 _N"File table overflow")
(def-unix-error EMFILE 24 _N"Too many open files")
(def-unix-error ENOTTY 25 _N"Inappropriate ioctl for device")
(def-unix-error ETXTBSY 26 _N"Text file busy")
(def-unix-error EFBIG 27 _N"File too large")
(def-unix-error ENOSPC 28 _N"No space left on device")
(def-unix-error ESPIPE 29 _N"Illegal seek")
(def-unix-error EROFS 30 _N"Read-only file system")
(def-unix-error EMLINK 31 _N"Too many links")
(def-unix-error EPIPE 32 _N"Broken pipe")
;;; 
;;; Math
(def-unix-error EDOM 33 _N"Numerical argument out of domain")
(def-unix-error ERANGE 34 #-linux _N"Result too large" #+linux _N"Math result not representable")
;;; 
#-(or linux svr4)
(progn
;;; non-blocking and interrupt i/o
(def-unix-error EWOULDBLOCK 35 _N"Operation would block")
#-bsd(def-unix-error EDEADLK 35 _N"Operation would block") ; Ditto
#+bsd(def-unix-error EAGAIN 35 _N"Resource temporarily unavailable")
(def-unix-error EINPROGRESS 36 _N"Operation now in progress")
(def-unix-error EALREADY 37 _N"Operation already in progress")
;;;
;;; ipc/network software
(def-unix-error ENOTSOCK 38 _N"Socket operation on non-socket")
(def-unix-error EDESTADDRREQ 39 _N"Destination address required")
(def-unix-error EMSGSIZE 40 _N"Message too long")
(def-unix-error EPROTOTYPE 41 _N"Protocol wrong type for socket")
(def-unix-error ENOPROTOOPT 42 _N"Protocol not available")
(def-unix-error EPROTONOSUPPORT 43 _N"Protocol not supported")
(def-unix-error ESOCKTNOSUPPORT 44 _N"Socket type not supported")
(def-unix-error EOPNOTSUPP 45 _N"Operation not supported on socket")
(def-unix-error EPFNOSUPPORT 46 _N"Protocol family not supported")
(def-unix-error EAFNOSUPPORT 47 _N"Address family not supported by protocol family")
(def-unix-error EADDRINUSE 48 _N"Address already in use")
(def-unix-error EADDRNOTAVAIL 49 _N"Can't assign requested address")
;;;
;;; operational errors
(def-unix-error ENETDOWN 50 _N"Network is down")
(def-unix-error ENETUNREACH 51 _N"Network is unreachable")
(def-unix-error ENETRESET 52 _N"Network dropped connection on reset")
(def-unix-error ECONNABORTED 53 _N"Software caused connection abort")
(def-unix-error ECONNRESET 54 _N"Connection reset by peer")
(def-unix-error ENOBUFS 55 _N"No buffer space available")
(def-unix-error EISCONN 56 _N"Socket is already connected")
(def-unix-error ENOTCONN 57 _N"Socket is not connected")
(def-unix-error ESHUTDOWN 58 _N"Can't send after socket shutdown")
(def-unix-error ETOOMANYREFS 59 _N"Too many references: can't splice")
(def-unix-error ETIMEDOUT 60 _N"Connection timed out")
(def-unix-error ECONNREFUSED 61 _N"Connection refused")
;;; 
(def-unix-error ELOOP 62 _N"Too many levels of symbolic links")
(def-unix-error ENAMETOOLONG 63 _N"File name too long")
;;; 
(def-unix-error EHOSTDOWN 64 _N"Host is down")
(def-unix-error EHOSTUNREACH 65 _N"No route to host")
(def-unix-error ENOTEMPTY 66 _N"Directory not empty")
;;; 
;;; quotas & resource 
(def-unix-error EPROCLIM 67 _N"Too many processes")
(def-unix-error EUSERS 68 _N"Too many users")
(def-unix-error EDQUOT 69 _N"Disc quota exceeded")
;;;
;;; CMU RFS
(def-unix-error ELOCAL 126 _N"namei should continue locally")
(def-unix-error EREMOTE 127 _N"namei was handled remotely")
;;;
;;; VICE
(def-unix-error EVICEERR 70 _N"Remote file system error _N")
(def-unix-error EVICEOP 71 _N"syscall was handled by Vice")
)
#+svr4
(progn
(def-unix-error ENOMSG 35 _N"No message of desired type")
(def-unix-error EIDRM 36 _N"Identifier removed")
(def-unix-error ECHRNG 37 _N"Channel number out of range")
(def-unix-error EL2NSYNC 38 _N"Level 2 not synchronized")
(def-unix-error EL3HLT 39 _N"Level 3 halted")
(def-unix-error EL3RST 40 _N"Level 3 reset")
(def-unix-error ELNRNG 41 _N"Link number out of range")
(def-unix-error EUNATCH 42 _N"Protocol driver not attached")
(def-unix-error ENOCSI 43 _N"No CSI structure available")
(def-unix-error EL2HLT 44 _N"Level 2 halted")
(def-unix-error EDEADLK 45 _N"Deadlock situation detected/avoided")
(def-unix-error ENOLCK 46 _N"No record locks available")
(def-unix-error ECANCELED 47 _N"Error 47")
(def-unix-error ENOTSUP 48 _N"Error 48")
(def-unix-error EBADE 50 _N"Bad exchange descriptor")
(def-unix-error EBADR 51 _N"Bad request descriptor")
(def-unix-error EXFULL 52 _N"Message tables full")
(def-unix-error ENOANO 53 _N"Anode table overflow")
(def-unix-error EBADRQC 54 _N"Bad request code")
(def-unix-error EBADSLT 55 _N"Invalid slot")
(def-unix-error EDEADLOCK 56 _N"File locking deadlock")
(def-unix-error EBFONT 57 _N"Bad font file format")
(def-unix-error ENOSTR 60 _N"Not a stream device")
(def-unix-error ENODATA 61 _N"No data available")
(def-unix-error ETIME 62 _N"Timer expired")
(def-unix-error ENOSR 63 _N"Out of stream resources")
(def-unix-error ENONET 64 _N"Machine is not on the network")
(def-unix-error ENOPKG 65 _N"Package not installed")
(def-unix-error EREMOTE 66 _N"Object is remote")
(def-unix-error ENOLINK 67 _N"Link has been severed")
(def-unix-error EADV 68 _N"Advertise error")
(def-unix-error ESRMNT 69 _N"Srmount error")
(def-unix-error ECOMM 70 _N"Communication error on send")
(def-unix-error EPROTO 71 _N"Protocol error")
(def-unix-error EMULTIHOP 74 _N"Multihop attempted")
(def-unix-error EBADMSG 77 _N"Not a data message")
(def-unix-error ENAMETOOLONG 78 _N"File name too long")
(def-unix-error EOVERFLOW 79 _N"Value too large for defined data type")
(def-unix-error ENOTUNIQ 80 _N"Name not unique on network")
(def-unix-error EBADFD 81 _N"File descriptor in bad state")
(def-unix-error EREMCHG 82 _N"Remote address changed")
(def-unix-error ELIBACC 83 _N"Can not access a needed shared library")
(def-unix-error ELIBBAD 84 _N"Accessing a corrupted shared library")
(def-unix-error ELIBSCN 85 _N".lib section in a.out corrupted")
(def-unix-error ELIBMAX 86 _N"Attempting to link in more shared libraries than system limit")
(def-unix-error ELIBEXEC 87 _N"Can not exec a shared library directly")
(def-unix-error EILSEQ 88 _N"Error 88")
(def-unix-error ENOSYS 89 _N"Operation not applicable")
(def-unix-error ELOOP 90 _N"Number of symbolic links encountered during path name traversal exceeds MAXSYMLINKS")
(def-unix-error ERESTART 91 _N"Error 91")
(def-unix-error ESTRPIPE 92 _N"Error 92")
(def-unix-error ENOTEMPTY 93 _N"Directory not empty")
(def-unix-error EUSERS 94 _N"Too many users")
(def-unix-error ENOTSOCK 95 _N"Socket operation on non-socket")
(def-unix-error EDESTADDRREQ 96 _N"Destination address required")
(def-unix-error EMSGSIZE 97 _N"Message too long")
(def-unix-error EPROTOTYPE 98 _N"Protocol wrong type for socket")
(def-unix-error ENOPROTOOPT 99 _N"Option not supported by protocol")
(def-unix-error EPROTONOSUPPORT 120 _N"Protocol not supported")
(def-unix-error ESOCKTNOSUPPORT 121 _N"Socket type not supported")
(def-unix-error EOPNOTSUPP 122 _N"Operation not supported on transport endpoint")
(def-unix-error EPFNOSUPPORT 123 _N"Protocol family not supported")
(def-unix-error EAFNOSUPPORT 124 _N"Address family not supported by protocol family")
(def-unix-error EADDRINUSE 125 _N"Address already in use")
(def-unix-error EADDRNOTAVAIL 126 _N"Cannot assign requested address")
(def-unix-error ENETDOWN 127 _N"Network is down")
(def-unix-error ENETUNREACH 128 _N"Network is unreachable")
(def-unix-error ENETRESET 129 _N"Network dropped connection because of reset")
(def-unix-error ECONNABORTED 130 _N"Software caused connection abort")
(def-unix-error ECONNRESET 131 _N"Connection reset by peer")
(def-unix-error ENOBUFS 132 _N"No buffer space available")
(def-unix-error EISCONN 133 _N"Transport endpoint is already connected")
(def-unix-error ENOTCONN 134 _N"Transport endpoint is not connected")
(def-unix-error ESHUTDOWN 143 _N"Cannot send after socket shutdown")
(def-unix-error ETOOMANYREFS 144 _N"Too many references: cannot splice")
(def-unix-error ETIMEDOUT 145 _N"Connection timed out")
(def-unix-error ECONNREFUSED 146 _N"Connection refused")
(def-unix-error EHOSTDOWN 147 _N"Host is down")
(def-unix-error EHOSTUNREACH 148 _N"No route to host")
(def-unix-error EWOULDBLOCK 11 _N"Resource temporarily unavailable")
(def-unix-error EALREADY 149 _N"Operation already in progress")
(def-unix-error EINPROGRESS 150 _N"Operation now in progress")
(def-unix-error ESTALE 151 _N"Stale NFS file handle")
)
#+linux
(progn
(def-unix-error  EDEADLK         35     _N"Resource deadlock would occur")
(def-unix-error  ENAMETOOLONG    36     _N"File name too long")
(def-unix-error  ENOLCK          37     _N"No record locks available")
(def-unix-error  ENOSYS          38     _N"Function not implemented")
(def-unix-error  ENOTEMPTY       39     _N"Directory not empty")
(def-unix-error  ELOOP           40     _N"Too many symbolic links encountered")
(def-unix-error  EWOULDBLOCK     11     _N"Operation would block")
(def-unix-error  ENOMSG          42     _N"No message of desired type")
(def-unix-error  EIDRM           43     _N"Identifier removed")
(def-unix-error  ECHRNG          44     _N"Channel number out of range")
(def-unix-error  EL2NSYNC        45     _N"Level 2 not synchronized")
(def-unix-error  EL3HLT          46     _N"Level 3 halted")
(def-unix-error  EL3RST          47     _N"Level 3 reset")
(def-unix-error  ELNRNG          48     _N"Link number out of range")
(def-unix-error  EUNATCH         49     _N"Protocol driver not attached")
(def-unix-error  ENOCSI          50     _N"No CSI structure available")
(def-unix-error  EL2HLT          51     _N"Level 2 halted")
(def-unix-error  EBADE           52     _N"Invalid exchange")
(def-unix-error  EBADR           53     _N"Invalid request descriptor")
(def-unix-error  EXFULL          54     _N"Exchange full")
(def-unix-error  ENOANO          55     _N"No anode")
(def-unix-error  EBADRQC         56     _N"Invalid request code")
(def-unix-error  EBADSLT         57     _N"Invalid slot")
(def-unix-error  EDEADLOCK       EDEADLK     _N"File locking deadlock error")
(def-unix-error  EBFONT          59     _N"Bad font file format")
(def-unix-error  ENOSTR          60     _N"Device not a stream")
(def-unix-error  ENODATA         61     _N"No data available")
(def-unix-error  ETIME           62     _N"Timer expired")
(def-unix-error  ENOSR           63     _N"Out of streams resources")
(def-unix-error  ENONET          64     _N"Machine is not on the network")
(def-unix-error  ENOPKG          65     _N"Package not installed")
(def-unix-error  EREMOTE         66     _N"Object is remote")
(def-unix-error  ENOLINK         67     _N"Link has been severed")
(def-unix-error  EADV            68     _N"Advertise error")
(def-unix-error  ESRMNT          69     _N"Srmount error")
(def-unix-error  ECOMM           70     _N"Communication error on send")
(def-unix-error  EPROTO          71     _N"Protocol error")
(def-unix-error  EMULTIHOP       72     _N"Multihop attempted")
(def-unix-error  EDOTDOT         73     _N"RFS specific error")
(def-unix-error  EBADMSG         74     _N"Not a data message")
(def-unix-error  EOVERFLOW       75     _N"Value too large for defined data type")
(def-unix-error  ENOTUNIQ        76     _N"Name not unique on network")
(def-unix-error  EBADFD          77     _N"File descriptor in bad state")
(def-unix-error  EREMCHG         78     _N"Remote address changed")
(def-unix-error  ELIBACC         79     _N"Can not access a needed shared library")
(def-unix-error  ELIBBAD         80     _N"Accessing a corrupted shared library")
(def-unix-error  ELIBSCN         81     _N".lib section in a.out corrupted")
(def-unix-error  ELIBMAX         82     _N"Attempting to link in too many shared libraries")
(def-unix-error  ELIBEXEC        83     _N"Cannot exec a shared library directly")
(def-unix-error  EILSEQ          84     _N"Illegal byte sequence")
(def-unix-error  ERESTART        85     _N"Interrupted system call should be restarted _N")
(def-unix-error  ESTRPIPE        86     _N"Streams pipe error")
(def-unix-error  EUSERS          87     _N"Too many users")
(def-unix-error  ENOTSOCK        88     _N"Socket operation on non-socket")
(def-unix-error  EDESTADDRREQ    89     _N"Destination address required")
(def-unix-error  EMSGSIZE        90     _N"Message too long")
(def-unix-error  EPROTOTYPE      91     _N"Protocol wrong type for socket")
(def-unix-error  ENOPROTOOPT     92     _N"Protocol not available")
(def-unix-error  EPROTONOSUPPORT 93     _N"Protocol not supported")
(def-unix-error  ESOCKTNOSUPPORT 94     _N"Socket type not supported")
(def-unix-error  EOPNOTSUPP      95     _N"Operation not supported on transport endpoint")
(def-unix-error  EPFNOSUPPORT    96     _N"Protocol family not supported")
(def-unix-error  EAFNOSUPPORT    97     _N"Address family not supported by protocol")
(def-unix-error  EADDRINUSE      98     _N"Address already in use")
(def-unix-error  EADDRNOTAVAIL   99     _N"Cannot assign requested address")
(def-unix-error  ENETDOWN        100    _N"Network is down")
(def-unix-error  ENETUNREACH     101    _N"Network is unreachable")
(def-unix-error  ENETRESET       102    _N"Network dropped connection because of reset")
(def-unix-error  ECONNABORTED    103    _N"Software caused connection abort")
(def-unix-error  ECONNRESET      104    _N"Connection reset by peer")
(def-unix-error  ENOBUFS         105    _N"No buffer space available")
(def-unix-error  EISCONN         106    _N"Transport endpoint is already connected")
(def-unix-error  ENOTCONN        107    _N"Transport endpoint is not connected")
(def-unix-error  ESHUTDOWN       108    _N"Cannot send after transport endpoint shutdown")
(def-unix-error  ETOOMANYREFS    109    _N"Too many references: cannot splice")
(def-unix-error  ETIMEDOUT       110    _N"Connection timed out")
(def-unix-error  ECONNREFUSED    111    _N"Connection refused")
(def-unix-error  EHOSTDOWN       112    _N"Host is down")
(def-unix-error  EHOSTUNREACH    113    _N"No route to host")
(def-unix-error  EALREADY        114    _N"Operation already in progress")
(def-unix-error  EINPROGRESS     115    _N"Operation now in progress")
(def-unix-error  ESTALE          116    _N"Stale NFS file handle")
(def-unix-error  EUCLEAN         117    _N"Structure needs cleaning")
(def-unix-error  ENOTNAM         118    _N"Not a XENIX named type file")
(def-unix-error  ENAVAIL         119    _N"No XENIX semaphores available")
(def-unix-error  EISNAM          120    _N"Is a named type file")
(def-unix-error  EREMOTEIO       121    _N"Remote I/O error")
(def-unix-error  EDQUOT          122    _N"Quota exceeded")
)

;;;
;;; And now for something completely different ...
(emit-unix-errors)

(def-alien-routine ("os_get_errno" unix-get-errno) int)
(def-alien-routine ("os_set_errno" unix-set-errno) int (newvalue int))
(defun unix-errno () (unix-get-errno))

