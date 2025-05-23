;;; ol-docview.el --- Links to Docview mode buffers  -*- lexical-binding: t; -*-

;; Copyright (C) 2009-2025 Free Software Foundation, Inc.

;; Author: Jan Böcker <jan.boecker at jboecker dot de>
;; Keywords: outlines, hypermedia, calendar, text
;; URL: https://orgmode.org
;;
;; This file is part of GNU Emacs.
;;
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
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:

;; This file implements links to open files in doc-view-mode.
;; Org mode loads this module by default - if this is not what you want,
;; configure the variable `org-modules'.

;; The links take the form
;;
;;    docview:<file path>::<page number>
;;
;; for example: [[docview:~/.elisp/org/doc/org.pdf::1][Org-Mode Manual]]
;;
;; Autocompletion for inserting links is supported; you will be
;; prompted for a file and a page number.
;;
;; If you use org-store-link in a doc-view mode buffer, the stored
;; link will point to the current page.

;;; Code:

(require 'org-macs)
(org-assert-version)

(require 'doc-view)
(require 'ol)

(declare-function doc-view-goto-page "doc-view" (page))
(declare-function image-mode-window-get "image-mode" (prop &optional winprops))
(declare-function org-open-file "org" (path &optional in-emacs line search))

(org-link-set-parameters "docview"
			 :follow #'org-docview-open
			 :export #'org-docview-export
			 :store #'org-docview-store-link)

(defun org-docview-export (link description backend _info)
  "Export a docview LINK with DESCRIPTION for BACKEND."
  (let ((path (if (string-match "\\(.+\\)::.+" link) (match-string 1 link)
		link))
        (desc (or description link)))
    (when (stringp path)
      (setq path (expand-file-name path))
      (cond
       ((eq backend 'html) (format "<a href=\"%s\">%s</a>" path desc))
       ((eq backend 'latex) (format "\\href{%s}{%s}" path desc))
       ((eq backend 'ascii) (format "[%s] (<%s>)" desc path))
       (t path)))))

(defun org-docview-open (link _)
  "Open docview: LINK."
  (string-match "\\(.*?\\)\\(?:::\\([0-9]+\\)\\)?$" link)
  (let ((path (match-string 1 link))
	(page (and (match-beginning 2)
		   (string-to-number (match-string 2 link)))))
    ;; Let Org mode open the file (in-emacs = 1) to ensure
    ;; org-link-frame-setup is respected.
    (if (file-exists-p path)
        (org-open-file path 1)
      (error "No such file: %s" path))
    (when page (doc-view-goto-page page))))

(defun org-docview-store-link (&optional _interactive?)
  "Store a link to a docview buffer."
  (when (eq major-mode 'doc-view-mode)
    ;; This buffer is in doc-view-mode
    (let* ((path buffer-file-name)
	   (page (image-mode-window-get 'page))
	   (link (concat "docview:" path "::" (number-to-string page))))
      (org-link-store-props
       :type "docview"
       :link link
       :description path))))

(defun org-docview-complete-link ()
  "Use the existing file name completion for file.
Links to get the file name, then ask the user for the page number
and append it."
  (concat (replace-regexp-in-string "^file:" "docview:" (org-link-complete-file))
	  "::"
	  (read-from-minibuffer "Page:" "1")))

(provide 'ol-docview)

;;; ol-docview.el ends here
