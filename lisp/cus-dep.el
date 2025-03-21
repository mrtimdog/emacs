;;; cus-dep.el --- find customization dependencies  -*- lexical-binding: t; -*-
;;
;; Copyright (C) 1997, 2001-2025 Free Software Foundation, Inc.
;;
;; Author: Per Abrahamsen <abraham@dina.kvl.dk>
;; Keywords: internal
;; Package: emacs

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

;;; Code:

(require 'widget)
(require 'cus-face)
(require 'cl-lib)

(defvar generated-custom-dependencies-file "cus-load.el"
  "Output file for `custom-make-dependencies'.")

;; See finder-no-scan-regexp in finder.el.
(defvar custom-dependencies-no-scan-regexp "\\(^\\.#\\|\\(loaddefs\\|\
ldefs-boot\\|cus-load\\|finder-inf\\|esh-groups\\|subdirs\\)\\.el$\\)"
  "Regexp matching file names not to scan for `custom-make-dependencies'.")

(require 'loaddefs-gen)

;; Hack workaround for bug#14384.
;; Define defcustom-mh as an alias for defcustom, etc.
;; Only do this in batch mode to avoid messing up a normal Emacs session.
;; Alternative would be to load mh-e when making cus-load.
;; (Would be better to split just the necessary parts of mh-e into a
;; separate file and only load that.)
(when (and noninteractive)
  (mapc (lambda (e) (let ((sym (intern (format "%s-mh" e))))
		      (or (fboundp sym)
			  (defalias sym e))))
	'(defcustom defface defgroup)))

(defun custom--get-def (expr)
  (if (not (memq (car-safe expr)
                 '( define-minor-mode define-globalized-minor-mode)))
      expr
    ;; For define-minor-mode, we don't want to evaluate the whole
    ;; expression, because it tends to define functions which aren't
    ;; usable (because they call other functions that were skipped).
    ;; Concretely it gave us an error
    ;; "void-function bug-reference--run-auto-setup"
    ;; when subsequently loading `cus-load.el'.
    (let ((es (list (macroexpand-all expr)))
          defs)
      (while es
        (let ((e (pop es)))
          (pcase e
            (`(progn . ,exps) (setq es (append exps es)))
            (`(custom-declare-variable . ,_) (push e defs)))))
      (macroexp-progn (nreverse defs)))))

(defun custom-make-dependencies ()
  "Batch function to extract custom dependencies from .el files.
Usage: emacs -batch -l ./cus-dep.el -f custom-make-dependencies DIRS"
  (let* ((enable-local-eval nil)
	 (enable-local-variables :safe)
         (preloaded (concat "\\`\\(\\./+\\)?"
                            (regexp-opt preloaded-file-list t)
                            "\\.el\\'"))
         (file-count 0)
         (files
          ;; Use up command-line-args-left else Emacs can try to open
          ;; the args as directories after we are done.
          (cl-loop for subdir = (pop command-line-args-left)
                   while subdir
                   append (mapcar (lambda (f)
                                    (cons subdir f))
                                  (directory-files subdir nil
                                                   "\\`[^=.].*\\.el\\'"))))
	 (progress (make-progress-reporter
                    (byte-compile-info "Scanning files for custom")
                    0 (length files) nil 10)))
    (with-temp-buffer
      (dolist (elem files)
        (let* ((subdir (car elem))
               (file (cdr elem))
               (default-directory
                 (directory-file-name (expand-file-name subdir))))
          (progress-reporter-update progress (setq file-count (1+ file-count)))
          (unless (or (string-match custom-dependencies-no-scan-regexp file)
                      (string-match preloaded (format "%s/%s" subdir file))
                      (not (file-exists-p file)))
            (erase-buffer)
            (kill-all-local-variables)
            (insert-file-contents file)
            (hack-local-variables)
            (goto-char (point-min))
            (string-match "\\`\\(.*\\)\\.el\\'" file)
            (let ((name (or generated-autoload-load-name ; see bug#5277
                            (file-name-nondirectory (match-string 1 file))))
                  (load-true-file-name file)
                  (load-file-name file))
              (if (save-excursion
                    (re-search-forward
		     (concat "(\\(cc-\\)?provide[ \t\n]+\\('\\|(quote[ \t\n]\\)[ \t\n]*"
			     (regexp-quote name) "[ \t\n)]")
		     nil t))
                  (setq name (intern name)))
              (condition-case nil
                  (while (re-search-forward
                          "^(def\\(custom\\|face\\|group\\|ine\\(?:-globalized\\)?-minor-mode\\)" nil t)
                    (beginning-of-line)
                    (let ((type (match-string 1))
			  (expr (custom--get-def (read (current-buffer)))))
                      (condition-case nil
                          (let ((custom-dont-initialize t)
                                (sym (nth 1 expr)))
                            (put (if (eq (car-safe sym) 'quote)
                                     (cadr sym)
                                   sym)
                                 'custom-where name)
                            ;; Eval to get the 'custom-group, -tag,
                            ;; -version, group-documentation etc properties.
                            (eval expr t))
                        ;; Eval failed for some reason.  Eg maybe the
                        ;; defcustom uses something defined earlier
                        ;; in the file (we haven't loaded the file).
                        ;; In most cases, we can still get the :group.
                        (error
                         (ignore-errors
                           (let ((group (cadr (memq :group expr))))
                             (and group
                                  (eq (car group) 'quote)
                                  (custom-add-to-group
                                   (cadr group)
                                   (nth 1 expr)
                                   (intern (format "custom-%s"
                                                   (if (equal type "custom")
                                                       "variable"
                                                     type)))))))))))
                (error nil)))))))
    (progress-reporter-done progress))
  (byte-compile-info
   (format "Generating %s..." generated-custom-dependencies-file) t)
  (set-buffer (find-file-noselect generated-custom-dependencies-file))
  (setq buffer-undo-list t)
  (erase-buffer)
  (generate-lisp-file-heading
   generated-custom-dependencies-file 'custom-make-dependencies
   :title "custom dependencies")
  (let (alist)
    (mapatoms (lambda (symbol)
		(let ((members (get symbol 'custom-group))
		      where found)
		  (when members
		    (dolist (member (mapcar #'car members))
		      (setq where (get member 'custom-where))
		      (unless (or (null where)
				  (member where found))
			(push where found)))
		    (when found
		      (push (cons (symbol-name symbol)
				  (with-output-to-string
				    (prin1 (sort found #'string<))))
			    alist))))))
    (dolist (e (sort alist (lambda (e1 e2) (string< (car e1) (car e2)))))
      (insert "(custom--add-custom-loads '" (car e) " '" (cdr e) ")\n")))
  (insert "\

;; The remainder of this file is for handling :version.
;; We provide a minimum of information so that `customize-changed'
;; can do its job.

;; For groups we set `custom-version', `group-documentation' and
;; `custom-tag' (which are shown in the customize buffer), so we
;; don't have to load the file containing the group.

;; This macro is used so we don't modify the information about
;; variables and groups if it's already set. (We don't know when
;; " (file-name-nondirectory generated-custom-dependencies-file)
      " is going to be loaded and at that time some of the
;; files might be loaded and some others might not).
\(defmacro custom-put-if-not (symbol propname value)
  `(unless (get ,symbol ,propname)
     (put ,symbol ,propname ,value)))

")
  (let ((version-alist nil)
	groups)
    (mapatoms (lambda (symbol)
		(let ((version (get symbol 'custom-version))
		      where)
		  (when version
		    (setq where (get symbol 'custom-where))
		    (when where
		      (if (or (custom-variable-p symbol)
                              (facep symbol))
			  ;; This means it's a variable or a face.
			  (progn
			    (if (assoc version version-alist)
				(unless
				    (member where
					    (cdr (assoc version version-alist)))
				  (push where (cdr (assoc version version-alist))))
			      (push (list version where) version-alist)))
			;; This is a group
			(push (list (symbol-name symbol)
				    (with-output-to-string (prin1 version))
				    (with-output-to-string
				      (prin1 (get symbol 'group-documentation)))
				    (if (get symbol 'custom-tag)
					(with-output-to-string
					  (prin1 (get symbol 'custom-tag)))))
			      groups)))))))
    (dolist (e (sort groups (lambda (e1 e2) (string< (car e1) (car e2)))))
      (insert "(custom-put-if-not '" (car e) " 'custom-version '"
	      (nth 1 e) ")\n")
      (insert "(custom-put-if-not '" (car e) " 'group-documentation "
	      (nth 2 e) ")\n")
      (if (nth 3 e)
	  (insert "(custom-put-if-not '" (car e) " 'custom-tag "
		  (nth 3 e) ")\n")))

    (insert "\n(defvar custom-versions-load-alist "
	    (if version-alist "'" ""))
    (prin1 (sort version-alist (lambda (e1 e2) (version< (car e1) (car e2))))
	   (current-buffer))
    (insert "\n  \"For internal use by custom.
This is an alist whose members have as car a version string, and as
elements the files that have variables or faces that contain that
version.  These files should be loaded before showing the customization
buffer that `customize-changed' generates.\")\n\n"))
  (generate-lisp-file-trailer generated-custom-dependencies-file)
  (save-buffer)
  (byte-compile-info
   (format "Generating %s...done" generated-custom-dependencies-file) t))


(provide 'cus-dep)

;;; cus-dep.el ends here
