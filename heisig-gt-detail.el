;;; heisig-gt-detail.el --- Detail buffer for one kanji  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Assisted-by: Claude:claude-opus-5
;; Keywords: languages, i18n
;; URL: https://github.com/dmgerman/heisig-gt
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `heisig-gt-detail-show' fills one buffer with everything the
;; database holds about a single kanji: readings, components, the
;; characters it is itself a component of, Heisig's story, the
;; mnemonic, the stories other learners wrote, compounds, and the
;; stroke order.
;;
;; Components and the characters built from them are buttons, so the
;; primitive graph can be walked in either direction; `n' and `p' walk
;; the Heisig frames in order instead.

;;; Code:

;; `heisig-gt-kanji' is deliberately not required here: it requires
;; this file.  The one command that goes back to it is reached through
;; its autoload.
(require 'button)
(require 'heisig-gt-db)
(require 'seq)
(require 'subr-x)

(declare-function heisig-gt-kanji "heisig-gt-kanji" (&optional char))
(declare-function heisig-gt-words "heisig-gt-words" (&optional chars))

;;;; Faces

(defface heisig-gt-detail-char
  '((t :height 6.0))
  "Face for the character at the top of the detail buffer."
  :group 'heisig-gt)

(defface heisig-gt-detail-keyword
  '((t :inherit font-lock-function-name-face :height 1.4))
  "Face for the keyword at the top of the detail buffer."
  :group 'heisig-gt)

(defface heisig-gt-detail-section
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a section heading in the detail buffer."
  :group 'heisig-gt)

(defface heisig-gt-detail-reading
  '((t :inherit font-lock-string-face))
  "Face for a reading in the detail buffer."
  :group 'heisig-gt)

(defface heisig-gt-detail-attribution
  '((t :inherit font-lock-comment-face))
  "Face for the author and vote count of a borrowed story."
  :group 'heisig-gt)

;;;; Customization

(defcustom heisig-gt-detail-buffer-name "*Kanji Detail*"
  "Name of the buffer `heisig-gt-detail-show' fills.
One buffer is reused for every kanji, so walking the components
or the frames leaves one window in place rather than a trail of
them."
  :type 'string
  :group 'heisig-gt)

(defcustom heisig-gt-detail-max-words 20
  "How many compounds the detail buffer lists.
The database holds over a hundred for some characters, which
buries every section below them."
  :type 'integer
  :group 'heisig-gt)

(defcustom heisig-gt-detail-max-stories 5
  "How many borrowed stories the detail buffer lists."
  :type 'integer
  :group 'heisig-gt)

(defcustom heisig-gt-detail-show-stroke-order t
  "Whether to render the stroke-order diagram.
Ignored when this Emacs cannot display SVG."
  :type 'boolean
  :group 'heisig-gt)

;;;; Buffer-local state

(defvar-local heisig-gt-detail--char nil
  "Character the detail buffer is currently showing.")

;;;; HTML fragments
;;
;; Three of the stored fields are HTML: Heisig's story, his comment on
;; the primitive, and the mnemonic sentence, which marks the component
;; keywords it uses.  Between them they use six tags, so a regexp pass
;; is enough and `shr' -- which would reflow the text and pull in the
;; whole renderer -- is not needed.  The fragments are stored as they
;; came so a better renderer can be dropped in later.

(defconst heisig-gt-detail--tag-regexp
  (rx "<" (group (or "b" "strong" "i" "em" "u")) ">"
      (group (*? anychar))
      "</" (backref 1) ">")
  "One emphasis element and its contents.")

(defconst heisig-gt-detail--entities
  '(("&amp;" . "&") ("&lt;" . "<") ("&gt;" . ">")
    ("&quot;" . "\"") ("&#39;" . "'") ("&apos;" . "'")
    ("&nbsp;" . " "))
  "HTML entities the sources use, and what they stand for.")

(defun heisig-gt-detail--tag-face (tag)
  "Return the face TAG asks for."
  (pcase (downcase tag)
    ((or "b" "strong") 'bold)
    ((or "i" "em") 'italic)
    ("u" 'underline)))

(defun heisig-gt-detail--render-html (html)
  "Return the HTML fragment HTML as a propertized string.
Emphasis becomes a text property, `<br>' becomes a newline, and
any other tag is dropped.  Nested emphasis composes rather than
replacing what encloses it."
  (if (null html)
      ""
    (with-temp-buffer
      (insert html)
      (let ((case-fold-search t))
        (goto-char (point-min))
        (while (re-search-forward (rx "<br" (? " ") (? "/") ">") nil t)
          (replace-match "\n"))
        ;; Innermost elements match first, and the scan resumes at the
        ;; start of what was just unwrapped, so an element nested
        ;; inside another is reached on the following pass and adds
        ;; its face to the one already there.
        (goto-char (point-min))
        (while (re-search-forward heisig-gt-detail--tag-regexp nil t)
          (let ((face (heisig-gt-detail--tag-face (match-string 1)))
                (inner (match-string 2))
                (start (match-beginning 0)))
            (delete-region start (match-end 0))
            (goto-char start)
            (insert inner)
            (add-face-text-property start (point) face)
            (goto-char start)))
        (goto-char (point-min))
        (while (re-search-forward (rx "<" (? "/") alpha (*? anychar) ">")
                                  nil t)
          (replace-match ""))
        (dolist (entity heisig-gt-detail--entities)
          (goto-char (point-min))
          (while (search-forward (car entity) nil t)
            (replace-match (cdr entity) t t))))
      (string-trim (buffer-string)))))

;;;; Rendering helpers

(defun heisig-gt-detail--section (title)
  "Insert the heading TITLE, with a blank line above it."
  (insert "\n" (propertize title 'face 'heisig-gt-detail-section) "\n"))

(defun heisig-gt-detail--line (label value)
  "Insert LABEL and VALUE on a line, or nothing when VALUE is empty."
  (unless (or (null value) (equal value ""))
    (insert (propertize (format "%-9s" label) 'face 'bold) value "\n")))

(defun heisig-gt-detail--char-button (char)
  "Insert CHAR as a button visiting it, or as plain text when unknown.
A character the database has no row for is still shown: the
component graph names characters outside the decks the database
was built from, and dropping them would misrepresent what a
kanji is made of."
  (if (heisig-gt-db-known-p char)
      (insert-text-button
       char
       'action (lambda (button)
                 (heisig-gt-detail-show (button-get button 'heisig-gt-char)))
       'heisig-gt-char char
       'follow-link t
       'help-echo (format "Show %s" char))
    (insert (propertize char 'face 'shadow))))

(defun heisig-gt-detail--insert-chars (label chars)
  "Insert LABEL and CHARS, each a button, separated by spaces."
  (when chars
    (insert (propertize (format "%-9s" label) 'face 'bold))
    (dolist (char chars)
      (heisig-gt-detail--char-button char)
      (insert " "))
    (insert "\n")))

(defun heisig-gt-detail--facts (kanji)
  "Return the one-line summary of the measurable facts about KANJI."
  (string-join
   (delq nil
         (list (plist-get kanji :kind)
               (when-let* ((n (plist-get kanji :strokes)))
                 (format "%d strokes" n))
               (when-let* ((r (plist-get kanji :radical)))
                 (format "radical %s" r))
               (when-let* ((j (plist-get kanji :jlpt)))
                 (and (> j 0) (format "JLPT N%d" j)))
               (when-let* ((g (plist-get kanji :grade)))
                 (format "grade %s" g))
               (when-let* ((f (plist-get kanji :freq-rank)))
                 (format "frequency %d" f))
               (when-let* ((k (plist-get kanji :kanken)))
                 (format "kanken %s" k))
               (when-let* ((w (plist-get kanji :wk)))
                 (format "WaniKani %s" w))))
   " · "))

(defun heisig-gt-detail--study-line (char)
  "Return the one-line summary of the Anki progress of CHAR, or nil."
  (when-let* ((study (heisig-gt-db-study char))
              (status (plist-get study :status)))
    (string-join
     (delq nil
           (list (propertize (symbol-name status)
                             'face (heisig-gt-db-status-face status))
                 (when-let* ((ivl (plist-get study :ivl)))
                   (and (> ivl 0) (format "interval %d days" ivl)))
                 (when-let* ((reps (plist-get study :reps)))
                   (format "%d reviews" reps))
                 (when-let* ((lapses (plist-get study :lapses)))
                   (and (> lapses 0) (format "%d lapses" lapses)))
                 (when-let* ((due (plist-get study :due)))
                   (format-time-string "due %Y-%m-%d" due))))
     " · ")))

;;;; Rendering

(defun heisig-gt-detail--insert-header (kanji)
  "Insert the heading of the detail buffer for KANJI."
  (insert (propertize (plist-get kanji :char)
                      'face 'heisig-gt-detail-char)
          "\n")
  (when-let* ((frame (plist-get kanji :heisig6)))
    (insert (propertize (format "frame %d" frame)
                        'face 'font-lock-constant-face)
            "  "))
  (insert (propertize (or (plist-get kanji :keyword) "")
                      'face 'heisig-gt-detail-keyword)
          "\n")
  ;; A keyword the user overrode is worth saying so: it is the one
  ;; field here that is not the same for every reader of the book.
  (when (equal (plist-get kanji :keyword-source) "usr")
    (insert (propertize "your own keyword" 'face 'shadow) "\n"))
  (insert (heisig-gt-detail--facts kanji) "\n"))

(defun heisig-gt-detail--insert-readings (char)
  "Insert the readings of CHAR."
  (let ((on (heisig-gt-db-readings char "on"))
        (kun (heisig-gt-db-readings char "kun"))
        (nanori (heisig-gt-db-readings char "nanori")))
    (when (or on kun nanori)
      (heisig-gt-detail--section "Readings")
      (dolist (pair (list (cons "On" on) (cons "Kun" kun)
                          (cons "Nanori" nanori)))
        (when (cdr pair)
          (heisig-gt-detail--line
           (car pair)
           (propertize (string-join (cdr pair) "、")
                       'face 'heisig-gt-detail-reading)))))))

(defun heisig-gt-detail--insert-graph (char)
  "Insert the components of CHAR and the characters it builds."
  (let ((components (heisig-gt-db-components char))
        (used-in (heisig-gt-db-used-in char)))
    (when (or components used-in)
      (heisig-gt-detail--section "Components")
      (dolist (row components)
        (heisig-gt-detail--char-button (car row))
        (insert "  " (propertize (or (heisig-gt-db-component-name row) "")
                                 'face 'bold))
        (when (caddr row)
          (insert "  " (propertize (caddr row) 'face 'shadow)))
        (insert "\n"))
      (heisig-gt-detail--insert-chars "Used in" used-in))))

(defun heisig-gt-detail--insert-prose (kanji)
  "Insert the story, the comment and the mnemonic of KANJI."
  (dolist (pair (list (cons "Story" (plist-get kanji :story))
                      (cons "Note" (plist-get kanji :comment))
                      (cons "Mnemonic" (plist-get kanji :mnemonic))))
    (when (cdr pair)
      (heisig-gt-detail--section (car pair))
      (insert (heisig-gt-detail--render-html (cdr pair)) "\n"))))

(defun heisig-gt-detail--insert-words (char)
  "Insert the compounds recorded for CHAR."
  (when-let* ((words (heisig-gt-db-words char)))
    (heisig-gt-detail--section "Compounds")
    (dolist (word (seq-take words heisig-gt-detail-max-words))
      (insert (format "%-12s %s" (car word)
                      (propertize (or (cadr word) "")
                                  'face 'heisig-gt-detail-reading)))
      (when (caddr word)
        (insert "  " (propertize (caddr word) 'face 'shadow)))
      (insert "\n"))
    (when (> (length words) heisig-gt-detail-max-words)
      (insert (propertize
               (format "... and %d more\n"
                       (- (length words) heisig-gt-detail-max-words))
               'face 'shadow)))))

(defun heisig-gt-detail--insert-stories (char)
  "Insert the borrowed stories recorded for CHAR."
  (when-let* ((stories (heisig-gt-db-stories char)))
    (heisig-gt-detail--section "Stories")
    (dolist (story (seq-take stories heisig-gt-detail-max-stories))
      (pcase-let ((`(,source ,author ,votes ,_date ,text) story))
        (insert (propertize
                 (format "%s%s\n"
                         (or author source "")
                         (if votes (format " (%d votes)" votes) ""))
                 'face 'heisig-gt-detail-attribution))
        (insert (heisig-gt-detail--render-html text) "\n\n")))))

(defun heisig-gt-detail--insert-stroke-order (char)
  "Insert the stroke-order diagram of CHAR when one can be shown."
  (when (and heisig-gt-detail-show-stroke-order
             (display-graphic-p)
             (image-type-available-p 'svg))
    (when-let* ((svg (heisig-gt-db-stroke-svg char)))
      (heisig-gt-detail--section "Stroke order")
      (insert-image (create-image svg 'svg t))
      (insert "\n"))))

(defun heisig-gt-detail--render (char)
  "Fill the current buffer with everything known about CHAR."
  (let ((kanji (or (heisig-gt-db-kanji char)
                   (user-error "No entry for %s" char)))
        (inhibit-read-only t))
    (erase-buffer)
    (heisig-gt-detail--insert-header kanji)
    (heisig-gt-detail--line "Meanings" (plist-get kanji :meanings))
    (heisig-gt-detail--insert-readings char)
    (heisig-gt-detail--insert-graph char)
    (heisig-gt-detail--insert-prose kanji)
    (heisig-gt-detail--insert-words char)
    (heisig-gt-detail--insert-stories char)
    (heisig-gt-detail--insert-stroke-order char)
    (when-let* ((study (heisig-gt-detail--study-line char)))
      (heisig-gt-detail--section "Anki")
      (insert study "\n"))
    (heisig-gt-detail--section "Sources")
    (insert (propertize (or (plist-get kanji :sources) "") 'face 'shadow)
            "\n")
    (setq heisig-gt-detail--char char)
    (goto-char (point-min))))

;;;; Mode + keymap

(defvar-keymap heisig-gt-detail-mode-map
  :doc "Keymap for `heisig-gt-detail-mode'."
  :parent special-mode-map
  "n"   #'heisig-gt-detail-next-frame
  "p"   #'heisig-gt-detail-previous-frame
  "w"   #'heisig-gt-detail-words
  "M-w" #'heisig-gt-detail-copy-char
  ;; `k' reaches the kanji list from the word list too, so it means
  ;; the same thing here; `l' is kept for the reader who already has
  ;; it in their fingers.
  "k"   #'heisig-gt-detail-back-to-list
  "l"   #'heisig-gt-detail-back-to-list
  "g"   #'revert-buffer)

(define-derived-mode heisig-gt-detail-mode special-mode "Kanji"
  "Major mode for the buffer showing one kanji in detail.

Every character shown as a component, or as one of the characters
the current one is a component of, is a button: following it
shows that character here instead.  A character the database has
no entry for is shown dimmed and is not a button.

  \\[heisig-gt-detail-next-frame] next Heisig frame
  \\[heisig-gt-detail-previous-frame] previous Heisig frame
  \\[heisig-gt-detail-words] list the words written with it
  \\[heisig-gt-detail-back-to-list] go to its row in the kanji list
  \\[heisig-gt-detail-copy-char] copy the character to the kill ring
  \\[revert-buffer] redraw
  \\[quit-window] quit

\\{heisig-gt-detail-mode-map}"
  (setq-local revert-buffer-function #'heisig-gt-detail--revert)
  (setq-local truncate-lines nil))

(defun heisig-gt-detail--revert (&rest _args)
  "Redraw the detail buffer from the database."
  (when heisig-gt-detail--char
    (heisig-gt-detail--render heisig-gt-detail--char)))

;;;; Commands

;;;###autoload
(defun heisig-gt-detail-show (char &optional other-window)
  "Show everything known about CHAR.
One buffer is reused, so following a component replaces what is
displayed rather than opening another window.  With
OTHER-WINDOW, display it in a window other than the selected
one."
  (interactive (list (read-string "Kanji: ")))
  (let ((buf (get-buffer-create heisig-gt-detail-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'heisig-gt-detail-mode)
        (heisig-gt-detail-mode))
      (heisig-gt-detail--render char))
    (if other-window
        (display-buffer buf)
      (pop-to-buffer buf))
    buf))

(defun heisig-gt-detail--require-char ()
  "Return the character this buffer is showing, or signal."
  (or heisig-gt-detail--char
      (user-error "This buffer is not showing a kanji")))

(defun heisig-gt-detail-copy-char ()
  "Copy the character being shown to the kill ring."
  (interactive nil heisig-gt-detail-mode)
  (let ((char (heisig-gt-detail--require-char)))
    (kill-new char)
    (message "Copied %s" char)))

(defun heisig-gt-detail--step-frame (direction)
  "Show the character DIRECTION frames from the current one."
  (let* ((char (heisig-gt-detail--require-char))
         (frame (plist-get (heisig-gt-db-kanji char) :heisig6)))
    (unless frame
      (user-error "%s has no Heisig frame to step from" char))
    (let ((next (heisig-gt-db-neighbour frame direction)))
      (unless next
        (user-error "No %s frame" (if (> direction 0) "later" "earlier")))
      (heisig-gt-detail-show next))))

(defun heisig-gt-detail-next-frame ()
  "Show the kanji at the next Heisig frame."
  (interactive nil heisig-gt-detail-mode)
  (heisig-gt-detail--step-frame 1))

(defun heisig-gt-detail-previous-frame ()
  "Show the kanji at the previous Heisig frame."
  (interactive nil heisig-gt-detail-mode)
  (heisig-gt-detail--step-frame -1))

(defun heisig-gt-detail-words ()
  "List the words written with the character being shown."
  (interactive nil heisig-gt-detail-mode)
  (heisig-gt-words (heisig-gt-detail--require-char)))

(defun heisig-gt-detail-back-to-list ()
  "Return to the kanji list, on the character being shown."
  (interactive nil heisig-gt-detail-mode)
  (heisig-gt-kanji heisig-gt-detail--char))

(provide 'heisig-gt-detail)

;;; heisig-gt-detail.el ends here
