#!/usr/bin/env python3
"""Build heisig-gt.db from an Anki collection and kanji-all.json.

Three sources are merged, in this order of precedence per field:

  1. Anki deck ``jp::kanjiMigaku``  -- notetype carrying a ``MigakuData``
     field, whose value is base64-encoded JSON.  This is the only source
     with real Heisig frame numbers, Heisig's own stories, and the
     primitive graph.
  2. Anki deck ``jp::kanjiAcademy`` -- notetype carrying a
     ``ComponentBreakdown`` field.  Adds component glosses, a mnemonic
     sentence per kanji, and compound words.
  3. ``kanji-all.json``             -- every space has been stripped from
     its English text, so it is used only where nothing better exists.
     Its frequency-ranked definitions are unique to it.

The row's ``sources`` column records which of the three contributed, so a
value that reads oddly can be traced back to the source that damaged it.

Usage:
    build-heisig-db.py --anki PATH --json PATH --out heisig-gt.db
"""

import argparse
import base64
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import time

FIELD_SEP = "\x1f"

SCHEMA = """
PRAGMA journal_mode = OFF;

CREATE TABLE kanji (
  char            TEXT PRIMARY KEY,
  kind            TEXT NOT NULL,
  heisig5         INTEGER,
  heisig6         INTEGER,
  keyword         TEXT,
  keyword_source  TEXT,
  heisig_keyword5 TEXT,
  heisig_keyword6 TEXT,
  usr_keyword     TEXT,
  strokes         INTEGER,
  grade           INTEGER,
  jlpt            INTEGER,
  kanken          REAL,
  wk              INTEGER,
  freq_rank       INTEGER,
  radical         TEXT,
  meanings        TEXT,
  definitions     TEXT,
  top_reading     TEXT,
  top_onyomi      TEXT,
  top_kunyomi     TEXT,
  story           TEXT,
  comment         TEXT,
  mnemonic        TEXT,
  stroke_svg      TEXT,
  sources         TEXT
);

CREATE TABLE reading (
  char   TEXT NOT NULL,
  kind   TEXT NOT NULL,
  value  TEXT NOT NULL,
  romaji TEXT,
  ord    INTEGER NOT NULL
);

CREATE TABLE component (
  char      TEXT NOT NULL,
  ord       INTEGER NOT NULL,
  comp_char TEXT NOT NULL,
  keyword   TEXT,
  gloss     TEXT
);

CREATE TABLE component_of (
  char      TEXT NOT NULL,
  ord       INTEGER NOT NULL,
  comp_char TEXT NOT NULL
);

CREATE TABLE word (
  char       TEXT NOT NULL,
  ord        INTEGER NOT NULL,
  surface    TEXT NOT NULL,
  reading    TEXT,
  definition TEXT,
  freq       INTEGER
);

CREATE TABLE definition (
  char          TEXT NOT NULL,
  ord           INTEGER NOT NULL,
  term          TEXT,
  pronunciation TEXT,
  pos           TEXT,
  definition    TEXT,
  freq          INTEGER,
  stars         TEXT
);

CREATE TABLE story (
  char   TEXT NOT NULL,
  ord    INTEGER NOT NULL,
  source TEXT,
  author TEXT,
  votes  INTEGER,
  date   TEXT,
  text   TEXT
);

CREATE TABLE vocab (
  rank         INTEGER PRIMARY KEY,
  netflix_rank INTEGER NOT NULL,
  lemma        TEXT NOT NULL,
  surface      TEXT,
  root         TEXT NOT NULL,
  reading      TEXT,
  romaji       TEXT,
  pos          TEXT,
  unidic_pos   TEXT,
  jlpt         INTEGER,
  definition   TEXT,
  chars        TEXT,
  count        INTEGER,
  pct          REAL,
  cum_pct      REAL
);

-- One row per distinct character per word, so "the words written with
-- 目" is an index lookup rather than a LIKE over 52000 headwords.
-- Every character, not only the Han ones: the elisp filter searches
-- the headword directly and would otherwise find kana this table
-- cannot, which is a difference nothing textual would warn about.
CREATE TABLE vocab_char (
  char TEXT NOT NULL,
  rank INTEGER NOT NULL
);

CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);

CREATE INDEX idx_kanji_kind    ON kanji (kind);
CREATE INDEX idx_kanji_heisig6 ON kanji (heisig6);
CREATE INDEX idx_kanji_keyword ON kanji (keyword);
CREATE INDEX idx_kanji_jlpt    ON kanji (jlpt);
CREATE INDEX idx_kanji_strokes ON kanji (strokes);
CREATE INDEX idx_kanji_radical ON kanji (radical);

CREATE INDEX idx_reading_char      ON reading (char);
CREATE INDEX idx_reading_romaji    ON reading (romaji);
CREATE INDEX idx_component_char    ON component (char);
CREATE INDEX idx_component_comp    ON component (comp_char);
CREATE INDEX idx_component_of_char ON component_of (char);
CREATE INDEX idx_component_of_comp ON component_of (comp_char);
CREATE INDEX idx_word_char         ON word (char);
CREATE INDEX idx_definition_char   ON definition (char);
CREATE INDEX idx_story_char        ON story (char);
CREATE INDEX idx_vocab_root        ON vocab (root);
CREATE INDEX idx_vocab_reading     ON vocab (reading);
CREATE INDEX idx_vocab_romaji      ON vocab (romaji);
CREATE INDEX idx_vocab_jlpt        ON vocab (jlpt);
CREATE INDEX idx_vocab_char_char   ON vocab_char (char);
CREATE INDEX idx_vocab_char_rank   ON vocab_char (rank);
"""

SCHEMA_VERSION = "5"


def is_kanji(s):
    """Return True when S is exactly one Han character."""
    if len(s) != 1:
        return False
    cp = ord(s)
    return (0x3400 <= cp <= 0x4DBF or 0x4E00 <= cp <= 0x9FFF
            or 0xF900 <= cp <= 0xFAFF or 0x20000 <= cp <= 0x2FA1F)


def is_primitive(s):
    """Return True when S names a Heisig primitive.

    Primitives come in two shapes.  Those Unicode does not encode as a
    kanji are written as a bracketed English name -- "[apron]".  The
    rest are single characters outside the Han blocks: radicals from
    the CJK Radicals Supplement and Kangxi blocks, and a handful of
    katakana and symbols used for their shape (ハ, ヨ, `∈').  Both are
    referenced from `primitives' and `primitive_of', so leaving either
    out would leave those component links dangling.

    The single-character test is "not ASCII" rather than a block list:
    the set of shapes in use is open-ended, while the only ASCII value
    ever seen in this field is a stray "[" from a malformed note.
    """
    if len(s) > 2 and s.startswith("[") and s.endswith("]"):
        return True
    return len(s) == 1 and ord(s) > 0x2000


def entry_kind(s):
    """Return "kanji", "primitive", or None when S is neither."""
    if is_kanji(s):
        return "kanji"
    if is_primitive(s):
        return "primitive"
    return None


# --- Kana to romaji ---------------------------------------------------
#
# Stored alongside each reading rather than derived when a row is
# drawn: it is the same answer every time, and a list of 2000 kanji
# would otherwise transliterate every reading on every redraw.  The
# spelling is the one a Japanese IME expects, not strict Hepburn --
# these exist to be typed at a filter prompt, so plain ASCII with no
# macrons, and `shi' rather than `si'.

KANA_ROMAJI = {
    "きゃ": "kya", "きゅ": "kyu", "きょ": "kyo",
    "ぎゃ": "gya", "ぎゅ": "gyu", "ぎょ": "gyo",
    "しゃ": "sha", "しゅ": "shu", "しょ": "sho", "しぇ": "she",
    "じゃ": "ja", "じゅ": "ju", "じょ": "jo", "じぇ": "je",
    "ちゃ": "cha", "ちゅ": "chu", "ちょ": "cho", "ちぇ": "che",
    "ぢゃ": "ja", "ぢゅ": "ju", "ぢょ": "jo",
    "にゃ": "nya", "にゅ": "nyu", "にょ": "nyo",
    "ひゃ": "hya", "ひゅ": "hyu", "ひょ": "hyo",
    "びゃ": "bya", "びゅ": "byu", "びょ": "byo",
    "ぴゃ": "pya", "ぴゅ": "pyu", "ぴょ": "pyo",
    "みゃ": "mya", "みゅ": "myu", "みょ": "myo",
    "りゃ": "rya", "りゅ": "ryu", "りょ": "ryo",
    "ふぁ": "fa", "ふぃ": "fi", "ふぇ": "fe", "ふぉ": "fo",
    "てぃ": "ti", "でぃ": "di", "とぅ": "tu", "どぅ": "du",
    "うぃ": "wi", "うぇ": "we", "うぉ": "wo",
    "ゔぁ": "va", "ゔぃ": "vi", "ゔぇ": "ve", "ゔぉ": "vo",
    "あ": "a", "い": "i", "う": "u", "え": "e", "お": "o",
    "か": "ka", "き": "ki", "く": "ku", "け": "ke", "こ": "ko",
    "が": "ga", "ぎ": "gi", "ぐ": "gu", "げ": "ge", "ご": "go",
    "さ": "sa", "し": "shi", "す": "su", "せ": "se", "そ": "so",
    "ざ": "za", "じ": "ji", "ず": "zu", "ぜ": "ze", "ぞ": "zo",
    "た": "ta", "ち": "chi", "つ": "tsu", "て": "te", "と": "to",
    "だ": "da", "ぢ": "ji", "づ": "zu", "で": "de", "ど": "do",
    "な": "na", "に": "ni", "ぬ": "nu", "ね": "ne", "の": "no",
    "は": "ha", "ひ": "hi", "ふ": "fu", "へ": "he", "ほ": "ho",
    "ば": "ba", "び": "bi", "ぶ": "bu", "べ": "be", "ぼ": "bo",
    "ぱ": "pa", "ぴ": "pi", "ぷ": "pu", "ぺ": "pe", "ぽ": "po",
    "ま": "ma", "み": "mi", "む": "mu", "め": "me", "も": "mo",
    "や": "ya", "ゆ": "yu", "よ": "yo",
    "ら": "ra", "り": "ri", "る": "ru", "れ": "re", "ろ": "ro",
    "わ": "wa", "ゐ": "wi", "ゑ": "we", "を": "wo", "ん": "n",
    "ゔ": "vu",
    "ぁ": "a", "ぃ": "i", "ぅ": "u", "ぇ": "e", "ぉ": "o",
    "ゃ": "ya", "ゅ": "yu", "ょ": "yo", "ゎ": "wa",
}

# Markers a dictionary uses inside a reading: `.' opens the okurigana,
# and a leading or trailing `-' marks a prefix or a suffix.  They carry
# real information, which is why the kana is stored as it came -- but
# the romaji exists to be typed, and `muzuka.shii' is not what anyone
# would type to find it.
READING_MARKERS = ".-・"

SOKUON = "っ"
CHOONPU = "ー"
VOWELS = "aiueo"


def katakana_to_hiragana(text):
    """Return TEXT with every katakana turned into its hiragana twin."""
    return "".join(
        chr(ord(ch) - 0x60) if "ァ" <= ch <= "ヶ" else ch
        for ch in text)


def kana_to_romaji(reading):
    """Return READING transliterated, or "" when it has no kana.

    Unknown characters are passed through: a reading is occasionally
    already Latin, and dropping what we cannot name would silently
    produce a shorter, wrong answer.
    """
    if not reading:
        return ""
    kana = katakana_to_hiragana(reading)
    out = []
    i = 0
    while i < len(kana):
        ch = kana[i]
        if ch in READING_MARKERS:
            i += 1
            continue
        if ch == SOKUON:
            # The small tsu doubles the consonant that follows it, and
            # `chi' doubles as `tchi' rather than `cchi'.  At the end
            # of a reading there is no consonant to double -- 50 of
            # them end this way, イッ and ハッ among them -- and the
            # conventional stand-in is `t', which also keeps ハッ from
            # collapsing onto ハ.
            nxt = kana_to_romaji(kana[i + 1:i + 3])
            out.append("t" if (not nxt or nxt.startswith("ch"))
                       else nxt[0])
            i += 1
            continue
        if ch == CHOONPU:
            # The long mark repeats whatever vowel it lengthens.
            previous = "".join(out)
            if previous and previous[-1] in VOWELS:
                out.append(previous[-1])
            i += 1
            continue
        pair = kana[i:i + 2]
        if pair in KANA_ROMAJI:
            out.append(KANA_ROMAJI[pair])
            i += 2
            continue
        out.append(KANA_ROMAJI.get(ch, ch))
        i += 1
    return "".join(out)


def warn(msg):
    print("build-heisig-db: %s" % msg, file=sys.stderr)


# --- Anki -------------------------------------------------------------

def open_anki_copy(path):
    """Copy the collection to a temp file and open it read-only.

    Anki holds a WAL lock on the live collection; opening it directly
    can fail or read a torn state.  The copy is the caller's to delete.
    """
    tmp = tempfile.NamedTemporaryFile(suffix=".anki2", delete=False)
    tmp.close()
    shutil.copyfile(path, tmp.name)
    con = sqlite3.connect(tmp.name)
    con.text_factory = str
    # Anki declares `unicase' on its name columns and indexes them with
    # it.  SQLite refuses to plan a query against an index whose
    # collation it does not know ("no query solution"), so the name has
    # to exist even though nothing here depends on its exact ordering.
    con.create_collation(
        "unicase",
        lambda a, b: (a.lower() > b.lower()) - (a.lower() < b.lower()))
    return con, tmp.name


def deck_ids(con, names):
    """Return the ids of every deck in NAMES, including its subdecks.

    Anki separates deck-name components with FIELD_SEP; "::" is how the
    same name is written in the interface, so both are accepted.
    """
    ids = []
    rows = con.execute("SELECT id, name FROM decks").fetchall()
    for name in names:
        want = name.replace("::", FIELD_SEP)
        found = [i for i, n in rows
                 if n == want or n.startswith(want + FIELD_SEP)]
        if not found:
            warn("deck not found: %s" % name)
        ids.extend(found)
    return ids


def field_names(con, mid):
    """Return the field names of notetype MID, in ordinal order."""
    rows = con.execute(
        "SELECT ord, name FROM fields WHERE ntid = ? ORDER BY ord",
        (mid,)).fetchall()
    return [n for _, n in rows]


def anki_notes(con, dids):
    """Yield (mid, field-name -> value) for every note in decks DIDS.

    Cards in a filtered deck keep their home deck in `odid'; that is the
    deck the note really belongs to, so it is what we match on.
    """
    if not dids:
        return
    placeholders = ",".join("?" * len(dids))
    sql = ("SELECT DISTINCT n.id, n.mid, n.flds FROM cards c "
           "JOIN notes n ON c.nid = n.id "
           "WHERE COALESCE(NULLIF(c.odid, 0), c.did) IN (%s)" % placeholders)
    names_cache = {}
    for _nid, mid, flds in con.execute(sql, dids):
        if mid not in names_cache:
            names_cache[mid] = field_names(con, mid)
        names = names_cache[mid]
        values = flds.split(FIELD_SEP)
        yield mid, dict(zip(names, values))


def collect_anki(path, decks):
    """Return (migaku, academy) dicts mapping kanji -> note data.

    The two notetypes are told apart by the fields they carry rather
    than by id, so a re-imported deck with a fresh notetype id still
    works.
    """
    con, tmp = open_anki_copy(path)
    try:
        dids = deck_ids(con, decks)
        migaku, academy = {}, {}
        dup_migaku, dup_academy, skipped = [], [], []
        for _mid, note in anki_notes(con, dids):
            char = note.get("Character", "")
            if entry_kind(char) is None:
                skipped.append(char)
                continue
            if "MigakuData" in note:
                data = decode_migaku(note["MigakuData"])
                if data is None:
                    skipped.append(char)
                    continue
                data["_svg"] = note.get("StrokeOrder", "")
                if char in migaku:
                    dup_migaku.append(char)
                migaku[char] = data
            elif "ComponentBreakdown" in note:
                if char in academy:
                    dup_academy.append(char)
                academy[char] = note
        if skipped:
            warn("skipped %d note(s) with no usable kanji: %s"
                 % (len(skipped), " ".join(sorted(set(skipped))[:20])))
        for label, dups in (("kanjiMigaku", dup_migaku),
                            ("kanjiAcademy", dup_academy)):
            if dups:
                warn("%s: %d duplicate note(s), last wins: %s"
                     % (label, len(dups), " ".join(sorted(set(dups)))))
        return migaku, academy
    finally:
        con.close()
        os.unlink(tmp)


def decode_migaku(value):
    """Decode a MigakuData field, or return None when it is unusable.

    `primitives_detail' and `primitive_of_detail' are dropped: they are
    whole nested copies of other kanji records and account for 22 MB of
    the 22.4 MB of decoded JSON, all of it re-derivable from the
    component tables.
    """
    try:
        data = json.loads(base64.b64decode(value))
    except Exception:
        return None
    if not isinstance(data, dict) or not data.get("has_result"):
        return None
    data.pop("primitives_detail", None)
    data.pop("primitive_of_detail", None)
    return data


# --- kanji-all.json ---------------------------------------------------

def collect_json(path):
    """Return a dict mapping kanji -> entry from kanji-all.json."""
    if not path:
        return {}
    with open(path, encoding="utf-8") as stream:
        entries = json.load(stream)
    out = {}
    for entry in entries:
        char = entry.get("kanji", "")
        if entry_kind(char) == "kanji":
            out[char] = entry
    return out


def as_int(value):
    """Return VALUE as an int, or None when it is not a number.

    The JSON source stores every number as a string and uses the empty
    string for "unknown", so plain int() is not enough.
    """
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


FREQ_UNKNOWN = 999999


def as_freq(value):
    """Return VALUE as a frequency rank, or None when it is unknown.

    Both Anki sources spell "no frequency data" as the sentinel 999999
    rather than as a missing key; left alone it would sort every
    unranked kanji in among the genuinely rare ones.
    """
    value = as_int(value)
    return None if value is None or value >= FREQ_UNKNOWN else value


NULL_TOKENS = frozenset(("none", "null", "nan", "undefined"))


JLPT_LEVELS = frozenset((1, 2, 3, 4, 5))


def as_jlpt(value):
    """Return VALUE as a JLPT level, or None when it is not one.

    The levels are N5 (easiest) through N1.  The JSON source spells
    "no level" as "0" for 114 kanji and as the empty string for two
    more; one column carrying two spellings of absent is how the kanji
    and the word list came to need different code to render the same
    field, and how `0' came to be offered at the by-jlpt prompt as
    though it were a level.
    """
    value = as_int(value)
    return value if value in JLPT_LEVELS else None


def blank_to_none(value):
    """Return None for a string that carries no value, else VALUE.

    Empty and whitespace-only strings, and the handful of spellings a
    null acquires when something stringifies it on the way into JSON.
    Two component glosses in kanji-all.json are the literal text
    "None"; left alone they name a component "None" and offer it as a
    filter candidate.
    """
    if isinstance(value, str):
        if not value.strip():
            return None
        if value.strip().lower() in NULL_TOKENS:
            return None
    return value


def first(*values):
    """Return the first argument that is neither None nor empty."""
    for value in values:
        if value not in (None, "", [], {}):
            return value
    return None


# --- Merge ------------------------------------------------------------

def merge_kanji(char, mig, aca, jsn):
    """Return the `kanji' table row for CHAR, and the source list.

    MIG, ACA and JSN are this kanji's records in the three sources, any
    of which may be None.
    """
    mig = mig or {}
    aca = aca or {}
    jsn = jsn or {}
    sources = [name for name, src in
               (("migaku", mig), ("academy", aca), ("json", jsn)) if src]

    kind = entry_kind(char) or "kanji"
    usr_kw = mig.get("usr_keyword")
    # A primitive has no Heisig frame and therefore no frame keyword;
    # its name lives in `primitive_keywords' instead.
    prim_kw = (mig.get("usr_primitive_keyword")
               or ((mig.get("primitive_keywords") or [None])[0]))
    keyword_candidates = (
        ("usr", usr_kw),
        ("heisig6", mig.get("heisig_keyword6")),
        ("heisig5", mig.get("heisig_keyword5")),
        ("primitive", prim_kw),
        ("academy", aca.get("Keyword")),
        ("json", jsn.get("keyword")))
    keyword, keyword_source = None, None
    for name, value in keyword_candidates:
        if value:
            keyword, keyword_source = value, name
            break

    meanings = mig.get("meanings")
    return {
        "char": char,
        "kind": kind,
        "heisig5": mig.get("heisig_id5"),
        "heisig6": mig.get("heisig_id6"),
        "keyword": keyword,
        "keyword_source": keyword_source,
        "heisig_keyword5": mig.get("heisig_keyword5"),
        "heisig_keyword6": mig.get("heisig_keyword6"),
        "usr_keyword": usr_kw,
        "strokes": first(mig.get("stroke_count"), as_int(jsn.get("strokes"))),
        "grade": mig.get("grade"),
        "jlpt": first(as_jlpt(mig.get("jlpt")),
                      as_jlpt(jsn.get("jlptlevel"))),
        "kanken": mig.get("kanken"),
        "wk": mig.get("wk"),
        "freq_rank": as_freq(mig.get("frequency_rank")),
        "radical": first((mig.get("radicals") or [None])[0],
                         aca.get("Radical"), jsn.get("radical")),
        "meanings": first(", ".join(meanings) if meanings else None,
                          aca.get("Definitions"), jsn.get("henglish")),
        "definitions": first(aca.get("Definitions"), jsn.get("henglish")),
        "top_reading": jsn.get("topreading") or None,
        "top_onyomi": jsn.get("toponyomi") or None,
        "top_kunyomi": jsn.get("topkunyomi") or None,
        "story": first(mig.get("usr_story"), mig.get("heisig_story")),
        "comment": mig.get("heisig_comment"),
        "mnemonic": aca.get("ExampleSentences") or None,
        "stroke_svg": first(mig.get("_svg"), aca.get("StrokeOrder")),
        "sources": ",".join(sources),
    }


def merge_readings(mig, aca, jsn):
    """Return (kind, value) pairs for one kanji, best source first.

    Migaku splits on/kun/nanori explicitly.  Academy packs them into two
    lines, kun first then on, in KANJIDIC order.  The JSON source gives
    only `rt' strings under separate keys.
    """
    if mig:
        out = []
        for kind, key in (("on", "onyomi"), ("kun", "kunyomi"),
                          ("nanori", "nanori")):
            for value in mig.get(key) or []:
                out.append((kind, value))
        if out:
            return out
    if aca and aca.get("Readings"):
        lines = aca["Readings"].split("\n")
        out = []
        for kind, line in zip(("kun", "on"), lines):
            for value in line.split("、"):
                if value.strip():
                    out.append((kind, value.strip()))
        if out:
            return out
    if jsn:
        out = []
        for kind, key in (("on", "onyomi"), ("kun", "kunyomi")):
            for row in jsn.get(key) or []:
                if row.get("rt"):
                    out.append((kind, row["rt"]))
        return out
    return []


def merge_components(mig, aca, jsn):
    """Return (comp_char, keyword, gloss) triples for one kanji.

    Academy is preferred because it is the only source that names and
    glosses each component; Migaku gives bare characters, and the JSON
    source gives space-stripped glosses.
    """
    if aca and aca.get("ComponentBreakdown"):
        out = []
        for line in aca["ComponentBreakdown"].split("\n"):
            parts = line.split(";")
            if parts and parts[0].strip():
                out.append((parts[0].strip(),
                            blank_to_none(parts[1]) if len(parts) > 1 else None,
                            blank_to_none(parts[2]) if len(parts) > 2 else None))
        if out:
            return out
    if mig and mig.get("primitives"):
        keywords = mig.get("primitive_keywords") or []
        return [(comp, keywords[i] if i < len(keywords) else None, None)
                for i, comp in enumerate(mig["primitives"])]
    if jsn and jsn.get("components"):
        out = []
        for part in jsn["components"].split("<br>"):
            comp, _, gloss = part.partition(":")
            if comp.strip():
                out.append((comp.strip(), None, blank_to_none(gloss)))
        return out
    return []


def merge_words(mig, aca, jsn):
    """Return (surface, reading, definition, freq) tuples for one kanji.

    Every source is used: they carry different words, and a compound
    that appears in two of them is deduplicated on its surface form.
    """
    out, seen = [], set()

    def add(surface, reading, definition, freq):
        if surface and surface not in seen:
            seen.add(surface)
            out.append((surface, reading, definition, freq))

    for pair in (mig or {}).get("words_default") or []:
        if isinstance(pair, (list, tuple)) and pair:
            add(pair[0], pair[1] if len(pair) > 1 else None, None, None)
    if aca and aca.get("CompoundWords"):
        for line in aca["CompoundWords"].split("\n"):
            surface, _, reading = line.partition("[")
            add(surface.strip(), reading.rstrip("]").strip() or None,
                None, None)
    for row in (jsn or {}).get("words") or []:
        # Continuation rows repeat the previous word with an empty
        # root, carrying only an extra gloss; they have no surface of
        # their own and are dropped.
        add(row.get("root"), row.get("furigana") or None,
            row.get("definition") or None, as_freq(row.get("frequency")))
    return out


KOOHI_PREFIX = None


def parse_koohi(text):
    """Split a koohi_stories entry into (author, votes, date, text).

    Entries look like "3) [xiteru] 9-10-2007(20): the story".  Anything
    that does not match is returned whole as the text.
    """
    body = text
    if ")" in body[:4]:
        body = body[body.index(")") + 1:].strip()
    author = votes = date = None
    if body.startswith("["):
        end = body.find("]")
        if end > 0:
            author = body[1:end]
            body = body[end + 1:].strip()
    if ":" in body:
        head, _, rest = body.partition(":")
        if "(" in head and head.rstrip().endswith(")"):
            date_part, _, votes_part = head.partition("(")
            date = date_part.strip() or None
            votes = as_int(votes_part.rstrip().rstrip(")"))
            body = rest.strip()
    return author, votes, date, body


def merge_stories(mig, jsn):
    """Return (source, author, votes, date, text) tuples for one kanji."""
    out = []
    for entry in (mig or {}).get("koohi_stories") or []:
        author, votes, date, text = parse_koohi(entry)
        out.append(("koohii", author, votes, date, text))
    if jsn and jsn.get("koohistory1"):
        out.append(("json", None, None, None, jsn["koohistory1"]))
    return out


# --- Vocabulary -------------------------------------------------------
#
# Two sources, neither of them Anki.  The word list and its ordering
# come from a frequency report over Japanese Netflix subtitles; the
# readings, parts of speech and definitions come from the dictionary
# yomikun-gt ships.
#
# Everything that resolves to a dictionary headword is imported, not
# just the common few thousand: a fifth of the report is not really
# vocabulary -- "エポ", "でーん", "ＡＦＣ" -- and where that junk sits
# decides what any given rank cut-off actually contains.  Importing the
# lot leaves the cut-off a setting the reader can move rather than one
# frozen into the file.

UNIDIC_DISAMBIGUATOR = "-"


def distinct_chars(word):
    """Return the distinct characters of WORD, in the order written."""
    return "".join(dict.fromkeys(word))


def read_tango(specs):
    """Return a dict mapping a lemma to its JLPT level.

    SPECS are "LEVEL=PATH" strings naming the vocabulary databases
    yomikun-gt ships, one per level.  They are cumulative -- every N5
    word is also in the N4 list -- so a word takes the easiest level
    it appears in, which is the highest number.

    Only N5, N4 and N3 exist; a word above them has no level rather
    than a wrong one.
    """
    levels = {}
    for spec in specs or ():
        level, _, path = spec.partition("=")
        if not path:
            warn("ignoring malformed --tango %r, want LEVEL=PATH" % spec)
            continue
        con = sqlite3.connect(path)
        con.text_factory = str
        try:
            for (morph,) in con.execute("SELECT morph FROM words"):
                lemma = emacsql_unquote(morph)
                current = levels.get(lemma)
                if current is None or int(level) > current:
                    levels[lemma] = int(level)
        finally:
            con.close()
    return levels


def headword_candidates(record, with_reading=False):
    """Return the headwords RECORD might be listed under, best first.

    UniDic writes a lemma with the sense that disambiguates it
    attached -- `私-代名詞', `ママ-mama' -- which no headword carries,
    so the bare lemma is tried next, then the spelling that appeared
    on screen.

    WITH_READING adds the reading, which is how kana-only words like
    `だけ' resolve in the dictionary.  The JLPT lists are keyed by
    lemma and spelling only, so matching a reading against them would
    be matching on something they do not record.
    """
    lemma = record["lemma"]
    candidates = [lemma,
                  lemma.split(UNIDIC_DISAMBIGUATOR)[0],
                  record["surface"]]
    if with_reading:
        candidates.append(record["reading"])
    return [c for c in candidates if c]


def lookup_jlpt(record, levels):
    """Return the JLPT level of RECORD, or None."""
    for candidate in headword_candidates(record):
        if candidate in levels:
            return levels[candidate]
    return None

MAX_SENSES = 5


def dictionary_index(path):
    """Return a dict mapping headword -> list of (reading, pos, definition).

    Every value in that database was written by emacsql, which wraps
    each one in literal double quotes -- `を' is stored as `"を"'.  They
    are stripped here, once, so nothing downstream has to know.
    """
    con = sqlite3.connect(path)
    con.text_factory = str
    index = {}
    try:
        for root, pronun, pos, definition in con.execute(
                "SELECT root, pronun, pos, def FROM dict"):
            index.setdefault(emacsql_unquote(root), []).append(
                (emacsql_unquote(pronun), emacsql_unquote(pos),
                 emacsql_unquote(definition)))
    finally:
        con.close()
    return index


def emacsql_unquote(value):
    """Return VALUE without the double quotes emacsql stored it inside."""
    if (isinstance(value, str) and len(value) > 1
            and value.startswith('"') and value.endswith('"')):
        return value[1:-1]
    return value


def read_netflix(path):
    """Yield one record per line of the Netflix frequency report.

    The report is ordered by descending frequency, so its line order is
    the ordering; the rank columns it carries are dense over tied
    counts and do not number the lines.
    """
    with open(path, encoding="utf-8") as stream:
        for position, line in enumerate(stream, start=1):
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 10:
                continue
            # Field 1 is the dictionary form, 2 the orthography as it
            # appeared on screen, and 3 the pronunciation in katakana.
            # The middle two are easy to confuse: for 目指す all three
            # read 目指す, 目指す, メザス, but for 為る they read 為る,
            # する, スル.
            yield {
                "netflix_rank": position,
                "count": as_int(parts[0]) or 0,
                "lemma": parts[1],
                "surface": parts[2],
                "reading": katakana_to_hiragana(parts[3]),
                "unidic_pos": parts[4],
            }


def as_float(value):
    """Return VALUE as a float, or None when it is not a number."""
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def resolve_word(record, index):
    """Return (ROOT, SENSES) for RECORD, or (None, None) when unknown.

    Tried under each of `headword_candidates', the reading included.
    """
    for candidate in headword_candidates(record, with_reading=True):
        if candidate in index:
            return candidate, index[candidate]
    return None, None


def choose_sense(senses, reading):
    """Return the (POS, DEFINITION) that best describes a word.

    A headword carries one row per sense, and the dictionary keeps
    homographs under the same one -- 「気」 is both `ki' and `ke'.  The
    senses that match the reading the corpus actually recorded are the
    ones worth showing, and only when none does are the rest used.
    """
    matching = [s for s in senses if s[0] == reading] or senses
    pos = matching[0][1]
    seen, definitions = set(), []
    for _reading, _pos, definition in matching:
        if definition and definition not in seen:
            seen.add(definition)
            definitions.append(definition)
        if len(definitions) >= MAX_SENSES:
            break
    return pos, "; ".join(definitions) or None


def collect_vocab(netflix_path, dictionary_path, tango_specs=None):
    """Return the vocabulary rows, densely ranked in Netflix order.

    One word occupies several lines of the report, one per spelling
    and part of speech the tokeniser saw -- 言う is counted separately
    as 言う, いう and 言える.  They are merged on the headword and
    reading they resolved to, keeping the position of the commonest
    spelling and summing the counts, so a word is ranked by how often
    it was heard rather than by how often it was heard spelled one
    particular way.

    `pct' and `cum_pct' are recomputed over the merged counts, against
    the size of the whole corpus rather than of what was imported --
    so cumulative coverage answers "how much of Netflix do the first N
    words accounts for", and stops short of 100% by however much the
    dropped entries were worth.
    """
    if not netflix_path or not dictionary_path:
        return []
    index = dictionary_index(dictionary_path)
    levels = read_tango(tango_specs)
    merged, order, dropped, corpus, read = {}, [], 0, 0, 0
    for record in read_netflix(netflix_path):
        corpus += record["count"]
        read += 1
        root, senses = resolve_word(record, index)
        if root is None:
            dropped += 1
            continue
        key = (root, record["reading"])
        if key in merged:
            merged[key]["count"] += record["count"]
            continue
        pos, definition = choose_sense(senses, record["reading"])
        merged[key] = {
            "netflix_rank": record["netflix_rank"],
            "lemma": record["lemma"].split(UNIDIC_DISAMBIGUATOR)[0],
            "surface": record["surface"],
            "root": root,
            "reading": record["reading"],
            "romaji": blank_to_none(kana_to_romaji(record["reading"])),
            "pos": pos,
            "unidic_pos": record["unidic_pos"],
            "jlpt": as_jlpt(lookup_jlpt(record, levels)),
            "definition": definition,
            # Computed here, once, and the only definition of what a
            # word "is written with": the row carries it for the elisp
            # filter and `vocab_char' indexes this same string for the
            # SQL seed, so the two cannot drift apart.
            "chars": distinct_chars(root),
            "count": record["count"],
        }
        order.append(key)

    rows, running = [], 0
    for rank, key in enumerate(order, start=1):
        row = merged[key]
        running += row["count"]
        row["rank"] = rank
        row["pct"] = 100.0 * row["count"] / corpus if corpus else None
        row["cum_pct"] = 100.0 * running / corpus if corpus else None
        rows.append(row)

    warn("vocabulary: %d words from %d entries (%d spellings merged, "
         "%d matched no dictionary headword)"
         % (len(rows), read, read - dropped - len(rows), dropped))
    return rows


VOCAB_COLUMNS = ["rank", "netflix_rank", "lemma", "surface", "root", "reading",
                 "romaji", "pos", "unidic_pos", "jlpt", "definition",
                 "chars", "count",
                 "pct", "cum_pct"]


# --- Write ------------------------------------------------------------

KANJI_COLUMNS = [
    "char", "kind", "heisig5", "heisig6", "keyword", "keyword_source",
    "heisig_keyword5", "heisig_keyword6", "usr_keyword", "strokes",
    "grade", "jlpt", "kanken", "wk", "freq_rank", "radical", "meanings",
    "definitions", "top_reading", "top_onyomi", "top_kunyomi", "story",
    "comment", "mnemonic", "stroke_svg", "sources"]


def build(migaku, academy, jsondata, vocab, out_path):
    """Write the merged database to OUT_PATH, replacing any old one."""
    if os.path.exists(out_path):
        os.unlink(out_path)
    con = sqlite3.connect(out_path)
    con.executescript(SCHEMA)

    chars = sorted(set(migaku) | set(academy) | set(jsondata))
    kanji_rows, reading_rows, comp_rows, comp_of_rows = [], [], [], []
    word_rows, def_rows, story_rows = [], [], []

    for char in chars:
        mig, aca, jsn = (migaku.get(char), academy.get(char),
                         jsondata.get(char))
        row = merge_kanji(char, mig, aca, jsn)
        kanji_rows.append(tuple(blank_to_none(row[c]) for c in KANJI_COLUMNS))

        for i, (kind, value) in enumerate(merge_readings(mig, aca, jsn)):
            reading_rows.append((char, kind, value,
                                 blank_to_none(kana_to_romaji(value)), i))
        for i, (comp, kw, gloss) in enumerate(merge_components(mig, aca, jsn)):
            comp_rows.append((char, i, comp, kw, gloss))
        for i, comp in enumerate((mig or {}).get("primitive_of") or []):
            comp_of_rows.append((char, i, comp))
        for i, word in enumerate(merge_words(mig, aca, jsn)):
            word_rows.append((char, i) + word)
        for i, d in enumerate((jsn or {}).get("miadefinition") or []):
            def_rows.append((char, i, d.get("term") or None,
                             d.get("pronunciation") or None,
                             d.get("pos") or None,
                             d.get("definition") or None,
                             as_freq(d.get("frequency")),
                             d.get("starCount") or None))
        for i, story in enumerate(merge_stories(mig, jsn)):
            story_rows.append((char, i) + story)

    con.executemany(
        "INSERT INTO kanji (%s) VALUES (%s)"
        % (",".join(KANJI_COLUMNS), ",".join("?" * len(KANJI_COLUMNS))),
        kanji_rows)
    con.executemany("INSERT INTO reading VALUES (?,?,?,?,?)",
                    reading_rows)
    con.executemany("INSERT INTO component VALUES (?,?,?,?,?)", comp_rows)
    con.executemany("INSERT INTO component_of VALUES (?,?,?)", comp_of_rows)
    con.executemany("INSERT INTO word VALUES (?,?,?,?,?,?)", word_rows)
    con.executemany("INSERT INTO definition VALUES (?,?,?,?,?,?,?,?)",
                    def_rows)
    con.executemany("INSERT INTO story VALUES (?,?,?,?,?,?,?)", story_rows)

    con.executemany(
        "INSERT INTO vocab (%s) VALUES (%s)"
        % (",".join(VOCAB_COLUMNS), ",".join("?" * len(VOCAB_COLUMNS))),
        [tuple(row[c] for c in VOCAB_COLUMNS) for row in vocab])
    con.executemany(
        "INSERT INTO vocab_char VALUES (?,?)",
        [(ch, row["rank"]) for row in vocab for ch in row["chars"]])

    counts = {
        "schema_version": SCHEMA_VERSION,
        "built": time.strftime("%Y-%m-%d %H:%M:%S"),
        "kanji": sum(1 for r in kanji_rows
                     if r[KANJI_COLUMNS.index("kind")] == "kanji"),
        "primitives": sum(1 for r in kanji_rows
                          if r[KANJI_COLUMNS.index("kind")] == "primitive"),
        "from_migaku": len(migaku),
        "from_academy": len(academy),
        "from_json": len(jsondata),
        "readings": len(reading_rows),
        "components": len(comp_rows),
        "component_of": len(comp_of_rows),
        "words": len(word_rows),
        "definitions": len(def_rows),
        "stories": len(story_rows),
        "vocab": len(vocab),
        "with_heisig6": sum(1 for r in kanji_rows
                            if r[KANJI_COLUMNS.index("heisig6")]),
    }
    con.executemany("INSERT INTO meta VALUES (?,?)",
                    [(k, str(v)) for k, v in counts.items()])
    con.commit()
    con.execute("VACUUM")
    con.close()
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--anki", help="path to collection.anki2")
    parser.add_argument("--json", help="path to kanji-all.json")
    parser.add_argument("--out", required=True, help="database to write")
    parser.add_argument("--netflix",
                        help="Netflix subtitle word-frequency report")
    parser.add_argument("--dictionary",
                        help="yomikun-gt dictionary database")
    parser.add_argument("--tango", action="append",
                        help="JLPT vocabulary list as LEVEL=PATH "
                             "(repeatable)")
    parser.add_argument("--deck", action="append", default=None,
                        help="Anki deck to read (repeatable); defaults to "
                             "jp::kanjiMigaku and jp::kanjiAcademy")
    args = parser.parse_args()

    if not args.anki and not args.json:
        parser.error("at least one of --anki and --json is required")

    decks = args.deck or ["jp::kanjiMigaku", "jp::kanjiAcademy"]
    migaku, academy = ({}, {})
    if args.anki:
        migaku, academy = collect_anki(args.anki, decks)
    jsondata = collect_json(args.json)

    vocab = collect_vocab(args.netflix, args.dictionary, args.tango)

    counts = build(migaku, academy, jsondata, vocab, args.out)
    width = max(len(k) for k in counts)
    for key, value in counts.items():
        print("%-*s  %s" % (width, key, value))
    print("%-*s  %s bytes" % (width, "file", os.path.getsize(args.out)))


if __name__ == "__main__":
    main()
