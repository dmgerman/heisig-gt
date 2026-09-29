# CLAUDE.md — heisig-gt

## What this repo is

`heisig-gt` browses kanji in a `tabulated-list-mode` buffer, with a detail
buffer per kanji. It reads two SQLite databases and writes neither.

## Rules

- **Never commit or push** — commits are made by the user explicitly.
- Never write to the user's Anki collection. It is copied before it is
  opened, and only ever read.
- `heisig-gt.db` is generated (`make db`) and git-ignored. So are both test
  fixtures.

## Key files

| File | Role |
|------|------|
| `heisig-gt.el` | `defgroup`, `Package-Requires`, requires the other three |
| `heisig-gt-db.el` | Both databases: schema access, bulk tables, the Anki study overlay, the status vocabulary and its faces |
| `heisig-gt-detail.el` | `heisig-gt-detail-show`: one reusable `*Kanji Detail*` buffer, component buttons, the HTML-fragment renderer |
| `heisig-gt-kanji.el` | `heisig-gt-kanji`: the `*Kanji*` buffer — **and the generic base mode**: rendering, filter algebra, sorting, columns, bookmarks, state. A derived mode supplies registries and a loader via the `heisig-gt-kanji--*-registry` / `--reload-function` / `--id-function` buffer-locals |
| `heisig-gt-words.el` | `heisig-gt-words`: the `*Words*` buffer, derived from `heisig-gt-kanji-mode` |
| `tools/build-heisig-db.py` | Merges Anki + `kanji-all.json` into `heisig-gt.db` |
| `tools/make-test-fixture.py` | Writes the miniature Anki collection the suite reads |
| `test/` | ERT suite (71 tests) + `heisig-gt-test-helper.el` |

Load order (`EL_FILES`): db → detail → list → heisig-gt. `heisig-gt-kanji.el`
requires `heisig-gt-detail.el`; detail reaches back to the list only through
the autoload of `heisig-gt-kanji`, which is what keeps the two from requiring
each other.

The `defgroup` lives in `heisig-gt.el` and is defined *before* it requires
the other three, which is why they can say `:group 'heisig-gt` without
requiring it back.

## Architecture in one paragraph

Columns and filters are each a plain alist registry
(`heisig-gt-kanji-column-alist`, `heisig-gt-kanji-filter-alist`), copied in
shape from `org-roam-gt-list.el`. `heisig-gt-kanji-columns` selects a subset
of the column registry *and* its left-to-right order, so showing, hiding and
reordering are one mechanism rather than three. Records are plists, not
structs, so a column's `:value` function and the database column it reads
are spelled the same way. The kanji list is read once per revert into a
buffer-local cache; sorting, filtering and column changes redraw from it, so
only `g` pays for a table scan. Columns that need child-table data
(components, readings) read a bulk table built with one query and grouped by
character — asking per row would be ~2000 queries per redraw. Rows are
re-found by character after a redraw, since records are rebuilt on every
read. The only advice installed is `:after` on `tabulated-list-sort`, guarded
by `derived-mode-p`, because header-click sorting never passes through a
command of the mode and is otherwise invisible to state persistence.

## Things that bit us

- **Anki's `unicase` collation.** Anki declares it on `decks.name`,
  `notetypes.name` and `fields.name`, and indexes `fields` with it. A reader
  that does not register the collation gets `no query solution` from any
  query the planner routes onto such an index. The Python builder registers a
  stand-in; the elisp side cannot, so it reads `SELECT id, name FROM decks`
  whole and matches names in Lisp. Never add a `WHERE name = ?` to the elisp
  Anki queries.
- **`999999` is Anki's "unranked", not a frequency.** Left alone it sorts
  every unranked kanji in among the genuinely rare ones. Stored as NULL.
- **Heisig primitives are rows.** Some are bracketed names (`[apron]`), some
  are single non-Han characters (`ハ`, `⺮`, `∈`). They are referenced by
  `primitives` / `primitive_of`, so dropping them dangles those links. They
  carry `kind = 'primitive'`.
- **The component graph reaches outside the database.** ~3000 of the
  `component_of` rows name characters with no row of their own — kanji
  outside the decks the DB was built from. `heisig-gt-db-known-p` is what
  decides whether a character is rendered as a button or as dimmed text.
- **`kanji-all.json` has had every space stripped** from its English text
  (`"oncemore,again"`). It is used only where nothing better exists, and the
  `sources` column records where it was.
- **`primitives_detail` / `primitive_of_detail`** are 22 MB of the 22.4 MB of
  decoded `MigakuData` — whole nested copies of other kanji records. The
  builder drops them; the component tables carry the same information.
- **`package-lint` reads symbols inside `rx` forms as function calls.**
  `(rx (any ";,"))` fails the lint with "you should depend on (emacs 31.1)
  if you need `any'". Other `rx` symbols used here (`bos`, `digit`,
  `backref`, `alpha`, `anychar`) do not collide, but spell a class as a
  plain string regexp rather than risk it.
- **Two thirds of component rows have an English name; the rest are
  resolved.** Only the Academy source glosses components.
  `heisig-gt-db-component-name` falls back to the component's own
  `kanji.keyword` (丿 is a component of 乏 and a kanji keyworded "katana"),
  then to the first clause of its gloss. That takes coverage from 2705 to
  4219 of 4221 rows. Both the `component-keywords` column and the detail
  buffer's component section go through it, so they never disagree.
- **The database has a schema version; bump it when you add a column.**
  `SCHEMA_VERSION` in the builder and `heisig-gt-db-schema-version` in
  `heisig-gt-db.el` must agree. `heisig-gt-db--check-schema` compares them
  once at connect and sends the user to `make db`; without it a database
  built before the change fails mid-redraw with "no such column". Currently
  `2` — `1` had no `reading.romaji`.
- **Romaji is stored, not computed.** `kana_to_romaji` in the builder fills
  `reading.romaji`. Deriving it per cell would transliterate ~7400 readings
  on every redraw of a 2000-row list. It is IME spelling, not Hepburn
  (`jou`, not `jō`), and drops the okurigana dot, because its purpose is to
  be typed at a filter prompt.
- **The base mode is named for the kanji list, because it is the kanji
  list.** `heisig-gt-kanji.el` holds both the kanji buffer and the generic
  machinery a derived mode reuses; `heisig-gt-words-mode` derives from
  `heisig-gt-kanji-mode`. If a third list ever arrives, that is the point
  to split `heisig-gt-kanji.el` into a `heisig-gt-tabulated.el` base plus
  a kanji-specific file — not before.
- **`heisig-gt-list*` was the old name.** Two autoloaded obsolete aliases
  remain; the bookmark-handler one is load-bearing, since a bookmark
  stores the handler symbol and one saved before the rename names the old
  one.
- **There is one list mode, not two.** `heisig-gt-words-mode` derives from
  `heisig-gt-kanji-mode` and overrides seven buffer-locals. Do not copy the
  machinery for a third list; add the parameter instead.
- **The saved-view file holds one entry per mode.** `heisig-gt-kanji--state`
  is an alist keyed by `major-mode`; the two lists have different columns
  and would otherwise clobber each other.
- **`make test` does not depend on `make compile`.** A stale `.elc` will be
  loaded in preference to newer source, which looks like a mass test
  failure with a confusing message. `make check` and `make check-ci` build
  first; a bare `make test` after editing may not.
- **The frequency report's columns 2 and 3 are easy to confuse.** 2 is the
  on-screen spelling, 3 is the pronunciation in katakana. For 目指す all
  three of lemma/spelling/pronunciation read 目指す/目指す/メザス, so the
  bug only shows on words like 為る (為る/する/スル). If readings start
  coming out as kanji, this is why.
- **checkdoc differs between Emacs 30 and 31.** 30 flags "holds" in a
  relative clause as a non-imperative first word; 31 does not. `make check`
  under Emacs 31 is not evidence that CI will pass. Run `make check-ci`.

## Running tests and checks

```sh
make               # byte-compile + info (default)
make test          # ERT suite; builds both fixtures first
make lint          # package-lint (needs MAIN_FILE, see below)
make checkdoc      # checkdoc, errors on any warning
make check         # compile + lint + checkdoc + check-declare + test + info
make check-ci      # the same under emacs-plus@30 and @31 — run before pushing
make db            # build ~/.emacs.d/heisig-gt.db from Anki + kanji-all.json
```

`Makefile.common` here is the copy from `org-roam-gt`, not the one at
`modules/dmg/Makefile.common`: the canonical copy lacks the `MAIN_FILE`
variable that sets `package-lint-main-file`, without which `make lint` fails
with a hundred "you should depend on (emacs 24.3)" errors. The canonical copy
needs updating and re-syncing; until then, `sync-makefile-common.sh --check`
reports this package as DIFFERS, as it already does for `org-roam-gt`.

## Test environment

The suite reads fixtures it generates: `tools/make-test-fixture.py` writes a
miniature Anki collection, and `tools/build-heisig-db.py` merges it with
`test/fixtures/mini-kanji.json`. Both are `make test` prerequisites. Building
the fixture with the real builder is deliberate — a schema the reader and the
builder disagree about then fails here rather than against real data. It
makes `python3` a test dependency, which is a declared, loud one rather than
a silent auto-detect.
