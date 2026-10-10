;;; heisig-gt-db.el --- SQLite access for heisig-gt  -*- lexical-binding: t; -*-

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

;; Read access to the two databases heisig-gt uses.
;;
;; The first is its own: a read-only SQLite file built ahead of time by
;; tools/build-heisig-db.py.  One row per kanji in `kanji', with the
;; readings, components, compounds, definitions and stories in child
;; tables keyed on the character.  Nothing here writes to it.
;;
;; The second is the user's Anki collection, consulted for study
;; progress only.  It is copied before it is opened -- Anki holds a
;; write-ahead lock on the live file -- and a failure to read it is
;; never an error: the study columns simply have nothing to show.
;;
;; Both are read with the sqlite support built into Emacs since 29, so
;; the package has no package dependencies at all.

;;; Code:

(require 'seq)
(require 'sqlite)
(require 'subr-x)

;;;; Customization

(defcustom heisig-gt-db-file (locate-user-emacs-file "heisig-gt.db")
  "Database of kanji read by heisig-gt.
Build it with `make db' in the package directory; see the
commentary of `heisig-gt' for what goes into it.  This file is
only ever read."
  :type 'file
  :group 'heisig-gt)

(defcustom heisig-gt-anki-file
  (expand-file-name "~/Library/Application Support/Anki2/0/collection.anki2")
  "Anki collection consulted for study progress, or nil for none.
The file is copied before it is opened, so Anki may be running.
When it cannot be read, the study columns show nothing and the
rest of the package works unchanged."
  :type '(choice (const :tag "No study data" nil) file)
  :group 'heisig-gt)

(defcustom heisig-gt-anki-decks '("jp::kanjiMigaku" "jp::kanjiAcademy")
  "Anki decks whose cards carry the study progress of a kanji.
Subdecks of a named deck are included.  A card in a filtered deck
counts towards the deck it came from, not the filtered one."
  :type '(repeat string)
  :group 'heisig-gt)

;;;; Connection

(defconst heisig-gt-db-schema-version "5"
  "Schema `tools/build-heisig-db.py' writes and this file reads.
Bumped whenever a column is added, so a database built before the
change is reported as stale rather than failing later with an SQL
error about a column that is not there.")

(defvar heisig-gt-db--connection nil
  "Open handle on `heisig-gt-db-file', or nil when it is closed.")

(defvar heisig-gt-db--connection-file nil
  "File `heisig-gt-db--connection' was opened on.
Kept so that changing `heisig-gt-db-file' reopens rather than
silently keeping the old database.")

(defun heisig-gt-db--ensure-open ()
  "Return an open handle on `heisig-gt-db-file', opening it if needed.
Signals a `user-error' naming the command that builds the
database when the file is missing: that is a setup step the user
has yet to run, not a bug to report."
  (unless (and heisig-gt-db--connection
               (sqlitep heisig-gt-db--connection)
               (equal heisig-gt-db--connection-file heisig-gt-db-file))
    (unless (sqlite-available-p)
      (user-error "Heisig-gt: this Emacs was built without SQLite support"))
    (unless (file-readable-p heisig-gt-db-file)
      (user-error "Heisig-gt: no database at %s; build one with `make db'"
                  heisig-gt-db-file))
    (setq heisig-gt-db--connection (sqlite-open heisig-gt-db-file))
    (setq heisig-gt-db--connection-file heisig-gt-db-file)
    (heisig-gt-db--check-schema))
  heisig-gt-db--connection)

(defun heisig-gt-db--check-schema ()
  "Signal when the open database was built by an older builder.
Checked once, when the connection is made.  Without it the first
query for a column added since would fail deep inside a redraw,
reporting a missing column rather than a database to rebuild."
  (let ((found (caar (sqlite-select
                      heisig-gt-db--connection
                      "SELECT value FROM meta WHERE key = 'schema_version'"))))
    (unless (equal found heisig-gt-db-schema-version)
      (heisig-gt-db-close)
      (user-error
       "Heisig-gt: %s is schema %s, this Emacs needs %s; rebuild with `make db'"
       heisig-gt-db-file (or found "unknown")
       heisig-gt-db-schema-version))))

(defun heisig-gt-db-close ()
  "Close the kanji database and drop every cached query result.
The next query reopens it, so this is also how to pick up a
database rebuilt while Emacs was running."
  (interactive)
  (when (and heisig-gt-db--connection (sqlitep heisig-gt-db--connection))
    (sqlite-close heisig-gt-db--connection))
  (setq heisig-gt-db--connection nil)
  (setq heisig-gt-db--connection-file nil)
  (heisig-gt-db--clear-caches))

(defun heisig-gt-db-query (query &optional values)
  "Run QUERY against the kanji database and return its rows.
VALUES are bound to the placeholders in QUERY.  Each row is a
list of column values, with nil for SQL NULL."
  (sqlite-select (heisig-gt-db--ensure-open) query values))

;;;; Records
;;
;; A kanji is a plist rather than a struct: the column registry looks
;; its cells up by keyword, and a plist keeps that lookup and the
;; database column names spelled the same way.

(defconst heisig-gt-db-kanji-fields
  '(:char :kind :heisig5 :heisig6 :keyword :keyword-source
    :heisig-keyword5 :heisig-keyword6 :usr-keyword :strokes :grade
    :jlpt :kanken :wk :freq-rank :radical :meanings :definitions
    :top-reading :top-onyomi :top-kunyomi :story :comment :mnemonic
    :sources)
  "Fields of a kanji record, in the order the list query returns them.
`:stroke-svg' is deliberately absent: the SVGs total several
megabytes and only the detail buffer ever needs one, so it is
fetched on demand by `heisig-gt-db-stroke-svg'.")

(defconst heisig-gt-db--kanji-select
  (concat "SELECT char, kind, heisig5, heisig6, keyword, keyword_source,"
          " heisig_keyword5, heisig_keyword6, usr_keyword, strokes, grade,"
          " jlpt, kanken, wk, freq_rank, radical, meanings, definitions,"
          " top_reading, top_onyomi, top_kunyomi, story, comment, mnemonic,"
          " sources FROM kanji")
  "SELECT returning the columns named by `heisig-gt-db-kanji-fields'.")

(defun heisig-gt-db--row-to-kanji (row)
  "Return the kanji record for ROW, a row of `heisig-gt-db--kanji-select'."
  (apply #'append (seq-mapn #'list heisig-gt-db-kanji-fields row)))

(defun heisig-gt-db-kanji-list ()
  "Return every kanji in the database as a list of records.
Ordered by Heisig frame number, entries without one last, so the
buffer opens in the order the book teaches."
  (mapcar #'heisig-gt-db--row-to-kanji
          (heisig-gt-db-query
           (concat heisig-gt-db--kanji-select
                   " ORDER BY heisig6 IS NULL, heisig6, char"))))

(defun heisig-gt-db-kanji (char)
  "Return the record for CHAR, or nil when it is not in the database."
  (when-let* ((row (car (heisig-gt-db-query
                         (concat heisig-gt-db--kanji-select
                                 " WHERE char = ?")
                         (list char)))))
    (heisig-gt-db--row-to-kanji row)))

(defun heisig-gt-db-field (kanji field)
  "Return FIELD of the record KANJI."
  (plist-get kanji field))

;;;; Bulk tables
;;
;; The list buffer can show a column of components or readings, which
;; means every row needs them at once.  Asking per row would be ~2000
;; queries per redraw, so each of these reads its whole table in one
;; query and groups the result by character.  They are built on first
;; use and dropped by `heisig-gt-db-close'.

(defvar heisig-gt-db--readings-table nil
  "Cache for `heisig-gt-db-readings-table', or nil when unbuilt.")

(defvar heisig-gt-db--components-table nil
  "Cache for `heisig-gt-db-components-table', or nil when unbuilt.")

(defvar heisig-gt-db--used-in-table nil
  "Cache for `heisig-gt-db-used-in-table', or nil when unbuilt.")

(defvar heisig-gt-db--chars-table nil
  "Cache for `heisig-gt-db-known-p', or nil when unbuilt.")

(defvar heisig-gt-db--keyword-table nil
  "Cache for `heisig-gt-db-keyword', or nil when unbuilt.")

(defun heisig-gt-db--clear-caches ()
  "Drop every cached bulk table."
  (setq heisig-gt-db--readings-table nil)
  (setq heisig-gt-db--components-table nil)
  (setq heisig-gt-db--used-in-table nil)
  (setq heisig-gt-db--chars-table nil)
  (setq heisig-gt-db--keyword-table nil))

(defun heisig-gt-db--group-rows (rows)
  "Return a hash mapping the car of each row in ROWS to the cdrs.
Each value keeps the order the rows arrived in, which is the
order the database recorded."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (group (seq-group-by #'car rows))
      (puthash (car group) (mapcar #'cdr (cdr group)) table))
    table))

(defun heisig-gt-db-readings-table ()
  "Return a hash mapping a character to its (KIND VALUE ROMAJI) readings."
  (or heisig-gt-db--readings-table
      (setq heisig-gt-db--readings-table
            (heisig-gt-db--group-rows
             (heisig-gt-db-query
              (concat "SELECT char, kind, value, romaji"
                      " FROM reading ORDER BY char, ord"))))))

(defun heisig-gt-db-components-table ()
  "Return a hash mapping a character to its (COMP KEYWORD GLOSS) rows."
  (or heisig-gt-db--components-table
      (setq heisig-gt-db--components-table
            (heisig-gt-db--group-rows
             (heisig-gt-db-query
              (concat "SELECT char, comp_char, keyword, gloss"
                      " FROM component ORDER BY char, ord"))))))

(defun heisig-gt-db-used-in-table ()
  "Return a hash mapping a character to the characters it builds."
  (or heisig-gt-db--used-in-table
      (setq heisig-gt-db--used-in-table
            (heisig-gt-db--group-rows
             (heisig-gt-db-query
              (concat "SELECT char, comp_char"
                      " FROM component_of ORDER BY char, ord"))))))

(defun heisig-gt-db--readings-of-kind (char kind)
  "Return the (KIND VALUE ROMAJI) rows of CHAR whose kind is KIND."
  (seq-filter (lambda (row) (equal (car row) kind))
              (gethash char (heisig-gt-db-readings-table))))

(defun heisig-gt-db-readings (char kind)
  "Return the readings of CHAR of KIND, a string like \"on\" or \"kun\"."
  (mapcar #'cadr (heisig-gt-db--readings-of-kind char kind)))

(defun heisig-gt-db-readings-romaji (char kind)
  "Return the readings of CHAR of KIND, transliterated.

The romaji is stored beside the kana rather than derived here:
it is the same answer every time, and a list of 2000 kanji would
otherwise transliterate every reading on every redraw.  A
reading nothing could be made of is dropped, so the romaji and
the kana can differ in length."
  (delq nil (mapcar #'caddr (heisig-gt-db--readings-of-kind char kind))))

(defun heisig-gt-db-all-readings (kind)
  "Return every distinct reading of KIND, in both scripts, sorted.
Kana and romaji are offered together so a filter prompt accepts
whichever the reader has to hand -- typing \"kou\" needs no input
method, and is the reason the romaji is stored at all."
  (let ((kana nil)
        (romaji nil))
    (maphash (lambda (_char rows)
               (dolist (row rows)
                 (when (equal (car row) kind)
                   (push (cadr row) kana)
                   (when (caddr row) (push (caddr row) romaji)))))
             (heisig-gt-db-readings-table))
    (append (sort (delete-dups romaji) #'string-lessp)
            (sort (delete-dups kana) #'string-lessp))))

(defun heisig-gt-db-reading-romaji-matches-p (char kind regexp)
  "Return non-nil when a reading of KIND of CHAR matches REGEXP.
Matched against the transliteration rather than the kana, so a
fragment like \"shou\" selects every reading carrying it without
an input method and without having to name one in full."
  (seq-some (lambda (romaji) (string-match-p regexp romaji))
            (heisig-gt-db-readings-romaji char kind)))

(defun heisig-gt-db-reading-matches-p (char kind value)
  "Return non-nil when CHAR has a reading of KIND spelled VALUE.
VALUE may be kana or romaji; both are compared, so a filter does
not have to know which the reader typed."
  (seq-some (lambda (row)
              (or (equal value (cadr row)) (equal value (caddr row))))
            (heisig-gt-db--readings-of-kind char kind)))

(defun heisig-gt-db-components (char)
  "Return the (COMP KEYWORD GLOSS) rows recorded for CHAR."
  (gethash char (heisig-gt-db-components-table)))

(defun heisig-gt-db-used-in (char)
  "Return the characters CHAR is a component of."
  (mapcar #'car (gethash char (heisig-gt-db-used-in-table))))

(defun heisig-gt-db-keyword (char)
  "Return the keyword recorded for CHAR, or nil when it has none."
  (unless heisig-gt-db--keyword-table
    (setq heisig-gt-db--keyword-table (make-hash-table :test #'equal))
    (dolist (row (heisig-gt-db-query
                  "SELECT char, keyword FROM kanji WHERE keyword IS NOT NULL"))
      (puthash (car row) (cadr row) heisig-gt-db--keyword-table)))
  (gethash char heisig-gt-db--keyword-table))

(defun heisig-gt-db--first-clause (gloss)
  "Return the first clause of GLOSS.
A dictionary gloss lists every sense a character carries, which
is too much where a component wants naming; the first is the one
that names it."
  ;; Spelled as a string rather than with `rx': package-lint reads the
  ;; `any' inside an rx form as a call to the Emacs 31 function of that
  ;; name and fails the lint.
  (car (split-string gloss "[;,]" t "[ \t\n]+")))

(defun heisig-gt-db-component-name (row)
  "Return the English name of the component ROW, or nil.
ROW is one row of `heisig-gt-db-components'.

Only two thirds of the component rows carry a name of their own,
because only the Academy source glosses components at all.  For
the rest, the component is very often a character with a row and
a keyword of its own -- 丿 is a component of 乏 and a kanji
keyworded \"katana\" -- so its own keyword names it.  Failing
both, the first clause of whatever gloss was recorded does.

Between them these cover all but a couple of the rows; the
remainder have no English anywhere in any source and are nil."
  (or (cadr row)
      (heisig-gt-db-keyword (car row))
      (when-let* ((gloss (caddr row)))
        (heisig-gt-db--first-clause gloss))))

(defun heisig-gt-db-all-component-names ()
  "Return every distinct English component name, sorted.

Resolved through `heisig-gt-db-component-name' rather than read
out of the database, because two thirds of the names are not
stored: they are the keyword of the component's own row, or a
clause of its gloss.  Offering only what is stored would leave
most of the candidates out."
  (let ((names nil))
    (maphash (lambda (_char rows)
               (dolist (row rows)
                 (when-let* ((name (heisig-gt-db-component-name row)))
                   (push name names))))
             (heisig-gt-db-components-table))
    (sort (delete-dups names) #'string-lessp)))

(defun heisig-gt-db-component-names (char)
  "Return the English names of the components of CHAR.
A component nothing names is dropped rather than left as a gap,
so the names line up with each other and not with the
characters."
  (delq nil (mapcar #'heisig-gt-db-component-name
                    (heisig-gt-db-components char))))

;;;; Per-character detail
;;
;; Only the detail buffer needs these, one character at a time, so
;; they go straight to the database rather than through a bulk table.

(defun heisig-gt-db-words (char)
  "Return the (SURFACE READING DEFINITION FREQ) compounds of CHAR."
  (heisig-gt-db-query
   (concat "SELECT surface, reading, definition, freq"
           " FROM word WHERE char = ? ORDER BY ord")
   (list char)))

(defun heisig-gt-db-definitions (char)
  "Return the (TERM PRONUNCIATION POS DEFINITION FREQ STARS) rows of CHAR."
  (heisig-gt-db-query
   (concat "SELECT term, pronunciation, pos, definition, freq, stars"
           " FROM definition WHERE char = ? ORDER BY ord")
   (list char)))

(defun heisig-gt-db-stories (char)
  "Return the (SOURCE AUTHOR VOTES DATE TEXT) stories of CHAR."
  (heisig-gt-db-query
   (concat "SELECT source, author, votes, date, text"
           " FROM story WHERE char = ? ORDER BY ord")
   (list char)))

(defun heisig-gt-db-stroke-svg (char)
  "Return the stroke-order SVG of CHAR as a string, or nil."
  (caar (heisig-gt-db-query
         "SELECT stroke_svg FROM kanji WHERE char = ?" (list char))))

(defun heisig-gt-db-meta (key)
  "Return the value recorded under KEY when the database was built."
  (caar (heisig-gt-db-query "SELECT value FROM meta WHERE key = ?"
                            (list key))))

(defun heisig-gt-db-neighbour (heisig direction)
  "Return the character whose frame number is next to HEISIG.
DIRECTION is 1 for the following frame and -1 for the preceding
one.  Returns nil at either end, or when HEISIG is nil."
  (when heisig
    (caar (heisig-gt-db-query
           (if (> direction 0)
               (concat "SELECT char FROM kanji WHERE heisig6 > ?"
                       " ORDER BY heisig6 LIMIT 1")
             (concat "SELECT char FROM kanji WHERE heisig6 < ?"
                     " ORDER BY heisig6 DESC LIMIT 1"))
           (list heisig)))))

;;;; Vocabulary
;;
;; A second body of data, from two sources neither of which is Anki:
;; the word list and its order come from a frequency report over
;; Japanese Netflix subtitles, and the readings, parts of speech and
;; definitions from the dictionary yomikun-gt ships.
;;
;; Everything that resolved to a dictionary headword is imported --
;; some 52000 words -- rather than the common few thousand, because a
;; fifth of that report is not really vocabulary and where the junk
;; sits decides what any rank cut-off actually contains.  The cut-off
;; is therefore a setting, `heisig-gt-words-max-rank', applied here.

(defconst heisig-gt-db-vocab-fields
  '(:rank :netflix-rank :lemma :surface :root :reading :romaji :pos
    :unidic-pos :jlpt :definition :chars :count :pct :cum-pct)
  "Fields of a vocabulary record, in the order the query returns them.")

(defconst heisig-gt-db--vocab-select
  (concat "SELECT rank, netflix_rank, lemma, surface, root, reading,"
          " romaji, pos, unidic_pos, jlpt, definition, chars, count,"
          " pct, cum_pct FROM vocab")
  "SELECT returning the columns named by `heisig-gt-db-vocab-fields'.")

(defun heisig-gt-db--row-to-vocab (row)
  "Return the vocabulary record for ROW."
  (apply #'append (seq-mapn #'list heisig-gt-db-vocab-fields row)))

(defun heisig-gt-db-vocab-list (&optional chars limit)
  "Return the vocabulary as a list of records, commonest first.

CHARS narrows to the words written with any one of those
characters -- the seed of a word list -- and is matched through
an index rather than by scanning every headword.  LIMIT stops at
that rank.

The index and the `chars\' field of a record are built from the
same string by the same builder, so this and the by-kanji filter
cannot answer the same question differently.  They did once: the
index held only Han characters while the filter searched the
whole headword, so seeding with a kana character found nothing
that filtering on it found.

Widening within CHARS and narrowing across separate filters is
the same rule the rest of the package follows: a seed of several
kanji asks for the words that use any of them."
  (let* ((limit (or limit most-positive-fixnum))
         (query (concat heisig-gt-db--vocab-select " WHERE rank <= ?"
                        (when chars
                          (concat " AND rank IN (SELECT rank FROM vocab_char"
                                  " WHERE char IN ("
                                  (string-join
                                   (make-list (length chars) "?") ",")
                                  "))"))
                        " ORDER BY rank")))
    (mapcar #'heisig-gt-db--row-to-vocab
            (heisig-gt-db-query query (cons limit chars)))))

(defun heisig-gt-db-vocab-total ()
  "Return how many words are in the database, ignoring any cut-off."
  (or (caar (heisig-gt-db-query "SELECT COUNT(*) FROM vocab")) 0))

(defun heisig-gt-db-vocab-parts-of-speech ()
  "Return every distinct part of speech in the vocabulary, sorted."
  (sort (delq nil (mapcar #'car (heisig-gt-db-query
                                 "SELECT DISTINCT pos FROM vocab")))
        #'string-lessp))

;;;; Study progress
;;
;; Read from the Anki collection on every refresh rather than copied
;; into the kanji database at build time: progress changes daily, and a
;; column showing yesterday's interval would be worse than no column.

(defconst heisig-gt-db-anki-field-separator "\C-_"
  "Character Anki writes between the parts of a compound value.
It separates the fields of a note, and the components of a deck
name.")

(defvar heisig-gt-db--study-table nil
  "Cache for `heisig-gt-db-study-table', or nil when unbuilt.")

(defvar heisig-gt-db-study-unavailable nil
  "Why study progress could not be read, or nil when it could.
A string fit to show in the mode line.  Set by
`heisig-gt-db-reload-study'.")

(defun heisig-gt-db--anki-queue-status (queue)
  "Return the status symbol for Anki's QUEUE value.
Anki distinguishes day-learning and preview queues from ordinary
learning; for the purpose of a progress column they are the same
thing, and the two buried queues likewise."
  (cond ((null queue) nil)
        ((<= queue -2) 'buried)
        ((= queue -1) 'suspended)
        ((= queue 0) 'new)
        ((= queue 2) 'review)
        (t 'learning)))

(defun heisig-gt-db--anki-deck-ids (db)
  "Return the ids of `heisig-gt-anki-decks' and their subdecks in DB.
Deck names are matched in Lisp rather than in SQL: Anki declares
its name columns with a custom collation that Emacs cannot
register, and any query constraining a name may be planned onto
an index that needs it."
  (let ((sep heisig-gt-db-anki-field-separator)
        (rows (sqlite-select db "SELECT id, name FROM decks")))
    (seq-mapcat
     (lambda (deck)
       (let ((want (string-replace "::" sep deck)))
         (seq-keep (lambda (row)
                     (let ((name (cadr row)))
                       (and (or (equal name want)
                                (string-prefix-p (concat want sep) name))
                            (car row))))
                   rows)))
     heisig-gt-anki-decks)))

(defun heisig-gt-db--anki-read (file)
  "Return the study rows of every card in `heisig-gt-anki-decks' in FILE.
Each element is (CHAR STATUS IVL REPS LAPSES DUE), where DUE is an
Emacs time for a card in review and nil otherwise.

FILE is copied before it is opened: Anki keeps a write-ahead lock
on the live collection, and reading it in place can fail or
observe a torn state.  Only what the collection had at its last
checkpoint is visible, which for a closed or idle Anki is
everything."
  (let ((copy (make-temp-file "heisig-gt-anki" nil ".anki2"))
        (db nil))
    (unwind-protect
        (progn
          (copy-file file copy t)
          (setq db (sqlite-open copy))
          (let* ((dids (heisig-gt-db--anki-deck-ids db))
                 (crt (or (caar (sqlite-select db "SELECT crt FROM col")) 0)))
            (when dids
              (seq-keep
               (lambda (row)
                 (pcase-let ((`(,flds ,queue ,ivl ,reps ,lapses ,due) row))
                   (let ((char (car (split-string
                                     flds
                                     heisig-gt-db-anki-field-separator)))
                         (status (heisig-gt-db--anki-queue-status queue)))
                     (and char (not (string-empty-p char))
                          (list char status ivl reps lapses
                                ;; `due' counts days since the
                                ;; collection was created, but only for
                                ;; a card in review; in every other
                                ;; queue it is a position or an epoch
                                ;; second, neither of which is a date.
                                (when (eq status 'review)
                                  (time-convert
                                   (+ crt (* (or due 0) 86400)) t)))))))
               (sqlite-select
                db
                (concat "SELECT n.flds, c.queue, c.ivl, c.reps, c.lapses,"
                        " c.due FROM cards c JOIN notes n ON c.nid = n.id"
                        " WHERE COALESCE(NULLIF(c.odid, 0), c.did) IN ("
                        (string-join (make-list (length dids) "?") ",")
                        ")")
                dids)))))
      (when (and db (sqlitep db)) (sqlite-close db))
      (when (file-exists-p copy) (delete-file copy)))))

(defun heisig-gt-db-reload-study ()
  "Re-read study progress from the Anki collection.
Returns the table `heisig-gt-db-study-table' will hand out.  A
collection that is missing, unreadable, or not an Anki database
leaves the table empty and records why in
`heisig-gt-db-study-unavailable'; it is never an error, because
the rest of the buffer does not depend on it."
  (setq heisig-gt-db-study-unavailable nil)
  (setq heisig-gt-db--study-table (make-hash-table :test #'equal))
  (cond
   ((null heisig-gt-anki-file)
    (setq heisig-gt-db-study-unavailable "no Anki collection configured"))
   ((not (file-readable-p heisig-gt-anki-file))
    (setq heisig-gt-db-study-unavailable "Anki collection unreadable"))
   (t
    (condition-case err
        (dolist (row (heisig-gt-db--anki-read heisig-gt-anki-file))
          (pcase-let ((`(,char ,status ,ivl ,reps ,lapses ,due) row))
            ;; A kanji can carry more than one card; the one furthest
            ;; along is the one that describes how well it is known.
            (let ((old (gethash char heisig-gt-db--study-table)))
              (when (or (null old)
                        (> (or ivl 0) (or (plist-get old :ivl) 0)))
                (puthash char (list :status status :ivl ivl :reps reps
                                    :lapses lapses :due due)
                         heisig-gt-db--study-table)))))
      (error
       (setq heisig-gt-db-study-unavailable
             (format "Anki collection: %s" (error-message-string err)))))))
  heisig-gt-db--study-table)

(defun heisig-gt-db-study-table ()
  "Return the hash mapping a character to its study progress.
Built on first use; `heisig-gt-db-reload-study' rebuilds it."
  (or heisig-gt-db--study-table (heisig-gt-db-reload-study)))

(defun heisig-gt-db-study (char)
  "Return the study progress plist of CHAR, or nil when it has none."
  (gethash char (heisig-gt-db-study-table)))


(defun heisig-gt-db-known-p (char)
  "Return non-nil when CHAR has a row of its own in the database.
The component graph reaches characters outside it -- it records
what a kanji is built from, and what it builds, whether or not
those are in the decks the database was built from -- so anything
that offers to visit a character has to ask first."
  (unless heisig-gt-db--chars-table
    (setq heisig-gt-db--chars-table (make-hash-table :test #'equal))
    (dolist (row (heisig-gt-db-query "SELECT char FROM kanji"))
      (puthash (car row) t heisig-gt-db--chars-table)))
  (gethash char heisig-gt-db--chars-table))

;;;; Status appearance
;;
;; The status vocabulary is defined here, by
;; `heisig-gt-db--anki-queue-status', so how a status looks is defined
;; here too rather than separately in each buffer that shows one.

(defface heisig-gt-status-new
  '((t :inherit font-lock-comment-face))
  "Face for a kanji Anki has not started teaching."
  :group 'heisig-gt)

(defface heisig-gt-status-learning
  '((t :inherit font-lock-keyword-face))
  "Face for a kanji in Anki's learning queue."
  :group 'heisig-gt)

(defface heisig-gt-status-review
  '((t :inherit success))
  "Face for a kanji in Anki's review queue."
  :group 'heisig-gt)

(defface heisig-gt-status-suspended
  '((t :inherit shadow))
  "Face for a suspended kanji."
  :group 'heisig-gt)

(defface heisig-gt-status-buried
  '((t :inherit shadow))
  "Face for a buried kanji."
  :group 'heisig-gt)

(defun heisig-gt-db-jlpt-string (level)
  "Return LEVEL written as a JLPT level, or the empty string for none.

Shared by the kanji list and the word list rather than spelled
once in each: they differed once, one of them guarding against a
level of 0 and the other not, because the database recorded
\"no level\" as both NULL and 0.  The builder now stores only
NULL, so one rendering serves both."
  (if level (format "N%d" level) ""))

(defconst heisig-gt-db-statuses '(new learning review suspended buried)
  "Every status `heisig-gt-db--anki-queue-status' can return.")

(defun heisig-gt-db-status-face (status)
  "Return the face for STATUS, or nil when there is none."
  (pcase status
    ('new 'heisig-gt-status-new)
    ('learning 'heisig-gt-status-learning)
    ('review 'heisig-gt-status-review)
    ('suspended 'heisig-gt-status-suspended)
    ('buried 'heisig-gt-status-buried)))

(provide 'heisig-gt-db)

;;; heisig-gt-db.el ends here
