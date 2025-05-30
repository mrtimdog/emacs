;;; compile.el --- run compiler as inferior of Emacs, parse error messages  -*- lexical-binding:t -*-

;; Copyright (C) 1985-1987, 1993-1999, 2001-2025 Free Software
;; Foundation, Inc.

;; Authors: Roland McGrath <roland@gnu.org>,
;;	    Daniel Pfeiffer <occitan@esperanto.org>
;; Maintainer: emacs-devel@gnu.org
;; Keywords: tools, processes

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

;; This package provides the compile facilities documented in the Emacs user's
;; manual.

;;; Code:

(eval-when-compile (require 'cl-lib))
(require 'tool-bar)
(require 'comint)
(require 'text-property-search)

(defgroup compilation nil
  "Run compiler as inferior of Emacs, parse error messages."
  :group 'tools
  :group 'processes)


;;;###autoload
(defcustom compilation-mode-hook nil
  "List of hook functions run by `compilation-mode'."
  :type 'hook)

;;;###autoload
(defcustom compilation-start-hook nil
  "Hook run after starting a new compilation process.
The hook is run with one argument, the new process."
  :type 'hook)

;;;###autoload
(defcustom compilation-window-height nil
  "Number of lines in a compilation window.
If nil, use Emacs default."
  :type '(choice (const :tag "Default" nil)
		 integer))

(defcustom compilation-transform-file-match-alist
  '(("/bin/[a-z]*sh\\'" nil))
  "Alist of regexp/replacements to alter file names in compiler messages.
If the replacement is nil, the matching message will not be considered
an error or warning.  If not nil, it should be a replacement string
for the matched regexp.

If a non-nil replacement is specified, the value of the matched file name
used to locate the warning or error is modified using the replacement, but
the compilation buffer still displays the original value.

For example, to prepend a subdirectory \"bar/\" to all file names in
compiler messages, add an entry matching \"\\\\=`\" and a replacement
string of \"bar/\", i.e.:

    (\"\\\\=`\" \"bar/\")

Similarly, to remove a prefix \"bar/\", use:

    (\"\\\\=`bar/\" \"\")"
  :type '(repeat (list (regexp :tag "Filename that matches")
                       (radio :tag "Action"
                              (const :tag "Do not consider as error" nil)
                              (string :tag "Replace matched filename with"))))
  :version "27.1")

(defcustom compilation-filter-hook nil
  "Hook run after `compilation-filter' has inserted a string into the buffer.
It is called with the variable `compilation-filter-start' bound
to the position of the start of the inserted text, and point at
its end.

If Emacs lacks asynchronous process support, this hook is run
after `call-process' inserts the grep output into the buffer."
  :type 'hook
  :options '(ansi-color-compilation-filter
             ansi-osc-compilation-filter)
  :version "31.1")

(defvar compilation-filter-start nil
  "Position of the start of the text inserted by `compilation-filter'.
This is bound before running `compilation-filter-hook'.")

(defcustom compilation-hidden-output nil
  "Regexp to match output from the compilation that should be hidden.
This can also be a list of regexps.

The text matched by this variable will be made invisible, which
means that it'll still be present in the buffer, so that
navigation commands (for instance, `next-error') can still make
use of the hidden text to determine the current directory and the
like.

For instance, to hide the verbose output from recursive
makefiles, you can say something like:

  (setopt compilation-hidden-output
          \\='(\"^make[^\\n]+\\n\"))"
  :type '(choice regexp
                 (repeat regexp))
  :version "29.1")

(defvar compilation-first-column 1
  "This is how compilers number the first column, usually 1 or 0.
If this is buffer-local in the destination buffer, Emacs obeys
that value, otherwise it uses the value in the *compilation*
buffer.  This enables a major mode to specify its own value.")

(defvar compilation-parse-errors-filename-function #'identity
  "Function to call to post-process filenames while parsing error messages.
It takes one arg FILENAME which is the name of a file as found
in the compilation output, and should return a transformed file name
or a buffer, the one which was compiled.")
;; Note: the compilation-parse-errors-filename-function need not save the
;; match data.

;;;###autoload
(defvar compilation-process-setup-function #'ignore
  "Function to call to customize the compilation process.
This function is called immediately before the compilation process is
started.  It can be used to set any variables or functions that are used
while processing the output of the compilation process.")

;;;###autoload
(defvar compilation-buffer-name-function #'compilation--default-buffer-name
  "Function to compute the name of a compilation buffer.
The function receives one argument, the name of the major mode of the
compilation buffer.  It should return a string.
By default, it returns `(concat \"*\" (downcase name-of-mode) \"*\")'.")

;;;###autoload
(defvar compilation-finish-functions nil
  "Functions to call when a compilation process finishes.
Each function is called with two arguments: the compilation buffer,
and a string describing how the process finished.")

(defvar compilation-in-progress nil
  "List of compilation processes now running.")
(or (assq 'compilation-in-progress mode-line-modes)
    (add-to-list 'mode-line-modes
                 (list 'compilation-in-progress
                       (propertize "[Compiling] "
	                           'help-echo "Compiling; mouse-2: Goto Buffer"
                                   'mouse-face 'mode-line-highlight
                                   'local-map
                                   (make-mode-line-mouse-map
                                    'mouse-2
			            #'compilation-goto-in-progress-buffer)))))

(defun compilation-goto-in-progress-buffer ()
  "Switch to the compilation buffer."
  (interactive)
  (cond
   ((> (length compilation-in-progress) 1)
    (switch-to-buffer (completing-read
                       "Several compilation buffers; switch to: "
                       (mapcar
                        (lambda (process)
                          (buffer-name (process-buffer process)))
                        compilation-in-progress)
                       nil t)))
   (compilation-in-progress
    (switch-to-buffer (process-buffer (car compilation-in-progress))))
   (t
    (error "No ongoing compilations"))))

(defvar compilation-error "error"
  "Stem of message to print when no matches are found.")

(defvar compilation-arguments nil
  "Arguments that were given to `compilation-start'.")

(defvar compilation-num-errors-found 0)
(defvar compilation-num-warnings-found 0)
(defvar compilation-num-infos-found 0)

(defvar compilation-mode-line-errors
  '(" [" (:propertize (:eval (int-to-string compilation-num-errors-found))
                      face compilation-error
                      help-echo "Number of errors so far")
    " " (:propertize (:eval (int-to-string compilation-num-warnings-found))
                     face compilation-warning
                     help-echo "Number of warnings so far")
    " " (:propertize (:eval (int-to-string compilation-num-infos-found))
                     face compilation-info
                     help-echo "Number of informational messages so far")
    "]"))
(put 'compilation-mode-line-errors 'risky-local-variable t)

;; If you make any changes to `compilation-error-regexp-alist-alist',
;; be sure to run the ERT test in test/lisp/progmodes/compile-tests.el.
;; emacs -batch -l compile-tests.el -f ert-run-tests-batch-and-exit

(defvar compilation-error-regexp-alist-alist
 (eval-when-compile
   ;; The order of this list is the default order of items in
   ;; `compilation-error-regexp-alist' which is also the matching order,
   ;; so don't add things in alphabetic order just out of habit.
   ;; FIXME: We should sort it by frequency (less often used ones in the back),
   ;; but individual patterns also have their own partial order.
  `((absoft
     "^\\(?:[Ee]rror on \\|[Ww]arning on\\( \\)\\)?[Ll]ine[ \t]+\\([0-9]+\\)[ \t]+\
of[ \t]+\"?\\([a-zA-Z]?:?[^\":\n]+\\)\"?:" 3 2 nil (1))

    (ada
     "\\(warning: .*\\)? at \\([^ \n]+\\):\\([0-9]+\\)$" 2 3 nil (1))

    (aix
     " in line \\([0-9]+\\) of file \\([^ \n]+[^. \n]\\)\\.? " 2 1)

    ;; Checkstyle task may report its own severity level: "[checkstyle] [ERROR] ..."
    ;; (see AuditEventDefaultFormatter.java in checkstyle sources).
    (ant
     "^[ \t]*\\(?:\\[[^] \n]+\\][ \t]*\\)\\{1,2\\}\\(\\(?:[A-Za-z]:\\)?[^: \n]+\\):\
\\([0-9]+\\):\\(?:\\([0-9]+\\):\\([0-9]+\\):\\([0-9]+\\):\\)?\\( warning\\)?"
     1 (2 . 4) (3 . 5) (6))

    (bash
     "^\\([^: \n\t]+\\): line \\([0-9]+\\):" 1 2)

    (borland
     "^\\(?:Error\\|Warnin\\(g\\)\\) \\(?:[FEW][0-9]+ \\)?\
\\([a-zA-Z]?:?[^:( \t\n]+\\)\
 \\([0-9]+\\)\\(?:[) \t]\\|:[^0-9\n]\\)" 2 3 nil (1))

    (python-tracebacks-and-caml
     "^[ \t]*File \\(\"?\\)\\([^,\" \n\t<>]+\\)\\1, lines? \\([0-9]+\\)-?\\([0-9]+\\)?\\(?:$\\|,\
\\(?: characters? \\([0-9]+\\)-?\\([0-9]+\\)?:\\)?\\([ \n]Warning\\(?: [0-9]+\\)?:\\)?\\)"
     2 (3 . 4) (5 . 6) (7))

    (cmake
     "^CMake \\(?:Error\\|\\(Warning\\)\\) at \\(.*\\):\\([1-9][0-9]*\\) ([^)]+):$"
     2 3 nil (1))
    (cmake-info
     "^  \\(?: \\*\\)?\\(.*\\):\\([1-9][0-9]*\\) ([^)]+)$"
     1 2 nil 0)

    (comma
     "^\"\\([^,\" \n\t]+\\)\", line \\([0-9]+\\)\
\\(?:[(. pos]+\\([0-9]+\\))?\\)?[:.,; (-]\\( warning:\\|[-0-9 ]*(W)\\)?" 1 2 3 (4))

    (msft
     ;; Must be before edg-1, so that MSVC's longer messages are
     ;; considered before EDG.
     ;; The message may be a "warning", "error", or "fatal error" with
     ;; an error code, or "see declaration of" without an error code.
     "^ *\\([0-9]+>\\)?\\(\\(?:[a-zA-Z]:\\)?[^ :(\t\n][^:(\t\n]*\\)(\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)?) ?\
: \\(?:see declaration\\|\\(?:warnin\\(g\\)\\|[a-z ]+\\) C[0-9]+:\\)"
     2 3 4 (5))

    (edg-1
     "^\\([^ \n]+\\)(\\([0-9]+\\)): \\(?:error\\|warnin\\(g\\)\\|remar\\(k\\)\\)"
     1 2 nil (3 . 4))
    (edg-2
     "at line \\([0-9]+\\) of \"\\([^ \n]+\\)\"$"
     2 1 nil 0)

    (epc
     "^Error [0-9]+ at (\\([0-9]+\\):\\([^)\n]+\\))" 2 1)

    (ftnchek
     "\\(^Warning .*\\)? line[ \n]\\([0-9]+\\)[ \n]\\(?:col \\([0-9]+\\)[ \n]\\)?file \\([^ :;\n]+\\)"
     4 2 3 (1))

    ;; Introduced in Kotlin 1.8 and current as of Kotlin 2.0.
    ;; Emitted by `GradleStyleMessagerRenderer' in Kotlin sources.
    (gradle-kotlin
     ,(rx bol
          (| (group "w")                ; 1: warning
             (group (in "iv"))          ; 2: info
             "e")                       ; error
          ": "
          "file://"
          (group                        ; 3: file
           (? (in "A-Za-z") ":")
           (+ (not (in "\n:"))))
          ":"
          (group (+ digit))             ; 4: line
          ":"
          (group (+ digit))             ; 5: column
          " ")
     3 4 5 (1 . 2))

    ;; Obsoleted in Kotlin 1.8 Beta, released on Nov 15, 2022.
    ;; See commit `93a0cdbf973' in Kotlin Git repository.
    (gradle-kotlin-legacy
     ,(rx bol
          (| (group "w")                ; 1: warning
             (group (in "iv"))          ; 2: info
             "e")                       ; error
          ": "
          (group                        ; 3: file
           (? (in "A-Za-z") ":")
           (+ (not (in "\n:"))))
          ": ("
          (group (+ digit))             ; 4: line
          ", "
          (group (+ digit))             ; 5: column
          "): ")
     3 4 5 (1 . 2))

    (gradle-android
     ,(rx bol (* " ") "ERROR:"
          (group-n 1                    ; file
                   (+ (not (in ":\n"))))
          ":"
          (group-n 2 (+ digit))         ; line
          ": ")
     1 2)

   (iar
     "^\"\\(.*\\)\",\\([0-9]+\\)\\s-+\\(?:Error\\|Warnin\\(g\\)\\)\\[[0-9]+\\]:"
     1 2 nil (3))

    (ibm
     "^\\([^( \n\t]+\\)(\\([0-9]+\\):\\([0-9]+\\)) :\
 \\(?:warnin\\(g\\)\\|informationa\\(l\\)\\)?" 1 2 3 (4 . 5))

    ;; fixme: should be `mips'
    (irix
     "^[-[:alnum:]_/ ]+: \\(?:\\(?:[sS]evere\\|[eE]rror\\|[wW]arnin\\(g\\)\\|[iI]nf\\(o\\)\\)[0-9 ]*: \\)?\
\\([^,\" \n\t]+\\)\\(?:, line\\|:\\) \\([0-9]+\\):" 3 4 nil (1 . 2))

    (java
     "^\\(?:[ \t]+at \\|==[0-9]+== +\\(?:at\\|b\\(y\\)\\)\\).+(\\([^()\n]+\\):\\([0-9]+\\))$" 2 3 nil (1))

    (javac
     ,(rx bol
          (group                        ; file
           (? (in "A-Za-z") ":")
           (+ (not (in "\n:"))))
          ":"
          (group (+ (in "0-9")))        ; line number
          ": "
          (? (group "warning: "))       ; type (optional)
          (* nonl) "\n"                 ; message
          (* nonl) "\n"                 ; source line containing error
          (* " ") "^"                   ; caret line; ^ marks error
          eol)
     1 2
     ,#'current-column
     (3))

    (jikes-file
     "^\\(?:Found\\|Issued\\) .* compiling \"\\(.+\\)\":$" 1 nil nil 0)

    (maven
     ;; Maven is a popular free software build tool for Java.
     ,(rx bol
          ;; It is unclear whether the initial [type] tag is always present.
          (? "["
             (or "ERROR" (group-n 1 "WARNING") (group-n 2 "INFO"))
             "] ")
          (group-n 3                    ; File
                   (not (any "\n ["))
                   (* (or (not (any "\n :"))
                          (: " " (not (any "\n/-")))
                          (: ":" (not (any "\n ["))))))
          ":["
          (group-n 4 (+ digit))         ; Line
          ","
          (group-n 5 (+ digit))         ; Column
          "] ")
     3 4 5 (1 . 2))

    (jikes-line
     "^ *\\([0-9]+\\)\\.[ \t]+.*\n +\\(<-*>\n\\*\\*\\* \\(?:Error\\|Warnin\\(g\\)\\)\\)"
     nil 1 nil 2 0
     (2 (compilation-face '(3))))

    (clang-include
     ,(rx bol "In file included from "
          (group (+ (not (any ?\n ?:)))) ?:
          (group (+ (any (?0 . ?9)))) ?:
          eol)
     1 2 nil 0)

    (gcc-include
     "^\\(?:In file included \\|                 \\|\t\\)from \
\\([0-9]*[^0-9\n]\\(?:[^\n :]\\| [^-/\n]\\|:[^ \n]\\)*?\\):\
\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?\\(?:\\([:,]\\|$\\)\\)?"
     1 2 3 (nil . 4))

    (ruby-Test::Unit
     "^    [[ ]?\\([^ (].*\\):\\([1-9][0-9]*\\)\\(\\]\\)?:in " 1 2)

    ;; Tested with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT 2.1.
    (lua
     ,(rx bol
          (+? (not (in "\t\n")))
          ": "
          (group (+? (not (in "\t\n"))))
          ":"
          (group (+ (in "0-9")))
          ": "
          (+ nonl)
          "\nstack traceback:\n\t")
     1 2 nil 2 1)
    (lua-stack
     ,(rx bol "\t"
          (| "[C]:"
             (: (group (+? (not (in "\t\n"))))
                ":"
                (? (group (+ (in "0-9")))
                   ":")))
          " in ")
     1 2 nil 0 1)

    (gmake
     ;; Set GNU make error messages as INFO level.
     ;; It starts with the name of the make program which is variable,
     ;; so don't try to match it.
     ": \\*\\*\\* \\[\\(\\(.+?\\):\\([0-9]+\\): .+\\)\\]" 2 3 nil 0 1)

    (gnu
     ;; The `gnu' message syntax is
     ;;   [PROGRAM:]FILE:LINE[-ENDLINE]:[COL[-ENDCOL]:] MESSAGE
     ;; or
     ;;   [PROGRAM:]FILE:LINE[.COL][-ENDLINE[.ENDCOL]]: MESSAGE
     ,(rx
       bol
       ;; Match an optional program name which is used for
       ;; non-interactive programs other than compilers (e.g. the
       ;; "jade:" entry in compilation.txt).
       (? (| (: alpha (+ (in ?. ?- alnum)) ":" (? " "))
             ;; Skip indentation generated by GCC's -fanalyzer.
             (: (+ " ") "|")))

       ;; File name group.
       (group-n 1
         ;; Avoid matching the file name as a program in the pattern
         ;; above by disallowing file names entirely composed of digits.
         ;; Do not allow file names beginning with a space.
         (| (not (in "0-9" "\n\t "))
            (: (+ (in "0-9"))
               (not (in "0-9" "\n"))))
         ;; A file name can be composed of any non-newline char, but
         ;; rule out some valid but unlikely cases, such as a trailing
         ;; space or a space followed by a -, or a colon followed by a
         ;; space.
         (*? (| (not (in "\n :"))
                (: " " (not (in ?- "/\n")))
                (: ":" (not (in " \n"))))))
       ":" (? " ")

       ;; Line number group.
       (group-n 2 (+ (in "0-9")))
       (? (| (: "-"
                (group-n 4 (+ (in "0-9")))               ; ending line
                (? "." (group-n 5 (+ (in "0-9")))))      ; ending column
             (: (in ".:")
                (group-n 3 (+ (in "0-9")))               ; starting column
                (? "-"
                   (? (group-n 4 (+ (in "0-9"))) ".")    ; ending line
                   (group-n 5 (+ (in "0-9")))))))        ; ending column
       ":"
       (| (: (* " ")
             (group-n 6 (| "FutureWarning"
                           "RuntimeWarning"
                           "Warning" "warning"
                           "W:")))
          (: (* " ")
             (group-n 7
               (| (| "Info" "info"
                     "Information" "information"
                     "Informational" "informational"
                     "I:"
                     "instantiated from"
                     "required from"
                     "Note" "note")
                  (: "[ skipping " (+ nonl) " ]"))))
          (: (* " ")
             (| "Error" "error"))

          ;; Avoid matching time stamps on the form "HH:MM:SS" where
          ;; MM is interpreted as a line number by trying to rule out
          ;; messages where the text after the line number starts with
          ;; a 2-digit number.
          (: (? (in "0-9"))
             (| (not (in "0-9\n"))
                eol))
          (: (in "0-9") (in "0-9") (in "0-9"))))
     1 (2 . 4) (3 . 5) (6 . 7))

    (cucumber
     ,(rx (| (: bol
                (| (: "cucumber" (? " -p " (+ (not space))))
                   "     "))
             "#")
          " "
          (group (not "(") (* nonl))          ; file
          ":"
          (group (in "1-9") (* (in "0-9"))))  ; line
     1 2)

    (lcc
     "^\\(?:E\\|\\(W\\)\\), \\([^(\n]+\\)(\\([0-9]+\\),[ \t]*\\([0-9]+\\)"
     2 3 4 (1))

    (makepp
     "^makepp\\(?:\\(?:: warning\\(:\\).*?\\|\\(: Scanning\\|: [LR]e?l?oading makefile\\|: Imported\\|log:.*?\\) \\|: .*?\\)\
`\\(\\(\\S +?\\)\\(?::\\([0-9]+\\)\\)?\\)['(]\\)"
     4 5 nil (1 . 2) 3
     (0 (progn (save-match-data
                 (compilation-parse-errors
                  (match-end 0) (line-end-position)
                  `("`\\(\\(\\S +?\\)\\(?::\\([0-9]+\\)\\)?\\)['(]"
                    2 3 nil
                    ,(cond ((match-end 1) 1) ((match-end 2) 0) (t 2))
                    1)))
               (end-of-line)
               nil)))

    ;; Should be lint-1, lint-2 (SysV lint)
    (mips-1
     " (\\([0-9]+\\)) in \\([^ \n]+\\)" 2 1)
    (mips-2
     " in \\([^()\n ]+\\)(\\([0-9]+\\))$" 1 2)

    (omake
     ;; "omake -P" reports "file foo changed"
     ;; (useful if you do "cvs up" and want to see what has changed)
     "^\\*\\*\\* omake: file \\(.*\\) changed" 1 nil nil nil nil
     ;; FIXME-omake: This tries to prevent reusing pre-existing markers
     ;; for subsequent messages, since those messages's line numbers
     ;; are about another version of the file.
     (0 (progn (compilation--flush-file-structure (match-string 1))
               nil)))

    (oracle
     "^\\(?:Semantic error\\|Error\\|PCC-[0-9]+:\\).* line \\([0-9]+\\)\
\\(?:\\(?:,\\| at\\)? column \\([0-9]+\\)\\)?\
\\(?:,\\| in\\| of\\)? file \\(.*?\\):?$"
     3 1 2)

    ;; "during global destruction": This comes out under "use
    ;; warnings" in recent perl when breaking circular references
    ;; during program or thread exit.
    (perl
     " at \\([^ \n]+\\) line \\([0-9]+\\)\\(?:[,.]\\|$\\| \
during global destruction\\.$\\)" 1 2)

    (php
     "\\(?:Parse\\|Fatal\\) error: \\(.*\\) in \\(.*\\) on line \\([0-9]+\\)"
     2 3 nil nil)

    (rust
     ,(rx bol (or (group-n 1 "error") (group-n 2 "warning") (group-n 3 "note"))
          (? "[" (+ (in "A-Z" "0-9")) "]") ":" (* nonl)
          "\n" (+ " ") "-->"
          " " (group-n 4 (+ nonl))        ; file
          ":" (group-n 5 (+ (in "0-9")))  ; line
          ":" (group-n 6 (+ (in "0-9")))) ; column
     4 5 6 (2 . 3)
     nil
     (1 compilation-error-face)
     (2 compilation-warning-face)
     (3 compilation-info-face))

    (rxp
     "^\\(?:Error\\|Warnin\\(g\\)\\):.*\n.* line \\([0-9]+\\) char\
 \\([0-9]+\\) of file://\\(.+\\)"
     4 2 3 (1))

    (shellcheck
     "^In \\(.+\\) line \\([0-9]+\\):" 1 2)

    (sparc-pascal-file
     "^\\w\\w\\w \\w\\w\\w +[0-3]?[0-9] +[0-2][0-9]:[0-5][0-9]:[0-5][0-9]\
 [12][09][0-9][0-9] +\\(.*\\):$"
     1 nil nil 0)
    (sparc-pascal-line
     "^\\(\\(?:E\\|\\(w\\)\\) +[0-9]+\\) line \\([0-9]+\\) -  "
     nil 3 nil (2) nil (1 (compilation-face '(2))))
    (sparc-pascal-example
     "^ +\\([0-9]+\\) +.*\n\\(\\(?:e\\|\\(w\\)\\) [0-9]+\\)-+"
     nil 1 nil (3) nil (2 (compilation-face '(3))))

    (sun
     ": \\(?:ERROR\\|WARNIN\\(G\\)\\|REMAR\\(K\\)\\) \\(?:[[:alnum:] ]+, \\)?\
File = \\(.+\\), Line = \\([0-9]+\\)\\(?:, Column = \\([0-9]+\\)\\)?"
     3 4 5 (1 . 2))

    (sun-ada
     "^\\([^, \n\t]+\\), line \\([0-9]+\\), char \\([0-9]+\\)[:., (-]" 1 2 3)

    (watcom
     "^[ \t]*\\(\\(?:[a-zA-Z]:\\)?[^ :(\t\n][^:(\t\n]*\\)(\\([0-9]+\\)): ?\
\\(?:\\(Error! E[0-9]+\\)\\|\\(Warning! W[0-9]+\\)\\):"
     1 2 nil (4))

    (4bsd
     "\\(?:^\\|::  \\|\\S ( \\)\\(/[^ \n\t()]+\\)(\\([0-9]+\\))\
\\(?:: \\(warning:\\)?\\|$\\| ),\\)" 1 2 nil (3))

    (gcov-file
     "^ *-: *\\(0\\):Source:\\(.+\\)$"
     2 1 nil 0 nil)
    (gcov-header
     "^ *-: *\\(0\\):\\(?:Object\\|Graph\\|Data\\|Runs\\|Programs\\):.+$"
     nil 1 nil 0 nil)
    ;; Underlines over all lines of gcov output are too uncomfortable to read.
    ;; However, hyperlinks embedded in the lines are useful.
    ;; So I put default face on the lines; and then put
    ;; compilation-*-face by manually to eliminate the underlines.
    ;; The hyperlinks are still effective.
    (gcov-nomark
     "^ *-: *\\([1-9]\\|[0-9]\\{2,\\}\\):.*$"
     nil 1 nil 0 nil
     (0 'default)
     (1 compilation-line-face))
    (gcov-called-line
     "^ *\\([0-9]+\\): *\\([0-9]+\\):.*$"
     nil 2 nil 0 nil
     (0 'default)
     (1 compilation-info-face) (2 compilation-line-face))
    (gcov-never-called
     "^ *\\(#####\\): *\\([0-9]+\\):.*$"
     nil 2 nil 2 nil
     (0 'default)
     (1 compilation-error-face) (2 compilation-line-face))

    (perl--Pod::Checker
     ;; podchecker error messages, per Pod::Checker.
     ;; The style is from the Pod::Checker::poderror() function, eg.
     ;; *** ERROR: Spurious text after =cut at line 193 in file foo.pm
     ;;
     ;; Plus end_pod() can give "at line EOF" instead of a
     ;; number, so for that match "on line N" which is the
     ;; originating spot, eg.
     ;; *** ERROR: =over on line 37 without closing =back at line EOF in file bar.pm
     ;;
     ;; Plus command() can give both "on line N" and "at line N";
     ;; the latter is desired and is matched because the .* is
     ;; greedy.
     ;; *** ERROR: =over on line 1 without closing =back (at head1) at line 3 in file x.pod
     ;;
     "^\\*\\*\\* \\(?:ERROR\\|\\(WARNING\\)\\).* \\(?:at\\|on\\) line \
\\([0-9]+\\) \\(?:.* \\)?in file \\([^ \t\n]+\\)"
     3 2 nil (1))
    (perl--Test
     ;; perl Test module error messages.
     ;; Style per the ok() function "$context", eg.
     ;; # Failed test 1 in foo.t at line 6
     ;;
     "^# Failed test [0-9]+ in \\([^ \t\r\n]+\\) at line \\([0-9]+\\)"
     1 2)
    (perl--Test2
     ;; Or when comparing got/want values, with a "fail #n" if repeated
     ;; # Test 2 got: "xx" (t-compilation-perl-2.t at line 10)
     ;; # Test 3 got: "xx" (t-compilation-perl-2.t at line 10 fail #2)
     ;;
     ;; And under Test::Harness they're preceded by progress stuff with
     ;; \r and "NOK",
     ;; ... NOK 1# Test 1 got: "1234" (t/foo.t at line 46)
     ;;
     "^\\(.*NOK.*\\)?# Test [0-9]+ got:.* (\\([^ \t\r\n]+\\) at line \
\\([0-9]+\\)\\( fail #[0-9]+\\)?)"
     2 3)
    (perl--Test::Harness
     ;; perl Test::Harness output, eg.
     ;; NOK 1# Test 1 got: "1234" (t/foo.t at line 46)
     ;;
     ;; Test::Harness is slightly designed for tty output, since
     ;; it prints CRs to overwrite progress messages, but if you
     ;; run it in with M-x compile this pattern can at least step
     ;; through the failures.
     ;;
     "^.*NOK.* \\([^ \t\r\n]+\\) at line \\([0-9]+\\)"
     1 2)
    (weblint
     ;; The style comes from HTML::Lint::Error::as_string(), eg.
     ;; index.html (13:1) Unknown element <fdjsk>
     ;;
     ;; The pattern only matches filenames without spaces, since that
     ;; should be usual and should help reduce the chance of a false
     ;; match of a message from some unrelated program.
     ;;
     ;; This message style is quite close to the "ibm" entry which is
     ;; for IBM C, though that ibm bit doesn't put a space after the
     ;; filename.
     ;;
     "^\\([^ \t\r\n(]+\\) (\\([0-9]+\\):\\([0-9]+\\)) "
     1 2 3)

    ;; Guile compilation yields file-headers in the following format:
    ;;
    ;;   In sourcefile.scm:
    ;;
    ;; We need to catch those, but we also need to be aware that Emacs
    ;; byte-compilation yields compiler headers in similar form of
    ;; those:
    ;;
    ;;   In toplevel form:
    ;;   In end of data:
    ;;
    ;; We want to catch the Guile file-headers but not the Emacs
    ;; byte-compilation headers, because that will cause next-error
    ;; and prev-error to break, because the files "toplevel form" and
    ;; "end of data" does not exist.
    ;;
    ;; To differentiate between these two cases, we require that the
    ;; file-match must always contain an extension.
    ;;
    ;; We should also only treat this as "info", not "error", because
    ;; we do not know what lines will follow.
    (guile-file "^In \\(.+\\..+\\):\n" 1 nil nil 0)
    (guile-line "^ *\\([0-9]+\\): *\\([0-9]+\\)" nil 1 2)

    ;; Typescript compilation prior to tsc version 2.7, "plain" format:
    ;; greeter.ts(30,12): error TS2339: Property 'foo' does not exist.
    (typescript-tsc-plain
     ,(rx bol
          (group (not (in " \t\n()"))   ; 1: file
                 (* (not (in "\n()"))))
          "("
          (group (+ (in "0-9")))        ; 2: line
          ","
          (group (+ (in "0-9")))        ; 3: column
          "): error "
          (+ (in "0-9A-Z"))             ; error code
          ": ")
     1 2 3 2)

    ;; Typescript compilation after tsc version 2.7, "pretty" format:
    ;; src/resources/document.ts:140:22 - error TS2362: something.
    (typescript-tsc-pretty
     ,(rx bol
          (group (not (in " \t\n()"))   ; 1: file
                 (* (not (in "\n()"))))
          ":"
          (group (+ (in "0-9")))        ; 2: line
          ":"
          (group (+ (in "0-9")))        ; 3: column
          " - error "
          (+ (in "0-9A-Z"))             ; error code
          ": ")
     1 2 3 2)
    ))
  "Alist of values for `compilation-error-regexp-alist'.")

(defcustom compilation-error-regexp-alist
  ;; Omit `omake' by default: its mere presence here triggers special processing
  ;; and modifies regexps for other rules (see `compilation-parse-errors'),
  ;; which may slow down matching (or even cause mismatches).
  (delq 'omake (mapcar #'car compilation-error-regexp-alist-alist))
  "Alist that specifies how to match errors in compiler output.
On GNU and Unix, any string is a valid filename, so these
matchers must make some common sense assumptions, which catch
normal cases.  A shorter list will be lighter on resource usage.

Instead of an alist element, you can use a symbol, which is
looked up in `compilation-error-regexp-alist-alist'.  You can see
the predefined symbols and their effects in the file
`etc/compilation.txt' (linked below if you are customizing this).

Each elt has the form (REGEXP FILE [LINE COLUMN TYPE HYPERLINK
HIGHLIGHT...]).  If REGEXP matches, the FILE'th subexpression
gives the file name, and the LINE'th subexpression gives the line
number.  The COLUMN'th subexpression gives the column number on
that line.

If FILE, LINE or COLUMN are nil or that index didn't match, that
information is not present on the matched line.  In that case the
file name is assumed to be the same as the previous one in the
buffer, line number defaults to 1 and column defaults to
beginning of line's indentation.

FILE can also have the form (FILE FORMAT...), where the FORMATs
\(e.g. \"%s.c\") will be applied in turn to the recognized file
name, until a file of that name is found.  Or FILE can also be a
function that returns (FILENAME) or (RELATIVE-FILENAME . DIRNAME).
In the former case, FILENAME may be relative or absolute, or it may
be a buffer.

LINE can also be of the form (LINE . END-LINE) meaning a range
of lines.  COLUMN can also be of the form (COLUMN . END-COLUMN)
meaning a range of columns starting on LINE and ending on
END-LINE, if that matched.

LINE, END-LINE, COL, and END-COL can also be functions of no argument
that return the corresponding line or column number.  They can assume REGEXP
has just been matched, and should correspondingly preserve this match data.

TYPE is 2 or nil for a real error or 1 for warning or 0 for info.
TYPE can also be of the form (WARNING . INFO).  In that case this
will be equivalent to 1 if the WARNING'th subexpression matched
or else equivalent to 0 if the INFO'th subexpression matched,
or else equivalent to 2 if neither of them matched.
See `compilation-error-face', `compilation-warning-face',
`compilation-info-face' and `compilation-skip-threshold'.

What matched the HYPERLINK'th subexpression has `mouse-face' and
`compilation-message-face' applied.  If this is nil, the text
matched by the whole REGEXP becomes the hyperlink.

Additional HIGHLIGHTs take the shape (SUBMATCH FACE), where
SUBMATCH is the number of a submatch and FACE is an expression
which evaluates to a face name (a symbol or string).
Alternatively, FACE can evaluate to a property list of the
form (face FACE PROP1 VAL1 PROP2 VAL2 ...), in which case all the
listed text properties PROP# are given values VAL# as well.

After identifying compilation errors and warnings determined by this
variable, the `compilation-transform-file-match-alist' variable
is then consulted.  It allows further transformations of the
matched file names, and ignoring false positives."
  :type '(repeat (choice (symbol :tag "Predefined symbol")
			 (sexp :tag "Error specification")))
  :link `(file-link :tag "example file"
		    ,(expand-file-name "compilation.txt" data-directory)))

(defvar compilation-error-case-fold-search nil
  "If non-nil, use case-insensitive matching of compilation errors.
If nil, matching is case-sensitive.

Compilation errors are given by the regexps in
`compilation-error-regexp-alist' and
`compilation-error-regexp-alist-alist'.

This variable should only be set for backward compatibility as a temporary
measure.  The proper solution is to use a regexp that matches the
messages without case-folding.")

;;;###autoload(put 'compilation-directory 'safe-local-variable 'stringp)
(defvar compilation-directory nil
  "Directory to restore to when doing `recompile'.")

(defvar compilation-directory-matcher
  '("\\(?:Entering\\|Leavin\\(g\\)\\) directory [`']\\(.+\\)'$" (2 . 1))
  "A list for tracking when directories are entered or left.
If nil, do not track directories, e.g. if all file names are absolute.  The
first element is the REGEXP matching these messages.  It can match any number
of variants, e.g. different languages.  The remaining elements are all of the
form (DIR .  LEAVE).  If for any one of these the DIR'th subexpression
matches, that is a directory name.  If LEAVE is nil or the corresponding
LEAVE'th subexpression doesn't match, this message is about going into another
directory.  If it does match anything, this message is about going back to the
directory we were in before the last entering message.  If you change this,
you may also want to change `compilation-page-delimiter'.")

(defvar compilation-page-delimiter
  "^\\(?:\f\\|.*\\(?:Entering\\|Leaving\\) directory [`'].+'\n\\)+"
  "Value of `page-delimiter' in Compilation mode.")

(defvar compilation-mode-font-lock-keywords
   '(;; configure output lines.
     ("^[Cc]hecking \\(?:[Ff]or \\|[Ii]f \\|[Ww]hether \\(?:to \\)?\\)?\\(.+\\)\\.\\.\\. *\\(?:(cached) *\\)?\\(\\(yes\\(?: .+\\)?\\)\\|no\\|\\(.*\\)\\)$"
      (1 font-lock-variable-name-face)
      (2 (compilation-face '(4 . 3))))
     ;; Command output lines.  Recognize `make[n]:' lines too.
     ("^\\([[:alnum:]_/.+-]+\\)\\(\\[\\([0-9]+\\)\\]\\)?[ \t]*:"
      (1 font-lock-function-name-face) (3 compilation-line-face nil t))
     (" --?o\\(?:utfile\\|utput\\)?[= ]\\(\\S +\\)" . 1)
     ("^Compilation \\(finished\\).*"
      (0 '(face nil compilation-message nil help-echo nil mouse-face nil) t)
      (1 compilation-info-face))
     ("^Compilation \\(exited abnormally\\|interrupt\\|killed\\|terminated\\|segmentation fault\\)\\(?:.*with code \\([0-9]+\\)\\)?.*"
      (0 '(face nil compilation-message nil help-echo nil mouse-face nil) t)
      (1 compilation-error-face)
      (2 compilation-error-face nil t)))
   "Additional things to highlight in Compilation mode.
This gets tacked on the end of the generated expressions.")

(defvar compilation-highlight-regexp t
  "Regexp matching part of visited source lines to highlight temporarily.
Highlight entire line if t; don't highlight source lines if nil.")

(defvar compilation-highlight-overlay nil
  "Overlay used to temporarily highlight compilation matches.")

(defcustom compilation-error-screen-columns t
  "If non-nil, column numbers in error messages are screen columns.
Otherwise they are interpreted as character positions, with
each character occupying one column.
The default is to use screen columns, which requires that the compilation
program and Emacs agree about the display width of the characters,
especially the TAB character.
If this is buffer-local in the destination buffer, Emacs obeys
that value, otherwise it uses the value in the *compilation*
buffer.  This enables a major mode to specify its own value."
  :type 'boolean
  :version "20.4")

(defcustom compilation-read-command t
  "Non-nil means \\[compile] reads the compilation command to use.
Otherwise, \\[compile] just uses the value of `compile-command'.

Note that changing this to nil may be a security risk, because a
file might define a malicious `compile-command' as a file local
variable, and you might not notice.  Therefore, `compile-command'
is considered unsafe if this variable is nil."
  :type 'boolean)

(defcustom compilation-search-all-directories t
  "Whether further upward directories should be used when searching a file.
When doing a parallel build, several files from different
directories can be compiled at the same time.  This makes it
difficult to determine the base directory for a relative file
name in a compiler error or warning.  If this variable is
non-nil, instead of just relying on the previous directory change
in the compilation buffer, all other directories further upwards
will be used as well."
  :type 'boolean
  :version "28.1")

;;;###autoload
(defcustom compilation-ask-about-save t
  "Non-nil means \\[compile] asks which buffers to save before compiling.
Otherwise, it saves all modified buffers without asking."
  :type 'boolean)

(defcustom compilation-save-buffers-predicate nil
  "The second argument (PRED) passed to `save-some-buffers' before compiling.
E.g., one can set this to
  (lambda ()
    (string-prefix-p my-compilation-root (file-truename (buffer-file-name))))
to limit saving to files located under `my-compilation-root'.
Note, that, in general, `compilation-directory' cannot be used instead
of `my-compilation-root' here."
  :type '(choice
          (const :tag "Default (save all file-visiting buffers)" nil)
          (const :tag "Save all buffers" t)
          function)
  :version "24.1")

;;;###autoload
(defcustom compilation-search-path '(nil)
  "List of directories to search for source files named in error messages.
Elements should be directory names, not file names of directories.
The value nil as an element means to try the default directory."
  :type '(repeat (choice (const :tag "Default" nil)
			 (string :tag "Directory"))))

;;;###autoload
(defcustom compile-command "make -k "
  "Last shell command used to do a compilation; default for next compilation.

Sometimes it is useful for files to supply local values for this variable.
You might also use mode hooks to specify it in certain modes, like this:

    (add-hook \\='c-mode-hook
       (lambda ()
	 (unless (or (file-exists-p \"makefile\")
		     (file-exists-p \"Makefile\"))
           (setq-local compile-command
		(concat \"make -k \"
			(if buffer-file-name
			  (shell-quote-argument
			    (file-name-sans-extension buffer-file-name))))))))

It's often useful to leave a space at the end of the value."
  :type 'string)
;;;###autoload(put 'compile-command 'safe-local-variable (lambda (a) (and (stringp a) (if (boundp 'compilation-read-command) compilation-read-command t))))

;;;###autoload
(defcustom compilation-disable-input nil
  "If non-nil, send end-of-file as compilation process input.
This only affects platforms that support asynchronous processes (see
`start-process'); synchronous compilation processes never accept input."
  :type 'boolean
  :version "22.1")

;; A weak per-compilation-buffer hash indexed by (FILENAME . DIRECTORY).  Each
;; value is a FILE-STRUCTURE as described above, with the car eq to the hash
;; key.  This holds the tree seen from root, for storing new nodes.
(defvar compilation-locs ())

(defvar compilation-debug nil
  "Set this to t before creating a *compilation* buffer.
Then every error line will have a debug text property with the matcher that
fit this line and the match data.  Use `describe-text-properties'.")

(defvar compilation-exit-message-function
  (lambda (_process-status exit-status msg) (cons msg exit-status))
  "If non-nil, called when a compilation process dies to return a status message.
This should be a function of three arguments: process status, exit status,
and exit message; it returns a cons (MESSAGE . MODELINE) of the strings to
write into the compilation buffer, and to put in its mode line.")

(defcustom compilation-environment nil
  "List of environment variables for compilation to inherit.
Each element should be a string of the form ENVVARNAME=VALUE.
This list is temporarily prepended to `process-environment' prior to
starting the compilation process."
  :type '(repeat (string :tag "ENVVARNAME=VALUE"))
  :options '(("LANG=C"))
  :version "24.1")

;; History of compile commands.
(defvar compile-history nil)

(defface compilation-error
  '((t :inherit error))
  "Face used to highlight compiler errors."
  :version "22.1")

(defface compilation-warning
  '((t :inherit warning))
  "Face used to highlight compiler warnings."
  :version "22.1")

(defface compilation-info
  '((t :inherit success))
  "Face used to highlight compiler information."
  :version "22.1")

;; The next three faces must be able to stand out against the
;; `mode-line' and `mode-line-inactive' faces.

(defface compilation-mode-line-fail
  '((default :inherit compilation-error)
    (((class color) (min-colors 16)) (:foreground "Red1" :weight bold))
    (((class color) (min-colors 8)) (:foreground "red"))
    (t (:inverse-video t :weight bold)))
  "Face for Compilation mode's \"error\" mode line indicator."
  :version "24.3")

(defface compilation-mode-line-run
  '((t :inherit compilation-warning))
  "Face for Compilation mode's \"running\" mode line indicator."
  :version "24.3")

(defface compilation-mode-line-exit
  '((default :inherit compilation-info)
    (((class color) (min-colors 16))
     (:foreground "ForestGreen" :weight bold))
    (((class color)) (:foreground "green" :weight bold))
    (t (:weight bold)))
  "Face for Compilation mode's \"exit\" mode line indicator."
  :version "24.3")

(defface compilation-line-number
  '((t :inherit font-lock-keyword-face))
  "Face for displaying line numbers in compiler messages."
  :version "22.1")

(defface compilation-column-number
  '((t :inherit font-lock-doc-face))
  "Face for displaying column numbers in compiler messages."
  :version "22.1")

(defcustom compilation-message-face 'underline
  "Face name to use for whole messages.
Faces `compilation-error-face', `compilation-warning-face',
`compilation-info-face', `compilation-line-face' and
`compilation-column-face' get prepended to this, when applicable."
  :type 'face
  :version "22.1")

(defvar compilation-error-face 'compilation-error
  "Face name to use for file name in error messages.")

(defvar compilation-warning-face 'compilation-warning
  "Face name to use for file name in warning messages.")

(defvar compilation-info-face 'compilation-info
  "Face name to use for file name in informational messages.")

(defvar compilation-line-face 'compilation-line-number
  "Face name to use for line numbers in compiler messages.")

(defvar compilation-column-face 'compilation-column-number
  "Face name to use for column numbers in compiler messages.")

;; same faces as dired uses
(defvar compilation-enter-directory-face 'font-lock-function-name-face
  "Face name to use for entering directory messages.")

(defvar compilation-leave-directory-face 'font-lock-builtin-face
  "Face name to use for leaving directory messages.")

(defcustom compilation-auto-jump-to-first-error nil
  "If non-nil, automatically jump to the first error during compilation.

The value `if-location-known' means automatically jump to the first error
if the error's file can be found.  The value `first-known' means jump to
the first error whose file can be found.  Any other non-nil value means
jump to the first error unconditionally."
  :type '(choice (const :tag "Never" nil)
                 (const :tag "Always" t)
                 (const :tag "If location known" if-location-known)
                 (const :tag "First known location" first-known))
  :version "29.1")

(defvar-local compilation-auto-jump-to-next nil
  "If non-nil, automatically jump to the next error encountered.")

;; (defvar-local compilation-buffer-modtime nil
;;   "The buffer modification time, for buffers not associated with files.")

(defvar compilation-skip-to-next-location t
  "If non-nil, skip multiple error messages for the same source location.")

(defcustom compilation-skip-threshold 1
  "Compilation motion commands skip less important messages.
The value can be either 2 -- skip anything less than error, 1 --
skip anything less than warning or 0 -- don't skip any messages.
Note that all messages not positively identified as warning or
info, are considered errors."
  :type '(choice (const :tag "Skip warnings and info" 2)
		 (const :tag "Skip info" 1)
		 (const :tag "No skip" 0))
  :version "22.1")

(defun compilation-set-skip-threshold (level)
  "Switch the `compilation-skip-threshold' level."
  (interactive
   (list
    (mod (if current-prefix-arg
             (prefix-numeric-value current-prefix-arg)
           (1+ compilation-skip-threshold))
         3)))
  (setq compilation-skip-threshold level)
  (message "Skipping %s"
           (pcase compilation-skip-threshold
             (0 "Nothing")
             (1 "Info messages")
             (2 "Warnings and info"))))

(defcustom compilation-skip-visited nil
  "Compilation motion commands skip visited messages if this is t.
Visited messages are ones for which the file, line and column have been jumped
to from the current content in the current compilation buffer, even if it was
from a different message."
  :type 'boolean
  :version "22.1")

(defun compilation-type (type)
  (or (and (car type) (match-end (car type)) 1)
      (and (cdr type) (match-end (cdr type)) 0)
      2))

(defun compilation-face (type)
  (let ((typ (compilation-type type)))
    (cond
     ((eq typ 1)
      compilation-warning-face)
     ((eq typ 0)
      compilation-info-face)
     ((eq typ 2)
      compilation-error-face))))

;;   LOC (or location) is a list of (COLUMN LINE FILE-STRUCTURE nil nil)

;; COLUMN and LINE are numbers parsed from an error message.  COLUMN and maybe
;; LINE will be nil for a message that doesn't contain them.  Then the
;; location refers to an indented beginning of line or beginning of file.
;; Once any location in some file has been jumped to, the list is extended to
;; (COLUMN LINE FILE-STRUCTURE MARKER TIMESTAMP . VISITED)
;; for all LOCs pertaining to that file.
;; MARKER initially points to LINE and COLUMN in a buffer visiting that file.
;; Being a marker it sticks to some text, when the buffer grows or shrinks
;; before that point.  VISITED is t if we have jumped there, else nil.
;; FIXME-omake: TIMESTAMP was used to try and handle "incremental compilation":
;; `omake -P' polls filesystem for changes and recompiles when a file is
;; modified using the same *compilation* buffer. this necessitates
;; re-parsing markers.

;; (cl-defstruct (compilation--loc
;;             (:constructor nil)
;;             (:copier nil)
;;             (:constructor compilation--make-loc
;;                           (file-struct line col marker))
;;             (:conc-name compilation--loc->))
;;   col line file-struct marker timestamp visited)

;; FIXME: We don't use a defstruct because of compilation-assq which looks up
;; and creates part of the LOC (only the first cons cell containing the COL).

(defmacro compilation--make-cdrloc (line file-struct marker)
  `(list ,line ,file-struct ,marker nil))
(defmacro compilation--loc->col (loc) `(car ,loc))
(defmacro compilation--loc->line (loc) `(cadr ,loc))
(defmacro compilation--loc->file-struct (loc) `(nth 2 ,loc))
(defmacro compilation--loc->marker (loc) `(nth 3 ,loc))
;; (defmacro compilation--loc->timestamp (loc) `(nth 4 ,loc))
(defmacro compilation--loc->visited (loc) `(nthcdr 5 ,loc))

;;   FILE-STRUCTURE is a list of
;;   ((FILENAME DIRECTORY) FORMATS (LINE LOC ...) ...)

;; FILENAME is a string parsed from an error message, or the buffer which was
;; compiled.  DIRECTORY is a string obtained by following directory change
;; messages.  DIRECTORY will be nil for an absolute filename or a buffer.
;; FORMATS is a list of formats to apply to FILENAME if a file of that name
;; can't be found.
;; The rest of the list is an alist of elements with LINE as key.  The keys
;; are either nil or line numbers.  If present, nil comes first, followed by
;; the numbers in decreasing order.  The LOCs for each line are again an alist
;; ordered the same way.  Note that the whole file structure is referenced in
;; every LOC.

(defmacro compilation--make-file-struct (file-spec formats &optional loc-tree)
  `(cons ,file-spec (cons ,formats ,loc-tree)))
(defmacro compilation--file-struct->file-spec (fs) `(car ,fs))
(defmacro compilation--file-struct->formats (fs) `(cadr ,fs))
;; The FORMATS field plays the role of ANCHOR in the loc-tree.
(defmacro compilation--file-struct->loc-tree (fs) `(cdr ,fs))

;;   MESSAGE is a list of (LOC TYPE END-LOC)

;; TYPE is 0 for info or 1 for warning if the message matcher identified it as
;; such, 2 otherwise (for a real error).  END-LOC is a LOC pointing to the
;; other end, if the parsed message contained a range.  If the end of the
;; range didn't specify a COLUMN, it defaults to -1, meaning end of line.
;; These are the value of the `compilation-message' text-properties in the
;; compilation buffer.

(cl-defstruct (compilation--message
            (:constructor nil)
            (:copier nil)
            ;; (:type list)                ;Old representation.
            (:constructor compilation--make-message (loc type end-loc rule))
            (:conc-name compilation--message->))
  loc type end-loc rule)

(defvar-local compilation--previous-directory-cache nil
  "A pair (POS . RES) caching the result of previous directory search.
Basically, this pair says that calling
   (previous-single-property-change POS \\='compilation-directory)
returned RES, i.e. there is no change of `compilation-directory' between
POS and RES.")

(defun compilation--flush-directory-cache (start _end)
  (cond
   ((or (not compilation--previous-directory-cache)
        (<= (car compilation--previous-directory-cache) start)))
   ((or (not (cdr compilation--previous-directory-cache))
	(null (marker-buffer (cdr compilation--previous-directory-cache)))
        (<= (cdr compilation--previous-directory-cache) start))
    (set-marker (car compilation--previous-directory-cache) start))
   (t (setq compilation--previous-directory-cache nil))))

(defun compilation--previous-directory (pos)
  "Like (previous-single-property-change POS \\='compilation-directory), but faster."
  ;; This avoids an N² behavior when there's no/few compilation-directory
  ;; entries, in which case each call to previous-single-property-change
  ;; ends up having to walk very far back to find the last change.
  (if (and compilation--previous-directory-cache
           (< pos (car compilation--previous-directory-cache))
           (or (null (cdr compilation--previous-directory-cache))
               (< (cdr compilation--previous-directory-cache) pos)))
      ;; No need to call previous-single-property-change.
      (cdr compilation--previous-directory-cache)

    (let* ((cache (and compilation--previous-directory-cache
                       (<= (car compilation--previous-directory-cache) pos)
                       (car compilation--previous-directory-cache)))
           (prev
            (previous-single-property-change
             pos 'compilation-directory nil cache))
           (res
            (cond
             ((null cache)
              (setq compilation--previous-directory-cache
                    (cons (copy-marker pos) (if prev (copy-marker prev))))
              prev)
             ((and prev (= prev cache))
              (set-marker (car compilation--previous-directory-cache) pos)
              (cdr compilation--previous-directory-cache))
             (t
              (set-marker cache pos)
              (setcdr compilation--previous-directory-cache
                      (copy-marker prev))
              prev))))
      (if (markerp res) (marker-position res) res))))

;; Internal function for calculating the text properties of a directory
;; change message.  The compilation-directory property is important, because it
;; is the stack of nested enter-messages.  Relative filenames on the following
;; lines are relative to the top of the stack.
(defun compilation-directory-properties (idx leave)
  (if leave (setq leave (match-end leave)))
  ;; find previous stack, and push onto it, or if `leave' pop it
  (let ((dir (compilation--previous-directory (match-beginning 0))))
    (setq dir (if dir (or (get-text-property (1- dir) 'compilation-directory)
			  (get-text-property dir 'compilation-directory))))
    `(font-lock-face ,(if leave
                          compilation-leave-directory-face
                        compilation-enter-directory-face)
      compilation-directory ,(if leave
                                 (or (cdr dir)
                                     '(nil)) ; nil only isn't a property-change
                               (cons (match-string-no-properties idx) dir))
      ;; Place a `compilation-message' everywhere we change text-properties
      ;; so compilation--remove-properties can know what to remove.
      compilation-message ,(compilation--make-message nil 0 nil nil)
      mouse-face highlight
      keymap compilation-button-map
      help-echo "mouse-2: visit destination directory")))

;; Data type `reverse-ordered-alist' retriever.  This function retrieves the
;; KEY element from the ALIST, creating it in the right position if not already
;; present. ALIST structure is
;; '(ANCHOR (KEY1 ...) (KEY2 ...)... (KEYn ALIST ...))
;; ANCHOR is ignored, but necessary so that elements can be inserted.  KEY1
;; may be nil.  The other KEYs are ordered backwards so that growing line
;; numbers can be inserted in front and searching can abort after half the
;; list on average.
(eval-when-compile		    ;Don't keep it at runtime if not needed.
(defmacro compilation-assq (key alist)
  `(let* ((l1 ,alist)
	  (l2 (cdr l1)))
     (car (if (if (null ,key)
		  (if l2 (null (caar l2)))
		(while (if l2 (if (caar l2) (< ,key (caar l2)) t))
		  (setq l1 l2
			l2 (cdr l1)))
		(if l2 (eq ,key (caar l2))))
	      l2
	    (setcdr l1 (cons (list ,key) l2)))))))

(defun compilation--file-known-p ()
  "Say whether the file under point can be found."
  (when-let* ((msg (get-text-property (point) 'compilation-message))
              (loc (compilation--message->loc msg))
              (elem (compilation-find-file-1
                     (point-marker)
                     (caar (compilation--loc->file-struct loc))
                     (cadr (car (compilation--loc->file-struct loc)))
                     (compilation--file-struct->formats
                      (compilation--loc->file-struct loc)))))
    (car elem)))

(defun compilation-auto-jump (buffer pos)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (goto-char pos)
      (let ((win (get-buffer-window buffer 0)))
        (if win (set-window-point win pos)))
      (when compilation-auto-jump-to-first-error
        (cl-case compilation-auto-jump-to-first-error
          (if-location-known
           (when (compilation--file-known-p)
	     (compile-goto-error)))
          (first-known
           (let (match)
             (while (and (not (compilation--file-known-p))
                         (setq match (text-property-search-forward
                                      'compilation-message nil nil t)))
               (goto-char (prop-match-beginning match))))
           (when (compilation--file-known-p)
	     (compile-goto-error)))
          (otherwise
           (compile-goto-error)))))))

;; This function is the central driver, called when font-locking to gather
;; all information needed to later jump to corresponding source code.
;; Return a property list with all meta information on this error location.

(defun compilation-error-properties (file line end-line col end-col type fmt
                                          rule)
  (unless (text-property-not-all (match-beginning 0) (point)
                                 'compilation-message nil)
    (if file
        (when (stringp
               (setq file (if (functionp file) (funcall file)
                            (match-string-no-properties file))))
	  (let ((dir
	         (unless (file-name-absolute-p file)
                   (let ((pos (compilation--previous-directory
                               (match-beginning 0))))
                     (when pos
                       (or (get-text-property (1- pos) 'compilation-directory)
                           (get-text-property pos 'compilation-directory)))))))
	    (setq file (cons file (car dir)))))
      ;; This message didn't mention one, get it from previous
      (let ((prev-pos
	     ;; Find the previous message.
	     (previous-single-property-change (point) 'compilation-message)))
	(if prev-pos
	    ;; Get the file structure that belongs to it.
	    (let* ((prev
		    (or (get-text-property (1- prev-pos) 'compilation-message)
			(get-text-property prev-pos 'compilation-message)))
		   (prev-file-struct
		    (and prev
			 (compilation--loc->file-struct
			  (compilation--message->loc prev)))))

	      ;; Construct FILE . DIR from that.
	      (if prev-file-struct
		  (setq file (cons (caar prev-file-struct)
				   (cadr (car prev-file-struct)))))))
	(unless file
	  (setq file '("*unknown*")))))
    ;; All of these fields are optional, get them only if we have an index, and
    ;; it matched some part of the message.
    (setq line
          (if (functionp line) (funcall line)
            (and line
	         (setq line (match-string-no-properties line))
                 (string-to-number line))))
    (setq end-line
          (if (functionp end-line) (funcall end-line)
            (and end-line
	         (setq end-line (match-string-no-properties end-line))
                 (string-to-number end-line))))
    (setq col
          (if (functionp col) (funcall col)
            (and col
                 (setq col (match-string-no-properties col))
                 (string-to-number col))))
    (setq end-col
          (let ((ec (if (functionp end-col)
                        (funcall end-col)
                      (and end-col (match-beginning end-col)
                           (string-to-number
                            (match-string-no-properties end-col))))))
            (if ec
                (1+ ec)     ; Add one to get an exclusive upper bound.
              (and end-line -1))))
    (if (consp type)            ; not a static type, check what it is.
	(setq type (or (and (car type) (match-end (car type)) 1)
		       (and (cdr type) (match-end (cdr type)) 0)
		       2)))
    ;; Remove matches like /bin/sh and do other file name transforms.
    (save-match-data
      (when-let* ((file-name
                   (and (consp file)
                        (not (bufferp (car file)))
                        (if (cdr file)
                            (expand-file-name (car file) (cdr file))
                          (car file)))))
        (cl-loop for (regexp replacement)
                 in compilation-transform-file-match-alist
                 when (string-match regexp file-name)
                 return (if replacement
                            (setq file (list (replace-match replacement nil nil
                                                            file-name)))
                          (setq file nil)))))
    (if (not file)
        ;; If we ignored all the files with errors on this line, then
        ;; return nil.
        nil
      (when (and compilation-auto-jump-to-next
                 (>= type compilation-skip-threshold))
        (kill-local-variable 'compilation-auto-jump-to-next)
        (run-with-timer 0 nil 'compilation-auto-jump
                        (current-buffer) (match-beginning 0)))

      (compilation-internal-error-properties
       file line end-line col end-col type fmt rule))))

(defun compilation-beginning-of-line (&optional n)
  "Like `beginning-of-line', but accounts for lines hidden by `selective-display'."
  (if (or (not (eq selective-display t))
          (null n)
          (= n 1))
      (beginning-of-line n)
    (re-search-forward "[\n\r]" nil 'end (1- n))
    (if (< n 0)
        (beginning-of-line))))

(defun compilation-move-to-column (col screen)
  "Go to column COL on the current line.
If SCREEN is non-nil, columns are screen columns, otherwise, they are
just char-counts."
  (setq col (- col compilation-first-column))
  (if screen
      ;; Presumably, the compilation tool doesn't know about our current
      ;; `tab-width' setting, so it probably assumed 8-wide TABs (bug#21038).
      (let ((tab-width 8)) (move-to-column (max col 0)))
    (goto-char (min (+ (line-beginning-position) col) (line-end-position)))))

(defun compilation-internal-error-properties (file line end-line col end-col
                                              type fmts rule)
  "Get the meta-info that will be added as text-properties.
LINE, END-LINE, COL, END-COL are integers or nil.
TYPE can be 0, 1, or 2, meaning error, warning, or just info.
FILE should be (FILENAME) or (RELATIVE-FILENAME . DIRNAME) or (BUFFER) or
nil.
FMTS is a list of format specs for transforming the file name.
RULE is the name (symbol) of the rule used or nil if anonymous.
 (See `compilation-error-regexp-alist'.)"
  (unless file (setq file '("*unknown*")))
  (let* ((file-struct (compilation-get-file-structure file fmts))
	 ;; Get first already existing marker (if any has one, all have one).
	 ;; Do this first, as the compilation-assq's may create new nodes.
	 (marker-line	; a line structure
          (cadr (compilation--file-struct->loc-tree file-struct)))
	 (marker
          (if marker-line (compilation--loc->marker (cadr marker-line))))
	 (screen-columns compilation-error-screen-columns)
	 (first-column compilation-first-column)
	 end-marker loc end-loc)
    (if (not (and marker (marker-buffer marker)))
	(setq marker nil)		; no valid marker for this file
      (unless line (setq line 1))       ; normalize no linenumber to line 1
      (catch 'marker			; find nearest loc, at least one exists
	(dolist (x (cddr (compilation--file-struct->loc-tree
                          file-struct)))	; Loop over remaining lines.
	  (if (> (car x) line)		; Still bigger.
	      (setq marker-line x)
	    (if (> (- (or (car marker-line) 1) line)
		   (- line (car x)))	; Current line is nearer.
		(setq marker-line x))
	    (throw 'marker t))))
      (setq marker (compilation--loc->marker (cadr marker-line))
	    marker-line (or (car marker-line) 1))
      (with-current-buffer (marker-buffer marker)
        (let ((screen-columns
               ;; Obey the compilation-error-screen-columns of the target
               ;; buffer if its major mode set it buffer-locally.
               (if (local-variable-p 'compilation-error-screen-columns)
                   compilation-error-screen-columns screen-columns))
	      (compilation-first-column
               (if (local-variable-p 'compilation-first-column)
                   compilation-first-column first-column)))
          (save-excursion
	  (save-restriction
	    (widen)
	    (goto-char (marker-position marker))
	    ;; Set end-marker if appropriate and go to line.
	    (if (not (or end-col end-line))
		(compilation-beginning-of-line (- line marker-line -1))
	      (compilation-beginning-of-line (- (or end-line line)
                                                marker-line -1))
	      (if (or (null end-col) (< end-col 0))
		  (end-of-line)
		(compilation-move-to-column end-col screen-columns))
	      (setq end-marker (point-marker))
	      (when end-line
                (compilation-beginning-of-line (- line end-line -1))))
	    (if col
		(compilation-move-to-column col screen-columns)
	      (forward-to-indentation 0))
	    (setq marker (point-marker)))))))

    (setq loc (compilation-assq line (compilation--file-struct->loc-tree
                                      file-struct)))
    (setq end-loc
          (if end-line
              (compilation-assq
               end-col (compilation-assq
                        end-line (compilation--file-struct->loc-tree
                                  file-struct)))
            (if end-col			; use same line element
                (compilation-assq end-col loc))))
    (setq loc (compilation-assq col loc))
    ;; If they are new, make the loc(s) reference the file they point to.
    ;; FIXME-omake: there's a problem with timestamps here: the markers
    ;; relative to which we computed the current `marker' have a timestamp
    ;; almost guaranteed to be different from compilation-buffer-modtime, so if
    ;; we use their timestamp, we'll never use `loc' since the timestamp won't
    ;; match compilation-buffer-modtime, and if we use
    ;; compilation-buffer-modtime then we have different timestamps for
    ;; locations that were computed together, which doesn't make sense either.
    ;; I think this points to a fundamental problem in our approach to the
    ;; "omake -P" problem.  --Stef
    (or (cdr loc)
        (setcdr loc (compilation--make-cdrloc line file-struct marker)))
    (if end-loc
	(or (cdr end-loc)
	    (setcdr end-loc
                    (compilation--make-cdrloc (or end-line line) file-struct
                                              end-marker))))

    ;; Must start with face
    `(font-lock-face ,compilation-message-face
      compilation-message ,(compilation--make-message loc type end-loc rule)
      help-echo ,(if col
                     "mouse-2: visit this file, line and column"
                   (if line
                       "mouse-2: visit this file and line"
                     "mouse-2: visit this file"))
      keymap compilation-button-map
      mouse-face highlight)))

(defun compilation--put-prop (matchnum prop val)
  (when (and (integerp matchnum) (match-beginning matchnum))
    (put-text-property
     (match-beginning matchnum) (match-end matchnum)
     prop val)))

(defun compilation--remove-properties (&optional start end)
  (with-silent-modifications
    ;; When compile.el used font-lock directly, we could just remove all
    ;; our text-properties in one go, but now that we manually place
    ;; font-lock-face, we have to be careful to only remove the font-lock-face
    ;; we placed.
    ;; (remove-list-of-text-properties
    ;;  (or start (point-min)) (or end (point-max))
    ;;  '(compilation-debug compilation-directory compilation-message
    ;;    font-lock-face help-echo mouse-face))
    (let (next)
      (unless start (setq start (point-min)))
      (unless end (setq end (point-max)))
      (compilation--flush-directory-cache start end)
      (while
          (progn
            (setq next (or (next-single-property-change
                            start 'compilation-message nil end)
                           end))
            (when (get-text-property start 'compilation-message)
              (remove-list-of-text-properties
               start next
               '(compilation-debug compilation-directory compilation-message
                 font-lock-face help-echo mouse-face)))
            (< next end))
        (setq start next)))))

(defun compilation--parse-region (start end)
  (goto-char end)
  (unless (bolp)
    ;; We generally don't like to parse partial lines.
    (cl-assert (eobp))
    (when (let ((proc (get-buffer-process (current-buffer))))
            (and proc (memq (process-status proc) '(run open))))
      (setq end (line-beginning-position))))
  (compilation--remove-properties start end)
  ;; compilation-directory-matcher is the only part that really needs to be
  ;; parsed sequentially.  So we could split it out, handle directories
  ;; like syntax-propertize, and the rest as font-lock-keywords.  But since
  ;; we want to have it work even when font-lock is off, we'd then need to
  ;; use our own compilation-parsed text-property to keep track of the parts
  ;; that have already been parsed.
  (goto-char start)
  (while (re-search-forward (car compilation-directory-matcher)
                            end t)
    (compilation--flush-directory-cache (match-beginning 0) (match-end 0))
    (when compilation-debug
      (font-lock-append-text-property
       (match-beginning 0) (match-end 0)
       'compilation-debug
       (vector 'directory compilation-directory-matcher)))
    (dolist (elt (cdr compilation-directory-matcher))
      (add-text-properties (match-beginning (car elt))
                           (match-end (car elt))
                           (compilation-directory-properties
                            (car elt) (cdr elt)))))

  (compilation-parse-errors start end))

(defun compilation--note-type (type)
  "Note that a new message with severity TYPE was seen.
This updates the appropriate variable used by the mode-line."
  (cl-case type
    (0 (incf compilation-num-infos-found))
    (1 (incf compilation-num-warnings-found))
    (2 (incf compilation-num-errors-found))))

(defun compilation-parse-errors (start end &rest rules)
  "Parse errors between START and END.
The errors recognized are the ones specified in RULES which default
to `compilation-error-regexp-alist' if RULES is nil."
  (let ((case-fold-search compilation-error-case-fold-search)
        (omake-included (memq 'omake compilation-error-regexp-alist)))
    (dolist (rule-item (or rules compilation-error-regexp-alist))
      (let* ((item
              (if (symbolp rule-item)
                  (cdr (assq rule-item compilation-error-regexp-alist-alist))
                rule-item))
             (pat (car item))
             (file (nth 1 item))
             (line (nth 2 item))
             (col (nth 3 item))
             (type (nth 4 item))
             (rule (and (symbolp rule-item) rule-item))
             end-line end-col fmt
             props)

        ;; omake reports some error indented, so skip the indentation.
        ;; another solution is to modify (some?) regexps in
        ;; `compilation-error-regexp-alist'.
        ;; note that omake usage is not limited to ocaml and C (for stubs).
        ;; FIXME-omake: Doing it here seems wrong, at least it should depend on
        ;; whether or not omake's own error messages are recognized.
        (cond
         ((or (not omake-included) (not pat))
          nil)
         ((string-match "\\`\\([^^]\\|\\^\\( \\*\\|\\[\\)\\)" pat)
          nil) ;; Not anchored or anchored but already allows empty spaces.
         (t (setq pat (concat "^\\(?:      \\)?" (substring pat 1)))))

        (if (and (consp file) (not (functionp file)))
            (setq fmt (cdr file)
                  file (car file)))
        (if (and (consp line) (not (functionp line)))
            (setq end-line (cdr line)
                  line (car line)))
        (if (and (consp col) (not (functionp col)))
            (setq end-col (cdr col)
                  col (car col)))

        (unless (or (null (nth 5 item)) (integerp (nth 5 item)))
          (error "HYPERLINK should be an integer: %s" (nth 5 item)))

        (goto-char start)
        (while (and pat (re-search-forward pat end t))
          (when (setq props (compilation-error-properties
                             file line end-line col end-col
                             (or type 2) fmt rule))

            (when file
              (let ((this-type (if (consp type)
                                   (compilation-type type)
                                 (or type 2))))
                (compilation--note-type this-type)

                (compilation--put-prop
                 file 'font-lock-face
                 (symbol-value (aref [compilation-info-face
                                      compilation-warning-face
                                      compilation-error-face]
                                     this-type)))))

            (compilation--put-prop
             line 'font-lock-face compilation-line-face)
            (compilation--put-prop
             end-line 'font-lock-face compilation-line-face)

            (compilation--put-prop
             col 'font-lock-face compilation-column-face)
            (compilation--put-prop
             end-col 'font-lock-face compilation-column-face)

            ;; Obey HIGHLIGHT.
            (dolist (extra-item (nthcdr 6 item))
              (let ((mn (pop extra-item)))
                (when (match-beginning mn)
                  (let ((face (eval (car extra-item))))
                    (cond
                     ((null face))
                     ((or (symbolp face) (stringp face))
                      (put-text-property
                       (match-beginning mn) (match-end mn)
                       'font-lock-face face))
		     ((and (listp face)
			   (eq (car face) 'face)
			   (or (symbolp (cadr face))
			       (stringp (cadr face))))
                      (compilation--put-prop mn 'font-lock-face (cadr face))
                      (add-text-properties
                       (match-beginning mn) (match-end mn)
                       (nthcdr 2 face)))
                     (t
                      (error "Don't know how to handle face %S"
                             face)))))))
            (let ((mn (or (nth 5 item) 0)))
              (when compilation-debug
                (font-lock-append-text-property
                 (match-beginning 0) (match-end 0)
                 'compilation-debug (vector 'std item props)))
              (add-text-properties
               (match-beginning mn) (match-end mn)
               (cddr props))
              (font-lock-append-text-property
               (match-beginning mn) (match-end mn)
               'font-lock-face (cadr props)))))))))

(defvar-local compilation--parsed -1)

(defun compilation--ensure-parse (limit)
  "Make sure the text has been parsed up to LIMIT."
  (save-excursion
    (goto-char limit)
    (setq limit (line-beginning-position 2))
    (unless (markerp compilation--parsed)
      ;; We use a marker for compilation--parsed so that users (such as
      ;; grep.el) don't need to flush-parse when they modify the buffer
      ;; in a way that impacts buffer positions but does not require
      ;; re-parsing.
      (setq compilation--parsed
            (set-marker (make-marker)
                        (save-excursion
                          (goto-char (point-min))
                          (text-property-search-forward 'compilation-annotation)
                          ;; If we have no end marker, this will be
                          ;; `point-min' still.
                          (point)))))
    (when (< compilation--parsed limit)
      (let ((start (max compilation--parsed (point-min))))
        (move-marker compilation--parsed limit)
        (goto-char start)
        (forward-line 0)  ;Not line-beginning-position: ignore (comint) fields.
        (while (and (not (bobp))
                    (get-text-property (1- (point)) 'compilation-multiline))
          (forward-line -1))
        (with-silent-modifications
          (compilation--parse-region (point) compilation--parsed)))))
  nil)

(defun compilation--flush-parse (start _end)
  "Mark the region between START and END for re-parsing."
  (if (markerp compilation--parsed)
      (move-marker compilation--parsed (min start compilation--parsed))))

(defun compilation-mode-font-lock-keywords ()
  "Return expressions to highlight in Compilation mode."
  (append
   '((compilation--ensure-parse))
   compilation-mode-font-lock-keywords))

(defun compilation-read-command (command)
  (read-shell-command "Compile command: " command
                      (if (equal (car compile-history) command)
                          '(compile-history . 1)
                        'compile-history)))


;;;###autoload
(defun compile (command &optional comint)
  "Compile the program including the current buffer.  Default: run `make'.
Runs COMMAND, a shell command, in a separate process asynchronously
with output going to the buffer `*compilation*'.

You can then use the command \\[next-error] to find the next error message
and move to the source code that caused it.

If optional second arg COMINT is t the buffer will be in Comint mode with
`compilation-shell-minor-mode'.

Interactively, prompts for the command if the variable
`compilation-read-command' is non-nil; otherwise uses `compile-command'.
With prefix arg, always prompts.
Additionally, with universal prefix arg, compilation buffer will be in
comint mode, i.e. interactive.

To run more than one compilation at once, start one then rename
the `*compilation*' buffer to some other name with
\\[rename-buffer].  Then _switch buffers_ and start the new compilation.
It will create a new `*compilation*' buffer.

On most systems, termination of the main compilation process
kills its subprocesses.

The name used for the buffer is actually whatever is returned by
the function in `compilation-buffer-name-function', so you can set that
to a function that generates a unique name."
  (interactive
   (list
    (let ((command (eval compile-command)))
      (if (or compilation-read-command current-prefix-arg)
	  (compilation-read-command command)
	command))
    (consp current-prefix-arg)))
  (unless (equal command (eval compile-command))
    (setq compile-command command))
  (save-some-buffers (not compilation-ask-about-save)
                     compilation-save-buffers-predicate)
  (setq-default compilation-directory default-directory)
  (compilation-start command comint))

;; run compile with the default command line
;;;###autoload
(defun recompile (&optional edit-command)
  "Re-compile the program including the current buffer.
If this is run in a Compilation mode buffer, reuse the arguments from the
original use.  Otherwise, recompile using `compile-command'.
If the optional argument `edit-command' is non-nil, the command can be edited."
  (interactive "P")
  (save-some-buffers (not compilation-ask-about-save)
                     compilation-save-buffers-predicate)
  (let ((default-directory (or compilation-directory default-directory))
	(command (eval compile-command)))
    (when edit-command
      (setq command (compilation-read-command (or (car compilation-arguments)
						  command)))
      (if compilation-arguments (setcar compilation-arguments command)))
    (apply #'compilation-start (or compilation-arguments (list command)))))

(defcustom compilation-scroll-output nil
  "Non-nil to scroll the *compilation* buffer window as output appears.

Setting it causes the Compilation mode commands to put point at the
end of their output window so that the end of the output is always
visible rather than the beginning.

The value `first-error' stops scrolling at the first error, and leaves
point on its location in the *compilation* buffer."
  :type '(choice (const :tag "No scrolling" nil)
		 (const :tag "Scroll compilation output" t)
		 (const :tag "Stop scrolling at the first error" first-error))
  :version "20.3")


(defun compilation-buffer-name (name-of-mode _mode-command name-function)
  "Return the name of a compilation buffer to use.
If NAME-FUNCTION is non-nil, call it with one argument NAME-OF-MODE
to determine the buffer name.
Likewise if `compilation-buffer-name-function' is non-nil.
If current buffer has the NAME-OF-MODE major mode,
return the name of the current buffer, so that it gets reused.
Otherwise, construct a buffer name from NAME-OF-MODE."
  (funcall (or name-function
	       compilation-buffer-name-function
               #'compilation--default-buffer-name)
           name-of-mode))

;;;###autoload
(defun compilation--default-buffer-name (name-of-mode)
  (cond ((or (eq major-mode (intern-soft name-of-mode))
             (eq major-mode (intern-soft (concat name-of-mode "-mode"))))
	 (buffer-name))
	(t
	 (concat "*" (downcase name-of-mode) "*"))))

(defcustom compilation-always-kill nil
  "If t, always kill a running compilation process before starting a new one.
If nil, ask to kill it."
  :type 'boolean
  :version "24.3")

(defcustom compilation-max-output-line-length 400
  "Output lines that are longer than this value will be hidden.
If nil, don't hide anything."
  :type '(choice (const :tag "Hide nothing" nil)
                 integer)
  :version "29.1")

(defun compilation--update-in-progress-mode-line ()
  ;; `compilation-in-progress' affects the mode-line of all
  ;; buffers when it changes from nil to non-nil or vice-versa.
  (unless compilation-in-progress (force-mode-line-update t)))

(defun compilation-insert-annotation (&rest args)
  "Insert ARGS at point, adding the `compilation-annotation' text property.
This property is used to distinguish output of the compilation
process from additional information inserted by Emacs."
  (let ((start (point)))
    (apply #'insert args)
    (put-text-property start (point) 'compilation-annotation t)))

(defvar-local compilation--start-time nil
  "The time when the compilation started as returned by `float-time'.")

(defun compilation--downcase-mode-name (mode)
  "Downcase the name of major MODE, even if MODE is not a string.
The function `downcase' will barf if passed the name of a `major-mode'
which is not a string, but instead a symbol or a list."
  (downcase (format-mode-line mode)))

;;;###autoload
(defun compilation-start (command &optional mode name-function highlight-regexp
                                  continue)
  "Run compilation command COMMAND (low level interface).
If COMMAND starts with a cd command, that becomes the `default-directory'.
The rest of the arguments are optional; for them, nil means use the default.

MODE is the major mode to set in the compilation buffer.  Mode
may also be t meaning use `compilation-shell-minor-mode' under `comint-mode'.

If NAME-FUNCTION is non-nil, call it with one argument (the mode name)
to determine the buffer name.  Otherwise, the default is to
reuses the current buffer if it has the proper major mode,
else use or create a buffer with name based on the major mode.

If HIGHLIGHT-REGEXP is non-nil, `next-error' will temporarily highlight
the matching section of the visited source line; the default is to use the
global value of `compilation-highlight-regexp'.

If CONTINUE is non-nil, the buffer won't be emptied before
compilation is started.  This can be useful if you wish to
combine the output from several compilation commands in the same
buffer.  The new output will be at the end of the buffer, and
point is not changed.

Returns the compilation buffer created."
  (or mode (setq mode 'compilation-mode))
  (let* ((name-of-mode
	  (if (eq mode t)
	      "compilation"
	    (replace-regexp-in-string "-mode\\'" "" (symbol-name mode))))
	 (thisdir default-directory)
	 (thisenv compilation-environment)
         (buffer-path (and (local-variable-p 'exec-path) exec-path))
         (buffer-env (and (local-variable-p 'process-environment)
                          process-environment))
	 outwin outbuf)
    (with-current-buffer
	(setq outbuf
	      (get-buffer-create
               (compilation-buffer-name name-of-mode mode name-function)))
      (let ((comp-proc (get-buffer-process (current-buffer))))
      (if comp-proc
          (if (or (not (eq (process-status comp-proc) 'run))
                  (eq (process-query-on-exit-flag comp-proc) nil)
                  (yes-or-no-p
                   (format "A %s process is running; kill it? "
                           name-of-mode)))
              (condition-case ()
                  (progn
                    (interrupt-process comp-proc)
                    (sit-for 1)
                    (delete-process comp-proc))
                (error nil))
            (error "Cannot have two processes in `%s' at once"
                   (buffer-name)))))
      ;; first transfer directory from where M-x compile was called
      (setq default-directory thisdir)
      ;; Make compilation buffer read-only.  The filter can still write it.
      ;; Clear out the compilation buffer.
      (let ((inhibit-read-only t)
	    (default-directory thisdir))
	;; Then evaluate a cd command if any, but don't perform it yet, else
	;; start-command would do it again through the shell: (cd "..") AND
	;; sh -c "cd ..; make"
	(cd (cond
             ((not (string-match "\\`\\s *cd\\(?:\\s +\\(\\S +?\\|'[^']*'\\|\"\\(?:[^\"`$\\]\\|\\\\.\\)*\"\\)\\)?\\s *[;&\n]"
                                 command))
              default-directory)
             ((not (match-end 1)) "~")
             ((eq (aref command (match-beginning 1)) ?\')
              (substring command (1+ (match-beginning 1))
                         (1- (match-end 1))))
             ((eq (aref command (match-beginning 1)) ?\")
              (replace-regexp-in-string
               "\\\\\\(.\\)" "\\1"
               (substring command (1+ (match-beginning 1))
                          (1- (match-end 1)))))
             ;; Try globbing as well (bug#15417).
             (t (let* ((substituted-dir
                        (substitute-env-vars (match-string 1 command)))
                       ;; FIXME: This also tries to expand `*' that were
                       ;; introduced by the envvar expansion!
                       (expanded-dir
                        (file-expand-wildcards substituted-dir)))
                  (if (= (length expanded-dir) 1)
                      (car expanded-dir)
                    substituted-dir)))))
        (if continue
            (progn
              ;; Save the point so we can restore it.
              (setq continue (point))
              (goto-char (point-max)))
	  (erase-buffer))
	;; Select the desired mode.
	(if (not (eq mode t))
            (progn
              (buffer-disable-undo)
              (funcall mode))
	  (setq buffer-read-only nil)
	  (with-no-warnings (comint-mode))
	  (compilation-shell-minor-mode))
        ;; Remember the original dir, so we can use it when we recompile.
        ;; default-directory' can't be used reliably for that because it may be
        ;; affected by the special handling of "cd ...;".
        ;; NB: must be done after (funcall mode) as that resets local variables
        (setq-local compilation-directory thisdir)
        (setq-local compilation-environment thisenv)
        (if buffer-path
            (setq-local exec-path buffer-path)
          (kill-local-variable 'exec-path))
        (if buffer-env
            (setq-local process-environment buffer-env)
          (kill-local-variable 'process-environment))
	(if highlight-regexp
            (setq-local compilation-highlight-regexp highlight-regexp))
        (if (or compilation-auto-jump-to-first-error
		(eq compilation-scroll-output 'first-error))
            (setq-local compilation-auto-jump-to-next t))
        (when (zerop (buffer-size))
	  ;; Output a mode setter, for saving and later reloading this buffer.
	  (compilation-insert-annotation
           "-*- mode: " name-of-mode
           "; default-directory: "
           (prin1-to-string (abbreviate-file-name default-directory))
	   " -*-\n"))
        (compilation-insert-annotation
         (format "%s started at %s\n\n"
                 mode-name
		 (substring (current-time-string) 0 19))
	 command "\n")
        (setq compilation--start-time (float-time))
	(setq thisdir default-directory))
      (set-buffer-modified-p nil))
    ;; Pop up the compilation buffer.
    ;; https://lists.gnu.org/r/emacs-devel/2007-11/msg01638.html
    (setq outwin (display-buffer outbuf '(nil (allow-no-window . t))))
    (with-current-buffer outbuf
      (let ((process-environment
	     (append
	      compilation-environment
              (and (derived-mode-p 'comint-mode)
                   (comint-term-environment))
	      (list (format "INSIDE_EMACS=%s,compile" emacs-version))
              ;; Some external programs (like "git grep") use a pager;
              ;; defeat that.
              (list "PAGER=")
	      (copy-sequence process-environment))))
        (setq-local compilation-arguments
                    (list command mode name-function highlight-regexp))
        (setq-local revert-buffer-function 'compilation-revert-buffer)
	(when (and outwin
                   (not continue)
	           ;; Forcing the window-start overrides the usual redisplay
	           ;; feature of bringing point into view, so setting the
	           ;; window-start to top of the buffer risks losing the
	           ;; effect of moving point to EOB below, per
	           ;; compilation-scroll-output, if the command is long
	           ;; enough to push point outside of the window.  This
	           ;; could happen, e.g., in `rgrep'.
	           (not compilation-scroll-output))
	  (set-window-start outwin (point-min)))

	;; Position point as the user will see it.
	(let ((desired-visible-point
	       (cond
                (continue continue)
	        ;; Put it at the end if `compilation-scroll-output' is set.
                (compilation-scroll-output (point-max))
		;; Normally put it at the top.
                (t (point-min)))))
	  (goto-char desired-visible-point)
	  (when (and outwin (not (eq outwin (selected-window))))
	    (set-window-point outwin desired-visible-point)))

	;; The setup function is called before compilation-set-window-height
	;; so it can set the compilation-window-height buffer locally.
	(if compilation-process-setup-function
	    (funcall compilation-process-setup-function))
	(and outwin (compilation-set-window-height outwin))
	;; Start the compilation.
	(if (fboundp 'make-process)
	    (let ((proc
		   (if (eq mode t)
                       ;; On remote hosts, the local `shell-file-name'
                       ;; might be useless.
                       (with-connection-local-variables
		        ;; comint uses `start-file-process'.
		        (get-buffer-process
			 (with-no-warnings
			   (comint-exec
			    outbuf (compilation--downcase-mode-name mode-name)
			    shell-file-name
			    nil `(,shell-command-switch ,command)))))
		     (start-file-process-shell-command
                      (compilation--downcase-mode-name mode-name)
		      outbuf command))))
              ;; Make the buffer's mode line show process state.
              (setq mode-line-process
                    '((:propertize ":%s" face compilation-mode-line-run)
                      compilation-mode-line-errors))

              ;; Set the process as killable without query by default.
              ;; This allows us to start a new compilation without
              ;; getting prompted.
              (when compilation-always-kill
                (set-process-query-on-exit-flag proc nil))

              (set-process-sentinel proc #'compilation-sentinel)
              (unless (eq mode t)
                ;; Keep the comint filter, since it's needed for proper
		;; handling of the prompts.
		(set-process-filter proc #'compilation-filter))
	      ;; Use (point-max) here so that output comes in
	      ;; after the initial text,
	      ;; regardless of where the user sees point.
	      (set-marker (process-mark proc) (point-max) outbuf)
	      (when compilation-disable-input
		(condition-case nil
		    (process-send-eof proc)
		  ;; The process may have exited already.
		  (error nil)))
	      (run-hook-with-args 'compilation-start-hook proc)
              (compilation--update-in-progress-mode-line)
	      (push proc compilation-in-progress))
	  ;; No asynchronous processes available.
	  (message "Executing `%s'..." command)
	  ;; Fake mode line display as if `start-process' were run.
	  (setq mode-line-process
		'((:propertize ":run" face compilation-mode-line-run)
                  compilation-mode-line-errors))
	  (force-mode-line-update)
	  (sit-for 0)			; Force redisplay
	  (save-excursion
	    ;; Insert the output at the end, after the initial text,
	    ;; regardless of where the user sees point.
	    (goto-char (point-max))
	    (let* ((inhibit-read-only t) ; call-process needs to modify outbuf
		   (compilation-filter-start (point))
		   (status (call-process shell-file-name nil outbuf nil "-c"
					 command)))
	      (run-hooks 'compilation-filter-hook)
	      (cond ((numberp status)
		     (compilation-handle-exit
		      'exit status
		      (if (zerop status)
			  "finished\n"
			(format "exited abnormally with code %d\n" status))))
		    ((stringp status)
		     (compilation-handle-exit 'signal status
					      (concat status "\n")))
		    (t
		     (compilation-handle-exit 'bizarre status status)))))
	  (set-buffer-modified-p nil)
	  (message "Executing `%s'...done" command)))
      ;; Now finally cd to where the shell started make/grep/...
      (setq default-directory thisdir)
      ;; The following form selected outwin ever since revision 1.183,
      ;; so possibly messing up point in some other window (bug#1073).
      ;; Moved into the scope of with-current-buffer, though still with
      ;; complete disregard for the case when compilation-scroll-output
      ;; equals 'first-error (martin 2008-10-04).
      (when compilation-scroll-output
	(goto-char (point-max))))

    ;; Make it so the next C-x ` will use this buffer.
    (setq next-error-last-buffer outbuf)))

(defun compilation-set-window-height (window)
  "Set the height of WINDOW according to `compilation-window-height'."
  (let ((height (buffer-local-value 'compilation-window-height (window-buffer window))))
    (and height
	 (window-full-width-p window)
	 ;; If window is alone in its frame, aside from a minibuffer,
	 ;; don't change its height.
	 (not (eq window (frame-root-window (window-frame window))))
	 ;; Stef said that doing the saves in this order is safer:
	 (save-excursion
	   (save-selected-window
	     (select-window window)
	     (enlarge-window (- height (window-height))))))))

(defvar compilation-menu-map
  (let ((map (make-sparse-keymap "Errors"))
	(opt-map (make-sparse-keymap "Skip")))
    (define-key map [stop-subjob]
      '(menu-item "Stop Compilation" kill-compilation
		  :help "Kill the process made by the M-x compile or M-x grep commands"))
    (define-key map [compilation-mode-separator3]
      '("----" . nil))
    (define-key map [compilation-next-error-follow-minor-mode]
      '(menu-item
	"Auto Error Display" next-error-follow-minor-mode
	:help "Display the error under cursor when moving the cursor"
	:button (:toggle . next-error-follow-minor-mode)))
    (define-key map [compilation-skip]
      (cons "Skip Less Important Messages" opt-map))
    (define-key opt-map [compilation-skip-none]
      '(menu-item "Don't Skip Any Messages"
		  (lambda ()
		    (interactive)
		    (customize-set-variable 'compilation-skip-threshold 0))
		  :help "Do not skip any type of messages"
		  :button (:radio . (eq compilation-skip-threshold 0))))
    (define-key opt-map [compilation-skip-info]
      '(menu-item "Skip Info"
		  (lambda ()
		    (interactive)
		    (customize-set-variable 'compilation-skip-threshold 1))
		  :help "Skip anything less than warning"
		  :button (:radio . (eq compilation-skip-threshold 1))))
    (define-key opt-map [compilation-skip-warning-and-info]
      '(menu-item "Skip Warnings and Info"
		  (lambda ()
		    (interactive)
		    (customize-set-variable 'compilation-skip-threshold 2))
		  :help "Skip over Warnings and Info, stop for errors"
		  :button (:radio . (eq compilation-skip-threshold 2))))
    (define-key map [compilation-mode-separator2]
      '("----" . nil))
    (define-key map [compilation-first-error]
      '(menu-item "First Error" first-error
		  :help "Restart at the first error, visit corresponding source code"))
    (define-key map [compilation-previous-error]
      '(menu-item "Previous Error" previous-error
		  :help "Visit previous `next-error' message and corresponding source code"))
    (define-key map [compilation-next-error]
      '(menu-item "Next Error" next-error
		  :help "Visit next `next-error' message and corresponding source code"))
    map))

(defvar compilation-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map [mouse-2] 'compile-goto-error)
    (define-key map [follow-link] 'mouse-face)
    (define-key map "\C-c\C-c" 'compile-goto-error)
    (define-key map "\C-m" 'compile-goto-error)
    (define-key map "\C-o" 'compilation-display-error)
    (define-key map "\C-c\C-k" 'kill-compilation)
    (define-key map "\M-n" 'compilation-next-error)
    (define-key map "\M-p" 'compilation-previous-error)
    (define-key map "\M-{" 'compilation-previous-file)
    (define-key map "\M-}" 'compilation-next-file)
    (define-key map "n" 'next-error-no-select)
    (define-key map "p" 'previous-error-no-select)
    (define-key map "l" 'recenter-current-error)

    (define-key map "g" 'recompile) ; revert
    ;; Set up the menu-bar
    (define-key map [menu-bar compilation]
      (cons "Errors" compilation-menu-map))
    map)
  "Keymap for `compilation-minor-mode'.")

(defvar compilation-shell-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\M-\C-m" 'compile-goto-error)
    (define-key map "\M-\C-n" 'compilation-next-error)
    (define-key map "\M-\C-p" 'compilation-previous-error)
    (define-key map "\M-{" 'compilation-previous-file)
    (define-key map "\M-}" 'compilation-next-file)
    ;; Set up the menu-bar
    (define-key map [menu-bar compilation]
      (cons "Errors" compilation-menu-map))
    map)
  "Keymap for `compilation-shell-minor-mode'.")

(defvar compilation-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-2] 'compile-goto-error)
    (define-key map [follow-link] 'mouse-face)
    (define-key map "\C-m" 'compile-goto-error)
    (define-key map "\M-\C-m" 'push-button)
    (define-key map [M-down-mouse-2] 'push-button)
    (define-key map [M-mouse-2] 'push-button)
    map)
  "Keymap for compilation-message buttons.")
(fset 'compilation-button-map compilation-button-map)

(defvar compilation-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Don't inherit from compilation-minor-mode-map,
    ;; because that introduces a menu bar item we don't want.
    ;; That confuses C-down-mouse-3.
    (set-keymap-parent map special-mode-map)
    (define-key map [mouse-2] 'compile-goto-error)
    (define-key map [follow-link] 'mouse-face)
    (define-key map "\C-c\C-c" 'compile-goto-error)
    (define-key map "\C-m" 'compile-goto-error)
    (define-key map "\C-o" 'compilation-display-error)
    (define-key map "\C-c\C-k" 'kill-compilation)
    (define-key map "\M-n" 'compilation-next-error)
    (define-key map "\M-p" 'compilation-previous-error)
    (define-key map "\M-{" 'compilation-previous-file)
    (define-key map "\M-}" 'compilation-next-file)
    (define-key map "n" 'next-error-no-select)
    (define-key map "p" 'previous-error-no-select)
    (define-key map "\t" 'compilation-next-error)
    (define-key map [backtab] 'compilation-previous-error)
    (define-key map "g" 'recompile) ; revert

    (define-key map "\C-c\C-f" 'next-error-follow-minor-mode)

    ;; Set up the menu-bar
    (let ((submap (make-sparse-keymap "Compile")))
      (define-key map [menu-bar compilation]
	(cons "Compile" submap))
      (set-keymap-parent submap compilation-menu-map))
    (define-key map [menu-bar compilation compilation-separator2]
      '("----" . nil))
    (define-key map [menu-bar compilation compilation-grep]
      '(menu-item "Search Files (grep)..." grep
		  :help "Run grep, with user-specified args, and collect output in a buffer"))
    (define-key map [menu-bar compilation compilation-recompile]
      '(menu-item "Recompile" recompile
	:help "Re-compile the program including the current buffer"))
    (define-key map [menu-bar compilation compilation-compile]
      '(menu-item "Compile..." compile
		  :help "Compile the program including the current buffer.  Default: run `make'"))
    map)
  "Keymap for compilation log buffers.")

(defvar compilation-mode-tool-bar-map
  ;; When bootstrapping, tool-bar-map is not properly initialized yet,
  ;; so don't do anything.
  (when (keymapp tool-bar-map)
    (let ((map (copy-keymap tool-bar-map)))
      (define-key map [undo] nil)
      (define-key map [separator-2] nil)
      (define-key-after map [separator-compile] menu-bar-separator)
      (tool-bar-local-item
       "left-arrow" 'previous-error-no-select 'previous-error-no-select map
       :rtl "right-arrow"
       :help "Goto previous error")
      (tool-bar-local-item
       "right-arrow" 'next-error-no-select 'next-error-no-select map
       :rtl "left-arrow"
       :help "Goto next error")
      (tool-bar-local-item
       "cancel" 'kill-compilation 'kill-compilation map
       :enable '(let ((buffer (compilation-find-buffer)))
		  (get-buffer-process buffer))
       :help "Stop compilation")
      (tool-bar-local-item
       "refresh" 'recompile 'recompile map
       :help "Restart compilation")
      map)))

(put 'compilation-mode 'mode-class 'special)

;;;###autoload
(defun compilation-mode (&optional name-of-mode)
  "Major mode for compilation log buffers.
\\<compilation-mode-map>To visit the source for a line-numbered error,
move point to the error message line and type \\[compile-goto-error].
To kill the compilation, type \\[kill-compilation].

Runs `compilation-mode-hook' with `run-mode-hooks' (which see).

\\{compilation-mode-map}"
  (interactive)
  (kill-all-local-variables)
  (use-local-map compilation-mode-map)
  ;; Let windows scroll along with the output.
  (setq-local window-point-insertion-type t)
  (setq-local tool-bar-map compilation-mode-tool-bar-map)
  (setq major-mode 'compilation-mode ; FIXME: Use define-derived-mode.
	mode-name (or name-of-mode "Compilation"))
  (setq-local page-delimiter compilation-page-delimiter)
  ;; (setq-local compilation-buffer-modtime nil)
  (compilation-setup)
  ;; Turn off deferred fontifications in the compilation buffer, if
  ;; the user turned them on globally.  This is because idle timers
  ;; aren't re-run after receiving input from a subprocess, so the
  ;; buffer is left unfontified after the compilation exits, until
  ;; some other input event happens.
  (setq-local jit-lock-defer-time nil)
  (setq buffer-read-only t)
  (run-mode-hooks 'compilation-mode-hook))

;;;###autoload
(put 'define-compilation-mode 'doc-string-elt 3)

(defmacro define-compilation-mode (mode name doc &rest body)
  "This is like `define-derived-mode' without the PARENT argument.
The parent is always `compilation-mode' and the customizable `compilation-...'
variables are also set from the name of the mode you have chosen,
by replacing the first word, e.g., `compilation-scroll-output' from
`grep-scroll-output' if that variable exists."
  (declare (indent defun))
  (let ((mode-name (replace-regexp-in-string "-mode\\'" "" (symbol-name mode))))
    `(define-derived-mode ,mode compilation-mode ,name
       ,doc
       ,@(mapcar (lambda (v)
		   (setq v (cons v
				 (intern-soft (replace-regexp-in-string
					       "^compilation" mode-name
					       (symbol-name v)))))
		   (and (cdr v)
			(or (boundp (cdr v))
                            ;; FIXME: This is hackish, using undocumented info.
			    (if (boundp 'byte-compile-bound-variables)
				(memq (cdr v) byte-compile-bound-variables)))
			`(set (make-local-variable ',(car v)) ,(cdr v))))
		 '(compilation-directory-matcher
		   compilation-error
		   compilation-error-regexp-alist
		   compilation-error-regexp-alist-alist
		   compilation-error-screen-columns
		   compilation-finish-functions
		   compilation-first-column
		   compilation-mode-font-lock-keywords
		   compilation-page-delimiter
		   compilation-parse-errors-filename-function
		   compilation-process-setup-function
		   compilation-scroll-output
		   compilation-search-path
		   compilation-skip-threshold
		   compilation-window-height))
       ,@body)))

(defun compilation-revert-buffer (ignore-auto noconfirm)
  (if buffer-file-name
      (let (revert-buffer-function)
	(revert-buffer ignore-auto noconfirm))
    (if (or noconfirm (yes-or-no-p "Restart compilation? "))
	(apply #'compilation-start compilation-arguments))))

(defvar compilation-current-error nil
  "Marker to the location from where the next error will be found.
The global commands next/previous/first-error/goto-error use this.")

(defvar compilation-messages-start nil
  "Buffer position of the beginning of the compilation messages.
If nil, use the beginning of buffer.")

(defun compilation-setup (&optional minor)
  "Prepare the buffer for the compilation parsing commands to work.
Optional argument MINOR indicates this is called from
`compilation-minor-mode'."
  (make-local-variable 'compilation-current-error)
  (make-local-variable 'compilation-messages-start)
  (make-local-variable 'compilation-error-screen-columns)
  (make-local-variable 'overlay-arrow-position)
  (setq-local compilation-num-errors-found 0)
  (setq-local compilation-num-warnings-found 0)
  (setq-local compilation-num-infos-found 0)
  (setq-local overlay-arrow-string "")
  (setq next-error-overlay-arrow-position nil)
  (add-hook 'kill-buffer-hook
	    (lambda () (setq next-error-overlay-arrow-position nil)) nil t)
  ;; Note that compilation-next-error-function is for interfacing
  ;; with the next-error function in simple.el, and it's only
  ;; coincidentally named similarly to compilation-next-error.
  (setq next-error-function 'compilation-next-error-function)
  (setq-local comint-file-name-prefix
              (or (file-remote-p default-directory) ""))
  (setq-local compilation-locs
              (make-hash-table :test 'equal :weakness 'value))
  ;; It's generally preferable to use after-change-functions since they
  ;; can be subject to combine-after-change-calls, but if we do that, we risk
  ;; running our hook after font-lock, resulting in incorrect refontification.
  (add-hook 'before-change-functions #'compilation--flush-parse nil t)
  ;; Also for minor mode, since it's not permanent-local.
  (add-hook 'change-major-mode-hook #'compilation--remove-properties nil t)
  (if minor
      (progn
	(font-lock-add-keywords nil (compilation-mode-font-lock-keywords))
        (font-lock-flush))
    (setq font-lock-defaults '(compilation-mode-font-lock-keywords t))))

(defun compilation--unsetup ()
  ;; Only for minor mode.
  (font-lock-remove-keywords nil (compilation-mode-font-lock-keywords))
  (remove-hook 'before-change-functions #'compilation--flush-parse t)
  (kill-local-variable 'compilation--parsed)
  (compilation--remove-properties)
  (font-lock-flush))

;;;###autoload
(define-minor-mode compilation-shell-minor-mode
  "Toggle Compilation Shell minor mode.

When Compilation Shell minor mode is enabled, all the
error-parsing commands of the Compilation major mode are
available but bound to keys that don't collide with Shell mode.
See `compilation-mode'."
  :lighter " Shell-Compile"
  (if compilation-shell-minor-mode
      (compilation-setup t)
    (compilation--unsetup)))

;;;###autoload
(define-minor-mode compilation-minor-mode
  "Toggle Compilation minor mode.

When Compilation minor mode is enabled, all the error-parsing
commands of Compilation major mode are available.  See
`compilation-mode'."
  :lighter " Compilation"
  (if compilation-minor-mode
      (compilation-setup t)
    (compilation--unsetup)))

(defun compilation-handle-exit (process-status exit-status msg)
  "Write MSG in the current buffer and hack its `mode-line-process'."
  (let ((inhibit-read-only t)
	(status (if compilation-exit-message-function
		    (funcall compilation-exit-message-function
			     process-status exit-status msg)
		  (cons msg exit-status)))
	(omax (point-max))
	(opoint (point))
	(cur-buffer (current-buffer)))
    ;; Record where we put the message, so we can ignore it later on.
    (goto-char omax)
    (compilation-insert-annotation ?\n mode-name " " (car status))
    (if (and (numberp compilation-window-height)
	     (zerop compilation-window-height))
	(message "%s" (cdr status)))
    (if (bolp)
	(forward-char -1))
    (compilation-insert-annotation
     " at "
     (substring (current-time-string) 0 19)
     ", duration "
     (let ((elapsed (- (float-time) compilation--start-time)))
       (cond ((< elapsed 10) (format "%.2f s" elapsed))
             ((< elapsed 60) (format "%.1f s" elapsed))
             (t (format-seconds "%h:%02m:%02s" elapsed)))))
    (goto-char (point-max))
    ;; Prevent that message from being recognized as a compilation error.
    (add-text-properties omax (point)
			 (append '(compilation-handle-exit t) nil))
    (setq mode-line-process
          (list
           (let ((out-string (format ":%s [%s]" process-status (cdr status)))
                 (msg (format "%s %s" mode-name
                              (replace-regexp-in-string "\n?$" ""
                                                        (car status)))))
             (message "%s" msg)
             (propertize out-string
                         'help-echo msg
                         'face (if (> exit-status 0)
                                   'compilation-mode-line-fail
                                 'compilation-mode-line-exit)))
           compilation-mode-line-errors))
    ;; Force mode line redisplay soon.
    (force-mode-line-update)
    (if (and opoint (< opoint omax))
	(goto-char opoint))
    (run-hook-with-args 'compilation-finish-functions cur-buffer msg)))

;; Called when compilation process changes state.
(defun compilation-sentinel (proc msg)
  "Sentinel for compilation buffers."
  (if (memq (process-status proc) '(exit signal))
      (unwind-protect
          (let ((buffer (process-buffer proc)))
            (if (null (buffer-name buffer))
                ;; buffer killed
                (set-process-buffer proc nil)
              (with-current-buffer buffer
                ;; Write something in the compilation buffer
                ;; and hack its mode line.
                (compilation-handle-exit (process-status proc)
                                         (process-exit-status proc)
                                         msg))))
        (setq compilation-in-progress (delq proc compilation-in-progress))
        (compilation--update-in-progress-mode-line)
        ;; Since the buffer and mode line will show that the
        ;; process is dead, we can delete it now.  Otherwise it
        ;; will stay around until M-x list-processes.
        (delete-process proc))))

(defun compilation-filter (proc string)
  "Process filter for compilation buffers.
Just inserts the text, handles carriage motion (see
`comint-inhibit-carriage-motion'), `compilation-hidden-output',
and runs `compilation-filter-hook'."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (let ((inhibit-read-only t)
            ;; `save-excursion' doesn't use the right insertion-type for us.
            (pos (copy-marker (point) t))
            ;; `save-restriction' doesn't use the right insertion type either:
            ;; If we are inserting at the end of the accessible part of the
            ;; buffer, keep the inserted text visible.
	    (min (point-min-marker))
	    (max (copy-marker (point-max) t))
	    (compilation-filter-start (marker-position (process-mark proc))))
        (unwind-protect
            (progn
	      (widen)
	      (goto-char compilation-filter-start)
              ;; We used to use `insert-before-markers', so that windows with
              ;; point at `process-mark' scroll along with the output, but we
              ;; now use window-point-insertion-type instead.
              (if (not compilation-max-output-line-length)
                  (insert string)
                (dolist (line (string-lines string nil t))
                  (compilation--insert-abbreviated-line
                   line compilation-max-output-line-length)))
              (when compilation-hidden-output
                (compilation--hide-output compilation-filter-start))
              (unless comint-inhibit-carriage-motion
                (comint-carriage-motion (process-mark proc) (point)))
              (set-marker (process-mark proc) (point))
              ;; Update the number of errors in compilation-mode-line-errors
              (compilation--ensure-parse (point))
              (run-hooks 'compilation-filter-hook))
	  (goto-char pos)
          (narrow-to-region min max)
	  (set-marker pos nil)
	  (set-marker min nil)
	  (set-marker max nil))))))

(defun compilation--hide-output (start)
  (save-excursion
    (goto-char start)
    (beginning-of-line)
    ;; Apply the match to each line, but wait until we have a complete
    ;; line.
    (let ((start (point)))
      (while (search-forward "\n" nil t)
        (save-restriction
          (narrow-to-region start (point))
          (dolist (regexp (ensure-list compilation-hidden-output))
            (goto-char start)
            (while (re-search-forward regexp nil t)
              (add-text-properties (match-beginning 0) (match-end 0)
                                   '( invisible t
                                      rear-nonsticky t))))
          (goto-char (point-max)))))))

(defun compilation--insert-abbreviated-line (string width)
  (if (and (> (current-column) 0)
           (get-text-property (1- (point)) 'button))
      ;; We already have an abbreviation; just add the string to it.
      (let ((beg (point)))
        (insert string)
        (add-text-properties
         beg
         ;; Don't make the final newline invisible.
         (if (= (aref string (1- (length string))) ?\n)
             (1- (point))
           (point))
         (text-properties-at (1- beg))))
    (insert string)
    ;; If we exceeded the limit, hide the last portion of the line.
    (let* ((ends-in-nl (= (aref string (1- (length string))) ?\n))
           (curcol (if ends-in-nl
                       (progn (backward-char) (current-column))
                     (current-column))))
      (when (> curcol width)
        (let ((start (save-excursion
                       (move-to-column width)
                       (point))))
          (buttonize-region
           start (point)
           (lambda (start)
             (let ((inhibit-read-only t))
               (remove-text-properties start (save-excursion
                                               (goto-char start)
                                               (line-end-position))
                                       (text-properties-at start)))))
          (put-text-property
           start (point)
           'display (if (char-displayable-p ?…) "[…]" "[...]"))))
      (if ends-in-nl (forward-char)))))

(defsubst compilation-buffer-internal-p ()
  "Test if inside a compilation buffer."
  (local-variable-p 'compilation-locs))

(defsubst compilation-buffer-p (buffer)
  "Test if BUFFER is a compilation buffer."
  (with-current-buffer buffer
    (compilation-buffer-internal-p)))

(defmacro compilation-loop (< property-change 1+ error limit)
  `(let (opt)
     (while (,< n 0)
       (setq opt pt)
       (or (setq pt (,property-change pt 'compilation-message))
	   ;; Handle the case where the first error message is
	   ;; at the start of the buffer, and n < 0.
	   (if (or (eq (get-text-property ,limit 'compilation-message)
		       (get-text-property opt 'compilation-message))
		   (eq pt opt))
	       (user-error ,error compilation-error)
	     (setq pt ,limit)))
       ;; prop 'compilation-message usually has 2 changes, on and off, so
       ;; re-search if off
       (or (setq msg (get-text-property pt 'compilation-message))
	   (if (setq pt (,property-change pt 'compilation-message nil ,limit))
	       (setq msg (get-text-property pt 'compilation-message)))
	   (user-error ,error compilation-error))
       (or (< (compilation--message->type msg) compilation-skip-threshold)
	   (if different-file
	       (eq (prog1 last
                     (setq last (compilation--loc->file-struct
                                 (compilation--message->loc msg))))
		   last))
	   (if compilation-skip-visited
	       (compilation--loc->visited (compilation--message->loc msg)))
	   (if compilation-skip-to-next-location
	       (eq (compilation--message->loc msg) loc))
	   ;; count this message only if none of the above are true
	   (setq n (,1+ n))))))

(defun compilation-next-single-property-change (position prop
                                                &optional object limit)
  (let (parsed res)
    (while (progn
             (compilation--ensure-parse
              (setq parsed (max compilation--parsed
                                (or limit (point-max)))))
             (and (or (not (setq res (next-single-property-change
                                      position prop object limit)))
                      (eq res limit))
                  (< position (or limit (point-max)))))
      (setq position parsed))
    res))

(defun compilation-next-error (n &optional different-file pt)
  "Move point to the next error in the compilation buffer.
This function does NOT find the source line like \\[next-error].
Prefix arg N says how many error messages to move forwards (or
backwards, if negative).
Optional arg DIFFERENT-FILE, if non-nil, means find next error for a
file that is different from the current one.
Optional arg PT, if non-nil, specifies the value of point to start
looking for the next message."
  (interactive "p")
  (or (compilation-buffer-p (current-buffer))
      (error "Not in a compilation buffer"))
  (or pt (setq pt (point)))
  (compilation--ensure-parse pt)
  (let* ((msg (get-text-property pt 'compilation-message))
         ;; `loc', `msg', and `last' are used by the compilation-loop macro.
	 (loc (and msg (compilation--message->loc msg)))
	 last)
    (if (zerop n)
	(unless (or msg			; find message near here
		    (setq msg (get-text-property (max (1- pt) (point-min))
						 'compilation-message)))
	  (setq pt (previous-single-property-change pt 'compilation-message nil
						    (line-beginning-position)))
	  (unless (setq msg (get-text-property (max (1- pt) (point-min))
                                               'compilation-message))
	    (setq pt (compilation-next-single-property-change
                      pt 'compilation-message nil
		      (line-end-position)))
	    (or (setq msg (get-text-property pt 'compilation-message))
		(setq pt (point)))))
      (setq last (compilation--loc->file-struct loc))
      (if (>= n 0)
	  (compilation-loop > compilation-next-single-property-change 1-
			    (if (get-buffer-process (current-buffer))
				"No more %ss yet"
			      "Past last %s")
			    (point-max))
	;; Don't move "back" to message at or before point.
	;; Pass an explicit (point-min) to make sure pt is non-nil.
	(setq pt (previous-single-property-change
                  pt 'compilation-message nil (point-min)))
	(compilation-loop < previous-single-property-change 1+
			  "Moved back before first %s" (point-min))))
    (goto-char pt)
    (or msg
	(user-error "No %s here" compilation-error))))

(defun compilation-previous-error (n)
  "Move point to the previous error in the compilation buffer.
Prefix arg N says how many error messages to move backwards (or
forwards, if negative).
Does NOT find the source line like \\[previous-error]."
  (interactive "p")
  (compilation-next-error (- n)))

(defun compilation-next-file (n)
  "Move point to the next error for a different file than the current one.
Prefix arg N says how many files to move forwards (or backwards, if negative)."
  (interactive "p")
  (compilation-next-error n t))

(defun compilation-previous-file (n)
  "Move point to the previous error for a different file than the current one.
Prefix arg N says how many files to move backwards (or forwards, if negative)."
  (interactive "p")
  (compilation-next-file (- n)))

(defun compilation-display-error ()
  "Display the source for current error in another window."
  (interactive)
  (setq compilation-current-error (point))
  (next-error-no-select 0))

(defun kill-compilation ()
  "Kill the process made by the \\[compile] or \\[grep] commands."
  (interactive)
  (let ((buffer (compilation-find-buffer)))
    (if (get-buffer-process buffer)
	(interrupt-process (get-buffer-process buffer))
      (error "The %s process is not running"
             (compilation--downcase-mode-name mode-name)))))

(defalias 'compile-mouse-goto-error 'compile-goto-error)

(defun compile-goto-error (&optional event)
  "Visit the source for the error message at point.
Use this command in a compilation log buffer."
  (interactive (list last-input-event))
  (if event (posn-set-point (event-end event)))
  (or (compilation-buffer-p (current-buffer))
      (error "Not in a compilation buffer"))
  (compilation--ensure-parse (point))
  (if (get-text-property (point) 'compilation-directory)
      (dired-other-window
       (car (get-text-property (point) 'compilation-directory)))
    (setq compilation-current-error (point))
    (next-error-internal)))

;; This is mostly unused, but we keep it for the sake of some external
;; packages which seem to make use of it.
(defun compilation-find-buffer (&optional avoid-current)
  "Return a compilation buffer.
If AVOID-CURRENT is nil, and the current buffer is a compilation buffer,
return it.  If AVOID-CURRENT is non-nil, return the current buffer only
as a last resort."
  (if (and (compilation-buffer-internal-p) (not avoid-current))
      (current-buffer)
    (next-error-find-buffer avoid-current 'compilation-buffer-internal-p)))

(defun compilation--update-markers (loc marker screen-columns first-column)
  "Update markers in LOC, and set MARKER to location pointed by LOC.
SCREEN-COLUMNS and FIRST-COLUMN are the value of
`compilation-error-screen-columns' and `compilation-first-column' to use
if they are not set buffer-locally in the target buffer."
  (with-current-buffer
      (if (bufferp (caar (compilation--loc->file-struct loc)))
          (caar (compilation--loc->file-struct loc))
        (apply #'compilation-find-file
               marker
               (caar (compilation--loc->file-struct loc))
               (cadr (car (compilation--loc->file-struct loc)))
               (compilation--file-struct->formats
                (compilation--loc->file-struct loc))))
    (let ((screen-columns
           ;; Obey the compilation-error-screen-columns of the target
           ;; buffer if its major mode set it buffer-locally.
           (if (local-variable-p 'compilation-error-screen-columns)
               compilation-error-screen-columns screen-columns))
          (compilation-first-column
           (if (local-variable-p 'compilation-first-column)
               compilation-first-column first-column))
          (last 1))
      (save-restriction
        (widen)
        (goto-char (point-min))
        ;; Treat file's found lines in forward order, 1 by 1.
        (dolist (line (reverse (cddr (compilation--loc->file-struct loc))))
          (when (car line)     ; else this is a filename without a line#
            (compilation-beginning-of-line (- (car line) last -1))
            (setq last (car line)))
          ;; Treat line's found columns and store/update a marker for each.
          (dolist (col (cdr line))
            (if (compilation--loc->col col)
                (if (eq (compilation--loc->col col) -1)
                    ;; Special case for range end.
                    (end-of-line)
                  (compilation-move-to-column (compilation--loc->col col)
                                              screen-columns))
              (beginning-of-line)
              (skip-chars-forward " \t"))
            (if (compilation--loc->marker col)
                (set-marker (compilation--loc->marker col) (point))
              (setf (compilation--loc->marker col) (point-marker)))
            ;; (setf (compilation--loc->timestamp col) timestamp)
            ))))))

;;;###autoload
(defun compilation-next-error-function (n &optional reset)
  "Advance to the next error message and visit the file where the error was.
This is the value of `next-error-function' in Compilation buffers."
  (interactive "p")
  (when reset
    (setq compilation-current-error nil))
  (let* ((screen-columns compilation-error-screen-columns)
	 (first-column compilation-first-column)
	 (msg (compilation-next-error (or n 1) nil
				      (or compilation-current-error
					  compilation-messages-start
					  (point-min))))
	 (loc (compilation--message->loc msg))
	 (end-loc (compilation--message->end-loc msg))
	 (marker (point-marker)))
    (unless loc
      (user-error "No next error"))
    (setq compilation-current-error (point-marker)
	  overlay-arrow-position
	  (if (bolp)
	      compilation-current-error
	    (copy-marker (line-beginning-position))))
    ;; If loc contains no marker, no error in that file has been visited.
    ;; If the marker is invalid the buffer has been killed.
    ;; So, recalculate all markers for that file.
    (unless (and (compilation--loc->marker loc)
                 (marker-buffer (compilation--loc->marker loc))
                 ;; FIXME-omake: For "omake -P", which automatically recompiles
                 ;; when the file is modified, the line numbers of new output
                 ;; may not be related to line numbers from earlier output
                 ;; (earlier markers), so we used to try to detect it here and
                 ;; force a reparse.  But that caused more problems elsewhere,
                 ;; so instead we now flush the file-structure when we see
                 ;; omake's message telling it's about to recompile a file.
                 ;; (or (null (compilation--loc->timestamp loc)) ;A fake-loc
                 ;;     (equal (compilation--loc->timestamp loc)
                 ;;            (setq timestamp compilation-buffer-modtime)))
                 )
      (compilation--update-markers loc marker screen-columns first-column))
    (compilation-goto-locus marker (compilation--loc->marker loc)
                            (compilation--loc->marker end-loc))
    (setf (compilation--loc->visited loc) t)))

(defvar-local compilation-gcpro nil
  "Internal variable used to keep some values from being GC'd.")

(defun compilation-fake-loc (marker file &optional line col)
  "Preassociate MARKER with FILE.
FILE should be ABSOLUTE-FILENAME or (RELATIVE-FILENAME . DIRNAME).
This is useful when you compile temporary files, but want
automatic translation of the messages to the real buffer from
which the temporary file came.  This may also affect previous messages
about FILE.

Optional args LINE and COL default to 1 and beginning of
indentation respectively.  The marker is expected to reflect
this.  In the simplest case the marker points to the first line
of the region that was saved to the temp file.

If you concatenate several regions into the temp file (e.g. a
header with variable assignments and a code region), you must
call this several times, once each for the last line of one
region and the first line of the next region."
  (or (consp file) (setq file (list file)))
  (compilation--flush-file-structure file)
  (let ((fs (compilation-get-file-structure file)))
    ;; Between the current call to compilation-fake-loc and the first
    ;; occurrence of an error message referring to `file', the data is
    ;; only kept in the weak hash-table compilation-locs, so we need
    ;; to prevent this entry in compilation-locs from being GC'd
    ;; away.  --Stef
    (push fs compilation-gcpro)
    (let ((loc (compilation-assq (or line 1) (cdr fs))))
      (setq loc (compilation-assq col loc))
      (cl-assert (null (cdr loc)))
      (setcdr loc (compilation--make-cdrloc line fs marker))
      loc)))

(defcustom compilation-context-lines nil
  "Display this many lines of leading context before the current message.
If nil or t, and the left fringe is displayed, don't scroll the
compilation output window; an arrow in the left fringe points to
the current message.  With no left fringe, if nil, the message
scrolls to the top of the window; there is no arrow.  If t, don't
scroll the compilation output window at all; an arrow before
column zero points to the current message."
  :type '(choice integer
                 (const :tag "Scroll window when no fringe" nil)
                 (const :tag  "No window scrolling" t))
  :version "22.1")

(defsubst compilation-set-window (w mk)
  "Maybe align the compilation output window W with marker MK near top."
  (cond ((integerp compilation-context-lines)
         (set-window-start w (save-excursion
			       (goto-char mk)
			       (compilation-beginning-of-line
			        (- 1 compilation-context-lines))
			       (point))))
        ((and (null compilation-context-lines)
              ;; If there is no left fringe.
              (equal (car (window-fringes w)) 0))
         (set-window-start w (save-excursion
                               (goto-char mk)
			       (beginning-of-line 1)
			       (point)))))
  (set-window-point w mk))

(defvar-local compilation-arrow-overlay nil
  "Overlay with the before-string property of `overlay-arrow-string'.

When non-nil, this overlay causes redisplay to display `overlay-arrow-string'
at the overlay's start position.")

(defconst compilation--margin-string (propertize "=>" 'face 'default)
  "The string which will appear in the margin in compilation mode.")

(defconst compilation--dummy-string
  (propertize ">" 'display
              `((margin left-margin) ,compilation--margin-string))
  "A string which is only a placeholder for `compilation--margin-string'.
Actual value is never used, only the text property.")

(defun compilation--set-up-margin (w)
  "Setup the margin for \"=>\" in window W if it isn't already set up."
  (set-window-margins w (+ (or (car (window-margins w)) 0) 2)))

(defun compilation--tear-down-margin (w)
  "Remove the margin for \"=>\" if it is setup in window W."
  (when (window-margins w)
    (set-window-margins w (- (car (window-margins w)) 2))))

(defun compilation--set-up-arrow-spec-in-margins ()
  "Set up `compilation-arrow-overlay' to display as an arrow in margins."
  (setq overlay-arrow-string "")
  (setq compilation-arrow-overlay
	(make-overlay overlay-arrow-position overlay-arrow-position))
  (overlay-put compilation-arrow-overlay
               'before-string compilation--dummy-string)
  (mapc #'compilation--set-up-margin (get-buffer-window-list nil nil t))
  (add-hook 'window-buffer-change-functions #'compilation--set-up-margin nil t)
  ;; Take precautions against `compilation-mode' getting reinitialized.
  (add-hook 'change-major-mode-hook
            #'compilation--tear-down-arrow-spec-in-margins nil t))

(defun compilation--tear-down-arrow-spec-in-margins ()
  "Restore `compilation-arrow-overlay' to not using the margins, which are removed."
  (when (overlayp compilation-arrow-overlay)
    (overlay-put compilation-arrow-overlay 'before-string nil)
    (delete-overlay compilation-arrow-overlay)
    (setq compilation-arrow-overlay nil)
    (mapc #'compilation--tear-down-margin (get-buffer-window-list nil nil t))
    (remove-hook 'change-major-mode-hook
                 #'compilation--tear-down-arrow-spec-in-margins t)
    (remove-hook 'window-buffer-change-functions
                 #'compilation--set-up-margin t)))

(defun compilation-set-overlay-arrow (w)
  "Set up, or switch off, the overlay-arrow for window W."
  (with-selected-window w        ; So the later `goto-char' will work.
    (if (and (eq compilation-context-lines t)
             (equal (car (window-fringes w)) 0)) ; No left fringe
        ;; Insert a before-string overlay at the beginning of the line
        ;; pointed to by `overlay-arrow-position', such that it will
        ;; display in a 2-character margin.
        (progn
          (cond
           ((overlayp compilation-arrow-overlay)
            (when (not (eq (overlay-start compilation-arrow-overlay)
		           overlay-arrow-position))
	      (if overlay-arrow-position
	          (move-overlay compilation-arrow-overlay
			        overlay-arrow-position overlay-arrow-position)
                (compilation--tear-down-arrow-spec-in-margins))))

           (overlay-arrow-position
            (compilation--set-up-arrow-spec-in-margins)))
          ;; Ensure that the "=>" remains in the window by causing
          ;; the window to be scrolled, if needed.
          (goto-char (overlay-start compilation-arrow-overlay)))

      ;; `compilation-context-lines' isn't t, or we've got a left
      ;; fringe, so remove any overlay arrow.
      (when (overlayp compilation-arrow-overlay)
        (compilation--tear-down-arrow-spec-in-margins)))))

(defvar next-error-highlight-timer)

(defun compilation-goto-locus (msg mk end-mk)
  "Jump to an error corresponding to MSG at MK.
All arguments are markers.  If END-MK is non-nil, mark is set there
and overlay is highlighted between MK and END-MK."
  ;; Show compilation buffer in other window, scrolled to this error.
  (let* ((from-compilation-buffer (eq (window-buffer)
                                      (marker-buffer msg)))
         ;; Use an existing window if it is in a visible frame.
         (pre-existing (get-buffer-window (marker-buffer msg) 0))
         (w (if (and from-compilation-buffer pre-existing)
                ;; Calling display-buffer here may end up (partly) hiding
                ;; the error location if the two buffers are in two
                ;; different frames.  So don't do it if it's not necessary.
                pre-existing
	      (display-buffer (marker-buffer msg) '(nil (allow-no-window . t)))))
	 (highlight-regexp (with-current-buffer (marker-buffer msg)
			     ;; also do this while we change buffer
			     (goto-char (marker-position msg))
			     (and w (progn (compilation-set-window w msg)
                                           (compilation-set-overlay-arrow w)))
			     compilation-highlight-regexp)))
    ;; Ideally, the window-size should be passed to `display-buffer'
    ;; so it's only used when creating a new window.
    (when (and (not pre-existing) w)
      (compilation-set-window-height w))

    (if (or from-compilation-buffer
            (eq w (selected-window)))
        ;; If the compilation buffer window is selected,
        ;; keep the compilation buffer in this window;
        ;; display the source in another window.
        (let ((pop-up-windows t))
          (pop-to-buffer (marker-buffer mk) 'other-window))
      (switch-to-buffer (marker-buffer mk)))
    (unless (eq (goto-char mk) (point))
      ;; If narrowing gets in the way of going to the right place, widen.
      (widen)
      (if next-error-move-function
	  (funcall next-error-move-function msg mk)
	(goto-char mk)))
    (if end-mk
        (push-mark end-mk t)
      (if mark-active (setq mark-active nil)))
    ;; If hideshow got in the way of
    ;; seeing the right place, open permanently.
    (dolist (ov (overlays-at (point)))
      (when (eq 'hs (overlay-get ov 'invisible))
        (delete-overlay ov)
        (goto-char mk)))

    (when highlight-regexp
      (if (timerp next-error-highlight-timer)
	  (cancel-timer next-error-highlight-timer))
      (unless compilation-highlight-overlay
	(setq compilation-highlight-overlay
	      (make-overlay (point-min) (point-min)))
	(overlay-put compilation-highlight-overlay 'face 'next-error))
      (with-current-buffer (marker-buffer mk)
	(save-excursion
	  (if end-mk (goto-char end-mk) (end-of-line))
	  (let ((end (point)))
	    (if mk (goto-char mk) (beginning-of-line))
	    (if (and (stringp highlight-regexp)
		     (re-search-forward highlight-regexp end t))
		(progn
		  (goto-char (match-beginning 0))
		  (move-overlay compilation-highlight-overlay
				(match-beginning 0) (match-end 0)
				(current-buffer)))
	      (move-overlay compilation-highlight-overlay
			    (point) end (current-buffer)))
	    (if (or (eq next-error-highlight t)
		    (numberp next-error-highlight))
		;; We want highlighting: delete overlay on next input.
		(add-hook 'pre-command-hook
			  #'compilation-goto-locus-delete-o)
	      ;; We don't want highlighting: delete overlay now.
	      (delete-overlay compilation-highlight-overlay))
	    ;; We want highlighting for a limited time:
	    ;; set up a timer to delete it.
	    (when (numberp next-error-highlight)
	      (setq next-error-highlight-timer
		    (run-at-time next-error-highlight nil
				 'compilation-goto-locus-delete-o)))))))
    (when (and (eq next-error-highlight 'fringe-arrow))
      ;; We want a fringe arrow (instead of highlighting).
      (setq next-error-overlay-arrow-position
	    (copy-marker (line-beginning-position))))))

(defun compilation-goto-locus-delete-o ()
  (delete-overlay compilation-highlight-overlay)
  ;; Get rid of timer and hook that would try to do this again.
  (if (timerp next-error-highlight-timer)
      (cancel-timer next-error-highlight-timer))
  (remove-hook 'pre-command-hook
	       #'compilation-goto-locus-delete-o))

(defun compilation--expand-fn (directory filename)
  "Expand FILENAME or resolve its true name.
Unlike `expand-file-name', `file-truename' follows symlinks, which
we try to avoid if possible."
  (let* ((expandedname (expand-file-name filename directory)))
    (if (file-exists-p expandedname)
        expandedname
      (file-truename (file-name-concat directory filename)))))

(defun compilation-find-file-1 (marker filename directory &optional formats)
  (or formats (setq formats '("%s")))
  (let ((dirs compilation-search-path)
        (spec-dir (if directory
                      (expand-file-name directory)
                    default-directory))
        buffer thisdir fmts name)
    (if (and filename
             (file-name-absolute-p filename))
        ;; The file name is absolute.  Use its explicit directory as
        ;; the first in the search path, and strip it from FILENAME.
        (setq filename (abbreviate-file-name (expand-file-name filename))
              dirs (cons (file-name-directory filename) dirs)
              filename (file-name-nondirectory filename)))
    ;; Now search the path.
    (while (and dirs (null buffer))
      (setq thisdir (or (car dirs) spec-dir)
            fmts formats)
      ;; For each directory, try each format string.
      (while (and fmts (null buffer))
        (setq name (compilation--expand-fn thisdir
                                           (format (car fmts) filename))
              buffer (and (file-exists-p name)
                          (find-file-noselect name))
              fmts (cdr fmts)))
      (setq dirs (cdr dirs)))
    ;; If we haven't found it, this might be a parallel build.
    ;; Search the directories further up the buffer.
    (when (and (null buffer)
               compilation-search-all-directories)
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (goto-char (marker-position marker))
          (when-let* ((prev (compilation--previous-directory (point))))
            (goto-char prev))
          (setq dirs (cdr (or (get-text-property
                               (1- (point)) 'compilation-directory)
                              (get-text-property
                               (point) 'compilation-directory))))))
      (while (and dirs (null buffer))
        (setq thisdir (car dirs)
              fmts formats)
        (while (and fmts (null buffer))
          (setq name (compilation--expand-fn thisdir
                                             (format (car fmts) filename))
                buffer (and (file-exists-p name)
                            (find-file-noselect name))
                fmts (cdr fmts)))
        (setq dirs (cdr dirs))))
    (list buffer spec-dir)))

(defun compilation-find-file (marker filename directory &rest formats)
  "Find a buffer for file FILENAME.
If FILENAME is not found at all, ask the user where to find it.
Pop up the buffer containing MARKER and scroll to MARKER if we ask
the user where to find the file.
Search the directories in `compilation-search-path'.
A nil in `compilation-search-path' means to try the
\"current\" directory, which is passed in DIRECTORY.
If DIRECTORY is relative, it is combined with `default-directory'.
If DIRECTORY is nil, that means use `default-directory'.
FORMATS, if given, is a list of formats to reformat FILENAME when
looking for it: for each element FMT in FORMATS, this function
attempts to find a file whose name is produced by (format FMT FILENAME)."
  (pcase-let ((`(,buffer ,spec-dir)
               (compilation-find-file-1 marker filename directory formats)))
    (while (null buffer)    ;Repeat until the user selects an existing file.
      ;; The file doesn't exist.  Ask the user where to find it.
      (save-excursion            ;This save-excursion is probably not right.
        (let ((w (let ((pop-up-windows t))
		   (display-buffer (marker-buffer marker)
				   '(nil (allow-no-window . t))))))
          (with-current-buffer (marker-buffer marker)
	    (goto-char marker)
	    (and w (progn (compilation-set-window w marker)
                          (compilation-set-overlay-arrow w))))
          (let* ((name (read-file-name
                        (format-prompt "Find this %s in"
                                       filename compilation-error)
                        spec-dir filename t nil
                        ;; The predicate below is fine when called from
                        ;; minibuffer-complete-and-exit, but it's too
                        ;; restrictive otherwise, since it also prevents the
                        ;; user from completing "fo" to "foo/" when she
                        ;; wants to enter "foo/bar".
                        ;;
                        ;; Try to make sure the user can only select
                        ;; a valid answer.  This predicate may be ignored,
                        ;; tho, so we still have to double-check afterwards.
                        ;; TODO: We should probably fix read-file-name so
                        ;; that it never ignores this predicate, even when
                        ;; using popup dialog boxes.
                        ;; (lambda (name)
                        ;;   (if (file-directory-p name)
                        ;;       (setq name (expand-file-name filename name)))
                        ;;   (file-exists-p name))
                        ))
                 (origname name))
            (cond
             ((not (file-exists-p name))
              (message "Cannot find file `%s'" name)
              (ding) (sit-for 2))
             ((and (file-directory-p name)
                   (not (file-exists-p
                         (setq name (compilation--expand-fn name filename)))))
              (message "No `%s' in directory %s" filename origname)
              (ding) (sit-for 2))
             (t
              (setq buffer (find-file-noselect name))))))))
    ;; Make intangible overlays tangible.
    ;; This is weird: it's not even clear which is the current buffer,
    ;; so the code below can't be expected to DTRT here.  -- Stef
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (overlay-get ov 'intangible)
        (overlay-put ov 'intangible nil)))
    buffer))

(defun compilation-get-file-structure (file &optional fmt)
  "Retrieve FILE's file-structure or create a new one.
FILE should be (FILENAME) or (RELATIVE-FILENAME . DIRNAME).
In the former case, FILENAME may be relative or absolute.

The file-structure looks like this:
  ((FILENAME [TRUE-DIRNAME]) FMT ...)

TRUE-DIRNAME is the `file-truename' of DIRNAME, if given."
  (or (gethash file compilation-locs)
      ;; File was not previously encountered, at least not in the form passed.
      ;; Let's normalize it and look again.
      (let ((filename (car file))
	    ;; Get the specified directory from FILE.
	    (spec-directory
             (if (cdr file)
		 (file-truename (concat comint-file-name-prefix (cdr file))))))

	;; Check for a comint-file-name-prefix and prepend it if appropriate.
	;; (This is very useful for compilation-minor-mode in an rlogin-mode
	;; buffer.)
	(if (file-name-absolute-p filename)
	    (setq filename (concat comint-file-name-prefix filename)))

	;; If compilation-parse-errors-filename-function is
	;; defined, use it to process the filename.  The result might be a
	;; buffer.
	(unless (memq compilation-parse-errors-filename-function
                      '(nil identity))
          (save-match-data
	    (setq filename
		  (funcall compilation-parse-errors-filename-function
			   filename))))

	;; Some compilers (e.g. Sun's java compiler, reportedly) produce bogus
	;; file names like "./bar//foo.c" for file "bar/foo.c";
	;; expand-file-name will collapse these into "/foo.c" and fail to find
	;; the appropriate file.  So we look for doubled slashes in the file
	;; name and fix them.
	(if (stringp filename)
            (setq filename (command-line-normalize-file-name filename)))

	;; Store it for the possibly unnormalized name
	(puthash file
		 ;; Retrieve or create file-structure for normalized name
		 ;; The gethash used to not use spec-directory, but
		 ;; this leads to errors when files in different
		 ;; directories have the same name:
		 ;; https://lists.gnu.org/r/emacs-devel/2007-08/msg00463.html
		 (or (gethash (cons filename spec-directory) compilation-locs)
		     (puthash (cons filename spec-directory)
			      (compilation--make-file-struct
                               (list filename spec-directory) fmt)
			      compilation-locs))
		 compilation-locs))))

(defun compilation--flush-file-structure (file)
  (or (consp file) (setq file (list file)))
  (let ((fs (compilation-get-file-structure file)))
    (cl-assert (eq fs (gethash file compilation-locs)))
    (cl-assert (eq fs (gethash (cons (caar fs) (cadr (car fs)))
                               compilation-locs)))
    (maphash (lambda (k v)
               (if (eq v fs) (remhash k compilation-locs)))
             compilation-locs)))

(defun compilation-forget-errors ()
  ;; In case we hit the same file/line specs, we want to recompute a new
  ;; marker for them, so flush our cache.
  (clrhash compilation-locs)
  (setq compilation-gcpro nil)
  (setq compilation-current-error nil)
  (let* ((proc (get-buffer-process (current-buffer)))
	 (mark (if proc (process-mark proc)))
	 (pos (or mark (point-max))))
    (setq compilation-messages-start
	  ;; In the future, ignore the text already present in the buffer.
	  ;; Since many process filter functions insert before markers,
	  ;; we need to put ours just before the insertion point rather
	  ;; than at the insertion point.  If that's not possible, then
	  ;; don't use a marker.  --Stef
	  (if (> pos (point-min)) (copy-marker (1- pos)) pos)))
  ;; Again, since this command is used in buffers that contain several
  ;; compilations, to set the beginning of "this compilation", it's a good
  ;; place to reset compilation-auto-jump-to-next.
  (setq-local compilation-auto-jump-to-next
              (or compilation-auto-jump-to-first-error
                  (eq compilation-scroll-output 'first-error))))

(define-obsolete-variable-alias 'compilation-last-buffer
  ;; Sadly, we forgot to declare this obsolete back then :-(
  'next-error-last-buffer "29.1 (tho really since 22.1)")

(provide 'compile)

;;; compile.el ends here
