;;; em-dirs.el --- directory navigation commands  -*- lexical-binding:t -*-

;; Copyright (C) 1999-2025 Free Software Foundation, Inc.

;; Author: John Wiegley <johnw@gnu.org>

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The only special feature that Eshell offers in the last-dir-ring.
;; To view the ring, enter:
;;
;;   cd =
;;
;; Changing to an index within the ring is done using:
;;
;;   cd -      ; same as cd -0
;;   cd -4
;;
;; Or, it is possible to change the first member in the ring which
;; matches a regexp:
;;
;;   cd =bcc   ; change to the last directory visited containing "bcc"
;;
;; This ring is maintained automatically, and is persisted across
;; Eshell sessions.  It is a separate mechanism from `pushd' and
;; `popd', and the two may be used at the same time.

;;; Code:

(require 'esh-mode)                     ;For eshell-directory-name
(require 'esh-var)                      ;For eshell-variable-aliases-list
(require 'ring)
(require 'esh-opt)

;;;###esh-module-autoload
(progn
(defgroup eshell-dirs nil
  "Directory navigation involves changing directories, examining the
current directory, maintaining a directory stack, and also keeping
track of a history of the last directory locations the user was in.
Emacs does provide standard Lisp definitions of `pwd' and `cd', but
they lack somewhat in feel from the typical shell equivalents."
  :tag "Directory navigation"
  :group 'eshell-module))

;;; User Variables:

(defcustom eshell-dirs-load-hook nil
  "A hook that gets run when `eshell-dirs' is loaded."
  :version "24.1"			; removed eshell-dirs-initialize
  :type 'hook)

(defcustom eshell-pwd-convert-function #'expand-file-name
  "The function used to normalize the value of Eshell's `pwd'.
The value returned by `pwd' is also used when recording the
last-visited directory in the last-dir-ring, so it will affect the
form of the list used by `cd ='."
  :type '(radio (function-item file-truename)
		(function-item expand-file-name)
		(function-item identity)
		(function :tag "Other"))
  :version "31.1")

(defcustom eshell-ask-to-save-last-dir 'always
  "Determine if the last-dir-ring should be automatically saved.
The last-dir-ring is always preserved when exiting an Eshell buffer.
However, when Emacs is being shut down, this variable determines
whether to prompt the user, or just save the ring.
If set to nil, it means never ask whether to save the last-dir-ring.
If set to t, always ask if any Eshell buffers are open at exit time.
If set to `always', the list-dir-ring will always be saved, silently."
  :type '(choice (const :tag "Never" nil)
		 (const :tag "Ask" t)
		 (const :tag "Always save" always)))

(defcustom eshell-cd-shows-directory nil
  "If non-nil, using `cd' will report the directory it changes to."
  :type 'boolean)

(defcustom eshell-cd-on-directory t
  "If non-nil, do a cd if a directory is in command position."
  :type 'boolean)

(defcustom eshell-directory-change-hook nil
  "A hook to run when the current directory changes."
  :type 'hook)

(defcustom eshell-list-files-after-cd nil
  "If non-nil, call \"ls\" with any remaining args after doing a cd.
This is provided for convenience, since the same effect is easily
achieved by adding a function to `eshell-directory-change-hook' that
calls \"ls\" and references `eshell-last-arguments'."
  :type 'boolean)

(defcustom eshell-pushd-tohome nil
  "If non-nil, make pushd with no arg behave as `pushd ~' (like `cd').
This mirrors the optional behavior of tcsh."
  :type 'boolean)

(defcustom eshell-pushd-dextract nil
  "If non-nil, make \"pushd +n\" pop the nth dir to the stack top.
This mirrors the optional behavior of tcsh."
  :type 'boolean)

(defcustom eshell-pushd-dunique nil
  "If non-nil, make pushd only add unique directories to the stack.
This mirrors the optional behavior of tcsh."
  :type 'boolean)

(defcustom eshell-dirtrack-verbose t
  "If non-nil, show the directory stack following directory change.
This is effective only if directory tracking is enabled."
  :type 'boolean)

(defcustom eshell-last-dir-ring-file-name
  (expand-file-name "lastdir" eshell-directory-name)
  "If non-nil, name of the file to read/write the last-dir-ring.
See also `eshell-read-last-dir-ring' and `eshell-write-last-dir-ring'.
If it is nil, the last-dir-ring will not be written to disk."
  :type 'file)

(defcustom eshell-last-dir-ring-size 32
  "If non-nil, the size of the directory history ring.
This ring is added to every time `cd' or `pushd' is used.  It simply
stores the most recent directory locations Eshell has been in.  To
return to the most recent entry, use `cd -' (equivalent to `cd -0').
To return to an older entry, use `cd -N', where N is an integer less
than `eshell-last-dir-ring-size'.  To return to the last directory
matching a particular regexp, use `cd =REGEXP'.  To display the
directory history list, use `cd ='.

This mechanism is very similar to that provided by `pushd', except
it's far more automatic.  `pushd' allows the user to decide which
directories gets pushed, and its size is unlimited.

`eshell-last-dir-ring' is meant for users who don't use `pushd'
explicitly very much, but every once in a while would like to return to
a previously visited directory without having to type in the whole
thing again."
  :type 'integer)

(defcustom eshell-last-dir-unique t
  "If non-nil, `eshell-last-dir-ring' contains only unique entries."
  :type 'boolean)

;;; Internal Variables:

(defvar eshell-dirstack nil
  "List of directories saved by pushd in the Eshell buffer.
Thus, this does not include the current directory.")

(defvar eshell-last-dir-ring nil
  "The last directory that Eshell was in.")

;;; Functions:

(defun eshell-dirs-initialize ()    ;Called from `eshell-mode' via intern-soft!
  "Initialize the builtin functions for Eshell."
  (setq-local eshell-variable-aliases-list
	(append
	 eshell-variable-aliases-list
         `(("-" ,(lambda (indices quoted)
                   (if (not indices)
                       (unless (ring-empty-p eshell-last-dir-ring)
                         (expand-file-name
                          (ring-ref eshell-last-dir-ring 0)))
                     ;; Apply the first index, expand the file name,
                     ;; and then apply the rest of the indices.
                     (eshell-apply-indices
                      (expand-file-name
                       (eshell-apply-indices eshell-last-dir-ring
                                             (list (car indices)) quoted))
                      (cdr indices) quoted))))
           ("+" "PWD")
           ("PWD" ,(lambda () (expand-file-name (eshell/pwd)))
            t t)
           ("OLDPWD" ,(lambda ()
                       (unless (ring-empty-p eshell-last-dir-ring)
                         (expand-file-name
                          (ring-ref eshell-last-dir-ring 0))))
            t t))))

  (when eshell-cd-on-directory
    (setq-local eshell-interpreter-alist
                (cons (cons (lambda (file _args)
                              (eshell-lone-directory-p file))
                            'eshell-dirs-substitute-cd)
                      eshell-interpreter-alist)))

  (add-hook 'eshell-parse-argument-hook
	    #'eshell-parse-user-reference nil t)
  (if (eshell-under-windows-p)
      (add-hook 'eshell-parse-argument-hook
		#'eshell-parse-drive-letter nil t))

  (when (eshell-using-module 'eshell-cmpl)
    (add-hook 'pcomplete-try-first-hook
	      #'eshell-complete-user-reference nil t))

  (make-local-variable 'eshell-dirstack)
  (make-local-variable 'eshell-last-dir-ring)

  (if eshell-last-dir-ring-file-name
      (eshell-read-last-dir-ring))
  (unless eshell-last-dir-ring
    (setq eshell-last-dir-ring (make-ring eshell-last-dir-ring-size)))

  (add-hook 'eshell-exit-hook #'eshell-write-last-dir-ring nil t)

  (add-hook 'kill-emacs-query-functions #'eshell-save-some-last-dir))

(defun eshell-save-some-last-dir ()
  "Save the list-dir-ring for any open Eshell buffers."
  (dolist (buf (buffer-list))
    (if (buffer-live-p buf)
	(with-current-buffer buf
	  (if (and eshell-mode
		   eshell-ask-to-save-last-dir
		   (or (eq eshell-ask-to-save-last-dir 'always)
		       (y-or-n-p
			(format-message
			 "Save last dir ring for Eshell buffer `%s'? "
			 (buffer-name buf)))))
	      (eshell-write-last-dir-ring)))))
  t)

(defun eshell-lone-directory-p (file)
  "Test whether FILE is just a directory name, and not a command name."
  (and (file-directory-p file)
       (or (file-name-directory file)
	   (not (eshell-search-path file)))))

(defun eshell-dirs-substitute-cd (&rest args)
  "Substitute the given command for a call to `cd' on that name."
  (if (> (length args) 1)
      (error "%s: command not found" (car args))
    (throw 'eshell-replace-command
	   (eshell-parse-command "cd" (flatten-tree args)))))

(defun eshell-expand-user-reference (file)
  "Expand a user reference in FILE to its real directory name."
  (replace-regexp-in-string
   (rx bos (group "~" (*? anychar)) (or "/" eos))
   #'expand-file-name file))

(defun eshell-parse-user-reference ()
  "An argument beginning with ~ is a filename to be expanded."
  (when (and (not eshell-current-argument)
             (not eshell-current-quoted)
             (eq (char-after) ?~))
    ;; Apply this modifier fairly early so it happens before things
    ;; like glob expansion.
    (add-hook 'eshell-current-modifiers #'eshell-expand-user-reference -50)
    (forward-char)
    (char-to-string (char-before))))

(defun eshell-parse-drive-letter ()
  "An argument beginning with X:[^/] is a drive letter reference."
  (when (and (not eshell-current-argument)
	     (looking-at "\\([A-Za-z]:\\)\\([^/\\]\\|\\'\\)"))
    (goto-char (match-end 1))
    (let* ((letter (match-string 1))
	   (regexp (concat "\\`" letter))
	   (path (eshell-find-previous-directory regexp)))
      (concat (or path letter) "/"))))

(defvar pcomplete-stub)
(defvar pcomplete-last-completion-raw)
(declare-function pcomplete-actual-arg "pcomplete")
(declare-function pcomplete-uniquify-list "pcomplete")

(defun eshell-complete-user-reference ()
  "If there is a user reference, complete it."
  (let ((arg (pcomplete-actual-arg)))
    (when (string-match "\\`~[a-z]*\\'" arg)
      (setq pcomplete-stub (substring arg 1)
            pcomplete-last-completion-raw t)
      (eshell-read-user-names)
      (let ((names (pcomplete-uniquify-list
                    (mapcar (lambda (user)
                              (file-name-as-directory (cdr user)))
                            eshell-user-names))))
        (throw 'pcomplete-completions
               ;; Provide a programmed completion table.  This works
               ;; just like completing over the list of names, except
               ;; it always returns the completed string for
               ;; `try-completion', never `t'.  That's because this is
               ;; only completing a directory name, and so the
               ;; completion isn't actually finished yet.
               (lambda (string pred action)
                 (pcase action
                   ('nil                  ; try-completion
                    (let ((result (try-completion string names pred)))
                      (if (eq result t) string result)))
                   ('t                    ; all-completions
                    (all-completions string names pred))
                   ('lambda               ; test-completion
                    (test-completion string names pred))
                   ('metadata
                    '(metadata (category . file)))
                   (`(boundaries . ,suffix)
                    `(boundaries 0 . ,(string-search "/" suffix))))))))))

(defun eshell/pwd ()
  "Change output from `pwd' to be cleaner."
  (let ((dir default-directory))
    (when (and (eq (aref dir (1- (length dir))) ?/)
               (not (and (eshell-under-windows-p)
                         (string-match "\\`[A-Za-z]:[\\/]\\'" dir)))
               (length> (file-local-name dir) 1))
      (setq dir (substring dir 0 -1)))
    (funcall (or eshell-pwd-convert-function #'identity) dir)))

(defun eshell-expand-multiple-dots (filename)
  ;; FIXME: This advice recommendation is rather odd: it's somewhat
  ;; dangerous and it claims not to work with minibuffer-completion, which
  ;; makes it much less interesting.
  "Convert `...' to `../..', `....' to `../../..', etc..

With the following piece of advice, you can make this functionality
available in most of Emacs, with the exception of filename completion
in the minibuffer:

    (advice-add \\='expand-file-name :around #\\='my-expand-multiple-dots)
    (defun my-expand-multiple-dots (orig-fun filename &rest args)
      (apply orig-fun (eshell-expand-multiple-dots filename) args))"
  (while (string-match "\\(?:\\`\\|/\\)\\.\\.\\(\\.+\\)\\(?:\\'\\|/\\)"
                       filename)
    (let* ((extra-dots (match-string 1 filename))
	   (len (length extra-dots))
	   replace-text)
      (while (> len 0)
	(setq replace-text (concat replace-text "/..")
	      len (1- len)))
      (setq filename
	    (replace-match replace-text t t filename 1))))
  filename)

(defun eshell-find-previous-directory (regexp)
  "Find the most recent last-dir matching REGEXP."
  (let ((index 0)
	(len (ring-length eshell-last-dir-ring))
	oldpath)
    (if (> (length regexp) 0)
	(while (< index len)
	  (setq oldpath (ring-ref eshell-last-dir-ring index))
	  (if (string-match regexp oldpath)
	      (setq index len)
	    (setq oldpath nil
		  index (1+ index)))))
    oldpath))

(defun eshell/cd (&rest args)           ; all but first ignored
  "Alias to extend the behavior of `cd'."
  (setq args (flatten-tree args))
  (let ((path (car args))
	(subpath (car (cdr args)))
	(case-fold-search (eshell-under-windows-p))
	handled)
    (if (numberp path)
	(setq path (number-to-string path)))
    (if (numberp subpath)
	(setq subpath (number-to-string subpath)))
    (cond
     (subpath
      (let ((curdir (eshell/pwd)))
	(if (string-match path curdir)
	    (setq path (replace-match subpath nil nil curdir))
	  (error "Path substring `%s' not found" path))))
     ((and path (string-match "^-\\([0-9]*\\)$" path))
      (let ((index (match-string 1 path)))
	(setq path
	      (ring-remove eshell-last-dir-ring
			   (if index
			       (string-to-number index)
			     0)))))
     ((and path (string-match "^=\\(.*\\)$" path))
      (let ((oldpath (eshell-find-previous-directory
		      (match-string 1 path))))
	(if oldpath
	    (setq path oldpath)
	  (let ((len (ring-length eshell-last-dir-ring))
		(index 0))
	    (if (= len 0)
		(error "Directory ring empty"))
            (eshell-with-buffered-print
              (while (< index len)
                (eshell-buffered-print
                 (concat (number-to-string index) ": "
                         (ring-ref eshell-last-dir-ring index) "\n"))
                (setq index (1+ index))))
	    (setq handled t)))))
     (path
      (setq path (eshell-expand-multiple-dots path))))
    (unless handled
      (let ((curdir (eshell/pwd))
	    (newdir (or path "~")))
	(unless (equal curdir newdir)
	  (eshell-add-to-dir-ring curdir))
	(let ((result (cd newdir)))
          ;; If we're in "/" and cd to ".." or the like, make things
          ;; less confusing by changing "/.." to "/".
          (when (equal (file-truename result) "/")
            (setq result (cd "/")))
	  (and eshell-cd-shows-directory
	       (eshell-printn result)))
	(run-hooks 'eshell-directory-change-hook)
        (when eshell-list-files-after-cd
          ;; Call "ls", but don't update the last-command information.
          (let ((eshell-last-command-name)
                (eshell-last-command-status)
                (eshell-last-arguments))
            (eshell-plain-command "ls" (cdr args))))
	nil))))

(put 'eshell/cd 'eshell-no-numeric-conversions t)
(put 'eshell/cd 'eshell-filename-arguments t)

(defun eshell-add-to-dir-ring (path)
  "Add PATH to the last-dir-ring, if applicable."
  (unless (and (not (ring-empty-p eshell-last-dir-ring))
	       (equal path (ring-ref eshell-last-dir-ring 0)))
    (if eshell-last-dir-unique
	(let ((index 0)
	      (len (ring-length eshell-last-dir-ring)))
	  (while (< index len)
	    (if (equal (ring-ref eshell-last-dir-ring index) path)
		(ring-remove eshell-last-dir-ring index)
	      (setq index (1+ index))))))
    (ring-insert eshell-last-dir-ring path)))

;;; pushd [+n | dir]
(defun eshell/pushd (&rest args)        ; all but first ignored
  "Implementation of pushd in Lisp."
  (let ((path (car args)))
    (cond
     ((null path)
      ;; no arg -- swap pwd and car of stack unless eshell-pushd-tohome
      (cond (eshell-pushd-tohome
	     (eshell/pushd "~"))
	    (eshell-dirstack
	     (let ((old (eshell/pwd)))
	       (eshell/cd (car eshell-dirstack))
	       (setq eshell-dirstack (cons old (cdr eshell-dirstack)))
	       (eshell/dirs t)))
	    (t
	     (error "pushd: No other directory"))))
     ((string-match "^\\+\\([0-9]\\)" path)
      ;; pushd +n
      (setq path (string-to-number (match-string 1 path)))
      (cond ((> path (length eshell-dirstack))
	     (error "Directory stack not that deep"))
	    ((= path 0)
	     (error "Couldn't cd"))
	    (eshell-pushd-dextract
	     (let ((dir (nth (1- path) eshell-dirstack)))
	       (eshell/popd path)
	       (eshell/pushd (eshell/pwd))
	       (eshell/cd dir)
	       (eshell/dirs t)))
	    (t
	     (let* ((ds (cons (eshell/pwd) eshell-dirstack))
		    (dslen (length ds))
		    (front (nthcdr path ds))
		    (back (nreverse (nthcdr (- dslen path) (reverse ds))))
		    (new-ds (append front back)))
	       (eshell/cd (car new-ds))
	       (setq eshell-dirstack (cdr new-ds))
	       (eshell/dirs t)))))
     (t
      ;; pushd <dir>
      (let ((old-wd (eshell/pwd)))
	(eshell/cd path)
	(if (or (null eshell-pushd-dunique)
		(not (member old-wd eshell-dirstack)))
	    (setq eshell-dirstack (cons old-wd eshell-dirstack)))
	(eshell/dirs t)))))
  nil)

(put 'eshell/pushd 'eshell-no-numeric-conversions t)
(put 'eshell/pushd 'eshell-filename-arguments t)

;;; popd [+n]
(defun eshell/popd (&rest args)
  "Implementation of popd in Lisp."
  (let ((ref (or (car args) "+0")))
    (unless (and (stringp ref)
		 (string-match "\\`\\([+-][0-9]+\\)\\'" ref))
      (error "popd: bad arg `%s'" ref))
    (setq ref (string-to-number (match-string 1 ref)))
    (cond ((= ref 0)
	   (unless eshell-dirstack
	     (error "popd: Directory stack empty"))
	   (eshell/cd (car eshell-dirstack))
	   (setq eshell-dirstack (cdr eshell-dirstack))
	   (eshell/dirs t))
	  ((<= (abs ref) (length eshell-dirstack))
	   (let* ((ds (cons nil eshell-dirstack))
		  (cell (nthcdr (if (> ref 0)
				    (1- ref)
				  (+ (length eshell-dirstack) ref)) ds))
		  (dir (cadr cell)))
	     (eshell/cd dir)
	     (setcdr cell (cdr (cdr cell)))
	     (setq eshell-dirstack (cdr ds))
	     (eshell/dirs t)))
	  (t
	   (error "Couldn't popd"))))
  nil)

(put 'eshell/popd 'eshell-no-numeric-conversions t)
(put 'eshell/pop 'eshell-filename-arguments t)

(defun eshell/dirs (&optional if-verbose)
  "Implementation of dirs in Lisp."
  (when (or (not if-verbose) eshell-dirtrack-verbose)
    (let* ((msg "")
	   (ds (cons (eshell/pwd) eshell-dirstack))
	   (home (expand-file-name "~/"))
	   (homelen (length home)))
      (while ds
	(let ((dir (car ds)))
	  (and (>= (length dir) homelen)
	       (string= home (substring dir 0 homelen))
	       (setq dir (concat "~/" (substring dir homelen))))
	  (setq msg (concat msg (directory-file-name dir) " "))
	  (setq ds (cdr ds))))
      msg)))

(defun eshell-read-last-dir-ring ()
  "Set the buffer's `eshell-last-dir-ring' from a history file."
  (let ((file eshell-last-dir-ring-file-name))
    (cond
     ((or (null file)
	  (equal file "")
	  (not (file-readable-p file)))
      nil)
     (t
      (let* ((count 0)
	     (size eshell-last-dir-ring-size)
	     (ring (make-ring size)))
	(with-temp-buffer
	  (insert-file-contents file)
	  ;; Save restriction in case file is already visited...
	  ;; Watch for those date stamps in history files!
	  (goto-char (point-max))
	  (while (and (< count size)
		      (re-search-backward "^\\([^\n].*\\)$" nil t))
	    (ring-insert-at-beginning ring (match-string 1))
	    (setq count (1+ count)))
	  ;; never allow the top element to equal the current
	  ;; directory
	  (while (and (not (ring-empty-p ring))
		      (equal (ring-ref ring 0) (eshell/pwd)))
	    (ring-remove ring 0)))
	(setq eshell-last-dir-ring ring))))))

(defun eshell-write-last-dir-ring ()
  "Write the buffer's `eshell-last-dir-ring' to a history file."
  (let* ((file eshell-last-dir-ring-file-name)
	 (resolved-file (if (stringp file) (file-truename file))))
    (cond
     ((or (null file)
	  (equal file "")
	  (null eshell-last-dir-ring)
	  (ring-empty-p eshell-last-dir-ring))
      nil)
     ((not (file-writable-p resolved-file))
      (message "Cannot write last-dir-ring file %s" resolved-file))
     (t
      (let* ((ring eshell-last-dir-ring)
	     (index (ring-length ring)))
	(with-temp-buffer
	  (while (> index 0)
	    (setq index (1- index))
	    (insert (ring-ref ring index) ?\n))
	  (insert (eshell/pwd) ?\n)
	  (eshell-with-private-file-modes
	   (write-region (point-min) (point-max) resolved-file nil
			 'no-message))))))))

(provide 'em-dirs)
;;; em-dirs.el ends here
