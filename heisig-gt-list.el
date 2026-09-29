;;; heisig-gt-list.el --- Read-only list buffer for kanji  -*- lexical-binding: t; -*-

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

;; `heisig-gt-list' shows one row per kanji in a `tabulated-list-mode'
;; buffer.  Which columns appear, and in what order, is one setting;
;; filters compose; the view can be bookmarked and persisted.
;;
;; Nothing in this mode writes anything: not to the kanji database,
;; not to the Anki collection, not to a file.

;;; Code:

;; `heisig-gt' is deliberately not required here: it requires this
;; file, and the dependency has to run in that direction so that
;; loading heisig-gt provides the list.  The `heisig-gt' customization
;; group this file adds options to is defined there, before the
;; require.
(require 'bookmark)
(require 'heisig-gt-db)
(require 'heisig-gt-detail)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)

;;;; Customization

(defcustom heisig-gt-list-buffer-name "*Kanji*"
  "Name of the buffer `heisig-gt-list' displays."
  :type 'string
  :group 'heisig-gt)

(defcustom heisig-gt-list-columns
  '(heisig char keyword strokes jlpt status
    onyomi onyomi-romaji kunyomi kunyomi-romaji meanings)
  "Columns displayed by `heisig-gt-list', in display order.
Each element is a key of `heisig-gt-list-column-alist'.  This one
setting chooses the columns and orders them, so showing, hiding
and reordering are the same operation.  Change it for a single
buffer with \\[heisig-gt-list-toggle-column] and
\\[heisig-gt-list-set-columns]."
  :type '(repeat symbol)
  :group 'heisig-gt)

(defcustom heisig-gt-list-column-widths nil
  "Display widths overriding those in `heisig-gt-list-column-alist'.
An alist of (KEY . WIDTH).  A key absent here keeps the width the
registry records for it."
  :type '(alist :key-type symbol :value-type integer)
  :group 'heisig-gt)

(defcustom heisig-gt-list-default-sort-key '("Frame" . nil)
  "Initial sort key of a `heisig-gt-list' buffer.
A cons of the column name and a flag that reverses the order, in
the shape `tabulated-list-sort-key' takes.  The default opens the
buffer in Heisig's own order."
  :type '(cons string boolean)
  :group 'heisig-gt)

(defcustom heisig-gt-list-date-format "%Y-%m-%d"
  "Format used for the Due column, as `format-time-string' takes it."
  :type 'string
  :group 'heisig-gt)

;;;; State persistence

(defcustom heisig-gt-list-persist-state nil
  "Whether the view survives between sessions.
When non-nil, the displayed columns, the active filters and the
sort key are written to `heisig-gt-list-state-file' as they
change, and restored the next time a list buffer is created."
  :type 'boolean
  :group 'heisig-gt)

(defcustom heisig-gt-list-state-file
  (locate-user-emacs-file "heisig-gt-list-state.el")
  "File holding the view saved when `heisig-gt-list-persist-state'."
  :type 'file
  :group 'heisig-gt)

(defvar heisig-gt-list--state nil
  "View read from `heisig-gt-list-state-file', as a plist.")

(defvar heisig-gt-list--state-loaded nil
  "Whether the state file has been read in this session.")

;;;; Filter registry

(defvar heisig-gt-list-filter-alist nil
  "Filters offered by \\[heisig-gt-list-filter-by].

Each entry is (KEY :name STRING :reader FN :predicate FN :doc
STRING).  The :reader takes no arguments and returns a LIST of
values, even when it read only one.  The :predicate is called
with one kanji record and one of those values.

A kanji is kept when EVERY active filter matches it, and one
filter matches when ANY of its values does -- so values within a
filter widen the selection and separate filters narrow it.")

;;;; Buffer-local state

(defvar-local heisig-gt-list--kanji nil
  "Every kanji record, as read from the database at the last revert.
Filtering, sorting and column changes all redraw from this cache,
so only \\[revert-buffer] pays for a table scan.")

(defvar-local heisig-gt-list--filters nil
  "Filters in force in this buffer.
A list of (:key KEY :values LIST :negate BOOL) plists.  The same
key may appear more than once, each occurrence narrowing
further.")

(defvar-local heisig-gt-list--shown 0
  "Rows the active filters left, as of the last redraw.")

(defvar-local heisig-gt-list--total 0
  "Rows before filtering, as of the last redraw.")

(defvar-local heisig-gt-list--columns nil
  "Columns displayed in this buffer, in display order.")

;;;; Mode parameters
;;
;; Everything below this point -- rendering, filtering, sorting, the
;; mode line, the column commands, bookmarks, state -- knows nothing
;; about kanji.  A mode derived from `heisig-gt-list-mode' supplies
;; its own registries, its own way of loading records and of naming
;; one, and inherits the rest unchanged.  `heisig-gt-words-mode' is
;; the second such mode.

(defvar-local heisig-gt-list--column-registry nil
  "Column registry of this buffer.
Defaults to `heisig-gt-list-column-alist' when nil.")

(defvar-local heisig-gt-list--filter-registry nil
  "Filter registry of this buffer.
Defaults to `heisig-gt-list-filter-alist' when nil.")

(defvar-local heisig-gt-list--reload-function nil
  "Function of no arguments returning this buffer's records.")

(defvar-local heisig-gt-list--id-function nil
  "Function returning the identity string of one record.
A record is rebuilt on every read, so no object identity survives
a redraw; this is what point is re-found by.")

(defvar-local heisig-gt-list--default-columns nil
  "Columns this buffer returns to when the view is reset.")

(defvar-local heisig-gt-list--default-sort-key nil
  "Sort key this buffer returns to when the view is reset.")

(defvar-local heisig-gt-list--bookmark-handler nil
  "Function restoring a bookmarked view of this buffer's mode.")

(defvar-local heisig-gt-list--scope-function nil
  "Function returning a description of what this buffer is showing.
Filters narrow what was loaded; a scope is what was loaded at
all, and the mode line names it first so a buffer that was seeded
does not read as the whole table.")

;; Declared ahead of the accessors below, which are defined before the
;; registries themselves so that the mode parameters read as one block.
(defvar heisig-gt-list-column-alist)
(defvar heisig-gt-list-filter-alist)

(defun heisig-gt-list--registry ()
  "Return the column registry in force in this buffer."
  (or heisig-gt-list--column-registry heisig-gt-list-column-alist))

(defun heisig-gt-list--filters-registry ()
  "Return the filter registry in force in this buffer."
  (or heisig-gt-list--filter-registry heisig-gt-list-filter-alist))

(defun heisig-gt-list--sort-key-default ()
  "Return the sort key this buffer falls back to."
  (or heisig-gt-list--default-sort-key heisig-gt-list-default-sort-key))

(defun heisig-gt-list--columns-default ()
  "Return the columns this buffer falls back to."
  (or heisig-gt-list--default-columns heisig-gt-list-columns))

;;;; Column value functions
;;
;; One function per column, each taking a kanji record and returning
;; the cell's text.  A column with nothing to show returns the empty
;; string rather than "-": a table of dashes is harder to read past
;; than a table of gaps.

(defun heisig-gt-list--text (value)
  "Return VALUE as cell text, or the empty string when it is nil."
  (if value (format "%s" value) ""))

(defun heisig-gt-list--char (kanji)
  "Return the character of KANJI."
  (heisig-gt-list--text (plist-get kanji :char)))

(defun heisig-gt-list--heisig (kanji)
  "Return the Heisig frame number of KANJI."
  (heisig-gt-list--text (plist-get kanji :heisig6)))

(defun heisig-gt-list--keyword (kanji)
  "Return the keyword of KANJI."
  (heisig-gt-list--text (plist-get kanji :keyword)))

(defun heisig-gt-list--kind (kanji)
  "Return whether KANJI is a kanji or a Heisig primitive."
  (heisig-gt-list--text (plist-get kanji :kind)))

(defun heisig-gt-list--strokes (kanji)
  "Return the stroke count of KANJI."
  (heisig-gt-list--text (plist-get kanji :strokes)))

(defun heisig-gt-list--radical (kanji)
  "Return the radical of KANJI."
  (heisig-gt-list--text (plist-get kanji :radical)))

(defun heisig-gt-list--jlpt (kanji)
  "Return the JLPT level of KANJI, written as N5 through N1."
  (let ((level (plist-get kanji :jlpt)))
    (if (and level (> level 0)) (format "N%d" level) "")))

(defun heisig-gt-list--grade (kanji)
  "Return the school grade KANJI is taught in."
  (heisig-gt-list--text (plist-get kanji :grade)))

(defun heisig-gt-list--kanken (kanji)
  "Return the Kanji Kentei level of KANJI."
  (heisig-gt-list--text (plist-get kanji :kanken)))

(defun heisig-gt-list--wk (kanji)
  "Return the WaniKani level of KANJI."
  (heisig-gt-list--text (plist-get kanji :wk)))

(defun heisig-gt-list--freq (kanji)
  "Return the newspaper frequency rank of KANJI."
  (heisig-gt-list--text (plist-get kanji :freq-rank)))

(defun heisig-gt-list--meanings (kanji)
  "Return the English meanings of KANJI."
  (heisig-gt-list--text (plist-get kanji :meanings)))

(defun heisig-gt-list--sources (kanji)
  "Return the sources KANJI's data was merged from."
  (heisig-gt-list--text (plist-get kanji :sources)))

(defun heisig-gt-list--components (kanji)
  "Return the components of KANJI, run together as they are written."
  (mapconcat #'car (heisig-gt-db-components (plist-get kanji :char)) ""))

(defun heisig-gt-list--component-keywords (kanji)
  "Return the English names of the components of KANJI."
  (string-join (heisig-gt-db-component-names (plist-get kanji :char)) ", "))

(defun heisig-gt-list--onyomi (kanji)
  "Return the on readings of KANJI."
  (string-join (heisig-gt-db-readings (plist-get kanji :char) "on") "、"))

(defun heisig-gt-list--kunyomi (kanji)
  "Return the kun readings of KANJI."
  (string-join (heisig-gt-db-readings (plist-get kanji :char) "kun") "、"))

(defun heisig-gt-list--onyomi-romaji (kanji)
  "Return the on readings of KANJI, transliterated."
  (string-join (heisig-gt-db-readings-romaji (plist-get kanji :char) "on")
               ", "))

(defun heisig-gt-list--kunyomi-romaji (kanji)
  "Return the kun readings of KANJI, transliterated."
  (string-join (heisig-gt-db-readings-romaji (plist-get kanji :char) "kun")
               ", "))

(defun heisig-gt-list-status (kanji)
  "Return the Anki status symbol of KANJI, or nil when it has none."
  (plist-get (heisig-gt-db-study (plist-get kanji :char)) :status))

(defun heisig-gt-list--status (kanji)
  "Return the Anki status of KANJI, coloured by what it is."
  (let ((status (heisig-gt-list-status kanji)))
    (if status
        (propertize (symbol-name status)
                    'face (heisig-gt-db-status-face status))
      "")))

(defun heisig-gt-list--study (kanji field)
  "Return FIELD of the Anki study record of KANJI."
  (plist-get (heisig-gt-db-study (plist-get kanji :char)) field))

(defun heisig-gt-list--ivl (kanji)
  "Return the current review interval of KANJI, in days."
  (let ((ivl (heisig-gt-list--study kanji :ivl)))
    ;; A negative interval is Anki's way of recording seconds for a
    ;; card still in learning; it is not a number of days and showing
    ;; it as one would be a lie.
    (if (and ivl (> ivl 0)) (number-to-string ivl) "")))

(defun heisig-gt-list--reps (kanji)
  "Return how many times KANJI has been reviewed."
  (heisig-gt-list--text (heisig-gt-list--study kanji :reps)))

(defun heisig-gt-list--lapses (kanji)
  "Return how many times KANJI has been forgotten."
  (heisig-gt-list--text (heisig-gt-list--study kanji :lapses)))

(defun heisig-gt-list--due (kanji)
  "Return the date KANJI is next due for review."
  (let ((due (heisig-gt-list--study kanji :due)))
    (if due (format-time-string heisig-gt-list-date-format due) "")))

;;;; Comparators
;;
;; A column whose :sort is t is sorted by tabulated-list on the text
;; it displays, which is the right order for every column whose text
;; sorts the way its value does -- the dates included, being written
;; largest unit first.  The comparators below cover the columns where
;; that does not hold: numbers rendered as strings, where "10" would
;; otherwise precede "9", and the keyword, where case would separate
;; "Zebra" from "apple".

(defun heisig-gt-list--compare-keyword (a b)
  "Return non-nil when entry A's keyword precedes entry B's.
Comparison ignores case."
  (string-lessp (downcase (heisig-gt-list--keyword (car a)))
                (downcase (heisig-gt-list--keyword (car b)))))

(defun heisig-gt-list--number-compare (field)
  "Return a comparator ordering entries by the numeric FIELD.
A record with no value for FIELD sorts after every record that
has one, so the unknowns collect at one end instead of being
mixed in as zeroes.  Ties fall back to the keyword, so the order
is stable."
  (lambda (a b)
    (let ((x (plist-get (car a) field))
          (y (plist-get (car b) field)))
      (cond ((and (null x) (null y)) (heisig-gt-list--compare-keyword a b))
            ((null x) nil)
            ((null y) t)
            ((= x y) (heisig-gt-list--compare-keyword a b))
            (t (< x y))))))

(defun heisig-gt-list--study-compare (field)
  "Return a comparator ordering entries by the study FIELD.
Like `heisig-gt-list--number-compare', but reading the value out
of the Anki study record instead of the kanji record."
  (lambda (a b)
    (let ((x (heisig-gt-list--study (car a) field))
          (y (heisig-gt-list--study (car b) field)))
      (cond ((and (null x) (null y)) (heisig-gt-list--compare-keyword a b))
            ((null x) nil)
            ((null y) t)
            ((= x y) (heisig-gt-list--compare-keyword a b))
            (t (< x y))))))

;;;; Column registry

(defvar heisig-gt-list-column-alist
  (list
   (cons 'heisig     (list :name "Frame" :width 5
                           :value #'heisig-gt-list--heisig
                           :face 'font-lock-constant-face
                           :sort (heisig-gt-list--number-compare :heisig6)
                           :doc "Heisig frame number, sixth edition."))
   (cons 'char       (list :name "Kanji" :width 5
                           :value #'heisig-gt-list--char
                           :face nil :sort t
                           :doc "The character itself."))
   (cons 'keyword    (list :name "Keyword" :width 22
                           :value #'heisig-gt-list--keyword
                           :face 'font-lock-function-name-face
                           :sort #'heisig-gt-list--compare-keyword
                           :doc "Heisig keyword, or your own where you set \
one."))
   (cons 'kind       (list :name "Kind" :width 9
                           :value #'heisig-gt-list--kind
                           :face nil :sort t
                           :doc "Whether the row is a kanji or a Heisig \
primitive."))
   (cons 'strokes    (list :name "Str" :width 3
                           :value #'heisig-gt-list--strokes
                           :face nil
                           :sort (heisig-gt-list--number-compare :strokes)
                           :doc "Number of strokes."))
   (cons 'radical    (list :name "Rad" :width 3
                           :value #'heisig-gt-list--radical
                           :face nil :sort t
                           :doc "Classical radical."))
   (cons 'components (list :name "Components" :width 12
                           :value #'heisig-gt-list--components
                           :face nil :sort t
                           :doc "Components the character is built from."))
   (cons 'component-keywords
                     (list :name "Comp keywords" :width 30
                           :value #'heisig-gt-list--component-keywords
                           :face 'font-lock-doc-face :sort t
                           :doc "English names of the components, in the \
order they are written."))
   (cons 'onyomi     (list :name "On" :width 14
                           :value #'heisig-gt-list--onyomi
                           :face 'font-lock-string-face :sort t
                           :doc "On readings."))
   (cons 'onyomi-romaji
                     (list :name "On (romaji)" :width 16
                           :value #'heisig-gt-list--onyomi-romaji
                           :face 'font-lock-string-face :sort t
                           :doc "On readings, transliterated."))
   (cons 'kunyomi    (list :name "Kun" :width 14
                           :value #'heisig-gt-list--kunyomi
                           :face 'font-lock-string-face :sort t
                           :doc "Kun readings."))
   (cons 'kunyomi-romaji
                     (list :name "Kun (romaji)" :width 18
                           :value #'heisig-gt-list--kunyomi-romaji
                           :face 'font-lock-string-face :sort t
                           :doc "Kun readings, transliterated."))
   (cons 'jlpt       (list :name "JLPT" :width 4
                           :value #'heisig-gt-list--jlpt
                           :face nil
                           :sort (heisig-gt-list--number-compare :jlpt)
                           :doc "JLPT level, N5 (easiest) through N1."))
   (cons 'grade      (list :name "Grade" :width 5
                           :value #'heisig-gt-list--grade
                           :face nil
                           :sort (heisig-gt-list--number-compare :grade)
                           :doc "School grade the character is taught in."))
   (cons 'kanken     (list :name "Kanken" :width 6
                           :value #'heisig-gt-list--kanken
                           :face nil
                           :sort (heisig-gt-list--number-compare :kanken)
                           :doc "Kanji Kentei level."))
   (cons 'wk         (list :name "WK" :width 3
                           :value #'heisig-gt-list--wk
                           :face nil
                           :sort (heisig-gt-list--number-compare :wk)
                           :doc "WaniKani level."))
   (cons 'freq       (list :name "Freq" :width 5
                           :value #'heisig-gt-list--freq
                           :face nil
                           :sort (heisig-gt-list--number-compare :freq-rank)
                           :doc "Frequency rank in newspapers; 1 is the \
commonest."))
   (cons 'status     (list :name "Status" :width 9
                           :value #'heisig-gt-list--status
                           :face nil :sort t
                           :doc "Which Anki queue the character is in."))
   (cons 'ivl        (list :name "Ivl" :width 5
                           :value #'heisig-gt-list--ivl
                           :face nil
                           :sort (heisig-gt-list--study-compare :ivl)
                           :doc "Current review interval, in days."))
   (cons 'reps       (list :name "Reps" :width 4
                           :value #'heisig-gt-list--reps
                           :face nil
                           :sort (heisig-gt-list--study-compare :reps)
                           :doc "Times the character has been reviewed."))
   (cons 'lapses     (list :name "Laps" :width 4
                           :value #'heisig-gt-list--lapses
                           :face nil
                           :sort (heisig-gt-list--study-compare :lapses)
                           :doc "Times the character has been forgotten."))
   (cons 'due        (list :name "Due" :width 10
                           :value #'heisig-gt-list--due
                           :face 'font-lock-comment-face :sort t
                           :doc "Date the character is next due for review."))
   (cons 'sources    (list :name "Sources" :width 20
                           :value #'heisig-gt-list--sources
                           :face 'font-lock-comment-face :sort t
                           :doc "Which sources the row's data was merged \
from."))
   (cons 'meanings   (list :name "Meanings" :width 45
                           :value #'heisig-gt-list--meanings
                           :face nil :sort t
                           :doc "English meanings.")))
  "Column registry for the kanji list buffer.

Registry order is the order a column returns to when it is shown
again, so `meanings' is last: turning any other column on places
it before rather than after the widest column in the table.

Each entry is (KEY :name STRING :width INTEGER :value FN :face
FACE :sort SORT :doc STRING).  The :value function is called with
one kanji record and returns the cell's display string.  :face is
applied to the cell, or nil for no face.  :sort is nil for a
column that cannot be sorted, t to sort by the displayed string,
or a function called with two elements of
`tabulated-list-entries'.

`heisig-gt-list-columns' selects which of these are displayed and
in what order.")

(defun heisig-gt-list--column (key)
  "Return the registry entry for column KEY, signalling when unknown."
  (or (alist-get key (heisig-gt-list--registry))
      (user-error "Unknown column: %s" key)))

(defun heisig-gt-list--column-keys ()
  "Return every column key, in registry order."
  (mapcar #'car (heisig-gt-list--registry)))

(defun heisig-gt-list--column-width (key)
  "Return the display width of column KEY.
`heisig-gt-list-column-widths' takes precedence over the width
recorded in the registry."
  (or (alist-get key heisig-gt-list-column-widths)
      (plist-get (heisig-gt-list--column key) :width)))

(defun heisig-gt-list--visible-columns ()
  "Return this buffer's displayed column keys, unknown keys removed.
Falls back to the first registry key when the selection is empty,
so the buffer always has at least one column."
  (let ((cols (seq-filter (lambda (key)
                            (assq key (heisig-gt-list--registry)))
                          heisig-gt-list--columns)))
    (or cols (list (car (heisig-gt-list--column-keys))))))

;;;; Rendering

(defun heisig-gt-list--cell (kanji key &optional expand)
  "Return the display string of column KEY for KANJI.
A value wider than the column is truncated to it and marked with
the function `truncate-string-ellipsis', so a shortened cell is
visibly shortened rather than silently cut.  Width is counted in
display columns, which is what makes a kanji take two of them.

EXPAND leaves the value at full length.  It is passed for the
last displayed column, which has the rest of the line to itself:
nothing follows it to be pushed out of place, so truncating it
would discard text for no gain."
  (let* ((entry (heisig-gt-list--column key))
         (face (plist-get entry :face))
         (raw (funcall (plist-get entry :value) kanji))
         (text (if expand
                   raw
                 (truncate-string-to-width
                  raw (heisig-gt-list--column-width key) nil nil t))))
    (if face (propertize text 'face face) text)))

(defun heisig-gt-list--format ()
  "Return `tabulated-list-format' for this buffer's displayed columns.
The last column is declared with width 0, tabulated-list's way of
saying a column takes the rest of the line: it is neither padded
nor truncated.  `heisig-gt-list--cell' leaves that column's value
at full length to match."
  (let* ((cols (heisig-gt-list--visible-columns))
         (last (car (last cols))))
    (apply #'vector
           (mapcar
            (lambda (key)
              (let ((entry (heisig-gt-list--column key)))
                (list (plist-get entry :name)
                      (if (eq key last) 0 (heisig-gt-list--column-width key))
                      (plist-get entry :sort))))
            cols))))

(defun heisig-gt-list--filter-matches-p (kanji filter)
  "Return non-nil when KANJI satisfies FILTER.
FILTER matches when its predicate holds for ANY of its values, so
several values of one attribute widen the selection.  A filter
carrying a non-nil :negate matches exactly the kanji it would
otherwise reject.  A key with no registry entry matches
everything, so a filter left over from a removed registration
narrows nothing instead of emptying the buffer."
  (let* ((entry (alist-get (plist-get filter :key)
                           (heisig-gt-list--filters-registry)))
         (predicate (plist-get entry :predicate))
         (matched (or (null predicate)
                      (and (seq-some (lambda (value)
                                       (funcall predicate kanji value))
                                     (plist-get filter :values))
                           t))))
    (if (plist-get filter :negate) (not matched) matched)))

(defun heisig-gt-list--apply-filters (kanji-list)
  "Return KANJI-LIST narrowed by every filter in `heisig-gt-list--filters'.
A kanji is kept only when every active filter matches it, so
separate filters narrow the selection while the values within one
filter widen it."
  (seq-filter
   (lambda (kanji)
     (seq-every-p (lambda (filter)
                    (heisig-gt-list--filter-matches-p kanji filter))
                  heisig-gt-list--filters))
   kanji-list))

(defun heisig-gt-list--filter-description (filter)
  "Return a compact display string for FILTER.
The `by-' prefix is dropped from the key and the values are
joined with commas, giving forms like \"jlpt=5,4\" and
\"!status=suspended\"."
  (let ((key (symbol-name (plist-get filter :key))))
    (format "%s%s=%s"
            (if (plist-get filter :negate) "!" "")
            (if (string-prefix-p "by-" key) (substring key 3) key)
            (mapconcat (lambda (value) (format "%s" value))
                       (plist-get filter :values)
                       ","))))

(defun heisig-gt-list--entries ()
  "Compute `tabulated-list-entries' from the cached kanji list.
Applies `heisig-gt-list--filters'.  The kanji record itself is
the tabulated-list id of its row."
  (let* ((cols (heisig-gt-list--visible-columns))
         (last (car (last cols)))
         (kanji-list (heisig-gt-list--apply-filters heisig-gt-list--kanji)))
    (setq heisig-gt-list--total (length heisig-gt-list--kanji))
    (setq heisig-gt-list--shown (length kanji-list))
    (mapcar
     (lambda (kanji)
       (list kanji
             (apply #'vector
                    (mapcar (lambda (key)
                              (heisig-gt-list--cell kanji key (eq key last)))
                            cols))))
     kanji-list)))

;;;; Mode line

(defun heisig-gt-list--mode-line ()
  "Return the mode-line string reporting filters and row counts.
Reads the counts `heisig-gt-list--entries' recorded at the last
redraw rather than recomputing them: this runs on every
redisplay, and re-filtering the kanji list there would apply
every predicate to every row many times a second."
  (concat
   (when-let* ((scope (and heisig-gt-list--scope-function
                           (funcall heisig-gt-list--scope-function))))
     (concat " " scope))
   (when heisig-gt-list--filters
     (concat " ["
             (mapconcat #'heisig-gt-list--filter-description
                        heisig-gt-list--filters
                        " ")
             "]"))
   (format " %d/%d" heisig-gt-list--shown heisig-gt-list--total)
   ;; Say so once, in the one place that is always visible: without
   ;; it, an empty Status column looks like a kanji nobody has
   ;; studied rather than a collection nobody could read.
   (when heisig-gt-db-study-unavailable
     (format " [no study data: %s]" heisig-gt-db-study-unavailable))))

;;;; Sort key

(defun heisig-gt-list--sortable-columns ()
  "Return the names of the displayed columns that can be sorted."
  (seq-keep (lambda (entry)
              (and (nth 2 entry) (nth 0 entry)))
            (append (heisig-gt-list--format) nil)))

(defun heisig-gt-list--valid-sort-key (key)
  "Return KEY when it names a displayed sortable column, else a default.
The sorted column can be hidden, which would otherwise leave
tabulated-list sorting on a column that is no longer there."
  (let ((sortable (heisig-gt-list--sortable-columns)))
    (cond ((and key (member (car key) sortable)) key)
          ((member (car (heisig-gt-list--sort-key-default)) sortable)
           (heisig-gt-list--sort-key-default))
          (sortable (cons (car sortable) nil)))))

;;;; State-file persistence

(defun heisig-gt-list--state-load ()
  "Read `heisig-gt-list-state-file' into `heisig-gt-list--state'.
A missing or unreadable file leaves the state empty, which is the
same as never having saved one."
  (setq heisig-gt-list--state-loaded t)
  (setq heisig-gt-list--state
        (when (and heisig-gt-list-persist-state
                   (file-readable-p heisig-gt-list-state-file))
          (with-demoted-errors "heisig-gt-list: cannot read state: %S"
            (with-temp-buffer
              (insert-file-contents heisig-gt-list-state-file)
              (read (current-buffer)))))))

(defun heisig-gt-list--state-capture ()
  "Return this buffer's view as a plist."
  (list :sort-key tabulated-list-sort-key
        :columns heisig-gt-list--columns
        :filters heisig-gt-list--filters))

(defun heisig-gt-list--state-for-mode ()
  "Return the saved view for this buffer's mode, or nil.
The file holds one entry per mode: the kanji list and the word
list have different columns and different filters, and one
overwriting the other's view would be worse than saving neither."
  (alist-get major-mode heisig-gt-list--state))

(defun heisig-gt-list--state-apply ()
  "Apply the saved view to this buffer, where there is one."
  (when-let* ((heisig-gt-list--state (heisig-gt-list--state-for-mode)))
    (when-let* ((columns (plist-get heisig-gt-list--state :columns)))
      (setq heisig-gt-list--columns columns))
    (setq heisig-gt-list--filters
          (plist-get heisig-gt-list--state :filters))
    (when-let* ((key (plist-get heisig-gt-list--state :sort-key)))
      (setq tabulated-list-sort-key key))))

(defun heisig-gt-list-save-state ()
  "Write this buffer's view to `heisig-gt-list-state-file'."
  (interactive nil heisig-gt-list-mode)
  (setf (alist-get major-mode heisig-gt-list--state)
        (heisig-gt-list--state-capture))
  (with-demoted-errors "heisig-gt-list: cannot save state: %S"
    (with-temp-file heisig-gt-list-state-file
      (let ((print-level nil)
            (print-length nil))
        (prin1 heisig-gt-list--state (current-buffer))
        (insert "\n")))))

(defun heisig-gt-list--state-changed ()
  "Record the current view when state persistence is enabled."
  (when (and heisig-gt-list-persist-state
             (derived-mode-p 'heisig-gt-list-mode))
    (heisig-gt-list-save-state)))

(defun heisig-gt-list--tabulated-sort-observer (&rest _)
  "Record the view after a sort.
Sorting by clicking a column header never passes through a
command of this mode, so it is invisible to every other hook
`heisig-gt-list--state-changed' runs from."
  (heisig-gt-list--state-changed))

(advice-add 'tabulated-list-sort :after
            #'heisig-gt-list--tabulated-sort-observer)

;;;; Mode + keymap

(defvar-keymap heisig-gt-list-mode-map
  :doc "Keymap for `heisig-gt-list-mode'."
  :parent tabulated-list-mode-map
  "RET" #'heisig-gt-list-show
  "TAB" #'heisig-gt-list-show-other-window
  "o"   #'heisig-gt-list-show-other-window
  "w"   #'heisig-gt-list-copy-char
  "W"   #'heisig-gt-list-words
  "s"   #'heisig-gt-list-sort-cycle
  "/"   #'heisig-gt-list-filter-by
  "D"   #'heisig-gt-list-filter-remove
  "c"   #'heisig-gt-list-toggle-column
  "C"   #'heisig-gt-list-set-columns
  "V"   #'heisig-gt-list-reset-view
  "g"   #'revert-buffer
  "q"   #'quit-window)

(define-derived-mode heisig-gt-list-mode tabulated-list-mode "Heisig-gt"
  "Major mode for the read-only kanji list buffer.

Each row is one kanji, or one of Heisig's primitives, narrowed by
any active filter.  No command in this mode writes anything: not
to the kanji database, not to the Anki collection.

Columns come from `heisig-gt-list-column-alist'.  Which of them
are displayed, and in what order, is `heisig-gt-list-columns';
change it for this buffer with \\[heisig-gt-list-toggle-column]
and \\[heisig-gt-list-set-columns].  A value wider than its
column is truncated and marked with an ellipsis, except in the
last column, which takes the rest of the line and is shown in
full.

The Status, Ivl, Reps, Laps and Due columns come from the Anki
collection, re-read on every \\[revert-buffer].  When it cannot
be read the columns are empty and the mode line says why; nothing
else is affected.

Row-scoped commands (act on the kanji at point):
  \\[heisig-gt-list-show] show it in detail
  \\[heisig-gt-list-show-other-window] show it in the other window
  \\[heisig-gt-list-copy-char] copy the character to the kill ring
  \\[heisig-gt-list-words] list the words written with it

Buffer-scoped commands:
  \\[heisig-gt-list-filter-by] filter (see below)
  \\[universal-argument] \\[heisig-gt-list-filter-by] filter out (negated)
  \\[heisig-gt-list-filter-remove] remove one filter
  \\[heisig-gt-list-toggle-column] show or hide one column
  \\[heisig-gt-list-set-columns] choose the column set and order
  \\[heisig-gt-list-sort-cycle] cycle the sort column
  \\[heisig-gt-list-reset-view] reset the view to defaults
  \\[revert-buffer] re-read the database and Anki, then redraw
  \\[quit-window] quit

Filters are by-jlpt, by-grade, by-kind, by-status, by-source,
by-radical, by-component, by-component-keyword, by-used-in,
by-onyomi, by-kunyomi, by-keyword-regexp, by-meaning-regexp,
by-frame, by-strokes, by-freq, and unfilter.

by-onyomi and by-kunyomi take a reading in either script, and
complete on both, so \"kou\" and \"コウ\" select the same rows and
neither needs an input method.

by-component selects on the component character, and
by-component-keyword on its English name, so 水 and \"water\"
reach the same rows from either side of the Comp keywords
column.

The frame, stroke and frequency searches take a \"FROM,TO\" range
of numbers; either side may be left empty for no limit, so
\"800,\" is every frame from 800 on.

Selecting on more than one attribute is a matter of applying more
than one filter.  Values within a single filter WIDEN the
selection and separate filters NARROW it, so reading \"5,4\" at
the JLPT prompt and then filtering by status selects the N5 and
N4 kanji that are also in the chosen queue.  The same filter can
be applied repeatedly, each time narrowing further.  With a
prefix argument the filter is negated, selecting what it would
otherwise reject.

The mode line lists the filters in force and the number of rows
they leave, as \"[jlpt=5,4 !status=suspended] 25/2000\".

\\[bookmark-set] stores the current view -- the displayed
columns, the active filters, and the sort key.  Jumping to it
restores those three and re-reads the data.

Sorting: click a column header, or press \\[heisig-gt-list-sort-cycle]
to cycle through the sortable columns.

\\{heisig-gt-list-mode-map}"
  (setq heisig-gt-list--columns (heisig-gt-list--columns-default))
  ;; No leading gutter: that column exists in a list buffer to hold
  ;; mark characters, and this buffer is read only.  With padding the
  ;; first column would start one column in, against the left edge of
  ;; every other Emacs list buffer.
  (setq tabulated-list-padding 0)
  (setq tabulated-list-entries #'heisig-gt-list--entries)
  (setq-local revert-buffer-function #'heisig-gt-list--revert)
  (setq-local bookmark-make-record-function #'heisig-gt-list--make-record)
  (setq-local mode-line-process '(:eval (heisig-gt-list--mode-line)))
  (unless heisig-gt-list--state-loaded
    (heisig-gt-list--state-load))
  (heisig-gt-list--state-apply)
  (setq tabulated-list-format (heisig-gt-list--format))
  (setq tabulated-list-sort-key
        (heisig-gt-list--valid-sort-key
         (or tabulated-list-sort-key (heisig-gt-list--sort-key-default))))
  (tabulated-list-init-header))

;;;; Refresh

(defun heisig-gt-list--reload-kanji ()
  "Re-read the kanji list and the Anki study data."
  (heisig-gt-db-reload-study)
  (heisig-gt-db-kanji-list))

(defun heisig-gt-list--reload ()
  "Re-read this buffer's records into the cache."
  (setq heisig-gt-list--kanji
        (funcall (or heisig-gt-list--reload-function
                     #'heisig-gt-list--reload-kanji))))

(defun heisig-gt-list--record-id (record)
  "Return the identity string of RECORD."
  (when record
    (funcall (or heisig-gt-list--id-function
                 (lambda (r) (plist-get r :char)))
             record)))

(defun heisig-gt-list--id-at-point ()
  "Return the identity of the record on the current line, or nil."
  (heisig-gt-list--record-id (tabulated-list-get-id)))

(defun heisig-gt-list--char-at-point ()
  "Return the identity of the record on the current line, or nil."
  (heisig-gt-list--id-at-point))

(defun heisig-gt-list--goto-char-row (id)
  "Move point to the first row whose record identity is ID.
No-op when ID is nil; falls back to `point-min' when no row
matches, which is the case once a filter has removed the row."
  (when id
    (goto-char (point-min))
    (let ((found nil))
      (while (and (not (eobp)) (not found))
        (if (equal (heisig-gt-list--id-at-point) id)
            (setq found t)
          (forward-line 1)))
      (unless found (goto-char (point-min))))))

(defun heisig-gt-list--redraw-preserving-point ()
  "Rebuild the header and redraw, keeping point on the same kanji.
Looks the row up by character: the records are built fresh on
every read, so the character is the only identity that survives a
revert.  The row's visual offset from `window-start' is restored
as well."
  (let* ((win (get-buffer-window (current-buffer)))
         (visual-line (and win
                           (count-lines (window-start win)
                                        (line-beginning-position))))
         (char (heisig-gt-list--char-at-point)))
    (setq tabulated-list-format (heisig-gt-list--format))
    (setq tabulated-list-sort-key
          (heisig-gt-list--valid-sort-key tabulated-list-sort-key))
    (tabulated-list-init-header)
    (tabulated-list-print t)
    (unless (equal (heisig-gt-list--char-at-point) char)
      (heisig-gt-list--goto-char-row char))
    (when (and win visual-line (window-live-p win))
      (with-selected-window win
        (recenter visual-line)))))

(defun heisig-gt-list--revert (&rest _args)
  "Revert function for the kanji list buffer.
Re-reads the kanji list and the Anki study data, then redraws."
  (heisig-gt-list--reload)
  (heisig-gt-list--redraw-preserving-point))

;;;; Interactive entry point

;;;###autoload
(defun heisig-gt-list ()
  "Display the read-only kanji list buffer.
When the buffer already exists and is in `heisig-gt-list-mode',
reuse it: sort key, filters and displayed columns are preserved,
and the data is re-read.  When creating the buffer, initial view
state comes from `heisig-gt-list-state-file' when
`heisig-gt-list-persist-state' is enabled, otherwise from the
mode defaults."
  (interactive)
  (let ((buf (get-buffer-create heisig-gt-list-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'heisig-gt-list-mode)
        (heisig-gt-list-mode))
      (heisig-gt-list--reload)
      (heisig-gt-list--redraw-preserving-point))
    (pop-to-buffer-same-window buf)))

;;;; Cursor -> kanji lookup

(defun heisig-gt-list--kanji-at-point ()
  "Return the kanji record on the current line, or nil."
  (tabulated-list-get-id))

(defun heisig-gt-list--require-kanji ()
  "Return the kanji record on the current line, or signal."
  (or (heisig-gt-list--kanji-at-point)
      (user-error "No kanji on this line")))

;;;; Row commands

(defun heisig-gt-list-show ()
  "Show the kanji at point in the detail buffer."
  (interactive nil heisig-gt-list-mode)
  (heisig-gt-detail-show (plist-get (heisig-gt-list--require-kanji) :char)))

(defun heisig-gt-list-show-other-window ()
  "Show the kanji at point in the detail buffer, keeping point here."
  (interactive nil heisig-gt-list-mode)
  (let ((char (plist-get (heisig-gt-list--require-kanji) :char))
        (win (selected-window)))
    (heisig-gt-detail-show char t)
    (select-window win)))

(declare-function heisig-gt-words "heisig-gt-words" (&optional chars))

(defun heisig-gt-list-words ()
  "Show the words written with the kanji at point."
  (interactive nil heisig-gt-list-mode)
  (heisig-gt-words (plist-get (heisig-gt-list--require-kanji) :char)))

(defun heisig-gt-list-copy-char ()
  "Copy the character at point to the kill ring."
  (interactive nil heisig-gt-list-mode)
  (let ((char (plist-get (heisig-gt-list--require-kanji) :char)))
    (kill-new char)
    (message "Copied %s" char)))

;;;; Sorting

(defun heisig-gt-list-sort-cycle ()
  "Sort by the next sortable column, wrapping at the end.
Always ascending; click a column header to reverse it."
  (interactive nil heisig-gt-list-mode)
  (let* ((sortable (heisig-gt-list--sortable-columns))
         (current (car tabulated-list-sort-key))
         (position (and current (seq-position sortable current)))
         (next (nth (if position
                        (mod (1+ position) (length sortable))
                      0)
                    sortable)))
    (unless sortable
      (user-error "No sortable column is displayed"))
    (setq tabulated-list-sort-key (cons next nil))
    (heisig-gt-list--redraw-preserving-point)
    (heisig-gt-list--state-changed)
    (message "Sorted by %s" next)))

;;;; Columns

(defun heisig-gt-list--read-column (prompt)
  "Read a column key with PROMPT, completing on the registry."
  (intern (completing-read prompt
                           (mapcar #'symbol-name
                                   (heisig-gt-list--column-keys))
                           nil t)))

(defun heisig-gt-list-toggle-column (key)
  "Show column KEY when it is hidden, hide it when it is shown.
A column being shown again returns to its registry position, not
to the end of the line."
  (interactive (list (heisig-gt-list--read-column "Toggle column: "))
               heisig-gt-list-mode)
  (heisig-gt-list--column key)
  (setq heisig-gt-list--columns
        (if (memq key heisig-gt-list--columns)
            (delq key (copy-sequence heisig-gt-list--columns))
          ;; Re-derived from the registry rather than appended, so
          ;; the column comes back where it belongs.
          (seq-filter (lambda (k)
                        (or (eq k key) (memq k heisig-gt-list--columns)))
                      (heisig-gt-list--column-keys))))
  (heisig-gt-list--redraw-preserving-point)
  (heisig-gt-list--state-changed))

(defun heisig-gt-list-set-columns (keys)
  "Display exactly the columns KEYS, in the order given.
The current selection is offered as editable initial input, so
this is also how to reorder columns."
  (interactive
   (list (mapcar #'intern
                 (completing-read-multiple
                  "Columns (in order): "
                  (mapcar #'symbol-name (heisig-gt-list--column-keys))
                  nil t
                  (mapconcat #'symbol-name heisig-gt-list--columns ","))))
   heisig-gt-list-mode)
  (mapc #'heisig-gt-list--column keys)
  (unless keys
    (user-error "At least one column is needed"))
  (setq heisig-gt-list--columns keys)
  (heisig-gt-list--redraw-preserving-point)
  (heisig-gt-list--state-changed))

;;;; Reset

(defun heisig-gt-list-reset-view ()
  "Clear every filter and restore the default columns and sort key."
  (interactive nil heisig-gt-list-mode)
  (setq heisig-gt-list--filters nil)
  (setq heisig-gt-list--columns (heisig-gt-list--columns-default))
  (setq tabulated-list-sort-key
        (heisig-gt-list--valid-sort-key (heisig-gt-list--sort-key-default)))
  (heisig-gt-list--redraw-preserving-point)
  (heisig-gt-list--state-changed)
  (message "View reset"))

;;;; Bookmarking a view

(defcustom heisig-gt-list-bookmark-prefix "Kanji"
  "Prefix of the name \\[bookmark-set] offers for a kanji list view."
  :type 'string
  :group 'heisig-gt)

(defun heisig-gt-list--bookmark-name ()
  "Return the default bookmark name for this buffer's view.
The active filters are part of the name, so several saved views
do not all land on the same default."
  (if heisig-gt-list--filters
      (format "%s: %s" heisig-gt-list-bookmark-prefix
              (mapconcat #'heisig-gt-list--filter-description
                         heisig-gt-list--filters " "))
    heisig-gt-list-bookmark-prefix))

(defun heisig-gt-list--make-record ()
  "Return a bookmark record for this buffer's view.
What is stored is the view -- columns, filters, sort key -- and
not a position: the row a position named may not exist the next
time the data is read."
  `((handler . ,(or heisig-gt-list--bookmark-handler
                    #'heisig-gt-list-bookmark-jump))
    (defaults . (,(heisig-gt-list--bookmark-name)))
    (seed . ,(bound-and-true-p heisig-gt-words--seed))
    (columns . ,heisig-gt-list--columns)
    (filters . ,heisig-gt-list--filters)
    (sort-key . ,tabulated-list-sort-key)))

;;;###autoload
(defun heisig-gt-list-bookmark-jump (bookmark)
  "Restore the kanji list view stored in BOOKMARK."
  (heisig-gt-list)
  (with-current-buffer heisig-gt-list-buffer-name
    (setq heisig-gt-list--columns
          (or (bookmark-prop-get bookmark 'columns)
              heisig-gt-list-columns))
    (setq heisig-gt-list--filters (bookmark-prop-get bookmark 'filters))
    (setq tabulated-list-sort-key
          (heisig-gt-list--valid-sort-key
           (bookmark-prop-get bookmark 'sort-key)))
    (heisig-gt-list--redraw-preserving-point)))

;;;; Filter

(defun heisig-gt-list-filter-by (key &optional negate)
  "Add the filter KEY to the current buffer.
KEY is read from `heisig-gt-list-filter-alist'.  Its reader may
return several values, and a kanji matches the filter when any
one of them matches, so several JLPT levels widen the selection.

The filter is ADDED, not substituted: applying the same key again
narrows further rather than replacing what is already in force.
Remove one with `heisig-gt-list-filter-remove'.

With a prefix argument, NEGATE is non-nil and the filter selects
exactly the kanji it would otherwise reject.

The special KEY `unfilter' clears every active filter."
  (interactive
   (let ((choices (cons '(unfilter
                          :name "Unfilter"
                          :doc "Clear every active filter.")
                        (heisig-gt-list--filters-registry))))
     (list (intern (completing-read
                    (if current-prefix-arg "Filter out by: " "Filter by: ")
                    (mapcar (lambda (e) (symbol-name (car e))) choices)
                    nil t))
           current-prefix-arg))
   heisig-gt-list-mode)
  (if (eq key 'unfilter)
      (setq heisig-gt-list--filters nil)
    (let* ((entry (or (alist-get key (heisig-gt-list--filters-registry))
                      (user-error "Unknown filter: %s" key)))
           (values (funcall (plist-get entry :reader)))
           (filter (list :key key :values values :negate (and negate t))))
      (unless values
        (user-error "No value given; filter not added"))
      ;; An identical filter would narrow nothing and clutter the
      ;; indicator, so adding one again is a no-op rather than a
      ;; duplicate row in the list.
      (unless (member filter heisig-gt-list--filters)
        (setq heisig-gt-list--filters
              (append heisig-gt-list--filters (list filter))))))
  (heisig-gt-list--redraw-preserving-point)
  (heisig-gt-list--state-changed))

(defun heisig-gt-list-filter-remove (description)
  "Remove the single active filter named DESCRIPTION.
Completion offers the filters currently in force, in the form the
mode line shows them.  Use `heisig-gt-list-reset-view' to clear
all of them at once."
  (interactive
   (progn
     (unless heisig-gt-list--filters
       (user-error "No active filters"))
     (list (completing-read
            "Remove filter: "
            (mapcar #'heisig-gt-list--filter-description
                    heisig-gt-list--filters)
            nil t)))
   heisig-gt-list-mode)
  (setq heisig-gt-list--filters
        (seq-remove (lambda (filter)
                      (equal description
                             (heisig-gt-list--filter-description filter)))
                    heisig-gt-list--filters))
  (heisig-gt-list--redraw-preserving-point)
  (heisig-gt-list--state-changed)
  (message "Removed filter: %s" description))

;;;; Numeric ranges for the frame, stroke and frequency searches
;;
;; A range is stored as the string the user typed and parsed when it
;; is applied, so a bookmarked view records "800," rather than the
;; 1200 frames that happened to satisfy it on the day it was saved.

(defconst heisig-gt-list--range-regexp
  (rx bos (* space)
      (group (* digit)) (* space)
      (? "," (* space) (group (* digit)) (* space))
      eos)
  "Shape of a range: \"FROM,TO\", or a single number for an exact match.
Either side of the comma may be empty, leaving that end unbounded.")

(defun heisig-gt-list--range-bounds (spec)
  "Return the (FROM . TO) bounds of the range SPEC, or nil when invalid.
Either bound is nil when that end is unbounded."
  (when (and (stringp spec) (string-match heisig-gt-list--range-regexp spec))
    (let* ((from (match-string 1 spec))
           (to (match-string 2 spec))
           (low (unless (string-empty-p from) (string-to-number from))))
      (cond
       ;; "15" with no comma is an exact match, not "15 and up": a
       ;; single number reads as one value, and a range that quietly
       ;; became open-ended would return most of the table.
       ((null to) (and low (cons low low)))
       (t (cons low (unless (string-empty-p to) (string-to-number to))))))))

(defun heisig-gt-list--in-range-p (value spec)
  "Return non-nil when VALUE falls inside the range SPEC.
A nil VALUE is outside every range: an unknown stroke count is
not a stroke count of zero."
  (when-let* ((value value)
              (bounds (heisig-gt-list--range-bounds spec)))
    (and (or (null (car bounds)) (>= value (car bounds)))
         (or (null (cdr bounds)) (<= value (cdr bounds))))))

(defun heisig-gt-list--read-range (prompt)
  "Read a range with PROMPT, returning it as a one-element list.
Rejects anything `heisig-gt-list--range-bounds' cannot parse, so
a typo is refused at the prompt rather than silently matching
nothing."
  (let ((spec (read-string (format "%s (FROM,TO or N): " prompt))))
    (unless (heisig-gt-list--range-bounds spec)
      (user-error "Not a range: %s" spec))
    (list spec)))

(defun heisig-gt-list--values-of (field)
  "Return the distinct non-nil values of FIELD in the cached kanji.
Offering what the buffer actually holds keeps the completion
candidates honest: a level no row carries would produce an empty
buffer with no indication why."
  (sort (delete-dups (delq nil (mapcar (lambda (kanji)
                                         (plist-get kanji field))
                                       heisig-gt-list--kanji)))
        #'value<))

;;;; Built-in filter entries

(defun heisig-gt-list--read-numbers (prompt field)
  "Read several values of FIELD with PROMPT, completing on what is there."
  (mapcar #'string-to-number
          (completing-read-multiple
           prompt
           (mapcar #'number-to-string (heisig-gt-list--values-of field))
           nil t)))

(add-to-list 'heisig-gt-list-filter-alist
             (cons 'by-jlpt
                   (list :name "JLPT"
                         :reader (lambda ()
                                   (heisig-gt-list--read-numbers
                                    "JLPT levels (comma-separated): " :jlpt))
                         :predicate (lambda (kanji level)
                                      (equal level (plist-get kanji :jlpt)))
                         :doc "Show only kanji at one of the chosen JLPT \
levels.")))

(add-to-list 'heisig-gt-list-filter-alist
             (cons 'by-grade
                   (list :name "Grade"
                         :reader (lambda ()
                                   (heisig-gt-list--read-numbers
                                    "Grades (comma-separated): " :grade))
                         :predicate (lambda (kanji grade)
                                      (equal grade (plist-get kanji :grade)))
                         :doc "Show only kanji taught in one of the chosen \
school grades.")))

(add-to-list 'heisig-gt-list-filter-alist
             (cons 'by-kind
                   (list :name "Kind"
                         :reader (lambda ()
                                   (completing-read-multiple
                                    "Kinds: " '("kanji" "primitive") nil t))
                         :predicate (lambda (kanji kind)
                                      (equal kind (plist-get kanji :kind)))
                         :doc "Show only kanji, or only Heisig primitives.")))

(add-to-list 'heisig-gt-list-filter-alist
             (cons 'by-status
                   (list :name "Status"
                         :reader
                         (lambda ()
                           (mapcar #'intern
                                   (completing-read-multiple
                                    "Statuses: "
                                    (cons "none"
                                          (mapcar #'symbol-name
                                                  heisig-gt-db-statuses))
                                    nil t)))
                         :predicate
                         (lambda (kanji status)
                           (if (eq status 'none)
                               (null (heisig-gt-list-status kanji))
                             (eq status (heisig-gt-list-status kanji))))
                         :doc "Show only kanji in one of the chosen Anki \
queues; `none' is those Anki does not have.")))

(add-to-list 'heisig-gt-list-filter-alist
             (cons 'by-source
                   (list :name "Source"
                         :reader (lambda ()
                                   (completing-read-multiple
                                    "Sources: "
                                    '("migaku" "academy" "json") nil t))
                         :predicate
                         (lambda (kanji source)
                           (member source
                                   (split-string
                                    (or (plist-get kanji :sources) "")
                                    "," t)))
                         :doc "Show only kanji whose data came from one of \
the chosen sources.")))

(add-to-list 'heisig-gt-list-filter-alist
             (cons 'by-radical
                   (list :name "Radical"
                         :reader (lambda ()
                                   (completing-read-multiple
                                    "Radicals: "
                                    (heisig-gt-list--values-of :radical)
                                    nil t))
                         :predicate (lambda (kanji radical)
                                      (equal radical
                                             (plist-get kanji :radical)))
                         :doc "Show only kanji under one of the chosen \
radicals.")))

(add-to-list 'heisig-gt-list-filter-alist
             (cons 'by-component
                   (list :name "Component"
                         :reader (lambda ()
                                   (completing-read-multiple
                                    "Built from: " nil nil nil))
                         :predicate
                         (lambda (kanji component)
                           (seq-some
                            (lambda (row) (equal component (car row)))
                            (heisig-gt-db-components
                             (plist-get kanji :char))))
                         :doc "Show only kanji built from one of the chosen \
components.")))

(add-to-list 'heisig-gt-list-filter-alist
             (cons 'by-component-keyword
                   (list :name "Component keyword"
                         :reader
                         (lambda ()
                           (completing-read-multiple
                            "Built from, by name (comma-separated): "
                            (heisig-gt-db-all-component-names)
                            nil t))
                         :predicate
                         (lambda (kanji name)
                           (member name
                                   (heisig-gt-db-component-names
                                    (plist-get kanji :char))))
                         :doc "Show only kanji built from a component with \
one of the chosen English names.")))

(add-to-list 'heisig-gt-list-filter-alist
             (cons 'by-used-in
                   (list :name "Used in"
                         :reader (lambda ()
                                   (completing-read-multiple
                                    "Component of: " nil nil nil))
                         :predicate
                         (lambda (kanji target)
                           (member target
                                   (heisig-gt-db-used-in
                                    (plist-get kanji :char))))
                         :doc "Show only the components of the chosen \
kanji.")))

(add-to-list 'heisig-gt-list-filter-alist
             (cons 'by-onyomi
                   (list :name "On reading"
                         :reader (lambda ()
                                   (completing-read-multiple
                                    "On readings (kana or romaji): "
                                    (heisig-gt-db-all-readings "on")
                                    nil t))
                         :predicate
                         (lambda (kanji value)
                           (heisig-gt-db-reading-matches-p
                            (plist-get kanji :char) "on" value))
                         :doc "Show only kanji with one of the chosen on \
readings, spelled either way.")))

(add-to-list 'heisig-gt-list-filter-alist
             (cons 'by-kunyomi
                   (list :name "Kun reading"
                         :reader (lambda ()
                                   (completing-read-multiple
                                    "Kun readings (kana or romaji): "
                                    (heisig-gt-db-all-readings "kun")
                                    nil t))
                         :predicate
                         (lambda (kanji value)
                           (heisig-gt-db-reading-matches-p
                            (plist-get kanji :char) "kun" value))
                         :doc "Show only kanji with one of the chosen kun \
readings, spelled either way.")))

(add-to-list 'heisig-gt-list-filter-alist
             (cons 'by-keyword-regexp
                   ;; One regexp per filter: a comma is an ordinary
                   ;; character inside a regexp, so splitting on it
                   ;; would corrupt the pattern.  Apply the filter
                   ;; twice to narrow further.
                   (list :name "Keyword regexp"
                         :reader (lambda ()
                                   (list (read-regexp "Keyword matches")))
                         :predicate
                         (lambda (kanji regexp)
                           (string-match-p regexp
                                           (heisig-gt-list--keyword kanji)))
                         :doc "Show only kanji whose keyword matches a \
regexp.")))

(add-to-list 'heisig-gt-list-filter-alist
             (cons 'by-meaning-regexp
                   (list :name "Meaning regexp"
                         :reader (lambda ()
                                   (list (read-regexp "Meaning matches")))
                         :predicate
                         (lambda (kanji regexp)
                           (string-match-p regexp
                                           (heisig-gt-list--meanings kanji)))
                         :doc "Show only kanji whose meanings match a \
regexp.")))

(add-to-list 'heisig-gt-list-filter-alist
             (cons 'by-frame
                   (list :name "Frame"
                         :reader (lambda ()
                                   (heisig-gt-list--read-range "Frames"))
                         :predicate
                         (lambda (kanji spec)
                           (heisig-gt-list--in-range-p
                            (plist-get kanji :heisig6) spec))
                         :doc "Show only kanji in a range of Heisig \
frames.")))

(add-to-list 'heisig-gt-list-filter-alist
             (cons 'by-strokes
                   (list :name "Strokes"
                         :reader (lambda ()
                                   (heisig-gt-list--read-range "Strokes"))
                         :predicate
                         (lambda (kanji spec)
                           (heisig-gt-list--in-range-p
                            (plist-get kanji :strokes) spec))
                         :doc "Show only kanji in a range of stroke \
counts.")))

(add-to-list 'heisig-gt-list-filter-alist
             (cons 'by-freq
                   (list :name "Frequency"
                         :reader (lambda ()
                                   (heisig-gt-list--read-range
                                    "Frequency ranks"))
                         :predicate
                         (lambda (kanji spec)
                           (heisig-gt-list--in-range-p
                            (plist-get kanji :freq-rank) spec))
                         :doc "Show only kanji in a range of frequency \
ranks.")))

(provide 'heisig-gt-list)

;;; heisig-gt-list.el ends here
