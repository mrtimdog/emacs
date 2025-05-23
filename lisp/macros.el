;;; macros.el --- non-primitive commands for keyboard macros -*- lexical-binding:t -*-

;; Copyright (C) 1985-1987, 1992, 1994-1995, 2001-2025 Free Software
;; Foundation, Inc.

;; Maintainer: emacs-devel@gnu.org
;; Keywords: abbrev
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

;; Extension commands for keyboard macros.  These permit you to assign
;; a name to the last-defined keyboard macro, expand and insert the
;; Lisp corresponding to a macro, query the user from within a macro,
;; or apply a macro to each line in the reason.

;;; Code:

(require 'kmacro)

;;;###autoload
(defalias 'name-last-kbd-macro #'kmacro-name-last-macro)

(defun macros--insert-vector-macro (definition)
  "Print DEFINITION, a vector, into the current buffer."
  (insert ?\[
          (mapconcat (lambda (event)
                       (or (prin1-char event)
                           (prin1-to-string event)))
                     definition
                     " ")
          ?\]))

;;;###autoload
(defun insert-kbd-macro (macroname &optional keys)
  "Insert in buffer the definition of kbd macro MACRONAME, as Lisp code.
MACRONAME should be a symbol; if none is given, the function inserts
the definition of `last-kdb-macro'.
Optional second arg KEYS means also record the keys it is on
\(this is the prefix argument, when calling interactively).

This Lisp code will, when executed, define the kbd macro with the same
definition it has now.  If you say to record the keys, the Lisp code
will also rebind those keys to the macro.  Only global key bindings
are recorded since executing this Lisp code always makes global
bindings.

To save a kbd macro, visit a file of Lisp code such as your `~/.emacs',
use this command, and then save the file."
  (interactive (list (intern (completing-read "Insert kbd macro (name): "
					      obarray
                                              #'kmacro-keyboard-macro-p
					      t))
		     current-prefix-arg))
  (if (string= (symbol-name macroname) "")
      (pp `(setq last-kbd-macro
                 (key-parse ,(key-description last-kbd-macro)))
          (current-buffer))
    (let ((definition (symbol-function macroname)))
      (when (or (stringp definition) (vectorp definition))
        (setq definition (kmacro (kmacro--to-vector definition))))
      ;; Prefer `defalias' over `fset' since it additionally keeps
      ;; track of the file where the users added it, and it interacts
      ;; better with `advice-add' (and hence things like ELP).
      (let ((counter (kmacro--counter definition))
            (format  (kmacro--format  definition)))
        (pp `(defalias ',macroname
               (kmacro ,(key-description (kmacro--keys definition))
                       ;; FIXME: Do we really want to store the counter?
                       . ,(unless (and (equal counter 0) (equal format "%d"))
                            `(,counter ,format))))
            (current-buffer)))
      (when keys
        (let ((keys (or (where-is-internal definition '(keymap))
                        (where-is-internal macroname '(keymap)))))
	  (dolist (key keys)
	    (pp `(keymap-global-set ,(key-description key) #',macroname)
	        (current-buffer))))))))

;;;###autoload
(defun kbd-macro-query (flag)
  "Query user during kbd macro execution.

With prefix argument FLAG, enter recursive edit, reading
keyboard commands even within a kbd macro.  You can give
different commands each time the macro executes.

Without prefix argument, ask whether to continue running the
macro.

Your options are: \\<query-replace-map>

\\[act]	Finish this iteration normally and continue with the next.
\\[skip]	Skip the rest of this iteration, and start the next.
\\[exit]	Stop the macro entirely right now.
\\[recenter]	Redisplay the screen, then ask again.
\\[edit]	Enter recursive edit; ask again when you exit from that."
  (interactive "P")
  (or executing-kbd-macro
      defining-kbd-macro
      (user-error "Not defining or executing kbd macro"))
  (if flag
      (let (executing-kbd-macro defining-kbd-macro)
	(recursive-edit))
    (if (not executing-kbd-macro)
	nil
      (let ((loop t)
	    (msg (substitute-command-keys
		  "Proceed with macro?\\<query-replace-map>\
 (\\[act], \\[skip], \\[exit], \\[recenter], \\[edit]) ")))
	(while loop
	  (let ((key (let ((executing-kbd-macro nil)
			   (defining-kbd-macro nil))
		       (message "%s" msg)
		       (read-event)))
		def)
	    (setq key (vector key))
	    (setq def (lookup-key query-replace-map key))
	    (cond ((eq def 'act)
		   (setq loop nil))
		  ((eq def 'skip)
		   (setq loop nil)
		   (setq executing-kbd-macro ""))
		  ((eq def 'exit)
		   (setq loop nil)
		   (setq executing-kbd-macro t))
		  ((eq def 'recenter)
		   (recenter nil))
		  ((eq def 'edit)
		   (let (executing-kbd-macro defining-kbd-macro)
		     (recursive-edit)))
		  ((eq def 'quit)
		   (setq quit-flag t))
		  (t
		   (or (eq def 'help)
		       (ding))
		   (with-output-to-temp-buffer "*Help*"
		     (princ
		      (substitute-command-keys
		       "Specify how to proceed with keyboard macro execution.
Possibilities: \\<query-replace-map>
\\[act]	Finish this iteration normally and continue with the next.
\\[skip]	Skip the rest of this iteration, and start the next.
\\[exit]	Stop the macro entirely right now.
\\[recenter]	Redisplay the screen, then ask again.
\\[edit]	Enter recursive edit; ask again when you exit from that."))
		     (with-current-buffer standard-output
		       (help-mode)))))))))))

;;;###autoload
(defun apply-macro-to-region-lines (top bottom &optional macro)
  "Apply last keyboard macro to all lines in the region.
For each line that begins in the region, move to the beginning of
the line, and run the last keyboard macro.

When called from lisp, this function takes two arguments TOP and
BOTTOM, describing the current region.  TOP must be before BOTTOM.
The optional third argument MACRO specifies a keyboard macro to
execute.

This is useful for quoting or unquoting included text, adding and
removing comments, or producing tables where the entries are regular.

For example, in Usenet articles, sections of text quoted from another
author are indented, or have each line start with `>'.  To quote a
section of text, define a keyboard macro which inserts `>', put point
and mark at opposite ends of the quoted section, and use
\\[apply-macro-to-region-lines] to mark the entire section.

Suppose you wanted to build a keyword table in C where each entry
looked like this:

    { \"foo\", foo_data, foo_function },
    { \"bar\", bar_data, bar_function },
    { \"baz\", baz_data, baz_function },

You could enter the names in this format:

    foo
    bar
    baz

and write a macro to massage a word into a table entry:

    \\C-x (
       \\M-d { \"\\C-y\", \\C-y_data, \\C-y_function },
    \\C-x )

and then select the region of un-tablified names and use
\\[apply-macro-to-region-lines] to build the table from the names."
  (interactive "r")
  (or macro
      (progn
	(if (null last-kbd-macro)
	    (user-error "No keyboard macro has been defined"))
	(setq macro last-kbd-macro)))
  (save-excursion
    (let ((end-marker (copy-marker bottom))
	  next-line-marker)
      (goto-char top)
      (if (not (bolp))
	  (forward-line 1))
      (setq next-line-marker (point-marker))
      (while (< next-line-marker end-marker)
	(goto-char next-line-marker)
	(save-excursion
	  (forward-line 1)
	  (set-marker next-line-marker (point)))
	(save-excursion
	  (let ((mark-active nil))
	    (execute-kbd-macro macro))))
      (set-marker end-marker nil)
      (set-marker next-line-marker nil))))

;;;###autoload (define-key ctl-x-map "q" 'kbd-macro-query)

(provide 'macros)

;;; macros.el ends here
