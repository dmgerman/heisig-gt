;;; test-heisig-gt-kanji.el --- Tests for heisig-gt-kanji  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The list buffer: its column registry, its rendering, its filters
;; and its sort keys.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'heisig-gt-kanji)
(require 'heisig-gt-test-helper)

(defmacro heisig-gt-kanji-test-with-buffer (&rest body)
  "Run BODY in a fresh list buffer filled from the fixtures."
  (declare (indent 0) (debug t))
  `(heisig-gt-test-with-db
     (let ((buffer (generate-new-buffer " *heisig-gt-test-list*"))
           ;; Persistence is off so a test cannot write the
           ;; developer's state file.
           (heisig-gt-kanji-persist-state nil)
           (heisig-gt-kanji--state nil)
           (heisig-gt-kanji--state-loaded t))
       (unwind-protect
           (with-current-buffer buffer
             (heisig-gt-kanji-mode)
             (heisig-gt-kanji--reload)
             (heisig-gt-kanji--redraw-preserving-point)
             ,@body)
         (kill-buffer buffer)))))

(defun heisig-gt-kanji-test-column (key)
  "Return the cell text of column KEY on the current line."
  (heisig-gt-kanji--cell (tabulated-list-get-id) key))

;;;; Column registry

(ert-deftest heisig-gt-kanji-test-unknown-column-signals ()
  "Asking for a column that is not registered is an error."
  (should-error (heisig-gt-kanji--column 'nonesuch) :type 'user-error))

(ert-deftest heisig-gt-kanji-test-column-width-override ()
  "`heisig-gt-kanji-column-widths' beats the registry."
  (should (= (heisig-gt-kanji--column-width 'keyword) 22))
  (let ((heisig-gt-kanji-column-widths '((keyword . 4))))
    (should (= (heisig-gt-kanji--column-width 'keyword) 4))))

(ert-deftest heisig-gt-kanji-test-visible-columns-drop-unknown-keys ()
  "A key with no registry entry is ignored, not shown as a gap."
  (let ((heisig-gt-kanji--columns '(char nonesuch keyword)))
    (should (equal (heisig-gt-kanji--visible-columns) '(char keyword)))))

(ert-deftest heisig-gt-kanji-test-visible-columns-never-empty ()
  "A selection that names nothing still leaves one column."
  (let ((heisig-gt-kanji--columns nil))
    (should (= 1 (length (heisig-gt-kanji--visible-columns))))))

(ert-deftest heisig-gt-kanji-test-last-column-takes-the-rest-of-the-line ()
  "The last column is declared with width 0 and is never truncated."
  (let ((heisig-gt-kanji--columns '(char keyword meanings)))
    (let ((format (heisig-gt-kanji--format)))
      (should (= (length format) 3))
      (should (= (nth 1 (aref format 0)) 5))
      (should (= (nth 1 (aref format 2)) 0)))))

;;;; Rendering

(ert-deftest heisig-gt-kanji-test-cell-truncates-to-display-width ()
  "Truncation counts display columns, so a kanji costs two of them."
  (heisig-gt-test-with-db
    (let ((kanji (heisig-gt-db-kanji "一"))
          (heisig-gt-kanji-column-widths '((meanings . 4))))
      (should (= 2 (string-width (heisig-gt-kanji--cell kanji 'char))))
      ;; "one" fits; a longer value would come back marked.
      (should (equal (heisig-gt-kanji--cell kanji 'meanings) "one")))
    (let ((kanji (heisig-gt-db-kanji "森"))
          (heisig-gt-kanji-column-widths '((meanings . 6))))
      (should (= 6 (string-width (heisig-gt-kanji--cell kanji 'meanings))))
      (should-not (equal (heisig-gt-kanji--cell kanji 'meanings)
                         (plist-get kanji :meanings)))
      ;; With EXPAND it is left whole, which is what the last column
      ;; gets.
      (should (equal (heisig-gt-kanji--cell kanji 'meanings t)
                     "forest,woods")))))

(ert-deftest heisig-gt-kanji-test-component-keywords-column ()
  "The column names the components in the order they are written."
  (heisig-gt-test-with-db
    (should (equal (heisig-gt-kanji--cell (heisig-gt-db-kanji "一")
                                         'component-keywords)
                   "one"))
    (should (equal (heisig-gt-kanji--cell (heisig-gt-db-kanji "肉")
                                         'component-keywords)
                   "apron"))
    ;; A kanji with no components at all leaves the cell empty.
    (should (equal (heisig-gt-kanji--cell (heisig-gt-db-kanji "[apron]")
                                         'component-keywords)
                   ""))))

(ert-deftest heisig-gt-kanji-test-empty-cells-are-empty ()
  "A column with nothing to show renders as nothing."
  (heisig-gt-test-with-db
    (let ((forest (heisig-gt-db-kanji "森")))
      (should (equal (heisig-gt-kanji--cell forest 'heisig) ""))
      (should (equal (heisig-gt-kanji--cell forest 'jlpt) ""))
      (should (equal (heisig-gt-kanji--cell forest 'strokes) "")))))

(ert-deftest heisig-gt-kanji-test-jlpt-is-written-as-a-level ()
  "The JLPT column reads N5, not 5."
  (heisig-gt-test-with-db
    (should (equal (heisig-gt-kanji--jlpt (heisig-gt-db-kanji "一")) "N5"))))

(ert-deftest heisig-gt-kanji-test-buffer-renders-every-row ()
  "Every kanji in the database gets a row."
  (heisig-gt-kanji-test-with-buffer
    (should (= heisig-gt-kanji--total 5))
    (should (= heisig-gt-kanji--shown 5))
    (goto-char (point-min))
    (should (equal (heisig-gt-kanji--char-at-point) "一"))))

;;;; Filters

(defun heisig-gt-kanji-test-apply (key values &optional negate)
  "Apply the filter KEY over VALUES, optionally NEGATE it, and redraw."
  (setq heisig-gt-kanji--filters
        (list (list :key key :values values :negate negate)))
  (heisig-gt-kanji--redraw-preserving-point)
  heisig-gt-kanji--shown)

(ert-deftest heisig-gt-kanji-test-filter-selects ()
  "A filter keeps the rows its predicate accepts."
  (heisig-gt-kanji-test-with-buffer
    (should (= 1 (heisig-gt-kanji-test-apply 'by-kind '("primitive"))))
    (should (= 4 (heisig-gt-kanji-test-apply 'by-kind '("kanji"))))))

(ert-deftest heisig-gt-kanji-test-filter-values-widen ()
  "Values within one filter are an OR."
  (heisig-gt-kanji-test-with-buffer
    (should (= 1 (heisig-gt-kanji-test-apply 'by-jlpt '(5))))
    (should (= 2 (heisig-gt-kanji-test-apply 'by-jlpt '(4))))
    ;; The union of the two, not either one.
    (should (= 3 (heisig-gt-kanji-test-apply 'by-jlpt '(5 4))))))

(ert-deftest heisig-gt-kanji-test-filters-narrow ()
  "Separate filters are an AND."
  (heisig-gt-kanji-test-with-buffer
    (setq heisig-gt-kanji--filters
          (list (list :key 'by-kind :values '("kanji") :negate nil)
                (list :key 'by-jlpt :values '(5) :negate nil)))
    (heisig-gt-kanji--redraw-preserving-point)
    (should (= heisig-gt-kanji--shown 1))))

(ert-deftest heisig-gt-kanji-test-filter-negation ()
  "A negated filter keeps exactly what it would otherwise drop."
  (heisig-gt-kanji-test-with-buffer
    (should (= 1 (heisig-gt-kanji-test-apply 'by-kind '("primitive"))))
    (should (= 4 (heisig-gt-kanji-test-apply 'by-kind '("primitive") t)))))

(ert-deftest heisig-gt-kanji-test-unregistered-filter-narrows-nothing ()
  "A filter left over from a removed registration empties nothing."
  (heisig-gt-kanji-test-with-buffer
    (should (= 5 (heisig-gt-kanji-test-apply 'by-nonesuch '("x"))))))

(ert-deftest heisig-gt-kanji-test-filter-by-component ()
  "The component filter reads the graph, not the character."
  (heisig-gt-kanji-test-with-buffer
    (should (= 1 (heisig-gt-kanji-test-apply 'by-component '("[apron]"))))
    (goto-char (point-min))
    (should (equal (heisig-gt-kanji--char-at-point) "肉"))))

(ert-deftest heisig-gt-kanji-test-filter-by-component-keyword ()
  "The keyword filter reaches the same rows as the character one."
  (heisig-gt-kanji-test-with-buffer
    ;; 肉 is built from [apron], whose name is "apron".
    (should (= 1 (heisig-gt-kanji-test-apply 'by-component-keyword
                                            '("apron"))))
    (goto-char (point-min))
    (should (equal (heisig-gt-kanji--char-at-point) "肉"))
    ;; Either side of the Comp keywords column selects the same row.
    (should (= 1 (heisig-gt-kanji-test-apply 'by-component '("[apron]"))))
    ;; Values widen, as in every other filter.
    (should (= 2 (heisig-gt-kanji-test-apply 'by-component-keyword
                                            '("apron" "one"))))
    (should (= 0 (heisig-gt-kanji-test-apply 'by-component-keyword
                                            '("nonesuch"))))))

(ert-deftest heisig-gt-kanji-test-reading-columns ()
  "Each reading kind is shown in both scripts."
  (heisig-gt-test-with-db
    (let ((one (heisig-gt-db-kanji "一")))
      (should (equal (heisig-gt-kanji--cell one 'onyomi) "イチ"))
      (should (equal (heisig-gt-kanji--cell one 'onyomi-romaji) "ichi"))
      (should (equal (heisig-gt-kanji--cell one 'kunyomi) "ひと"))
      (should (equal (heisig-gt-kanji--cell one 'kunyomi-romaji) "hito")))
    ;; A primitive has no readings at all.
    (should (equal (heisig-gt-kanji--cell (heisig-gt-db-kanji "[apron]")
                                         'onyomi-romaji)
                   ""))))

(ert-deftest heisig-gt-kanji-test-readings-are-shown-by-default ()
  "All four reading columns are on, and all four precede Meanings."
  (dolist (key '(onyomi onyomi-romaji kunyomi kunyomi-romaji))
    (should (memq key heisig-gt-kanji-columns))
    (should (< (seq-position heisig-gt-kanji-columns key)
               (seq-position heisig-gt-kanji-columns 'meanings)))))

(ert-deftest heisig-gt-kanji-test-filter-by-reading-romaji ()
  "The romaji filters take a fragment, where the others take a reading."
  (heisig-gt-kanji-test-with-buffer
    ;; 一 is read イチ; the exact filter needs the whole of it.
    (should (= 0 (heisig-gt-kanji-test-apply 'by-onyomi '("ich"))))
    (should (= 1 (heisig-gt-kanji-test-apply 'by-onyomi-romaji '("ich"))))
    (should (= 1 (heisig-gt-kanji-test-apply 'by-onyomi-romaji '("^i"))))
    (should (= 0 (heisig-gt-kanji-test-apply 'by-onyomi-romaji '("^z"))))
    ;; The two kinds stay apart, as they do for the exact filters.
    (should (= 1 (heisig-gt-kanji-test-apply 'by-kunyomi-romaji '("hi"))))
    (should (= 0 (heisig-gt-kanji-test-apply 'by-onyomi-romaji '("hito"))))
    ;; However permissive the pattern, a kanji with no reading of
    ;; that kind cannot match: three of the five have an on reading
    ;; and two have a kun one.
    (should (= 3 (heisig-gt-kanji-test-apply 'by-onyomi-romaji '("."))))
    (should (= 2 (heisig-gt-kanji-test-apply 'by-kunyomi-romaji '("."))))))

(ert-deftest heisig-gt-kanji-test-filter-by-reading ()
  "A reading filter takes either script and keeps the kinds apart."
  (heisig-gt-kanji-test-with-buffer
    (should (= 1 (heisig-gt-kanji-test-apply 'by-onyomi '("イチ"))))
    (should (= 1 (heisig-gt-kanji-test-apply 'by-onyomi '("ichi"))))
    (goto-char (point-min))
    (should (equal (heisig-gt-kanji--char-at-point) "一"))
    ;; An on reading does not match as a kun one.
    (should (= 0 (heisig-gt-kanji-test-apply 'by-kunyomi '("ichi"))))
    (should (= 1 (heisig-gt-kanji-test-apply 'by-kunyomi '("hito"))))
    ;; Values widen, as in every other filter.
    (should (= 2 (heisig-gt-kanji-test-apply 'by-kunyomi '("hito" "kawa"))))))

(ert-deftest heisig-gt-kanji-test-filter-by-used-in ()
  "The inverse filter selects a character's components."
  (heisig-gt-kanji-test-with-buffer
    (should (= 1 (heisig-gt-kanji-test-apply 'by-used-in '("肉"))))
    (goto-char (point-min))
    (should (equal (heisig-gt-kanji--char-at-point) "[apron]"))))

(ert-deftest heisig-gt-kanji-test-filter-by-status ()
  "Status comes from Anki, and `none' is what Anki does not have."
  (heisig-gt-kanji-test-with-buffer
    (should (= 1 (heisig-gt-kanji-test-apply 'by-status '(review))))
    (should (= 1 (heisig-gt-kanji-test-apply 'by-status '(suspended))))
    (should (= 1 (heisig-gt-kanji-test-apply 'by-status '(none))))))

(ert-deftest heisig-gt-kanji-test-filter-by-source ()
  "The source filter matches one name in the comma-separated list."
  (heisig-gt-kanji-test-with-buffer
    (should (= 3 (heisig-gt-kanji-test-apply 'by-source '("json"))))
    (should (= 3 (heisig-gt-kanji-test-apply 'by-source '("migaku"))))))

(ert-deftest heisig-gt-kanji-test-filter-description ()
  "The mode-line label drops the `by-' prefix and marks negation."
  (should (equal (heisig-gt-kanji--filter-description
                  '(:key by-jlpt :values (5 4) :negate nil))
                 "jlpt=5,4"))
  (should (equal (heisig-gt-kanji--filter-description
                  '(:key by-status :values (suspended) :negate t))
                 "!status=suspended")))

;;;; Ranges

(ert-deftest heisig-gt-kanji-test-range-bounds ()
  "Both ends of a range are optional; a bare number is exact."
  (should (equal (heisig-gt-kanji--range-bounds "1,10") '(1 . 10)))
  (should (equal (heisig-gt-kanji--range-bounds "800,") '(800 . nil)))
  (should (equal (heisig-gt-kanji--range-bounds ",50") '(nil . 50)))
  (should (equal (heisig-gt-kanji--range-bounds " 5 , 7 ") '(5 . 7)))
  (should (equal (heisig-gt-kanji--range-bounds ",") '(nil . nil)))
  ;; A single number is one value, not an open-ended range: reading
  ;; "15" as "15 and up" would return most of the table.
  (should (equal (heisig-gt-kanji--range-bounds "15") '(15 . 15))))

(ert-deftest heisig-gt-kanji-test-range-rejects-nonsense ()
  "Anything that is not a range is refused rather than matching all."
  (should (null (heisig-gt-kanji--range-bounds "a-b")))
  (should (null (heisig-gt-kanji--range-bounds "1,2,3")))
  (should (null (heisig-gt-kanji--range-bounds "-5"))))

(ert-deftest heisig-gt-kanji-test-in-range ()
  "An unknown value is outside every range, including an open one."
  (should (heisig-gt-kanji--in-range-p 5 "1,10"))
  (should-not (heisig-gt-kanji--in-range-p 50 "1,10"))
  (should (heisig-gt-kanji--in-range-p 900 "800,"))
  ;; An unknown stroke count is not a stroke count of zero.
  (should-not (heisig-gt-kanji--in-range-p nil ","))
  (should-not (heisig-gt-kanji--in-range-p 5 "bogus")))

(ert-deftest heisig-gt-kanji-test-filter-by-frame-range ()
  "The frame filter uses the range, and excludes the unnumbered."
  (heisig-gt-kanji-test-with-buffer
    (should (= 1 (heisig-gt-kanji-test-apply 'by-frame '("1,10"))))
    (should (= 2 (heisig-gt-kanji-test-apply 'by-frame '(","))))))

;;;; Sorting

(ert-deftest heisig-gt-kanji-test-numeric-columns-sort-numerically ()
  "10 follows 9, which sorting on the displayed text would not give."
  (heisig-gt-kanji-test-with-buffer
    (setq tabulated-list-sort-key '("Frame" . nil))
    (heisig-gt-kanji--redraw-preserving-point)
    (goto-char (point-min))
    (should (equal (heisig-gt-kanji--char-at-point) "一"))
    (forward-line 1)
    (should (equal (heisig-gt-kanji--char-at-point) "肉"))))

(ert-deftest heisig-gt-kanji-test-unknown-values-sort-last ()
  "A row with no value collects at one end instead of counting as 0."
  (heisig-gt-kanji-test-with-buffer
    (setq heisig-gt-kanji--columns '(char strokes keyword))
    (setq tabulated-list-sort-key '("Str" . nil))
    (heisig-gt-kanji--redraw-preserving-point)
    (goto-char (point-max))
    (forward-line -1)
    ;; 森's stroke count is unknown in every source.
    (should (equal (heisig-gt-kanji--char-at-point) "森"))))

(ert-deftest heisig-gt-kanji-test-sort-key-survives-hiding-its-column ()
  "Hiding the sorted column falls back instead of sorting on nothing."
  (heisig-gt-kanji-test-with-buffer
    (setq tabulated-list-sort-key '("Keyword" . nil))
    (heisig-gt-kanji-toggle-column 'keyword)
    (should-not (equal (car tabulated-list-sort-key) "Keyword"))
    (should (member (car tabulated-list-sort-key)
                    (heisig-gt-kanji--sortable-columns)))))

;;;; Columns

(ert-deftest heisig-gt-kanji-test-toggle-column-round-trip ()
  "A column comes back in registry position, not at the end."
  (heisig-gt-kanji-test-with-buffer
    (setq heisig-gt-kanji--columns '(heisig char keyword meanings))
    (heisig-gt-kanji-toggle-column 'char)
    (should (equal heisig-gt-kanji--columns '(heisig keyword meanings)))
    (heisig-gt-kanji-toggle-column 'char)
    (should (equal heisig-gt-kanji--columns '(heisig char keyword meanings)))))

(ert-deftest heisig-gt-kanji-test-set-columns-keeps-the-order-given ()
  "Reordering is the same operation as choosing."
  (heisig-gt-kanji-test-with-buffer
    (heisig-gt-kanji-set-columns '(meanings char))
    (should (equal heisig-gt-kanji--columns '(meanings char)))
    (should-error (heisig-gt-kanji-set-columns nil) :type 'user-error)
    (should-error (heisig-gt-kanji-set-columns '(nonesuch))
                  :type 'user-error)))

(ert-deftest heisig-gt-kanji-test-reset-view ()
  "Resetting clears the filters and restores the defaults."
  (heisig-gt-kanji-test-with-buffer
    (heisig-gt-kanji-test-apply 'by-kind '("primitive"))
    (heisig-gt-kanji-set-columns '(char))
    (heisig-gt-kanji-reset-view)
    (should (null heisig-gt-kanji--filters))
    (should (equal heisig-gt-kanji--columns heisig-gt-kanji-columns))
    (should (= heisig-gt-kanji--shown 5))))

;;;; Mode line

(ert-deftest heisig-gt-kanji-test-mode-line-reports-counts ()
  "The mode line names the filters in force and what they left."
  (heisig-gt-kanji-test-with-buffer
    (should (equal (string-trim (heisig-gt-kanji--mode-line)) "5/5"))
    (heisig-gt-kanji-test-apply 'by-kind '("primitive"))
    (should (equal (string-trim (heisig-gt-kanji--mode-line))
                   "[kind=primitive] 1/5"))))

(ert-deftest heisig-gt-kanji-test-mode-line-reports-missing-study-data ()
  "An empty Status column is explained rather than left ambiguous."
  (heisig-gt-kanji-test-with-buffer
    (let ((heisig-gt-db-study-unavailable "Anki collection unreadable"))
      (should (string-match-p "no study data"
                              (heisig-gt-kanji--mode-line))))))

;;;; Bookmarks

(ert-deftest heisig-gt-kanji-test-go-to-a-character ()
  "The optional argument puts point on that character's row."
  (heisig-gt-kanji-test-with-buffer
    (goto-char (point-min))
    (should (heisig-gt-kanji--go-to "森"))
    (should (equal (heisig-gt-kanji--id-at-point) "森"))
    ;; An empty or absent argument is not a request to move.
    (should-not (heisig-gt-kanji--go-to nil))
    (should (equal (heisig-gt-kanji--id-at-point) "森"))))

(ert-deftest heisig-gt-kanji-test-go-to-an-unknown-character ()
  "A character with no entry leaves point where it was, and says so."
  (heisig-gt-kanji-test-with-buffer
    (heisig-gt-kanji--go-to "森")
    (let ((message nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args)
                   (setq message (apply #'format format args)))))
        (should-not (heisig-gt-kanji--go-to "鬱")))
      (should (string-match-p "not in the database" message)))
    ;; `--goto-char-row' would have dropped point at `point-min';
    ;; nobody asked to be moved there.
    (should (equal (heisig-gt-kanji--id-at-point) "森"))))

(ert-deftest heisig-gt-kanji-test-go-to-a-filtered-character ()
  "A character the filters exclude is reported as hidden, not absent."
  (heisig-gt-kanji-test-with-buffer
    (heisig-gt-kanji-test-apply 'by-kind '("primitive"))
    (let ((message nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args)
                   (setq message (apply #'format format args)))))
        (should-not (heisig-gt-kanji--go-to "森")))
      (should (string-match-p "hidden by the active filters" message))
      ;; It names them, so the reader knows what to remove.
      (should (string-match-p "kind=primitive" message)))))

(ert-deftest heisig-gt-kanji-test-old-names-still-work ()
  "The pre-rename names remain, so saved bookmarks still jump."
  (should (eq (indirect-function 'heisig-gt-list)
              (indirect-function 'heisig-gt-kanji)))
  (should (eq (indirect-function 'heisig-gt-list-bookmark-jump)
              (indirect-function 'heisig-gt-kanji-bookmark-jump))))

(ert-deftest heisig-gt-kanji-test-keys ()
  "`w' opens the word list; copying moved to the Emacs-standard `M-w'."
  (should (eq (keymap-lookup heisig-gt-kanji-mode-map "w")
              'heisig-gt-kanji-words))
  (should (eq (keymap-lookup heisig-gt-kanji-mode-map "M-w")
              'heisig-gt-kanji-copy-char)))

(ert-deftest heisig-gt-kanji-test-bookmark-records-the-view ()
  "A bookmark stores the view, not a position."
  (heisig-gt-kanji-test-with-buffer
    (heisig-gt-kanji-test-apply 'by-kind '("kanji"))
    (heisig-gt-kanji-set-columns '(char keyword))
    (let ((record (heisig-gt-kanji--make-record)))
      (should (eq (alist-get 'handler record)
                  'heisig-gt-kanji-bookmark-jump))
      (should (equal (alist-get 'columns record) '(char keyword)))
      (should (equal (alist-get 'filters record)
                     heisig-gt-kanji--filters))
      (should (null (alist-get 'position record))))))

(provide 'test-heisig-gt-kanji)

;;; test-heisig-gt-kanji.el ends here
