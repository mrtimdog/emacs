;;; etags.el --- etags facility for Emacs  -*- lexical-binding: t -*-

;; Copyright (C) 1985-2025 Free Software Foundation, Inc.

;; Author: Roland McGrath <roland@gnu.org>
;; Maintainer: emacs-devel@gnu.org
;; Keywords: tools

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

;; The namespacing of this package is a mess:
;; - The file name is "etags", but the "exported" functionality doesn't use
;;   this name
;; - Uses "etags-", "tags-", and "tag-" prefixes.
;; - Many functions use "-tag-" or "-tags-", or even "-etags-" not as
;;   prefixes but somewhere within the name.

(require 'ring)
(require 'xref)
(require 'fileloop)

;;;###autoload
(defvar tags-file-name nil
  "File name of tags table.
To switch to a new tags table, do not set this variable; instead,
invoke `visit-tags-table', which is the only reliable way of
setting the value of this variable, whether buffer-local or global.
Use the `etags' program to make a tags table file.")
;; Make M-x set-variable tags-file-name like M-x visit-tags-table.
;;;###autoload (put 'tags-file-name 'variable-interactive "fVisit tags table: ")
;;;###autoload (put 'tags-file-name 'safe-local-variable 'stringp)

(defgroup etags nil "Tags tables."
  :group 'tools)

;;;###autoload
(defcustom tags-case-fold-search 'default
  "Whether tags operations should be case-sensitive.
A value of t means case-insensitive, a value of nil means case-sensitive.
Any other value means use the setting of `case-fold-search'."
  :type '(choice (const :tag "Case-sensitive" nil)
		 (const :tag "Case-insensitive" t)
		 (other :tag "Use default" default))
  :version "21.1"
  :safe 'symbolp)

;;;###autoload
;; Use `visit-tags-table-buffer' to cycle through tags tables in this list.
(defcustom tags-table-list nil
  "List of file names of tags tables to search.
An element that is a directory means the file \"TAGS\" in that directory.
To switch to a new list of tags tables, setting this variable is sufficient.
If you set this variable, do not also set `tags-file-name'.
Use the `etags' program to make a tags table file."
  :type '(repeat file))

;;;###autoload
(defcustom tags-compression-info-list
  '("" ".Z" ".bz2" ".gz" ".xz" ".tgz")
  "List of extensions tried by etags when `auto-compression-mode' is on.
An empty string means search the non-compressed file."
  :version "24.1"			; added xz
  :type  '(repeat string))

;; !!! tags-compression-info-list should probably be replaced by access
;; to directory list and matching jka-compr-compression-info-list. Currently,
;; this implementation forces each modification of
;; jka-compr-compression-info-list to be reflected in this var.
;; An alternative could be to say that introducing a special
;; element in this list (e.g. t) means : try at this point
;; using directory listing and regexp matching using
;; jka-compr-compression-info-list.


;;;###autoload
(defcustom tags-add-tables 'ask-user
  "Control whether to add a new tags table to the current list.
t means do; nil means don't (always start a new list).
Any other value means ask the user whether to add a new tags table
to the current list (as opposed to starting a new list)."
  :type '(choice (const :tag "Do" t)
		 (const :tag "Don't" nil)
		 (other :tag "Ask" ask-user)))

(defcustom tags-revert-without-query nil
  "Non-nil means reread a TAGS table without querying, if it has changed."
  :type 'boolean)

(defvar tags-table-computed-list nil
  "List of tags tables to search, computed from `tags-table-list'.
This includes tables implicitly included by other tables.  The list is not
always complete: the included tables of a table are not known until that
table is read into core.  An element that is t is a placeholder
indicating that the preceding element is a table that has not been read
into core and might contain included tables to search.
See `tags-table-check-computed-list'.")

(defvar tags-table-computed-list-for nil
  "Value of `tags-table-list' that `tags-table-computed-list' corresponds to.
If `tags-table-list' changes, `tags-table-computed-list' is thrown away and
recomputed; see `tags-table-check-computed-list'.")

(defvar tags-table-list-pointer nil
  "Pointer into `tags-table-computed-list' for the current state of searching.
Use `visit-tags-table-buffer' to cycle through tags tables in this list.")

(defvar tags-table-list-started-at nil
  "Pointer into `tags-table-computed-list', where the current search started.")

(defvar tags-table-set-list nil
  "List of sets of tags table which have been used together in the past.
Each element is a list of strings which are file names.")

;;;###autoload
(defcustom find-tag-hook nil
  "Hook to be run by \\[find-tag] after finding a tag.  See `run-hooks'.
The value in the buffer in which \\[find-tag] is done is used,
not the value in the buffer \\[find-tag] goes to."
  :type 'hook)

;;;###autoload
(defcustom find-tag-default-function nil
  "A function of no arguments used by \\[find-tag] to pick a default tag.
If nil, and the symbol that is the value of `major-mode'
has a `find-tag-default-function' property (see `put'), that is used.
Otherwise, `find-tag-default' is used."
  :type '(choice (const nil) function))

(define-obsolete-variable-alias 'find-tag-marker-ring-length
  'tags-location-ring-length "25.1")

(defvar tags-location-ring-length 16
  "Size of the find-tag marker ring.
This variable has no effect, and is kept only for backward compatibility.
The actual size of the find-tag marker ring is unlimited.")

(defcustom tags-tag-face 'default
  "Face for tags in the output of `tags-apropos'."
  :type 'face
  :version "21.1")

(defcustom tags-apropos-verbose nil
  "If non-nil, print the name of the tags file in the *Tags List* buffer."
  :type 'boolean
  :version "21.1")

(defcustom tags-apropos-additional-actions nil
  "Specify additional actions for `tags-apropos' and `xref-find-apropos'.

If non-nil, value should be a list of triples (TITLE FUNCTION
TO-SEARCH).  For each triple, `tags-apropos' and `xref-find-apropos'
process TO-SEARCH and list tags from it.  TO-SEARCH should be an alist,
obarray, or symbol.
If it is a symbol, the symbol's value is used.
TITLE, a string, is a title used to label the additional list of tags.
FUNCTION is a function to call when a symbol is selected in the
*Tags List* buffer.  It will be called with one argument SYMBOL which
is the symbol being selected.

Example value:

   ((\"Emacs Lisp\" Info-goto-emacs-command-node obarray)
    (\"Common Lisp\" common-lisp-hyperspec common-lisp-hyperspec-obarray)
    (\"SCWM\" scwm-documentation scwm-obarray))"
  :type '(repeat (list (string :tag "Title")
		       function
		       (sexp :tag "Tags to search")))
  :version "21.1")

(defvar find-tag-marker-ring (make-ring 16)
  "Find-tag marker ring.
Obsolete variable kept for compatibility.  It is not used in any way.")
(make-obsolete-variable
 'find-tag-marker-ring
 "use `xref-push-marker-stack' or `xref-go-back' instead."
 "25.1")

(defvar default-tags-table-function nil
  "If non-nil, a function to choose a default tags file for a buffer.
This function receives no arguments and should return the default
tags table file to use for the current buffer.")

(defvar tags-location-ring (make-ring tags-location-ring-length)
  "Ring of markers which are locations visited by \\[find-tag].
Pop back to the last location with \\[negative-argument] \\[find-tag].")

;; Tags table state.
;; These variables are local in tags table buffers.

(defvar tags-table-files nil
  "List of file names covered by current tags table.
nil means it has not yet been computed;
use function `tags-table-files' to do so.")

(defvar tags-completion-table nil
  "List of tag names defined in current tags table.")

(defvar tags-included-tables nil
  "List of tags tables included by the current tags table.")

;; Hooks for file formats.

(defvar tags-table-format-functions '(etags-recognize-tags-table
				      tags-recognize-empty-tags-table)
  "Hook to be called in a tags table buffer to identify the type of tags table.
The functions are called in order, with no arguments,
until one returns non-nil.  The function should make buffer-local bindings
of the format-parsing tags function variables if successful.")

(defvar file-of-tag-function nil
  "Function to do the work of `file-of-tag' (which see).
One optional argument, a boolean specifying to return complete path (nil) or
relative path (non-nil).")
(defvar tags-table-files-function nil
  "Function to do the work of function `tags-table-files' (which see).")
(defvar tags-completion-table-function nil
  "Function to build the `tags-completion-table'.")
(defvar snarf-tag-function nil
  "Function to get info about a matched tag for `goto-tag-location-function'.
One optional argument, specifying to use explicit tag (non-nil) or not (nil).
The default is nil.")
(defvar goto-tag-location-function nil
  "Function of to go to the location in the buffer specified by a tag.
One argument, the tag info returned by `snarf-tag-function'.")
(defvar find-tag-regexp-search-function nil
  "Search function passed to `find-tag-in-order' for finding a regexp tag.")
(defvar find-tag-regexp-tag-order nil
  "Tag order passed to `find-tag-in-order' for finding a regexp tag.")
(defvar find-tag-regexp-next-line-after-failure-p nil
  "Flag passed to `find-tag-in-order' for finding a regexp tag.")
(defvar find-tag-search-function nil
  "Search function passed to `find-tag-in-order' for finding a tag.")
(defvar find-tag-tag-order nil
  "Tag order passed to `find-tag-in-order' for finding a tag.")
(defvar find-tag-next-line-after-failure-p nil
  "Flag passed to `find-tag-in-order' for finding a tag.")
(defvar list-tags-function nil
  "Function to do the work of `list-tags' (which see).")
(defvar tags-apropos-function nil
  "Function to do the work of `tags-apropos' (which see).")
(defvar tags-included-tables-function nil
  "Function to do the work of function `tags-included-tables' (which see).")
(defvar verify-tags-table-function nil
  "Function to return t if current buffer contains valid tags file.")

(defun initialize-new-tags-table ()
  "Initialize the tags table in the current buffer.
Return non-nil if it is a valid tags table, and
in that case, also make the tags table state variables
buffer-local and set them to nil."
  (setq-local tags-table-files nil)
  (setq-local tags-completion-table nil)
  (setq-local tags-included-tables nil)
  ;; We used to initialize find-tag-marker-ring and tags-location-ring
  ;; here, to new empty rings.  But that is wrong, because those
  ;; are global.

  ;; Value is t if we have found a valid tags table buffer.
  (run-hook-with-args-until-success 'tags-table-format-functions))

;;;###autoload
(define-derived-mode tags-table-mode special-mode "Tags Table"
  "Major mode for tags table file buffers."
  (setq buffer-undo-list t)
  (initialize-new-tags-table))

;;;###autoload
(defun visit-tags-table (file &optional local)
  "Tell tags commands to use tags table file FILE.
FILE should be the name of a file created with the `etags' program.
A directory name is ok too; it means file TAGS in that directory.

Normally \\[visit-tags-table] sets the global value of `tags-file-name'.
With a prefix arg, set the buffer-local value instead.  When called
from Lisp, if the optional arg LOCAL is non-nil, set the local value.
When you find a tag with \\[find-tag], the buffer it finds the tag
in is given a local value of this variable which is the name of the tags
file the tag was in."
  (interactive
   (let ((default-tag-dir
           (or (locate-dominating-file default-directory "TAGS")
               default-directory)))
     (list (read-file-name
            (format-prompt "Visit tags table" "TAGS")
            ;; default to TAGS from default-directory up to root.
            default-tag-dir
            (expand-file-name "TAGS" default-tag-dir)
            t)
           current-prefix-arg)))

  (or (stringp file) (signal 'wrong-type-argument (list 'stringp file)))
  ;; Bind tags-file-name so we can control below whether the local or
  ;; global value gets set.
  ;; Calling visit-tags-table-buffer with tags-file-name set to FILE will
  ;; initialize a buffer for FILE and set tags-file-name to the
  ;; fully-expanded name.
  (let ((tags-file-name file)
        (cbuf (current-buffer)))
    (save-excursion
      (or (visit-tags-table-buffer file)
	  (signal 'file-missing (list "Visiting tags table"
				      "No such file or directory"
				      file)))
      ;; Set FILE to the expanded name.  Do that in the buffer we
      ;; started from, because visit-tags-table-buffer switches
      ;; buffers after updating tags-file-name, so if tags-file-name
      ;; is local in the buffer we started, that value is only visible
      ;; in that buffer.
      (setq file (with-current-buffer cbuf tags-file-name))))
  (if local
      (progn
        ;; Force recomputation of tags-completion-table.
        (setq-local tags-completion-table nil)
        ;; Set the local value of tags-file-name.
        (setq-local tags-file-name file))
    ;; Set the global value of tags-file-name.
    (setq-default tags-file-name file)
    (setq tags-completion-table nil)))

(defun tags-table-check-computed-list ()
  "Compute `tags-table-computed-list' from `tags-table-list' if necessary."
  (let ((expanded-list (mapcar #'tags-expand-table-name tags-table-list)))
    (or (equal tags-table-computed-list-for expanded-list)
	;; The list (or default-directory) has changed since last computed.
	(let* ((compute-for (mapcar #'copy-sequence expanded-list))
	       (tables (copy-sequence compute-for)) ;Mutated in the loop.
	       (computed nil)
	       table-buffer)

	  (while tables
	    (setq computed (cons (car tables) computed)
		  table-buffer (get-file-buffer (car tables)))
	    (if (and table-buffer
		     ;; There is a buffer visiting the file.  Now make sure
		     ;; it is initialized as a tag table buffer.
		     (save-excursion
		       (tags-verify-table (buffer-file-name table-buffer))))
		(with-current-buffer table-buffer
                  ;; Needed so long as etags-tags-included-tables
                  ;; does not save-excursion.
                  (save-excursion
                    (if (tags-included-tables)
                        ;; Insert the included tables into the list we
                        ;; are processing.
                        (setcdr tables (nconc (mapcar #'tags-expand-table-name
                                                      (tags-included-tables))
                                              (cdr tables))))))
	      ;; This table is not in core yet.  Insert a placeholder
	      ;; saying we must read it into core to check for included
	      ;; tables before searching the next table in the list.
	      (setq computed (cons t computed)))
	    (setq tables (cdr tables)))

	  ;; Record the tags-table-list value (and the context of the
	  ;; current directory) we computed from.
	  (setq tags-table-computed-list-for compute-for
		tags-table-computed-list (nreverse computed))))))

(defun tags-table-extend-computed-list ()
  "Extend `tags-table-computed-list' to remove the first t placeholder.

An element of the list that is t is a placeholder indicating that the
preceding element is a table that has not been read in and might
contain included tables to search.  This function reads in the first
such table and puts its included tables into the list."
  (let ((list tags-table-computed-list))
    (while (not (eq (nth 1 list) t))
      (setq list (cdr list)))
    (save-excursion
      (if (tags-verify-table (car list))
	  ;; We are now in the buffer visiting (car LIST).  Extract its
	  ;; list of included tables and insert it into the computed list.
	  (let ((tables (tags-included-tables))
		(computed nil)
		table-buffer)
	    (while tables
	      (setq computed (cons (car tables) computed)
		    table-buffer (get-file-buffer (car tables)))
	      (if table-buffer
		  (with-current-buffer table-buffer
		    (if (tags-included-tables)
			;; Insert the included tables into the list we
			;; are processing.
			(setcdr tables (append (tags-included-tables)
					       tables))))
		;; This table is not in core yet.  Insert a placeholder
		;; saying we must read it into core to check for included
		;; tables before searching the next table in the list.
		(setq computed (cons t computed)))
	      (setq tables (cdr tables)))
	    (setq computed (nreverse computed))
	    ;; COMPUTED now contains the list of included tables (and
	    ;; tables included by them, etc.).  Now splice this into the
	    ;; current list.
	    (setcdr list (nconc computed (cdr (cdr list)))))
	;; It was not a valid table, so just remove the following placeholder.
	(setcdr list (cdr (cdr list)))))))

(defun tags-expand-table-name (file)
  "Expand tags table name FILE into a complete file name."
  (setq file (expand-file-name file))
  (if (file-directory-p file)
      (expand-file-name "TAGS" file)
    file))

;; Like member, but comparison is done after tags-expand-table-name on both
;; sides and elements of LIST that are t are skipped.
(defun tags-table-list-member (file list)
  "Like (member FILE LIST) after applying `tags-expand-table-name'.
More precisely, apply `tags-expand-table-name' to FILE
and each element of LIST, returning the link whose car is the first match.
If an element of LIST is t, ignore it."
  (setq file (tags-expand-table-name file))
  (while (and list
	      (or (eq (car list) t)
		  (not (string= file (tags-expand-table-name (car list))))))
    (setq list (cdr list)))
  list)

(defun tags-verify-table (file)
  "Read FILE into a buffer and verify that it is a valid tags table.
Sets the current buffer to one visiting FILE (if it exists).
Returns non-nil if it is a valid table."
  (if (get-file-buffer file)
      ;; The file is already in a buffer.  Check for the visited file
      ;; having changed since we last used it.
      (progn
	(set-buffer (get-file-buffer file))
        (or verify-tags-table-function (tags-table-mode))
	(unless (or (verify-visited-file-modtime (current-buffer))
                    ;; 'verify-visited-file-modtime' return non-nil if
                    ;; the tags table file was meanwhile deleted.  Avoid
                    ;; asking the question below again if so.
                    (not (file-exists-p file))
		    ;; Decide whether to revert the file.
		    ;; revert-without-query can say to revert
		    ;; or the user can say to revert.
		    (not (or (let ((tail revert-without-query)
			           (found nil))
			       (while tail
			         (if (string-match (car tail) buffer-file-name)
				     (setq found t))
			         (setq tail (cdr tail)))
			       found)
			     tags-revert-without-query
			     (yes-or-no-p
			      (format "Tags file %s has changed, read new contents? "
				      file)))))
	  (revert-buffer t t)
	  (tags-table-mode))
        (and verify-tags-table-function
	     (funcall verify-tags-table-function)))
    (when (file-exists-p file)
      (let* ((buf (find-file-noselect file))
             (newfile (buffer-file-name buf)))
        (unless (string= file newfile)
          ;; find-file-noselect has changed the file name.
          ;; Propagate the change to tags-file-name and tags-table-list.
          (let ((tail (member file tags-table-list)))
            (if tail (setcar tail newfile)))
          (if (eq file tags-file-name) (setq tags-file-name newfile)))
        ;; Only change buffer now that we're done using potentially
        ;; buffer-local variables.
        (set-buffer buf)
        (tags-table-mode)
        (and verify-tags-table-function
	     (funcall verify-tags-table-function))))))

;; Subroutine of visit-tags-table-buffer.  Search the current tags tables
;; for one that has tags for THIS-FILE (or that includes a table that
;; does).  Return the name of the first table listing THIS-FILE; if
;; the table is one included by another table, it is the master table that
;; we return.  If CORE-ONLY is non-nil, check only tags tables that are
;; already in buffers--don't visit any new files.
(defun tags-table-including (this-file core-only)
  "Search current tags tables for tags for THIS-FILE.
Subroutine of `visit-tags-table-buffer'.
Looks for a tags table that has such tags or that includes a table
that has them.  Returns the name of the first such table.
Non-nil CORE-ONLY means check only tags tables that are already in
buffers.  If CORE-ONLY is nil, it is ignored."
  (let ((tables tags-table-computed-list)
	(found nil))
    ;; Loop over the list, looking for a table containing tags for THIS-FILE.
    (while (and (not found)
		tables)

      (if core-only
	  ;; Skip tables not in core.
	  (while (eq (nth 1 tables) t)
	    (setq tables (cdr (cdr tables))))
	(if (eq (nth 1 tables) t)
	    ;; This table has not been read into core yet.  Read it in now.
	    (tags-table-extend-computed-list)))

      (if tables
	  ;; Select the tags table buffer and get the file list up to date.
	  (let ((tags-file-name (car tables)))
	    (visit-tags-table-buffer 'same)
	    (if (member this-file (mapcar #'expand-file-name
					  (tags-table-files)))
		;; Found it.
		(setq found tables))))
      (setq tables (cdr tables)))
    (if found
	;; Now determine if the table we found was one included by another
	;; table, not explicitly listed.  We do this by checking each
	;; element of the computed list to see if it appears in the user's
	;; explicit list; the last element we will check is FOUND itself.
	;; Then we return the last one which did in fact appear in
	;; tags-table-list.
	(let ((could-be nil)
	      (elt tags-table-computed-list))
	  (while (not (eq elt (cdr found)))
	    (if (tags-table-list-member (car elt) tags-table-list)
		;; This table appears in the user's list, so it could be
		;; the one which includes the table we found.
		(setq could-be (car elt)))
	    (setq elt (cdr elt))
	    (if (eq t (car elt))
		(setq elt (cdr elt))))
	  ;; The last element we found in the computed list before FOUND
	  ;; that appears in the user's list will be the table that
	  ;; included the one we found.
	  could-be))))

(defun tags-next-table ()
  "Move `tags-table-list-pointer' along and set `tags-file-name'.
Subroutine of `visit-tags-table-buffer'.\
Returns nil when out of tables."
  ;; If there is a placeholder element next, compute the list to replace it.
  (while (eq (nth 1 tags-table-list-pointer) t)
    (tags-table-extend-computed-list))

  ;; Go to the next table in the list.
  (setq tags-table-list-pointer (cdr tags-table-list-pointer))
  (or tags-table-list-pointer
      ;; Wrap around.
      (setq tags-table-list-pointer tags-table-computed-list))

  (if (eq tags-table-list-pointer tags-table-list-started-at)
      ;; We have come full circle.  No more tables.
      (setq tags-table-list-pointer nil)
    ;; Set tags-file-name to the name from the list.  It is already expanded.
    (setq tags-file-name (car tags-table-list-pointer))))

;;;###autoload
(defun visit-tags-table-buffer (&optional cont cbuf)
  "Select the buffer containing the current tags table.
Optional arg CONT specifies which tags table to visit.
If CONT is a string, visit that file as a tags table.
If CONT is t, visit the next table in `tags-table-list'.
If CONT is the atom `same', don't look for a new table;
 just select the buffer visiting `tags-file-name'.
If CONT is nil or absent, choose a first buffer from information in
 `tags-file-name', `tags-table-list', `tags-table-list-pointer'.
Optional second arg CBUF, if non-nil, specifies the initial buffer,
which is important if that buffer has a local value of `tags-file-name'.
Returns t if it visits a tags table, or nil if there are no more in the list."

  ;; Set tags-file-name to the tags table file we want to visit.
  (if cbuf (set-buffer cbuf))
  (cond ((eq cont 'same)
	 ;; Use the ambient value of tags-file-name.
	 (or tags-file-name
	     (user-error "%s"
                         (substitute-command-keys
                          (concat "No tags table in use; "
                                  "use \\[visit-tags-table] to select one")))))
	((eq t cont)
	 ;; Find the next table.
	 (if (tags-next-table)
	     ;; Skip over nonexistent files.
	     (while (and (not (or (get-file-buffer tags-file-name)
				  (file-exists-p tags-file-name)))
			 (tags-next-table)))))
	(t
	 ;; Pick a table out of our hat.
	 (tags-table-check-computed-list) ;Get it up to date, we might use it.
	 (setq tags-file-name
	       (or
		;; If passed a string, use that.
		(if (stringp cont)
		    (prog1 cont
		      (setq cont nil)))
		;; First, try a local variable.
		(cdr (assq 'tags-file-name (buffer-local-variables)))
		;; Second, try a user-specified function to guess.
		(and default-tags-table-function
		     (funcall default-tags-table-function))
		;; Third, look for a tags table that contains tags for the
		;; current buffer's file.  If one is found, the lists will
		;; be frobnicated, and CONT will be set non-nil so we don't
		;; do it below.
		(and buffer-file-name
                     (save-current-buffer
                       (or
                        ;; First check only tables already in buffers.
                        (tags-table-including buffer-file-name t)
                        ;; Since that didn't find any, now do the
                        ;; expensive version: reading new files.
                        (tags-table-including buffer-file-name nil))))
		;; Fourth, use the user variable tags-file-name, if it is
		;; not already in the current list.
		(and tags-file-name
		     (not (tags-table-list-member tags-file-name
						  tags-table-computed-list))
		     tags-file-name)
		;; Fifth, use the user variable giving the table list.
		;; Find the first element of the list that actually exists.
		(let ((list tags-table-list)
		      file)
		  (while (and list
			      (setq file (tags-expand-table-name (car list)))
			      (not (get-file-buffer file))
			      (not (file-exists-p file)))
		    (setq list (cdr list)))
		  (car list))
		;; Finally, prompt the user for a file name.
		(expand-file-name
                 (read-file-name (format-prompt "Visit tags table" "TAGS")
				 default-directory
				 "TAGS"
				 t))))))

  ;; Expand the table name into a full file name.
  (setq tags-file-name (tags-expand-table-name tags-file-name))

  (unless (and (eq cont t) (null tags-table-list-pointer))
    ;; Verify that tags-file-name names a valid tags table.
    ;; Bind another variable with the value of tags-file-name
    ;; before we switch buffers, in case tags-file-name is buffer-local.
    (let ((curbuf (current-buffer))
	  (local-tags-file-name tags-file-name))
      (if (tags-verify-table local-tags-file-name)

	  ;; We have a valid tags table.
	  (progn
	    ;; Bury the tags table buffer so it
	    ;; doesn't get in the user's way.
	    (bury-buffer (current-buffer))

	    ;; If this was a new table selection (CONT is nil), make
	    ;; sure tags-table-list includes the chosen table, and
	    ;; update the list pointer variables.
	    (or cont
		;; Look in the list for the table we chose.
		(let ((found (tags-table-list-member
			      local-tags-file-name
			      tags-table-computed-list)))
		  (if found
		      ;; There it is.  Just switch to it.
		      (setq tags-table-list-pointer found
			    tags-table-list-started-at found)

		    ;; The table is not in the current set.
		    ;; Try to find it in another previously used set.
		    (let ((sets tags-table-set-list))
		      (while (and sets
				  (not (tags-table-list-member
					local-tags-file-name
					(car sets))))
			(setq sets (cdr sets)))
		      (if sets
			  ;; Found in some other set.  Switch to that set.
			  (progn
			    (or (memq tags-table-list tags-table-set-list)
				;; Save the current list.
				(setq tags-table-set-list
				      (cons tags-table-list
					    tags-table-set-list)))
			    (setq tags-table-list (car sets)))

			;; Not found in any existing set.
			(if (and tags-table-list
				 (or (eq t tags-add-tables)
				     (and tags-add-tables
					  (y-or-n-p
					   (concat "Keep current list of "
						   "tags tables also? ")))))
			    ;; Add it to the current list.
			    (setq tags-table-list (cons local-tags-file-name
							tags-table-list))

			  ;; Make a fresh list, and store the old one.
			  (message "Starting a new list of tags tables")
			  (or (null tags-table-list)
			      (memq tags-table-list tags-table-set-list)
			      (setq tags-table-set-list
				    (cons tags-table-list
					  tags-table-set-list)))
			  ;; Clear out buffers holding old tables.
			  (dolist (table tags-table-list)
			    ;; The list can contain items t.
			    (if (stringp table)
				(let ((buffer (find-buffer-visiting table)))
			      (if buffer
				  (kill-buffer buffer)))))
			  (setq tags-table-list (list local-tags-file-name))))

		      ;; Recompute tags-table-computed-list.
		      (tags-table-check-computed-list)
		      ;; Set the tags table list state variables to start
		      ;; over from tags-table-computed-list.
		      (setq tags-table-list-started-at tags-table-computed-list
			    tags-table-list-pointer
			    tags-table-computed-list)))))

	    ;; Return of t says the tags table is valid.
	    t)

	;; The buffer was not valid.  Don't use it again.
	(set-buffer curbuf)
	(kill-local-variable 'tags-file-name)
	(if (eq local-tags-file-name tags-file-name)
	    (setq tags-file-name nil))
	(user-error (if (file-exists-p local-tags-file-name)
                        "File %s is not a valid tags table"
                      "File %s does not exist")
                    local-tags-file-name)))))

;;;###autoload
(defun tags-reset-tags-tables ()
  "Reset tags state to cancel effect of any previous \\[visit-tags-table] or \\[find-tag]."
  (interactive)
  ;; Clear out the markers we are throwing away.
  (let ((i 0))
    (while (< i tags-location-ring-length)
      (if (aref (cddr tags-location-ring) i)
	  (set-marker (aref (cddr tags-location-ring) i) nil))
      (setq i (1+ i))))
  (xref-clear-marker-stack)
  (setq tags-file-name nil
	tags-location-ring (make-ring tags-location-ring-length)
	tags-table-list nil
	tags-table-computed-list nil
	tags-table-computed-list-for nil
	tags-table-list-pointer nil
	tags-table-list-started-at nil
	tags-table-set-list nil))

(defun file-of-tag (&optional relative)
  "Return the file name of the file whose tags point is within.
Assumes the tags table is the current buffer.
If RELATIVE is non-nil, file name returned is relative to tags
table file's directory.  If RELATIVE is nil, file name returned
is complete."
  (funcall file-of-tag-function relative))

;;;###autoload
(defun tags-table-files ()
  "Return a list of files in the current tags table.
Assumes the tags table is the current buffer.  The file names are returned
as they appeared in the `etags' command that created the table, usually
without directory names."
  (or tags-table-files
      (setq tags-table-files
	    (funcall tags-table-files-function))))

(defun tags-included-tables ()
  "Return a list of tags tables included by the current table.
Assumes the tags table is the current buffer."
  (or tags-included-tables
      (setq tags-included-tables (funcall tags-included-tables-function))))

(defun tags-completion-table (&optional buf)
  "Build `tags-completion-table' on demand for a buffer's tags tables.
Optional argument BUF specifies the buffer for which to build
\`tags-completion-table', and defaults to the current buffer.
The tags included in the completion table are those in the current
tags table for BUF and its (recursively) included tags tables."
  (if (not buf) (setq buf (current-buffer)))
  (with-current-buffer buf
    (or tags-completion-table
        ;; No cached value for this buffer.
        (condition-case ()
            (let (tables cont)
              (message "Making tags completion table for %s..."
                       buffer-file-name)
              (save-excursion
                ;; Iterate over the current list of tags tables.
                (while (visit-tags-table-buffer cont buf)
                  ;; Find possible completions in this table.
                  (push (funcall tags-completion-table-function) tables)
                  (setq cont t)))
              (message "Making tags completion table for %s...done"
                       buffer-file-name)
              ;; Cache the result in a variable.
              (setq tags-completion-table
                    (nreverse (delete-dups (apply #'nconc tables)))))
          (quit (message "Tags completion table construction aborted.")
                (setq tags-completion-table nil))))))

;;;###autoload
(defun tags-lazy-completion-table ()
  (let ((buf (current-buffer)))
    (lambda (string pred action)
      (with-current-buffer buf
        (save-excursion
          ;; If we need to ask for the tag table, allow that.
          (let ((enable-recursive-minibuffers t))
            (visit-tags-table-buffer))
          (complete-with-action action
                                (tags-completion-table buf)
                                string pred))))))

;;;###autoload (defun tags-completion-at-point-function ()
;;;###autoload   (if (or tags-table-list tags-file-name)
;;;###autoload       (progn
;;;###autoload         (load "etags")
;;;###autoload         (tags-completion-at-point-function))))

(defun tags-completion-at-point-function ()
  "Using tags, return a completion table for the text around point.
If no tags table is loaded, do nothing and return nil."
  (when (or tags-table-list tags-file-name)
    (let ((completion-ignore-case (find-tag--completion-ignore-case))
	  (pattern (find-tag--default))
	  beg)
      (when pattern
	(save-excursion
          ;; Avoid end-of-buffer error.
          (goto-char (+ (point) (length pattern) -1))
          ;; The find-tag function might be overly optimistic.
          (when (search-backward pattern nil t)
            (setq beg (point))
            (forward-char (length pattern))
            (list beg (point) (tags-lazy-completion-table) :exclusive 'no)))))))

(defun find-tag-tag (string)
  "Read a tag name, with defaulting and completion."
  (let* ((completion-ignore-case (find-tag--completion-ignore-case))
	 (default (find-tag--default))
	 (spec (completing-read (format-prompt string default)
				(tags-lazy-completion-table)
				nil nil nil nil default)))
    (if (equal spec "")
	(or default (user-error "There is no default tag"))
      spec)))

(defun find-tag--completion-ignore-case ()
  (if (memq tags-case-fold-search '(t nil))
      tags-case-fold-search
    case-fold-search))

(defun find-tag--default ()
  (funcall (or find-tag-default-function
               (get major-mode 'find-tag-default-function)
               #'find-tag-default)))

(defvar last-tag nil
  "Last tag found by \\[find-tag].")

(defun find-tag-interactive (prompt &optional no-default)
  "Get interactive arguments for tag functions.
The functions using this are `find-tag-noselect',
`find-tag-other-window', and `find-tag-regexp'."
  (if (and current-prefix-arg last-tag)
      (list nil (if (< (prefix-numeric-value current-prefix-arg) 0)
		    '-
		  t))
    (list (if no-default
	      (read-string prompt)
	    (find-tag-tag prompt)))))

(defvar find-tag-history nil) ; Doc string?

;; Dynamic bondage:
(defvar etags-case-fold-search)
(defvar etags-syntax-table)
(defvar local-find-tag-hook)

;;;###autoload
(defun find-tag-noselect (tagname &optional next-p regexp-p)
  "Find tag (in current tags table) whose name contains TAGNAME.
Returns the buffer containing the tag's definition and moves its point there,
but does not select the buffer.
The default for TAGNAME is the expression in the buffer near point.

If second arg NEXT-P is t (interactively, with prefix arg), search for
another tag that matches the last tagname or regexp used.  When there are
multiple matches for a tag, more exact matches are found first.  If NEXT-P
is the atom `-' (interactively, with prefix arg that is a negative number
or just \\[negative-argument]), pop back to the previous tag gone to.

If third arg REGEXP-P is non-nil, treat TAGNAME as a regexp.

A marker representing the point when this command is invoked is pushed
onto a ring and may be popped back to with \\[pop-tag-mark].
Contrast this with the ring of marks gone to by the command.

See documentation of variable `tags-file-name'."
  (interactive (find-tag-interactive "Find tag"))

  (setq find-tag-history (cons tagname find-tag-history))
  ;; Save the current buffer's value of `find-tag-hook' before
  ;; selecting the tags table buffer.  For the same reason, save value
  ;; of `tags-file-name' in case it has a buffer-local value.
  (let ((local-find-tag-hook find-tag-hook))
    (if (eq '- next-p)
	;; Pop back to a previous location.
	(if (ring-empty-p tags-location-ring)
	    (user-error "No previous tag locations")
	  (let ((marker (ring-remove tags-location-ring 0)))
	    (prog1
		;; Move to the saved location.
		(set-buffer (or (marker-buffer marker)
                                (error "The marked buffer has been deleted")))
	      (goto-char (marker-position marker))
	      ;; Kill that marker so it doesn't slow down editing.
	      (set-marker marker nil nil)
	      ;; Run the user's hook.  Do we really want to do this for pop?
	      (run-hooks 'local-find-tag-hook))))
      ;; Record whence we came.
      (xref-push-marker-stack)
      (if (and next-p last-tag)
	  ;; Find the same table we last used.
	  (visit-tags-table-buffer 'same)
	;; Pick a table to use.
	(visit-tags-table-buffer)
	;; Record TAGNAME for a future call with NEXT-P non-nil.
	(setq last-tag tagname))
      ;; Record the location so we can pop back to it later.
      (let ((marker (make-marker)))
	(with-current-buffer
            ;; find-tag-in-order does the real work.
            (find-tag-in-order
             (if (and next-p last-tag) last-tag tagname)
             (if regexp-p
                 find-tag-regexp-search-function
               find-tag-search-function)
             (if regexp-p
                 find-tag-regexp-tag-order
               find-tag-tag-order)
             (if regexp-p
                 find-tag-regexp-next-line-after-failure-p
               find-tag-next-line-after-failure-p)
             (if regexp-p "matching" "containing")
             (or (not next-p) (not last-tag)))
	  (set-marker marker (point))
	  (run-hooks 'local-find-tag-hook)
	  (ring-insert tags-location-ring marker)
	  (current-buffer))))))

;;;###autoload
(defun find-tag (tagname &optional next-p regexp-p)
  "Find tag (in current tags table) whose name contains TAGNAME.
Select the buffer containing the tag's definition, and move point there.
The default for TAGNAME is the expression in the buffer around or before point.

If second arg NEXT-P is t (interactively, with prefix arg), search for
another tag that matches the last tagname or regexp used.  When there are
multiple matches for a tag, more exact matches are found first.  If NEXT-P
is the atom `-' (interactively, with prefix arg that is a negative number
or just \\[negative-argument]), pop back to the previous tag gone to.

If third arg REGEXP-P is non-nil, treat TAGNAME as a regexp.

A marker representing the point when this command is invoked is pushed
onto a ring and may be popped back to with \\[pop-tag-mark].
Contrast this with the ring of marks gone to by the command.

See documentation of variable `tags-file-name'."
  (declare (obsolete xref-find-definitions "25.1"))
  (interactive (find-tag-interactive "Find tag"))
  (let* ((buf (find-tag-noselect tagname next-p regexp-p))
	 (pos (with-current-buffer buf (point))))
    (condition-case nil
	(switch-to-buffer buf)
      (error (pop-to-buffer buf)))
    (goto-char pos)))

;;;###autoload
(defun find-tag-other-window (tagname &optional next-p regexp-p)
  "Find tag (in current tags table) whose name contains TAGNAME.
Select the buffer containing the tag's definition in another window, and
move point there.  The default for TAGNAME is the expression in the buffer
around or before point.

If second arg NEXT-P is t (interactively, with prefix arg), search for
another tag that matches the last tagname or regexp used.  When there are
multiple matches for a tag, more exact matches are found first.  If NEXT-P
is negative (interactively, with prefix arg that is a negative number or
just \\[negative-argument]), pop back to the previous tag gone to.

If third arg REGEXP-P is non-nil, treat TAGNAME as a regexp.

A marker representing the point when this command is invoked is pushed
onto a ring and may be popped back to with \\[pop-tag-mark].
Contrast this with the ring of marks gone to by the command.

See documentation of variable `tags-file-name'."
  (declare (obsolete xref-find-definitions-other-window "25.1"))
  (interactive (find-tag-interactive "Find tag other window"))

  ;; This hair is to deal with the case where the tag is found in the
  ;; selected window's buffer; without the hair, point is moved in both
  ;; windows.  To prevent this, we save the selected window's point before
  ;; doing find-tag-noselect, and restore it after.
  (let* ((window-point (window-point))
	 (tagbuf (find-tag-noselect tagname next-p regexp-p))
	 (tagpoint (progn (set-buffer tagbuf) (point))))
    (set-window-point (prog1
			  (selected-window)
			(switch-to-buffer-other-window tagbuf)
			;; We have to set this new window's point; it
			;; might already have been displaying a
			;; different portion of tagbuf, in which case
			;; switch-to-buffer-other-window doesn't set
			;; the window's point from the buffer.
			(set-window-point (selected-window) tagpoint))
		      window-point)))

;;;###autoload
(defun find-tag-other-frame (tagname &optional next-p)
  "Find tag (in current tags table) whose name contains TAGNAME.
Select the buffer containing the tag's definition in another frame, and
move point there.  The default for TAGNAME is the expression in the buffer
around or before point.

If second arg NEXT-P is t (interactively, with prefix arg), search for
another tag that matches the last tagname or regexp used.  When there are
multiple matches for a tag, more exact matches are found first.  If NEXT-P
is negative (interactively, with prefix arg that is a negative number or
just \\[negative-argument]), pop back to the previous tag gone to.

If third arg REGEXP-P is non-nil, treat TAGNAME as a regexp.

A marker representing the point when this command is invoked is pushed
onto a ring and may be popped back to with \\[pop-tag-mark].
Contrast this with the ring of marks gone to by the command.

See documentation of variable `tags-file-name'."
  (declare (obsolete xref-find-definitions-other-frame "25.1"))
  (interactive (find-tag-interactive "Find tag other frame"))
  (let ((pop-up-frames t))
    (with-suppressed-warnings ((obsolete find-tag-other-window))
      (find-tag-other-window tagname next-p))))

;;;###autoload
(defun find-tag-regexp (regexp &optional next-p other-window)
  "Find tag (in current tags table) whose name matches REGEXP.
Select the buffer containing the tag's definition and move point there.

If second arg NEXT-P is t (interactively, with prefix arg), search for
another tag that matches the last tagname or regexp used.  When there are
multiple matches for a tag, more exact matches are found first.  If NEXT-P
is negative (interactively, with prefix arg that is a negative number or
just \\[negative-argument]), pop back to the previous tag gone to.

If third arg OTHER-WINDOW is non-nil, select the buffer in another window.

A marker representing the point when this command is invoked is pushed
onto a ring and may be popped back to with \\[pop-tag-mark].
Contrast this with the ring of marks gone to by the command.

See documentation of variable `tags-file-name'."
  (declare (obsolete xref-find-apropos "25.1"))
  (interactive (find-tag-interactive "Find tag regexp" t))
  ;; We go through find-tag-other-window to do all the display hair there.
  (funcall (if other-window 'find-tag-other-window 'find-tag)
	   regexp next-p t))

;;;###autoload
(defalias 'pop-tag-mark 'xref-go-back)


(defvar tag-lines-already-matched nil
  "Matches remembered between calls.") ; Doc string: calls to what?

(defun find-tag-in-order (pattern
			  search-forward-func
			  order
			  next-line-after-failure-p
			  matching
			  first-search)
  "Internal tag-finding function.
PATTERN is a string to pass to arg SEARCH-FORWARD-FUNC, and to any
member of the function list ORDER.  If ORDER is nil, use saved state
to continue a previous search.

Arg NEXT-LINE-AFTER-FAILURE-P is non-nil if after a failed match,
point should be moved to the next line.

Arg MATCHING is a string, an English `-ing' word, to be used in an
error message."
;; Algorithm is as follows:
;; For each qualifier-func in ORDER, go to beginning of tags file, and
;; perform inner loop: for each naive match for PATTERN found using
;; SEARCH-FORWARD-FUNC, qualify the naive match using qualifier-func.  If
;; it qualifies, go to the specified line in the specified source file
;; and return.  Qualified matches are remembered to avoid repetition.
;; State is saved so that the loop can be continued.
  (let (file				;name of file containing tag
	tag-info			;where to find the tag in FILE
	(first-table t)
	(tag-order order)
	(match-marker (make-marker))
	goto-func
	(case-fold-search (if (memq tags-case-fold-search '(nil t))
			      tags-case-fold-search
			    case-fold-search))
        (cbuf (current-buffer))
	)
    (save-excursion

      (if first-search
	  ;; This is the start of a search for a fresh tag.
	  ;; Clear the list of tags matched by the previous search.
	  ;; find-tag-noselect has already put us in the first tags table
	  ;; buffer before we got called.
	  (setq tag-lines-already-matched nil)
	;; Continuing to search for the tag specified last time.
	;; tag-lines-already-matched lists locations matched in previous
	;; calls so we don't visit the same tag twice if it matches twice
	;; during two passes with different qualification predicates.
	;; Switch to the current tags table buffer.
	(visit-tags-table-buffer 'same))

      ;; Get a qualified match.
      (catch 'qualified-match-found

	;; Iterate over the list of tags tables.
	(while (or first-table (visit-tags-table-buffer t cbuf))

	  (and first-search first-table
	       ;; Start at beginning of tags file.
	       (goto-char (point-min)))

	  (setq first-table nil)

	  ;; Iterate over the list of ordering predicates.
	  (while order
	    (while (funcall search-forward-func pattern nil t)
	      ;; Naive match found.  Qualify the match.
	      (and (funcall (car order) pattern)
		   ;; Make sure it is not a previous qualified match.
                   (not (member (set-marker match-marker (line-beginning-position))
				tag-lines-already-matched))
		   (throw 'qualified-match-found nil))
	      (if next-line-after-failure-p
		  (forward-line 1)))
	    ;; Try the next flavor of match.
	    (setq order (cdr order))
	    (goto-char (point-min)))
	  (setq order tag-order))
	;; We throw out on match, so only get here if there were no matches.
	;; Clear out the markers we use to avoid duplicate matches so they
	;; don't slow down editing and are immediately available for GC.
	(while tag-lines-already-matched
	  (set-marker (car tag-lines-already-matched) nil nil)
	  (setq tag-lines-already-matched (cdr tag-lines-already-matched)))
	(set-marker match-marker nil nil)
	(user-error "No %stags %s %s" (if first-search "" "more ")
                    matching pattern))

      ;; Found a tag; extract location info.
      (beginning-of-line)
      (setq tag-lines-already-matched (cons match-marker
					    tag-lines-already-matched))
      ;; Expand the filename, using the tags table buffer's default-directory.
      ;; We should be able to search for file-name backwards in file-of-tag:
      ;; the beginning-of-line is ok except when positioned on a "file-name" tag.
      (setq file (expand-file-name
		  (if (memq (car order) '(tag-exact-file-name-match-p
					  tag-file-name-match-p
					  tag-partial-file-name-match-p))
                      (save-excursion (forward-line 1)
                                      (file-of-tag))
                    (file-of-tag)))
	    tag-info (funcall snarf-tag-function))

      ;; Get the local value in the tags table buffer before switching buffers.
      (setq goto-func goto-tag-location-function)
      (tag-find-file-of-tag-noselect file)
      (widen)
      (push-mark)
      (funcall goto-func tag-info)

      ;; Return the buffer where the tag was found.
      (current-buffer))))

(defun tag-find-file-of-tag-noselect (file)
  "Find the right line in the specified FILE."
  ;; If interested in compressed-files, search files with extensions.
  ;; Otherwise, search only the real file.
  (let* ((buffer-search-extensions (if auto-compression-mode
				       tags-compression-info-list
				     '("")))
	 the-buffer
	 (file-search-extensions buffer-search-extensions))
    ;; search a buffer visiting the file with each possible extension
    ;; Note: there is a small inefficiency in find-buffer-visiting :
    ;;   truename is computed even if not needed. Not too sure about this
    ;;   but I suspect truename computation accesses the disk.
    ;;   It is maybe a good idea to optimize this find-buffer-visiting.
    ;; An alternative would be to use only get-file-buffer
    ;; but this looks less "sure" to find the buffer for the file.
    (while (and (not the-buffer) buffer-search-extensions)
      (setq the-buffer (find-buffer-visiting (concat file (car buffer-search-extensions))))
      (setq buffer-search-extensions (cdr buffer-search-extensions)))
    ;; if found a buffer but file modified, ensure we re-read !
    (if (and the-buffer (not (verify-visited-file-modtime the-buffer)))
	(find-file-noselect (buffer-file-name the-buffer)))
    ;; if no buffer found, search for files with possible extensions on disk
    (while (and (not the-buffer) file-search-extensions)
      (if (not (file-exists-p (concat file (car file-search-extensions))))
	  (setq file-search-extensions (cdr file-search-extensions))
	(setq the-buffer (find-file-noselect (concat file (car file-search-extensions))))))
    (if (not the-buffer)
	(if auto-compression-mode
	    (error "File %s (with or without extensions %s) not found" file tags-compression-info-list)
	  (error "File %s not found" file))
      (set-buffer the-buffer))))

(defun tag-find-file-of-tag (file) ; Doc string?
  (let ((buf (tag-find-file-of-tag-noselect file)))
    (condition-case nil
	(switch-to-buffer buf)
      (error (pop-to-buffer buf)))))

;; `etags' TAGS file format support.

(defun etags-recognize-tags-table ()
  "If `etags-verify-tags-table', make buffer-local format variables.
If current buffer is a valid etags TAGS file, then give it
buffer-local values of tags table format variables."
  (when (etags-verify-tags-table)
    (setq-local file-of-tag-function 'etags-file-of-tag)
    (setq-local tags-table-files-function 'etags-tags-table-files)
    (setq-local tags-completion-table-function 'etags-tags-completion-table)
    (setq-local snarf-tag-function 'etags-snarf-tag)
    (setq-local goto-tag-location-function 'etags-goto-tag-location)
    (setq-local find-tag-regexp-search-function 're-search-forward)
    (setq-local find-tag-regexp-tag-order '(tag-re-match-p))
    (setq-local find-tag-regexp-next-line-after-failure-p t)
    (setq-local find-tag-search-function 'search-forward)
    (setq-local find-tag-tag-order '(tag-exact-file-name-match-p
                                     tag-file-name-match-p
                                     tag-exact-match-p
                                     tag-implicit-name-match-p
                                     tag-symbol-match-p
                                     tag-word-match-p
                                     tag-partial-file-name-match-p
                                     tag-any-match-p))
    (setq-local find-tag-next-line-after-failure-p nil)
    (setq-local list-tags-function 'etags-list-tags)
    (setq-local tags-apropos-function 'etags-tags-apropos)
    (setq-local tags-included-tables-function 'etags-tags-included-tables)
    (setq-local verify-tags-table-function 'etags-verify-tags-table)))

(defun etags-verify-tags-table ()
  "Return non-nil if the current buffer is a valid etags TAGS file."
  ;; Use eq instead of = in case char-after returns nil.
  (eq (char-after (point-min)) ?\f))

(defun etags-file-of-tag (&optional relative) ; Doc string?
  (save-excursion
    (re-search-backward "\f\n\\([^\n]+\\),[0-9]*\n")
    (let ((str (convert-standard-filename
                (buffer-substring (match-beginning 1) (match-end 1)))))
      (if relative
	  str
	(expand-file-name str (file-truename default-directory))))))


(defun etags-tags-completion-table () ; Doc string?
  (let (table
	(progress-reporter
	 (make-progress-reporter
	  (format "Making tags completion table for %s..." buffer-file-name)
	  (point-min) (point-max))))
    (save-excursion
      (goto-char (point-min))
      ;; This regexp matches an explicit tag name or the place where
      ;; it would start.
      (while (re-search-forward
              "[\f\t\n\r()=,; ]?\177\\(?:\\([^\n\001]+\\)\001\\)?"
	      nil t)
	(push	(prog1 (if (match-beginning 1)
			   ;; There is an explicit tag name.
			   (buffer-substring (match-beginning 1) (match-end 1))
			 ;; No explicit tag name.  Backtrack a little,
                         ;; and look for the implicit one.
                         (goto-char (match-beginning 0))
                         (skip-chars-backward "^\f\t\n\r()=,; ")
                         (prog1
                             (buffer-substring (point) (match-beginning 0))
                           (goto-char (match-end 0))))
		  (progress-reporter-update progress-reporter (point)))
		table)))
    table))

(defun etags-snarf-tag (&optional use-explicit) ; Doc string?
  (let (tag-text line startpos explicit-start)
    (if (save-excursion
	  (forward-line -1)
	  (looking-at "\f\n"))
	;; The match was for a source file name, not any tag within a file.
	;; Give text of t, meaning to go exactly to the location we specify,
	;; the beginning of the file.
	(setq tag-text t
	      line nil
	      startpos (point-min))

      ;; Find the end of the tag and record the whole tag text.
      (search-forward "\177")
      (setq tag-text (buffer-substring (1- (point)) (line-beginning-position)))
      ;; If use-explicit is non-nil and explicit tag is present, use it as part of
      ;; return value. Else just skip it.
      (setq explicit-start (point))
      (when (and (search-forward "\001" (line-beginning-position 2) t)
		 use-explicit)
	(setq tag-text (buffer-substring explicit-start (1- (point)))))


      (if (looking-at "[0-9]")
	  (setq line (string-to-number (buffer-substring
                                        (point)
                                        (progn (skip-chars-forward "0-9")
                                               (point))))))
      (search-forward ",")
      (if (looking-at "[0-9]")
	  (setq startpos (string-to-number (buffer-substring
                                            (point)
                                            (progn (skip-chars-forward "0-9")
                                                   (point)))))))
    ;; Leave point on the next line of the tags file.
    (forward-line 1)
    (cons tag-text (cons line startpos))))

(defun etags-goto-tag-location (tag-info)
  "Go to location of tag specified by TAG-INFO.
TAG-INFO is a cons (TEXT LINE . POSITION).
TEXT is the initial part of a line containing the tag.
LINE is the line number.
POSITION is the (one-based) char position of TEXT within the file.

If TEXT is t, it means the tag refers to exactly LINE or POSITION,
whichever is present, LINE having preference, no searching.
Either LINE or POSITION can be nil.  POSITION is used if present.

If the tag isn't exactly at the given position, then look near that
position using a search window that expands progressively until it
hits the start of file."
  (let ((startpos (cdr (cdr tag-info)))
	(line (car (cdr tag-info)))
	offset found pat)
    (if (eq (car tag-info) t)
	;; Direct file tag.
	(cond (line (progn (goto-char (point-min))
			   (forward-line (1- line))))
	      (startpos (goto-char startpos))
              (t (error "etags.el: BUG: bogus direct file tag")))
      ;; This constant is 1/2 the initial search window.
      ;; There is no sense in making it too small,
      ;; since just going around the loop once probably
      ;; costs about as much as searching 2000 chars.
      (setq offset 1000
	    found nil
	    pat (concat (if (eq selective-display t)
			    "\\(^\\|\^m\\)" "^")
			(regexp-quote (car tag-info))))
      ;; The character position in the tags table is 0-origin and counts CRs.
      ;; Convert it to a 1-origin Emacs character position.
      (when startpos
        (setq startpos (1+ startpos))
        (when (and line
                   (eq 1 (coding-system-eol-type buffer-file-coding-system)))
          ;; Act as if CRs were elided from all preceding lines.
          ;; Although this doesn't always give exactly the correct position,
          ;; it does typically improve the guess.
          (setq startpos (- startpos (1- line)))))
      ;; If no char pos was given, try the given line number.
      (or startpos
	  (if line
	      (setq startpos (progn (goto-char (point-min))
				    (forward-line (1- line))
				    (point)))))
      (or startpos
	  (setq startpos (point-min)))
      ;; First see if the tag is right at the specified location.
      (goto-char startpos)
      (setq found (looking-at pat))
      (while (and (not found)
		  (progn
		    (goto-char (- startpos offset))
		    (not (bobp))))
	(setq found
	      (re-search-forward pat (+ startpos offset) t)
	      offset (* 3 offset)))	; expand search window
      (or found
	  (re-search-forward pat nil t)
	  (user-error "Rerun etags: `%s' not found in %s"
                      pat buffer-file-name)))
    ;; Position point at the right place
    ;; if the search string matched an extra Ctrl-m at the beginning.
    (and (eq selective-display t)
	 (looking-at "\^m")
	 (forward-char 1))
    (beginning-of-line)))

(defun etags-list-tags (file) ; Doc string?
  (goto-char (point-min))
  (when (re-search-forward (concat "\f\n" "\\(" file "\\)" ",") nil t)
    (let ((path (save-excursion (forward-line 1) (file-of-tag)))
	  ;; Get the local value in the tags table
	  ;; buffer before switching buffers.
	  (goto-func goto-tag-location-function)
	  tag tag-info pt)
    (forward-line 1)
    ;; Exuberant ctags add a line starting with the DEL character;
    ;; skip past it.
    (when (looking-at "\177")
      (forward-line 1))
    (while (not (or (eobp) (looking-at "\f")))
      ;; We used to use explicit tags when available, but the current goto-func
      ;; can only handle implicit tags.
      (setq tag-info (save-excursion (funcall snarf-tag-function nil))
	    tag (car tag-info)
	    pt (with-current-buffer standard-output (point)))
      (princ tag)
      (when (= (aref tag 0) ?\() (princ " ...)"))
      (with-current-buffer standard-output
	(make-text-button pt (point)
			  'tag-info tag-info
			  'file-path path
			  'goto-func goto-func
			  'action (lambda (button)
				    (let ((tag-info (button-get button 'tag-info))
					  (goto-func (button-get button 'goto-func)))
				      (tag-find-file-of-tag (button-get button 'file-path))
				      (widen)
				      (funcall goto-func tag-info)))
			  'follow-link t
			  'face tags-tag-face
			  'type 'button))
      (terpri)
      (forward-line 1))
    t)))

(defmacro tags-with-face (face &rest body)
  "Execute BODY, give output to `standard-output' face FACE."
  (let ((pp (make-symbol "start")))
    `(let ((,pp (with-current-buffer standard-output (point))))
       ,@body
       (put-text-property ,pp (with-current-buffer standard-output (point))
			  'face ,face standard-output))))

(defun etags-tags-apropos-additional (regexp)
  "Display tags matching REGEXP from `tags-apropos-additional-actions'."
  (with-current-buffer standard-output
    (dolist (oba tags-apropos-additional-actions)
      (princ "\n\n")
      (tags-with-face 'highlight (princ (car oba)))
      (princ":\n\n")
      (let* ((beg (point))
	     (symbs (car (cddr oba)))
             (ins-symb (lambda (sy)
                         (let ((sn (symbol-name sy)))
                           (when (string-match regexp sn)
                             (make-text-button (point)
					  (progn (princ sy) (point))
					  'action-internal(cadr oba)
					  'action (lambda (button) (funcall
								    (button-get button 'action-internal)
								    (button-get button 'item)))
					  'item sn
					  'face tags-tag-face
					  'follow-link t
					  'type 'button)
                             (terpri))))))
        (when (symbolp symbs)
          (if (boundp symbs)
	      (setq symbs (symbol-value symbs))
	    (insert (format-message "symbol `%s' has no value\n" symbs))
	    (setq symbs nil)))
        (if (obarrayp symbs)
	    (mapatoms ins-symb symbs)
	  (dolist (sy symbs)
	    (funcall ins-symb (car sy))))
        (sort-lines nil beg (point))))))

(defun etags-tags-apropos (string) ; Doc string?
  (when tags-apropos-verbose
    (princ (substitute-command-keys "Tags in file `"))
    (tags-with-face 'highlight (princ buffer-file-name))
    (princ (substitute-command-keys "':\n\n")))
  (goto-char (point-min))
  (let ((progress-reporter (make-progress-reporter
			    (format-message
			     "Making tags apropos buffer for `%s'..." string)
			    (point-min) (point-max))))
    (while (re-search-forward string nil t)
      (progress-reporter-update progress-reporter (point))
      (beginning-of-line)

      (let* ( ;; Get the local value in the tags table
	     ;; buffer before switching buffers.
	     (goto-func goto-tag-location-function)
	     (tag-info (save-excursion (funcall snarf-tag-function)))
	     (tag (if (eq t (car tag-info)) nil (car tag-info)))
	     (file-path (save-excursion (if tag (file-of-tag)
					  (save-excursion (forward-line 1)
							  (file-of-tag)))))
	     (file-label (if tag (file-of-tag t)
			   (save-excursion (forward-line 1)
					   (file-of-tag t))))
	     (pt (with-current-buffer standard-output (point))))
	(if tag
	    (progn
	      (princ (format "[%s]: " file-label))
	      (princ tag)
	      (when (= (aref tag 0) ?\() (princ " ...)"))
	      (with-current-buffer standard-output
		(make-text-button pt (point)
				  'tag-info tag-info
				  'file-path file-path
				  'goto-func goto-func
				  'action (lambda (button)
					    (let ((tag-info (button-get button 'tag-info))
						  (goto-func (button-get button 'goto-func)))
					      (tag-find-file-of-tag (button-get button 'file-path))
					      (widen)
					      (funcall goto-func tag-info)))
				  'follow-link t
				  'face tags-tag-face
				  'type 'button)))
	  (princ (format "- %s" file-label))
	  (with-current-buffer standard-output
	    (make-text-button pt (point)
			      'file-path file-path
			      'action (lambda (button)
					(tag-find-file-of-tag (button-get button 'file-path))
					;; Get the local value in the tags table
					;; buffer before switching buffers.
					(goto-char (point-min)))
			      'follow-link t
			      'face tags-tag-face
			      'type 'button))))
      (terpri)
      (forward-line 1))
    (message nil))
  (when tags-apropos-verbose (princ "\n")))

(defun etags-tags-table-files () ; Doc string?
  (let ((files nil)
	beg)
    (goto-char (point-min))
    (while (search-forward "\f\n" nil t)
      (setq beg (point))
      (end-of-line)
      (skip-chars-backward "^," beg)
      (or (looking-at "include$")
	  (push (convert-standard-filename
                 (buffer-substring beg (1- (point))))
                files)))
    (nreverse files)))

;; FIXME?  Should this save-excursion?
(defun etags-tags-included-tables () ; Doc string?
  (let ((files nil)
	beg)
    (goto-char (point-min))
    (while (search-forward "\f\n" nil t)
      (setq beg (point))
      (end-of-line)
      (skip-chars-backward "^," beg)
      (when (looking-at "include$")
        ;; Expand in the default-directory of the tags table buffer.
        (push (expand-file-name (convert-standard-filename
                                 (buffer-substring beg (1- (point)))))
              files)))
    (nreverse files)))

;; Empty tags file support.

(defun tags-recognize-empty-tags-table ()
  "Return non-nil if current buffer is empty.
If empty, make buffer-local values of the tags table format variables
that do nothing."
  (when (zerop (buffer-size))
    (setq-local tags-table-files-function #'ignore)
    (setq-local tags-completion-table-function #'ignore)
    (setq-local find-tag-regexp-search-function #'ignore)
    (setq-local find-tag-search-function #'ignore)
    (setq-local tags-apropos-function #'ignore)
    (setq-local tags-included-tables-function #'ignore)
    (setq-local verify-tags-table-function
                (lambda () (zerop (buffer-size))))))


;; Match qualifier functions for tagnames.
;; These functions assume the etags file format defined in etc/ETAGS.EBNF.

;; This might be a neat idea, but it's too hairy at the moment.
;;(defmacro tags-with-syntax (&rest body)
;;  (declare (debug t))
;;   `(with-syntax-table
;;        (with-current-buffer (find-file-noselect (file-of-tag))
;;          (syntax-table))
;;      ,@body))

;; exact file name match, i.e. searched tag must match complete file
;; name including directories parts if there are some.
(defun tag-exact-file-name-match-p (tag)
  "Return non-nil if TAG matches complete file name.
Any directory part of the file name is also matched."
  (and (looking-at ",[0-9\n]")
       (save-excursion (backward-char (+ 2 (length tag)))
		       (looking-at "\f\n"))))

;; file name match as above, but searched tag must match the file
;; name not including the directories if there are some.
(defun tag-file-name-match-p (tag)
  "Return non-nil if TAG matches file name, excluding directory part."
  (and (looking-at ",[0-9\n]")
       (save-excursion (backward-char (1+ (length tag)))
		       (looking-at "/"))))

;; this / to detect we are after a directory separator is ok for unix,
;; is there a variable that contains the regexp for directory separator
;; on whatever operating system ?
;; Looks like ms-win will lose here :).

;; t if point is at a tag line that matches TAG exactly.
;; point should be just after a string that matches TAG.
(defun tag-exact-match-p (tag)
  "Return non-nil if current tag line matches TAG exactly.
Point should be just after a string that matches TAG."
  ;; The match is really exact if there is an explicit tag name.
  (or (and (eq (char-after (point)) ?\001)
	   (eq (char-after (- (point) (length tag) 1)) ?\177))
      ;; We are not on the explicit tag name, but perhaps it follows.
      (looking-at (concat "[^\177\n]*\177"
                          (regexp-quote tag)
                          ;; The optional "/x" part is for Ada tags.
                          "\\(/[fpsbtk]\\)?\001"))))

;; t if point is at a tag line that has an implicit name.
;; point should be just after a string that matches TAG.
(defun tag-implicit-name-match-p (tag)
  "Return non-nil if current tag line has an implicit name.
Point should be just after a string that matches TAG."
  ;; Look at the comment of the make_tag function in lib-src/etags.c for
  ;; a textual description of the four rules.
  (and (string-match "^[^ \t()=,;]+$" tag) ;rule #1
       ;; Rules #2 and #4, and a check that there's no explicit name.
       (looking-at "[ \t()=,;]?\177[0-9]*,[0-9]*$")
       (save-excursion
	 (backward-char (1+ (length tag)))
	 (looking-at "[\n \t()=,;]"))))	;rule #3

;; t if point is at a tag line that matches TAG as a symbol.
;; point should be just after a string that matches TAG.
(defun tag-symbol-match-p (tag)
  "Return non-nil if current tag line matches TAG as a symbol.
Point should be just after a string that matches TAG."
  (and (looking-at "\\Sw.*\177") (looking-at "\\S_.*\177")
       (save-excursion
	 (backward-char (1+ (length tag)))
	 (and (looking-at "\\Sw") (looking-at "\\S_")))))

;; t if point is at a tag line that matches TAG as a word.
;; point should be just after a string that matches TAG.
(defun tag-word-match-p (tag)
  "Return non-nil if current tag line matches TAG as a word.
Point should be just after a string that matches TAG."
  (and (looking-at "\\b.*\177")
       (save-excursion (backward-char (length tag))
		       (looking-at "\\b"))))

;; partial file name match, i.e. searched tag must match a substring
;; of the file name (potentially including a directory separator).
(defun tag-partial-file-name-match-p (_tag)
  "Return non-nil if current tag matches file name.
This is a substring match, and it can include directory separators.
Point should be just after a string that matches TAG."
  (and (looking-at ".*,[0-9\n]")
       (save-excursion (beginning-of-line)
                       (backward-char 2)
  		       (looking-at "\f\n"))))

;; t if point is in a tag line with a tag containing TAG as a substring.
(defun tag-any-match-p (_tag)
  "Return non-nil if current tag line contains TAG as a substring."
  (looking-at ".*\177"))

;; t if point is at a tag line that matches RE as a regexp.
(defun tag-re-match-p (re)
  "Return non-nil if current tag line matches regexp RE."
  (save-excursion
    (beginning-of-line)
    (let ((bol (point)))
      (and (search-forward "\177" (line-end-position) t)
	   (re-search-backward re bol t)))))
(define-obsolete-variable-alias 'tags-loop-revert-buffers 'fileloop-revert-buffers "27.1")

;;;###autoload
(defalias 'next-file 'tags-next-file)
(make-obsolete 'next-file
               "use `tags-next-file' or `fileloop-initialize' and `fileloop-next-file' instead" "27.1")
;;;###autoload
(defun tags-next-file (&optional initialize novisit)
  "Select next file among files in current tags table.

A first argument of t (prefix arg, if interactive) initializes to the
beginning of the list of files in the tags table.  If the argument is
neither nil nor t, it is evalled to initialize the list of files.

Non-nil second argument NOVISIT means use a temporary buffer
 to save time and avoid uninteresting warnings.

Value is nil if the file was already visited;
if the file was newly read in, the value is the filename."
  ;; Make the interactive arg t if there was any prefix arg.
  (interactive (list (if current-prefix-arg t)))
  (when initialize ;; Not the first run.
    (tags--compat-initialize initialize))
  (fileloop-next-file novisit)
  (switch-to-buffer (current-buffer)))

(defun etags--ensure-file (file)
  "Ensure FILE can be visited.

FILE should be an expanded file name.
This function tries to locate FILE, possibly adding it a suffix
present in `tags-compression-info-list'.  If the file can't be found,
signals an error.
Else, returns the filename that can be visited for sure."
  (let ((f (locate-file file nil (if auto-compression-mode
				     tags-compression-info-list
				   '("")))))
    (unless f
      (signal 'file-missing (list "Cannot locate file in TAGS" file)))
    f))

(defun tags--all-files ()
  (save-excursion
    (let ((cbuf (current-buffer))
          (files nil))
      ;; Visit the tags table buffer to get its list of files.
      (visit-tags-table-buffer)
      ;; Copy the list so we can setcdr below, and expand the file
      ;; names while we are at it, in this buffer's default directory.
      (setq files (mapcar #'expand-file-name (tags-table-files)))
      ;; Iterate over all the tags table files, collecting
      ;; a complete list of referenced file names.
      (while (visit-tags-table-buffer t cbuf)
        ;; Find the tail of the working list and chain on the new
        ;; sublist for this tags table.
        (let ((tail files))
          (while (cdr tail)
            (setq tail (cdr tail)))
          ;; Use a copy so the next loop iteration will not modify the
          ;; list later returned by (tags-table-files).
          (setf (if tail (cdr tail) files)
                (mapcar #'expand-file-name (tags-table-files)))))
      (mapcar #'etags--ensure-file files))))

(make-obsolete-variable 'tags-loop-operate 'fileloop-initialize "27.1")
(defvar tags-loop-operate nil
  "Form for `tags-loop-continue' to eval to change one file.")

(make-obsolete-variable 'tags-loop-scan 'fileloop-initialize "27.1")
(defvar tags-loop-scan
  '(user-error "%s"
	       (substitute-command-keys
	        "No \\[tags-search] or \\[tags-query-replace] in progress"))
  "Form for `tags-loop-continue' to eval to scan one file.
If it returns non-nil, this file needs processing by evalling
`tags-loop-operate'.  Otherwise, move on to the next file.")

(defun tags-loop-eval (form)
  "Evaluate FORM and return its result.
Bind `case-fold-search' during the evaluation, depending on the value of
`tags-case-fold-search'."
  (let ((case-fold-search (if (memq tags-case-fold-search '(t nil))
			      tags-case-fold-search
			    case-fold-search)))
    (eval form)))

(defun tags--compat-files (files)
  (cond
   ((eq files t) (tags--all-files)) ;; Initialize the list from the tags table.
   ((functionp files) files)
   ((stringp (car-safe files)) files)
   (t
    ;; Backward compatibility <27.1
    ;; Initialize the list by evalling the argument.
    (eval files))))

(defun tags--compat-initialize (initialize)
  (fileloop-initialize
   (tags--compat-files initialize)
   (lambda () (tags-loop-eval tags-loop-scan))
   (if tags-loop-operate
       (lambda () (tags-loop-eval tags-loop-operate))
     (lambda () (message "Scanning file %s...found" buffer-file-name) nil))))

;;;###autoload
(defun tags-loop-continue (&optional first-time)
  "Continue last \\[tags-search] or \\[tags-query-replace] command.
Used noninteractively with non-nil argument to begin such a command (the
argument is passed to `next-file', which see)."
  ;; Two variables control the processing we do on each file: the value of
  ;; `tags-loop-scan' is a form to be executed on each file to see if it is
  ;; interesting (it returns non-nil if so) and `tags-loop-operate' is a form to
  ;; evaluate to operate on an interesting file.  If the latter evaluates to
  ;; nil, we exit; otherwise we scan the next file.
  (declare (obsolete fileloop-continue "27.1"))
  (interactive)
  (when first-time ;; Backward compatibility.
    (tags--compat-initialize first-time))
  (fileloop-continue))

;; We use it to detect when the last loop was a tags-search.
(defvar tags--last-search-operate-function nil)

;;;###autoload
(defun tags-search (regexp &optional files)
  "Search through all files listed in tags table for match for REGEXP.
Stops when a match is found.
To continue searching for next match, use the command \\[fileloop-continue].

If FILES if non-nil should be a list or an iterator returning the
files to search.  The search will be restricted to these files.

Also see the documentation of the `tags-file-name' variable."
  (interactive "sTags search (regexp): ")
  (unless (and (equal regexp "")
               ;; FIXME: If some other fileloop operation took place,
               ;; rather than search for "", we should repeat the last search!
	       (eq fileloop--operate-function
                   tags--last-search-operate-function))
    (fileloop-initialize-search
     regexp
     (tags--compat-files (or files t))
     tags-case-fold-search)
    ;; Store it, so we can detect if some other fileloop operation took
    ;; place since the last search!
    (setq tags--last-search-operate-function fileloop--operate-function))
  (fileloop-continue))

;;;###autoload
(defun tags-query-replace (from to &optional delimited files)
  "Do `query-replace-regexp' of FROM with TO on all files listed in tags table.
Third arg DELIMITED (prefix arg) means replace only word-delimited matches.
If you exit (\\[keyboard-quit], RET or q), you can resume the query replace
with the command \\[fileloop-continue].

As each match is found, the user must type a character saying
what to do with it.  Type SPC or `y' to replace the match,
DEL or `n' to skip and go to the next match.  For more directions,
type \\[help-command] at that time.

For non-interactive use, this is superseded by `fileloop-initialize-replace'."
  (declare (advertised-calling-convention (from to &optional delimited) "27.1"))
  (interactive (query-replace-read-args "Tags query replace (regexp)" t t))
  (fileloop-initialize-replace
   from to
   (tags--compat-files (or files t))
   (if (equal from (downcase from)) nil 'default)
   delimited)
  (fileloop-continue))

(defun tags-complete-tags-table-file (string predicate what)
  "Complete STRING from file names in the current tags table.
PREDICATE, if non-nil, is a function to filter possible matches:
if it returns nil, the match is ignored.  If PREDICATE is nil,
every possible match is acceptable.
WHAT is a flag specifying the type of completion: t means `all-completions'
operation, any other value means `try-completions' operation.

This function serves as COLLECTION argument to `completing-read',
see the Info node `(elisp) Programmed Completion' for more detailed
description of the arguments."
  (save-excursion
    ;; If we need to ask for the tag table, allow that.
    (let ((enable-recursive-minibuffers t))
      (visit-tags-table-buffer))
    (if (eq what t)
        (all-completions string (tags-table-files) predicate)
      (try-completion string (tags-table-files) predicate))))

(defun tags--get-current-buffer-name-in-tags-file ()
  "Return file name that corresponds to the current buffer in the tags table.
This returns the file name which corresponds to the current buffer relative
to the directory of the current tags table (see `visit-tags-table-buffer').
If no file is associated with the current buffer, this function returns nil."
  (let ((buf-fname (buffer-file-name)))
    ;; FIXME: Are there interesting cases where 'buffer-file-name'
    ;; returns nil, but there's some file we expect to find in TAGS that
    ;; is associated with the buffer?  The obvious cases of Dired and
    ;; Info buffers are not interesting for TAGS, but are there any
    ;; others?
    (if buf-fname
        (let ((tag-dir
               (save-excursion
                 (visit-tags-table-buffer)
                 (file-name-directory buf-fname))))
          (file-relative-name buf-fname tag-dir)))))

;;;###autoload
(defun list-tags (file &optional _next-match)
  "Display list of tags in file FILE.
Interactively, prompt for FILE, with completion, offering the current
buffer's file name as the default.
This command searches only the first table in the list of tags tables,
and does not search included tables.
FILE should be as it was submitted to the `etags' command, which usually
means relative to the directory of the tags table file."
  (interactive (list (completing-read
                      "List tags in file: "
                      'tags-complete-tags-table-file
                      nil t
                      ;; Default FILE to the current buffer's file.
                      (tags--get-current-buffer-name-in-tags-file))))
  (if (string-empty-p file)
      (user-error "You must specify a file name"))
  (with-output-to-temp-buffer "*Tags List*"
    (princ (substitute-command-keys "Tags in file `"))
    (tags-with-face 'highlight (princ file))
    (princ (substitute-command-keys "':\n\n"))
    (save-excursion
      (let ((first-time t)
	    (gotany nil)
            (cbuf (current-buffer)))
	(while (visit-tags-table-buffer (not first-time) cbuf)
	  (setq first-time nil)
	  (if (funcall list-tags-function file)
	      (setq gotany t)))
	(or gotany
	    (user-error "File %s not in current tags tables" file)))))
  (with-current-buffer "*Tags List*"
    (require 'apropos)
    (with-no-warnings
      (apropos-mode))
    (setq buffer-read-only t)))

;;;###autoload
(defun tags-apropos (regexp)
  "Display list of all tags in tags table REGEXP matches."
  (declare (obsolete xref-find-apropos "25.1"))
  (interactive "sTags apropos (regexp): ")
  (with-output-to-temp-buffer "*Tags List*"
    (princ (substitute-command-keys
	    "Click mouse-2 to follow tags.\n\nTags matching regexp `"))
    (tags-with-face 'highlight (princ regexp))
    (princ (substitute-command-keys "':\n\n"))
    (save-excursion
      (let ((first-time t)
            (cbuf (current-buffer)))
	(while (visit-tags-table-buffer (not first-time) cbuf)
	  (setq first-time nil)
	  (funcall tags-apropos-function regexp))))
    (etags-tags-apropos-additional regexp))
  (with-current-buffer "*Tags List*"
    (require 'apropos)
    (declare-function apropos-mode "apropos")
    (apropos-mode)
    ;; apropos-mode is derived from fundamental-mode and it kills
    ;; all local variables.
    (setq buffer-read-only t)))

;; XXX Kludge interface.

(define-button-type 'tags-select-tags-table
  'action 'select-tags-table-select
  'follow-link t
  'help-echo "RET, t or mouse-2: select tags table")

;; XXX If a file is in multiple tables, selection may get the wrong one.
;;;###autoload
(defun select-tags-table ()
  "Select a tags table file from a menu of those you have already used.
The list of tags tables to select from is stored in `tags-table-set-list';
see the doc of that variable if you want to add names to the list."
  (interactive)
  (pop-to-buffer "*Tags Table List*")
  (setq buffer-read-only nil
	buffer-undo-list t)
  (erase-buffer)
  (let ((set-list tags-table-set-list)
	(desired-point nil)
	b)
    (when tags-table-list
      (setq desired-point (point-marker))
      (setq b (point))
      (princ (mapcar #'abbreviate-file-name tags-table-list) (current-buffer))
      (make-text-button b (point) 'type 'tags-select-tags-table
                        'etags-table (car tags-table-list))
      (insert "\n"))
    (while set-list
      (unless (eq (car set-list) tags-table-list)
	(setq b (point))
	(princ (mapcar #'abbreviate-file-name (car set-list)) (current-buffer))
	(make-text-button b (point) 'type 'tags-select-tags-table
                          'etags-table (car (car set-list)))
	(insert "\n"))
      (setq set-list (cdr set-list)))
    (when tags-file-name
      (or desired-point
          (setq desired-point (point-marker)))
      (setq b (point))
      (insert (abbreviate-file-name tags-file-name))
      (make-text-button b (point) 'type 'tags-select-tags-table
                        'etags-table tags-file-name)
      (insert "\n"))
    (setq set-list (delete tags-file-name
			   (apply #'nconc (cons (copy-sequence tags-table-list)
					        (mapcar #'copy-sequence
						        tags-table-set-list)))))
    (while set-list
      (setq b (point))
      (insert (abbreviate-file-name (car set-list)))
      (make-text-button b (point) 'type 'tags-select-tags-table
                          'etags-table (car set-list))
      (insert "\n")
      (setq set-list (delete (car set-list) set-list)))
    (goto-char (point-min))
    (insert-before-markers
     (substitute-command-keys
      "Type \\`t' to select a tags table or set of tags tables:\n\n"))
    (if desired-point
	(goto-char desired-point))
    (set-window-start (selected-window) 1 t))
  (set-buffer-modified-p nil)
  (select-tags-table-mode))

(defvar-keymap select-tags-table-mode-map
  :doc "Keymap for `select-tags-table-mode'."
  :parent button-buffer-map
  "t"   #'push-button
  "SPC" #'next-line
  "DEL" #'previous-line
  "n"   #'next-line
  "p"   #'previous-line
  "q"   #'select-tags-table-quit)

(define-derived-mode select-tags-table-mode special-mode "Select Tags Table"
  "Major mode for choosing a current tags table among those already loaded."
  )

(defun select-tags-table-select (button)
  "Select the tags table named on this line."
  (interactive (list (or (button-at (line-beginning-position))
                         (error "No tags table on current line"))))
  (let ((name (button-get button 'etags-table)))
    (visit-tags-table name)
    (select-tags-table-quit)
    (message "Tags table now %s" name)))

(defun select-tags-table-quit ()
  "Kill the buffer and delete the selected window."
  (interactive)
  (quit-window t (selected-window)))

;;;###autoload
(defun complete-tag ()
  "Perform tags completion on the text around point.
Completes to the set of names listed in the current tags table.
The string to complete is chosen in the same way as the default
for \\[find-tag] (which see)."
  (interactive)
  (or tags-table-list
      tags-file-name
      (user-error "%s"
                  (substitute-command-keys
                   "No tags table loaded; try \\[visit-tags-table]")))
  (let ((comp-data (tags-completion-at-point-function))
        (completion-ignore-case (find-tag--completion-ignore-case)))
    (if (null comp-data)
	(user-error "Nothing to complete")
      (completion-in-region (car comp-data) (cadr comp-data)
			    (nth 2 comp-data)
			    (plist-get (nthcdr 3 comp-data) :predicate)))))


;;; Xref backend

;; Stop searching if we find more than xref-limit matches, as the xref
;; infrastructure is not designed to handle very long lists.
;; Switching to some kind of lazy list might be better, but hopefully
;; we hit the limit rarely.
(defconst etags--xref-limit 1000)

(defvar etags-xref-find-definitions-tag-order '(tag-exact-match-p
                                                tag-implicit-name-match-p)
  "Tag order used in `xref-backend-definitions' to look for definitions.

If you want `xref-find-definitions' to find the tagged files by their
file name, add `tag-partial-file-name-match-p' to the list value.")

(defcustom etags-xref-prefer-current-file nil
  "Non-nil means show the matches in the current file first."
  :type 'boolean
  :version "28.1")

;;;###autoload
(defun etags--xref-backend () 'etags)

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql 'etags)))
  (find-tag--default))

(cl-defmethod xref-backend-identifier-completion-table ((_backend
                                                         (eql 'etags)))
  (tags-lazy-completion-table))

(cl-defmethod xref-backend-identifier-completion-ignore-case ((_backend
                                                               (eql 'etags)))
  (find-tag--completion-ignore-case))

(cl-defmethod xref-backend-definitions ((_backend (eql 'etags)) symbol)
  (let ((file (and buffer-file-name (expand-file-name buffer-file-name)))
        (definitions (etags--xref-find-definitions symbol))
        same-file-definitions)
    (when (and etags-xref-prefer-current-file file)
      (setq definitions
            (cl-delete-if
             (lambda (definition)
               (when (equal file
                            (xref-location-group
                             (xref-item-location definition)))
                 (push definition same-file-definitions)
                 t))
             definitions))
      (setq definitions (nconc (nreverse same-file-definitions)
                               definitions)))
    definitions))

(cl-defmethod xref-backend-apropos ((_backend (eql 'etags)) pattern)
  (let ((regexp (xref-apropos-regexp pattern)))
    (nconc
     (etags--xref-find-definitions regexp t)
     (etags--xref-apropos-additional regexp))))

(defun etags--xref-find-definitions (pattern &optional regexp?)
  ;; This emulates the behavior of `find-tag-in-order' but instead of
  ;; returning one match at a time all matches are returned as list.
  ;; NOTE: find-tag-tag-order is typically a buffer-local variable.
  (let* ((xrefs '())
         (first-time t)
         (search-fun (if regexp? #'re-search-forward #'search-forward))
         (marks (make-hash-table :test 'equal))
         (case-fold-search (find-tag--completion-ignore-case))
         (cbuf (current-buffer)))
    (save-excursion
      (while (visit-tags-table-buffer (not first-time) cbuf)
        (setq first-time nil)
        (dolist (order-fun (cond (regexp? find-tag-regexp-tag-order)
                                 (t etags-xref-find-definitions-tag-order)))
          (goto-char (point-min))
          (while (and (funcall search-fun pattern nil t)
                      (< (hash-table-count marks) etags--xref-limit))
            (when (funcall order-fun pattern)
              (beginning-of-line)
              (pcase-let* ((tag-info (etags-snarf-tag))
                           (`(,hint ,line . _) tag-info))
                (let* ((file (etags--ensure-file (file-of-tag)))
                       (mark-key (cons file line)))
                  (unless (gethash mark-key marks)
                    (let ((loc (xref-make-etags-location
                                tag-info (expand-file-name file))))
                      (push (xref-make (if (eq hint t) "(filename match)" hint)
                                       loc)
                            xrefs)
                      (puthash mark-key t marks))))))))))
    (nreverse xrefs)))

(defun etags--xref-apropos-additional (regexp)
  (cl-mapcan
   (lambda (oba)
     (pcase-let* ((`(,group ,goto-fun ,symbs) oba)
                  (res nil)
                  (add-xref (lambda (sym)
                              (let ((sn (symbol-name sym)))
                                (when (string-match-p regexp sn)
                                  (push
                                   (xref-make
                                    sn
                                    (xref-make-etags-apropos-location
                                     sym goto-fun group))
                                   res))))))
       (when (symbolp symbs)
         (if (boundp symbs)
             (setq symbs (symbol-value symbs))
           (warn "Symbol `%s' has no value" symbs)
           (setq symbs nil))
         (if (obarrayp symbs)
             (mapatoms add-xref symbs)
           (dolist (sy symbs)
             (funcall add-xref (car sy))))
         (nreverse res))))
   tags-apropos-additional-actions))

(cl-defstruct (xref-etags-location
               (:constructor xref-make-etags-location (tag-info file)))
  "Location of an etags tag."
  tag-info file)

(cl-defmethod xref-location-group ((l xref-etags-location))
  (xref-etags-location-file l))

(cl-defmethod xref-location-marker ((l xref-etags-location))
  (pcase-let (((cl-struct xref-etags-location tag-info file) l))
    (let ((buffer (find-file-noselect file)))
      (with-current-buffer buffer
        (save-excursion
          (save-restriction
            (widen)
            (etags-goto-tag-location tag-info)
            (point-marker)))))))

(cl-defmethod xref-location-line ((l xref-etags-location))
  (pcase-let (((cl-struct xref-etags-location tag-info) l))
    (nth 1 tag-info)))

(cl-defstruct (xref-etags-apropos-location
               (:constructor xref-make-etags-apropos-location (symbol goto-fun group)))
  "Location of an additional apropos etags symbol."
  symbol goto-fun group)

(cl-defmethod xref-location-group ((l xref-etags-apropos-location))
  (xref-etags-apropos-location-group l))

(cl-defmethod xref-location-marker ((l xref-etags-apropos-location))
  (save-window-excursion
    (pcase-let (((cl-struct xref-etags-apropos-location goto-fun symbol) l))
      (funcall goto-fun symbol)
      (point-marker))))


(provide 'etags)

;;; etags.el ends here
