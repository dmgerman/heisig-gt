;;; heisig-gt.el --- Browse kanji by Heisig frame, keyword and components  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Assisted-by: Claude:claude-opus-5
;; Keywords: languages, i18n
;; URL: https://github.com/dmgerman/heisig-gt
;; Version: 0.1
;; Package-Requires: ((emacs "30.1"))
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

;; heisig-gt browses a kanji database in a `tabulated-list-mode' buffer:
;; one row per kanji, columns chosen and ordered at will, composable
;; filters, and a detail buffer showing readings, components, the
;; Heisig story and the mnemonics.
;;
;; The data lives in an SQLite database built ahead of time by
;; tools/build-heisig-db.py from an Anki collection and, optionally,
;; kanji-all.json.  Build it with
;;
;;     make db
;;
;; and point `heisig-gt-db-file' at the result.  Nothing in this package
;; writes to that database.
;;
;; Study progress is not stored here either: it is read live from the
;; Anki collection on every refresh, so the Status, Interval, Reps and
;; Due columns show what Anki shows today without a rebuild.
;;
;; Start with \\[heisig-gt-list].

;;; Code:

(defgroup heisig-gt nil
  "Browse kanji by Heisig frame number, keyword and components."
  :prefix "heisig-gt-"
  :group 'applications)

;; Required after the group above, which their options are declared in.
(require 'heisig-gt-db)
(require 'heisig-gt-detail)
(require 'heisig-gt-list)
(require 'heisig-gt-words)

(provide 'heisig-gt)

;;; heisig-gt.el ends here
