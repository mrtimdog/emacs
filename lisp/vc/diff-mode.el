;;; diff-mode.el --- a mode for viewing/editing context diffs -*- lexical-binding: t -*-

;; Copyright (C) 1998-2025 Free Software Foundation, Inc.

;; Author: Stefan Monnier <monnier@iro.umontreal.ca>
;; Keywords: convenience patch diff vc

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

;; Provides support for font-lock, outline, navigation
;; commands, editing and various conversions as well as jumping
;; to the corresponding source file.

;; Inspired by Pavel Machek's patch-mode.el (<pavel@@atrey.karlin.mff.cuni.cz>)
;; Some efforts were spent to have it somewhat compatible with
;; `compilation-minor-mode'.

;; Bugs:

;; - Reverse doesn't work with normal diffs.

;; Todo:

;; - Improve `diff-add-change-log-entries-other-window',
;;   it is very simplistic now.
;;
;; - Add a `delete-after-apply' so C-c C-a automatically deletes hunks.
;;   Also allow C-c C-a to delete already-applied hunks.
;;
;; - Try `diff <file> <hunk>' to try and fuzzily discover the source location
;;   of a hunk.  Show then the changes between <file> and <hunk> and make it
;;   possible to apply them to <file>, <hunk-src>, or <hunk-dst>.
;;   Or maybe just make it into a ".rej to diff3-markers converter".
;;   Maybe just use `wiggle' (by Neil Brown) to do it for us.
;;
;; - in diff-apply-hunk, strip context in replace-match to better
;;   preserve markers and spacing.
;; - Handle `diff -b' output in context->unified.

;;; Code:
(require 'easy-mmode)
(require 'track-changes)
(eval-when-compile (require 'cl-lib))
(eval-when-compile (require 'subr-x))

(autoload 'vc-find-revision "vc")
(autoload 'vc-find-revision-no-save "vc")
(defvar vc-find-revision-no-save)
(defvar add-log-buffer-file-name-function)


(defgroup diff-mode ()
  "Major mode for viewing/editing diffs."
  :version "21.1"
  :group 'tools
  :group 'diff)

(defcustom diff-default-read-only nil
  "If non-nil, `diff-mode' buffers default to being read-only."
  :type 'boolean)

(defcustom diff-jump-to-old-file nil
  "Non-nil means `diff-goto-source' jumps to the old file.
Else, it jumps to the new file."
  :type 'boolean)

(defcustom diff-update-on-the-fly t
  "Non-nil means hunk headers are kept up-to-date on-the-fly.
When editing a diff file, the line numbers in the hunk headers
need to be kept consistent with the actual diff.  This can
either be done on the fly (but this sometimes interacts poorly with the
undo mechanism) or whenever the file is written (can be slow
when editing big diffs).

If this variable is nil, the hunk header numbers are updated when
the file is written instead."
  :type 'boolean)

(defcustom diff-advance-after-apply-hunk t
  "Non-nil means `diff-apply-hunk' will move to the next hunk after applying."
  :type 'boolean)

(defcustom diff-mode-hook nil
  "Run after setting up the `diff-mode' major mode."
  :type 'hook
  :options '(diff-delete-empty-files diff-make-unified))

(defcustom diff-refine 'font-lock
  "If non-nil, enable hunk refinement.

The value `font-lock' means to refine during font-lock.
The value `navigation' means to refine each hunk as you visit it
with `diff-hunk-next' or `diff-hunk-prev'.

You can always manually refine a hunk with `diff-refine-hunk'."
  :version "27.1"
  :type '(choice (const :tag "Don't refine hunks" nil)
                 (const :tag "Refine hunks during font-lock" font-lock)
                 (const :tag "Refine hunks during navigation" navigation)))

(defcustom diff-font-lock-prettify nil
  "If non-nil, font-lock will try and make the format prettier.

This mimics the Magit's diff format by making the hunk header
less cryptic, and on GUI frames also displays insertion and
deletion indicators on the left fringe (if it's available)."
  :version "27.1"
  :type 'boolean)

(defcustom diff-font-lock-syntax t
  "If non-nil, diff hunk font-lock includes source language syntax highlighting.
This highlighting is the same as added by `font-lock-mode'
when corresponding source files are visited normally.
Syntax highlighting is added over diff-mode's own highlighted changes.

If t, the default, highlight syntax only in Diff buffers created by Diff
commands that compare files or by VC commands that compare revisions.
These provide all necessary context for reliable highlighting.  This value
requires support from a VC backend to find the files being compared.
For diffs against the working-tree version of a file, the highlighting is
based on the current file contents.  File-based fontification tries to
infer fontification from the compared files.

If `hunk-only' fontification is based on hunk alone, without full source.
It tries to highlight hunks without enough context that sometimes might result
in wrong fontification.  This is the fastest option, but less reliable.

If `hunk-also', use reliable file-based syntax highlighting when available
and hunk-based syntax highlighting otherwise as a fallback."
  :version "27.1"
  :type '(choice (const :tag "Don't highlight syntax" nil)
                 (const :tag "Hunk-based only" hunk-only)
                 (const :tag "Highlight syntax" t)
                 (const :tag "Allow hunk-based fallback" hunk-also)))

(defcustom diff-whitespace-style '(face trailing)
  "Specify `whitespace-style' variable for `diff-mode' buffers."
  :require 'whitespace
  :type (get 'whitespace-style 'custom-type)
  :version "29.1")

(defcustom diff-ignore-whitespace-switches "-b"
  "Switch or list of diff switches to use when ignoring whitespace.
The default \"-b\" means to ignore whitespace-only changes,
\"-w\" means ignore all whitespace changes."
  :type '(choice
          (string :tag "Ignore whitespace-only changes" :value "-b")
          (string :tag "Ignore all whitespace changes" :value "-w")
          (string :tag "Single switch")
          (repeat :tag "Multiple switches" (string :tag "Switch")))
  :version "30.1")

(defvar diff-vc-backend nil
  "The VC backend that created the current Diff buffer, if any.")

(defvar diff-vc-revisions nil
  "The VC revisions compared in the current Diff buffer, if any.")

(defvar-local diff-default-directory nil
  "The default directory where the current Diff buffer was created.")


;;;;
;;;; keymap, menu, ...
;;;;

;; The additional bindings in read-only `diff-mode' buffers are not
;; activated by turning on `diff-minor-mode' in those buffers.  Instead,
;; a special entry in `minor-mode-map-alist' is used to achieve that.
;; I.e., `diff-mode-read-only' is a pseudo-minor mode for read-only
;; `diff-mode' buffers, while `diff-minor-mode' is a bona fide minor
;; mode for non-`diff-mode' buffers.  (It's not clear there are
;; practical uses for `diff-minor-mode': bug#34080).

(defvar-keymap diff-mode-shared-map
  :doc "Additional bindings for read-only `diff-mode' buffers.
These bindings are also available with an ESC prefix
(i.e. a \\=`M-' prefix) in read-write `diff-mode' buffers,
and with a `diff-minor-mode-prefix' prefix in `diff-minor-mode'."
  "n" #'diff-hunk-next
  "N" #'diff-file-next
  "p" #'diff-hunk-prev
  "P" #'diff-file-prev
  "TAB" #'diff-hunk-next
  "<backtab>" #'diff-hunk-prev
  "k" #'diff-hunk-kill
  "K" #'diff-file-kill
  "}" #'diff-file-next                  ; From compilation-minor-mode.
  "{" #'diff-file-prev
  "RET" #'diff-goto-source
  "<mouse-2>" #'diff-goto-source
  "W" #'widen
  "w" #'diff-kill-ring-save
  "o" #'diff-goto-source                ; other-window
  "A" #'diff-ediff-patch
  "r" #'diff-restrict-view
  "R" #'diff-reverse-direction
  "<remap> <undo>" #'diff-undo)

(defvar-keymap diff-mode-map
  :doc "Keymap for `diff-mode'.  See also `diff-mode-shared-map'."
  "ESC" (let ((map (define-keymap :parent diff-mode-shared-map)))
          ;; We want to inherit most bindings from
          ;; `diff-mode-shared-map', but not all since they may hide
          ;; useful `M-<foo>' global bindings when editing.
          (dolist (key '("A" "r" "R" "W" "w"))
            (keymap-set map key nil))
          map)
  ;; From compilation-minor-mode.
  "C-c C-c" #'diff-goto-source
  ;; By analogy with the global C-x 4 a binding.
  "C-x 4 A" #'diff-add-change-log-entries-other-window
  ;; Misc operations.
  "C-c C-a" #'diff-apply-hunk
  "C-c M-r" #'diff-revert-and-kill-hunk
  "C-c C-m a" #'diff-apply-buffer
  "C-c C-m n" #'diff-delete-other-hunks
  "C-c C-e" #'diff-ediff-patch
  "C-c C-n" #'diff-restrict-view
  "C-c C-s" #'diff-split-hunk
  "C-c C-t" #'diff-test-hunk
  "C-c C-r" #'diff-reverse-direction
  "C-c C-u" #'diff-context->unified
  ;; `d' because it duplicates the context :-(  --Stef
  "C-c C-d" #'diff-unified->context
  "C-c C-w" #'diff-ignore-whitespace-hunk
  ;; `l' because it "refreshes" the hunk like C-l refreshes the screen
  "C-c C-l" #'diff-refresh-hunk
  "C-c C-b" #'diff-refine-hunk        ;No reason for `b' :-(
  "C-c C-f" #'next-error-follow-minor-mode)

(easy-menu-define diff-mode-menu diff-mode-map
  "Menu for `diff-mode'."
  '("Diff"
    ["Jump to Source"		diff-goto-source
     :help "Jump to the corresponding source line"]
    ["Apply hunk"		diff-apply-hunk
     :help "Apply the current hunk to the source file and go to the next"]
    ["Test applying hunk"	diff-test-hunk
     :help "See whether it's possible to apply the current hunk"]
    ["Revert and kill hunk"     diff-revert-and-kill-hunk
     :help "Reverse-apply and then kill the current hunk."]
    ["Apply all hunks"		diff-apply-buffer
     :help "Apply all hunks in the current diff buffer"]
    ["Apply diff with Ediff"	diff-ediff-patch
     :help "Call `ediff-patch-file' on the current buffer"]
    ["Create Change Log entries" diff-add-change-log-entries-other-window
     :help "Create ChangeLog entries for the changes in the diff buffer"]
    "-----"
    ["Reverse direction"	diff-reverse-direction
     :help "Reverse the direction of the diffs"]
    ["Context -> Unified"	diff-context->unified
     :help "Convert context diffs to unified diffs"]
    ["Unified -> Context"	diff-unified->context
     :help "Convert unified diffs to context diffs"]
    ;;["Fixup Headers"		diff-fixup-modifs	(not buffer-read-only)]
    ["Remove trailing whitespace" diff-delete-trailing-whitespace
     :help "Remove trailing whitespace problems introduced by the diff"]
    ["Show trailing whitespace" whitespace-mode
     :style toggle :selected (bound-and-true-p whitespace-mode)
     :help "Show trailing whitespace in modified lines"]
    "-----"
    ["Split hunk"		diff-split-hunk
     :active (diff-splittable-p)
     :help "Split the current (unified diff) hunk at point into two hunks"]
    ["Ignore whitespace changes" diff-ignore-whitespace-hunk
     :help "Re-diff the current hunk, ignoring whitespace differences"]
    ["Recompute the hunk" diff-refresh-hunk
     :help "Re-diff the current hunk, keeping the whitespace differences"]
    ["Highlight fine changes"	diff-refine-hunk
     :help "Highlight changes of hunk at point at a finer granularity"]
    ["Kill current hunk"	diff-hunk-kill
     :help "Kill current hunk"]
    ["Kill current file's hunks" diff-file-kill
     :help "Kill all current file's hunks"]
    ["Delete other hunks"       diff-delete-other-hunks
     :help "Delete hunks other than the current hunk"]
    "-----"
    ["Previous Hunk"		diff-hunk-prev
     :help "Go to the previous count'th hunk"]
    ["Next Hunk"		diff-hunk-next
     :help "Go to the next count'th hunk"]
    ["Previous File"		diff-file-prev
     :help "Go to the previous count'th file"]
    ["Next File"		diff-file-next
     :help "Go to the next count'th file"]
    ))

(defcustom diff-minor-mode-prefix "\C-c="
  "Prefix key for `diff-minor-mode' commands."
  :type '(choice (string "\e") (string "\C-c=") string))

(defvar-keymap diff-minor-mode-map
  :doc "Keymap for `diff-minor-mode'.  See also `diff-mode-shared-map'."
  (key-description diff-minor-mode-prefix) diff-mode-shared-map)

(with-suppressed-warnings ((obsolete diff-auto-refine-mode))
  (define-minor-mode diff-auto-refine-mode
    "Toggle automatic diff hunk finer highlighting (Diff Auto Refine mode).

Diff Auto Refine mode is a buffer-local minor mode used with
`diff-mode'.  When enabled, Emacs automatically highlights
changes in detail as the user visits hunks.  When transitioning
from disabled to enabled, it tries to refine the current hunk, as
well."
    :group 'diff-mode :init-value nil :lighter nil ;; " Auto-Refine"
    (if diff-auto-refine-mode
        (progn
          (customize-set-variable 'diff-refine 'navigation)
          (condition-case-unless-debug nil (diff-refine-hunk) (error nil)))
      (customize-set-variable 'diff-refine nil))))
(make-obsolete 'diff-auto-refine-mode "set `diff-refine' instead." "27.1")
(make-obsolete-variable 'diff-auto-refine-mode
                        "set `diff-refine' instead." "27.1")

;;;;
;;;; font-lock support
;;;;

;; Note: The colors used in a color-rich environments (a GUI or in a
;; terminal supporting 24 bit colors) doesn't render well in terminal
;; supporting only 256 colors.  Concretely, both #ffeeee
;; (diff-removed) and #eeffee (diff-added) are mapped to the same
;; grayish color.  "min-colors 257" ensures that those colors are not
;; used terminals supporting only 256 colors.  However, any number
;; between 257 and 2^24 (16777216) would do.

(defface diff-header
  '((((class color) (min-colors 88) (background light))
     :background "grey85" :extend t)
    (((class color) (min-colors 88) (background dark))
     :background "grey45" :extend t)
    (((class color))
     :foreground "blue1" :weight bold :extend t)
    (t :weight bold :extend t))
  "`diff-mode' face inherited by hunk and index header faces.")

(defface diff-file-header
  '((((class color) (min-colors 88) (background light))
     :background "grey75" :weight bold :extend t)
    (((class color) (min-colors 88) (background dark))
     :background "grey60" :weight bold :extend t)
    (((class color))
     :foreground "cyan" :weight bold :extend t)
    (t :weight bold :extend t))			; :height 1.3
  "`diff-mode' face used to highlight file header lines.")

(defface diff-index
  '((t :inherit diff-file-header))
  "`diff-mode' face used to highlight index header lines.")

(defface diff-hunk-header
  '((t :inherit diff-header))
  "`diff-mode' face used to highlight hunk header lines.")

(defface diff-removed
  '((default
     :inherit diff-changed)
    (((class color) (min-colors 257) (background light))
     :background "#ffeeee" :extend t)
    (((class color) (min-colors 88) (background light))
     :background "#ffdddd" :extend t)
    (((class color) (min-colors 88) (background dark))
     :background "#553333" :extend t)
    (((class color))
     :foreground "red" :extend t))
  "`diff-mode' face used to highlight removed lines.")

(defface diff-added
  '((default
     :inherit diff-changed)
    (((class color) (min-colors 257) (background light))
     :background "#eeffee" :extend t)
    (((class color) (min-colors 88) (background light))
     :background "#ddffdd" :extend t)
    (((class color) (min-colors 88) (background dark))
     :background "#335533" :extend t)
    (((class color))
     :foreground "green" :extend t))
  "`diff-mode' face used to highlight added lines.")

(defface diff-changed-unspecified
  '((default
     :inherit diff-changed)
    (((class color) (min-colors 88) (background light))
     :background "grey90" :extend t)
    (((class color) (min-colors 88) (background dark))
     :background "grey20" :extend t)
    (((class color))
     :foreground "grey" :extend t))
  "`diff-mode' face used to highlight changed lines."
  :version "28.1")

(defface diff-changed
  '((t nil))
  "`diff-mode' face used to highlight changed lines."
  :version "25.1")

(defface diff-indicator-removed
  '((default :inherit diff-removed)
    (((class color) (min-colors 88))
     :foreground "#aa2222"))
  "`diff-mode' face used to highlight indicator of removed lines (-, <)."
  :version "22.1")
(defvar diff-indicator-removed-face 'diff-indicator-removed)

(defface diff-indicator-added
  '((default :inherit diff-added)
    (((class color) (min-colors 88))
     :foreground "#22aa22"))
  "`diff-mode' face used to highlight indicator of added lines (+, >)."
  :version "22.1")
(defvar diff-indicator-added-face 'diff-indicator-added)

(defface diff-indicator-changed
  '((default :inherit diff-changed)
    (((class color) (min-colors 88))
     :foreground "#aaaa22"))
  "`diff-mode' face used to highlight indicator of changed lines."
  :version "22.1")
(defvar diff-indicator-changed-face 'diff-indicator-changed)

(defface diff-function
  '((t :inherit diff-header))
  "`diff-mode' face used to highlight function names produced by \"diff -p\".")

(defface diff-context
  '((t :extend t))
  "`diff-mode' face used to highlight context and other side-information."
  :version "27.1")

(defface diff-nonexistent
  '((t :inherit diff-file-header))
  "`diff-mode' face used to highlight nonexistent files in recursive diffs.")

(defface diff-error
  '((((class color))
     :foreground "red" :background "black" :weight bold)
    (t :weight bold))
  "`diff-mode' face for error messages from diff."
  :version "28.1")

(defconst diff-yank-handler '(diff-yank-function))
(defun diff-yank-function (text)
  ;; FIXME: the yank-handler is now called separately on each piece of text
  ;; with a yank-handler property, so the next-single-property-change call
  ;; below will always return nil :-(   --stef
  (let ((mixed (next-single-property-change 0 'yank-handler text))
	(start (point)))
    ;; First insert the text.
    (insert text)
    ;; If the text does not include any diff markers and if we're not
    ;; yanking back into a diff-mode buffer, get rid of the prefixes.
    (unless (or mixed (derived-mode-p 'diff-mode))
      (undo-boundary)		; Just in case the user wanted the prefixes.
      (let ((re (save-excursion
		  (if (re-search-backward "^[><!][ \t]" start t)
		      (if (eq (char-after) ?!)
			  "^[!+- ][ \t]" "^[<>][ \t]")
		    "^[ <>!+-]"))))
	(save-excursion
	  (while (re-search-backward re start t)
	    (replace-match "" t t)))))))

(defconst diff-hunk-header-re-unified
  "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@")
(defconst diff-context-mid-hunk-header-re
  "--- \\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? ----$")

(defvar diff-use-changed-face (and (face-differs-from-default-p 'diff-changed)
				   (not (face-equal 'diff-changed 'diff-added))
				   (not (face-equal 'diff-changed 'diff-removed)))
  "Controls how changed lines are fontified in context diffs.
If non-nil, use the face `diff-changed-unspecified'.  Otherwise,
use the face `diff-removed' for removed lines, and the face
`diff-added' for added lines.")

(defvar diff-buffer-type nil)

(defvar diff--indicator-added-re
  (rx bol
      (group (any "+>"))
      (group (zero-or-more nonl) "\n")))

(defvar diff--indicator-removed-re
  (rx bol
      (group (any "<-"))
      (group (zero-or-more nonl) "\n")))

(defun diff--git-preamble-end ()
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "^diff --git .+ .+$" nil t)
    (forward-line 2)
    (point)))

(defun diff--git-footer-start ()
  (save-excursion
    (goto-char (point-max))
    (re-search-backward "^-- $" nil t)
    (point)))

(defun diff--indicator-matcher-helper (limit regexp)
  "Fontify added/removed lines from point to LIMIT using REGEXP.

If this is a Git patch, don't fontify lines before the first hunk, or in
the email signature at the end."
  (catch 'return
    (when (eq diff-buffer-type 'git)
      (let ((preamble-end (diff--git-preamble-end))
            (footer-start (diff--git-footer-start))
            (beg (point))
            (end limit))
        (cond ((or (<= end preamble-end)
                   (>= beg footer-start))
               (throw 'return nil))
              ;; end is after preamble, adjust beg:
              ((< beg preamble-end)
               (goto-char preamble-end))
              ;; beg is before footer, adjust end:
              ((> end footer-start)
               (setq limit footer-start)))))
    (re-search-forward regexp limit t)))

(defun diff--indicator-added-matcher (limit)
  (diff--indicator-matcher-helper limit diff--indicator-added-re))

(defun diff--indicator-removed-matcher (limit)
  (diff--indicator-matcher-helper limit diff--indicator-removed-re))

(defvar diff-font-lock-keywords
  `((,(concat "\\(" diff-hunk-header-re-unified "\\)\\(.*\\)$")
     (1 'diff-hunk-header) (6 'diff-function))
    ("^\\(\\*\\{15\\}\\)\\(.*\\)$"                        ;context
     (1 'diff-hunk-header) (2 'diff-function))
    ("^\\*\\*\\* .+ \\*\\*\\*\\*". 'diff-hunk-header) ;context
    (,diff-context-mid-hunk-header-re . 'diff-hunk-header) ;context
    ("^[0-9,]+[acd][0-9,]+$"     . 'diff-hunk-header) ;normal
    ("^---$"                     . 'diff-hunk-header) ;normal
    ;; For file headers, accept files with spaces, but be careful to rule
    ;; out false-positives when matching hunk headers.
    ("^\\(---\\|\\+\\+\\+\\|\\*\\*\\*\\) \\([^\t\n]+?\\)\\(?:\t.*\\| \\(\\*\\*\\*\\*\\|----\\)\\)?\n"
     (0 'diff-header)
     (2 (if (not (match-end 3)) 'diff-file-header) prepend))
    (diff--indicator-removed-matcher
     (1 diff-indicator-removed-face) (2 'diff-removed))
    (diff--indicator-added-matcher
     (1 diff-indicator-added-face) (2 'diff-added))
    ("^\\(!\\)\\(.*\n\\)"
     (1 (if diff-use-changed-face
	    diff-indicator-changed-face
	  ;; Otherwise, search for `diff-context-mid-hunk-header-re' and
	  ;; if the line of context diff is above, use `diff-removed';
	  ;; if below, use `diff-added'.
	  (save-match-data
	    (let ((limit (save-excursion (diff-beginning-of-hunk))))
              (when (< limit (point))
                (if (save-excursion (re-search-backward diff-context-mid-hunk-header-re limit t))
		    diff-indicator-added-face
		  diff-indicator-removed-face))))))
     (2 (if diff-use-changed-face
	    'diff-changed-unspecified
	  ;; Otherwise, use the same method as above.
	  (save-match-data
	    (let ((limit (save-excursion (diff-beginning-of-hunk))))
	      (when (< limit (point))
                (if (save-excursion (re-search-backward diff-context-mid-hunk-header-re limit t))
		    'diff-added
		  'diff-removed)))))))
    ("^\\(?:Index\\|revno\\): \\(.+\\).*\n"
     (0 'diff-header) (1 'diff-index prepend))
    ("^\\(?:index .*\\.\\.\\|diff \\).*\n" . 'diff-header)
    ("^\\(?:new\\|deleted\\) file mode .*\n" . 'diff-header)
    ("^Only in .*\n" . 'diff-nonexistent)
    ("^Binary files .* differ\n" . 'diff-file-header)
    ("^\\(#\\)\\(.*\\)"
     (1 'font-lock-comment-delimiter-face)
     (2 'font-lock-comment-face))
    ("^diff: .*" (0 'diff-error))
    ("^[^-=+*!<>#].*\n" (0 'diff-context))
    (,#'diff--font-lock-syntax)
    (,#'diff--font-lock-prettify)
    (,#'diff--font-lock-refined)))

(defconst diff-font-lock-defaults
  '(diff-font-lock-keywords t nil nil nil (font-lock-multiline . nil)))

(defvar diff-imenu-generic-expression
  ;; Prefer second name as first is most likely to be a backup or
  ;; version-control name.  The [\t\n] at the end of the unidiff pattern
  ;; catches Debian source diff files (which lack the trailing date).
  '((nil "\\+\\+\\+ \\([^\t\n]+\\)[\t\n]" 1) ; unidiffs
    (nil "^--- \\([^\t\n]+\\)\t.*\n\\*" 1))) ; context diffs

;;;;
;;;; Movement
;;;;

(defvar diff-valid-unified-empty-line t
  "If non-nil, empty lines are valid in unified diffs.
Some versions of diff replace all-blank context lines in unified format with
empty lines.  This makes the format less robust, but is tolerated.
See https://lists.gnu.org/r/emacs-devel/2007-11/msg01990.html")

(defconst diff-hunk-header-re
  (concat "^\\(?:" diff-hunk-header-re-unified ".*\\|\\*\\{15\\}.*\n\\*\\*\\* .+ \\*\\*\\*\\*\\|[0-9]+\\(,[0-9]+\\)?[acd][0-9]+\\(,[0-9]+\\)?\\)$"))
(defconst diff-file-header-re (concat "^\\(--- .+\n\\+\\+\\+ \\|\\*\\*\\* .+\n--- \\|[^-+!<>0-9@* \n]\\).+\n" (substring diff-hunk-header-re 1)))

(defconst diff-separator-re "^--+ ?$")

(defvar diff-outline-regexp
  (concat "\\(^diff.*\\|" diff-hunk-header-re "\\)"))

(defvar diff-narrowed-to nil)

(defun diff-hunk-style (&optional style)
  (when (looking-at diff-hunk-header-re)
    (setq style (cdr (assq (char-after) '((?@ . unified) (?* . context)))))
    (goto-char (match-end 0)))
  style)

(defun diff-prev-line-if-patch-separator ()
  "Return previous line if it has patch separator as produced by git."
  (pcase diff-buffer-type
    ('git
     (save-excursion
       (let ((old-point (point)))
         (forward-line -1)
         (if (looking-at "^-- $")
             (point)
           old-point))))
    (_ (point))))

(defun diff-end-of-hunk (&optional style donttrustheader)
  "Advance to the end of the current hunk, and return its position."
  (let (end)
    (when (looking-at diff-hunk-header-re)
      ;; Especially important for unified (because headers are ambiguous).
      (setq style (diff-hunk-style style))
      (goto-char (match-end 0))
      (when (and (not donttrustheader) (match-end 2))
        (let* ((nold (string-to-number (or (match-string 2) "1")))
               (nnew (string-to-number (or (match-string 4) "1")))
               (endold
                (save-excursion
                  (re-search-forward (if diff-valid-unified-empty-line
                                         "^[- \n]" "^[- ]")
                                     nil t nold)
                  (line-beginning-position
                   ;; Skip potential "\ No newline at end of file".
                   (if (looking-at ".*\n\\\\") 3 2))))
               (endnew
                ;; The hunk may end with a bunch of "+" lines, so the `end' is
                ;; then further than computed above.
                (save-excursion
                  (re-search-forward (if diff-valid-unified-empty-line
                                         "^[+ \n]" "^[+ ]")
                                     nil t nnew)
                  (line-beginning-position
                   ;; Skip potential "\ No newline at end of file".
                   (if (looking-at ".*\n\\\\") 3 2)))))
          (setq end (max endold endnew)))))
    ;; We may have a first evaluation of `end' thanks to the hunk header.
    (unless end
      (setq end (and (re-search-forward
                      (pcase style
                        ('unified
                         (concat (if diff-valid-unified-empty-line
                                     "^[^-+# \\\n]\\|" "^[^-+# \\]\\|")
                                 ;; A `unified' header is ambiguous.
                                 diff-file-header-re))
                        ('context (if diff-valid-unified-empty-line
                                      "^[^-+#! \n\\]" "^[^-+#! \\]"))
                        ('normal "^[^<>#\\]")
                        (_ "^[^-+#!<> \\]"))
                      nil t)
                     (match-beginning 0)))
      (when diff-valid-unified-empty-line
        ;; While empty lines may be valid inside hunks, they are also likely
        ;; to be unrelated to the hunk.
        (goto-char (or end (point-max)))
        (while (eq ?\n (char-before (1- (point))))
          (forward-char -1)
          (setq end (point))))
      (setq end (diff-prev-line-if-patch-separator)))
    ;; The return value is used by easy-mmode-define-navigation.
    (goto-char (or end (point-max)))))

;; "index ", "old mode", "new mode", "new file mode" and
;; "deleted file mode" are output by git-diff.
(defconst diff-file-junk-re
  (concat "Index: \\|Prereq: \\|=\\{20,\\}\\|" ; SVN
          "diff \\|index \\|\\(?:deleted file\\|new\\(?: file\\)?\\|old\\) mode\\|=== modified file"))

;; If point is in a diff header, then return beginning
;; of hunk position otherwise return nil.
(defun diff--at-diff-header-p ()
  "Return non-nil if point is inside a diff header."
  (let ((regexp-hunk diff-hunk-header-re)
        (regexp-file diff-file-header-re)
        (regexp-junk diff-file-junk-re)
        (orig (point)))
    (catch 'headerp
      (save-excursion
        (forward-line 0)
        (when (looking-at regexp-hunk) ; Hunk header.
          (throw 'headerp (point)))
        (forward-line -1)
        (when (re-search-forward regexp-file (line-end-position 4) t) ; File header.
          (forward-line 0)
          (throw 'headerp (point)))
        (goto-char orig)
        (forward-line 0)
        (when (looking-at regexp-junk) ; Git diff junk.
          (while (and (looking-at regexp-junk)
                      (not (bobp)))
            (forward-line -1))
          (re-search-forward regexp-file nil t)
          (forward-line 0)
          (throw 'headerp (point)))) nil)))

(defun diff-beginning-of-hunk (&optional try-harder)
  "Move back to the previous hunk beginning, and return its position.
If point is in a file header rather than a hunk, advance to the
next hunk if TRY-HARDER is non-nil; otherwise signal an error."
  (beginning-of-line)
  (if (looking-at diff-hunk-header-re) ; At hunk header.
      (point)
    (let ((pos (diff--at-diff-header-p))
          (regexp diff-hunk-header-re))
      (cond (pos ; At junk diff header.
             (if try-harder
                 (goto-char pos)
               (error "Can't find the beginning of the hunk")))
            ((re-search-backward regexp nil t)) ; In the middle of a hunk.
            ((re-search-forward regexp nil t) ; At first hunk header.
             (forward-line 0)
             (point))
            (t (error "Can't find the beginning of the hunk"))))))

(defun diff-unified-hunk-p ()
  (save-excursion
    (ignore-errors
      (diff-beginning-of-hunk)
      (looking-at "^@@"))))

(defun diff-beginning-of-file ()
  (beginning-of-line)
  (unless (looking-at diff-file-header-re)
    (let ((start (point))
          res)
      ;; diff-file-header-re may need to match up to 4 lines, so in case
      ;; we're inside the header, we need to move up to 3 lines forward.
      (forward-line 3)
      (if (and (setq res (re-search-backward diff-file-header-re nil t))
               ;; Maybe the 3 lines forward were too much and we matched
               ;; a file header after our starting point :-(
               (or (<= (point) start)
                   (setq res (re-search-backward diff-file-header-re nil t))))
          res
        (goto-char start)
        (error "Can't find the beginning of the file")))))


(defun diff-end-of-file ()
  (re-search-forward "^[-+#!<>0-9@* \\]" nil t)
  (re-search-forward (concat "^[^-+#!<>0-9@* \\]\\|" diff-file-header-re)
		     nil 'move)
  (if (match-beginning 1)
      (goto-char (match-beginning 1))
    (beginning-of-line)))

(defvar diff--auto-refine-data nil)

;; Define diff-{hunk,file}-{prev,next}
(easy-mmode-define-navigation
 diff-hunk diff-hunk-header-re "hunk" diff-end-of-hunk diff-restrict-view
 (when (and (eq diff-refine 'navigation) (called-interactively-p 'interactive))
   (unless (prog1 diff--auto-refine-data
             (setq diff--auto-refine-data
                   (cons (current-buffer) (point-marker))))
     (run-at-time 0.0 nil
                  (lambda ()
                    (when diff--auto-refine-data
                      (let ((buffer (car diff--auto-refine-data))
                            (point (cdr diff--auto-refine-data)))
                        (setq diff--auto-refine-data nil)
                        (with-local-quit
                          (when (buffer-live-p buffer)
                            (with-current-buffer buffer
                              (save-excursion
                                (goto-char point)
                                (diff-refine-hunk))))))))))))

(easy-mmode-define-navigation
 diff-file diff-file-header-re "file" diff-end-of-file)

(defun diff-bounds-of-hunk ()
  "Return the bounds of the diff hunk at point.
The return value is a list (BEG END), which are the hunk's start
and end positions.  Signal an error if no hunk is found.  If
point is in a file header, return the bounds of the next hunk."
  (save-excursion
    (let ((pos (point))
	  (beg (diff-beginning-of-hunk t))
	  (end (diff-end-of-hunk)))
      (cond ((>= end pos)
	     (list beg end))
	    ;; If this hunk ends above POS, consider the next hunk.
	    ((re-search-forward diff-hunk-header-re nil t)
	     (list (match-beginning 0) (diff-end-of-hunk)))
	    (t (error "No hunk found"))))))

(defun diff-bounds-of-file ()
  "Return the bounds of the file segment at point.
The return value is a list (BEG END), which are the segment's
start and end positions."
  (save-excursion
    (let ((pos (point))
	  (beg (progn (diff-beginning-of-file-and-junk)
		      (point))))
      (diff-end-of-file)
      ;; bzr puts a newline after the last hunk.
      (while (looking-at "^\n")
	(forward-char 1))
      (if (> pos (point))
	  (error "Not inside a file diff"))
      (list beg (point)))))

(defun diff-restrict-view (&optional arg)
  "Restrict the view to the current hunk.
If the prefix ARG is given, restrict the view to the current file instead."
  (interactive "P")
  (apply #'narrow-to-region
	 (if arg (diff-bounds-of-file) (diff-bounds-of-hunk)))
  (setq-local diff-narrowed-to (if arg 'file 'hunk)))

(defun diff--some-hunks-p ()
  (save-excursion
    (goto-char (point-min))
    (re-search-forward diff-hunk-header-re nil t)))

(defun diff-hunk-kill ()
  "Kill the hunk at point."
  (interactive)
  (if (not (diff--some-hunks-p))
      (error "No hunks")
    (diff-beginning-of-hunk t)
    (let* ((hunk-bounds (diff-bounds-of-hunk))
           (file-bounds (ignore-errors (diff-bounds-of-file)))
           ;; If the current hunk is the only one for its file, kill the
           ;; file header too.
           (bounds (if (and file-bounds
                            (progn (goto-char (car file-bounds))
                                   (= (progn (diff-hunk-next) (point))
                                      (car hunk-bounds)))
                            (progn (goto-char (cadr hunk-bounds))
                                   ;; bzr puts a newline after the last hunk.
                                   (while (looking-at "^\n")
                                     (forward-char 1))
                                   (= (point) (cadr file-bounds))))
                       file-bounds
                     hunk-bounds))
           (inhibit-read-only t))
      (apply #'kill-region bounds)
      (goto-char (car bounds))
      (ignore-errors (diff-beginning-of-hunk t)))))

;; This is not `diff-kill-other-hunks' because we might need to make
;; copies of file headers in order to ensure the new kill ring entry
;; would be a patch with the same meaning.  That is not implemented
;; because it does not seem like it would be useful.
(defun diff-delete-other-hunks (&optional beg end)
  "Delete hunks other than the current one.
Interactively, if the region is active, delete all hunks that the region
overlaps; otherwise delete all hunks except the current one.
When calling from Lisp, pass BEG and END as the bounds of the region in
which to delete hunks; BEG and END omitted or nil means to delete all
the hunks but the one which contains point."
  (interactive (list (use-region-beginning) (use-region-end)))
  (when (buffer-narrowed-p)
    (user-error "Command is not safe in a narrowed buffer"))
  (let ((inhibit-read-only t))
    (save-excursion
      (cond ((xor beg end)
             (error "Require exactly zero or two arguments"))
            (beg
             (goto-char beg)
             (setq beg (car (diff-bounds-of-hunk)))
             (goto-char end)
             (setq end (cadr (diff-bounds-of-hunk))))
            (t
             (pcase-setq `(,beg ,end) (diff-bounds-of-hunk))))
      (delete-region end (point-max))
      (goto-char beg)
      (diff-beginning-of-file)
      (diff-hunk-next)
      (delete-region (point) beg)
      (diff-beginning-of-file-and-junk)
      (delete-region (point-min) (point)))))

(defun diff-beginning-of-file-and-junk ()
  "Go to the beginning of file-related diff-info.
This is like `diff-beginning-of-file' except it tries to skip back over leading
data such as \"Index: ...\" and such."
  (let* ((orig (point))
         ;; Skip forward over what might be "leading junk" so as to get
         ;; closer to the actual diff.
         (_ (progn (beginning-of-line)
                   (while (looking-at diff-file-junk-re)
                     (forward-line 1))))
         (start (point))
         (prevfile (condition-case err
                       (save-excursion (diff-beginning-of-file) (point))
                     (error err)))
         (err (if (consp prevfile) prevfile))
         (nextfile (ignore-errors
                     (save-excursion
                       (goto-char start) (diff-file-next) (point))))
         ;; prevhunk is one of the limits.
         (prevhunk (save-excursion
                     (ignore-errors
                       (if (numberp prevfile) (goto-char prevfile))
                       (diff-hunk-prev) (point))))
         (previndex (save-excursion
                      (forward-line 1)  ;In case we're looking at "Index:".
                      (re-search-backward "^Index: " prevhunk t))))
    ;; If we're in the junk, we should use nextfile instead of prevfile.
    (if (and (numberp nextfile)
             (or (not (numberp prevfile))
                 (and previndex (> previndex prevfile))))
        (setq prevfile nextfile))
    (if (and previndex (numberp prevfile) (< previndex prevfile))
        (setq prevfile previndex))
    (if (and (numberp prevfile) (<= prevfile start))
          (progn
            (goto-char prevfile)
            ;; Now skip backward over the leading junk we may have before the
            ;; diff itself.
            (while (save-excursion
                     (and (zerop (forward-line -1))
                          (looking-at diff-file-junk-re)))
              (forward-line -1)))
      ;; File starts *after* the starting point: we really weren't in
      ;; a file diff but elsewhere.
      (goto-char orig)
      (signal (car err) (cdr err)))))

(defun diff-file-kill ()
  "Kill current file's hunks."
  (interactive)
  (if (not (diff--some-hunks-p))
      (error "No hunks")
    (diff-beginning-of-hunk t)
    (let ((inhibit-read-only t))
      (apply #'kill-region (diff-bounds-of-file)))
    (ignore-errors (diff-beginning-of-hunk t))))

(defun diff-kill-junk ()
  "Kill spurious empty diffs."
  (interactive)
  (save-excursion
    (let ((inhibit-read-only t))
      (goto-char (point-min))
      (while (re-search-forward (concat "^\\(Index: .*\n\\)"
					"\\([^-+!* <>].*\n\\)*?"
					"\\(\\(Index:\\) \\|"
					diff-file-header-re "\\)")
				nil t)
	(delete-region (if (match-end 4) (match-beginning 0) (match-end 1))
		       (match-beginning 3))
	(beginning-of-line)))))

(defun diff-count-matches (re start end)
  (save-excursion
    (let ((n 0))
      (goto-char start)
      (while (re-search-forward re end t) (incf n))
      n)))

(defun diff-splittable-p ()
  (save-excursion
    (beginning-of-line)
    (and (looking-at "^[-+ ]")
         (progn (forward-line -1) (looking-at "^[-+ ]"))
         (diff-unified-hunk-p))))

(defun diff-split-hunk ()
  "Split the current (unified diff) hunk at point into two hunks."
  (interactive)
  (beginning-of-line)
  (let ((pos (point))
	(start (diff-beginning-of-hunk)))
    (unless (looking-at diff-hunk-header-re-unified)
      (error "diff-split-hunk only works on unified context diffs"))
    (forward-line 1)
    (let* ((start1 (string-to-number (match-string 1)))
	   (start2 (string-to-number (match-string 3)))
	   (newstart1 (+ start1 (diff-count-matches "^[- \t]" (point) pos)))
	   (newstart2 (+ start2 (diff-count-matches "^[+ \t]" (point) pos)))
	   (inhibit-read-only t))
      (goto-char pos)
      ;; Hopefully the after-change-function will not screw us over.
      (insert "@@ -" (number-to-string newstart1) ",1 +"
	      (number-to-string newstart2) ",1 @@\n")
      ;; Fix the original hunk-header.
      (diff-fixup-modifs start pos))))

(defun diff--outline-level ()
  (if (string-match-p diff-hunk-header-re (match-string 0))
      2 1))

;;;;
;;;; jump to other buffers
;;;;

(defvar diff-remembered-files-alist nil)
(defvar diff-remembered-defdir nil)

(defun diff-filename-drop-dir (file)
  (when (string-match "/" file) (substring file (match-end 0))))

(defun diff-merge-strings (ancestor from to)
  "Merge the diff between ANCESTOR and FROM into TO.
Returns the merged string if successful or nil otherwise.
The strings are assumed not to contain any \"\\n\" (i.e. end of line).
If ANCESTOR = FROM, returns TO.
If ANCESTOR = TO, returns FROM.
The heuristic is simplistic and only really works for cases
like \(diff-merge-strings \"b/foo\" \"b/bar\" \"/a/c/foo\")."
  ;; Ideally, we want:
  ;;   AMB ANB CMD -> CND
  ;; but that's ambiguous if `foo' or `bar' is empty:
  ;; a/foo a/foo1 b/foo.c -> b/foo1.c but not 1b/foo.c or b/foo.c1
  (let ((str (concat ancestor "\n" from "\n" to)))
    (when (and (string-match (concat
			      "\\`\\(.*?\\)\\(.*\\)\\(.*\\)\n"
			      "\\1\\(.*\\)\\3\n"
			      "\\(.*\\(\\2\\).*\\)\\'")
			     str)
	       (equal to (match-string 5 str)))
      (concat (substring str (match-beginning 5) (match-beginning 6))
	      (match-string 4 str)
	      (substring str (match-end 6) (match-end 5))))))

(defun diff-tell-file-name (old name)
  "Tell Emacs where the find the source file of the current hunk.
If the OLD prefix arg is passed, tell the file NAME of the old file."
  (interactive
   (let* ((old current-prefix-arg)
	  (fs (diff-hunk-file-names current-prefix-arg)))
     (unless fs (error "No file name to look for"))
     (list old (read-file-name (format "File for %s: " (car fs))
			       nil (diff-find-file-name old 'noprompt) t))))
  (let ((fs (diff-hunk-file-names old)))
    (unless fs (error "No file name to look for"))
    (push (cons fs name) diff-remembered-files-alist)))

(defun diff-hunk-file-names (&optional old)
  "Give the list of file names textually mentioned for the current hunk."
  (save-excursion
    (unless (looking-at diff-file-header-re)
      (or (ignore-errors (diff-beginning-of-file))
	  (re-search-forward diff-file-header-re nil t)))
    (let ((limit (save-excursion
		   (condition-case ()
		       (progn (diff-hunk-prev) (point))
		     (error (point-min)))))
	  (header-files
           ;; handle file names with spaces;
           ;; cf. diff-font-lock-keywords / diff-file-header
           ;; FIXME if there are nonascii characters in the file names,
           ;; GNU diff displays them as octal escapes.
           ;; This function should undo that, so as to return file names
           ;; that are usable in Emacs.
	   (if (looking-at "[-*][-*][-*] \\([^\t\n]+\\).*\n[-+][-+][-+] \\([^\t\n]+\\)")
	       (list (if old (match-string 1) (match-string 2))
		     (if old (match-string 2) (match-string 1)))
	     (forward-line 1) nil)))
      (delq nil
	    (append
	     (when (and (not old)
			(save-excursion
			  (re-search-backward "^Index: \\(.+\\)" limit t)))
	       (list (match-string 1)))
	     header-files
             ;; this assumes that there are no spaces in filenames
             (and (re-search-backward "^diff " nil t)
                  (looking-at
		   "^diff \\(-[^ \t\nL]+ +\\)*\\(-L +\\S-+ +\\)*\\(\\S-+\\)\\( +\\(\\S-+\\)\\)?")
	          (list (if old (match-string 3) (match-string 5))
		        (if old (match-string 4) (match-string 3)))))))))

(defun diff-find-file-name (&optional old noprompt prefix)
  "Return the file corresponding to the current patch.
Non-nil OLD means that we want the old file.
Non-nil NOPROMPT means to prefer returning nil than to prompt the user.
PREFIX is only used internally: don't use it."
  (unless (equal diff-remembered-defdir default-directory)
    ;; Flush diff-remembered-files-alist if the default-directory is changed.
    (setq-local diff-remembered-defdir default-directory)
    (setq-local diff-remembered-files-alist nil))
  (save-excursion
    (save-restriction
      (widen)
      (unless (looking-at diff-file-header-re)
        (or (ignore-errors (diff-beginning-of-file))
	    (re-search-forward diff-file-header-re nil t)))
      (let ((fs (diff-hunk-file-names old)))
        (if prefix (setq fs (mapcar (lambda (f) (concat prefix f)) fs)))
        (or
         ;; use any previously used preference
         (cdr (assoc fs diff-remembered-files-alist))
         ;; try to be clever and use previous choices as an inspiration
         (cl-dolist (rf diff-remembered-files-alist)
	   (let ((newfile (diff-merge-strings (caar rf) (car fs) (cdr rf))))
	     (if (and newfile (file-exists-p newfile)) (cl-return newfile))))
         ;; look for each file in turn.  If none found, try again but
         ;; ignoring the first level of directory, ...
         (cl-do* ((files fs (delq nil (mapcar #'diff-filename-drop-dir files)))
                  (file nil nil))
	     ((or (null files)
		  (setq file (cl-do* ((files files (cdr files))
                                      (file (car files) (car files)))
			         ;; Use file-regular-p to avoid
			         ;; /dev/null, directories, etc.
			         ((or (null file) (file-regular-p file))
				  file))))
	      file))
         ;; <foo>.rej patches implicitly apply to <foo>
         (and (string-match "\\.rej\\'" (or buffer-file-name ""))
	      (let ((file (substring buffer-file-name 0 (match-beginning 0))))
	        (when (file-exists-p file) file)))
         ;; If we haven't found the file, maybe it's because we haven't paid
         ;; attention to the PCL-CVS hint.
         (and (not prefix)
	      (boundp 'cvs-pcl-cvs-dirchange-re)
	      (save-excursion
	        (re-search-backward cvs-pcl-cvs-dirchange-re nil t))
	      (diff-find-file-name old noprompt (match-string 1)))
         ;; if all else fails, ask the user
         (unless noprompt
           (let ((file (or (car fs) ""))
                 (creation (equal null-device
                                  (car (diff-hunk-file-names (not old))))))
             (when (and (memq diff-buffer-type '(git hg))
                        (string-match "/" file))
               ;; Strip the dst prefix (like b/) if diff is from Git/Hg.
               (setq file (substring file (match-end 0))))
             (setq file (expand-file-name file))
	     (setq file
		   (read-file-name (format "Use file %s: " file)
				   (file-name-directory file) file
                                   ;; Allow non-matching for creation.
                                   (not creation)
				   (file-name-nondirectory file)))
             (when (or (not creation) (file-exists-p file))
               ;; Only remember files that exist. User might have mistyped.
               (setq-local diff-remembered-files-alist
                           (cons (cons fs file) diff-remembered-files-alist)))
             file)))))))


(defun diff-ediff-patch ()
  "Call `ediff-patch-file' on the current buffer."
  (interactive)
  (condition-case nil
      (ediff-patch-file nil (current-buffer))
    (wrong-number-of-arguments (ediff-patch-file))))

;;;;
;;;; Conversion functions
;;;;

;;(defvar diff-inhibit-after-change nil
;;  "Non-nil means inhibit `diff-mode's after-change functions.")

(defun diff-unified->context (start end)
  "Convert unified diffs to context diffs.
START and END are either taken from the region (if a prefix arg is given) or
else cover the whole buffer."
  (interactive (if (or current-prefix-arg (use-region-p))
		   (list (region-beginning) (region-end))
		 (list (point-min) (point-max))))
  (unless (markerp end) (setq end (copy-marker end t)))
  (let (;;(diff-inhibit-after-change t)
	(inhibit-read-only t))
    (save-excursion
      (goto-char start)
      (while (and (re-search-forward
                   (concat "^\\(\\(---\\) .+\n\\(\\+\\+\\+\\) .+\\|"
                           diff-hunk-header-re-unified ".*\\)$")
                   nil t)
		  (< (point) end))
	(combine-after-change-calls
	  (if (match-beginning 2)
	      ;; we matched a file header
	      (progn
		;; use reverse order to make sure the indices are kept valid
		(replace-match "---" t t nil 3)
		(replace-match "***" t t nil 2))
	    ;; we matched a hunk header
	    (let ((line1 (match-string 4))
		  (lines1 (or (match-string 5) "1"))
		  (line2 (match-string 6))
		  (lines2 (or (match-string 7) "1"))
		  ;; Variables to use the special undo function.
		  (old-undo buffer-undo-list)
		  (old-end (marker-position end))
		  (start (match-beginning 0))
		  (reversible t))
	      (replace-match
	       (concat "***************\n*** " line1 ","
		       (number-to-string (+ (string-to-number line1)
					    (string-to-number lines1)
					    -1))
		       " ****"))
	      (save-restriction
		(narrow-to-region (line-beginning-position 2)
                                  ;; Call diff-end-of-hunk from just before
                                  ;; the hunk header so it can use the hunk
                                  ;; header info.
				  (progn (diff-end-of-hunk 'unified) (point)))
		(let ((hunk (buffer-string)))
		  (goto-char (point-min))
		  (if (not (save-excursion (re-search-forward "^-" nil t)))
		      (delete-region (point) (point-max))
		    (goto-char (point-max))
		    (let ((modif nil) last-pt)
		      (while (progn (setq last-pt (point))
				    (= (forward-line -1) 0))
			(pcase (char-after)
			  (?\s (insert " ") (setq modif nil) (backward-char 1))
			  (?+ (delete-region (point) last-pt) (setq modif t))
			  (?- (if (not modif)
                                  (progn (forward-char 1)
                                         (insert " "))
                                (delete-char 1)
                                (insert "! "))
                              (backward-char 2))
			  (?\\ (when (save-excursion (forward-line -1)
                                                     (= (char-after) ?+))
                                 (delete-region (point) last-pt)
                                 (setq modif t)))
                          ;; diff-valid-unified-empty-line.
                          (?\n (insert "  ") (setq modif nil)
                               (backward-char 2))
			  (_ (setq modif nil))))))
		  (goto-char (point-max))
		  (save-excursion
		    (insert "--- " line2 ","
			    (number-to-string (+ (string-to-number line2)
						 (string-to-number lines2)
						 -1))
                            " ----\n" hunk))
		  ;;(goto-char (point-min))
		  (forward-line 1)
		  (if (not (save-excursion (re-search-forward "^\\+" nil t)))
		      (delete-region (point) (point-max))
		    (let ((modif nil) (delete nil))
		      (if (save-excursion (re-search-forward "^\\+.*\n-"
                                                             nil t))
                          ;; Normally, lines in a substitution come with
                          ;; first the removals and then the additions, and
                          ;; the context->unified function follows this
                          ;; convention, of course.  Yet, other alternatives
                          ;; are valid as well, but they preclude the use of
                          ;; context->unified as an undo command.
			  (setq reversible nil))
		      (while (not (eobp))
			(pcase (char-after)
			  (?\s (insert " ") (setq modif nil) (backward-char 1))
			  (?- (setq delete t) (setq modif t))
			  (?+ (if (not modif)
                                  (progn (forward-char 1)
                                         (insert " "))
                                (delete-char 1)
                                (insert "! "))
                              (backward-char 2))
			  (?\\ (when (save-excursion (forward-line 1)
                                                     (not (eobp)))
                                 (setq delete t) (setq modif t)))
                          ;; diff-valid-unified-empty-line.
                          (?\n (insert "  ") (setq modif nil) (backward-char 2)
                               (setq reversible nil))
			  (_ (setq modif nil)))
			(let ((last-pt (point)))
			  (forward-line 1)
			  (when delete
			    (delete-region last-pt (point))
			    (setq delete nil)))))))
		(unless (or (not reversible) (eq buffer-undo-list t))
                  ;; Drop the many undo entries and replace them with
                  ;; a single entry that uses diff-context->unified to do
                  ;; the work.
		  (setq buffer-undo-list
			(cons (list 'apply (- old-end end) start (point-max)
				    'diff-context->unified start (point-max))
			      old-undo)))))))))))

(defun diff-context->unified (start end &optional to-context)
  "Convert context diffs to unified diffs.
START and END are either taken from the region
\(when it is highlighted) or else cover the whole buffer.
With a prefix argument, convert unified format to context format."
  (interactive (if (use-region-p)
		   (list (region-beginning) (region-end) current-prefix-arg)
		 (list (point-min) (point-max) current-prefix-arg)))
  (if to-context
      (diff-unified->context start end)
    (unless (markerp end) (setq end (copy-marker end t)))
    (let ( ;;(diff-inhibit-after-change t)
          (inhibit-read-only t))
      (save-excursion
        (goto-char start)
        (while (and (re-search-forward "^\\(\\(\\*\\*\\*\\) .+\n\\(---\\) .+\\|\\*\\{15\\}.*\n\\*\\*\\* \\([0-9]+\\),\\(-?[0-9]+\\) \\*\\*\\*\\*\\)\\(?: \\(.*\\)\\|$\\)" nil t)
                    (< (point) end))
          (combine-after-change-calls
            (if (match-beginning 2)
                ;; we matched a file header
                (progn
                  ;; use reverse order to make sure the indices are kept valid
                  (replace-match "+++" t t nil 3)
                  (replace-match "---" t t nil 2))
              ;; we matched a hunk header
              (let ((line1s (match-string 4))
                    (line1e (match-string 5))
                    (pt1 (match-beginning 0))
                    ;; Variables to use the special undo function.
                    (old-undo buffer-undo-list)
                    (old-end (marker-position end))
                    ;; We currently throw away the comment that can follow
                    ;; the hunk header.  FIXME: Preserve it instead!
                    (reversible (not (match-end 6))))
                (replace-match "")
                (unless (re-search-forward
                         diff-context-mid-hunk-header-re nil t)
                  (error "Can't find matching `--- n1,n2 ----' line"))
                (let ((line2s (match-string 1))
                      (line2e (match-string 2))
                      (pt2 (progn
                             (delete-region (progn (beginning-of-line) (point))
                                            (progn (forward-line 1) (point)))
                             (point-marker))))
                  (goto-char pt1)
                  (forward-line 1)
                  (while (< (point) pt2)
                    (pcase (char-after)
                      (?! (delete-char 2) (insert "-") (forward-line 1))
                      (?- (forward-char 1) (delete-char 1) (forward-line 1))
                      (?\s              ;merge with the other half of the chunk
                       (let* ((endline2
                               (save-excursion
                                 (goto-char pt2) (forward-line 1) (point))))
                         (pcase (char-after pt2)
                           ((or ?! ?+)
                            (insert "+"
                                    (prog1
                                        (buffer-substring (+ pt2 2) endline2)
                                      (delete-region pt2 endline2))))
                           (?\s
                            (unless (= (- endline2 pt2)
                                       (- (line-beginning-position 2) (point)))
                              ;; If the two lines we're merging don't have the
                              ;; same length (can happen with "diff -b"), then
                              ;; diff-unified->context will not properly undo
                              ;; this operation.
                              (setq reversible nil))
                            (delete-region pt2 endline2)
                            (delete-char 1)
                            (forward-line 1))
                           (?\\ (forward-line 1))
                           (_ (setq reversible nil)
                              (delete-char 1) (forward-line 1)))))
                      (_ (setq reversible nil) (forward-line 1))))
                  (while (looking-at "[+! ] ")
                    (if (/= (char-after) ?!) (forward-char 1)
                      (delete-char 1) (insert "+"))
                    (delete-char 1) (forward-line 1))
                  (save-excursion
                    (goto-char pt1)
                    (insert "@@ -" line1s ","
                            (number-to-string (- (string-to-number line1e)
                                                 (string-to-number line1s)
                                                 -1))
                            " +" line2s ","
                            (number-to-string (- (string-to-number line2e)
                                                 (string-to-number line2s)
                                                 -1)) " @@"))
                  (set-marker pt2 nil)
                  ;; The whole procedure succeeded, let's replace the myriad
                  ;; of undo elements with just a single special one.
                  (unless (or (not reversible) (eq buffer-undo-list t))
                    (setq buffer-undo-list
                          (cons (list 'apply (- old-end end) pt1 (point)
                                      'diff-unified->context pt1 (point))
                                old-undo)))
                  )))))))))

(defun diff-reverse-direction (start end)
  "Reverse the direction of the diffs.
START and END are either taken from the region (if a prefix arg is given) or
else cover the whole buffer."
  (interactive (if (or current-prefix-arg (use-region-p))
		   (list (region-beginning) (region-end))
		 (list (point-min) (point-max))))
  (unless (markerp end) (setq end (copy-marker end t)))
  (let (;;(diff-inhibit-after-change t)
	(inhibit-read-only t))
    (save-excursion
      (goto-char start)
      (while (and (re-search-forward "^\\(\\([-*][-*][-*] \\)\\(.+\\)\n\\([-+][-+][-+] \\)\\(.+\\)\\|\\*\\{15\\}.*\n\\*\\*\\* \\(.+\\) \\*\\*\\*\\*\\|@@ -\\([0-9,]+\\) \\+\\([0-9,]+\\) @@.*\\)$" nil t)
		  (< (point) end))
	(combine-after-change-calls
	  (cond
	   ;; a file header
	   ((match-beginning 2) (replace-match "\\2\\5\n\\4\\3" nil))
	   ;; a context-diff hunk header
	   ((match-beginning 6)
	    (let ((pt-lines1 (match-beginning 6))
		  (lines1 (match-string 6)))
	      (replace-match "" nil nil nil 6)
	      (forward-line 1)
	      (let ((half1s (point)))
		(while (looking-at "[-! \\][ \t]\\|#")
		  (when (= (char-after) ?-) (delete-char 1) (insert "+"))
		  (forward-line 1))
		(let ((half1 (delete-and-extract-region half1s (point))))
		  (unless (looking-at diff-context-mid-hunk-header-re)
		    (insert half1)
		    (error "Can't find matching `--- n1,n2 ----' line"))
		  (let* ((str1end (or (match-end 2) (match-end 1)))
                         (str1 (buffer-substring (match-beginning 1) str1end)))
                    (goto-char str1end)
                    (insert lines1)
                    (delete-region (match-beginning 1) str1end)
		    (forward-line 1)
		    (let ((half2s (point)))
		      (while (looking-at "[!+ \\][ \t]\\|#")
			(when (= (char-after) ?+) (delete-char 1) (insert "-"))
			(forward-line 1))
		      (let ((half2 (delete-and-extract-region half2s (point))))
			(insert (or half1 ""))
			(goto-char half1s)
			(insert (or half2 ""))))
		    (goto-char pt-lines1)
		    (insert str1))))))
	   ;; a unified-diff hunk header
	   ((match-beginning 7)
	    (replace-match "@@ -\\8 +\\7 @@" nil)
	    (forward-line 1)
	    (let ((c (char-after)) first last)
	      (while (pcase (setq c (char-after))
		       (?- (setq first (or first (point)))
                           (delete-char 1) (insert "+") t)
		       (?+ (setq last (or last (point)))
                           (delete-char 1) (insert "-") t)
		       ((or ?\\ ?#) t)
		       (_ (when (and first last (< first last))
			    (insert (delete-and-extract-region first last)))
			  (setq first nil last nil)
			  (memq c (if diff-valid-unified-empty-line
                                      '(?\s ?\n) '(?\s)))))
		(forward-line 1))))))))))

(defun diff-fixup-modifs (start end)
  "Fixup the hunk headers (in case the buffer was modified).
START and END are either taken from the region (if a prefix arg is given) or
else cover the whole buffer."
  (interactive (if (or current-prefix-arg (use-region-p))
		   (list (region-beginning) (region-end))
		 (list (point-min) (point-max))))
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char end) (diff-end-of-hunk nil 'donttrustheader)
      (let ((plus 0) (minus 0) (space 0) (bang 0))
	(while (and (= (forward-line -1) 0) (<= start (point)))
	  (if (not (looking-at
		    (concat diff-hunk-header-re-unified
			    "\\|[-*][-*][-*] [0-9,]+ [-*][-*][-*][-*]$"
			    "\\|--- .+\n\\+\\+\\+ ")))
	      (pcase (char-after)
                (?\s (incf space))
                (?+ (incf plus))
		(?- (unless ;; In git format-patch "^-- $" signifies
                            ;; the end of the patch.
			(and (eq diff-buffer-type 'git)
			     (looking-at "^-- $"))
                      (incf minus)))
                (?! (incf bang))
		((or ?\\ ?#) nil)
		(?\n (if diff-valid-unified-empty-line
                         (incf space)
		       (setq space 0 plus 0 minus 0 bang 0)))
		(_  (setq space 0 plus 0 minus 0 bang 0)))
	    (cond
	     ((looking-at diff-hunk-header-re-unified)
	      (let* ((old1 (match-string 2))
		     (old2 (match-string 4))
		     (new1 (number-to-string (+ space minus)))
		     (new2 (number-to-string (+ space plus))))
		(if old2
		    (unless (string= new2 old2) (replace-match new2 t t nil 4))
		  (goto-char (match-end 3))
		  (insert "," new2))
		(if old1
		    (unless (string= new1 old1) (replace-match new1 t t nil 2))
		  (goto-char (match-end 1))
		  (insert "," new1))))
	     ((looking-at diff-context-mid-hunk-header-re)
	      (when (> (+ space bang plus) 0)
		(let* ((old1 (match-string 1))
		       (old2 (match-string 2))
		       (new (number-to-string
			     (+ space bang plus -1 (string-to-number old1)))))
		  (unless (string= new old2) (replace-match new t t nil 2)))))
	     ((looking-at "\\*\\*\\* \\([0-9]+\\),\\(-?[0-9]*\\) \\*\\*\\*\\*$")
	      (when (> (+ space bang minus) 0)
		(let* ((old (match-string 1))
		       (new (format
			     (concat "%0" (number-to-string (length old)) "d")
			     (+ space bang minus -1 (string-to-number old)))))
		  (unless (string= new old) (replace-match new t t nil 2))))))
	    (setq space 0 plus 0 minus 0 bang 0)))))))

;;;;
;;;; Hooks
;;;;

(defun diff-write-contents-hooks ()
  "Fixup hunk headers if necessary."
  (if (buffer-modified-p) (diff-fixup-modifs (point-min) (point-max)))
  nil)

(defvar-local diff--track-changes nil)

(defun diff--track-changes-signal (tracker)
  (cl-assert (eq tracker diff--track-changes))
  (track-changes-fetch tracker #'diff--track-changes-function))

(defun diff--track-changes-function (beg end _before)
  (with-demoted-errors "%S"
    (save-excursion
      (goto-char beg)
      ;; Maybe we've cut the end of the hunk before point.
      (if (and (bolp) (not (bobp))) (backward-char 1))
      ;; We used to fixup modifs on all the changes, but it turns out that
      ;; it's safer not to do it on big changes, e.g. when yanking a big
      ;; diff, or when the user edits the header, since we might then
      ;; screw up perfectly correct values.  --Stef
      (when (ignore-errors (diff-beginning-of-hunk t))
        (let* ((style (if (looking-at "\\*\\*\\*") 'context))
               (start (line-beginning-position (if (eq style 'context) 3 2)))
               (mid (if (eq style 'context)
                        (save-excursion
                          (re-search-forward diff-context-mid-hunk-header-re
                                             nil t)))))
          (when (and ;; Don't try to fixup changes in the hunk header.
                 (>= beg start)
                 ;; Don't try to fixup changes in the mid-hunk header either.
                 (or (not mid)
                     (< end (match-beginning 0))
                     (> beg (match-end 0)))
                 (save-excursion
		   (diff-end-of-hunk nil 'donttrustheader)
                   ;; Don't try to fixup changes past the end of the hunk.
                   (>= (point) end)))
	   (diff-fixup-modifs (point) end)
	   ;; Ignore the changes we just made ourselves.
	   ;; This is not indispensable since the above `when' skips
	   ;; changes like the ones we make anyway, but it's good practice.
	   (track-changes-fetch diff--track-changes #'ignore)))))))

(defun diff-next-error (arg reset)
  ;; Select a window that displays the current buffer so that point
  ;; movements are reflected in that window.  Otherwise, the user might
  ;; never see the hunk corresponding to the source she's jumping to.
  (pop-to-buffer (current-buffer))
  (if reset (goto-char (point-min)))
  (diff-hunk-next arg)
  (diff-goto-source))

(defun diff--font-lock-cleanup ()
  (remove-overlays nil nil 'diff-mode 'fine)
  (remove-overlays nil nil 'diff-mode 'syntax)
  (when font-lock-mode
    (make-local-variable 'font-lock-extra-managed-props)
    ;; Added when diff--font-lock-prettify is non-nil!
    (cl-pushnew 'display font-lock-extra-managed-props)))

(defvar-local diff-mode-read-only nil
  "Non-nil when read-only diff buffer uses short keys.")

(defvar-keymap diff-read-only-map
  :doc "Additional bindings for read-only `diff-mode' buffers."
  :keymap (make-composed-keymap diff-mode-shared-map special-mode-map))

;; It should be lower than `outline-minor-mode' and `view-mode'.
(or (assq 'diff-mode-read-only minor-mode-map-alist)
    (nconc minor-mode-map-alist
           (list (cons 'diff-mode-read-only diff-read-only-map))))

(defvar whitespace-style)
(defvar whitespace-trailing-regexp)

;; Prevent applying `view-read-only' to diff-mode buffers (bug#75993).
;; We don't derive from `special-mode' because that would inhibit the
;; `self-insert-command' binding of normal keys.
(put 'diff-mode 'mode-class 'special)
;;;###autoload
(define-derived-mode diff-mode fundamental-mode "Diff"
  "Major mode for viewing/editing context diffs.
Supports unified and context diffs as well as, to a lesser extent, diffs
in the old \"normal\" format.  (Unified diffs have become the standard,
most commonly encountered format.)  If you edit the buffer manually,
`diff-mode' will try to update the hunk headers for you on-the-fly.

You can also switch between context diff and unified diff with \\[diff-context->unified],
or vice versa with \\[diff-unified->context] and you can also reverse the direction of
a diff with \\[diff-reverse-direction].

\\{diff-mode-map}
In read-only buffers the following bindings are also available:
\\{diff-read-only-map}"

  (setq-local font-lock-defaults diff-font-lock-defaults)
  (add-hook 'font-lock-mode-hook #'diff--font-lock-cleanup nil 'local)
  (setq-local imenu-generic-expression
              diff-imenu-generic-expression)
  ;; These are not perfect.  They would be better done separately for
  ;; context diffs and unidiffs.
  ;; (setq-local paragraph-start
  ;;        (concat "@@ "			; unidiff hunk
  ;; 	       "\\|\\*\\*\\* "		; context diff hunk or file start
  ;; 	       "\\|--- [^\t]+\t"))	; context or unidiff file
  ;; 					; start (first or second line)
  ;;   (setq-local paragraph-separate paragraph-start)
  ;;   (setq-local page-delimiter "--- [^\t]+\t")
  ;; compile support
  (setq-local next-error-function #'diff-next-error)

  (setq-local beginning-of-defun-function #'diff-beginning-of-file-and-junk)
  (setq-local end-of-defun-function #'diff-end-of-file)

  (diff-setup-whitespace)

  ;; read-only setup
  (when diff-default-read-only
    (setq buffer-read-only t))
  (when buffer-read-only
    (setq diff-mode-read-only t))
  (add-hook 'read-only-mode-hook
            (lambda ()
              (setq diff-mode-read-only buffer-read-only))
            nil t)

  ;; setup change hooks
  (if (not diff-update-on-the-fly)
      (add-hook 'write-contents-functions #'diff-write-contents-hooks nil t)
    (setq diff--track-changes
          (track-changes-register #'diff--track-changes-signal :nobefore t)))

  ;; add-log support
  (setq-local add-log-current-defun-function #'diff-current-defun)
  (setq-local add-log-buffer-file-name-function
              (lambda () (diff-find-file-name nil 'noprompt)))
  (add-function :filter-return (local 'filter-buffer-substring-function)
                #'diff--filter-substring)
  (unless buffer-file-name
    (hack-dir-local-variables-non-file-buffer))
  (diff-setup-buffer-type))

;;;###autoload
(define-minor-mode diff-minor-mode
  "Toggle Diff minor mode.

\\{diff-minor-mode-map}"
  :group 'diff-mode :lighter " Diff"
  ;; FIXME: setup font-lock
  (when diff--track-changes
    (track-changes-unregister diff--track-changes)
    (setq diff--track-changes nil))
  (remove-hook 'write-contents-functions #'diff-write-contents-hooks t)
  (when diff-minor-mode
    (if (not diff-update-on-the-fly)
        (add-hook 'write-contents-functions #'diff-write-contents-hooks nil t)
      (setq diff--track-changes
            (track-changes-register #'diff--track-changes-signal
                                    :nobefore t)))))

;;; Handy hook functions ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun diff-setup-whitespace ()
  "Set up Whitespace mode variables for the current Diff mode buffer.
This sets `whitespace-style' and `whitespace-trailing-regexp' so
that Whitespace mode shows trailing whitespace problems on the
modified lines of the diff."
  (setq-local whitespace-style diff-whitespace-style)
  (let ((style (save-excursion
		 (goto-char (point-min))
                 ;; FIXME: For buffers filled from async processes, this search
                 ;; will simply fail because the buffer is still empty :-(
		 (when (re-search-forward diff-hunk-header-re nil t)
		   (goto-char (match-beginning 0))
		   (diff-hunk-style)))))
    (setq-local whitespace-trailing-regexp
                (if (eq style 'context)
                    "^[-+!] .*?\\([\t ]+\\)$"
                  "^[-+!<>].*?\\([\t ]+\\)$"))))

(defun diff-setup-buffer-type ()
  "Try to guess the `diff-buffer-type' from content of current Diff mode buffer.
`outline-regexp' is updated accordingly."
  (save-excursion
    (goto-char (point-min))
    (setq-local diff-buffer-type
                (if (re-search-forward "^diff --git" nil t)
                    'git
                  (if (re-search-forward "^diff -r.*-r" nil t)
                      'hg
                    nil))))
  (when (eq diff-buffer-type 'git)
    (setq-local diff-outline-regexp
          (concat "\\(^diff --git.*\\|" diff-hunk-header-re "\\)")))
  (setq-local outline-level #'diff--outline-level)
  (setq-local outline-regexp diff-outline-regexp))

(defun diff-delete-if-empty ()
  ;; An empty diff file means there's no more diffs to integrate, so we
  ;; can just remove the file altogether.  Very handy for .rej files if we
  ;; remove hunks as we apply them.
  (when (and buffer-file-name
	     (eq 0 (file-attribute-size (file-attributes buffer-file-name))))
    (delete-file buffer-file-name)))

(defun diff-delete-empty-files ()
  "Arrange for empty diff files to be removed."
  (add-hook 'after-save-hook #'diff-delete-if-empty nil t))

(defun diff-make-unified ()
  "Turn context diffs into unified diffs if applicable."
  (if (save-excursion
	(goto-char (point-min))
	(and (looking-at diff-hunk-header-re) (eq (char-after) ?*)))
      (let ((mod (buffer-modified-p)))
	(unwind-protect
	    (diff-context->unified (point-min) (point-max))
	  (restore-buffer-modified-p mod)))))

;;;
;;; Misc operations that have proved useful at some point.
;;;

(defun diff-next-complex-hunk ()
  "Jump to the next \"complex\" hunk.
\"Complex\" is approximated by \"the hunk changes the number of lines\".
Only works for unified diffs."
  (interactive)
  (while
      (and (re-search-forward diff-hunk-header-re-unified nil t)
	   (equal (match-string 2) (match-string 4)))))

(defun diff-sanity-check-context-hunk-half (lines)
  (let ((count lines))
    (while
        (cond
         ((and (memq (char-after) '(?\s ?! ?+ ?-))
               (memq (char-after (1+ (point))) '(?\s ?\t)))
          (decf count) t)
         ((or (zerop count) (= count lines)) nil)
         ((memq (char-after) '(?! ?+ ?-))
          (if (not (and (eq (char-after (1+ (point))) ?\n)
                        (y-or-n-p "Try to auto-fix whitespace loss damage? ")))
              (error "End of hunk ambiguously marked")
            (forward-char 1) (insert " ") (forward-line -1) t))
         ((< lines 0)
          (error "End of hunk ambiguously marked"))
         ((not (y-or-n-p "Try to auto-fix whitespace loss and word-wrap damage? "))
          (error "Abort!"))
         ((eolp) (insert "  ") (forward-line -1) t)
         (t (insert " ") (delete-region (- (point) 2) (- (point) 1)) t))
      (forward-line))))

(defun diff-sanity-check-hunk ()
  (let (;; Every modification is protected by a y-or-n-p, so it's probably
        ;; OK to override a read-only setting.
        (inhibit-read-only t))
    (save-excursion
      (cond
       ((not (looking-at diff-hunk-header-re))
        (error "Not recognizable hunk header"))

       ;; A context diff.
       ((eq (char-after) ?*)
        (if (not (looking-at "\\*\\{15\\}\\(?: .*\\)?\n\\*\\*\\* \\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\*\\*\\*\\*"))
            (error "Unrecognized context diff first hunk header format")
          (forward-line 2)
          (diff-sanity-check-context-hunk-half
	   (if (match-end 2)
	       (1+ (- (string-to-number (match-string 2))
		      (string-to-number (match-string 1))))
	     1))
          (if (not (looking-at diff-context-mid-hunk-header-re))
              (error "Unrecognized context diff second hunk header format")
            (forward-line)
            (diff-sanity-check-context-hunk-half
	     (if (match-end 2)
		 (1+ (- (string-to-number (match-string 2))
			(string-to-number (match-string 1))))
	       1)))))

       ;; A unified diff.
       ((eq (char-after) ?@)
        (if (not (looking-at diff-hunk-header-re-unified))
            (error "Unrecognized unified diff hunk header format")
          (let ((before (string-to-number (or (match-string 2) "1")))
                (after (string-to-number (or (match-string 4) "1"))))
            (forward-line)
            (while
                (pcase (char-after)
                  (?\s (decf before) (decf after) t)
                  (?-
                   (cond
                    ((and (looking-at diff-separator-re)
                          (zerop before) (zerop after))
                     nil)
                    ((and (looking-at diff-file-header-re)
                          (zerop before) (zerop after))
                     ;; No need to query: this is a case where two patches
                     ;; are concatenated and only counting the lines will
                     ;; give the right result.  Let's just add an empty
                     ;; line so that our code which doesn't count lines
                     ;; will not get confused.
                     (save-excursion (insert "\n")) nil)
                    (t
                     (decf before) t)))
                  (?+ (decf after) t)
                  (_
                   (cond
                    ((and diff-valid-unified-empty-line
                          ;; Not just (eolp) so we don't infloop at eob.
                          (eq (char-after) ?\n)
                          (> before 0) (> after 0))
                     (decf before) (decf after) t)
                    ((and (zerop before) (zerop after)) nil)
                    ((or (< before 0) (< after 0))
                     (error (if (or (zerop before) (zerop after))
                                "End of hunk ambiguously marked"
                              "Hunk seriously messed up")))
                    ((not (y-or-n-p (concat "Try to auto-fix " (if (eolp) "whitespace loss" "word-wrap damage") "? ")))
                     (error "Abort!"))
                    ((eolp) (insert " ") (forward-line -1) t)
                    (t (insert " ")
                       (delete-region (- (point) 2) (- (point) 1)) t))))
              (forward-line)))))

       ;; A plain diff.
       (t
        ;; TODO.
        )))))

(defun diff-hunk-text (hunk destp char-offset)
  "Return the literal source text from HUNK as (TEXT . OFFSET).
If DESTP is nil, TEXT is the source, otherwise the destination text.
CHAR-OFFSET is a char-offset in HUNK, and OFFSET is the corresponding
char-offset in TEXT."
  (with-temp-buffer
    (insert hunk)
    (goto-char (point-min))
    (let ((src-pos nil)
	  (dst-pos nil)
	  (divider-pos nil)
	  (num-pfx-chars 2))
      ;; Set the following variables:
      ;;  SRC-POS     buffer pos of the source part of the hunk or nil if none
      ;;  DST-POS     buffer pos of the destination part of the hunk or nil
      ;;  DIVIDER-POS buffer pos of any divider line separating the src & dst
      ;;  NUM-PFX-CHARS  number of line-prefix characters used by this format"
      (cond ((looking-at "^@@")
	     ;; unified diff
	     (setq num-pfx-chars 1)
	     (forward-line 1)
	     (setq src-pos (point) dst-pos (point)))
	    ((looking-at "^\\*\\*")
	     ;; context diff
	     (forward-line 2)
	     (setq src-pos (point))
	     (re-search-forward diff-context-mid-hunk-header-re nil t)
	     (forward-line 0)
	     (setq divider-pos (point))
	     (forward-line 1)
	     (setq dst-pos (point)))
	    ((looking-at "^[0-9]+a[0-9,]+$")
	     ;; normal diff, insert
	     (forward-line 1)
	     (setq dst-pos (point)))
	    ((looking-at "^[0-9,]+d[0-9]+$")
	     ;; normal diff, delete
	     (forward-line 1)
	     (setq src-pos (point)))
	    ((looking-at "^[0-9,]+c[0-9,]+$")
	     ;; normal diff, change
	     (forward-line 1)
	     (setq src-pos (point))
	     (re-search-forward "^---$" nil t)
	     (forward-line 0)
	     (setq divider-pos (point))
	     (forward-line 1)
	     (setq dst-pos (point)))
	    (t
	     (error "Unknown diff hunk type")))

      (if (if destp (null dst-pos) (null src-pos))
	  ;; Implied empty text
	  (if char-offset '("" . 0) "")

	;; For context diffs, either side can be empty, (if there's only
	;; added or only removed text).  We should then use the other side.
	(cond ((equal src-pos divider-pos) (setq src-pos dst-pos))
	      ((equal dst-pos (point-max)) (setq dst-pos src-pos)))

	(when char-offset (goto-char (+ (point-min) char-offset)))

	;; Get rid of anything except the desired text.
	(save-excursion
	  ;; Delete unused text region
	  (let ((keep (if destp dst-pos src-pos)))
	    (when (and divider-pos (> divider-pos keep))
	      (delete-region divider-pos (point-max)))
	    (delete-region (point-min) keep))
	  ;; Remove line-prefix characters, and unneeded lines (unified diffs).
          ;; Also skip lines like "\ No newline at end of file"
	  (let ((kill-chars (list (if destp ?- ?+) ?\\))
                curr-char last-char)
	    (goto-char (point-min))
	    (while (not (eobp))
	      (setq curr-char (char-after))
	      (if (memq curr-char kill-chars)
		  (delete-region
		   ;; Check for "\ No newline at end of file"
		   (if (and (eq curr-char ?\\)
			    (not (eq last-char (if destp ?- ?+)))
			    (save-excursion
			      (forward-line 1)
			      (or (eobp) (and (eq last-char ?-)
					      (eq (char-after) ?+)))))
		       (max (1- (point)) (point-min))
		     (point))
		   (progn (forward-line 1) (point)))
		(delete-char num-pfx-chars)
		(forward-line 1))
	      (setq last-char curr-char))))

	(let ((text (buffer-substring-no-properties (point-min) (point-max))))
	  (if char-offset (cons text (- (point) (point-min))) text))))))


(defun diff-find-text (text)
  "Return the buffer position (BEG . END) of the nearest occurrence of TEXT.
If TEXT isn't found, nil is returned."
  (let* ((orig (point))
	 (forw (and (search-forward text nil t)
		    (cons (match-beginning 0) (match-end 0))))
	 (back (and (goto-char (+ orig (length text)))
		    (search-backward text nil t)
		    (cons (match-beginning 0) (match-end 0)))))
    ;; Choose the closest match.
    (if (and forw back)
	(if (> (- (car forw) orig) (- orig (car back))) back forw)
      (or back forw))))

(defun diff-find-approx-text (text)
  "Return the buffer position (BEG . END) of the nearest occurrence of TEXT.
Whitespace differences are ignored."
  (let* ((orig (point))
	 (re (concat "^[ \t\n]*"
		     (mapconcat #'regexp-quote (split-string text) "[ \t\n]+")
		     "[ \t\n]*\n"))
	 (forw (and (re-search-forward re nil t)
		    (cons (match-beginning 0) (match-end 0))))
	 (back (and (goto-char (+ orig (length text)))
		    (re-search-backward re nil t)
		    (cons (match-beginning 0) (match-end 0)))))
    ;; Choose the closest match.
    (if (and forw back)
	(if (> (- (car forw) orig) (- orig (car back))) back forw)
      (or back forw))))

(define-obsolete-function-alias 'diff-xor #'xor "27.1")

(defun diff-find-source-location (&optional other-file reverse noprompt)
  "Find current diff location within the source file.
OTHER-FILE, if non-nil, means to look at the diff's name and line
  numbers for the old file.  Furthermore, use `diff-vc-revisions'
  if it's available.  If `diff-jump-to-old-file' is non-nil, the
  sense of this parameter is reversed.  If the prefix argument is
  8 or more, `diff-jump-to-old-file' is set to OTHER-FILE.
REVERSE, if non-nil, switches the sense of SRC and DST (see below).
NOPROMPT, if non-nil, means not to prompt the user.
Return a list (BUF LINE-OFFSET (BEG . END) SRC DST SWITCHED).
BUF is the buffer corresponding to the source file.
LINE-OFFSET is the offset between the expected and actual positions
  of the text of the hunk or nil if the text was not found.
\(BEG . END) is a pair indicating the position of the text in the buffer.
SRC and DST are the two variants of text as returned by `diff-hunk-text'.
  SRC is the variant that was found in the buffer.
SWITCHED is non-nil if the patch is already applied."
  (save-excursion
    (let* ((other (xor other-file diff-jump-to-old-file))
	   (char-offset (- (point) (diff-beginning-of-hunk t)))
           ;; Check that the hunk is well-formed.  Otherwise diff-mode and
           ;; the user may disagree on what constitutes the hunk
           ;; (e.g. because an empty line truncates the hunk mid-course),
           ;; leading to potentially nasty surprises for the user.
	   ;;
	   ;; Suppress check when NOPROMPT is non-nil (Bug#3033).
           (_ (unless noprompt (diff-sanity-check-hunk)))
	   (hunk (buffer-substring
                  (point) (save-excursion (diff-end-of-hunk) (point))))
	   (old (diff-hunk-text hunk reverse char-offset))
	   (new (diff-hunk-text hunk (not reverse) char-offset))
	   ;; Find the location specification.
	   (line (if (not (looking-at "\\(?:\\*\\{15\\}.*\n\\)?[-@* ]*\\([0-9,]+\\)\\([ acd+]+\\([0-9,]+\\)\\)?"))
		     (error "Can't find the hunk header")
		   (if other (match-string 1)
		     (if (match-end 3) (match-string 3)
		       (unless (re-search-forward
                                diff-context-mid-hunk-header-re nil t)
			 (error "Can't find the hunk separator"))
		       (match-string 1)))))
	   (file (or (diff-find-file-name other noprompt)
                     (error "Can't find the file")))
	   (revision (and other diff-vc-backend
                          (if reverse (nth 1 diff-vc-revisions)
                            (or (nth 0 diff-vc-revisions)
                                ;; When diff shows changes in working revision
                                (vc-working-revision file)))))
	   (buf (if revision
                    (let ((vc-find-revision-no-save t))
                      (vc-find-revision (expand-file-name file) revision diff-vc-backend))
                  ;; NOPROMPT is only non-nil when called from
                  ;; `which-function-mode', so avoid "File x changed
                  ;; on disk. Reread from disk?" warnings.
                  (find-file-noselect file noprompt))))
      ;; Update the user preference if he so wished.
      (when (> (prefix-numeric-value other-file) 8)
	(setq diff-jump-to-old-file other))
      (with-current-buffer buf
        (goto-char (point-min)) (forward-line (1- (string-to-number line)))
	(let* ((orig-pos (point))
	       (switched nil)
	       (maybe-old (diff-find-text (car old)))
	       (maybe-new (diff-find-text (car new)))
	       (pos (or (and maybe-new maybe-old (null reverse) (setq switched t) maybe-new)
			maybe-old
			(progn (setq switched t) maybe-new)
			(progn (setq switched nil)
			       (condition-case nil
				   (diff-find-approx-text (car old))
				 (invalid-regexp nil)))	;Regex too big.
			(progn (setq switched t)
			       (condition-case nil
				   (diff-find-approx-text (car new))
				 (invalid-regexp nil)))	;Regex too big.
			(progn (setq switched nil) nil))))
	  (nconc
	   (list buf)
	   (if pos
	       (list (count-lines orig-pos (car pos)) pos)
	     (list nil (cons orig-pos (+ orig-pos (length (car old))))))
	   (if switched (list new old t) (list old new))))))))


(defun diff-hunk-status-msg (line-offset reversed dry-run)
  (let ((msg (if dry-run
		 (if reversed "already applied" "not yet applied")
	       (if reversed "undone" "applied"))))
    (message (cond ((null line-offset) "Hunk text not found")
		   ((= line-offset 0) "Hunk %s")
		   ((= line-offset 1) "Hunk %s at offset %d line")
		   (t "Hunk %s at offset %d lines"))
	     msg line-offset)))

(defvar diff-apply-hunk-to-backup-file nil)

(defun diff-apply-hunk (&optional reverse)
  "Apply the current hunk to the source file and go to the next.
By default, the new source file is patched, but if the variable
`diff-jump-to-old-file' is non-nil, then the old source file is
patched instead (some commands, such as `diff-goto-source' can change
the value of this variable when given an appropriate prefix argument).

With a prefix argument, REVERSE the hunk."
  (interactive "P")
  (diff-beginning-of-hunk t)
  (pcase-let* (;; Do not accept BUFFER.REV buffers as source location.
               (diff-vc-backend nil)
               ;; When we detect deletion, we will use the old file name.
               (deletion (equal null-device (car (diff-hunk-file-names reverse))))
               (`(,buf ,line-offset ,pos ,old ,new ,switched)
               ;; Sometimes we'd like to have the following behavior: if
               ;; REVERSE go to the new file, otherwise go to the old.
               ;; But that means that by default we use the old file, which is
               ;; the opposite of the default for diff-goto-source, and is thus
               ;; confusing.  Also when you don't know about it it's
               ;; pretty surprising.
               ;; TODO: make it possible to ask explicitly for this behavior.
               ;;
               ;; This is duplicated in diff-test-hunk.
               (diff-find-source-location (xor deletion reverse) reverse)))
    (cond
     ((null line-offset)
      (user-error "Can't find the text to patch"))
     ((with-current-buffer buf
        (and buffer-file-name
             (backup-file-name-p buffer-file-name)
             (not diff-apply-hunk-to-backup-file)
             (not (setq-local diff-apply-hunk-to-backup-file
                              (yes-or-no-p (format "Really apply this hunk to %s? "
                                                   (file-name-nondirectory
                                                    buffer-file-name)))))))
      (user-error "%s"
	     (substitute-command-keys
              (format "Use %s\\[diff-apply-hunk] to apply it to the other file"
                      (if (not reverse) "\\[universal-argument] ")))))
     ((and switched
	   ;; A reversed patch was detected, perhaps apply it in reverse.
	   (not (save-window-excursion
		  (pop-to-buffer buf)
		  (goto-char (+ (car pos) (cdr old)))
		  (y-or-n-p
		   (if reverse
		       "Hunk hasn't been applied yet; apply it now? "
		     "Hunk has already been applied; undo it? ")))))
      (message "(Nothing done)"))
     ((and deletion (not switched))
      (when (y-or-n-p (format-message "Delete file `%s'?" (buffer-file-name buf)))
        (delete-file (buffer-file-name buf) delete-by-moving-to-trash)
        (kill-buffer buf)))
     (t
      ;; Apply the hunk
      (with-current-buffer buf
	(goto-char (car pos))
	(delete-region (car pos) (cdr pos))
	(insert (car new)))
      ;; Display BUF in a window
      (set-window-point (display-buffer buf) (+ (car pos) (cdr new)))
      (diff-hunk-status-msg line-offset (xor switched reverse) nil)
      (when diff-advance-after-apply-hunk
	(diff-hunk-next))))))


(defun diff-test-hunk (&optional reverse)
  "See whether it's possible to apply the current hunk.
With a prefix argument, try to REVERSE the hunk."
  (interactive "P")
  (pcase-let ((`(,buf ,line-offset ,pos ,src ,_dst ,switched)
               (diff-find-source-location nil reverse)))
    (set-window-point (display-buffer buf) (+ (car pos) (cdr src)))
    (diff-hunk-status-msg line-offset (xor reverse switched) t)))


(defun diff-kill-applied-hunks ()
  "Kill all hunks that have already been applied starting at point."
  (interactive)
  (while (not (eobp))
    (pcase-let ((`(,_buf ,line-offset ,_pos ,_src ,_dst ,switched)
                 (diff-find-source-location nil nil)))
      (if (and line-offset switched)
          (diff-hunk-kill)
        (diff-hunk-next)))))

(defcustom diff-ask-before-revert-and-kill-hunk t
  "If non-nil, `diff-revert-and-kill-hunk' will ask for confirmation."
  :type 'boolean
  :version "31.1")

(defun diff-revert-and-kill-hunk ()
  "Reverse-apply and then kill the hunk at point.  Save changed buffer.

This command is useful in buffers generated by \\[vc-diff] and \\[vc-root-diff],
especially when preparing to commit the patch with \\[vc-next-action].
You can use \\<diff-mode-map>\\[diff-hunk-kill] to temporarily remove changes that you intend to
include in a separate commit or commits, and you can use this command
to permanently drop changes you didn't intend, or no longer want.

This is a destructive operation, so by default, this command asks you to
confirm you really want to reverse-apply and kill the hunk.  You can
customize `diff-ask-before-revert-and-kill-hunk' to control that."
  (interactive)
  (when (or (not diff-ask-before-revert-and-kill-hunk)
            (yes-or-no-p "Really reverse-apply and kill this hunk?"))
    (cl-destructuring-bind (beg end) (diff-bounds-of-hunk)
      (when (null (diff-apply-buffer beg end t))
        (diff-hunk-kill)))))

(defun diff-apply-buffer (&optional beg end reverse)
  "Apply the diff in the entire diff buffer.
Interactively, if the region is active, apply all hunks that the region
overlaps; otherwise, apply all hunks.
With a prefix argument, reverse-apply the hunks.
If applying all hunks succeeds, save the changed buffers.

When called from Lisp with optional arguments, restrict the application
to hunks lying between BEG and END, and reverse-apply them when REVERSE
is non-nil.  Returns nil if buffers were successfully modified and
saved, or the number of failed hunk applications otherwise."
  (interactive (list (use-region-beginning)
                     (use-region-end)
                     current-prefix-arg))
  (let ((buffer-edits nil)
        (failures 0)
        (diff-refine nil))
    (save-excursion
      (goto-char (or beg (point-min)))
      (diff-beginning-of-hunk t)
      (while (pcase-let ((`(,buf ,line-offset ,pos ,_src ,dst ,switched)
                          (diff-find-source-location nil reverse)))
               (cond ((and line-offset (not switched))
                      (push (cons pos dst)
                            (alist-get buf buffer-edits)))
                     (t (setq failures (1+ failures))))
               (and (not (eq (prog1 (point) (ignore-errors (diff-hunk-next)))
                             (point)))
                    (or (not end) (< (point) end))
                    (looking-at-p diff-hunk-header-re)))))
    (cond ((zerop failures)
           (dolist (buf-edits (reverse buffer-edits))
             (with-current-buffer (car buf-edits)
               (dolist (edit (cdr buf-edits))
                 (let ((pos (car edit))
                       (dst (cdr edit))
                       (inhibit-read-only t))
                   (goto-char (car pos))
                   (delete-region (car pos) (cdr pos))
                   (insert (car dst))))
               (save-buffer)))
           (message "Saved %d buffers" (length buffer-edits))
           nil)
          (t
           (message (ngettext "%d hunk failed; no buffers changed"
                              "%d hunks failed; no buffers changed"
                              failures)
                    failures)
           failures))))

(defalias 'diff-mouse-goto-source #'diff-goto-source)

(defun diff-goto-source (&optional other-file event)
  "Jump to the corresponding source line.
`diff-jump-to-old-file' (or its opposite if the OTHER-FILE prefix arg
is given) determines whether to jump to the old or the new file.
If the prefix arg is bigger than 8 (for example with \\[universal-argument] \\[universal-argument])
then `diff-jump-to-old-file' is also set, for the next invocations.

Under version control, the OTHER-FILE prefix arg means jump to the old
revision of the file if point is on an old changed line, or to the new
revision of the file otherwise."
  (interactive (list current-prefix-arg last-input-event))
  ;; When pointing at a removal line, we probably want to jump to
  ;; the old location, and else to the new (i.e. as if reverting).
  ;; This is a convenient detail when using smerge-diff.
  (if event (posn-set-point (event-end event)))
  (let ((buffer (when event (current-buffer)))
        (reverse (not (save-excursion (beginning-of-line) (looking-at "[-<]")))))
    (pcase-let ((`(,buf ,_line-offset ,pos ,src ,_dst ,_switched)
                 (diff-find-source-location other-file reverse)))
      (pop-to-buffer buf)
      (goto-char (+ (car pos) (cdr src)))
      (when buffer (next-error-found buffer (current-buffer))))))

(defun diff-kill-ring-save (beg end &optional reverse)
  "Save to `kill-ring' the result of applying diffs in region between BEG and END.
By default the command will copy the text that applying the diff would
produce, along with the text between hunks.  If REVERSE is non-nil, or
the command was invoked with a prefix argument, copy the lines that the
diff would remove (beginning with \"+\" or \"<\")."
  (interactive
   (append (if (use-region-p)
               (list (region-beginning) (region-end))
             (save-excursion
               (list (diff-beginning-of-hunk)
                     (diff-end-of-hunk))))
           (list current-prefix-arg)))
  (unless (derived-mode-p 'diff-mode)
    (user-error "Command can only be invoked in a diff-buffer"))
  (let ((parts '()))
    (save-excursion
      (goto-char beg)
      (catch 'break
        (while t
          (let ((hunk (diff-hunk-text
                       (buffer-substring
                        (save-excursion (diff-beginning-of-hunk))
                        (save-excursion (min (diff-end-of-hunk) end)))
                       (not reverse)
                       (save-excursion
                         (- (point) (diff-beginning-of-hunk))))))
            (push (substring (car hunk) (cdr hunk))
                  parts))
          ;; check if we have copied everything
          (diff-end-of-hunk)
          (when (<= end (point)) (throw 'break t))
          ;; copy the text between hunks
          (let ((inhibit-message t) start)
            (save-window-excursion
              (save-excursion
                (forward-line -1)
                ;; FIXME: Detect if the line we jump to doesn't match
                ;; the line in the diff.
                (diff-goto-source t)
                (forward-line +1)
                (setq start (point))))
            (save-window-excursion
              (diff-goto-source t)
              (push (buffer-substring start (point))
                    parts))))))
    (kill-new (string-join (nreverse parts)))
    (setq deactivate-mark t)
    (message (if reverse "Copied original text" "Copied modified text"))))

(defun diff-current-defun ()
  "Find the name of function at point.
For use in `add-log-current-defun-function'."
  ;; Kill change-log-default-name so it gets recomputed each time, since
  ;; each hunk may belong to another file which may belong to another
  ;; directory and hence have a different ChangeLog file.
  (kill-local-variable 'change-log-default-name)
  (save-excursion
    (when (looking-at diff-hunk-header-re)
      (forward-line 1)
      (re-search-forward "^[^ ]" nil t))
    (pcase-let ((`(,buf ,_line-offset ,pos ,src ,dst ,switched)
                 (ignore-errors         ;Signals errors in place of prompting.
                   ;; Use `noprompt' since this is used in which-function-mode
                   ;; and such.
                   (diff-find-source-location nil nil 'noprompt))))
      (when buf
        (beginning-of-line)
        (or (when (memq (char-after) '(?< ?-))
              ;; Cursor is pointing at removed text.  This could be a removed
              ;; function, in which case, going to the source buffer will
              ;; not help since the function is now removed.  Instead,
              ;; try to figure out the function name just from the
              ;; code-fragment.
              (let ((old (if switched dst src)))
                (with-temp-buffer
                  (insert (car old))
                  (funcall (buffer-local-value 'major-mode buf))
                  (goto-char (+ (point-min) (cdr old)))
                  (add-log-current-defun))))
            (with-current-buffer buf
              (goto-char (+ (car pos) (cdr src)))
              (add-log-current-defun)))))))

(defun diff-ignore-whitespace-hunk (&optional whole-buffer)
  "Re-diff the current hunk, ignoring whitespace differences.
With non-nil prefix arg, re-diff all the hunks."
  (interactive "P")
  (if whole-buffer
      (diff--ignore-whitespace-all-hunks)
    (diff-refresh-hunk t)))

(defun diff-refresh-hunk (&optional ignore-whitespace)
  "Re-diff the current hunk."
  (interactive)
  (let* ((char-offset (- (point) (diff-beginning-of-hunk t)))
	 (opt-type (pcase (char-after)
                     (?@ "-u")
                     (?* "-c")))
	 (line-nb (and (or (looking-at "[^0-9]+\\([0-9]+\\)")
			   (error "Can't find line number"))
		       (string-to-number (match-string 1))))
	 (inhibit-read-only t)
	 (hunk (delete-and-extract-region
		(point) (save-excursion (diff-end-of-hunk) (point))))
	 (lead (make-string (1- line-nb) ?\n)) ;Line nums start at 1.
	 (file1 (make-temp-file "diff1"))
	 (file2 (make-temp-file "diff2"))
	 (coding-system-for-read buffer-file-coding-system)
	 opts old new)
    (when ignore-whitespace
      (setq opts (ensure-list diff-ignore-whitespace-switches)))
    (when opt-type
      (setq opts (cons opt-type opts)))

    (unwind-protect
	(save-excursion
	  (setq old (diff-hunk-text hunk nil char-offset))
	  (setq new (diff-hunk-text hunk t char-offset))
	  (write-region (concat lead (car old)) nil file1 nil 'nomessage)
	  (write-region (concat lead (car new)) nil file2 nil 'nomessage)
	  (with-temp-buffer
	    (let ((status
		   (apply #'call-process
			  `(,diff-command nil t nil
			                 ,@opts ,file1 ,file2))))
	      (pcase status
		(0 nil)                 ;Nothing to reformat.
		(1 (goto-char (point-min))
                   ;; Remove the file-header.
                   (when (re-search-forward diff-hunk-header-re nil t)
                     (delete-region (point-min) (match-beginning 0))))
		(_ (goto-char (point-max))
		   (unless (bolp) (insert "\n"))
		   (insert hunk)))
	      (setq hunk (buffer-string))
	      (unless (memq status '(0 1))
		(error "Diff returned: %s" status)))))
      ;; Whatever happens, put back some equivalent text: either the new
      ;; one or the original one in case some error happened.
      (insert hunk)
      (delete-file file1)
      (delete-file file2))))

;;; Fine change highlighting.

(defface diff-refine-changed
  '((((class color) (min-colors 88) (background light))
     :background "#ffff55")
    (((class color) (min-colors 88) (background dark))
     :background "#aaaa22")
    (t :inverse-video t))
  "Face used for char-based changes shown by `diff-refine-hunk'.")

(defface diff-refine-removed
  '((default
     :inherit diff-refine-changed)
    (((class color) (min-colors 257) (background light))
     :background "#ffcccc")
    (((class color) (min-colors 88) (background light))
     :background "#ffbbbb")
    (((class color) (min-colors 88) (background dark))
     :background "#aa2222"))
  "Face used for removed characters shown by `diff-refine-hunk'."
  :version "24.3")

(defface diff-refine-added
  '((default
     :inherit diff-refine-changed)
    (((class color) (min-colors 257) (background light))
     :background "#bbffbb")
    (((class color) (min-colors 88) (background light))
     :background "#aaffaa")
    (((class color) (min-colors 88) (background dark))
     :background "#22aa22"))
  "Face used for added characters shown by `diff-refine-hunk'."
  :version "24.3")

(defun diff-refine-preproc ()
  (while (re-search-forward "^[+>]" nil t)
    ;; Remove spurious changes due to the fact that one side of the hunk is
    ;; marked with leading + or > and the other with leading - or <.
    ;; We used to replace all the prefix chars with " " but this only worked
    ;; when we did char-based refinement (or when using
    ;; smerge-refine-weight-hack) since otherwise, the `forward' motion done
    ;; in chopup do not necessarily do the same as the ones in highlight
    ;; since the "_" is not treated the same as " ".
    (replace-match (cdr (assq (char-before) '((?+ . "-") (?> . "<"))))))
  )

(defun diff--forward-while-leading-char (char bound)
  "Move point until reaching a line not starting with CHAR.
Return new point, if it was moved."
  (let ((pt nil))
    (while (and (< (point) bound) (eql (following-char) char))
      (forward-line 1)
      (setq pt (point)))
    pt))

(defun diff-refine-hunk ()
  "Highlight changes of hunk at point at a finer granularity."
  (interactive)
  (when (diff--some-hunks-p)
    (save-excursion
      (let ((beg (diff-beginning-of-hunk t))
            ;; Be careful to start from the hunk header so diff-end-of-hunk
            ;; gets to read the hunk header's line info.
            (end (progn (diff-end-of-hunk) (point))))
        (diff--refine-hunk beg end)))))

(defun diff--refine-propertize (beg end face)
  (let ((ol (make-overlay beg end)))
    (overlay-put ol 'diff-mode 'fine)
    (overlay-put ol 'evaporate t)
    (overlay-put ol 'face face)))

(defcustom diff-refine-nonmodified nil
  "If non-nil, also highlight the added/removed lines as \"refined\".
The lines highlighted when this is non-nil are those that were
added or removed in their entirety, as opposed to lines some
parts of which were modified.  The added lines are highlighted
using the `diff-refine-added' face, while the removed lines are
highlighted using the `diff-refine-removed' face.
This is currently implemented only for diff formats supported
by `diff-refine-hunk'."
  :version "30.1"
  :type 'boolean)

(defun diff--refine-hunk (start end)
  (require 'smerge-mode)
  (goto-char start)
  (let* ((style (diff-hunk-style))      ;Skips the hunk header as well.
         (beg (point))
         (props-c '((diff-mode . fine) (face . diff-refine-changed)))
         (props-r '((diff-mode . fine) (face . diff-refine-removed)))
         (props-a '((diff-mode . fine) (face . diff-refine-added))))

    (remove-overlays beg end 'diff-mode 'fine)

    (goto-char beg)
    (pcase style
      ('unified
       (while (re-search-forward "^[-+]" end t)
         (let ((beg-del (progn (beginning-of-line) (point)))
               beg-add end-add)
           (cond
            ((eq (char-after) ?+)
             (diff--forward-while-leading-char ?+ end)
             (when diff-refine-nonmodified
               (diff--refine-propertize beg-del (point) 'diff-refine-added)))
            ((and (diff--forward-while-leading-char ?- end)
                  ;; Allow for "\ No newline at end of file".
                  (progn (diff--forward-while-leading-char ?\\ end)
                         (setq beg-add (point)))
                  (diff--forward-while-leading-char ?+ end)
                  (progn (diff--forward-while-leading-char ?\\ end)
                         (setq end-add (point))))
             (smerge-refine-regions beg-del beg-add beg-add end-add
                                    nil #'diff-refine-preproc props-r props-a))
            (t ;; If we're here, it's because
             ;; (diff--forward-while-leading-char ?+ end) failed.
             (when diff-refine-nonmodified
              (diff--refine-propertize beg-del (point)
                                       'diff-refine-removed)))))))
      ('context
       (let* ((middle (save-excursion (re-search-forward "^---" end t)))
              (other middle))
         (when middle
           (while (re-search-forward "^\\(?:!.*\n\\)+" middle t)
             (smerge-refine-regions (match-beginning 0) (match-end 0)
                                    (save-excursion
                                      (goto-char other)
                                      (re-search-forward "^\\(?:!.*\n\\)+" end)
                                      (setq other (match-end 0))
                                      (match-beginning 0))
                                    other
                                    (if diff-use-changed-face props-c)
                                    #'diff-refine-preproc
                                    (unless diff-use-changed-face props-r)
                                    (unless diff-use-changed-face props-a)))
           (when diff-refine-nonmodified
             (goto-char beg)
             (while (re-search-forward "^\\(?:-.*\n\\)+" middle t)
               (diff--refine-propertize (match-beginning 0)
                                        (match-end 0)
                                        'diff-refine-removed))
             (goto-char middle)
             (while (re-search-forward "^\\(?:\\+.*\n\\)+" end t)
               (diff--refine-propertize (match-beginning 0)
                                        (match-end 0)
                                        'diff-refine-added))))))
      (_ ;; Normal diffs.
       (let ((beg1 (1+ (point))))
         (cond
          ((re-search-forward "^---.*\n" end t)
           ;; It's a combined add&remove, so there's something to do.
           (smerge-refine-regions beg1 (match-beginning 0)
                                  (match-end 0) end
                                  nil #'diff-refine-preproc props-r props-a))
          (diff-refine-nonmodified
           (diff--refine-propertize
            beg1 end
            (if (eq (char-after beg1) ?<)
                'diff-refine-removed 'diff-refine-added)))))))))

(defun diff--iterate-hunks (max fun)
  "Iterate over all hunks between point and MAX.
Call FUN with two args (BEG and END) for each hunk."
  (save-excursion
    (catch 'malformed
      (let* ((beg (or (ignore-errors (diff-beginning-of-hunk))
                      (ignore-errors (diff-hunk-next) (point))
                      max)))
        (while (< beg max)
          (goto-char beg)
          (unless (looking-at diff-hunk-header-re)
            (throw 'malformed nil))
          (let ((end
                 (save-excursion (diff-end-of-hunk) (point))))
            (unless (< beg end)
              (throw 'malformed nil))
            (funcall fun beg end)
            (goto-char end)
            (setq beg (if (looking-at diff-hunk-header-re)
                          end
                        (or (ignore-errors (diff-hunk-next) (point))
                            max)))))))))

;; This doesn't use `diff--iterate-hunks', since that assumes that
;; hunks don't change size.
(defun diff--ignore-whitespace-all-hunks ()
  "Re-diff all the hunks, ignoring whitespace-differences."
  (save-excursion
    (goto-char (point-min))
    (diff-hunk-next)
    (while (looking-at diff-hunk-header-re)
      (diff-refresh-hunk t))))

(defun diff--font-lock-refined (max)
  "Apply hunk refinement from font-lock."
  (when (eq diff-refine 'font-lock)
    (when (get-char-property (point) 'diff--font-lock-refined)
      ;; Refinement works over a complete hunk, whereas font-lock limits itself
      ;; to highlighting smallish chunks between point..max, so we may be
      ;; called N times for a large hunk in which case we don't want to
      ;; rehighlight that hunk N times (especially since each highlighting
      ;; of a large hunk can itself take a long time, adding insult to injury).
      ;; So, after refining a hunk (including a failed attempt), we place an
      ;; overlay over the whole hunk to mark it as refined, to avoid redoing
      ;; the job redundantly when asked to highlight subsequent parts of the
      ;; same hunk.
      (goto-char (next-single-char-property-change
                  (point) 'diff--font-lock-refined nil max)))
    ;; Ignore errors that diff cannot be found so that custom font-lock
    ;; keywords after `diff--font-lock-refined' can still be evaluated.
    (ignore-error file-missing
      (diff--iterate-hunks
       max
       (lambda (beg end)
         (unless (get-char-property beg 'diff--font-lock-refined)
           (diff--refine-hunk beg end)
           (let ((ol (make-overlay beg end)))
             (overlay-put ol 'diff--font-lock-refined t)
             (overlay-put ol 'diff-mode 'fine)
             (overlay-put ol 'evaporate t)
             (overlay-put ol 'modification-hooks
                          '(diff--overlay-auto-delete)))))))))

(defun diff--overlay-auto-delete (ol _after _beg _end &optional _len)
  (delete-overlay ol))

(defun diff-undo (&optional arg)
  "Perform `undo', ignoring the buffer's read-only status."
  (interactive "P")
  (let ((inhibit-read-only t))
    (undo arg)))

;;;###autoload
(defcustom diff-add-log-use-relative-names nil
  "Use relative file names when generating ChangeLog skeletons.
The files will be relative to the root directory of the VC
repository.  This option affects the behavior of
`diff-add-log-current-defuns'."
  :type 'boolean
  :safe #'booleanp
  :version "29.1")

(defun diff-add-log-current-defuns ()
  "Return an alist of defun names for the current diff.
The elements of the alist are of the form (FILE . (DEFUN...)),
where DEFUN... is a list of function names found in FILE.  If
`diff-add-log-use-relative-names' is non-nil, file names in the alist
are relative to the root directory of the VC repository."
  (save-excursion
    (goto-char (point-min))
    (let* ((defuns nil)
           (hunk-end nil)
           (hunk-mismatch-files nil)
           (make-defun-context-follower
            (lambda (goline)
              (let ((eodefun nil)
                    (defname nil))
                (list
                 (lambda () ;; Check for end of current defun.
                   (when (and eodefun
                              (funcall goline)
                              (>= (point) eodefun))
                     (setq defname nil)
                     (setq eodefun nil)))
                 (lambda (&optional get-current) ;; Check for new defun.
                   (if get-current
                       defname
                     (when-let* ((def (and (not eodefun)
                                           (funcall goline)
                                           (add-log-current-defun)))
                                 (eof (save-excursion
                                        (condition-case ()
                                            (progn (end-of-defun) (point))
                                          (scan-error hunk-end)))))
                       (setq eodefun eof)
                       (setq defname def)))))))))
      (while
          ;; Might need to skip over file headers between diff
          ;; hunks (e.g., "diff --git ..." etc).
          (re-search-forward diff-hunk-header-re nil t)
        (setq hunk-end (save-excursion (diff-end-of-hunk)))
        (pcase-let* ((filename (substring-no-properties
                                (if diff-add-log-use-relative-names
                                    (file-relative-name
                                     (diff-find-file-name)
                                     (vc-root-dir))
                                  (diff-find-file-name))))
                     (=lines 0)
                     (+lines 0)
                     (-lines 0)
                     (`(,buf ,line-offset (,beg . ,_end)
                             (,old-text . ,_old-offset)
                             (,new-text . ,_new-offset)
                             ,applied)
                      ;; Try to use the vc integration of
                      ;; `diff-find-source-location', unless it
                      ;; would look for non-existent files like
                      ;; /dev/null.
                      (diff-find-source-location
                       (not (equal null-device
                                   (car (diff-hunk-file-names t))))))
                     (other-buf nil)
                     (goto-otherbuf
                      ;; If APPLIED, we have NEW-TEXT in BUF, so we
                      ;; need to a buffer with OLD-TEXT to follow
                      ;; -lines.
                      (lambda ()
                        (if other-buf (set-buffer other-buf)
                          (set-buffer (generate-new-buffer " *diff-other-text*"))
                          (insert (if applied old-text new-text))
                          (let ((delay-mode-hooks t))
                            (funcall (buffer-local-value 'major-mode buf)))
                          (setq other-buf (current-buffer)))
                        (goto-char (point-min))
                        (forward-line (+ =lines -1
                                         (if applied -lines +lines)))))
                     (gotobuf (lambda ()
                                (set-buffer buf)
                                (goto-char beg)
                                (forward-line (+ =lines -1
                                                 (if applied +lines -lines)))))
                     (`(,=ck-eodefun ,=ck-defun)
                      (funcall make-defun-context-follower gotobuf))
                     (`(,-ck-eodefun ,-ck-defun)
                      (funcall make-defun-context-follower
                               (if applied goto-otherbuf gotobuf)))
                     (`(,+ck-eodefun ,+ck-defun)
                      (funcall make-defun-context-follower
                               (if applied gotobuf goto-otherbuf))))
          (unless (eql line-offset 0)
            (cl-pushnew filename hunk-mismatch-files :test #'equal))
          ;; Some modes always return nil for `add-log-current-defun',
          ;; make sure at least the filename is included.
          (unless (assoc filename defuns)
            (push (cons filename nil) defuns))
          (unwind-protect
              (while (progn (forward-line)
                            (< (point) hunk-end))
                (let ((patch-char (char-after)))
                  (pcase patch-char
                    (?+ (incf +lines))
                    (?- (incf -lines))
                    (?\s (incf =lines)))
                  (save-current-buffer
                    (funcall =ck-eodefun)
                    (funcall +ck-eodefun)
                    (funcall -ck-eodefun)
                    (when-let* ((def (cond
                                      ((eq patch-char ?\s)
                                       ;; Just updating context defun.
                                       (ignore (funcall =ck-defun)))
                                      ;; + or - in existing defun.
                                      ((funcall =ck-defun t))
                                      ;; Check added or removed defun.
                                      (t (funcall (if (eq ?+ patch-char)
                                                      +ck-defun -ck-defun))))))
                      (cl-pushnew def (alist-get filename defuns
                                                 nil nil #'equal)
                                  :test #'equal)))))
            (when (buffer-live-p other-buf)
              (kill-buffer other-buf)))))
      (when hunk-mismatch-files
        (message "Diff didn't match for %s."
                 (mapconcat #'identity hunk-mismatch-files ", ")))
      (dolist (file-defuns defuns)
        (cl-callf nreverse (cdr file-defuns)))
      (nreverse defuns))))

(defun diff-add-change-log-entries-other-window ()
  "Iterate through the current diff and create ChangeLog entries.
I.e. like `add-change-log-entry-other-window' but applied to all hunks."
  (interactive)
  ;; XXX: Currently add-change-log-entry-other-window is only called
  ;; once per hunk.  Some hunks have multiple changes, it would be
  ;; good to call it for each change.
  (save-excursion
    (goto-char (point-min))
    (condition-case nil
        ;; Call add-change-log-entry-other-window for each hunk in
        ;; the diff buffer.
        (while (progn
                 (diff-hunk-next)
                 ;; Move to where the changes are,
                 ;; `add-change-log-entry-other-window' works better in
                 ;; that case.
                 (re-search-forward
		  (concat "\n[!+<>-]"
                          ;; If the hunk is a context hunk with an empty first
                          ;; half, recognize the "--- NNN,MMM ----" line
                          "\\(-- [0-9]+\\(,[0-9]+\\)? ----\n"
                          ;; and skip to the next non-context line.
                          "\\( .*\n\\)*[+]\\)?")
                  nil t))
          (save-excursion
            ;; FIXME: this pops up windows of all the buffers.
            (add-change-log-entry nil nil t nil t)))
      ;; When there's no more hunks, diff-hunk-next signals an error.
      (error nil))))

(defun diff-delete-trailing-whitespace (&optional other-file)
  "Remove trailing whitespace from lines modified in this diff.
This edits both the current Diff mode buffer and the patched
source file(s).  If `diff-jump-to-old-file' is non-nil, edit the
original (unpatched) source file instead.  With a prefix argument
OTHER-FILE, flip the choice of which source file to edit.

If a file referenced in the diff has no buffer and needs to be
fixed, visit it in a buffer."
  (interactive "P")
  (save-excursion
    (goto-char (point-min))
    (let* ((other (xor other-file diff-jump-to-old-file))
  	   (modified-buffers nil)
  	   (style (save-excursion
  	   	    (when (re-search-forward diff-hunk-header-re nil t)
  	   	      (goto-char (match-beginning 0))
  	   	      (diff-hunk-style))))
  	   (regexp (concat "^[" (if other "-<" "+>") "!]"
  	   		   (if (eq style 'context) " " "")
  	   		   ".*?\\([ \t]+\\)$"))
	   (inhibit-read-only t)
	   (end-marker (make-marker))
	   hunk-end)
      ;; Move to the first hunk.
      (re-search-forward diff-hunk-header-re nil 1)
      (while (progn (save-excursion
		      (re-search-forward diff-hunk-header-re nil 1)
		      (setq hunk-end (point)))
		    (< (point) hunk-end))
	;; For context diffs, search only in the appropriate half of
	;; the hunk.  For other diffs, search within the entire hunk.
  	(if (not (eq style 'context))
  	    (set-marker end-marker hunk-end)
  	  (let ((mid-hunk
  		 (save-excursion
  		   (re-search-forward diff-context-mid-hunk-header-re hunk-end)
  		   (point))))
  	    (if other
  		(set-marker end-marker mid-hunk)
  	      (goto-char mid-hunk)
  	      (set-marker end-marker hunk-end))))
	(while (re-search-forward regexp end-marker t)
	  (let ((match-data (match-data)))
	    (pcase-let ((`(,buf ,line-offset ,pos ,src ,_dst ,_switched)
			 (diff-find-source-location other-file)))
	      (when line-offset
		;; Remove the whitespace in the Diff mode buffer.
		(set-match-data match-data)
		(replace-match "" t t nil 1)
		;; Remove the whitespace in the source buffer.
		(with-current-buffer buf
		  (save-excursion
		    (goto-char (+ (car pos) (cdr src)))
		    (beginning-of-line)
		    (when (re-search-forward "\\([ \t]+\\)$" (line-end-position) t)
		      (unless (memq buf modified-buffers)
			(push buf modified-buffers))
		      (replace-match ""))))))))
	(goto-char hunk-end))
      (if modified-buffers
	  (message "Deleted trailing whitespace from %s."
		   (mapconcat (lambda (buf) (format-message
					     "`%s'" (buffer-name buf)))
			      modified-buffers ", "))
	(message "No trailing whitespace to delete.")))))


;;; Prettifying from font-lock

(define-fringe-bitmap 'diff-fringe-add
  [#b00000000
   #b00000000
   #b00010000
   #b00010000
   #b01111100
   #b00010000
   #b00010000
   #b00000000
   #b00000000]
  nil nil 'center)

(define-fringe-bitmap 'diff-fringe-del
  [#b00000000
   #b00000000
   #b00000000
   #b00000000
   #b01111100
   #b00000000
   #b00000000
   #b00000000
   #b00000000]
  nil nil 'center)

(define-fringe-bitmap 'diff-fringe-rep
  [#b00000000
   #b00010000
   #b00010000
   #b00010000
   #b00010000
   #b00010000
   #b00000000
   #b00010000
   #b00000000]
  nil nil 'center)

(define-fringe-bitmap 'diff-fringe-nul
  ;; Maybe there should be such an "empty" bitmap defined by default?
  [#b00000000
   #b00000000
   #b00000000
   #b00000000
   #b00000000
   #b00000000
   #b00000000
   #b00000000
   #b00000000]
  nil nil 'center)

(defun diff--font-lock-prettify (limit)
  (when diff-font-lock-prettify
    (when (> (frame-parameter nil 'left-fringe) 0)
      (save-excursion
        ;; FIXME: Include the first space for context-style hunks!
        (while (re-search-forward "^[-+! ]" limit t)
          (unless (eq (get-text-property (match-beginning 0) 'face)
                      'diff-header)
            (put-text-property
             (match-beginning 0) (match-end 0)
             'display
             (alist-get
              (char-before)
              '((?+ . (left-fringe diff-fringe-add diff-indicator-added))
                (?- . (left-fringe diff-fringe-del diff-indicator-removed))
                (?! . (left-fringe diff-fringe-rep diff-indicator-changed))
                (?\s . (left-fringe diff-fringe-nul fringe)))))))))
    ;; Mimics the output of Magit's diff.
    ;; FIXME: This has only been tested with Git's diff output.
    ;; FIXME: Add support for Git's "rename from/to"?
    (while (re-search-forward "^diff " limit t)
      ;; We split the regexp match into a search plus a looking-at because
      ;; we want to use LIMIT for the search but we still want to match
      ;; all the header's lines even if LIMIT falls in the middle of it.
      (when (save-excursion
              (forward-line 0)
              (looking-at
               (eval-when-compile
                 (let* ((index "\\(?:index.*\n\\)?")
                        (file4 (concat
                                "\\(?:" null-device "\\|[ab]/\\(?4:.*\\)\\)"))
                        (file5 (concat
                                "\\(?:" null-device "\\|[ab]/\\(?5:.*\\)\\)"))
                        (header (concat "--- " file4 "\n"
                                        "\\+\\+\\+ " file5 "\n"))
                        (binary (concat
                                 "Binary files " file4
                                 " and " file5 " \\(?7:differ\\)\n"))
                        (horb (concat "\\(?:" header "\\|" binary "\\)?")))
                   (concat "diff.*?\\(?: a/\\(.*?\\) b/\\(.*\\)\\)?\n"
                           "\\(?:"
                           ;; For new/deleted files, there might be no
                           ;; header (and no hunk) if the file is/was empty.
                           "\\(?3:new\\(?6:\\)\\|deleted\\) file mode \\(?10:[0-7]\\{6\\}\\)\n"
                           index horb
                           ;; Normal case. There might be no header
                           ;; (and no hunk) if only the file mode
                           ;; changed.
                           "\\|"
                           "\\(?:old mode \\(?8:[0-7]\\{6\\}\\)\n\\)?"
                           "\\(?:new mode \\(?9:[0-7]\\{6\\}\\)\n\\)?"
                           index horb "\\)")))))
        ;; The file names can be extracted either from the `diff' line
        ;; or from the two header lines.  Prefer the header line info if
        ;; available since the `diff' line is ambiguous in case the
        ;; file names include " b/" or " a/".
        ;; FIXME: This prettification throws away all the information
        ;; about the index hashes.
        (let ((oldfile (or (match-string 4) (match-string 1)))
              (newfile (or (match-string 5) (match-string 2)))
              (kind (if (match-beginning 7) " BINARY"
                      (unless (or (match-beginning 4)
                                  (match-beginning 5)
                                  (not (match-beginning 3)))
                        " empty")))
              (filemode
               (cond
                ((match-beginning 10)
                 (concat " file with mode " (match-string 10) "  "))
                ((and (match-beginning 8) (match-beginning 9))
                 (concat " file (mode changed from "
                         (match-string 8) " to " (match-string 9) ")  "))
                (t " file  "))))
          (add-text-properties
           (match-beginning 0) (1- (match-end 0))
           (list 'display
                 (propertize
                  (cond
                   ((match-beginning 3)
                    (concat (capitalize (match-string 3)) kind filemode
                            (if (match-beginning 6) newfile oldfile)))
                   ((and (null (match-string 4)) (match-string 5))
                    (concat "New " kind filemode newfile))
                   ((null (match-string 2))
                    ;; We used to use
                    ;;     (concat "Deleted" kind filemode oldfile)
                    ;; here but that misfires for `diff-buffers'
                    ;; (see 24 Jun 2022 message in bug#54034).
                    ;; AFAIK if (match-string 2) is nil then so is
                    ;; (match-string 1), so "Deleted" doesn't sound right,
                    ;; so better just let the header in plain sight for now.
                    ;; FIXME: `diff-buffers' should maybe try to better
                    ;; mimic Git's format with "a/" and "b/" so prettification
                    ;; can "just work!"
                    nil)
                   (t
                    (concat "Modified" kind filemode oldfile)))
                  'face '(diff-file-header diff-header))
                 'font-lock-multiline t))))))
  nil)

;;; Syntax highlighting from font-lock

(defun diff--font-lock-syntax (max)
  "Apply source language syntax highlighting from font-lock.
Calls `diff-syntax-fontify' on every hunk found between point
and the position in MAX."
  (when diff-font-lock-syntax
    (when (get-char-property (point) 'diff--font-lock-syntax)
      (goto-char (next-single-char-property-change
                  (point) 'diff--font-lock-syntax nil max)))
    (diff--iterate-hunks
     max
     (lambda (beg end)
       (unless (get-char-property beg 'diff--font-lock-syntax)
         (diff-syntax-fontify beg end)
         (let ((ol (make-overlay beg end)))
           (overlay-put ol 'diff--font-lock-syntax t)
           (overlay-put ol 'diff-mode 'syntax)
           (overlay-put ol 'evaporate t)
           (overlay-put ol 'modification-hooks
                        '(diff--overlay-auto-delete))))))))

(defun diff-syntax-fontify (beg end)
  "Highlight source language syntax in diff hunk between BEG and END."
  (remove-overlays beg end 'diff-mode 'syntax)
  (save-excursion
    (diff-syntax-fontify-hunk beg end t)
    (diff-syntax-fontify-hunk beg end nil)))

(eval-when-compile (require 'subr-x)) ; for string-trim-right

(defvar-local diff--syntax-file-attributes nil)
(put 'diff--syntax-file-attributes 'permanent-local t)

(defvar diff--cached-revision-buffers nil
  "List of ((FILE . REVISION) . BUFFER) in MRU order.")

(defvar diff--cache-clean-timer nil)
(defconst diff--cache-clean-interval 3600)  ; seconds

(defun diff--cache-clean ()
  "Discard the least recently used half of the cache."
  (let ((n (/ (length diff--cached-revision-buffers) 2)))
    (mapc #'kill-buffer (mapcar #'cdr (nthcdr n diff--cached-revision-buffers)))
    (setq diff--cached-revision-buffers
          (ntake n diff--cached-revision-buffers)))
  (diff--cache-schedule-clean))

(defun diff--cache-schedule-clean ()
  (setq diff--cache-clean-timer
        (and diff--cached-revision-buffers
             (run-with-timer diff--cache-clean-interval nil
                             #'diff--cache-clean))))

(defun diff--get-revision-properties (file revision text line-nb)
  "Get font-lock properties from FILE at REVISION for TEXT at LINE-NB."
  (let* ((file-rev (cons file revision))
         (entry (assoc file-rev diff--cached-revision-buffers))
         (buffer (cdr entry)))
    (if (buffer-live-p buffer)
        (progn
          (setq diff--cached-revision-buffers
                (cons entry
                      (delq entry diff--cached-revision-buffers))))
      ;; Cache miss: create a new entry.
      (setq buffer (get-buffer-create (format " *diff-syntax:%s.~%s~*"
                                              file revision)))
      (condition-case nil
          (vc-find-revision-no-save file revision diff-vc-backend buffer)
        (error
         (kill-buffer buffer)
         (setq buffer nil))
        (:success
         (push (cons file-rev buffer)
               diff--cached-revision-buffers))))
    (when diff--cache-clean-timer
      (cancel-timer diff--cache-clean-timer))
    (diff--cache-schedule-clean)
    (and buffer
         (with-current-buffer buffer
           ;; Major mode is set in vc-find-revision-no-save already.
           (diff-syntax-fontify-props nil text line-nb)))))

(defun diff-syntax-fontify-hunk (beg end old)
  "Highlight source language syntax in diff hunk between BEG and END.
When OLD is non-nil, highlight the hunk from the old source."
  (goto-char beg)
  (let* ((hunk (buffer-substring-no-properties beg end))
         ;; Trim a trailing newline to find hunk in diff-syntax-fontify-props
         ;; in diffs that have no newline at end of diff file.
         (text (string-trim-right
                (or (with-demoted-errors "Error getting hunk text: %S"
                      (diff-hunk-text hunk (not old) nil))
                    "")))
	 (line (if (looking-at "\\(?:\\*\\{15\\}.*\n\\)?[-@* ]*\\([0-9,]+\\)\\([ acd+]+\\([0-9,]+\\)\\)?")
		   (if old (match-string 1)
		     (if (match-end 3) (match-string 3) (match-string 1)))))
         (line-nb (when line
                    (if (string-match "\\([0-9]+\\),\\([0-9]+\\)" line)
                        (list (string-to-number (match-string 1 line))
                              (string-to-number (match-string 2 line)))
                      (list (string-to-number line) 1)))) ; One-line diffs
         (props
          (or
           (when (and diff-vc-backend
                      (not (eq diff-font-lock-syntax 'hunk-only)))
             (let* ((file (diff-find-file-name old t))
                    (file (and file (expand-file-name file)))
                    (revision (and file (if (not old) (nth 1 diff-vc-revisions)
                                          (or (nth 0 diff-vc-revisions)
                                              (vc-working-revision file))))))
               (when file
                 (if (not revision)
                     ;; Get properties from the current working revision
                     (when (and (not old) (file-readable-p file)
                                (file-regular-p file))
                       (let ((buf (get-file-buffer file)))
                         ;; Try to reuse an existing buffer
                         (if buf
                             (with-current-buffer buf
                               (diff-syntax-fontify-props nil text line-nb))
                           ;; Get properties from the file.
                           (with-current-buffer (get-buffer-create
                                                 " *diff-syntax-file*")
                             (let ((attrs (file-attributes file)))
                               (if (equal diff--syntax-file-attributes attrs)
                                   ;; Same file as last-time, unmodified.
                                   ;; Reuse buffer as-is.
                                   (setq file nil)
                                 (erase-buffer)
                                 (insert-file-contents file)
                                 (setq diff--syntax-file-attributes attrs)))
                             (diff-syntax-fontify-props file text line-nb)))))
                   (diff--get-revision-properties file revision
                                                  text line-nb)))))
           (let ((file (car (diff-hunk-file-names old))))
             (cond
              ((and file diff-default-directory
                    (not (eq diff-font-lock-syntax 'hunk-only))
                    (not diff-vc-backend)
                    (file-readable-p file) (file-regular-p file))
               ;; Try to get full text from the file.
               (with-temp-buffer
                 (insert-file-contents file)
                 (diff-syntax-fontify-props file text line-nb)))
              ;; Otherwise, get properties from the hunk alone
              ((memq diff-font-lock-syntax '(hunk-also hunk-only))
               (with-temp-buffer
                 (insert text)
                 (with-demoted-errors "%S"
                   (diff-syntax-fontify-props file text line-nb t)))))))))

    ;; Put properties over the hunk text
    (goto-char beg)
    (when (and props (eq (diff-hunk-style) 'unified))
      (while (< (progn (forward-line 1) (point)) end)
        ;; Skip the "\ No newline at end of file" lines as well as the lines
        ;; corresponding to the "other" version.
        (unless (looking-at-p (if old "[+>\\]" "[-<\\]"))
          (if (and old (not (looking-at-p "[-<]")))
              ;; Fontify context lines only from new source,
              ;; don't refontify context lines from old source.
              (pop props)
            (let ((line-props (pop props))
                  (bol (1+ (point))))
              (dolist (prop line-props)
                ;; Ideally, we'd want to use text-properties as in:
                ;;
                ;;     (add-face-text-property
                ;;      (+ bol (nth 0 prop)) (+ bol (nth 1 prop))
                ;;      (nth 2 prop) 'append)
                ;;
                ;; rather than overlays here, but they'd get removed by later
                ;; font-locking.
                ;; This is because we also apply faces outside of the
                ;; beg...end chunk currently font-locked and when font-lock
                ;; later comes to handle the rest of the hunk that we already
                ;; handled we don't (want to) redo it (we work at
                ;; hunk-granularity rather than font-lock's own chunk
                ;; granularity).
                ;; I see two ways to fix this:
                ;; - don't immediately apply the props that fall outside of
                ;;   font-lock's chunk but stash them somewhere (e.g. in another
                ;;   text property) and only later when font-lock comes back
                ;;   move them to `face'.
                ;; - change the code so work at font-lock's chunk granularity
                ;;   (this seems doable without too much extra overhead,
                ;;   contrary to the refine highlighting, which inherently
                ;;   works at a different granularity).
                (let ((ol (make-overlay (+ bol (nth 0 prop))
                                        (+ bol (nth 1 prop))
                                        nil 'front-advance nil)))
                  (overlay-put ol 'diff-mode 'syntax)
                  (overlay-put ol 'evaporate t)
                  (overlay-put ol 'face (nth 2 prop)))))))))))

(defun diff-syntax-fontify-props (file text line-nb &optional hunk-only)
  "Get font-lock properties from the source code.
FILE is the name of the source file.  If non-nil, it requests initialization
of the mode according to FILE.
TEXT is the literal source text from hunk.
LINE-NB is a pair of numbers: start line number and the number of
lines in the hunk.
When HUNK-ONLY is non-nil, then don't verify the existence of the
hunk text in the source file.  Otherwise, don't highlight the hunk if the
hunk text is not found in the source file."
  (when file
    ;; When initialization is requested, we should be in a brand new
    ;; temp buffer.
    (cl-assert (null buffer-file-name))
    ;; Use `:safe' to find `mode:'.  In case of hunk-only, use nil because
    ;; Local Variables list might be incomplete when context is truncated.
    (let ((enable-local-variables
           (unless hunk-only
             (if (memq enable-local-variables '(:safe :all nil))
                 enable-local-variables
               ;; Ignore other values that query.
               :safe)))
          (buffer-file-name file))
      ;; Don't run hooks that might assume buffer-file-name
      ;; really associates buffer with a file (bug#39190).
      (delay-mode-hooks (set-auto-mode))
      ;; FIXME: Is this really worth the trouble?
      (when (and (fboundp 'generic-mode-find-file-hook)
                 (memq #'generic-mode-find-file-hook
                       ;; There's no point checking the buffer-local value,
                       ;; we're in a fresh new buffer.
                       (default-value 'find-file-hook)))
        (generic-mode-find-file-hook))))

  (let ((font-lock-defaults (or font-lock-defaults '(nil t)))
        props beg end)
    (goto-char (point-min))
    (if hunk-only
        (setq beg (point-min) end (point-max))
      (forward-line (1- (nth 0 line-nb)))
      ;; non-regexp looking-at to compare hunk text for verification
      (if (search-forward text (+ (point) (length text)) t)
          (setq beg (- (point) (length text)) end (point))
        (goto-char (point-min))
        (if (search-forward text nil t)
            (setq beg (- (point) (length text)) end (point)))))

    (when (and beg end)
      (goto-char beg)
      (font-lock-ensure beg end)

      (while (< (point) end)
        (let* ((bol (point))
               (eol (line-end-position))
               line-props
               (searching t)
               (from (point)) to
               (val (get-text-property from 'face)))
          (while searching
            (setq to (next-single-property-change from 'face nil eol))
            (when val (push (list (- from bol) (- to bol) val) line-props))
            (setq val (get-text-property to 'face) from to)
            (unless (< to eol) (setq searching nil)))
          (when val (push (list from eol val) line-props))
          (push (nreverse line-props) props))
        (forward-line 1)))
    (nreverse props)))

;;;###autoload
(defun diff-vc-deduce-fileset ()
  (when (buffer-narrowed-p)
    ;; If user used `diff-restrict-view' then we may not have the
    ;; file header, and the commit will not succeed (bug#73387).
    (user-error "Cannot commit patch when narrowed; consider %s"
                (mapconcat (lambda (c)
                             (key-description
                              (where-is-internal c nil t)))
                           '(widen
                             diff-delete-other-hunks
                             vc-next-action)
                           " ")))
  (let ((backend (vc-responsible-backend default-directory))
        files)
    (save-excursion
      (goto-char (point-min))
      (while (progn (diff-file-next) (not (eobp)))
        (push (diff-find-file-name nil t) files)))
    (list backend (delete nil (nreverse files)) nil nil 'patch)))

(defun diff--filter-substring (str)
  (when diff-font-lock-prettify
    ;; Strip the `display' properties added by diff-font-lock-prettify,
    ;; since they look weird when you kill&yank!
    (remove-text-properties 0 (length str) '(display nil) str)
    ;; We could also try to only remove those `display' properties actually
    ;; added by diff-font-lock-prettify rather than removing them all blindly.
    ;; E.g.:
    ;;(let ((len (length str))
    ;;      (i 0))
    ;;  (while (and (< i len)
    ;;              (setq i (text-property-not-all i len 'display nil str)))
    ;;    (let* ((val (get-text-property i 'display str))
    ;;           (end (or (text-property-not-all i len 'display val str) len)))
    ;;      ;; FIXME: Check for display props that prettify the file header!
    ;;      (when (eq 'left-fringe (car-safe val))
    ;;        ;; FIXME: Should we check that it's a diff-fringe-* bitmap?
    ;;        (remove-text-properties i end '(display nil) str))
    ;;      (setq i end))))
    )
  str)

;;; Support for converting a diff to diff3 markers via `wiggle'.

;; Wiggle can be found at https://neil.brown.name/wiggle/ or in your nearest
;; Debian repository.

(defun diff-wiggle ()
  "Use `wiggle' to apply the whole current file diff by hook or by crook.
When a hunk can't cleanly be applied, it gets turned into a diff3-style
conflict."
  (interactive)
  (let* ((bounds (diff-bounds-of-file))
         (file (diff-find-file-name))
         (tmpbuf (current-buffer))
         (filebuf (find-buffer-visiting file))
         (patchfile (make-temp-file
                     (expand-file-name "wiggle" (file-name-directory file))
                     nil ".diff"))
         (errfile (make-temp-file
                     (expand-file-name "wiggle" (file-name-directory file))
                     nil ".error")))
    (unwind-protect
        (with-temp-buffer
          (set-buffer (prog1 tmpbuf (setq tmpbuf (current-buffer))))
          (when (buffer-modified-p filebuf)
            (save-some-buffers nil (lambda () (eq (current-buffer) filebuf)))
            (if (buffer-modified-p filebuf) (user-error "Abort!")))
          (write-region (car bounds) (cadr bounds) patchfile nil 'silent)
          (let ((exitcode
                 (call-process "wiggle" nil (list tmpbuf errfile) nil
                               file patchfile)))
            (if (not (memq exitcode '(0 1)))
                (message "diff-wiggle error: %s"
                         (with-current-buffer tmpbuf
                           (goto-char (point-min))
                           (insert-file-contents errfile)
                           (buffer-string)))
              (with-current-buffer tmpbuf
                (write-region nil nil file nil 'silent)
                (with-current-buffer filebuf
                  (revert-buffer t t t)
                  (save-excursion
                    (goto-char (point-min))
                    (if (re-search-forward "^<<<<<<<" nil t)
                        (smerge-mode 1)))
                  (pop-to-buffer filebuf))))))
      (delete-file patchfile)
      (delete-file errfile))))

;; provide the package
(provide 'diff-mode)

;;; Old Change Log from when diff-mode wasn't part of Emacs:
;; Revision 1.11  1999/10/09 23:38:29  monnier
;; (diff-mode-load-hook): dropped.
;; (auto-mode-alist): also catch *.diffs.
;; (diff-find-file-name, diff-mode):  add smarts to find the right file
;;     for *.rej files (that lack any file name indication).
;;
;; Revision 1.10  1999/09/30 15:32:11  monnier
;; added support for "\ No newline at end of file".
;;
;; Revision 1.9  1999/09/15 00:01:13  monnier
;; - added basic `compile' support.
;; - have diff-kill-hunk call diff-kill-file if it's the only hunk.
;; - diff-kill-file now tries to kill the leading garbage as well.
;;
;; Revision 1.8  1999/09/13 21:10:09  monnier
;; - don't use CL in the autoloaded code
;; - accept diffs using -T
;;
;; Revision 1.7  1999/09/05 20:53:03  monnier
;; interface to ediff-patch
;;
;; Revision 1.6  1999/09/01 20:55:13  monnier
;; (ediff=patch-file):  add bindings to call ediff-patch.
;; (diff-find-file-name):  taken out of diff-goto-source.
;; (diff-unified->context, diff-context->unified, diff-reverse-direction,
;;  diff-fixup-modifs):  only use the region if a prefix arg is given.
;;
;; Revision 1.5  1999/08/31 19:18:52  monnier
;; (diff-beginning-of-file, diff-prev-file):  fixed wrong parenthesis.
;;
;; Revision 1.4  1999/08/31 13:01:44  monnier
;; use `combine-after-change-calls' to minimize the slowdown of font-lock.
;;

;;; diff-mode.el ends here
