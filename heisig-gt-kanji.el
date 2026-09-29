;;; heisig-gt-kanji.el --- Read-only list buffer for kanji  -*- lexical-binding: t; -*-

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

;; `heisig-gt-kanji' shows one row per kanji in a `tabulated-list-mode'
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

(defcustom heisig-gt-kanji-buffer-name "*Kanji*"
  "Name of the buffer `heisig-gt-kanji' displays."
  :type 'string
  :group 'heisig-gt)

(defcustom heisig-gt-kanji-columns
  '(heisig char keyword strokes jlpt status
    onyomi onyomi-romaji kunyomi kunyomi-romaji meanings)
  "Columns displayed by `heisig-gt-kanji', in display order.
Each element is a key of `heisig-gt-kanji-column-alist'.  This one
setting chooses the columns and orders them, so showing, hiding
and reordering are the same operation.  Change it for a single
buffer with \\[heisig-gt-kanji-toggle-column] and
\\[heisig-gt-kanji-set-columns]."
  :type '(repeat symbol)
  :group 'heisig-gt)

(defcustom heisig-gt-kanji-column-widths nil
  "Display widths overriding those in `heisig-gt-kanji-column-alist'.
An alist of (KEY . WIDTH).  A key absent here keeps the width the
registry records for it."
  :type '(alist :key-type symbol :value-type integer)
  :group 'heisig-gt)

(defcustom heisig-gt-kanji-default-sort-key '("Frame" . nil)
  "Initial sort key of a `heisig-gt-kanji' buffer.
A cons of the column name and a flag that reverses the order, in
the shape `tabulated-list-sort-key' takes.  The default opens the
buffer in Heisig's own order."
  :type '(cons string boolean)
  :group 'heisig-gt)

(defcustom heisig-gt-kanji-date-format "%Y-%m-%d"
  "Format used for the Due column, as `format-time-string' takes it."
  :type 'string
  :group 'heisig-gt)

;;;; State persistence

(defcustom heisig-gt-kanji-persist-state nil
  "Whether the view survives between sessions.
When non-nil, the displayed columns, the active filters and the
sort key are written to `heisig-gt-kanji-state-file' as they
change, and restored the next time a list buffer is created."
  :type 'boolean
  :group 'heisig-gt)

(defcustom heisig-gt-kanji-state-file
  (locate-user-emacs-file "heisig-gt-kanji-state.el")
  "File holding the view saved when `heisig-gt-kanji-persist-state'."
  :type 'file
  :group 'heisig-gt)

(defvar heisig-gt-kanji--state nil
  "View read from `heisig-gt-kanji-state-file', as a plist.")

(defvar heisig-gt-kanji--state-loaded nil
  "Whether the state file has been read in this session.")

;;;; Filter registry

(defvar heisig-gt-kanji-filter-alist nil
  "Filters offered by \\[heisig-gt-kanji-filter-by].

Each entry is (KEY :name STRING :reader FN :predicate FN :doc
STRING).  The :reader takes no arguments and returns a LIST of
values, even when it read only one.  The :predicate is called
with one kanji record and one of those values.

A kanji is kept when EVERY active filter matches it, and one
filter matches when ANY of its values does -- so values within a
filter widen the selection and separate filters narrow it.")

;;;; Buffer-local state

(defvar-local heisig-gt-kanji--records nil
  "Every kanji record, as read from the database at the last revert.
Filtering, sorting and column changes all redraw from this cache,
so only \\[revert-buffer] pays for a table scan.")

(defvar-local heisig-gt-kanji--filters nil
  "Filters in force in this buffer.
A list of (:key KEY :values LIST :negate BOOL) plists.  The same
key may appear more than once, each occurrence narrowing
further.")

(defvar-local heisig-gt-kanji--shown 0
  "Rows the active filters left, as of the last redraw.")

(defvar-local heisig-gt-kanji--total 0
  "Rows before filtering, as of the last redraw.")

(defvar-local heisig-gt-kanji--columns nil
  "Columns displayed in this buffer, in display order.")

;;;; Mode parameters
;;
;; Everything below this point -- rendering, filtering, sorting, the
;; mode line, the column commands, bookmarks, state -- knows nothing
;; about kanji.  A mode derived from `heisig-gt-kanji-mode' supplies
;; its own registries, its own way of loading records and of naming
;; one, and inherits the rest unchanged.  `heisig-gt-words-mode' is
;; the second such mode.

(defvar-local heisig-gt-kanji--column-registry nil
  "Column registry of this buffer.
Defaults to `heisig-gt-kanji-column-alist' when nil.")

(defvar-local heisig-gt-kanji--filter-registry nil
  "Filter registry of this buffer.
Defaults to `heisig-gt-kanji-filter-alist' when nil.")

(defvar-local heisig-gt-kanji--reload-function nil
  "Function of no arguments returning this buffer's records.")

(defvar-local heisig-gt-kanji--id-function nil
  "Function returning the identity string of one record.
A record is rebuilt on every read, so no object identity survives
a redraw; this is what point is re-found by.")

(defvar-local heisig-gt-kanji--default-columns nil
  "Columns this buffer returns to when the view is reset.")

(defvar-local heisig-gt-kanji--default-sort-key nil
  "Sort key this buffer returns to when the view is reset.")

(defvar-local heisig-gt-kanji--bookmark-handler nil
  "Function restoring a bookmarked view of this buffer's mode.")

(defvar-local heisig-gt-kanji--scope-function nil
  "Function returning a description of what this buffer is showing.
Filters narrow what was loaded; a scope is what was loaded at
all, and the mode line names it first so a buffer that was seeded
does not read as the whole table.")

;; Declared ahead of the accessors below, which are defined before the
;; registries themselves so that the mode parameters read as one block.
(defvar heisig-gt-kanji-column-alist)
(defvar heisig-gt-kanji-filter-alist)

(defun heisig-gt-kanji--registry ()
  "Return the column registry in force in this buffer."
  (or heisig-gt-kanji--column-registry heisig-gt-kanji-column-alist))

(defun heisig-gt-kanji--filters-registry ()
  "Return the filter registry in force in this buffer."
  (or heisig-gt-kanji--filter-registry heisig-gt-kanji-filter-alist))

(defun heisig-gt-kanji--sort-key-default ()
  "Return the sort key this buffer falls back to."
  (or heisig-gt-kanji--default-sort-key heisig-gt-kanji-default-sort-key))

(defun heisig-gt-kanji--columns-default ()
  "Return the columns this buffer falls back to."
  (or heisig-gt-kanji--default-columns heisig-gt-kanji-columns))

;;;; Column value functions
;;
;; One function per column, each taking a kanji record and returning
;; the cell's text.  A column with nothing to show returns the empty
;; string rather than "-": a table of dashes is harder to read past
;; than a table of gaps.

(defun heisig-gt-kanji--text (value)
  "Return VALUE as cell text, or the empty string when it is nil."
  (if value (format "%s" value) ""))

(defun heisig-gt-kanji--char (kanji)
  "Return the character of KANJI."
  (heisig-gt-kanji--text (plist-get kanji :char)))

(defun heisig-gt-kanji--heisig (kanji)
  "Return the Heisig frame number of KANJI."
  (heisig-gt-kanji--text (plist-get kanji :heisig6)))

(defun heisig-gt-kanji--keyword (kanji)
  "Return the keyword of KANJI."
  (heisig-gt-kanji--text (plist-get kanji :keyword)))

(defun heisig-gt-kanji--kind (kanji)
  "Return whether KANJI is a kanji or a Heisig primitive."
  (heisig-gt-kanji--text (plist-get kanji :kind)))

(defun heisig-gt-kanji--strokes (kanji)
  "Return the stroke count of KANJI."
  (heisig-gt-kanji--text (plist-get kanji :strokes)))

(defun heisig-gt-kanji--radical (kanji)
  "Return the radical of KANJI."
  (heisig-gt-kanji--text (plist-get kanji :radical)))

(defun heisig-gt-kanji--jlpt (kanji)
  "Return the JLPT level of KANJI, written as N5 through N1."
  (let ((level (plist-get kanji :jlpt)))
    (if (and level (> level 0)) (format "N%d" level) "")))

(defun heisig-gt-kanji--grade (kanji)
  "Return the school grade KANJI is taught in."
  (heisig-gt-kanji--text (plist-get kanji :grade)))

(defun heisig-gt-kanji--kanken (kanji)
  "Return the Kanji Kentei level of KANJI."
  (heisig-gt-kanji--text (plist-get kanji :kanken)))

(defun heisig-gt-kanji--wk (kanji)
  "Return the WaniKani level of KANJI."
  (heisig-gt-kanji--text (plist-get kanji :wk)))

(defun heisig-gt-kanji--freq (kanji)
  "Return the newspaper frequency rank of KANJI."
  (heisig-gt-kanji--text (plist-get kanji :freq-rank)))

(defun heisig-gt-kanji--meanings (kanji)
  "Return the English meanings of KANJI."
  (heisig-gt-kanji--text (plist-get kanji :meanings)))

(defun heisig-gt-kanji--sources (kanji)
  "Return the sources KANJI's data was merged from."
  (heisig-gt-kanji--text (plist-get kanji :sources)))

(defun heisig-gt-kanji--components (kanji)
  "Return the components of KANJI, run together as they are written."
  (mapconcat #'car (heisig-gt-db-components (plist-get kanji :char)) ""))

(defun heisig-gt-kanji--component-keywords (kanji)
  "Return the English names of the components of KANJI."
  (string-join (heisig-gt-db-component-names (plist-get kanji :char)) ", "))

(defun heisig-gt-kanji--onyomi (kanji)
  "Return the on readings of KANJI."
  (string-join (heisig-gt-db-readings (plist-get kanji :char) "on") "、"))

(defun heisig-gt-kanji--kunyomi (kanji)
  "Return the kun readings of KANJI."
  (string-join (heisig-gt-db-readings (plist-get kanji :char) "kun") "、"))

(defun heisig-gt-kanji--onyomi-romaji (kanji)
  "Return the on readings of KANJI, transliterated."
  (string-join (heisig-gt-db-readings-romaji (plist-get kanji :char) "on")
               ", "))

(defun heisig-gt-kanji--kunyomi-romaji (kanji)
  "Return the kun readings of KANJI, transliterated."
  (string-join (heisig-gt-db-readings-romaji (plist-get kanji :char) "kun")
               ", "))

(defun heisig-gt-kanji-status (kanji)
  "Return the Anki status symbol of KANJI, or nil when it has none."
  (plist-get (heisig-gt-db-study (plist-get kanji :char)) :status))

(defun heisig-gt-kanji--status (kanji)
  "Return the Anki status of KANJI, coloured by what it is."
  (let ((status (heisig-gt-kanji-status kanji)))
    (if status
        (propertize (symbol-name status)
                    'face (heisig-gt-db-status-face status))
      "")))

(defun heisig-gt-kanji--study (kanji field)
  "Return FIELD of the Anki study record of KANJI."
  (plist-get (heisig-gt-db-study (plist-get kanji :char)) field))

(defun heisig-gt-kanji--ivl (kanji)
  "Return the current review interval of KANJI, in days."
  (let ((ivl (heisig-gt-kanji--study kanji :ivl)))
    ;; A negative interval is Anki's way of recording seconds for a
    ;; card still in learning; it is not a number of days and showing
    ;; it as one would be a lie.
    (if (and ivl (> ivl 0)) (number-to-string ivl) "")))

(defun heisig-gt-kanji--reps (kanji)
  "Return how many times KANJI has been reviewed."
  (heisig-gt-kanji--text (heisig-gt-kanji--study kanji :reps)))

(defun heisig-gt-kanji--lapses (kanji)
  "Return how many times KANJI has been forgotten."
  (heisig-gt-kanji--text (heisig-gt-kanji--study kanji :lapses)))

(defun heisig-gt-kanji--due (kanji)
  "Return the date KANJI is next due for review."
  (let ((due (heisig-gt-kanji--study kanji :due)))
    (if due (format-time-string heisig-gt-kanji-date-format due) "")))

;;;; Comparators
;;
;; A column whose :sort is t is sorted by tabulated-list on the text
;; it displays, which is the right order for every column whose text
;; sorts the way its value does -- the dates included, being written
;; largest unit first.  The comparators below cover the columns where
;; that does not hold: numbers rendered as strings, where "10" would
;; otherwise precede "9", and the keyword, where case would separate
;; "Zebra" from "apple".

(defun heisig-gt-kanji--compare-keyword (a b)
  "Return non-nil when entry A's keyword precedes entry B's.
Comparison ignores case."
  (string-lessp (downcase (heisig-gt-kanji--keyword (car a)))
                (downcase (heisig-gt-kanji--keyword (car b)))))

(defun heisig-gt-kanji--number-compare (field)
  "Return a comparator ordering entries by the numeric FIELD.
A record with no value for FIELD sorts after every record that
has one, so the unknowns collect at one end instead of being
mixed in as zeroes.  Ties fall back to the keyword, so the order
is stable."
  (lambda (a b)
    (let ((x (plist-get (car a) field))
          (y (plist-get (car b) field)))
      (cond ((and (null x) (null y)) (heisig-gt-kanji--compare-keyword a b))
            ((null x) nil)
            ((null y) t)
            ((= x y) (heisig-gt-kanji--compare-keyword a b))
            (t (< x y))))))

(defun heisig-gt-kanji--study-compare (field)
  "Return a comparator ordering entries by the study FIELD.
Like `heisig-gt-kanji--number-compare', but reading the value out
of the Anki study record instead of the kanji record."
  (lambda (a b)
    (let ((x (heisig-gt-kanji--study (car a) field))
          (y (heisig-gt-kanji--study (car b) field)))
      (cond ((and (null x) (null y)) (heisig-gt-kanji--compare-keyword a b))
            ((null x) nil)
            ((null y) t)
            ((= x y) (heisig-gt-kanji--compare-keyword a b))
            (t (< x y))))))

;;;; Column registry

(defvar heisig-gt-kanji-column-alist
  (list
   (cons 'heisig     (list :name "Frame" :width 5
                           :value #'heisig-gt-kanji--heisig
                           :face 'font-lock-constant-face
                           :sort (heisig-gt-kanji--number-compare :heisig6)
                           :doc "Heisig frame number, sixth edition."))
   (cons 'char       (list :name "Kanji" :width 5
                           :value #'heisig-gt-kanji--char
                           :face nil :sort t
                           :doc "The character itself."))
   (cons 'keyword    (list :name "Keyword" :width 22
                           :value #'heisig-gt-kanji--keyword
                           :face 'font-lock-function-name-face
                           :sort #'heisig-gt-kanji--compare-keyword
                           :doc "Heisig keyword, or your own where you set \
one."))
   (cons 'kind       (list :name "Kind" :width 9
                           :value #'heisig-gt-kanji--kind
                           :face nil :sort t
                           :doc "Whether the row is a kanji or a Heisig \
primitive."))
   (cons 'strokes    (list :name "Str" :width 3
                           :value #'heisig-gt-kanji--strokes
                           :face nil
                           :sort (heisig-gt-kanji--number-compare :strokes)
                           :doc "Number of strokes."))
   (cons 'radical    (list :name "Rad" :width 3
                           :value #'heisig-gt-kanji--radical
                           :face nil :sort t
                           :doc "Classical radical."))
   (cons 'components (list :name "Components" :width 12
                           :value #'heisig-gt-kanji--components
                           :face nil :sort t
                           :doc "Components the character is built from."))
   (cons 'component-keywords
                     (list :name "Comp keywords" :width 30
                           :value #'heisig-gt-kanji--component-keywords
                           :face 'font-lock-doc-face :sort t
                           :doc "English names of the components, in the \
order they are written."))
   (cons 'onyomi     (list :name "On" :width 14
                           :value #'heisig-gt-kanji--onyomi
                           :face 'font-lock-string-face :sort t
                           :doc "On readings."))
   (cons 'onyomi-romaji
                     (list :name "On (romaji)" :width 16
                           :value #'heisig-gt-kanji--onyomi-romaji
                           :face 'font-lock-string-face :sort t
                           :doc "On readings, transliterated."))
   (cons 'kunyomi    (list :name "Kun" :width 14
                           :value #'heisig-gt-kanji--kunyomi
                           :face 'font-lock-string-face :sort t
                           :doc "Kun readings."))
   (cons 'kunyomi-romaji
                     (list :name "Kun (romaji)" :width 18
                           :value #'heisig-gt-kanji--kunyomi-romaji
                           :face 'font-lock-string-face :sort t
                           :doc "Kun readings, transliterated."))
   (cons 'jlpt       (list :name "JLPT" :width 4
                           :value #'heisig-gt-kanji--jlpt
                           :face nil
                           :sort (heisig-gt-kanji--number-compare :jlpt)
                           :doc "JLPT level, N5 (easiest) through N1."))
   (cons 'grade      (list :name "Grade" :width 5
                           :value #'heisig-gt-kanji--grade
                           :face nil
                           :sort (heisig-gt-kanji--number-compare :grade)
                           :doc "School grade the character is taught in."))
   (cons 'kanken     (list :name "Kanken" :width 6
                           :value #'heisig-gt-kanji--kanken
                           :face nil
                           :sort (heisig-gt-kanji--number-compare :kanken)
                           :doc "Kanji Kentei level."))
   (cons 'wk         (list :name "WK" :width 3
                           :value #'heisig-gt-kanji--wk
                           :face nil
                           :sort (heisig-gt-kanji--number-compare :wk)
                           :doc "WaniKani level."))
   (cons 'freq       (list :name "Freq" :width 5
                           :value #'heisig-gt-kanji--freq
                           :face nil
                           :sort (heisig-gt-kanji--number-compare :freq-rank)
                           :doc "Frequency rank in newspapers; 1 is the \
commonest."))
   (cons 'status     (list :name "Status" :width 9
                           :value #'heisig-gt-kanji--status
                           :face nil :sort t
                           :doc "Which Anki queue the character is in."))
   (cons 'ivl        (list :name "Ivl" :width 5
                           :value #'heisig-gt-kanji--ivl
                           :face nil
                           :sort (heisig-gt-kanji--study-compare :ivl)
                           :doc "Current review interval, in days."))
   (cons 'reps       (list :name "Reps" :width 4
                           :value #'heisig-gt-kanji--reps
                           :face nil
                           :sort (heisig-gt-kanji--study-compare :reps)
                           :doc "Times the character has been reviewed."))
   (cons 'lapses     (list :name "Laps" :width 4
                           :value #'heisig-gt-kanji--lapses
                           :face nil
                           :sort (heisig-gt-kanji--study-compare :lapses)
                           :doc "Times the character has been forgotten."))
   (cons 'due        (list :name "Due" :width 10
                           :value #'heisig-gt-kanji--due
                           :face 'font-lock-comment-face :sort t
                           :doc "Date the character is next due for review."))
   (cons 'sources    (list :name "Sources" :width 20
                           :value #'heisig-gt-kanji--sources
                           :face 'font-lock-comment-face :sort t
                           :doc "Which sources the row's data was merged \
from."))
   (cons 'meanings   (list :name "Meanings" :width 45
                           :value #'heisig-gt-kanji--meanings
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

`heisig-gt-kanji-columns' selects which of these are displayed and
in what order.")

(defun heisig-gt-kanji--column (key)
  "Return the registry entry for column KEY, signalling when unknown."
  (or (alist-get key (heisig-gt-kanji--registry))
      (user-error "Unknown column: %s" key)))

(defun heisig-gt-kanji--column-keys ()
  "Return every column key, in registry order."
  (mapcar #'car (heisig-gt-kanji--registry)))

(defun heisig-gt-kanji--column-width (key)
  "Return the display width of column KEY.
`heisig-gt-kanji-column-widths' takes precedence over the width
recorded in the registry."
  (or (alist-get key heisig-gt-kanji-column-widths)
      (plist-get (heisig-gt-kanji--column key) :width)))

(defun heisig-gt-kanji--visible-columns ()
  "Return this buffer's displayed column keys, unknown keys removed.
Falls back to the first registry key when the selection is empty,
so the buffer always has at least one column."
  (let ((cols (seq-filter (lambda (key)
                            (assq key (heisig-gt-kanji--registry)))
                          heisig-gt-kanji--columns)))
    (or cols (list (car (heisig-gt-kanji--column-keys))))))

;;;; Rendering

(defun heisig-gt-kanji--cell (kanji key &optional expand)
  "Return the display string of column KEY for KANJI.
A value wider than the column is truncated to it and marked with
the function `truncate-string-ellipsis', so a shortened cell is
visibly shortened rather than silently cut.  Width is counted in
display columns, which is what makes a kanji take two of them.

EXPAND leaves the value at full length.  It is passed for the
last displayed column, which has the rest of the line to itself:
nothing follows it to be pushed out of place, so truncating it
would discard text for no gain."
  (let* ((entry (heisig-gt-kanji--column key))
         (face (plist-get entry :face))
         (raw (funcall (plist-get entry :value) kanji))
         (text (if expand
                   raw
                 (truncate-string-to-width
                  raw (heisig-gt-kanji--column-width key) nil nil t))))
    (if face (propertize text 'face face) text)))

(defun heisig-gt-kanji--format ()
  "Return `tabulated-list-format' for this buffer's displayed columns.
The last column is declared with width 0, tabulated-list's way of
saying a column takes the rest of the line: it is neither padded
nor truncated.  `heisig-gt-kanji--cell' leaves that column's value
at full length to match."
  (let* ((cols (heisig-gt-kanji--visible-columns))
         (last (car (last cols))))
    (apply #'vector
           (mapcar
            (lambda (key)
              (let ((entry (heisig-gt-kanji--column key)))
                (list (plist-get entry :name)
                      (if (eq key last) 0 (heisig-gt-kanji--column-width key))
                      (plist-get entry :sort))))
            cols))))

(defun heisig-gt-kanji--filter-matches-p (kanji filter)
  "Return non-nil when KANJI satisfies FILTER.
FILTER matches when its predicate holds for ANY of its values, so
several values of one attribute widen the selection.  A filter
carrying a non-nil :negate matches exactly the kanji it would
otherwise reject.  A key with no registry entry matches
everything, so a filter left over from a removed registration
narrows nothing instead of emptying the buffer."
  (let* ((entry (alist-get (plist-get filter :key)
                           (heisig-gt-kanji--filters-registry)))
         (predicate (plist-get entry :predicate))
         (matched (or (null predicate)
                      (and (seq-some (lambda (value)
                                       (funcall predicate kanji value))
                                     (plist-get filter :values))
                           t))))
    (if (plist-get filter :negate) (not matched) matched)))

(defun heisig-gt-kanji--apply-filters (kanji-list)
  "Return KANJI-LIST narrowed by every filter in `heisig-gt-kanji--filters'.
A kanji is kept only when every active filter matches it, so
separate filters narrow the selection while the values within one
filter widen it."
  (seq-filter
   (lambda (kanji)
     (seq-every-p (lambda (filter)
                    (heisig-gt-kanji--filter-matches-p kanji filter))
                  heisig-gt-kanji--filters))
   kanji-list))

(defun heisig-gt-kanji--filter-description (filter)
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

(defun heisig-gt-kanji--entries ()
  "Compute `tabulated-list-entries' from the cached kanji list.
Applies `heisig-gt-kanji--filters'.  The kanji record itself is
the tabulated-list id of its row."
  (let* ((cols (heisig-gt-kanji--visible-columns))
         (last (car (last cols)))
         (kanji-list (heisig-gt-kanji--apply-filters heisig-gt-kanji--records)))
    (setq heisig-gt-kanji--total (length heisig-gt-kanji--records))
    (setq heisig-gt-kanji--shown (length kanji-list))
    (mapcar
     (lambda (kanji)
       (list kanji
             (apply #'vector
                    (mapcar (lambda (key)
                              (heisig-gt-kanji--cell kanji key (eq key last)))
                            cols))))
     kanji-list)))

;;;; Mode line

(defun heisig-gt-kanji--mode-line ()
  "Return the mode-line string reporting filters and row counts.
Reads the counts `heisig-gt-kanji--entries' recorded at the last
redraw rather than recomputing them: this runs on every
redisplay, and re-filtering the kanji list there would apply
every predicate to every row many times a second."
  (concat
   (when-let* ((scope (and heisig-gt-kanji--scope-function
                           (funcall heisig-gt-kanji--scope-function))))
     (concat " " scope))
   (when heisig-gt-kanji--filters
     (concat " ["
             (mapconcat #'heisig-gt-kanji--filter-description
                        heisig-gt-kanji--filters
                        " ")
             "]"))
   (format " %d/%d" heisig-gt-kanji--shown heisig-gt-kanji--total)
   ;; Say so once, in the one place that is always visible: without
   ;; it, an empty Status column looks like a kanji nobody has
   ;; studied rather than a collection nobody could read.
   (when heisig-gt-db-study-unavailable
     (format " [no study data: %s]" heisig-gt-db-study-unavailable))))

;;;; Sort key

(defun heisig-gt-kanji--sortable-columns ()
  "Return the names of the displayed columns that can be sorted."
  (seq-keep (lambda (entry)
              (and (nth 2 entry) (nth 0 entry)))
            (append (heisig-gt-kanji--format) nil)))

(defun heisig-gt-kanji--valid-sort-key (key)
  "Return KEY when it names a displayed sortable column, else a default.
The sorted column can be hidden, which would otherwise leave
tabulated-list sorting on a column that is no longer there."
  (let ((sortable (heisig-gt-kanji--sortable-columns)))
    (cond ((and key (member (car key) sortable)) key)
          ((member (car (heisig-gt-kanji--sort-key-default)) sortable)
           (heisig-gt-kanji--sort-key-default))
          (sortable (cons (car sortable) nil)))))

;;;; State-file persistence

(defun heisig-gt-kanji--state-load ()
  "Read `heisig-gt-kanji-state-file' into `heisig-gt-kanji--state'.
A missing or unreadable file leaves the state empty, which is the
same as never having saved one."
  (setq heisig-gt-kanji--state-loaded t)
  (setq heisig-gt-kanji--state
        (when (and heisig-gt-kanji-persist-state
                   (file-readable-p heisig-gt-kanji-state-file))
          (with-demoted-errors "heisig-gt-kanji: cannot read state: %S"
            (with-temp-buffer
              (insert-file-contents heisig-gt-kanji-state-file)
              (read (current-buffer)))))))

(defun heisig-gt-kanji--state-capture ()
  "Return this buffer's view as a plist."
  (list :sort-key tabulated-list-sort-key
        :columns heisig-gt-kanji--columns
        :filters heisig-gt-kanji--filters))

(defun heisig-gt-kanji--state-for-mode ()
  "Return the saved view for this buffer's mode, or nil.
The file holds one entry per mode: the kanji list and the word
list have different columns and different filters, and one
overwriting the other's view would be worse than saving neither."
  (alist-get major-mode heisig-gt-kanji--state))

(defun heisig-gt-kanji--state-apply ()
  "Apply the saved view to this buffer, where there is one."
  (when-let* ((heisig-gt-kanji--state (heisig-gt-kanji--state-for-mode)))
    (when-let* ((columns (plist-get heisig-gt-kanji--state :columns)))
      (setq heisig-gt-kanji--columns columns))
    (setq heisig-gt-kanji--filters
          (plist-get heisig-gt-kanji--state :filters))
    (when-let* ((key (plist-get heisig-gt-kanji--state :sort-key)))
      (setq tabulated-list-sort-key key))))

(defun heisig-gt-kanji-save-state ()
  "Write this buffer's view to `heisig-gt-kanji-state-file'."
  (interactive nil heisig-gt-kanji-mode)
  (setf (alist-get major-mode heisig-gt-kanji--state)
        (heisig-gt-kanji--state-capture))
  (with-demoted-errors "heisig-gt-kanji: cannot save state: %S"
    (with-temp-file heisig-gt-kanji-state-file
      (let ((print-level nil)
            (print-length nil))
        (prin1 heisig-gt-kanji--state (current-buffer))
        (insert "\n")))))

(defun heisig-gt-kanji--state-changed ()
  "Record the current view when state persistence is enabled."
  (when (and heisig-gt-kanji-persist-state
             (derived-mode-p 'heisig-gt-kanji-mode))
    (heisig-gt-kanji-save-state)))

(defun heisig-gt-kanji--tabulated-sort-observer (&rest _)
  "Record the view after a sort.
Sorting by clicking a column header never passes through a
command of this mode, so it is invisible to every other hook
`heisig-gt-kanji--state-changed' runs from."
  (heisig-gt-kanji--state-changed))

(advice-add 'tabulated-list-sort :after
            #'heisig-gt-kanji--tabulated-sort-observer)

;;;; Mode + keymap

(defvar-keymap heisig-gt-kanji-mode-map
  :doc "Keymap for `heisig-gt-kanji-mode'."
  :parent tabulated-list-mode-map
  "RET" #'heisig-gt-kanji-show
  "TAB" #'heisig-gt-kanji-show-other-window
  "o"   #'heisig-gt-kanji-show-other-window
  "w"   #'heisig-gt-kanji-words
  "M-w" #'heisig-gt-kanji-copy-char
  "s"   #'heisig-gt-kanji-sort-cycle
  "/"   #'heisig-gt-kanji-filter-by
  "D"   #'heisig-gt-kanji-filter-remove
  "c"   #'heisig-gt-kanji-toggle-column
  "C"   #'heisig-gt-kanji-set-columns
  "V"   #'heisig-gt-kanji-reset-view
  "g"   #'revert-buffer
  "q"   #'quit-window)

(define-derived-mode heisig-gt-kanji-mode tabulated-list-mode "Heisig-gt"
  "Major mode for the read-only kanji list buffer.

Each row is one kanji, or one of Heisig's primitives, narrowed by
any active filter.  No command in this mode writes anything: not
to the kanji database, not to the Anki collection.

Columns come from `heisig-gt-kanji-column-alist'.  Which of them
are displayed, and in what order, is `heisig-gt-kanji-columns';
change it for this buffer with \\[heisig-gt-kanji-toggle-column]
and \\[heisig-gt-kanji-set-columns].  A value wider than its
column is truncated and marked with an ellipsis, except in the
last column, which takes the rest of the line and is shown in
full.

The Status, Ivl, Reps, Laps and Due columns come from the Anki
collection, re-read on every \\[revert-buffer].  When it cannot
be read the columns are empty and the mode line says why; nothing
else is affected.

Row-scoped commands (act on the kanji at point):
  \\[heisig-gt-kanji-show] show it in detail
  \\[heisig-gt-kanji-show-other-window] show it in the other window
  \\[heisig-gt-kanji-words] list the words written with it
  \\[heisig-gt-kanji-copy-char] copy the character to the kill ring

Buffer-scoped commands:
  \\[heisig-gt-kanji-filter-by] filter (see below)
  \\[universal-argument] \\[heisig-gt-kanji-filter-by] filter out (negated)
  \\[heisig-gt-kanji-filter-remove] remove one filter
  \\[heisig-gt-kanji-toggle-column] show or hide one column
  \\[heisig-gt-kanji-set-columns] choose the column set and order
  \\[heisig-gt-kanji-sort-cycle] cycle the sort column
  \\[heisig-gt-kanji-reset-view] reset the view to defaults
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

Sorting: click a column header, or press \\[heisig-gt-kanji-sort-cycle]
to cycle through the sortable columns.

\\{heisig-gt-kanji-mode-map}"
  (setq heisig-gt-kanji--columns (heisig-gt-kanji--columns-default))
  ;; No leading gutter: that column exists in a list buffer to hold
  ;; mark characters, and this buffer is read only.  With padding the
  ;; first column would start one column in, against the left edge of
  ;; every other Emacs list buffer.
  (setq tabulated-list-padding 0)
  (setq tabulated-list-entries #'heisig-gt-kanji--entries)
  (setq-local revert-buffer-function #'heisig-gt-kanji--revert)
  (setq-local bookmark-make-record-function #'heisig-gt-kanji--make-record)
  (setq-local mode-line-process '(:eval (heisig-gt-kanji--mode-line)))
  (unless heisig-gt-kanji--state-loaded
    (heisig-gt-kanji--state-load))
  (heisig-gt-kanji--state-apply)
  (setq tabulated-list-format (heisig-gt-kanji--format))
  (setq tabulated-list-sort-key
        (heisig-gt-kanji--valid-sort-key
         (or tabulated-list-sort-key (heisig-gt-kanji--sort-key-default))))
  (tabulated-list-init-header))

;;;; Refresh

(defun heisig-gt-kanji--reload-kanji ()
  "Re-read the kanji list and the Anki study data."
  (heisig-gt-db-reload-study)
  (heisig-gt-db-kanji-list))

(defun heisig-gt-kanji--reload ()
  "Re-read this buffer's records into the cache."
  (setq heisig-gt-kanji--records
        (funcall (or heisig-gt-kanji--reload-function
                     #'heisig-gt-kanji--reload-kanji))))

(defun heisig-gt-kanji--record-id (record)
  "Return the identity string of RECORD."
  (when record
    (funcall (or heisig-gt-kanji--id-function
                 (lambda (r) (plist-get r :char)))
             record)))

(defun heisig-gt-kanji--id-at-point ()
  "Return the identity of the record on the current line, or nil."
  (heisig-gt-kanji--record-id (tabulated-list-get-id)))

(defun heisig-gt-kanji--char-at-point ()
  "Return the identity of the record on the current line, or nil."
  (heisig-gt-kanji--id-at-point))

(defun heisig-gt-kanji--goto-char-row (id)
  "Move point to the first row whose record identity is ID.
No-op when ID is nil; falls back to `point-min' when no row
matches, which is the case once a filter has removed the row."
  (when id
    (goto-char (point-min))
    (let ((found nil))
      (while (and (not (eobp)) (not found))
        (if (equal (heisig-gt-kanji--id-at-point) id)
            (setq found t)
          (forward-line 1)))
      (unless found (goto-char (point-min))))))

(defun heisig-gt-kanji--redraw-preserving-point ()
  "Rebuild the header and redraw, keeping point on the same kanji.
Looks the row up by character: the records are built fresh on
every read, so the character is the only identity that survives a
revert.  The row's visual offset from `window-start' is restored
as well."
  (let* ((win (get-buffer-window (current-buffer)))
         (visual-line (and win
                           (count-lines (window-start win)
                                        (line-beginning-position))))
         (char (heisig-gt-kanji--char-at-point)))
    (setq tabulated-list-format (heisig-gt-kanji--format))
    (setq tabulated-list-sort-key
          (heisig-gt-kanji--valid-sort-key tabulated-list-sort-key))
    (tabulated-list-init-header)
    (tabulated-list-print t)
    (unless (equal (heisig-gt-kanji--char-at-point) char)
      (heisig-gt-kanji--goto-char-row char))
    (when (and win visual-line (window-live-p win))
      (with-selected-window win
        (recenter visual-line)))))

(defun heisig-gt-kanji--revert (&rest _args)
  "Revert function for the kanji list buffer.
Re-reads the kanji list and the Anki study data, then redraws."
  (heisig-gt-kanji--reload)
  (heisig-gt-kanji--redraw-preserving-point))

;;;; Interactive entry point

(defun heisig-gt-kanji--go-to (char)
  "Put point on CHAR's row, reporting when there is no row to go to.

Two ways it can be missing, and they call for different answers:
a character with no entry at all is not going to appear however
the view is changed, while one the active filters exclude is
there and hidden.  Saying which saves the reader from hunting for
a row that was never coming."
  (when (and char (not (string-empty-p char)))
    (let ((before (point)))
      (heisig-gt-kanji--goto-char-row char)
      (cond
       ((equal (heisig-gt-kanji--id-at-point) char) t)
       (t
        ;; `--goto-char-row' falls back to `point-min' when it finds
        ;; nothing; nobody asked to be moved there.
        (goto-char before)
        (message
         (cond
          ((not (heisig-gt-db-known-p char))
           (format "%s is not in the database" char))
          (heisig-gt-kanji--filters
           (format "%s is hidden by the active filters (%s)" char
                   (mapconcat #'heisig-gt-kanji--filter-description
                              heisig-gt-kanji--filters " ")))
          (t (format "%s has no row" char))))
        nil)))))

;;;###autoload
(defun heisig-gt-kanji (&optional char)
  "Display the read-only kanji list buffer.

With CHAR, put point on that character's row.  When it has no row
-- because the database has no entry for it, or because the
active filters exclude it -- point is left alone and a message
says which.  Interactively, CHAR is read only when a prefix
argument is given.

When the buffer already exists and is in `heisig-gt-kanji-mode',
reuse it: sort key, filters and displayed columns are preserved,
and the data is re-read.  When creating the buffer, initial view
state comes from `heisig-gt-kanji-state-file' when
`heisig-gt-kanji-persist-state' is enabled, otherwise from the
mode defaults."
  (interactive
   (list (when current-prefix-arg (read-string "Kanji: "))))
  (let ((buf (get-buffer-create heisig-gt-kanji-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'heisig-gt-kanji-mode)
        (heisig-gt-kanji-mode))
      (heisig-gt-kanji--reload)
      (heisig-gt-kanji--redraw-preserving-point)
      (heisig-gt-kanji--go-to char))
    (pop-to-buffer-same-window buf)))

;; The command and the bookmark handler were `heisig-gt-list' and
;; `heisig-gt-list-bookmark-jump' until the word list arrived and made
;; "the list" ambiguous.  The handler alias matters most: a bookmark
;; saved under the old name stores that symbol, and jumping to it
;; would otherwise fail.

;;;###autoload
(define-obsolete-function-alias 'heisig-gt-list #'heisig-gt-kanji "0.2")

;;;; Cursor -> kanji lookup

(defun heisig-gt-kanji--record-at-point ()
  "Return the kanji record on the current line, or nil."
  (tabulated-list-get-id))

(defun heisig-gt-kanji--require-kanji ()
  "Return the kanji record on the current line, or signal."
  (or (heisig-gt-kanji--record-at-point)
      (user-error "No kanji on this line")))

;;;; Row commands

(defun heisig-gt-kanji-show ()
  "Show the kanji at point in the detail buffer."
  (interactive nil heisig-gt-kanji-mode)
  (heisig-gt-detail-show (plist-get (heisig-gt-kanji--require-kanji) :char)))

(defun heisig-gt-kanji-show-other-window ()
  "Show the kanji at point in the detail buffer, keeping point here."
  (interactive nil heisig-gt-kanji-mode)
  (let ((char (plist-get (heisig-gt-kanji--require-kanji) :char))
        (win (selected-window)))
    (heisig-gt-detail-show char t)
    (select-window win)))

(declare-function heisig-gt-words "heisig-gt-words" (&optional chars))

(defun heisig-gt-kanji-words ()
  "Show the words written with the kanji at point."
  (interactive nil heisig-gt-kanji-mode)
  (heisig-gt-words (plist-get (heisig-gt-kanji--require-kanji) :char)))

(defun heisig-gt-kanji-copy-char ()
  "Copy the character at point to the kill ring."
  (interactive nil heisig-gt-kanji-mode)
  (let ((char (plist-get (heisig-gt-kanji--require-kanji) :char)))
    (kill-new char)
    (message "Copied %s" char)))

;;;; Sorting

(defun heisig-gt-kanji-sort-cycle ()
  "Sort by the next sortable column, wrapping at the end.
Always ascending; click a column header to reverse it."
  (interactive nil heisig-gt-kanji-mode)
  (let* ((sortable (heisig-gt-kanji--sortable-columns))
         (current (car tabulated-list-sort-key))
         (position (and current (seq-position sortable current)))
         (next (nth (if position
                        (mod (1+ position) (length sortable))
                      0)
                    sortable)))
    (unless sortable
      (user-error "No sortable column is displayed"))
    (setq tabulated-list-sort-key (cons next nil))
    (heisig-gt-kanji--redraw-preserving-point)
    (heisig-gt-kanji--state-changed)
    (message "Sorted by %s" next)))

;;;; Columns

(defun heisig-gt-kanji--read-column (prompt)
  "Read a column key with PROMPT, completing on the registry."
  (intern (completing-read prompt
                           (mapcar #'symbol-name
                                   (heisig-gt-kanji--column-keys))
                           nil t)))

(defun heisig-gt-kanji-toggle-column (key)
  "Show column KEY when it is hidden, hide it when it is shown.
A column being shown again returns to its registry position, not
to the end of the line."
  (interactive (list (heisig-gt-kanji--read-column "Toggle column: "))
               heisig-gt-kanji-mode)
  (heisig-gt-kanji--column key)
  (setq heisig-gt-kanji--columns
        (if (memq key heisig-gt-kanji--columns)
            (delq key (copy-sequence heisig-gt-kanji--columns))
          ;; Re-derived from the registry rather than appended, so
          ;; the column comes back where it belongs.
          (seq-filter (lambda (k)
                        (or (eq k key) (memq k heisig-gt-kanji--columns)))
                      (heisig-gt-kanji--column-keys))))
  (heisig-gt-kanji--redraw-preserving-point)
  (heisig-gt-kanji--state-changed))

(defun heisig-gt-kanji-set-columns (keys)
  "Display exactly the columns KEYS, in the order given.
The current selection is offered as editable initial input, so
this is also how to reorder columns."
  (interactive
   (list (mapcar #'intern
                 (completing-read-multiple
                  "Columns (in order): "
                  (mapcar #'symbol-name (heisig-gt-kanji--column-keys))
                  nil t
                  (mapconcat #'symbol-name heisig-gt-kanji--columns ","))))
   heisig-gt-kanji-mode)
  (mapc #'heisig-gt-kanji--column keys)
  (unless keys
    (user-error "At least one column is needed"))
  (setq heisig-gt-kanji--columns keys)
  (heisig-gt-kanji--redraw-preserving-point)
  (heisig-gt-kanji--state-changed))

;;;; Reset

(defun heisig-gt-kanji-reset-view ()
  "Clear every filter and restore the default columns and sort key."
  (interactive nil heisig-gt-kanji-mode)
  (setq heisig-gt-kanji--filters nil)
  (setq heisig-gt-kanji--columns (heisig-gt-kanji--columns-default))
  (setq tabulated-list-sort-key
        (heisig-gt-kanji--valid-sort-key (heisig-gt-kanji--sort-key-default)))
  (heisig-gt-kanji--redraw-preserving-point)
  (heisig-gt-kanji--state-changed)
  (message "View reset"))

;;;; Bookmarking a view

(defcustom heisig-gt-kanji-bookmark-prefix "Kanji"
  "Prefix of the name \\[bookmark-set] offers for a kanji list view."
  :type 'string
  :group 'heisig-gt)

(defun heisig-gt-kanji--bookmark-name ()
  "Return the default bookmark name for this buffer's view.
The active filters are part of the name, so several saved views
do not all land on the same default."
  (if heisig-gt-kanji--filters
      (format "%s: %s" heisig-gt-kanji-bookmark-prefix
              (mapconcat #'heisig-gt-kanji--filter-description
                         heisig-gt-kanji--filters " "))
    heisig-gt-kanji-bookmark-prefix))

(defun heisig-gt-kanji--make-record ()
  "Return a bookmark record for this buffer's view.
What is stored is the view -- columns, filters, sort key -- and
not a position: the row a position named may not exist the next
time the data is read."
  `((handler . ,(or heisig-gt-kanji--bookmark-handler
                    #'heisig-gt-kanji-bookmark-jump))
    (defaults . (,(heisig-gt-kanji--bookmark-name)))
    (seed . ,(bound-and-true-p heisig-gt-words--seed))
    (columns . ,heisig-gt-kanji--columns)
    (filters . ,heisig-gt-kanji--filters)
    (sort-key . ,tabulated-list-sort-key)))

;;;###autoload
(defun heisig-gt-kanji-bookmark-jump (bookmark)
  "Restore the kanji list view stored in BOOKMARK."
  (heisig-gt-kanji)
  (with-current-buffer heisig-gt-kanji-buffer-name
    (setq heisig-gt-kanji--columns
          (or (bookmark-prop-get bookmark 'columns)
              heisig-gt-kanji-columns))
    (setq heisig-gt-kanji--filters (bookmark-prop-get bookmark 'filters))
    (setq tabulated-list-sort-key
          (heisig-gt-kanji--valid-sort-key
           (bookmark-prop-get bookmark 'sort-key)))
    (heisig-gt-kanji--redraw-preserving-point)))

;;;; Filter

(defun heisig-gt-kanji-filter-by (key &optional negate)
  "Add the filter KEY to the current buffer.
KEY is read from `heisig-gt-kanji-filter-alist'.  Its reader may
return several values, and a kanji matches the filter when any
one of them matches, so several JLPT levels widen the selection.

The filter is ADDED, not substituted: applying the same key again
narrows further rather than replacing what is already in force.
Remove one with `heisig-gt-kanji-filter-remove'.

With a prefix argument, NEGATE is non-nil and the filter selects
exactly the kanji it would otherwise reject.

The special KEY `unfilter' clears every active filter."
  (interactive
   (let ((choices (cons '(unfilter
                          :name "Unfilter"
                          :doc "Clear every active filter.")
                        (heisig-gt-kanji--filters-registry))))
     (list (intern (completing-read
                    (if current-prefix-arg "Filter out by: " "Filter by: ")
                    (mapcar (lambda (e) (symbol-name (car e))) choices)
                    nil t))
           current-prefix-arg))
   heisig-gt-kanji-mode)
  (if (eq key 'unfilter)
      (setq heisig-gt-kanji--filters nil)
    (let* ((entry (or (alist-get key (heisig-gt-kanji--filters-registry))
                      (user-error "Unknown filter: %s" key)))
           (values (funcall (plist-get entry :reader)))
           (filter (list :key key :values values :negate (and negate t))))
      (unless values
        (user-error "No value given; filter not added"))
      ;; An identical filter would narrow nothing and clutter the
      ;; indicator, so adding one again is a no-op rather than a
      ;; duplicate row in the list.
      (unless (member filter heisig-gt-kanji--filters)
        (setq heisig-gt-kanji--filters
              (append heisig-gt-kanji--filters (list filter))))))
  (heisig-gt-kanji--redraw-preserving-point)
  (heisig-gt-kanji--state-changed))

(defun heisig-gt-kanji-filter-remove (description)
  "Remove the single active filter named DESCRIPTION.
Completion offers the filters currently in force, in the form the
mode line shows them.  Use `heisig-gt-kanji-reset-view' to clear
all of them at once."
  (interactive
   (progn
     (unless heisig-gt-kanji--filters
       (user-error "No active filters"))
     (list (completing-read
            "Remove filter: "
            (mapcar #'heisig-gt-kanji--filter-description
                    heisig-gt-kanji--filters)
            nil t)))
   heisig-gt-kanji-mode)
  (setq heisig-gt-kanji--filters
        (seq-remove (lambda (filter)
                      (equal description
                             (heisig-gt-kanji--filter-description filter)))
                    heisig-gt-kanji--filters))
  (heisig-gt-kanji--redraw-preserving-point)
  (heisig-gt-kanji--state-changed)
  (message "Removed filter: %s" description))

;;;; Numeric ranges for the frame, stroke and frequency searches
;;
;; A range is stored as the string the user typed and parsed when it
;; is applied, so a bookmarked view records "800," rather than the
;; 1200 frames that happened to satisfy it on the day it was saved.

(defconst heisig-gt-kanji--range-regexp
  (rx bos (* space)
      (group (* digit)) (* space)
      (? "," (* space) (group (* digit)) (* space))
      eos)
  "Shape of a range: \"FROM,TO\", or a single number for an exact match.
Either side of the comma may be empty, leaving that end unbounded.")

(defun heisig-gt-kanji--range-bounds (spec)
  "Return the (FROM . TO) bounds of the range SPEC, or nil when invalid.
Either bound is nil when that end is unbounded."
  (when (and (stringp spec) (string-match heisig-gt-kanji--range-regexp spec))
    (let* ((from (match-string 1 spec))
           (to (match-string 2 spec))
           (low (unless (string-empty-p from) (string-to-number from))))
      (cond
       ;; "15" with no comma is an exact match, not "15 and up": a
       ;; single number reads as one value, and a range that quietly
       ;; became open-ended would return most of the table.
       ((null to) (and low (cons low low)))
       (t (cons low (unless (string-empty-p to) (string-to-number to))))))))

(defun heisig-gt-kanji--in-range-p (value spec)
  "Return non-nil when VALUE falls inside the range SPEC.
A nil VALUE is outside every range: an unknown stroke count is
not a stroke count of zero."
  (when-let* ((value value)
              (bounds (heisig-gt-kanji--range-bounds spec)))
    (and (or (null (car bounds)) (>= value (car bounds)))
         (or (null (cdr bounds)) (<= value (cdr bounds))))))

(defun heisig-gt-kanji--read-range (prompt)
  "Read a range with PROMPT, returning it as a one-element list.
Rejects anything `heisig-gt-kanji--range-bounds' cannot parse, so
a typo is refused at the prompt rather than silently matching
nothing."
  (let ((spec (read-string (format "%s (FROM,TO or N): " prompt))))
    (unless (heisig-gt-kanji--range-bounds spec)
      (user-error "Not a range: %s" spec))
    (list spec)))

(defun heisig-gt-kanji--values-of (field)
  "Return the distinct non-nil values of FIELD in the cached kanji.
Offering what the buffer actually holds keeps the completion
candidates honest: a level no row carries would produce an empty
buffer with no indication why."
  (sort (delete-dups (delq nil (mapcar (lambda (kanji)
                                         (plist-get kanji field))
                                       heisig-gt-kanji--records)))
        #'value<))

;;;; Built-in filter entries

(defun heisig-gt-kanji--read-numbers (prompt field)
  "Read several values of FIELD with PROMPT, completing on what is there."
  (mapcar #'string-to-number
          (completing-read-multiple
           prompt
           (mapcar #'number-to-string (heisig-gt-kanji--values-of field))
           nil t)))

(add-to-list 'heisig-gt-kanji-filter-alist
             (cons 'by-jlpt
                   (list :name "JLPT"
                         :reader (lambda ()
                                   (heisig-gt-kanji--read-numbers
                                    "JLPT levels (comma-separated): " :jlpt))
                         :predicate (lambda (kanji level)
                                      (equal level (plist-get kanji :jlpt)))
                         :doc "Show only kanji at one of the chosen JLPT \
levels.")))

(add-to-list 'heisig-gt-kanji-filter-alist
             (cons 'by-grade
                   (list :name "Grade"
                         :reader (lambda ()
                                   (heisig-gt-kanji--read-numbers
                                    "Grades (comma-separated): " :grade))
                         :predicate (lambda (kanji grade)
                                      (equal grade (plist-get kanji :grade)))
                         :doc "Show only kanji taught in one of the chosen \
school grades.")))

(add-to-list 'heisig-gt-kanji-filter-alist
             (cons 'by-kind
                   (list :name "Kind"
                         :reader (lambda ()
                                   (completing-read-multiple
                                    "Kinds: " '("kanji" "primitive") nil t))
                         :predicate (lambda (kanji kind)
                                      (equal kind (plist-get kanji :kind)))
                         :doc "Show only kanji, or only Heisig primitives.")))

(add-to-list 'heisig-gt-kanji-filter-alist
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
                               (null (heisig-gt-kanji-status kanji))
                             (eq status (heisig-gt-kanji-status kanji))))
                         :doc "Show only kanji in one of the chosen Anki \
queues; `none' is those Anki does not have.")))

(add-to-list 'heisig-gt-kanji-filter-alist
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

(add-to-list 'heisig-gt-kanji-filter-alist
             (cons 'by-radical
                   (list :name "Radical"
                         :reader (lambda ()
                                   (completing-read-multiple
                                    "Radicals: "
                                    (heisig-gt-kanji--values-of :radical)
                                    nil t))
                         :predicate (lambda (kanji radical)
                                      (equal radical
                                             (plist-get kanji :radical)))
                         :doc "Show only kanji under one of the chosen \
radicals.")))

(add-to-list 'heisig-gt-kanji-filter-alist
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

(add-to-list 'heisig-gt-kanji-filter-alist
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

(add-to-list 'heisig-gt-kanji-filter-alist
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

(add-to-list 'heisig-gt-kanji-filter-alist
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

(add-to-list 'heisig-gt-kanji-filter-alist
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

(add-to-list 'heisig-gt-kanji-filter-alist
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
                                           (heisig-gt-kanji--keyword kanji)))
                         :doc "Show only kanji whose keyword matches a \
regexp.")))

(add-to-list 'heisig-gt-kanji-filter-alist
             (cons 'by-meaning-regexp
                   (list :name "Meaning regexp"
                         :reader (lambda ()
                                   (list (read-regexp "Meaning matches")))
                         :predicate
                         (lambda (kanji regexp)
                           (string-match-p regexp
                                           (heisig-gt-kanji--meanings kanji)))
                         :doc "Show only kanji whose meanings match a \
regexp.")))

(add-to-list 'heisig-gt-kanji-filter-alist
             (cons 'by-frame
                   (list :name "Frame"
                         :reader (lambda ()
                                   (heisig-gt-kanji--read-range "Frames"))
                         :predicate
                         (lambda (kanji spec)
                           (heisig-gt-kanji--in-range-p
                            (plist-get kanji :heisig6) spec))
                         :doc "Show only kanji in a range of Heisig \
frames.")))

(add-to-list 'heisig-gt-kanji-filter-alist
             (cons 'by-strokes
                   (list :name "Strokes"
                         :reader (lambda ()
                                   (heisig-gt-kanji--read-range "Strokes"))
                         :predicate
                         (lambda (kanji spec)
                           (heisig-gt-kanji--in-range-p
                            (plist-get kanji :strokes) spec))
                         :doc "Show only kanji in a range of stroke \
counts.")))

(add-to-list 'heisig-gt-kanji-filter-alist
             (cons 'by-freq
                   (list :name "Frequency"
                         :reader (lambda ()
                                   (heisig-gt-kanji--read-range
                                    "Frequency ranks"))
                         :predicate
                         (lambda (kanji spec)
                           (heisig-gt-kanji--in-range-p
                            (plist-get kanji :freq-rank) spec))
                         :doc "Show only kanji in a range of frequency \
ranks.")))

;;;###autoload
(define-obsolete-function-alias 'heisig-gt-list-bookmark-jump
  #'heisig-gt-kanji-bookmark-jump "0.2")

(provide 'heisig-gt-kanji)

;;; heisig-gt-kanji.el ends here
