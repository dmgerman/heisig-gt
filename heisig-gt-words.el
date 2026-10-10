;;; heisig-gt-words.el --- Word list seeded by kanji  -*- lexical-binding: t; -*-

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

;; `heisig-gt-words' lists Japanese words, ordered by how often they
;; occur in Netflix subtitles, seeded by the kanji they are written
;; with.  From the kanji list, \\[heisig-gt-kanji-words] seeds it with
;; the kanji at point.
;;
;; The mode derives from `heisig-gt-kanji-mode' and supplies its own
;; column and filter registries; everything else -- rendering,
;; sorting, the filter algebra, bookmarks, saved views -- is that
;; mode's and behaves identically here.
;;
;; The seed is what was loaded; filters narrow it further, either by
;; more kanji or by pronunciation, which can be typed in romaji.

;;; Code:

(require 'heisig-gt-db)
(require 'heisig-gt-kanji)
(require 'seq)
(require 'subr-x)

;;;; Customization

(defcustom heisig-gt-words-buffer-name "*Words*"
  "Name of the buffer `heisig-gt-words' displays."
  :type 'string
  :group 'heisig-gt)

(defcustom heisig-gt-words-max-rank 20000
  "How far down the frequency order the word list reaches.

The database holds every word that resolved to a dictionary
headword, some 52000 of them, because a fifth of the frequency
report is not really vocabulary -- stray katakana, initialisms,
names the tokeniser kept -- and where that junk sits decides what
any given cut-off actually contains.  Raising this needs no
rebuild.

For scale: the first 1000 words account for 82% of all words
spoken, 12000 for 96%, and the whole 52000 for 98%."
  :type 'integer
  :group 'heisig-gt)

(defcustom heisig-gt-words-columns
  '(rank root reading romaji pos jlpt definition)
  "Columns displayed by `heisig-gt-words', in display order."
  :type '(repeat symbol)
  :group 'heisig-gt)

(defcustom heisig-gt-words-default-sort-key '("Rank" . nil)
  "Initial sort key of a `heisig-gt-words' buffer.
The default opens the list commonest word first, which is the
order the frequency report is in."
  :type '(cons string boolean)
  :group 'heisig-gt)

;;;; Buffer-local state

(defvar-local heisig-gt-words--seed nil
  "Characters this buffer was seeded with, or nil for no seed.
A word is loaded when it is written with any one of them.  Nil
loads every word up to `heisig-gt-words-max-rank'.")

;;;; Column value functions

(defun heisig-gt-words--text (word field)
  "Return FIELD of WORD as cell text, empty when it is absent."
  (let ((value (plist-get word field)))
    (if value (format "%s" value) "")))

(defun heisig-gt-words--rank (word)
  "Return the frequency rank of WORD."
  (heisig-gt-words--text word :rank))

(defun heisig-gt-words--root (word)
  "Return the dictionary headword of WORD."
  (heisig-gt-words--text word :root))

(defun heisig-gt-words--surface (word)
  "Return the spelling the subtitles used for WORD."
  (heisig-gt-words--text word :surface))

(defun heisig-gt-words--lemma (word)
  "Return the dictionary form the tokeniser gave WORD."
  (heisig-gt-words--text word :lemma))

(defun heisig-gt-words--reading (word)
  "Return the pronunciation of WORD, in kana."
  (heisig-gt-words--text word :reading))

(defun heisig-gt-words--romaji (word)
  "Return the pronunciation of WORD, transliterated."
  (heisig-gt-words--text word :romaji))

(defun heisig-gt-words--pos (word)
  "Return the part-of-speech tags the dictionary gives WORD."
  (heisig-gt-words--text word :pos))

(defun heisig-gt-words--unidic-pos (word)
  "Return the part of speech the tokeniser gave WORD."
  (heisig-gt-words--text word :unidic-pos))

(defun heisig-gt-words--count (word)
  "Return how many times WORD occurs in the corpus."
  (heisig-gt-words--text word :count))

(defun heisig-gt-words--definition (word)
  "Return the English senses of WORD."
  (heisig-gt-words--text word :definition))

(defun heisig-gt-words--jlpt (word)
  "Return the JLPT level of WORD, written as N5 through N3.
Only those three lists exist, so a word above them is blank
rather than wrongly marked as hard."
  (heisig-gt-db-jlpt-string (plist-get word :jlpt)))

(defun heisig-gt-words--pct (word)
  "Return how much of all speech WORD accounts for."
  (let ((pct (plist-get word :pct)))
    (if pct (format "%.3f" pct) "")))

(defun heisig-gt-words--cum-pct (word)
  "Return how much of all speech WORD and everything commoner cover."
  (let ((pct (plist-get word :cum-pct)))
    (if pct (format "%.1f%%" pct) "")))

;;;; Column registry

(defvar heisig-gt-words-column-alist
  (list
   (cons 'rank       (list :name "Rank" :width 6
                           :value #'heisig-gt-words--rank
                           :face 'font-lock-constant-face
                           :sort (heisig-gt-kanji--number-compare :rank)
                           :doc "Position in the Netflix frequency order."))
   (cons 'root       (list :name "Word" :width 14
                           :value #'heisig-gt-words--root
                           :face nil :sort t
                           :doc "Dictionary headword."))
   (cons 'surface    (list :name "Written" :width 14
                           :value #'heisig-gt-words--surface
                           :face nil :sort t
                           :doc "Spelling the subtitles used most often."))
   (cons 'lemma      (list :name "Lemma" :width 14
                           :value #'heisig-gt-words--lemma
                           :face nil :sort t
                           :doc "Dictionary form the tokeniser assigned."))
   (cons 'reading    (list :name "Reading" :width 16
                           :value #'heisig-gt-words--reading
                           :face 'font-lock-string-face :sort t
                           :doc "Pronunciation, in kana."))
   (cons 'romaji     (list :name "Romaji" :width 18
                           :value #'heisig-gt-words--romaji
                           :face 'font-lock-string-face :sort t
                           :doc "Pronunciation, transliterated."))
   (cons 'pos        (list :name "Type" :width 14
                           :value #'heisig-gt-words--pos
                           :face 'font-lock-type-face :sort t
                           :doc "Part of speech, as the dictionary tags it."))
   (cons 'unidic-pos (list :name "UniDic" :width 10
                           :value #'heisig-gt-words--unidic-pos
                           :face 'font-lock-type-face :sort t
                           :doc "Part of speech the tokeniser assigned."))
   (cons 'jlpt       (list :name "JLPT" :width 4
                           :value #'heisig-gt-words--jlpt
                           :face nil
                           :sort (heisig-gt-kanji--number-compare :jlpt)
                           :doc "JLPT level; only N5, N4 and N3 exist."))
   (cons 'count      (list :name "Count" :width 8
                           :value #'heisig-gt-words--count
                           :face nil
                           :sort (heisig-gt-kanji--number-compare :count)
                           :doc "Times the word occurs in the corpus."))
   (cons 'pct        (list :name "%" :width 6
                           :value #'heisig-gt-words--pct
                           :face nil
                           :sort (heisig-gt-kanji--number-compare :pct)
                           :doc "Share of all words spoken."))
   (cons 'cum-pct    (list :name "Cum" :width 7
                           :value #'heisig-gt-words--cum-pct
                           :face 'font-lock-comment-face
                           :sort (heisig-gt-kanji--number-compare :cum-pct)
                           :doc "Share covered by this word and every \
commoner one."))
   (cons 'definition (list :name "Definition" :width 60
                           :value #'heisig-gt-words--definition
                           :face nil :sort t
                           :doc "English senses, commonest first.")))
  "Column registry for the word list buffer.
Same shape as `heisig-gt-kanji-column-alist'; see its docstring.")

;;;; Filter registry

(defvar heisig-gt-words-filter-alist nil
  "Filters offered in a `heisig-gt-words' buffer.
Same shape as `heisig-gt-kanji-filter-alist'; see its docstring.")

(defun heisig-gt-words--pos-tags ()
  "Return every distinct part-of-speech tag in this buffer, sorted.
The dictionary tags a word with a space-separated set -- `adj-na
n uk' -- so the tags are offered rather than the sets: there are
about a hundred of the first and over a thousand of the second."
  (sort (delete-dups
         (seq-mapcat (lambda (word)
                       (split-string (or (plist-get word :pos) "") " " t))
                     heisig-gt-kanji--records))
        #'string-lessp))

(defconst heisig-gt-words-seed-separators '(?\s ?\t ?, ?、)
  "Characters discarded when a seed is read.
A seed is a run of characters, so nothing in it separates one
from the next; these are accepted and dropped because a reader
typing several will reach for one of them anyway.")

(defun heisig-gt-words--split-seed (string)
  "Return the seed STRING spells, as a list of one-character strings.

The one place a seed is parsed.  It was two -- the prompt and the
entry point each had their own copy -- which is a standing
invitation for the command and the key that reseeds it to accept
different input."
  (mapcar #'char-to-string
          (seq-remove (lambda (ch)
                        (memq ch heisig-gt-words-seed-separators))
                      (string-to-list (or string "")))))

(defun heisig-gt-words--seed-chars (prompt)
  "Read a seed with PROMPT, returned as a list."
  (heisig-gt-words--split-seed (read-string prompt)))

(add-to-list 'heisig-gt-words-filter-alist
             (cons 'by-kanji
                   (list :name "Kanji"
                         :reader (lambda ()
                                   (heisig-gt-words--seed-chars
                                    "Written with (any of): "))
                         :predicate
                         (lambda (word char)
                           ;; `chars' and not `root': the seed selects
                           ;; through an index built from `chars', and
                           ;; reading the headword here instead is how
                           ;; the two came to disagree about kana.
                           (string-search char (or (plist-get word :chars)
                                                   "")))
                         :doc "Show only words written with one of the \
chosen characters.  Any character counts, not only kanji: メ selects \
カメラ.")))

(add-to-list 'heisig-gt-words-filter-alist
             (cons 'by-romaji
                   ;; A regexp rather than a completion: a word's
                   ;; reading is nearly unique, so choosing one from a
                   ;; list would only ever select that word, while
                   ;; "kou" usefully selects hundreds.
                   (list :name "Romaji"
                         :reader (lambda ()
                                   (list (read-regexp
                                          "Pronunciation matches (romaji)")))
                         :predicate
                         (lambda (word regexp)
                           (string-match-p regexp
                                           (or (plist-get word :romaji) "")))
                         :doc "Show only words whose pronunciation matches \
a regexp, written in romaji.")))

(add-to-list 'heisig-gt-words-filter-alist
             (cons 'by-reading
                   (list :name "Reading"
                         :reader (lambda ()
                                   (list (read-regexp
                                          "Pronunciation matches (kana)")))
                         :predicate
                         (lambda (word regexp)
                           (string-match-p regexp
                                           (or (plist-get word :reading) "")))
                         :doc "Show only words whose pronunciation matches \
a regexp, written in kana.")))

(add-to-list 'heisig-gt-words-filter-alist
             (cons 'by-pos
                   (list :name "Type"
                         :reader (lambda ()
                                   (completing-read-multiple
                                    "Parts of speech: "
                                    (heisig-gt-words--pos-tags) nil t))
                         :predicate
                         (lambda (word tag)
                           (member tag (split-string
                                        (or (plist-get word :pos) "")
                                        " " t)))
                         :doc "Show only words carrying one of the chosen \
part-of-speech tags.")))

(add-to-list 'heisig-gt-words-filter-alist
             (cons 'by-jlpt
                   (list :name "JLPT"
                         :reader
                         (lambda ()
                           (mapcar (lambda (value)
                                     (if (equal value "none")
                                         'none
                                       (string-to-number value)))
                                   (completing-read-multiple
                                    "JLPT levels: "
                                    '("5" "4" "3" "none") nil t)))
                         :predicate
                         (lambda (word level)
                           (if (eq level 'none)
                               (null (plist-get word :jlpt))
                             (equal level (plist-get word :jlpt))))
                         :doc "Show only words at one of the chosen JLPT \
levels; `none' is those above N3 or unlisted.")))

(add-to-list 'heisig-gt-words-filter-alist
             (cons 'by-rank
                   (list :name "Rank"
                         :reader (lambda ()
                                   (heisig-gt-kanji--read-range "Ranks"))
                         :predicate
                         (lambda (word spec)
                           (heisig-gt-kanji--in-range-p
                            (plist-get word :rank) spec))
                         :doc "Show only words in a range of frequency \
ranks.")))

(add-to-list 'heisig-gt-words-filter-alist
             (cons 'by-definition-regexp
                   (list :name "Definition regexp"
                         :reader (lambda ()
                                   (list (read-regexp "Definition matches")))
                         :predicate
                         (lambda (word regexp)
                           (string-match-p
                            regexp (or (plist-get word :definition) "")))
                         :doc "Show only words whose definition matches a \
regexp.")))

;;;; Loading

(defun heisig-gt-words--reload ()
  "Return this buffer's words, honouring the seed and the cut-off."
  (heisig-gt-db-vocab-list heisig-gt-words--seed heisig-gt-words-max-rank))

(defun heisig-gt-words--scope ()
  "Return the mode-line description of this buffer's contents."
  (if heisig-gt-words--seed
      (format "[%s]" (string-join heisig-gt-words--seed ""))
    (format "[top %d]" heisig-gt-words-max-rank)))

;;;; Commands

(defun heisig-gt-words--require-word ()
  "Return the word on the current line, or signal."
  (or (tabulated-list-get-id) (user-error "No word on this line")))

(defun heisig-gt-words-copy ()
  "Copy the word at point to the kill ring."
  (interactive nil heisig-gt-words-mode)
  (let ((word (plist-get (heisig-gt-words--require-word) :root)))
    (kill-new word)
    (message "Copied %s" word)))

(defun heisig-gt-words--read-kanji (prompt)
  "Return a kanji of the word at point, asking with PROMPT.
The question is only put when the word is written with more than
one kanji; with a single one there is nothing to choose.

Only the characters the kanji database has an entry for are
offered: the vocabulary comes from a subtitle corpus and the
kanji from Anki decks, so a word can be written with a character
neither the list nor the detail buffer has anything to say about,
and offering it would be offering a dead end."
  (let* ((root (plist-get (heisig-gt-words--require-word) :root))
         (chars (seq-uniq
                 (seq-filter (lambda (ch)
                               (heisig-gt-db-known-p (char-to-string ch)))
                             (string-to-list root)))))
    (unless chars
      (user-error "No kanji in %s is in the database" root))
    (if (cdr chars)
        (completing-read prompt (mapcar #'char-to-string chars) nil t)
      (char-to-string (car chars)))))

(defun heisig-gt-words-show-kanji ()
  "Show the detail of a kanji the word at point is written with."
  (interactive nil heisig-gt-words-mode)
  (heisig-gt-detail-show (heisig-gt-words--read-kanji "Show kanji: ")))

(defun heisig-gt-words-kanji-list ()
  "Show the kanji list, on a kanji the word at point is written with.

Where \[heisig-gt-words-show-kanji] opens the one character,
this goes to its row in the kanji list, so what surrounds it in
Heisig's order is there too.  A character the list's own filters
exclude is reported rather than jumped to."
  (interactive nil heisig-gt-words-mode)
  (heisig-gt-kanji (heisig-gt-words--read-kanji "Go to kanji: ")))

(defun heisig-gt-words-set-seed (chars)
  "Reload the buffer seeded with CHARS, replacing any present seed.
An empty answer clears the seed, which loads every word up to
`heisig-gt-words-max-rank'.  Seeding replaces; to narrow what is
already here, add a by-kanji filter instead."
  (interactive (list (heisig-gt-words--seed-chars
                      "Seed with (empty for all): "))
               heisig-gt-words-mode)
  (setq heisig-gt-words--seed chars)
  (heisig-gt-kanji--reload)
  (heisig-gt-kanji--redraw-preserving-point))

;;;; Mode

(defvar-keymap heisig-gt-words-mode-map
  :doc "Keymap for `heisig-gt-words-mode'."
  :parent heisig-gt-kanji-mode-map
  "k"   #'heisig-gt-words-show-kanji
  "K"   #'heisig-gt-words-kanji-list
  "RET" #'heisig-gt-words-show-kanji
  "TAB" #'heisig-gt-words-show-kanji
  "M-w" #'heisig-gt-words-copy
  "S"   #'heisig-gt-words-set-seed
  ;; `w' opens the word list everywhere else in the package; shadowed
  ;; here rather than left inherited, because the command behind it
  ;; reads a kanji from the row and a word row has none.
  "w"   #'undefined)

(define-derived-mode heisig-gt-words-mode heisig-gt-kanji-mode "Heisig-gt-words"
  "Major mode for the read-only word list buffer.

Each row is one Japanese word, ordered by how often it occurs in
Netflix subtitles.  Readings, parts of speech and definitions
come from the dictionary yomikun-gt ships; the JLPT level, where
there is one, from its N5, N4 and N3 vocabulary lists.

The buffer has a seed -- the characters whose words were loaded
-- and filters that narrow what the seed brought in.  The mode
line names the seed first, then the filters, then the counts.

  \\[heisig-gt-words-show-kanji] show the detail of a kanji of the word at point
  \\[heisig-gt-words-kanji-list] go to that kanji's row in the kanji list
  \\[heisig-gt-words-set-seed] reseed (replaces; empty for every word)
  \\[heisig-gt-words-copy] copy the word to the kill ring

Filters are by-kanji, by-romaji, by-reading, by-pos, by-jlpt,
by-rank, by-definition-regexp, and unfilter.  by-kanji narrows to
the words also written with a further character, and by-romaji
searches the pronunciation without needing an input method.
Everything else -- columns, sorting, bookmarks, saved views --
works as it does in `heisig-gt-kanji-mode'.

\\{heisig-gt-words-mode-map}"
  (setq heisig-gt-kanji--column-registry heisig-gt-words-column-alist)
  (setq heisig-gt-kanji--filter-registry heisig-gt-words-filter-alist)
  (setq heisig-gt-kanji--reload-function #'heisig-gt-words--reload)
  (setq heisig-gt-kanji--id-function (lambda (word) (plist-get word :rank)))
  (setq heisig-gt-kanji--default-columns heisig-gt-words-columns)
  (setq heisig-gt-kanji--default-sort-key heisig-gt-words-default-sort-key)
  ;; The seed is part of what this buffer is showing, so it is part of
  ;; its view.  Declaring it here is what makes the state file and a
  ;; bookmark keep it alike; the state file dropped it before, and a
  ;; restored view silently became the whole cut-off.
  (setq heisig-gt-kanji--view-extra-function
        (lambda () (list :seed heisig-gt-words--seed)))
  (setq heisig-gt-kanji--view-restore-function
        (lambda (view) (setq heisig-gt-words--seed (plist-get view :seed))))
  (setq heisig-gt-kanji--scope-function #'heisig-gt-words--scope)
  (setq heisig-gt-kanji--columns heisig-gt-words-columns)
  (setq tabulated-list-format (heisig-gt-kanji--format))
  (setq tabulated-list-sort-key
        (heisig-gt-kanji--valid-sort-key heisig-gt-words-default-sort-key))
  (tabulated-list-init-header))

;;;###autoload
(defun heisig-gt-words (&optional chars)
  "Display the word list, seeded with CHARS.
CHARS is a string of characters; a word is shown when it is
written with any one of them.  An empty seed shows every word up
to `heisig-gt-words-max-rank'.

Interactively, reads the seed; from the kanji list,
\\[heisig-gt-kanji-words] seeds it with the kanji at point."
  (interactive (list (read-string "Seed with (empty for all): ")))
  (let ((buf (get-buffer-create heisig-gt-words-buffer-name))
        (seed (heisig-gt-words--split-seed chars)))
    (with-current-buffer buf
      (unless (derived-mode-p 'heisig-gt-words-mode)
        (heisig-gt-words-mode))
      (setq heisig-gt-words--seed seed)
      (heisig-gt-kanji--reload)
      (heisig-gt-kanji--redraw-preserving-point))
    (pop-to-buffer-same-window buf)))

(add-to-list 'heisig-gt-kanji-view-mode-alist
             (list 'heisig-gt-words-mode
                   ;; Opened with no seed: the seed travels in the
                   ;; view, and is applied by the restore function
                   ;; above before the records are read.
                   :open (lambda () (heisig-gt-words ""))
                   :buffer-name-variable 'heisig-gt-words-buffer-name))

;; A bookmark saved before the handlers were one function names this
;; one, so it has to keep resolving; it forwards, and the mode field
;; its record lacks is supplied here.
;;;###autoload
(defun heisig-gt-words-bookmark-jump (bookmark)
  "Restore the word list view stored in BOOKMARK."
  (declare (obsolete heisig-gt-kanji-bookmark-jump "0.2"))
  (heisig-gt-kanji-bookmark-jump bookmark 'heisig-gt-words-mode))

(provide 'heisig-gt-words)

;;; heisig-gt-words.el ends here
