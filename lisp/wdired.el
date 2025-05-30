;;; wdired.el --- Rename files editing their names in dired buffers -*- coding: utf-8; lexical-binding: t; -*-

;; Copyright (C) 2004-2025 Free Software Foundation, Inc.

;; Author: Juan León Lahoz García <juanleon1@gmail.com>
;; Old-Version: 2.0
;; Keywords: dired, environment, files, renaming

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

;; wdired.el (the "w" is for writable) provides an alternative way of
;; renaming files.
;;
;; Have you ever wanted to use `C-x r t' (`string-rectangle'), `M-%'
;; (`query-replace'), `M-c' (`capitalize-word'), etc... to change the
;; name of the files in a Dired buffer?  Now you can do this.  All the
;; power of Emacs commands are available when renaming files!
;;
;; This package provides a function that makes the filenames of a
;; Dired buffer editable, by changing the buffer mode (which inhibits
;; all of the commands of Dired mode).  Here you can edit the names of
;; one or more files and directories, and when you press `C-c C-c',
;; the renaming takes effect and you are back to Dired mode.
;;
;; Other things you can do with WDired:
;;
;; - Move files to another directory (by typing their path,
;;   absolute or relative, as a part of the new filename).
;;
;; - Change the target of symbolic links.
;;
;; - Change the permission bits of the filenames (in systems with a
;;   working unix-alike "chmod").  See and customize the variable
;;   `wdired-allow-to-change-permissions'.  To change a single char
;;   (toggling between its two more usual values), you can press the
;;   space bar over it or left-click the mouse.  To set any char to a
;;   specific value (this includes the SUID, SGID and STI bits) you
;;   can use the key labeled as the letter you want.  Please note that
;;   permissions of the links cannot be changed in that way, because
;;   the change would affect to their targets, and this would not be
;;   WYSIWYG :-).
;;
;; - Mark files for deletion, by deleting their whole filename.

;; * Usage:

;; You can edit the names of the files by typing `C-x C-q' or
;; `M-x wdired-change-to-wdired-mode'.  Use `C-c C-c' when
;; finished or `C-c C-k' to abort.
;;
;; You can customize the behavior of this package from the "WDired"
;; menu or with `M-x customize-group RET wdired RET'.

;;; Code:

(require 'dired)
(eval-when-compile (require 'cl-lib))
(autoload 'dired-do-create-files-regexp "dired-aux")

(defgroup wdired nil
  "Mode to rename files by editing their names in Dired buffers."
  :group 'dired)

(defcustom wdired-use-interactive-rename nil
  "If non-nil, WDired requires confirmation before actually renaming files.
If nil, WDired doesn't require confirmation to change the file names,
and the variable `wdired-confirm-overwrite' controls whether it is ok
to overwrite files without asking."
  :type 'boolean)

(defcustom wdired-confirm-overwrite t
  "If nil the renames can overwrite files without asking.
This variable has no effect at all if `wdired-use-interactive-rename'
is not nil."
  :type 'boolean)

(defcustom wdired-use-dired-vertical-movement nil
  "If t, the \"up\" and \"down\" movement works as in Dired mode.
That is, always move the point to the beginning of the filename at line.

If `sometimes', only move to the beginning of filename if the point is
before it.  This behavior is very handy when editing several filenames.

If nil, \"up\" and \"down\" movement is done as in any other buffer."
  :type '(choice (const :tag "As in any other mode" nil)
		 (const :tag "Smart cursor placement" sometimes)
		 (other :tag "As in dired mode" t)))

(defcustom wdired-allow-to-redirect-links t
  "If non-nil, the target of the symbolic links are editable.
In systems without symbolic links support, this variable has no effect
at all."
  :type 'boolean)

(defcustom wdired-allow-to-change-permissions nil
  "If non-nil, the permissions bits of the files are editable.

If t, to change a single bit, put the cursor over it and press the
space bar, or left click over it.  You can also hit the letter you want
to set: if this value is allowed, the character in the buffer will be
changed.  Anyway, the point is advanced one position, so, for example,
you can keep the <x> key pressed to give execution permissions to
everybody to that file.

If `advanced', the bits are freely editable.  You can use
`string-rectangle', `query-replace', etc.  You can put any value (even
newlines), but if you want your changes to be useful, you better put a
intelligible value.

The real change of the permissions is done by the external
program \"chmod\", which must exist."
  :type '(choice (const :tag "Not allowed" nil)
                 (const :tag "Toggle/set bits" t)
		 (other :tag "Bits freely editable" advanced)))

(defcustom wdired-keep-marker-rename t
  ;; Use t as default so that renamed files "take their markers with them".
  "Controls marking of files renamed in WDired.
If t, files keep their previous marks when they are renamed.
If a character, renamed files (whether previously marked or not)
are afterward marked with that character.
This option affects only files renamed by `wdired-finish-edit'.
See `dired-keep-marker-rename' if you want to do the same for files
renamed by `dired-do-rename' and `dired-do-rename-regexp'."
  :type '(choice (const :tag "Keep" t)
		 (character :tag "Mark" :value ?R))
  :version "24.3")

(defcustom wdired-create-parent-directories t
  "If non-nil, create parent directories of destination files.
If non-nil, when you rename a file to a destination path within a
nonexistent directory, wdired will create any parent directories
necessary.  When nil, attempts to rename a file into a
nonexistent directory will fail."
  :version "26.1"
  :type 'boolean)

(defcustom wdired-search-replace-filenames t
  "Non-nil to search and replace in file names only."
  :version "29.1"
  :type 'boolean)

(defvar-keymap wdired-mode-map
  :doc "Keymap used in `wdired-mode'."
  "C-x C-s" #'wdired-finish-edit
  "C-c C-c" #'wdired-finish-edit
  "C-c C-k" #'wdired-abort-changes
  "C-c C-[" #'wdired-abort-changes
  "C-x C-q" #'wdired-exit
  "RET"     #'undefined
  "C-j"     #'undefined
  "C-o"     #'undefined
  "<up>"    #'wdired-previous-line
  "C-p"     #'wdired-previous-line
  "<down>"  #'wdired-next-line
  "C-n"     #'wdired-next-line
  "C-("     #'dired-hide-details-mode
  "<remap> <upcase-word>"         #'wdired-upcase-word
  "<remap> <capitalize-word>"     #'wdired-capitalize-word
  "<remap> <downcase-word>"       #'wdired-downcase-word
  "<remap> <self-insert-command>" #'wdired--self-insert)

(easy-menu-define wdired-mode-menu wdired-mode-map
  "Menu for `wdired-mode'."
  '("WDired"
    ["Commit Changes" wdired-finish-edit]
    ["Abort Changes" wdired-abort-changes
     :help "Abort changes and return to Dired mode"]
    "---"
    ["Options" wdired-customize]))

(defvar wdired-mode-hook nil
  "Hooks run when changing to WDired mode.")

;; Local variables (put here to avoid compilation gripes)
(defvar wdired--perm-beg) ;; Column where the permission bits start
(defvar wdired--perm-end) ;; Column where the permission bits stop
(defvar wdired--old-content)
(defvar wdired--old-point)
(defvar wdired--old-marks)

(defun wdired-mode ()
  "Writable Dired (WDired) mode.
\\<wdired-mode-map>
In WDired mode, you can edit the names of the files in the
buffer, the target of the links, and the permission bits of the
files.

Type \\[wdired-finish-edit] to exit WDired mode, returning to
Dired mode, and make your edits \"take effect\" by modifying the
file and directory names, link targets, and/or file permissions
on disk.  If you delete the filename of a file, it is flagged for
deletion in the Dired buffer.

Type \\[wdired-abort-changes] to abort your edits and exit WDired mode.

Type \\[customize-group] RET wdired to customize WDired behavior.

The only editable texts in a WDired buffer are filenames,
symbolic link targets, and filenames permission."
  (interactive)
  (error "This mode can be enabled only by `wdired-change-to-wdired-mode'"))
(put 'wdired-mode 'mode-class 'special)

(declare-function dired-isearch-search-filenames "dired-aux")

;;;###autoload
(defun wdired-change-to-wdired-mode ()
  "Put a Dired buffer in Writable Dired (WDired) mode.
\\<wdired-mode-map>
In WDired mode, you can edit the names of the files in the
buffer, the target of the links, and the permission bits of the
files.  After typing \\[wdired-finish-edit], Emacs modifies the files and
directories to reflect your edits.

See `wdired-mode'."
  (interactive)
  (unless (derived-mode-p 'dired-mode)
    (error "Not a Dired buffer"))
  (setq-local wdired--old-content
              (buffer-substring (point-min) (point-max)))
  (setq-local wdired--old-marks
              (dired-remember-marks (point-min) (point-max)))
  (setq-local wdired--old-point (point))
  (wdired--set-permission-bounds)
  (when wdired-search-replace-filenames
    (add-function :around (local 'isearch-search-fun-function)
                  #'dired-isearch-search-filenames
                  '((isearch-message-prefix . "filename ")))
    (setq-local replace-search-function
                (setq-local replace-re-search-function
                            (funcall isearch-search-fun-function)))
    ;; Original dired hook removes dired-isearch-search-filenames that
    ;; is needed outside isearch for lazy-highlighting in query-replace.
    (remove-hook 'isearch-mode-hook #'dired-isearch-filenames-setup t))
  (use-local-map wdired-mode-map)
  (force-mode-line-update)
  (setq buffer-read-only nil)
  (dired-unadvertise default-directory)
  (add-hook 'kill-buffer-hook #'wdired-check-kill-buffer nil t)
  (add-hook 'before-change-functions #'wdired--before-change-fn nil t)
  (add-hook 'after-change-functions #'wdired--restore-properties nil t)
  (setq major-mode 'wdired-mode)
  (setq mode-name "Editable Dired")
  (add-function :override (local 'revert-buffer-function) #'wdired-revert)
  (set-buffer-modified-p nil)
  (setq buffer-undo-list nil)
  ;; Non-nil `dired-filename-display-length' may cause filenames to be
  ;; hidden partly, so we remove filename invisibility spec
  ;; temporarily to ensure filenames are visible for editing.
  (dired-filename-update-invisibility-spec)
  (run-mode-hooks 'wdired-mode-hook)
  (message "%s" (substitute-command-keys
		 "Press \\[wdired-finish-edit] when finished \
or \\[wdired-abort-changes] to abort changes")))

(defun wdired--set-permission-bounds ()
  (save-excursion
    (goto-char (point-min))
    (if (not (re-search-forward dired-re-perms nil t 1))
        (progn
          (setq-local wdired--perm-beg nil)
          (setq-local wdired--perm-end nil))
      (goto-char (match-beginning 0))
      ;; Add 1 since the first char matched by `dired-re-perms' is the
      ;; one describing the nature of the entry (dir/symlink/...) rather
      ;; than its permissions.
      (setq-local wdired--perm-beg (1+ (wdired--current-column)))
      (goto-char (match-end 0))
      (setq-local wdired--perm-end (wdired--current-column)))))

(defun wdired--current-column ()
  (- (point) (line-beginning-position)))

(defun wdired--point-at-perms-p ()
  (and wdired--perm-beg
       (<= wdired--perm-beg (wdired--current-column) wdired--perm-end)))

(defun wdired--line-preprocessed-p ()
  (get-text-property (line-beginning-position) 'front-sticky))

(defun wdired--self-insert ()
  (interactive)
  (if (wdired--line-preprocessed-p)
      (call-interactively 'self-insert-command)
    (wdired--before-change-fn (point) (point))
    (let* ((map (get-text-property (point) 'keymap)))
      (call-interactively (or (if map (lookup-key map (this-command-keys)))
                              #'self-insert-command)))))

(put 'wdired--self-insert 'delete-selection 'delete-selection-uses-region-p)

(defun wdired--before-change-fn (beg end)
  (save-match-data
    (save-excursion
      (save-restriction
        (widen)
        ;; Make sure to process entire lines.
        (goto-char end)
        (setq end (line-end-position))
        (goto-char beg)
        (forward-line 0)

        (while (< (point) end)
          (unless (wdired--line-preprocessed-p)
            (with-silent-modifications
              (put-text-property (point) (1+ (point)) 'front-sticky t)
              (wdired--preprocess-files)
              (when wdired-allow-to-change-permissions
                (wdired--preprocess-perms))
              (when (fboundp 'make-symbolic-link)
                (wdired--preprocess-symlinks))))
          (forward-line))
        (when (eobp)
          (with-silent-modifications
            ;; Is this good enough? Assumes no extra white lines from dired.
            (put-text-property (1- (point-max)) (point-max) 'read-only t)))))))

;; Protect the buffer so only the filenames can be changed, and put
;; properties so filenames (old and new) can be easily found.
(defun wdired--preprocess-files ()
  (save-excursion
    (let ((used-F (dired-check-switches dired-actual-switches "F" "classify"))
	  (beg (point))
          (filename (dired-get-filename nil t)))
      (when (and filename
		 (not (member (file-name-nondirectory filename) '("." ".."))))
	(dired-move-to-filename)
	;; The rear-nonsticky property below shall ensure that text preceding
	;; the filename can't be modified.
	(add-text-properties
	 (1- (point)) (point) `(old-name ,filename rear-nonsticky (read-only)))
	(put-text-property beg (point) 'read-only t)
        (dired-move-to-end-of-filename t)
	(put-text-property (point) (1+ (point)) 'end-name t))
      (when (and used-F (looking-at "[*/@|=>]$")) (forward-char))
      (when (save-excursion
              (and (re-search-backward
                    dired-permission-flags-regexp nil t)
                   (looking-at "l")
                   (search-forward " -> " (line-end-position) t)))
        (goto-char (line-end-position))))))

;; This code is a copy of some dired-get-filename lines.
(defsubst wdired-normalize-filename (file unquotep)
  (when unquotep
    ;; Unquote names quoted by ls or by dired-insert-directory.
    ;; This code was written using `read' to unquote, because
    ;; it's faster than substituting \007 (4 chars) -> ^G (1
    ;; char) etc. in a lisp loop.  Unfortunately, this decision
    ;; has necessitated hacks such as dealing with filenames
    ;; with quotation marks in their names.
    (while (string-match "\\(?:[^\\]\\|\\`\\)\\(\"\\)" file)
      (setq file (replace-match "\\\"" nil t file 1)))
    ;; Unescape any spaces escaped by ls -b (bug#10469).
    ;; Other -b quotes, eg \t, \n, work transparently.
    (if (dired-switches-escape-p dired-actual-switches)
        (let ((start 0)
              (rep "")
              (shift -1))
          (while (string-match "\\(\\\\\\) " file start)
            (setq file (replace-match rep nil t file 1)
                  start (+ shift (match-end 0))))))
    (when (eq system-type 'windows-nt)
      (save-match-data
	(let ((start 0))
	  (while (string-match "\\\\" file start)
	    (aset file (match-beginning 0) ?/)
	    (setq start (match-end 0))))))

    ;; Hence we don't need to worry about converting `\\' back to `\'.
    (setq file (read (concat "\"" file "\""))))
  (and file buffer-file-coding-system
       (not file-name-coding-system)
       (not default-file-name-coding-system)
       (setq file (encode-coding-string file buffer-file-coding-system)))
  file)

(defun wdired-get-filename (&optional no-dir old)
  "Return the filename at line.
Similar to `dired-get-filename' but it doesn't rely on regexps.  It
relies on WDired buffer's properties.  Optional arg NO-DIR with value
non-nil means don't include directory.  Optional arg OLD with value
non-nil means return old filename."
  ;; FIXME: Use dired-get-filename's new properties.
  (let ((used-F (dired-check-switches dired-actual-switches "F" "classify"))
        beg end file)
    (wdired--before-change-fn (point) (point))
    (save-excursion
      (setq end (line-end-position))
      (beginning-of-line)
      (setq beg (next-single-property-change (point) 'old-name nil end))
      (unless (eq beg end)
	(if old
	    (setq file (get-text-property beg 'old-name))
	  ;; In the following form changed `(1+ beg)' to `beg' so that
	  ;; the filename end is found even when the filename is empty.
	  ;; Fixes error and spurious newlines when marking files for
	  ;; deletion.
	  (setq end (next-single-property-change beg 'end-name nil end))
          (when (save-excursion
                  (and (re-search-forward
                        dired-permission-flags-regexp nil t)
                       (goto-char (match-beginning 0))
                       (looking-at "l")
                       (if (and used-F
                                dired-ls-F-marks-symlinks)
                           (re-search-forward "@? -> " (line-end-position) t)
                         (search-forward " -> " (line-end-position) t))))
            (goto-char (match-beginning 0))
            (setq end (point)))
          (when (and used-F
                     (save-excursion
                       (goto-char end)
                       (looking-back "[*/@|=>]$" (1- (point)))))
              (setq end (1- end)))
	  (setq file (buffer-substring-no-properties (1+ beg) end)))
	;; Don't unquote the old name, it wasn't quoted in the first place
        (and file (setq file (wdired-normalize-filename file (not old)))))
      (if (or no-dir old)
	  (if no-dir (file-relative-name file) file)
	(and file (> (length file) 0)
             (concat (dired-current-directory) file))))))

(defun wdired-change-to-dired-mode ()
  "Change the mode back to Dired."
  (or (eq major-mode 'wdired-mode)
      (error "Not a Wdired buffer"))
  (let ((inhibit-read-only t))
    (remove-text-properties
     (point-min) (point-max)
     '(front-sticky nil rear-nonsticky nil read-only nil keymap nil)))
  (when wdired-search-replace-filenames
    (remove-function (local 'isearch-search-fun-function)
                     #'dired-isearch-search-filenames)
    (kill-local-variable 'replace-search-function)
    (kill-local-variable 'replace-re-search-function)
    ;; Restore dired hook
    (add-hook 'isearch-mode-hook #'dired-isearch-filenames-setup nil t))
  (use-local-map dired-mode-map)
  (force-mode-line-update)
  (setq buffer-read-only t)
  (setq major-mode 'dired-mode)
  (dired-sort-set-mode-line)
  (dired-advertise)
  (dired-hide-details-update-invisibility-spec)
  ;; Restore filename invisibility spec that is removed in
  ;; `wdired-change-to-wdired-mode'.
  (dired-filename-update-invisibility-spec)
  (remove-hook 'kill-buffer-hook #'wdired-check-kill-buffer t)
  (remove-hook 'before-change-functions #'wdired--before-change-fn t)
  (remove-hook 'after-change-functions #'wdired--restore-properties t)
  (remove-function (local 'revert-buffer-function) #'wdired-revert))

(defun wdired-abort-changes ()
  "Abort changes and return to `dired-mode'."
  (interactive)
  (remove-hook 'before-change-functions #'wdired--before-change-fn t)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert wdired--old-content)
    (goto-char wdired--old-point))
  (wdired-change-to-dired-mode)
  ;; Update markers in `dired-subdir-alist'
  (dired-build-subdir-alist)
  (set-buffer-modified-p nil)
  (setq buffer-undo-list nil)
  (message "Changes aborted"))

(defun wdired-finish-edit ()
  "Actually rename files based on your editing in the Dired buffer."
  (interactive)
  (let ((changes nil)
	(errors 0)
	files-deleted
	files-renamed
	some-file-names-unchanged
	file-old file-new tmp-value)
    (save-excursion
      (when (and wdired-allow-to-redirect-links
		 (fboundp 'make-symbolic-link))
	(setq tmp-value (wdired-do-symlink-changes))
	(setq errors (cdr tmp-value))
	(setq changes (car tmp-value)))
      (when (and wdired-allow-to-change-permissions
		 wdired--perm-beg) ; could have been changed
	(setq tmp-value (wdired-do-perm-changes))
	(setq errors (+ errors (cdr tmp-value)))
	(setq changes (or changes (car tmp-value))))
      (goto-char (point-max))
      (while (not (bobp))
	(setq file-old (and (wdired--line-preprocessed-p)
	                    (wdired-get-filename nil t)))
	(when file-old
	  (setq file-new (wdired-get-filename))
          (if (equal file-new file-old)
	      (setq some-file-names-unchanged t)
            (setq changes t)
            (if (not file-new)		;empty filename!
                (push file-old files-deleted)
	      (when wdired-keep-marker-rename
		(let ((mark (cond ((integerp wdired-keep-marker-rename)
				   wdired-keep-marker-rename)
				  (wdired-keep-marker-rename
				   (cdr (assoc file-old wdired--old-marks)))
				  (t nil))))
		  (when mark
		    (push (cons (substitute-in-file-name file-new) mark)
			  wdired--old-marks))))
              (push (cons file-old (substitute-in-file-name file-new))
                    files-renamed))))
	(forward-line -1)))
    (when files-renamed
      (pcase-let ((`(,errs . ,successful-renames)
                   (wdired-do-renames files-renamed)))
        (incf errors errs)
        ;; Some of the renames may fail -- in that case, don't mark an
        ;; already-existing file with the same name as renamed.
        (pcase-dolist (`(,file . _) wdired--old-marks)
          (unless (member file successful-renames)
            (setq wdired--old-marks
                  (assoc-delete-all file wdired--old-marks #'equal))))))
    ;; We have to be in wdired-mode when wdired-do-renames is executed
    ;; so that wdired--restore-properties runs, but we have to change
    ;; back to dired-mode before reverting the buffer to avoid using
    ;; wdired-revert, which changes back to wdired-mode.
    (wdired-change-to-dired-mode)
    (if changes
	(progn
	  (cond
           ((and (stringp dired-directory)
                 (not (file-directory-p dired-directory))
                 (null some-file-names-unchanged)
                 (= (length files-renamed) 1))
            ;; If we are displaying a single file (rather than the
	    ;; contents of a directory), change dired-directory if that
	    ;; file was renamed.
            (setq dired-directory (cdr (car files-renamed))))
           ((and (consp dired-directory)
                 (cdr dired-directory)
                 files-renamed)
            ;; Fix dired buffers created with
            ;; (dired '(foo f1 f2 f3)).
            (setq dired-directory
                  (cons (car dired-directory)
                        ;; Replace in `dired-directory' files that have
                        ;; been modified with their new name keeping
                        ;; the ones that are unmodified at the same place.
                        (cl-loop for f in (cdr dired-directory)
                                 collect
                                 (or (assoc-default f files-renamed)
                                     ;; F could be relative or
                                     ;; abbreviated, whereas
                                     ;; files-renamed always consists
                                     ;; of absolute file names.
                                     (let ((relative
                                            (not (file-name-absolute-p f)))
                                           (match
                                            (assoc-default (expand-file-name f)
                                                           files-renamed)))
                                       (cond
                                        ;; If it was relative, convert
                                        ;; the new name back to relative.
                                        ((and match relative)
                                         (file-relative-name match))
                                        (t match)))
                                     f))))))
	  ;; Re-sort the buffer.
	  (revert-buffer)
	  (let ((inhibit-read-only t))
	    (dired-mark-remembered wdired--old-marks)))
      (let ((inhibit-read-only t))
	(remove-text-properties (point-min) (point-max)
				'(old-name nil end-name nil old-link nil
					   end-link nil end-perm nil
					   old-perm nil perm-changed nil))
	(message "(No changes to be performed)")
        ;; Deleting file indicator characters or editing the symlink
        ;; arrow in WDired are noops, so redisplay them immediately on
        ;; returning to Dired.
        (revert-buffer)))
    (when files-deleted
      (wdired-flag-for-deletion files-deleted))
    (when (> errors 0)
      (dired-log-summary (format "%d actions failed" errors) nil)))
  (set-buffer-modified-p nil)
  (setq buffer-undo-list nil))

(defun wdired-do-renames (renames)
  "Perform RENAMES in parallel."
  (let* ((residue ())
         (progress nil)
         (errors 0)
         (total (1- (length renames)))
         (prep (make-progress-reporter "Renaming" 0 total))
         (overwrite (or (not wdired-confirm-overwrite) 1))
         (successful-renames nil))
    (while (or renames
               ;; We've done one round through the renames, we have found
               ;; some residue, but we also made some progress, so maybe
               ;; some of the residue were resolved: try again.
               (prog1 (setq renames residue)
                 (setq progress nil)
                 (setq residue nil)))
      (progress-reporter-update prep (- total (length renames)))
      (let* ((rename (pop renames))
             (file-new (cdr rename)))
        (cond
         ((rassoc file-new renames)
          (let ((msg
                 (format "Rename of '%s' to '%s' failed; target name collision"
                         (car rename) file-new)))
            (dired-log msg)
            (error msg)))
         ((assoc file-new renames)
          ;; Renaming to a file name that already exists but will itself be
          ;; renamed as well.  Let's wait until that one gets renamed.
          (push rename residue))
         ((and (assoc file-new residue)
               ;; Make sure the file really exists: if it doesn't it's
               ;; not really a conflict.  It might be a temp-file generated
               ;; specifically to break a circular renaming.
               (file-exists-p file-new))
          ;; Renaming to a file name that already exists, needed to be renamed,
          ;; but whose renaming could not be performed right away.
          (if (or progress renames)
              ;; There's still a chance the conflict will be resolved.
              (push rename residue)
            ;; We have not made any progress and we've reached the end of
            ;; the renames, so we really have a circular conflict, and we
            ;; have to forcefully break the cycle.
            (let ((tmp (make-temp-name file-new)))
              (let ((msg (format
                          "Rename of '%s' to '%s' conflict; using temp '%s'"
                          (car rename) file-new tmp)))
                (dired-log msg)
                (message msg))
              (push (cons (car rename) tmp) renames)
              (push (cons tmp file-new) residue))))
         (t
          (setq progress t)
          (let ((file-ori (car rename)))
            (if wdired-use-interactive-rename
                (wdired-search-and-rename file-ori file-new)
              ;; If dired-rename-file autoloads dired-aux while
              ;; dired-backup-overwrite is locally bound,
              ;; dired-backup-overwrite won't be initialized.
              ;; So we must ensure dired-aux is loaded.
              (require 'dired-aux)
              (condition-case err
                  (dlet ((dired-backup-overwrite nil))
                    (and wdired-create-parent-directories
                         (wdired-create-parentdirs file-new))
                    (dired-rename-file file-ori file-new
                                       overwrite))
                (:success
                 (push file-new successful-renames))
                (error
                 (setq errors (1+ errors))
                 (dired-log "Rename `%s' to `%s' failed:\n%s\n"
                            file-ori file-new
                            err)))))))))
    (progress-reporter-done prep)
    (cons errors successful-renames)))

(defun wdired-create-parentdirs (file-new)
  "Create parent directories for FILE-NEW if they don't exist."
  (and (not (file-exists-p (file-name-directory file-new)))
       (message "Creating directory for file %s" file-new)
       (make-directory (file-name-directory file-new) t)))

(defun wdired-exit ()
  "Exit wdired and return to Dired mode.
Just return to Dired mode if there are no changes.  Otherwise,
ask a yes-or-no question whether to save or cancel changes,
and proceed depending on the answer."
  (interactive)
  (if (buffer-modified-p)
      (if (y-or-n-p (format "Buffer %s modified; save changes? "
			    (current-buffer)))
	  (wdired-finish-edit)
	(wdired-abort-changes))
    (wdired-change-to-dired-mode)
    (set-buffer-modified-p nil)
    (setq buffer-undo-list nil)
    (message "(No changes need to be saved)")))

;; Rename a file, searching it in a modified dired buffer, in order
;; to be able to use `dired-do-create-files-regexp' and get its
;; "benefits".
(defun wdired-search-and-rename (filename-ori filename-new)
  (save-excursion
    (goto-char (point-max))
    (forward-line -1)
    (let ((done nil)
          (failed t)
	  curr-filename)
      (while (and (not done) (not (bobp)))
        (setq curr-filename (wdired-get-filename nil t))
        (if (equal curr-filename filename-ori)
            (unwind-protect
                (progn
                  (setq done t)
                  (let ((inhibit-read-only t))
                    (dired-move-to-filename)
                    (search-forward (wdired-get-filename t) nil t)
                    (replace-match (file-name-nondirectory filename-ori) t t))
                  (dired-do-create-files-regexp
                   (function dired-rename-file)
                   "Move" 1 ".*" filename-new nil t)
                  (setq failed nil))
              ;; If user types C-g when prompted to change the file
              ;; name, make sure we return to dired-mode.
              (when failed (wdired-change-to-dired-mode)))
	  (forward-line -1))))))

;; marks a list of files for deletion
(defun wdired-flag-for-deletion (filenames-ori)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (if (member (dired-get-filename nil t) filenames-ori)
          (dired-flag-file-deletion 1)
	(forward-line)))))

(defun wdired-customize ()
  "Customize WDired options."
  (interactive)
  (customize-apropos "wdired" 'groups))

(defun wdired-revert (&optional _arg _noconfirm)
  "Discard changes in the buffer and update it based on changes on disk.
Optional arguments are ignored."
  (wdired-change-to-dired-mode)
  (revert-buffer)
  (wdired-change-to-wdired-mode))

(defun wdired-check-kill-buffer ()
  ;; FIXME: Can't we use the normal mechanism for that?  --Stef
  (if (and
       (buffer-modified-p)
       (not (y-or-n-p "Buffer changed.  Discard changes and kill buffer?")))
      (error "Error")))

;; Added to after-change-functions in wdired-change-to-wdired-mode to
;; ensure that, on editing a file name, new characters get the
;; dired-filename text property, which allows functions that look for
;; this property (e.g. dired-isearch-filenames) to work in wdired-mode
;; and also avoids an error with non-nil wdired-use-interactive-rename
;; (bug#32173).  Also prevents editing the symlink arrow (which is a
;; noop) from corrupting the link name (see bug#18475 for elaboration).
(defun wdired--restore-properties (beg end _len)
  (save-match-data
    (save-excursion
      (save-restriction
        (widen)
        (let ((lep (line-end-position))
              (used-F (dired-check-switches
                       dired-actual-switches
                       "F" "classify")))
          ;; Deleting the space between the link name and the arrow (a
          ;; noop) also deletes the end-name property, so restore it.
          (when (and (save-excursion
                       (re-search-backward dired-permission-flags-regexp nil t)
                       (looking-at "l"))
                     (get-text-property (1- (point)) 'dired-filename)
                     (not (get-text-property (point) 'dired-filename))
                     (not (get-text-property (point) 'end-name)))
            (put-text-property (point) (1+ (point)) 'end-name t))
          (beginning-of-line)
          (when (re-search-forward
                 directory-listing-before-filename-regexp lep t)
            (setq beg (point)
                  end (if (or
                           ;; If the file is a symlink, put the
                           ;; dired-filename property only on the link
                           ;; name.  (Using (file-symlink-p
                           ;; (dired-get-filename)) fails in
                           ;; wdired-mode, bug#32673.)
                           (and (re-search-backward
                                 dired-permission-flags-regexp nil t)
                                (looking-at "l")
                                ;; macOS and Ultrix adds "@" to the end
                                ;; of symlinks when using -F.
                                (if (and used-F
                                         dired-ls-F-marks-symlinks)
                                    (re-search-forward "@? -> " lep t)
                                  (search-forward " -> " lep t)))
                           ;; When dired-listing-switches includes "F"
                           ;; or "classify", don't treat appended
                           ;; indicator characters as part of the file
                           ;; name (bug#34915).
                           (and used-F
                                (re-search-forward "[*/@|=>]$" lep t)))
                          (goto-char (match-beginning 0))
                        lep))
            (put-text-property beg end 'dired-filename t)))))))

(defun wdired-next-line (arg)
  "Move down lines then position at filename or the current column.
See `wdired-use-dired-vertical-movement'.  Optional prefix ARG
says how many lines to move; default is one line."
  (interactive "^p")
  (setq this-command 'next-line)       ;Let `line-move' preserve the column.
  (with-no-warnings (next-line arg))
  (if (or (eq wdired-use-dired-vertical-movement t)
	  (and wdired-use-dired-vertical-movement
	       (< (current-column)
		  (save-excursion (dired-move-to-filename)
				  (current-column)))))
      (dired-move-to-filename)))

(defun wdired-previous-line (arg)
  "Move up lines then position at filename or the current column.
See `wdired-use-dired-vertical-movement'.  Optional prefix ARG
says how many lines to move; default is one line."
  (interactive "^p")
  (setq this-command 'previous-line)       ;Let `line-move' preserve the column.
  (with-no-warnings (previous-line arg))
  (if (or (eq wdired-use-dired-vertical-movement t)
	  (and wdired-use-dired-vertical-movement
	       (< (current-column)
		  (save-excursion (dired-move-to-filename)
				  (current-column)))))
      (dired-move-to-filename)))

;; Put the needed properties to allow the user to change links' targets
(defun wdired--preprocess-symlinks ()
  (save-excursion
    (when (looking-at dired-re-sym)
      (re-search-forward " -> \\(.*\\)$")
      (put-text-property (1- (match-beginning 1))
			 (match-beginning 1) 'old-link
			 (match-string-no-properties 1))
      (put-text-property (match-end 1) (1+ (match-end 1)) 'end-link t)
      (unless wdired-allow-to-redirect-links
        (put-text-property (match-beginning 0)
			   (match-end 1) 'read-only t)))))

(defun wdired-get-previous-link (&optional old move)
  "Return the next symlink target.
If OLD, return the old target.  If MOVE, move point before it."
  (let (beg end target)
    (setq beg (previous-single-property-change (point) 'old-link nil))
    (when beg
      (when (save-excursion
              (goto-char beg)
              (and (looking-at " ")
                   (looking-back " ->" (line-beginning-position))))
        (setq beg (1+ beg)))
      (if old
          (setq target (get-text-property (1- beg) 'old-link))
        (setq end (save-excursion
                    (goto-char beg)
                    (next-single-property-change beg 'end-link nil
                                                 (line-end-position))))
        (setq target (buffer-substring-no-properties beg end)))
      (if move (goto-char (1- beg))))
    (and target (wdired-normalize-filename target t))))

(declare-function make-symbolic-link "fileio.c")

;; Perform the changes in the target of the changed links.
(defun wdired-do-symlink-changes ()
  (let ((changes nil)
	(errors 0)
	link-to-ori link-to-new link-from)
    (goto-char (point-max))
    (while (setq link-to-new (wdired-get-previous-link))
      (setq link-to-ori (wdired-get-previous-link t t))
      (setq link-from (wdired-get-filename nil t))
      (unless (equal link-to-new link-to-ori)
        (setq changes t)
        (if (equal link-to-new "") ;empty filename!
            (setq link-to-new (null-device)))
        (condition-case err
            (progn
              (delete-file link-from)
              (make-symbolic-link
               (substitute-in-file-name link-to-new) link-from))
          (error
           (setq errors (1+ errors))
           (dired-log "Link `%s' to `%s' failed:\n%s\n"
                      link-from link-to-new
                      err)))))
    (cons changes errors)))

;; Perform a "case command" skipping read-only words.
(defun wdired-xcase-word (command arg)
  (if (< arg 0)
      (funcall command arg)
    (while (> arg 0)
      (condition-case nil
          (progn
            (funcall command 1)
            (setq arg (1- arg)))
        (error
         (if (forward-word-strictly)
	     ;; Skip any non-word characters to avoid triggering a read-only
	     ;; error which would cause skipping the next word characters too.
	     (skip-syntax-forward "^w")
	   (setq arg 0)))))))

(defun wdired-downcase-word (arg)
  "WDired version of `downcase-word'.
Like original function but it skips read-only words."
  (interactive "p")
  (wdired-xcase-word 'downcase-word arg))

(defun wdired-upcase-word (arg)
  "WDired version of `upcase-word'.
Like original function but it skips read-only words."
  (interactive "p")
  (wdired-xcase-word 'upcase-word arg))

(defun wdired-capitalize-word (arg)
  "WDired version of `capitalize-word'.
Like original function but it skips read-only words."
  (interactive "p")
  (wdired-xcase-word 'capitalize-word arg))

;; The following code deals with changing the access bits (or
;; permissions) of the files.

(defvar-keymap wdired-perm-mode-map
  "SPC" #'wdired-toggle-bit
  "r"   #'wdired-set-bit
  "w"   #'wdired-set-bit
  "x"   #'wdired-set-bit
  "-"   #'wdired-set-bit
  "S"   #'wdired-set-bit
  "T"   #'wdired-set-bit
  "t"   #'wdired-set-bit
  "s"   #'wdired-set-bit
  "l"   #'wdired-set-bit
  "<mouse-1>" #'wdired-mouse-toggle-bit)

;; Put a keymap property to the permission bits of the files, and store the
;; original name and permissions as a property
(defun wdired--preprocess-perms ()
  (save-excursion
    (when (and (not (looking-at dired-re-sym))
	       (wdired-get-filename)
	       (re-search-forward dired-re-perms
                                  (line-end-position) 'eol))
      (let ((begin (match-beginning 0))
	    (end (match-end 0)))
	(if (eq wdired-allow-to-change-permissions 'advanced)
	    (progn
	      (put-text-property begin end 'read-only nil)
	      ;; make first permission bit writable
	      (put-text-property
	       (1- begin) begin 'rear-nonsticky '(read-only)))
	  ;; avoid that keymap applies to text following permissions
	  (add-text-properties
	   (1+ begin) end
	   `(keymap ,wdired-perm-mode-map rear-nonsticky (keymap))))
	(put-text-property end (1+ end) 'end-perm t)
	(put-text-property
	 begin (1+ begin)
         'old-perm (match-string-no-properties 0))))))

(defun wdired-perm-allowed-in-pos (char pos)
  (cond
   ((= char ?-)          t)
   ((= char ?r)          (= (% pos 3) 0))
   ((= char ?w)          (= (% pos 3) 1))
   ((= char ?x)          (= (% pos 3) 2))
   ((memq char '(?s ?S)) (memq pos '(2 5)))
   ((memq char '(?t ?T)) (= pos 8))
   ((= char ?l)          (= pos 5))))

(defun wdired-set-bit (&optional char)
  "Set a permission bit character."
  (interactive (list last-command-event))
  (unless char (setq char last-command-event))
  (if (wdired-perm-allowed-in-pos char
                                  (- (wdired--current-column) wdired--perm-beg))
      (let ((new-bit (char-to-string char))
            (inhibit-read-only t)
	    (pos-prop (+ (line-beginning-position) wdired--perm-beg)))
        (set-text-properties 0 1 (text-properties-at (point)) new-bit)
        (insert new-bit)
        (delete-char 1)
	(put-text-property (1- pos-prop) pos-prop 'perm-changed t))
    (forward-char 1)))

(defun wdired-toggle-bit ()
  "Toggle the permission bit at point."
  (interactive)
  (wdired-set-bit
   (cond
    ((not (eq (char-after (point)) ?-)) ?-)
    ((= (% (- (wdired--current-column) wdired--perm-beg) 3) 0) ?r)
    ((= (% (- (wdired--current-column) wdired--perm-beg) 3) 1) ?w)
    (t ?x))))

(defun wdired-mouse-toggle-bit (event)
  "Toggle the permission bit that was left clicked."
  (interactive "e")
  (mouse-set-point event)
  (wdired-toggle-bit))

;; Allowed chars for #o4000 bit are Ss  in position 3
;; Allowed chars for #o2000 bit are Ssl in position 6
;; Allowed chars for #o1000 bit are Tt  in position 9
(defun wdired-perms-to-number (perms)
  (let ((nperm #o0777))
    (if (= (elt perms 1) ?-) (setq nperm (- nperm #o400)))
    (if (= (elt perms 2) ?-) (setq nperm (- nperm #o200)))
    (let ((p-bit (elt perms 3)))
      (if (memq p-bit '(?- ?S)) (setq nperm (- nperm #o100)))
      (if (memq p-bit '(?s ?S)) (setq nperm (+ nperm #o4000))))
    (if (= (elt perms 4) ?-) (setq nperm (- nperm #o40)))
    (if (= (elt perms 5) ?-) (setq nperm (- nperm #o20)))
    (let ((p-bit (elt perms 6)))
      (if (memq p-bit '(?- ?S ?l)) (setq nperm (- nperm #o10)))
      (if (memq p-bit '(?s ?S ?l)) (setq nperm (+ nperm #o2000))))
    (if (= (elt perms 7) ?-) (setq nperm (- nperm 4)))
    (if (= (elt perms 8) ?-) (setq nperm (- nperm 2)))
    (let ((p-bit (elt perms 9)))
      (if (memq p-bit '(?- ?T)) (setq nperm (- nperm 1)))
      (if (memq p-bit '(?t ?T)) (setq nperm (+ nperm #o1000))))
    nperm))

;; Perform the changes in the permissions of the files that have
;; changed.
(defun wdired-do-perm-changes ()
  (let ((changes nil)
	(errors 0)
	(prop-wanted (if (eq wdired-allow-to-change-permissions 'advanced)
			 'old-perm 'perm-changed))
	filename perms-ori perms-new)
    (goto-char (next-single-property-change (point-min) prop-wanted
					    nil (point-max)))
    (while (not (eobp))
      (setq perms-ori (get-text-property (point) 'old-perm))
      (setq perms-new (buffer-substring-no-properties
		       (point) (next-single-property-change (point) 'end-perm)))
      (unless (equal perms-ori perms-new)
        (setq changes t)
        (setq filename (wdired-get-filename nil t))
        (if (= (length perms-new) 10)
            (condition-case nil
		(set-file-modes filename (wdired-perms-to-number perms-new)
				'nofollow)
              (error
               (setq errors (1+ errors))
               (dired-log "Setting mode of `%s' to `%s' failed\n\n"
                          filename perms-new)))
          (setq errors (1+ errors))
          (dired-log "Cannot parse permission `%s' for file `%s'\n\n"
                     perms-new filename)))
      (goto-char (next-single-property-change (1+ (point)) prop-wanted
					      nil (point-max))))
    (cons changes errors)))

(provide 'wdired)
;;; wdired.el ends here
