;;; test-heisig-gt-detail.el --- Tests for heisig-gt-detail  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The detail buffer: the HTML fragments the sources store, and what
;; the rendered buffer contains.

;;; Code:

(require 'ert)
(require 'heisig-gt-detail)
(require 'heisig-gt-test-helper)

(defmacro heisig-gt-detail-test-with-buffer (char &rest body)
  "Render CHAR into a fresh detail buffer and run BODY there."
  (declare (indent 1) (debug t))
  `(heisig-gt-test-with-db
     (let ((buffer (generate-new-buffer " *heisig-gt-test-detail*")))
       (unwind-protect
           (with-current-buffer buffer
             (heisig-gt-detail-mode)
             (heisig-gt-detail--render ,char)
             ,@body)
         (kill-buffer buffer)))))

;;;; HTML fragments

(ert-deftest heisig-gt-detail-test-html-plain-text-is-unchanged ()
  "A fragment with no markup comes back as it went in."
  (should (equal (heisig-gt-detail--render-html "Water . . . gone.")
                 "Water . . . gone."))
  (should (equal (heisig-gt-detail--render-html nil) "")))

(ert-deftest heisig-gt-detail-test-html-emphasis-becomes-a-property ()
  "Emphasis is carried by a text property, not by the text."
  (let ((rendered (heisig-gt-detail--render-html "a <b>bold</b> move")))
    (should (equal (substring-no-properties rendered) "a bold move"))
    (should (memq 'bold (ensure-list (get-text-property 2 'face rendered))))
    (should (null (get-text-property 0 'face rendered)))))

(ert-deftest heisig-gt-detail-test-html-nesting-composes ()
  "Nested emphasis adds to what encloses it rather than replacing it."
  (let* ((rendered (heisig-gt-detail--render-html
                    "<strong><u>puddle</u></strong>"))
         (faces (ensure-list (get-text-property 0 'face rendered))))
    (should (equal (substring-no-properties rendered) "puddle"))
    (should (memq 'bold faces))
    (should (memq 'underline faces))))

(ert-deftest heisig-gt-detail-test-html-line-breaks ()
  "A break element becomes a newline, in either spelling."
  (should (equal (heisig-gt-detail--render-html "a<br>b") "a\nb"))
  (should (equal (heisig-gt-detail--render-html "a<br/>b") "a\nb")))

(ert-deftest heisig-gt-detail-test-html-drops-other-tags ()
  "A tag that carries no emphasis is removed, keeping its text."
  (should (equal (heisig-gt-detail--render-html
                  "<div lang=\"en\">text</div>")
                 "text")))

(ert-deftest heisig-gt-detail-test-html-entities ()
  "The entities the sources use are decoded."
  (should (equal (heisig-gt-detail--render-html "a &amp; b") "a & b"))
  (should (equal (heisig-gt-detail--render-html "&lt;tag&gt;") "<tag>"))
  (should (equal (heisig-gt-detail--render-html "it&#39;s") "it's")))

;;;; Rendering

(ert-deftest heisig-gt-detail-test-buffer-has-every-section ()
  "The buffer names each section it has something to put under."
  (heisig-gt-detail-test-with-buffer "一"
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "frame 1" text))
      (should (string-match-p "Readings" text))
      (should (string-match-p "イチ" text))
      (should (string-match-p "Components" text))
      (should (string-match-p "Story" text))
      (should (string-match-p "Compounds" text))
      (should (string-match-p "一番" text))
      (should (string-match-p "Stories" text))
      (should (string-match-p "A single line" text))
      (should (string-match-p "Anki" text))
      (should (string-match-p "migaku,academy,json" text)))))

(ert-deftest heisig-gt-detail-test-empty-sections-are-omitted ()
  "A section with nothing under it is not written at all."
  (heisig-gt-detail-test-with-buffer "森"
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "forest" text))
      (should-not (string-match-p "Readings" text))
      (should-not (string-match-p "Compounds" text))
      ;; 森 is in no Anki deck, so there is no progress to report.
      (should-not (string-match-p "Anki" text)))))

(ert-deftest heisig-gt-detail-test-records-what-it-is-showing ()
  "The buffer remembers its character, which is what `n' steps from."
  (heisig-gt-detail-test-with-buffer "一"
    (should (equal heisig-gt-detail--char "一"))
    (should (equal (heisig-gt-detail--require-char) "一"))))

(ert-deftest heisig-gt-detail-test-unknown-character-signals ()
  "Rendering a character with no row is refused, not drawn empty."
  (heisig-gt-test-with-db
    (with-temp-buffer
      (should-error (heisig-gt-detail--render "鬱") :type 'user-error))))

(ert-deftest heisig-gt-detail-test-user-keyword-is-marked ()
  "A keyword the user set is said to be theirs."
  (heisig-gt-detail-test-with-buffer "肉"
    (should (string-match-p
             "your own keyword"
             (buffer-substring-no-properties (point-min) (point-max))))))

;;;; Links

(ert-deftest heisig-gt-detail-test-known-components-are-buttons ()
  "A component with a row of its own can be followed."
  (heisig-gt-detail-test-with-buffer "肉"
    (goto-char (point-min))
    (should (search-forward "[apron]" nil t))
    (let ((button (next-button (point-min))))
      (should button)
      (should (equal (button-get button 'heisig-gt-char) "[apron]")))))

(ert-deftest heisig-gt-detail-test-dangling-links-are-plain-text ()
  "A character the graph names but the database lacks is not a button.
The component graph reaches outside the decks the database was
built from, and a button that led nowhere would be worse than
none."
  (heisig-gt-detail-test-with-buffer "一"
    (goto-char (point-min))
    (should (search-forward "二" nil t))
    (should (null (get-text-property (match-beginning 0) 'button)))))

;;;; Frame stepping

(ert-deftest heisig-gt-detail-test-keys ()
  "The detail buffer spells its keys as the two lists do.
`k' reaches the kanji list from the word list as well, and `l'
stays bound to it for the reader who already has that one."
  (should (eq (keymap-lookup heisig-gt-detail-mode-map "w")
              'heisig-gt-detail-words))
  (should (eq (keymap-lookup heisig-gt-detail-mode-map "M-w")
              'heisig-gt-detail-copy-char))
  (should (eq (keymap-lookup heisig-gt-detail-mode-map "k")
              'heisig-gt-detail-back-to-list))
  (should (eq (keymap-lookup heisig-gt-detail-mode-map "l")
              'heisig-gt-detail-back-to-list)))

(ert-deftest heisig-gt-detail-test-stepping-stops-at-the-ends ()
  "There is no frame before the first one."
  (heisig-gt-detail-test-with-buffer "一"
    (should-error (heisig-gt-detail--step-frame -1) :type 'user-error)))

(ert-deftest heisig-gt-detail-test-stepping-needs-a-frame ()
  "A character with no frame number has nothing to step from."
  (heisig-gt-detail-test-with-buffer "森"
    (should-error (heisig-gt-detail--step-frame 1) :type 'user-error)))

(provide 'test-heisig-gt-detail)

;;; test-heisig-gt-detail.el ends here
