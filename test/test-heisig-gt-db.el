;;; test-heisig-gt-db.el --- Tests for heisig-gt-db  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The database layer, read against the generated fixtures.

;;; Code:

(require 'ert)
(require 'heisig-gt-db)
(require 'heisig-gt-kanji)
(require 'heisig-gt-words)
(require 'heisig-gt-test-helper)

;;;; Records

(ert-deftest heisig-gt-db-test-kanji-list-is-in-frame-order ()
  "The list opens in Heisig's order, with unnumbered entries last."
  (heisig-gt-test-with-db
    (let ((chars (mapcar (lambda (k) (plist-get k :char))
                         (heisig-gt-db-kanji-list))))
      (should (equal (seq-take chars 2) '("一" "肉")))
      ;; 川 and 森 have no frame; they follow the two that do.
      (should (equal (seq-drop chars 2) '("[apron]" "川" "森"))))))

(ert-deftest heisig-gt-db-test-record-fields ()
  "A record carries the merged value of every column."
  (heisig-gt-test-with-db
    (let ((one (heisig-gt-db-kanji "一")))
      (should (equal (plist-get one :kind) "kanji"))
      (should (equal (plist-get one :heisig6) 1))
      (should (equal (plist-get one :keyword) "one"))
      (should (equal (plist-get one :strokes) 1))
      (should (equal (plist-get one :jlpt) 5))
      (should (equal (plist-get one :meanings) "one"))
      (should (equal (plist-get one :sources) "migaku,academy,json")))))

(ert-deftest heisig-gt-db-test-user-keyword-wins ()
  "A keyword the user set outranks the one Heisig gave."
  (heisig-gt-test-with-db
    (let ((meat (heisig-gt-db-kanji "肉")))
      (should (equal (plist-get meat :keyword) "my meat"))
      (should (equal (plist-get meat :keyword-source) "usr"))
      ;; The keyword it displaced is still recorded.
      (should (equal (plist-get meat :heisig-keyword6) "meat")))))

(ert-deftest heisig-gt-db-test-frequency-sentinel-is-dropped ()
  "999999 means \"unranked\", not \"the rarest kanji there is\"."
  (heisig-gt-test-with-db
    (should (null (plist-get (heisig-gt-db-kanji "肉") :freq-rank)))
    (should (equal (plist-get (heisig-gt-db-kanji "一") :freq-rank) 2))))

(ert-deftest heisig-gt-db-test-json-only-entry ()
  "A kanji only the JSON source has still gets a row, marked as such."
  (heisig-gt-test-with-db
    (let ((forest (heisig-gt-db-kanji "森")))
      (should (equal (plist-get forest :sources) "json"))
      (should (equal (plist-get forest :keyword) "forest"))
      ;; Its stroke count is the empty string the source uses for
      ;; "unknown", and must not become a zero.
      (should (null (plist-get forest :strokes)))
      ;; Its JLPT level is the literal "0" that source uses for "no
      ;; level", for 114 kanji.  One column must not carry two
      ;; spellings of absent: it offered 0 at the by-jlpt prompt as
      ;; though it were a level, and forced the kanji list and the
      ;; word list to render the field with different code.
      (should (null (plist-get forest :jlpt))))))

(ert-deftest heisig-gt-db-test-jlpt-has-one-spelling-of-absent ()
  "No row records a JLPT level outside N5..N1."
  (heisig-gt-test-with-db
    (should-not (seq-find (lambda (kanji)
                            (let ((level (plist-get kanji :jlpt)))
                              (and level (not (memq level '(1 2 3 4 5))))))
                          (heisig-gt-db-kanji-list)))
    (should-not (seq-find (lambda (word)
                            (let ((level (plist-get word :jlpt)))
                              (and level (not (memq level '(1 2 3 4 5))))))
                          (heisig-gt-db-vocab-list)))))

(ert-deftest heisig-gt-db-test-jlpt-renders-the-same-everywhere ()
  "One rendering serves both lists, so they cannot disagree.
They did: one guarded against a level of 0 and the other did not."
  (should (equal (heisig-gt-db-jlpt-string 5) "N5"))
  (should (equal (heisig-gt-db-jlpt-string 1) "N1"))
  (should (equal (heisig-gt-db-jlpt-string nil) ""))
  (heisig-gt-test-with-db
    (let ((kanji (heisig-gt-db-kanji "一"))
          (word (seq-find (lambda (w) (equal (plist-get w :root) "だ"))
                          (heisig-gt-db-vocab-list))))
      (should (equal (plist-get kanji :jlpt) (plist-get word :jlpt)))
      (should (equal (heisig-gt-kanji--jlpt kanji)
                     (heisig-gt-words--jlpt word))))))

(ert-deftest heisig-gt-db-test-primitive-row ()
  "A Heisig primitive gets a row of its own, named by its keyword."
  (heisig-gt-test-with-db
    (let ((apron (heisig-gt-db-kanji "[apron]")))
      (should (equal (plist-get apron :kind) "primitive"))
      (should (equal (plist-get apron :keyword) "apron"))
      (should (null (plist-get apron :heisig6))))))

(ert-deftest heisig-gt-db-test-malformed-note-is-skipped ()
  "A note whose character is junk produces no row."
  (heisig-gt-test-with-db
    (should (null (heisig-gt-db-kanji "[")))))

;;;; Child tables

(ert-deftest heisig-gt-db-test-readings ()
  "Readings come back split by kind, in the order recorded."
  (heisig-gt-test-with-db
    (should (equal (heisig-gt-db-readings "一" "on") '("イチ")))
    (should (equal (heisig-gt-db-readings "一" "kun") '("ひと")))
    (should (equal (heisig-gt-db-readings "一" "nanori") '("かず")))
    (should (null (heisig-gt-db-readings "一" "nonesuch")))))

(ert-deftest heisig-gt-db-test-readings-romaji ()
  "Every reading is stored transliterated beside its kana."
  (heisig-gt-test-with-db
    (should (equal (heisig-gt-db-readings-romaji "一" "on") '("ichi")))
    (should (equal (heisig-gt-db-readings-romaji "一" "kun") '("hito")))
    (should (equal (heisig-gt-db-readings-romaji "一" "nanori") '("kazu")))
    (should (equal (heisig-gt-db-readings-romaji "川" "kun") '("kawa")))))

(ert-deftest heisig-gt-db-test-reading-matches-either-script ()
  "A reading is found by its kana or by its romaji."
  (heisig-gt-test-with-db
    (should (heisig-gt-db-reading-matches-p "一" "on" "イチ"))
    (should (heisig-gt-db-reading-matches-p "一" "on" "ichi"))
    (should-not (heisig-gt-db-reading-matches-p "一" "on" "hito"))
    ;; ...and only of the kind asked for.
    (should (heisig-gt-db-reading-matches-p "一" "kun" "hito"))
    (should-not (heisig-gt-db-reading-matches-p "一" "kun" "ichi"))))

(ert-deftest heisig-gt-db-test-all-readings-offers-both-scripts ()
  "The filter candidates carry each reading in both spellings."
  (heisig-gt-test-with-db
    (let ((on (heisig-gt-db-all-readings "on")))
      (should (member "イチ" on))
      (should (member "ichi" on))
      (should-not (member "ひと" on)))))

(ert-deftest heisig-gt-db-test-readings-fall-back-to-academy ()
  "With no Migaku note, the two Academy lines are kun then on."
  (heisig-gt-test-with-db
    (should (equal (heisig-gt-db-readings "川" "kun") '("かわ")))
    (should (equal (heisig-gt-db-readings "川" "on") '("セン")))))

(ert-deftest heisig-gt-db-test-components-prefer-academy ()
  "Academy is used for components because only it glosses them."
  (heisig-gt-test-with-db
    (should (equal (heisig-gt-db-components "一")
                   '(("一" "one" "one radical (no.1)"))))))

(ert-deftest heisig-gt-db-test-component-name-prefers-its-own ()
  "A component the Academy source glossed is named by that gloss."
  (heisig-gt-test-with-db
    (should (equal (heisig-gt-db-component-names "一") '("one")))))

(ert-deftest heisig-gt-db-test-component-name-falls-back-to-the-kanji ()
  "A component with no name of its own borrows its own keyword.
Only the Academy source glosses components, so a third of the
rows have nothing; most of those components are characters with
a row and a keyword of their own."
  (heisig-gt-test-with-db
    ;; 肉's component comes from Migaku, which records the bare
    ;; character; "apron" is the keyword on [apron]'s own row.
    (should (equal (heisig-gt-db-components "肉") '(("[apron]" nil nil))))
    (should (equal (heisig-gt-db-component-names "肉") '("apron")))))

(ert-deftest heisig-gt-db-test-component-name-falls-back-to-the-gloss ()
  "Failing both, the first clause of the gloss names the component."
  (heisig-gt-test-with-db
    ;; 森's component comes from the JSON source, which glosses but
    ;; does not keyword, and 木 has no row of its own here.
    (should (null (heisig-gt-db-keyword "木")))
    (should (equal (heisig-gt-db-component-names "森") '("tree")))))

(ert-deftest heisig-gt-db-test-component-name-takes-one-clause ()
  "A dictionary gloss lists every sense; only the first names it."
  (should (equal (heisig-gt-db--first-clause "of;this") "of"))
  (should (equal (heisig-gt-db--first-clause "gone, past, quit") "gone"))
  (should (equal (heisig-gt-db--first-clause "tree") "tree")))

(ert-deftest heisig-gt-db-test-stringified-null-is-not-a-name ()
  "A gloss that is the literal text \"None\" is a null, not a name.
Two of them are in kanji-all.json; left alone they name a
component \"None\" and offer it as a filter candidate."
  (heisig-gt-test-with-db
    ;; 森's second component carries that gloss and nothing else.
    (should (equal (heisig-gt-db-components "森")
                   '(("木" nil "tree") ("朩" nil nil))))
    (should (equal (heisig-gt-db-component-names "森") '("tree")))
    (should-not (member "None" (heisig-gt-db-all-component-names)))))

(ert-deftest heisig-gt-db-test-nameless-components-are-dropped ()
  "A component nothing names is left out, not left as a gap."
  (heisig-gt-test-with-db
    (should (null (heisig-gt-db-component-name '("鬱" nil nil))))))

(ert-deftest heisig-gt-db-test-used-in ()
  "The inverse of the component graph is recorded too."
  (heisig-gt-test-with-db
    (should (equal (heisig-gt-db-used-in "一") '("二" "三")))
    (should (equal (heisig-gt-db-used-in "[apron]") '("肉")))))

(ert-deftest heisig-gt-db-test-known-p ()
  "Only a character with a row of its own is known."
  (heisig-gt-test-with-db
    (should (heisig-gt-db-known-p "一"))
    (should (heisig-gt-db-known-p "[apron]"))
    ;; 二 is named by the graph but has no row: following it would
    ;; land nowhere, and the detail buffer has to be able to tell.
    (should-not (heisig-gt-db-known-p "二"))))

(ert-deftest heisig-gt-db-test-words-and-stories ()
  "Compounds and stories come back for the character that has them."
  (heisig-gt-test-with-db
    (should (member '("一番" "いちばん" nil nil) (heisig-gt-db-words "一")))
    (let ((story (car (heisig-gt-db-stories "一"))))
      (should (equal (nth 0 story) "koohii"))
      (should (equal (nth 1 story) "someone"))
      (should (equal (nth 2 story) 42))
      (should (equal (nth 4 story) "A single line.")))))

(ert-deftest heisig-gt-db-test-stroke-svg ()
  "The stroke diagram is stored, and fetched only when asked for."
  (heisig-gt-test-with-db
    (should (string-prefix-p "<svg" (heisig-gt-db-stroke-svg "一")))
    ;; It is deliberately not part of a list record: the SVGs are
    ;; megabytes and no row of the list shows one.
    (should-not (plist-member (heisig-gt-db-kanji "一") :stroke-svg))))

(ert-deftest heisig-gt-db-test-neighbour ()
  "Frame stepping crosses to the next numbered frame, and stops."
  (heisig-gt-test-with-db
    (should (equal (heisig-gt-db-neighbour 1 1) "肉"))
    (should (null (heisig-gt-db-neighbour 1 -1)))
    (should (equal (heisig-gt-db-neighbour 2013 -1) "一"))
    (should (null (heisig-gt-db-neighbour 2013 1)))))

(ert-deftest heisig-gt-db-test-meta ()
  "The builder records what it did in the meta table."
  (heisig-gt-test-with-db
    ;; Compared against the constant, not a literal: the two have to
    ;; agree, and that is the whole point of recording it.
    (should (equal (heisig-gt-db-meta "schema_version")
                   heisig-gt-db-schema-version))
    (should (equal (heisig-gt-db-meta "kanji") "4"))
    (should (null (heisig-gt-db-meta "nonesuch")))))

;;;; Study progress

(ert-deftest heisig-gt-db-test-study-statuses ()
  "Each Anki queue maps to the status that describes it."
  (heisig-gt-test-with-db
    (heisig-gt-db-reload-study)
    (should (null heisig-gt-db-study-unavailable))
    (should (eq (plist-get (heisig-gt-db-study "一") :status) 'review))
    (should (eq (plist-get (heisig-gt-db-study "肉") :status) 'new))
    (should (eq (plist-get (heisig-gt-db-study "川") :status) 'learning))
    (should (eq (plist-get (heisig-gt-db-study "[apron]") :status)
                'suspended))
    ;; 森 is in no deck at all.
    (should (null (heisig-gt-db-study "森")))))

(ert-deftest heisig-gt-db-test-study-keeps-the-furthest-card ()
  "A kanji with two cards is described by the one furthest along."
  (heisig-gt-test-with-db
    (heisig-gt-db-reload-study)
    ;; 一 has a 100-day review card and a 5-day one.
    (should (equal (plist-get (heisig-gt-db-study "一") :ivl) 100))))

(ert-deftest heisig-gt-db-test-study-due-date ()
  "A due date is computed only for a card in review."
  (heisig-gt-test-with-db
    (heisig-gt-db-reload-study)
    (should (equal (format-time-string
                    "%Y-%m-%d" (plist-get (heisig-gt-db-study "一") :due)
                    t)
                   ;; The fixture's collection was created on
                   ;; 2020-02-15 and the card is due on day 3000,
                   ;; which 2028's leap day puts on 3 May.
                   "2028-05-03"))
    ;; In every other queue `due' is a position or an epoch second,
    ;; neither of which is a date.
    (should (null (plist-get (heisig-gt-db-study "肉") :due)))
    (should (null (plist-get (heisig-gt-db-study "川") :due)))))

(ert-deftest heisig-gt-db-test-study-missing-collection-is-not-an-error ()
  "An unreadable collection empties the table and says why."
  (heisig-gt-test-with-db
    (let ((heisig-gt-anki-file "/nonexistent/collection.anki2"))
      (should (= 0 (hash-table-count (heisig-gt-db-reload-study))))
      (should heisig-gt-db-study-unavailable))))

(ert-deftest heisig-gt-db-test-study-no-collection-is-not-an-error ()
  "Configuring no collection at all is equally harmless."
  (heisig-gt-test-with-db
    (let ((heisig-gt-anki-file nil))
      (should (= 0 (hash-table-count (heisig-gt-db-reload-study))))
      (should heisig-gt-db-study-unavailable))))

(ert-deftest heisig-gt-db-test-study-garbage-collection-is-not-an-error ()
  "A file that is not a database is reported, not signalled."
  (heisig-gt-test-with-db
    (let ((heisig-gt-anki-file
           (make-temp-file "heisig-gt-test-garbage" nil ".anki2"
                           "not a database")))
      (unwind-protect
          (progn
            (should (= 0 (hash-table-count (heisig-gt-db-reload-study))))
            (should heisig-gt-db-study-unavailable))
        (delete-file heisig-gt-anki-file)))))

(ert-deftest heisig-gt-db-test-unknown-deck-yields-no-study-data ()
  "Naming a deck that is not there leaves the table empty."
  (heisig-gt-test-with-db
    (let ((heisig-gt-anki-decks '("jp::nonesuch")))
      (should (= 0 (hash-table-count (heisig-gt-db-reload-study))))
      ;; Nothing went wrong; there is simply nothing to show.
      (should (null heisig-gt-db-study-unavailable)))))

;;;; Missing database

(ert-deftest heisig-gt-db-test-stale-schema-names-the-fix ()
  "A database built before a column was added says to rebuild.
Without the check the first query for the new column would fail
in the middle of a redraw, reporting a missing column rather than
a database to rebuild."
  (heisig-gt-test-require-fixtures)
  (let ((stale (make-temp-file "heisig-gt-test-stale" nil ".db")))
    (unwind-protect
        (progn
          (copy-file heisig-gt-test-db stale t)
          (let ((db (sqlite-open stale)))
            (sqlite-execute
             db "UPDATE meta SET value = '0' WHERE key = 'schema_version'")
            (sqlite-close db))
          (let ((heisig-gt-db-file stale)
                (heisig-gt-db--connection nil)
                (heisig-gt-db--connection-file nil))
            (should-error (heisig-gt-db-kanji-list) :type 'user-error)))
      (delete-file stale))))

(ert-deftest heisig-gt-db-test-missing-database-names-the-fix ()
  "A missing database is a setup step, and says which one."
  (let ((heisig-gt-db-file "/nonexistent/heisig-gt.db")
        (heisig-gt-db--connection nil)
        (heisig-gt-db--connection-file nil))
    (should-error (heisig-gt-db-kanji-list) :type 'user-error)))

(provide 'test-heisig-gt-db)

;;; test-heisig-gt-db.el ends here
