# Makefile for heisig-gt.
#
# Package-specific settings only; every rule lives in Makefile.common,
# which is an identical copy across the dmg packages.  Run `make help'
# for the target list, and see the header of Makefile.common for what
# each variable below controls.

PACKAGE = heisig-gt

# Foundational files first so follow-on files can (require
# 'heisig-gt-db) and (require 'heisig-gt-detail) without erroring when
# compiled in isolation.
EL_FILES = heisig-gt-db.el \
           heisig-gt-detail.el \
           heisig-gt-list.el \
           heisig-gt-words.el \
           heisig-gt.el

# No runtime dependency beyond Emacs itself: the database is read with
# the built-in sqlite support present since Emacs 29, so no emacsql.
# `package-lint' is dev tooling.
DEPS = package-lint

TEST_DIR = test

INFO_SRC = readme.org

# `make db' is not part of `check': it needs the user's Anki
# collection, which CI does not have.
DB_FILE  ?= $(HOME)/.emacs.d/heisig-gt.db
ANKI_FILE ?= $(HOME)/Library/Application Support/Anki2/0/collection.anki2
JSON_FILE ?= kanji-all.json
NETFLIX_FILE ?= $(HOME)/tmDropbox/jp/netflix/netflix_unidic_3011_no_names_word_freq_report.txt
DICT_FILE    ?= $(HOME)/dictionary.db
TANGO_DIR    ?= ../yomikun-gt/db

FIXTURE_ANKI = test/fixtures/mini-collection.anki2
FIXTURE_DICT = test/fixtures/mini-dictionary.db
FIXTURE_N5   = test/fixtures/mini-tango5.db
FIXTURE_N4   = test/fixtures/mini-tango4.db
FIXTURE_DB   = test/fixtures/mini-heisig.db

EXTRA_CLEAN = $(FIXTURE_ANKI) $(FIXTURE_DICT) $(FIXTURE_N5) \
              $(FIXTURE_N4) $(FIXTURE_DB)

HELP_EXTRA = "  make db             build $(DB_FILE) from Anki + JSON + Netflix + dictionary"

include Makefile.common

.PHONY: db

db:
	./tools/build-heisig-db.py \
	  --anki "$(ANKI_FILE)" \
	  --json "$(JSON_FILE)" \
	  --netflix "$(NETFLIX_FILE)" \
	  --dictionary "$(DICT_FILE)" \
	  --tango "5=$(TANGO_DIR)/tangoN5.db" \
	  --tango "4=$(TANGO_DIR)/tangoN4.db" \
	  --tango "3=$(TANGO_DIR)/tangon3.db" \
	  --out "$(DB_FILE)"

# The suite reads a database built by the same script the user runs,
# so a schema the reader and the builder disagree about fails the
# tests rather than surfacing later against real data.  Both fixtures
# are generated; only their inputs are committed.
test: $(FIXTURE_DB)

$(FIXTURE_ANKI): tools/make-test-fixture.py
	./tools/make-test-fixture.py --out $@ \
	  --dictionary $(FIXTURE_DICT) \
	  --tango "5=$(FIXTURE_N5)" --tango "4=$(FIXTURE_N4)"

$(FIXTURE_DB): tools/build-heisig-db.py test/fixtures/mini-kanji.json \
               test/fixtures/mini-netflix.txt $(FIXTURE_ANKI)
	./tools/build-heisig-db.py \
	  --anki $(FIXTURE_ANKI) \
	  --json test/fixtures/mini-kanji.json \
	  --netflix test/fixtures/mini-netflix.txt \
	  --dictionary $(FIXTURE_DICT) \
	  --tango "5=$(FIXTURE_N5)" --tango "4=$(FIXTURE_N4)" \
	  --out $@
