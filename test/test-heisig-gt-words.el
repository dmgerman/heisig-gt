;;; test-heisig-gt-words.el --- Tests for heisig-gt-words  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The word list: how the frequency report and the dictionary are
;; merged, and how the buffer seeds and narrows.

;;; Code:

(require 'ert)
(require 'heisig-gt-words)
(require 'heisig-gt-test-helper)

(defmacro heisig-gt-words-test-with-buffer (seed &rest body)
  "Run BODY in a word-list buffer seeded with SEED."
  (declare (indent 1) (debug t))
  `(heisig-gt-test-with-db
     (let ((buffer (generate-new-buffer " *heisig-gt-test-words*"))
           (heisig-gt-kanji-persist-state nil)
           (heisig-gt-kanji--state nil)
           (heisig-gt-kanji--state-loaded t))
       (unwind-protect
           (with-current-buffer buffer
             (heisig-gt-words-mode)
             (setq heisig-gt-words--seed ,seed)
             (heisig-gt-kanji--reload)
             (heisig-gt-kanji--redraw-preserving-point)
             ,@body)
         (kill-buffer buffer)))))

(defun heisig-gt-words-test-apply (key values &optional negate)
  "Apply the filter KEY over VALUES, optionally NEGATE it, and redraw."
  (setq heisig-gt-kanji--filters
        (list (list :key key :values values :negate negate)))
  (heisig-gt-kanji--redraw-preserving-point)
  heisig-gt-kanji--shown)

(defun heisig-gt-words-test-roots ()
  "Return the headword of every row now displayed, in order."
  (let ((roots nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((word (tabulated-list-get-id)))
          (push (plist-get word :root) roots))
        (forward-line 1)))
    (nreverse roots)))

;;;; The merge

(ert-deftest heisig-gt-words-test-ordering-is-the-frequency-order ()
  "The list opens commonest first, which is the report's own order."
  (heisig-gt-test-with-db
    (should (equal (mapcar (lambda (w) (plist-get w :root))
                           (heisig-gt-db-vocab-list))
                   '("だ" "言う" "目" "目的" "為る" "私" "川" "目指す")))))

(ert-deftest heisig-gt-words-test-spellings-are-merged ()
  "One word counted under two spellings becomes one row.
言う is recorded separately as 言う and いう; ranking it by
either alone would understate how often it is actually said."
  (heisig-gt-test-with-db
    (let ((rows (seq-filter (lambda (w) (equal (plist-get w :root) "言う"))
                            (heisig-gt-db-vocab-list))))
      (should (= (length rows) 1))
      (should (= (plist-get (car rows) :count) 700000)))))

(ert-deftest heisig-gt-words-test-unidic-disambiguator-is-stripped ()
  "A lemma written 私-代名詞 resolves to the headword 私."
  (heisig-gt-test-with-db
    (let ((word (seq-find (lambda (w) (equal (plist-get w :root) "私"))
                          (heisig-gt-db-vocab-list))))
      (should word)
      (should (equal (plist-get word :lemma) "私"))
      (should (equal (plist-get word :definition) "I, me")))))

(ert-deftest heisig-gt-words-test-non-words-are-dropped ()
  "An entry matching no dictionary headword does not become a word.
A fifth of the frequency report is stray katakana, initialisms
and names the tokeniser kept; エポ stands for all of them."
  (heisig-gt-test-with-db
    (should-not (seq-find (lambda (w) (equal (plist-get w :root) "エポ"))
                          (heisig-gt-db-vocab-list)))))

(ert-deftest heisig-gt-words-test-emacsql-quotes-are-stripped ()
  "The dictionary wraps every value in literal double quotes.
A builder that left them would store the headword as \"\\\"目\\\"\"
and match nothing."
  (heisig-gt-test-with-db
    (let ((word (seq-find (lambda (w) (equal (plist-get w :root) "目"))
                          (heisig-gt-db-vocab-list))))
      (should (equal (plist-get word :pos) "n"))
      (should (equal (plist-get word :definition) "eye, eyeball")))))

(ert-deftest heisig-gt-words-test-senses-follow-the-reading ()
  "A headword's senses are chosen by the reading the corpus heard.
目 is both `me' and `moku'; the corpus recorded `me', so the
counter sense is not what the row shows."
  (heisig-gt-test-with-db
    (let ((word (seq-find (lambda (w) (equal (plist-get w :root) "目"))
                          (heisig-gt-db-vocab-list))))
      (should (equal (plist-get word :reading) "め"))
      (should-not (string-match-p "counter" (plist-get word :definition))))))

(ert-deftest heisig-gt-words-test-reading-is-kana-not-orthography ()
  "The reading comes from the pronunciation field, not the spelling.
為る is written する on screen and pronounced スル; the two are
adjacent columns in the report and easy to confuse."
  (heisig-gt-test-with-db
    (let ((word (seq-find (lambda (w) (equal (plist-get w :root) "為る"))
                          (heisig-gt-db-vocab-list))))
      (should (equal (plist-get word :surface) "する"))
      (should (equal (plist-get word :reading) "する"))
      (should (equal (plist-get word :romaji) "suru")))
    (let ((word (seq-find (lambda (w) (equal (plist-get w :root) "目的"))
                          (heisig-gt-db-vocab-list))))
      (should (equal (plist-get word :reading) "もくてき"))
      (should (equal (plist-get word :romaji) "mokuteki")))))

(ert-deftest heisig-gt-words-test-jlpt-takes-the-easiest-list ()
  "The vocabulary lists are cumulative, so the highest N wins."
  (heisig-gt-test-with-db
    (let ((by-root (lambda (root)
                     (plist-get (seq-find
                                 (lambda (w)
                                   (equal (plist-get w :root) root))
                                 (heisig-gt-db-vocab-list))
                                :jlpt))))
      ;; 目 is in both lists; N5 is the easier one.
      (should (equal (funcall by-root "目") 5))
      (should (equal (funcall by-root "目的") 4))
      ;; Above N3 there is no list, so no level rather than a guess.
      (should (null (funcall by-root "目指す"))))))

(ert-deftest heisig-gt-words-test-coverage-is-of-the-whole-corpus ()
  "Cumulative coverage counts the dropped entries against the total.
Otherwise the last word would always read 100%, which would say
the imported words cover everything said."
  (heisig-gt-test-with-db
    (let ((last (car (last (heisig-gt-db-vocab-list)))))
      (should (< (plist-get last :cum-pct) 100)))))

;;;; Seeding and the cut-off

(ert-deftest heisig-gt-words-test-seed-selects-by-kanji ()
  "A seed loads the words written with any one of its characters."
  (heisig-gt-words-test-with-buffer '("目")
    (should (equal (heisig-gt-words-test-roots)
                   '("目" "目的" "目指す")))))

(ert-deftest heisig-gt-words-test-seed-and-filter-agree ()
  "The seed and the by-kanji filter must answer the same question.

They are different implementations of one concept -- the seed is
an indexed SQL join over `vocab_char\', the filter a string
search over a record field -- and nothing textual links them, so
the invariant is asserted here over every character the fixture
holds rather than left to inspection.

It did not hold once: the index carried only Han characters while
the filter searched the whole headword, so seeding with メ
returned nothing where filtering on it returned 107 words."
  (heisig-gt-test-with-db
    (let* ((all (heisig-gt-db-vocab-list))
           (chars (seq-uniq
                   (seq-mapcat (lambda (word)
                                 (string-to-list (plist-get word :chars)))
                               all)))
           (predicate (plist-get (alist-get 'by-kanji
                                            heisig-gt-words-filter-alist)
                                 :predicate)))
      (should (> (length chars) 5))
      (dolist (ch chars)
        (let* ((char (char-to-string ch))
               (ranks (lambda (words)
                        (mapcar (lambda (w) (plist-get w :rank)) words)))
               (via-seed (funcall ranks
                                  (heisig-gt-db-vocab-list (list char))))
               (via-filter (funcall ranks
                                    (seq-filter
                                     (lambda (w) (funcall predicate w char))
                                     all))))
          (should (equal via-seed via-filter))
          ;; Neither may be vacuously empty: a character taken from a
          ;; word must select at least that word.
          (should via-seed))))))

(ert-deftest heisig-gt-words-test-seed-accepts-kana ()
  "A kana character is a legitimate seed, not an empty answer."
  (heisig-gt-words-test-with-buffer '("う")
    (should (equal (heisig-gt-words-test-roots) '("言う"))))
  (heisig-gt-words-test-with-buffer '("る")
    (should (equal (heisig-gt-words-test-roots) '("為る")))))

(ert-deftest heisig-gt-words-test-chars-is-the-headword ()
  "A record carries the characters its headword is written with."
  (heisig-gt-test-with-db
    (let ((word (seq-find (lambda (w) (equal (plist-get w :root) "目指す"))
                          (heisig-gt-db-vocab-list))))
      (should (equal (plist-get word :chars) "目指す")))))

(ert-deftest heisig-gt-words-test-seed-widens ()
  "Several seed characters ask for the words using any of them."
  (heisig-gt-words-test-with-buffer '("目" "川")
    (should (equal (heisig-gt-words-test-roots)
                   '("目" "目的" "川" "目指す")))))

(ert-deftest heisig-gt-words-test-no-seed-loads-everything ()
  "An empty seed is the whole list, up to the cut-off."
  (heisig-gt-words-test-with-buffer nil
    (should (= heisig-gt-kanji--total 8))))

(ert-deftest heisig-gt-words-test-max-rank-limits-the-load ()
  "The cut-off is applied when loading, not when drawing."
  (heisig-gt-test-with-db
    (let ((heisig-gt-words-max-rank 3))
      (should (= 3 (length (heisig-gt-db-vocab-list
                            nil heisig-gt-words-max-rank)))))))

(ert-deftest heisig-gt-words-test-scope-is-named-in-the-mode-line ()
  "The mode line says what was loaded before saying what was filtered."
  (heisig-gt-words-test-with-buffer '("目")
    (should (string-match-p "\\[目\\]" (heisig-gt-kanji--mode-line))))
  (heisig-gt-words-test-with-buffer nil
    (should (string-match-p "top" (heisig-gt-kanji--mode-line)))))

;;;; Narrowing

(ert-deftest heisig-gt-words-test-narrow-by-further-kanji ()
  "Adding a kanji narrows: the word must use that one as well."
  (heisig-gt-words-test-with-buffer '("目")
    (should (= 1 (heisig-gt-words-test-apply 'by-kanji '("的"))))
    (should (equal (heisig-gt-words-test-roots) '("目的")))))

(ert-deftest heisig-gt-words-test-narrow-by-romaji ()
  "Pronunciation is searched in romaji, needing no input method."
  (heisig-gt-words-test-with-buffer nil
    (should (= 1 (heisig-gt-words-test-apply 'by-romaji '("mokuteki"))))
    (should (equal (heisig-gt-words-test-roots) '("目的")))
    ;; A regexp, so a fragment selects everything sharing it.
    (should (= 2 (heisig-gt-words-test-apply 'by-romaji '("^me"))))))

(ert-deftest heisig-gt-words-test-narrow-by-reading ()
  "The same search is available over the kana."
  (heisig-gt-words-test-with-buffer nil
    (should (= 1 (heisig-gt-words-test-apply 'by-reading '("もくてき"))))))

(ert-deftest heisig-gt-words-test-narrow-by-pos ()
  "A word is tagged with a set of parts of speech; any one matches."
  (heisig-gt-words-test-with-buffer nil
    (should (= 3 (heisig-gt-words-test-apply 'by-pos '("n"))))
    ;; `v5s vt' is one field holding two tags.
    (should (= 1 (heisig-gt-words-test-apply 'by-pos '("vt"))))))

(ert-deftest heisig-gt-words-test-narrow-by-jlpt ()
  "Levels widen among themselves, and `none' is what has no level."
  (heisig-gt-words-test-with-buffer nil
    (should (= 3 (heisig-gt-words-test-apply 'by-jlpt '(5))))
    (should (= 5 (heisig-gt-words-test-apply 'by-jlpt '(5 4))))
    (should (= 3 (heisig-gt-words-test-apply 'by-jlpt '(none))))))

(ert-deftest heisig-gt-words-test-narrow-by-rank-range ()
  "The rank filter takes the same ranges the kanji list does."
  (heisig-gt-words-test-with-buffer nil
    (should (= 3 (heisig-gt-words-test-apply 'by-rank '("1,3"))))
    (should (= 4 (heisig-gt-words-test-apply 'by-rank '("5,"))))))

(ert-deftest heisig-gt-words-test-filters-compose-with-the-seed ()
  "Seed, then narrow twice: each step is an AND over the last."
  (heisig-gt-words-test-with-buffer '("目")
    (setq heisig-gt-kanji--filters
          (list (list :key 'by-pos :values '("n") :negate nil)
                (list :key 'by-jlpt :values '(4) :negate nil)))
    (heisig-gt-kanji--redraw-preserving-point)
    (should (equal (heisig-gt-words-test-roots) '("目的")))))

;;;; Mode plumbing

(ert-deftest heisig-gt-words-test-has-its-own-registries ()
  "The mode supplies its own columns and filters, not the kanji ones."
  (heisig-gt-words-test-with-buffer nil
    (should (eq (heisig-gt-kanji--registry) heisig-gt-words-column-alist))
    (should (eq (heisig-gt-kanji--filters-registry)
                heisig-gt-words-filter-alist))
    ;; A kanji column is not a word column.
    (should-error (heisig-gt-kanji--column 'heisig) :type 'user-error)))

(ert-deftest heisig-gt-words-test-rows-are-found-by-rank ()
  "Records are rebuilt on every read, so rank is what point follows."
  (heisig-gt-words-test-with-buffer nil
    (goto-char (point-min))
    (forward-line 3)
    (let ((id (heisig-gt-kanji--id-at-point)))
      (should (equal id 4))
      (heisig-gt-kanji--revert)
      (should (equal (heisig-gt-kanji--id-at-point) id)))))

(ert-deftest heisig-gt-words-test-kanji-list-goes-to-the-row ()
  "`K' opens the kanji list with point on the chosen character."
  (heisig-gt-words-test-with-buffer '("川")
    (goto-char (point-min))
    (should (equal (plist-get (tabulated-list-get-id) :root) "川"))
    (unwind-protect
        (progn
          (heisig-gt-words-kanji-list)
          (with-current-buffer heisig-gt-kanji-buffer-name
            (should (derived-mode-p 'heisig-gt-kanji-mode))
            (should (equal (heisig-gt-kanji--id-at-point) "川"))))
      (when (get-buffer heisig-gt-kanji-buffer-name)
        (kill-buffer heisig-gt-kanji-buffer-name)))))

(ert-deftest heisig-gt-words-test-read-kanji-offers-only-known-ones ()
  "The choice is between the characters that have an entry.
A word can be written with a character the kanji database has
nothing to say about; offering it would be offering a dead end."
  (heisig-gt-words-test-with-buffer '("川")
    (goto-char (point-min))
    ;; 川 is the only kanji, and it is known: no prompt.
    (should (equal (heisig-gt-words--read-kanji "x") "川")))
  (heisig-gt-words-test-with-buffer '("目")
    (goto-char (point-min))
    (should-not (heisig-gt-db-known-p "目"))
    (should-error (heisig-gt-words--read-kanji "x") :type 'user-error)))

(ert-deftest heisig-gt-words-test-keys ()
  "`k' reaches the kanji, and `w' does not reach a broken command.
`w' opens the word list throughout the package; inherited into a
word buffer it would call a command that reads a kanji from the
row, and a word row has none."
  (heisig-gt-words-test-with-buffer nil
    (should (eq (keymap-lookup heisig-gt-words-mode-map "k")
                'heisig-gt-words-show-kanji))
    (should (eq (keymap-lookup heisig-gt-words-mode-map "K")
                'heisig-gt-words-kanji-list))
    (should (eq (keymap-lookup heisig-gt-words-mode-map "M-w")
                'heisig-gt-words-copy))
    (should (eq (keymap-lookup heisig-gt-words-mode-map "w") 'undefined))))

(ert-deftest heisig-gt-words-test-show-kanji-goes-to-the-detail ()
  "A word with one known kanji goes straight there, with no prompt."
  (heisig-gt-words-test-with-buffer '("川")
    (goto-char (point-min))
    (should (equal (plist-get (tabulated-list-get-id) :root) "川"))
    (unwind-protect
        (progn
          (heisig-gt-words-show-kanji)
          (with-current-buffer heisig-gt-detail-buffer-name
            (should (equal heisig-gt-detail--char "川"))))
      (when (get-buffer heisig-gt-detail-buffer-name)
        (kill-buffer heisig-gt-detail-buffer-name)))))

(ert-deftest heisig-gt-words-test-show-kanji-needs-a-known-kanji ()
  "A word written with no kanji the database has says so.
The two bodies of data do not cover the same characters: the
vocabulary is built from a subtitle corpus and the kanji from
Anki decks, so a word can be written with a character that has no
entry to show."
  (heisig-gt-words-test-with-buffer '("目")
    (goto-char (point-min))
    (should-not (heisig-gt-db-known-p "目"))
    (should-error (heisig-gt-words-show-kanji) :type 'user-error)))

(ert-deftest heisig-gt-words-test-bookmark-records-the-seed ()
  "A bookmarked word view remembers what it was seeded with."
  (heisig-gt-words-test-with-buffer '("目")
    (let ((record (heisig-gt-kanji--make-record)))
      (should (eq (alist-get 'handler record)
                  'heisig-gt-words-bookmark-jump))
      (should (equal (alist-get 'seed record) '("目"))))))

(ert-deftest heisig-gt-words-test-saved-views-are-per-mode ()
  "The kanji list and the word list do not overwrite each other."
  (heisig-gt-test-with-db
    (let ((heisig-gt-kanji--state nil))
      (setf (alist-get 'heisig-gt-kanji-mode heisig-gt-kanji--state)
            '(:columns (char)))
      (setf (alist-get 'heisig-gt-words-mode heisig-gt-kanji--state)
            '(:columns (root)))
      (should (equal (alist-get 'heisig-gt-kanji-mode heisig-gt-kanji--state)
                     '(:columns (char)))))))

(provide 'test-heisig-gt-words)

;;; test-heisig-gt-words.el ends here
