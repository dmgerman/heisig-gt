;;; test-heisig-gt-list.el --- Tests for heisig-gt-list  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The list buffer: its column registry, its rendering, its filters
;; and its sort keys.

;;; Code:

(require 'ert)
(require 'heisig-gt-list)
(require 'heisig-gt-test-helper)

(defmacro heisig-gt-list-test-with-buffer (&rest body)
  "Run BODY in a fresh list buffer filled from the fixtures."
  (declare (indent 0) (debug t))
  `(heisig-gt-test-with-db
     (let ((buffer (generate-new-buffer " *heisig-gt-test-list*"))
           ;; Persistence is off so a test cannot write the
           ;; developer's state file.
           (heisig-gt-list-persist-state nil)
           (heisig-gt-list--state nil)
           (heisig-gt-list--state-loaded t))
       (unwind-protect
           (with-current-buffer buffer
             (heisig-gt-list-mode)
             (heisig-gt-list--reload)
             (heisig-gt-list--redraw-preserving-point)
             ,@body)
         (kill-buffer buffer)))))

(defun heisig-gt-list-test-column (key)
  "Return the cell text of column KEY on the current line."
  (heisig-gt-list--cell (tabulated-list-get-id) key))

;;;; Column registry

(ert-deftest heisig-gt-list-test-unknown-column-signals ()
  "Asking for a column that is not registered is an error."
  (should-error (heisig-gt-list--column 'nonesuch) :type 'user-error))

(ert-deftest heisig-gt-list-test-column-width-override ()
  "`heisig-gt-list-column-widths' beats the registry."
  (should (= (heisig-gt-list--column-width 'keyword) 22))
  (let ((heisig-gt-list-column-widths '((keyword . 4))))
    (should (= (heisig-gt-list--column-width 'keyword) 4))))

(ert-deftest heisig-gt-list-test-visible-columns-drop-unknown-keys ()
  "A key with no registry entry is ignored, not shown as a gap."
  (let ((heisig-gt-list--columns '(char nonesuch keyword)))
    (should (equal (heisig-gt-list--visible-columns) '(char keyword)))))

(ert-deftest heisig-gt-list-test-visible-columns-never-empty ()
  "A selection that names nothing still leaves one column."
  (let ((heisig-gt-list--columns nil))
    (should (= 1 (length (heisig-gt-list--visible-columns))))))

(ert-deftest heisig-gt-list-test-last-column-takes-the-rest-of-the-line ()
  "The last column is declared with width 0 and is never truncated."
  (let ((heisig-gt-list--columns '(char keyword meanings)))
    (let ((format (heisig-gt-list--format)))
      (should (= (length format) 3))
      (should (= (nth 1 (aref format 0)) 5))
      (should (= (nth 1 (aref format 2)) 0)))))

;;;; Rendering

(ert-deftest heisig-gt-list-test-cell-truncates-to-display-width ()
  "Truncation counts display columns, so a kanji costs two of them."
  (heisig-gt-test-with-db
    (let ((kanji (heisig-gt-db-kanji "一"))
          (heisig-gt-list-column-widths '((meanings . 4))))
      (should (= 2 (string-width (heisig-gt-list--cell kanji 'char))))
      ;; "one" fits; a longer value would come back marked.
      (should (equal (heisig-gt-list--cell kanji 'meanings) "one")))
    (let ((kanji (heisig-gt-db-kanji "森"))
          (heisig-gt-list-column-widths '((meanings . 6))))
      (should (= 6 (string-width (heisig-gt-list--cell kanji 'meanings))))
      (should-not (equal (heisig-gt-list--cell kanji 'meanings)
                         (plist-get kanji :meanings)))
      ;; With EXPAND it is left whole, which is what the last column
      ;; gets.
      (should (equal (heisig-gt-list--cell kanji 'meanings t)
                     "forest,woods")))))

(ert-deftest heisig-gt-list-test-component-keywords-column ()
  "The column names the components in the order they are written."
  (heisig-gt-test-with-db
    (should (equal (heisig-gt-list--cell (heisig-gt-db-kanji "一")
                                         'component-keywords)
                   "one"))
    (should (equal (heisig-gt-list--cell (heisig-gt-db-kanji "肉")
                                         'component-keywords)
                   "apron"))
    ;; A kanji with no components at all leaves the cell empty.
    (should (equal (heisig-gt-list--cell (heisig-gt-db-kanji "[apron]")
                                         'component-keywords)
                   ""))))

(ert-deftest heisig-gt-list-test-empty-cells-are-empty ()
  "A column with nothing to show renders as nothing."
  (heisig-gt-test-with-db
    (let ((forest (heisig-gt-db-kanji "森")))
      (should (equal (heisig-gt-list--cell forest 'heisig) ""))
      (should (equal (heisig-gt-list--cell forest 'jlpt) ""))
      (should (equal (heisig-gt-list--cell forest 'strokes) "")))))

(ert-deftest heisig-gt-list-test-jlpt-is-written-as-a-level ()
  "The JLPT column reads N5, not 5."
  (heisig-gt-test-with-db
    (should (equal (heisig-gt-list--jlpt (heisig-gt-db-kanji "一")) "N5"))))

(ert-deftest heisig-gt-list-test-buffer-renders-every-row ()
  "Every kanji in the database gets a row."
  (heisig-gt-list-test-with-buffer
    (should (= heisig-gt-list--total 5))
    (should (= heisig-gt-list--shown 5))
    (goto-char (point-min))
    (should (equal (heisig-gt-list--char-at-point) "一"))))

;;;; Filters

(defun heisig-gt-list-test-apply (key values &optional negate)
  "Apply the filter KEY over VALUES, optionally NEGATE it, and redraw."
  (setq heisig-gt-list--filters
        (list (list :key key :values values :negate negate)))
  (heisig-gt-list--redraw-preserving-point)
  heisig-gt-list--shown)

(ert-deftest heisig-gt-list-test-filter-selects ()
  "A filter keeps the rows its predicate accepts."
  (heisig-gt-list-test-with-buffer
    (should (= 1 (heisig-gt-list-test-apply 'by-kind '("primitive"))))
    (should (= 4 (heisig-gt-list-test-apply 'by-kind '("kanji"))))))

(ert-deftest heisig-gt-list-test-filter-values-widen ()
  "Values within one filter are an OR."
  (heisig-gt-list-test-with-buffer
    (should (= 1 (heisig-gt-list-test-apply 'by-jlpt '(5))))
    (should (= 2 (heisig-gt-list-test-apply 'by-jlpt '(4))))
    ;; The union of the two, not either one.
    (should (= 3 (heisig-gt-list-test-apply 'by-jlpt '(5 4))))))

(ert-deftest heisig-gt-list-test-filters-narrow ()
  "Separate filters are an AND."
  (heisig-gt-list-test-with-buffer
    (setq heisig-gt-list--filters
          (list (list :key 'by-kind :values '("kanji") :negate nil)
                (list :key 'by-jlpt :values '(5) :negate nil)))
    (heisig-gt-list--redraw-preserving-point)
    (should (= heisig-gt-list--shown 1))))

(ert-deftest heisig-gt-list-test-filter-negation ()
  "A negated filter keeps exactly what it would otherwise drop."
  (heisig-gt-list-test-with-buffer
    (should (= 1 (heisig-gt-list-test-apply 'by-kind '("primitive"))))
    (should (= 4 (heisig-gt-list-test-apply 'by-kind '("primitive") t)))))

(ert-deftest heisig-gt-list-test-unregistered-filter-narrows-nothing ()
  "A filter left over from a removed registration empties nothing."
  (heisig-gt-list-test-with-buffer
    (should (= 5 (heisig-gt-list-test-apply 'by-nonesuch '("x"))))))

(ert-deftest heisig-gt-list-test-filter-by-component ()
  "The component filter reads the graph, not the character."
  (heisig-gt-list-test-with-buffer
    (should (= 1 (heisig-gt-list-test-apply 'by-component '("[apron]"))))
    (goto-char (point-min))
    (should (equal (heisig-gt-list--char-at-point) "肉"))))

(ert-deftest heisig-gt-list-test-filter-by-component-keyword ()
  "The keyword filter reaches the same rows as the character one."
  (heisig-gt-list-test-with-buffer
    ;; 肉 is built from [apron], whose name is "apron".
    (should (= 1 (heisig-gt-list-test-apply 'by-component-keyword
                                            '("apron"))))
    (goto-char (point-min))
    (should (equal (heisig-gt-list--char-at-point) "肉"))
    ;; Either side of the Comp keywords column selects the same row.
    (should (= 1 (heisig-gt-list-test-apply 'by-component '("[apron]"))))
    ;; Values widen, as in every other filter.
    (should (= 2 (heisig-gt-list-test-apply 'by-component-keyword
                                            '("apron" "one"))))
    (should (= 0 (heisig-gt-list-test-apply 'by-component-keyword
                                            '("nonesuch"))))))

(ert-deftest heisig-gt-list-test-reading-columns ()
  "Each reading kind is shown in both scripts."
  (heisig-gt-test-with-db
    (let ((one (heisig-gt-db-kanji "一")))
      (should (equal (heisig-gt-list--cell one 'onyomi) "イチ"))
      (should (equal (heisig-gt-list--cell one 'onyomi-romaji) "ichi"))
      (should (equal (heisig-gt-list--cell one 'kunyomi) "ひと"))
      (should (equal (heisig-gt-list--cell one 'kunyomi-romaji) "hito")))
    ;; A primitive has no readings at all.
    (should (equal (heisig-gt-list--cell (heisig-gt-db-kanji "[apron]")
                                         'onyomi-romaji)
                   ""))))

(ert-deftest heisig-gt-list-test-readings-are-shown-by-default ()
  "All four reading columns are on, and all four precede Meanings."
  (dolist (key '(onyomi onyomi-romaji kunyomi kunyomi-romaji))
    (should (memq key heisig-gt-list-columns))
    (should (< (seq-position heisig-gt-list-columns key)
               (seq-position heisig-gt-list-columns 'meanings)))))

(ert-deftest heisig-gt-list-test-filter-by-reading ()
  "A reading filter takes either script and keeps the kinds apart."
  (heisig-gt-list-test-with-buffer
    (should (= 1 (heisig-gt-list-test-apply 'by-onyomi '("イチ"))))
    (should (= 1 (heisig-gt-list-test-apply 'by-onyomi '("ichi"))))
    (goto-char (point-min))
    (should (equal (heisig-gt-list--char-at-point) "一"))
    ;; An on reading does not match as a kun one.
    (should (= 0 (heisig-gt-list-test-apply 'by-kunyomi '("ichi"))))
    (should (= 1 (heisig-gt-list-test-apply 'by-kunyomi '("hito"))))
    ;; Values widen, as in every other filter.
    (should (= 2 (heisig-gt-list-test-apply 'by-kunyomi '("hito" "kawa"))))))

(ert-deftest heisig-gt-list-test-filter-by-used-in ()
  "The inverse filter selects a character's components."
  (heisig-gt-list-test-with-buffer
    (should (= 1 (heisig-gt-list-test-apply 'by-used-in '("肉"))))
    (goto-char (point-min))
    (should (equal (heisig-gt-list--char-at-point) "[apron]"))))

(ert-deftest heisig-gt-list-test-filter-by-status ()
  "Status comes from Anki, and `none' is what Anki does not have."
  (heisig-gt-list-test-with-buffer
    (should (= 1 (heisig-gt-list-test-apply 'by-status '(review))))
    (should (= 1 (heisig-gt-list-test-apply 'by-status '(suspended))))
    (should (= 1 (heisig-gt-list-test-apply 'by-status '(none))))))

(ert-deftest heisig-gt-list-test-filter-by-source ()
  "The source filter matches one name in the comma-separated list."
  (heisig-gt-list-test-with-buffer
    (should (= 3 (heisig-gt-list-test-apply 'by-source '("json"))))
    (should (= 3 (heisig-gt-list-test-apply 'by-source '("migaku"))))))

(ert-deftest heisig-gt-list-test-filter-description ()
  "The mode-line label drops the `by-' prefix and marks negation."
  (should (equal (heisig-gt-list--filter-description
                  '(:key by-jlpt :values (5 4) :negate nil))
                 "jlpt=5,4"))
  (should (equal (heisig-gt-list--filter-description
                  '(:key by-status :values (suspended) :negate t))
                 "!status=suspended")))

;;;; Ranges

(ert-deftest heisig-gt-list-test-range-bounds ()
  "Both ends of a range are optional; a bare number is exact."
  (should (equal (heisig-gt-list--range-bounds "1,10") '(1 . 10)))
  (should (equal (heisig-gt-list--range-bounds "800,") '(800 . nil)))
  (should (equal (heisig-gt-list--range-bounds ",50") '(nil . 50)))
  (should (equal (heisig-gt-list--range-bounds " 5 , 7 ") '(5 . 7)))
  (should (equal (heisig-gt-list--range-bounds ",") '(nil . nil)))
  ;; A single number is one value, not an open-ended range: reading
  ;; "15" as "15 and up" would return most of the table.
  (should (equal (heisig-gt-list--range-bounds "15") '(15 . 15))))

(ert-deftest heisig-gt-list-test-range-rejects-nonsense ()
  "Anything that is not a range is refused rather than matching all."
  (should (null (heisig-gt-list--range-bounds "a-b")))
  (should (null (heisig-gt-list--range-bounds "1,2,3")))
  (should (null (heisig-gt-list--range-bounds "-5"))))

(ert-deftest heisig-gt-list-test-in-range ()
  "An unknown value is outside every range, including an open one."
  (should (heisig-gt-list--in-range-p 5 "1,10"))
  (should-not (heisig-gt-list--in-range-p 50 "1,10"))
  (should (heisig-gt-list--in-range-p 900 "800,"))
  ;; An unknown stroke count is not a stroke count of zero.
  (should-not (heisig-gt-list--in-range-p nil ","))
  (should-not (heisig-gt-list--in-range-p 5 "bogus")))

(ert-deftest heisig-gt-list-test-filter-by-frame-range ()
  "The frame filter uses the range, and excludes the unnumbered."
  (heisig-gt-list-test-with-buffer
    (should (= 1 (heisig-gt-list-test-apply 'by-frame '("1,10"))))
    (should (= 2 (heisig-gt-list-test-apply 'by-frame '(","))))))

;;;; Sorting

(ert-deftest heisig-gt-list-test-numeric-columns-sort-numerically ()
  "10 follows 9, which sorting on the displayed text would not give."
  (heisig-gt-list-test-with-buffer
    (setq tabulated-list-sort-key '("Frame" . nil))
    (heisig-gt-list--redraw-preserving-point)
    (goto-char (point-min))
    (should (equal (heisig-gt-list--char-at-point) "一"))
    (forward-line 1)
    (should (equal (heisig-gt-list--char-at-point) "肉"))))

(ert-deftest heisig-gt-list-test-unknown-values-sort-last ()
  "A row with no value collects at one end instead of counting as 0."
  (heisig-gt-list-test-with-buffer
    (setq heisig-gt-list--columns '(char strokes keyword))
    (setq tabulated-list-sort-key '("Str" . nil))
    (heisig-gt-list--redraw-preserving-point)
    (goto-char (point-max))
    (forward-line -1)
    ;; 森's stroke count is unknown in every source.
    (should (equal (heisig-gt-list--char-at-point) "森"))))

(ert-deftest heisig-gt-list-test-sort-key-survives-hiding-its-column ()
  "Hiding the sorted column falls back instead of sorting on nothing."
  (heisig-gt-list-test-with-buffer
    (setq tabulated-list-sort-key '("Keyword" . nil))
    (heisig-gt-list-toggle-column 'keyword)
    (should-not (equal (car tabulated-list-sort-key) "Keyword"))
    (should (member (car tabulated-list-sort-key)
                    (heisig-gt-list--sortable-columns)))))

;;;; Columns

(ert-deftest heisig-gt-list-test-toggle-column-round-trip ()
  "A column comes back in registry position, not at the end."
  (heisig-gt-list-test-with-buffer
    (setq heisig-gt-list--columns '(heisig char keyword meanings))
    (heisig-gt-list-toggle-column 'char)
    (should (equal heisig-gt-list--columns '(heisig keyword meanings)))
    (heisig-gt-list-toggle-column 'char)
    (should (equal heisig-gt-list--columns '(heisig char keyword meanings)))))

(ert-deftest heisig-gt-list-test-set-columns-keeps-the-order-given ()
  "Reordering is the same operation as choosing."
  (heisig-gt-list-test-with-buffer
    (heisig-gt-list-set-columns '(meanings char))
    (should (equal heisig-gt-list--columns '(meanings char)))
    (should-error (heisig-gt-list-set-columns nil) :type 'user-error)
    (should-error (heisig-gt-list-set-columns '(nonesuch))
                  :type 'user-error)))

(ert-deftest heisig-gt-list-test-reset-view ()
  "Resetting clears the filters and restores the defaults."
  (heisig-gt-list-test-with-buffer
    (heisig-gt-list-test-apply 'by-kind '("primitive"))
    (heisig-gt-list-set-columns '(char))
    (heisig-gt-list-reset-view)
    (should (null heisig-gt-list--filters))
    (should (equal heisig-gt-list--columns heisig-gt-list-columns))
    (should (= heisig-gt-list--shown 5))))

;;;; Mode line

(ert-deftest heisig-gt-list-test-mode-line-reports-counts ()
  "The mode line names the filters in force and what they left."
  (heisig-gt-list-test-with-buffer
    (should (equal (string-trim (heisig-gt-list--mode-line)) "5/5"))
    (heisig-gt-list-test-apply 'by-kind '("primitive"))
    (should (equal (string-trim (heisig-gt-list--mode-line))
                   "[kind=primitive] 1/5"))))

(ert-deftest heisig-gt-list-test-mode-line-reports-missing-study-data ()
  "An empty Status column is explained rather than left ambiguous."
  (heisig-gt-list-test-with-buffer
    (let ((heisig-gt-db-study-unavailable "Anki collection unreadable"))
      (should (string-match-p "no study data"
                              (heisig-gt-list--mode-line))))))

;;;; Bookmarks

(ert-deftest heisig-gt-list-test-bookmark-records-the-view ()
  "A bookmark stores the view, not a position."
  (heisig-gt-list-test-with-buffer
    (heisig-gt-list-test-apply 'by-kind '("kanji"))
    (heisig-gt-list-set-columns '(char keyword))
    (let ((record (heisig-gt-list--make-record)))
      (should (eq (alist-get 'handler record)
                  'heisig-gt-list-bookmark-jump))
      (should (equal (alist-get 'columns record) '(char keyword)))
      (should (equal (alist-get 'filters record)
                     heisig-gt-list--filters))
      (should (null (alist-get 'position record))))))

(provide 'test-heisig-gt-list)

;;; test-heisig-gt-list.el ends here
