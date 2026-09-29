#!/usr/bin/env python3
"""Write a miniature Anki collection for the test suite.

The elisp tests need something Anki-shaped to read study progress
from, and something for build-heisig-db.py to merge with the JSON
fixture.  A real collection is 245 MB and personal; this is the
smallest file with the same shape: the four tables heisig-gt reads
(`col', `decks', `notes', `cards'), plus the `notetypes' and `fields'
tables the builder uses to work out which field is which.

The `unicase' collation Anki declares on its name columns is declared
here too, so a reader that does not know it meets the same failure the
real collection produces.

Usage: make-test-fixture.py --out test/fixtures/mini-collection.anki2
"""

import argparse
import base64
import json
import os
import sqlite3

SEP = "\x1f"

# 2020-02-15 21:00:00 UTC, matching the shape of a real `crt'.
CRT = 1581800400

SCHEMA = """
CREATE TABLE col (id integer primary key, crt integer not null);
CREATE TABLE decks (
  id integer PRIMARY KEY NOT NULL,
  name text NOT NULL COLLATE unicase);
CREATE TABLE notetypes (
  id integer NOT NULL PRIMARY KEY,
  name text NOT NULL COLLATE unicase);
CREATE TABLE fields (
  ntid integer NOT NULL,
  ord integer NOT NULL,
  name text NOT NULL COLLATE unicase,
  PRIMARY KEY (ntid, ord)) WITHOUT ROWID;
CREATE UNIQUE INDEX idx_fields_name_ntid ON fields (name, ntid);
CREATE TABLE notes (
  id integer PRIMARY KEY, mid integer NOT NULL, flds text NOT NULL);
CREATE TABLE cards (
  id integer PRIMARY KEY, nid integer NOT NULL, did integer NOT NULL,
  queue integer NOT NULL, ivl integer NOT NULL, reps integer NOT NULL,
  lapses integer NOT NULL, due integer NOT NULL, odid integer NOT NULL);
"""

MIGAKU_MID = 1000000000001
ACADEMY_MID = 1000000000002
MIGAKU_DID = 2000000000001
ACADEMY_DID = 2000000000002

MIGAKU_FIELDS = ["Character", "UserData", "MigakuData", "StrokeOrder"]
ACADEMY_FIELDS = [
    "Character", "Keyword", "StrokeOrder", "Definitions",
    "ExampleSentences", "Notes", "Images", "Audio", "WordAudio", "Field9",
    "ComponentBreakdown", "Field11", "Radical", "CompoundWords",
    "Readings", "Field15", "Flag", "Field17"]

SVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 109 109"></svg>'

# One kanji present in every source, one Anki-only, one primitive, and
# one malformed note -- between them they cover each merge path.
MIGAKU_NOTES = [
    ("一", {"character": "一", "has_result": True, "stroke_count": 1,
            "onyomi": ["イチ"], "kunyomi": ["ひと"], "nanori": ["かず"],
            "meanings": ["one"], "frequency_rank": 2, "grade": 1,
            "jlpt": 5, "kanken": 10, "wk": 1,
            "primitives": ["一"], "primitive_of": ["二", "三"],
            "primitive_keywords": [], "heisig_id5": 1, "heisig_id6": 1,
            "heisig_keyword5": "one", "heisig_keyword6": "one",
            "heisig_story": "In Chinese characters, the number <b>one</b>.",
            "heisig_comment": "", "radicals": ["一"],
            "words_default": [["一", "いち"]],
            "koohi_stories": ["1) [someone] 1-2-2003(42): A single line."],
            "usr_keyword": None, "usr_story": None,
            "usr_primitive_keyword": None}),
    ("肉", {"character": "肉", "has_result": True, "stroke_count": 6,
            "onyomi": ["ニク"], "kunyomi": [], "nanori": [],
            "meanings": ["meat"], "frequency_rank": 999999, "grade": 2,
            "jlpt": 4, "kanken": 9, "wk": 5,
            "primitives": ["[apron]"], "primitive_of": [],
            "primitive_keywords": [], "heisig_id5": 1993,
            "heisig_id6": 2013, "heisig_keyword5": "meat",
            "heisig_keyword6": "meat", "heisig_story": "",
            "heisig_comment": "", "radicals": ["肉"],
            "words_default": [], "koohi_stories": [],
            "usr_keyword": "my meat", "usr_story": None,
            "usr_primitive_keyword": None}),
    ("[apron]", {"character": "[apron]", "has_result": True,
                 "stroke_count": None, "onyomi": [], "kunyomi": [],
                 "nanori": [], "meanings": [], "frequency_rank": 999999,
                 "grade": None, "jlpt": None, "kanken": None, "wk": None,
                 "primitives": [], "primitive_of": ["肉"],
                 "primitive_keywords": ["apron"], "heisig_id5": None,
                 "heisig_id6": None, "heisig_keyword5": None,
                 "heisig_keyword6": None, "heisig_story": "",
                 "heisig_comment": "", "radicals": [],
                 "words_default": [], "koohi_stories": [],
                 "usr_keyword": None, "usr_story": None,
                 "usr_primitive_keyword": None}),
    ("[", None),
]

ACADEMY_NOTES = [
    # Character, Keyword, Definitions, ExampleSentences,
    # ComponentBreakdown, Radical, CompoundWords, Readings
    ("一", "one", "one, single", "Just <strong>one</strong>.",
     "一;one;one radical (no.1);", "一", "一番[いちばん]", "ひと\nイチ"),
    ("川", "river", "river, stream", "A <u>river</u> runs through it.",
     "川;river;;", "川", "川口[かわぐち]", "かわ\nセン"),
]

# (nid-offset, deck, queue, ivl, reps, lapses, due)
CARDS = [
    (0, MIGAKU_DID, 2, 100, 9, 1, 3000),    # 一 in review
    (1, MIGAKU_DID, 0, 0, 0, 0, 5),         # 肉 new
    (2, MIGAKU_DID, -1, 0, 0, 0, 0),        # [apron] suspended
    (0, ACADEMY_DID, 2, 5, 2, 0, 2900),     # 一 again, shorter interval
    (1, ACADEMY_DID, 1, -60, 3, 0, 0),      # 川 learning
]


def build(path):
    if os.path.exists(path):
        os.unlink(path)
    con = sqlite3.connect(path)
    con.create_collation(
        "unicase",
        lambda a, b: (a.lower() > b.lower()) - (a.lower() < b.lower()))
    con.executescript(SCHEMA)
    con.execute("INSERT INTO col VALUES (1, ?)", (CRT,))
    con.executemany("INSERT INTO decks VALUES (?,?)", [
        (MIGAKU_DID, "jp" + SEP + "kanjiMigaku"),
        (ACADEMY_DID, "jp" + SEP + "kanjiAcademy"),
        (9, "other")])
    con.executemany("INSERT INTO notetypes VALUES (?,?)", [
        (MIGAKU_MID, "migaku-kanji"), (ACADEMY_MID, "academy-kanji")])
    con.executemany("INSERT INTO fields VALUES (?,?,?)", [
        (MIGAKU_MID, i, n) for i, n in enumerate(MIGAKU_FIELDS)
    ] + [(ACADEMY_MID, i, n) for i, n in enumerate(ACADEMY_FIELDS)])

    migaku_ids, academy_ids = [], []
    for i, (char, data) in enumerate(MIGAKU_NOTES):
        nid = 3000000000000 + i
        blob = ("" if data is None else
                base64.b64encode(
                    json.dumps(data).encode("utf-8")).decode("ascii"))
        con.execute("INSERT INTO notes VALUES (?,?,?)",
                    (nid, MIGAKU_MID, SEP.join([char, "", blob, SVG])))
        migaku_ids.append(nid)
    for i, note in enumerate(ACADEMY_NOTES):
        nid = 4000000000000 + i
        char, keyword, defs, mnemonic, comps, radical, words, readings = note
        flds = [""] * len(ACADEMY_FIELDS)
        for name, value in (("Character", char), ("Keyword", keyword),
                            ("Definitions", defs),
                            ("ExampleSentences", mnemonic),
                            ("ComponentBreakdown", comps),
                            ("Radical", radical), ("CompoundWords", words),
                            ("Readings", readings), ("StrokeOrder", SVG)):
            flds[ACADEMY_FIELDS.index(name)] = value
        con.execute("INSERT INTO notes VALUES (?,?,?)",
                    (nid, ACADEMY_MID, SEP.join(flds)))
        academy_ids.append(nid)

    for i, (offset, did, queue, ivl, reps, lapses, due) in enumerate(CARDS):
        ids = migaku_ids if did == MIGAKU_DID else academy_ids
        con.execute("INSERT INTO cards VALUES (?,?,?,?,?,?,?,?,?)",
                    (5000000000000 + i, ids[offset], did, queue, ivl, reps,
                     lapses, due, 0))
    con.commit()
    con.close()


# --- Dictionary and JLPT list ----------------------------------------
#
# Both are emacsql's work in the real thing, which wraps every stored
# string in literal double quotes -- `を' is stored as `"を"'.  The
# fixtures are written the same way on purpose: a builder that forgot
# to strip them would pass against clean data and fail against the
# user's.

DICT_ROWS = [
    ("だ", "だ", "cop-da", "be, is"),
    ("言う", "いう", "v5u", "to say, to utter"),
    ("言う", "いう", "v5u", "to name, to call"),
    ("目", "め", "n", "eye, eyeball"),
    ("目", "もく", "ctr", "counter for go pieces"),
    ("目的", "もくてき", "n", "purpose, goal, aim"),
    ("為る", "する", "vs-i", "to do, to carry out"),
    ("私", "わたし", "pn", "I, me"),
    ("川", "かわ", "n", "river, stream"),
    ("目指す", "めざす", "v5s vt", "to aim at, to head for"),
]

# Cumulative, as the real lists are: every N5 word is also in N4.
TANGO = {5: ["だ", "目", "川"], 4: ["だ", "目", "川", "目的", "私"]}


def quoted(value):
    """Return VALUE wrapped the way emacsql stores a string."""
    return '"%s"' % value


def build_dictionary(path):
    if os.path.exists(path):
        os.unlink(path)
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE dict(root text, pronun text, pos text,"
                " def text, rank int)")
    con.execute("CREATE TABLE entries(root, reading, pos, wtype, gloss)")
    con.executemany(
        "INSERT INTO dict VALUES (?,?,?,?,?)",
        [(quoted(r), quoted(p), quoted(po), quoted(d), quoted("1"))
         for r, p, po, d in DICT_ROWS])
    con.commit()
    con.close()


def build_tango(path, level):
    if os.path.exists(path):
        os.unlink(path)
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE words (morph , mtype , surface , status ,"
                " date , PRIMARY KEY (morph, mtype, surface))")
    con.executemany(
        "INSERT INTO words VALUES (?,?,?,?,?)",
        [(quoted(w), quoted("名詞"), quoted(w), quoted("known"), "")
         for w in TANGO[level]])
    con.commit()
    con.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True)
    parser.add_argument("--dictionary")
    parser.add_argument("--tango", action="append",
                        help="LEVEL=PATH (repeatable)")
    args = parser.parse_args()
    build(args.out)
    written = [args.out]
    if args.dictionary:
        build_dictionary(args.dictionary)
        written.append(args.dictionary)
    for spec in args.tango or ():
        level, _, path = spec.partition("=")
        build_tango(path, int(level))
        written.append(path)
    for path in written:
        print("wrote %s (%d bytes)" % (path, os.path.getsize(path)))


if __name__ == "__main__":
    main()
