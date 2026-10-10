;;; heisig-gt-test-helper.el --- Fixtures for the heisig-gt suite  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Both fixtures are generated, not committed: tools/make-test-fixture.py
;; writes a miniature Anki collection and tools/build-heisig-db.py
;; merges it with test/fixtures/mini-kanji.json.  `make test' builds
;; them first.  Generating rather than committing means the suite reads
;; a database produced by the same builder the user runs, so a schema
;; the reader and the builder disagree about fails here.
;;
;; No test touches the user's own database or Anki collection.

;;; Code:

(require 'ert)
(require 'heisig-gt-kanji)

(defconst heisig-gt-test-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory this file lives in.")

(defconst heisig-gt-test-db
  (expand-file-name "fixtures/mini-heisig.db" heisig-gt-test-directory)
  "Miniature kanji database the suite reads.")

(defconst heisig-gt-test-anki
  (expand-file-name "fixtures/mini-collection.anki2"
                    heisig-gt-test-directory)
  "Miniature Anki collection the suite reads study progress from.")

(defun heisig-gt-test-require-fixtures ()
  "Signal unless both fixtures exist, naming how to build them."
  (dolist (file (list heisig-gt-test-db heisig-gt-test-anki))
    (unless (file-readable-p file)
      (error "Missing fixture %s; run `make test' to build it" file))))

(defmacro heisig-gt-test-with-db (&rest body)
  "Run BODY against the fixture database and Anki collection.
Every cache is dropped before and after, so one test cannot see
what another left behind."
  (declare (indent 0) (debug t))
  `(progn
     (heisig-gt-test-require-fixtures)
     (let ((heisig-gt-db-file heisig-gt-test-db)
           (heisig-gt-anki-file heisig-gt-test-anki)
           (heisig-gt-anki-decks '("jp::kanjiMigaku" "jp::kanjiAcademy")))
       (unwind-protect
           (progn
             (heisig-gt-db-close)
             (setq heisig-gt-db--study-table nil)
             ,@body)
         (heisig-gt-db-close)
         (setq heisig-gt-db--study-table nil)
         (setq heisig-gt-db-study-unavailable nil)))))

(defun heisig-gt-test-view-restored (mode view)
  "Return what VIEW amounts to once restored into a MODE buffer.

The shown row count, the displayed columns, the sort key, and the
view the buffer then reports -- which together are everything two
stores of one view have to agree about.  Reporting the view
through `heisig-gt-kanji--view-capture\' rather than naming its
fields keeps this helper ignorant of what any one mode adds to a
view, so a mode that adds another field is covered without
touching it.

This is the harness for a verified bug: a word buffer's seed was
kept by a bookmark and dropped by the state file, and one view
restored as 74 rows through one path and 20000 through the other.
It is one function because three copies of it could drift, and a
drifting guard on a fixed bug is worse than none."
  (with-temp-buffer
    (funcall mode)
    (heisig-gt-kanji--view-apply view)
    (heisig-gt-kanji--reload)
    (heisig-gt-kanji--redraw-preserving-point)
    (list :shown heisig-gt-kanji--shown
          :columns heisig-gt-kanji--columns
          :sort-key tabulated-list-sort-key
          :view (heisig-gt-kanji--view-capture))))

(provide 'heisig-gt-test-helper)

;;; heisig-gt-test-helper.el ends here
