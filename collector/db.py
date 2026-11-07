"""The bird log: one SQLite file beside the photos, in archive/birds.db.

A visit is one time something came to the feeder (a Bird Buddy postcard, or
photos we imported). Its media are files under archive/. Each time someone
identifies a visit (Claude, or the owner correcting it), that's a new
identification with its sightings: which species, how many. Nothing is
overwritten, so Bird Buddy's guess, every Claude run and the owner's word all
stay side by side. The "current" answer for a visit is the owner's latest if
they gave one, otherwise Claude's latest. Digests are Claude's short story of
the last 7 or 30 days, a new one each time, for the screen.

Visits come from three places: Bird Buddy postcards (photos, exact time),
Bird Buddy's visit report (source "bb-report": a species and a count per
hour, no photos), and imports. Alongside them sit the feeder's readings,
the weekly essay, the note cards, and what Bird Buddy says about each
species.
"""

from __future__ import annotations

import config
import re
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

ARCHIVE = Path(__file__).resolve().parent.parent / "archive"
DB_PATH = ARCHIVE / "birds.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS visits (
    id            TEXT PRIMARY KEY,  -- Bird Buddy postcard id, or import:<hash>
    source        TEXT NOT NULL,     -- birdbuddy | import | sample
    feeder        TEXT,
    seen_at       TEXT NOT NULL,     -- when it happened, ISO 8601 UTC
    bb_species    TEXT,              -- Bird Buddy's guesses, JSON list
    bb_confidence TEXT,
    raw           TEXT,              -- the source's own JSON, kept to study
    number        INTEGER            -- its catalogue number, if photographed (number_visits)
);

CREATE TABLE IF NOT EXISTS media (
    id        TEXT PRIMARY KEY,      -- Bird Buddy media id, or sha256
    visit_id  TEXT NOT NULL REFERENCES visits(id),
    kind      TEXT NOT NULL,         -- photo | video | frame (a still Claude chose from the video)
    taken_at  TEXT,
    path      TEXT NOT NULL,         -- relative to archive/
    width     INTEGER,
    height    INTEGER,
    public_url TEXT                  -- where the TRMNL can fetch it, if anywhere
);

CREATE TABLE IF NOT EXISTS identifications (
    id             INTEGER PRIMARY KEY,
    visit_id       TEXT NOT NULL REFERENCES visits(id),
    by             TEXT NOT NULL,    -- a model id, or "owner"
    prompt_version TEXT,
    made_at        TEXT NOT NULL,
    caption        TEXT,             -- the feed's sentence, bird in **bold**
    best_media     TEXT,             -- the visit's best photo
    notes          TEXT,             -- what's happening, a sentence or two
    raw            TEXT              -- the model's whole answer
);

CREATE TABLE IF NOT EXISTS sightings (
    identification_id INTEGER NOT NULL REFERENCES identifications(id),
    common_name       TEXT NOT NULL,
    scientific_name   TEXT,          -- the species' key across the log
    is_bird           INTEGER NOT NULL,
    count             INTEGER,       -- most seen at once in one frame
    confidence        TEXT,          -- high | medium | low
    details           TEXT           -- sex, age, plumage, behavior
);

CREATE TABLE IF NOT EXISTS digests (
    id          INTEGER PRIMARY KEY,
    days        INTEGER NOT NULL,    -- the rolling window: 7, 30
    ends_at     TEXT NOT NULL,       -- the window is the days before this
    made_at     TEXT NOT NULL,
    by          TEXT NOT NULL,
    headline    TEXT NOT NULL,       -- a few words, for the top of the screen
    narrative   TEXT NOT NULL,       -- two or three sentences
    raw         TEXT
);

CREATE TABLE IF NOT EXISTS feeder_state (
    at          TEXT NOT NULL,       -- when the collector read it
    feeder      TEXT,
    state       TEXT,                -- ONLINE, OFFLINE, DEEP_SLEEP, ...
    food        TEXT,                -- HIGH | MEDIUM | LOW: all Bird Buddy says
    battery     INTEGER,             -- percent
    charging    INTEGER,
    signal      INTEGER,
    temperature REAL,
    latitude    REAL,
    longitude   REAL
);

-- The story: a dateline and paragraphs, each about one bird with
-- its name in **bold** and the photo that goes with it.
CREATE TABLE IF NOT EXISTS essays (
    id          INTEGER PRIMARY KEY,
    written_at  TEXT NOT NULL,
    by          TEXT NOT NULL,
    dateline    TEXT NOT NULL,
    paragraphs  TEXT NOT NULL        -- JSON [{"text": ..., "media_id": ...}]
);

-- Every call to Claude: what it was for, the tokens, and what it cost.
CREATE TABLE IF NOT EXISTS claude_calls (
    at                 TEXT NOT NULL,
    purpose            TEXT NOT NULL, -- identify | story | cards | digest
    model              TEXT NOT NULL,
    effort             TEXT,
    input_tokens       INTEGER,
    output_tokens      INTEGER,      -- includes Claude's thinking
    cache_read_tokens  INTEGER,
    cache_write_tokens INTEGER,
    cost_usd           REAL,
    request_id         TEXT
);

-- Each time Claude reconsidered the story: kept, revised or new, and why.
-- Tonight's note: the day summed up, one per day, written after sunset.
CREATE TABLE IF NOT EXISTS day_notes (
    day        TEXT PRIMARY KEY,     -- local date, YYYY-MM-DD
    written_at TEXT NOT NULL,
    by         TEXT NOT NULL,
    text       TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS essay_checks (
    at       TEXT NOT NULL,
    decision TEXT NOT NULL,          -- keep | revise | new
    reason   TEXT
);

-- Cards for the board's note slots. Made once, dealt many times.
CREATE TABLE IF NOT EXISTS cards (
    id            INTEGER PRIMARY KEY,
    deck          TEXT NOT NULL,     -- species | season | practical
    label         TEXT NOT NULL,     -- "Did you know", "Listen for", ...
    text          TEXT NOT NULL,     -- one or two complete sentences
    species       TEXT,              -- scientific name it's about, if any
    month_from    INTEGER,           -- season window, 1-12, inclusive
    month_to      INTEGER,
    made_by       TEXT NOT NULL,
    made_at       TEXT NOT NULL,
    link          TEXT,              -- a URL its QR code opens (a call, a page)
    shown_count   INTEGER NOT NULL DEFAULT 0,
    last_shown_at TEXT,
    retired       INTEGER NOT NULL DEFAULT 0
);

-- What Bird Buddy tells us about each species: its names, profile,
-- illustration and recordings. Fetched once per species.
CREATE TABLE IF NOT EXISTS species_info (
    bb_id           TEXT PRIMARY KEY,
    common_name     TEXT NOT NULL,
    scientific_name TEXT,
    description     TEXT,            -- Bird Buddy's own words: a source, not for copying
    icon_url        TEXT,            -- a public illustration, used until we have photos
    song_url        TEXT,            -- a public recording
    song_author     TEXT,
    fetched_at      TEXT NOT NULL
);

-- The hours already read from Bird Buddy's visit report, so each past
-- hour is asked for once.
CREATE TABLE IF NOT EXISTS report_hours (
    hour_start TEXT PRIMARY KEY,     -- ISO 8601 UTC
    visits     INTEGER NOT NULL,
    fetched_at TEXT NOT NULL
);

-- What people did in the app, as their phones sent it (feed.take_inbox):
-- a visit kept, or its bird corrected. A correction becomes the owner's
-- identification once applied.
CREATE TABLE IF NOT EXISTS phone_marks (
    id          TEXT PRIMARY KEY,    -- the phone's own id for the mark
    kind        TEXT NOT NULL,       -- keep | correct
    visit_id    TEXT NOT NULL,
    body        TEXT NOT NULL,       -- the mark as sent, JSON
    received_at TEXT NOT NULL,
    applied_at  TEXT                 -- when a correction was applied
);

-- What Claude saw of the seed tray in a visit's photos (identify.py): the
-- seed is something seen, like the birds. Bird Buddy's food sensor reads
-- LOW for our account whatever the tray holds.
CREATE TABLE IF NOT EXISTS trays (
    visit_id TEXT PRIMARY KEY REFERENCES visits(id),
    tray     TEXT NOT NULL,       -- plenty | some | few | empty | unseen
    by       TEXT NOT NULL,       -- the model that looked
    made_at  TEXT NOT NULL
);

-- The birds likely at the feeder this month that haven't come yet
-- (likely.py), written by Claude once a month.
CREATE TABLE IF NOT EXISTS likely (
    month   TEXT PRIMARY KEY,     -- 2026-10
    birds   TEXT NOT NULL,        -- JSON: common_name, scientific_name, chance, note
    by      TEXT NOT NULL,
    made_at TEXT NOT NULL
);

-- Each phone that wants notifications (feed.take_inbox): its push token,
-- which kinds it asked for and the birds it follows. Replaced whenever the
-- phone sends a different one.
CREATE TABLE IF NOT EXISTS push_devices (
    device     TEXT PRIMARY KEY,  -- the phone's own id, as in its marks
    token      TEXT,              -- APNs device token, hex; NULL once Apple refuses it
    env        TEXT,              -- production (TestFlight) | sandbox (Xcode, simulator)
    status     TEXT,              -- authorized | provisional | denied | ...
    kinds      TEXT NOT NULL,     -- JSON list: visit, good, new, follow, note, story, seed, decide, broken
    follow     TEXT NOT NULL,     -- JSON list of bird keys (the feed's slugs)
    first_seen TEXT NOT NULL,     -- nothing from before this is sent to it
    updated_at TEXT NOT NULL
);

-- Every notification decided for a phone (notify.py), so none goes twice.
CREATE TABLE IF NOT EXISTS notifications (
    key     TEXT NOT NULL,        -- what it's about: visit:<id>, note:<day>, seed:<seen>...
    device  TEXT NOT NULL,
    kind    TEXT NOT NULL,        -- the kind it went as
    sent_at TEXT NOT NULL,
    status  TEXT NOT NULL,        -- sent | folded (into an "earlier" one) | unsent (no key) | refused: <reason>
    payload TEXT,
    PRIMARY KEY (key, device)
);

-- Views are rebuilt on every connect: SQLite fixes a view's "*" columns when
-- it's created, so a view made before a column was added never sees it.
DROP VIEW IF EXISTS species;
DROP VIEW IF EXISTS log;
DROP VIEW IF EXISTS current_identifications;

-- Each visit's current identification: the owner's latest, else the latest.
CREATE VIEW current_identifications AS
SELECT i.* FROM identifications i
WHERE i.id = (
    SELECT j.id FROM identifications j
    WHERE j.visit_id = i.visit_id
    ORDER BY (j.by = 'owner') DESC, j.made_at DESC, j.id DESC
    LIMIT 1
);

-- The log: every visit with what was in it, newest first.
CREATE VIEW log AS
SELECT v.id AS visit_id, v.seen_at, s.common_name, s.scientific_name,
       s.is_bird, s.count, s.confidence, s.details, ci.notes, ci.by
FROM visits v
JOIN current_identifications ci ON ci.visit_id = v.id
JOIN sightings s ON s.identification_id = ci.id
ORDER BY v.seen_at DESC;

-- The species table: every kind of bird that's come, with its visits.
CREATE VIEW species AS
SELECT scientific_name,
       MAX(common_name)          AS common_name,
       COUNT(DISTINCT visit_id)  AS visits,
       MAX(count)                AS most_at_once,
       MIN(seen_at)              AS first_seen,
       MAX(seen_at)              AS last_seen
FROM log
WHERE is_bird = 1
GROUP BY scientific_name
ORDER BY visits DESC;
"""


# Columns added after a table first existed: (table, column, type).
ADDED = [("media", "public_url", "TEXT"), ("identifications", "caption", "TEXT"),
         ("cards", "link", "TEXT"), ("identifications", "best_media", "TEXT"),
         ("visits", "number", "INTEGER")]


def connect() -> sqlite3.Connection:
    ARCHIVE.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    for table, column, kind in ADDED:
        cols = {r["name"] for r in conn.execute(f"PRAGMA table_info({table})")}
        if cols and column not in cols:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {kind}")
    conn.executescript(SCHEMA)
    return conn


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def number_visits(conn) -> int:
    """Give each photographed visit (a postcard or an import) its catalogue
    number, the way a naturalist numbers specimens: once, in the order they
    came into the archive, never changed. The first ones were numbered by
    when they happened. Bird Buddy's hourly reports have no photo and no
    number. Returns how many were numbered."""
    start = conn.execute("SELECT COALESCE(MAX(number), 0) FROM visits").fetchone()[0]
    new = [r["id"] for r in conn.execute(
        "SELECT id FROM visits WHERE number IS NULL AND source IN ('birdbuddy', 'import') "
        "ORDER BY seen_at, id")]
    for n, visit_id in enumerate(new, start + 1):
        conn.execute("UPDATE visits SET number = ? WHERE id = ?", (n, visit_id))
    if new:
        conn.commit()
    return len(new)


def place(conn) -> tuple[float, float]:
    """Where the feeder is, from its last reading; config.HOME until there is one."""
    state = conn.execute("SELECT latitude, longitude FROM feeder_state "
                         "WHERE latitude IS NOT NULL ORDER BY at DESC LIMIT 1").fetchone()
    return (state[0], state[1]) if state else config.HOME


def binomial(name: str | None) -> str:
    """Genus and species only: "Junco hyemalis [oreganus Group]" is a Junco hyemalis."""
    return " ".join((name or "").split()[:2])


def species_of(sighting: dict) -> dict:
    """A sighting keyed by its species, with any form moved into its details:
    "Dark-eyed Junco (Oregon)", Junco hyemalis [oreganus Group], becomes a
    Dark-eyed Junco, Junco hyemalis, "Oregon form." A hybrid ("x") keeps its name."""
    common, scientific = sighting["common_name"], sighting["scientific_name"] or ""
    if " x " in scientific or binomial(scientific) == scientific.strip():
        return sighting
    form = re.search(r"\(([^)]+)\)\s*$", common)
    form = form[1] if form else " ".join(scientific.split()[2:]).strip("[]")
    details = f"{form} form. {sighting.get('details') or ''}".strip()
    return {**sighting, "common_name": re.sub(r"\s*\([^)]*\)\s*$", "", common),
            "scientific_name": binomial(scientific), "details": details}


SETTLING = timedelta(days=7)  # watching this long before a species can be "new"
MILESTONES = (10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000)


def yard(conn, now: datetime) -> dict:
    """The yard list and this week's firsts.

    The list is every bird species Claude has seen in the feeder's photos
    and is sure of (high confidence), in the order each was first
    photographed; a probable bird waits for a clear photo. A species is new to the yard
    when nobody (Claude or Bird Buddy's hourly counts) had seen it before
    this week, and Claude has a photo of it. Watching began with the first
    Bird Buddy record, and nothing counts as new in the first week of
    watching, when every bird is a first. A milestone is the feeder's 10th,
    25th, 50th... photographed visit, when it fell this week.
    """
    rows = conn.execute(
        "SELECT v.seen_at, v.source, s.common_name, s.scientific_name, s.is_bird, "
        "  s.confidence "
        "FROM visits v JOIN current_identifications ci ON ci.visit_id = v.id "
        "JOIN sightings s ON s.identification_id = ci.id "
        "WHERE v.source != 'sample' ORDER BY v.seen_at").fetchall()
    first, photographed, names = {}, {}, {}
    for r in rows:
        species = binomial(r["scientific_name"])
        if not r["is_bird"] or not species or species.endswith("sp."):
            continue
        first.setdefault(species, r["seen_at"])
        if r["source"] != "bb-report" and r["confidence"] == "high":
            photographed.setdefault(species, r["seen_at"])
            names.setdefault(species, r["common_name"].split(" (")[0])  # not "(Oregon)"
    week_ago = (now - timedelta(days=7)).isoformat(timespec="seconds")
    watching = min((r["seen_at"] for r in rows if r["source"] in ("birdbuddy", "bb-report")),
                   default=None)
    settled = watching and (datetime.fromisoformat(watching) + SETTLING).isoformat(timespec="seconds")
    order = sorted(photographed, key=photographed.get)
    new = {species: order.index(species) + 1 for species in order
           if settled and first[species] >= max(settled, week_ago)}

    visits = [r[0] for r in conn.execute(
        "SELECT seen_at FROM visits WHERE source = 'birdbuddy' ORDER BY seen_at")]
    milestones = [(n, visits[n - 1]) for n in MILESTONES
                  if n <= len(visits) and visits[n - 1] >= week_ago]
    return {"species": [names[s] for s in order], "since": photographed[order[0]] if order else None,
            "new": new, "names": names, "milestones": milestones}


TRAY = {"plenty": 3, "some": 2, "few": 1, "empty": 0}


def save_tray(conn, visit_id: str, tray: str, by: str) -> None:
    with conn:
        conn.execute("INSERT OR REPLACE INTO trays (visit_id, tray, by, made_at) VALUES (?, ?, ?, ?)",
                     (visit_id, tray, by, now()))


QUIET = timedelta(hours=4)  # of daylight without a bird; the longest on a fed day so far was 3.2


def quiet(conn, local: datetime, sunrise: datetime, sunset: datetime) -> timedelta:
    """How much daylight has passed since the last photographed visit, in
    local time. Days before today borrow today's sunrise and sunset, which
    move only a few minutes a day."""
    last = conn.execute("SELECT MAX(seen_at) FROM visits WHERE source = 'birdbuddy'").fetchone()[0]
    if not last:
        return timedelta()
    since = datetime.fromisoformat(last).astimezone().replace(tzinfo=None)
    total = timedelta()
    for back in range((local.date() - since.date()).days + 1):
        day = timedelta(days=back)
        total += max(min(local, sunset - day) - max(since, sunrise - day), timedelta())
    return total


def seed(conn, local: datetime, sunrise: datetime | None = None,
         sunset: datetime | None = None) -> dict | None:
    """The seed, from what Claude last saw of the tray and the daylight
    since: the one reading the board, the app, the day note and the story
    share. None before Claude has seen a tray.

    "level" is 3 (plenty) to 0 (out); "words" says it for the board;
    "seen" is when the tray was last seen; "filled" is when it was last
    seen going from few or empty to plenty: a refill, seen, not reported.
    A tray last seen with a few seeds (or empty), then hours of daylight
    without a bird, is probably out; one last seen full and then quiet is
    just a quiet spell."""
    looks = conn.execute(
        "SELECT v.seen_at, t.tray FROM trays t JOIN visits v ON v.id = t.visit_id "
        "WHERE t.tray != 'unseen' ORDER BY v.seen_at").fetchall()
    if not looks:
        return None
    seen, tray = datetime.fromisoformat(looks[-1]["seen_at"]), looks[-1]["tray"]
    filled = None
    for before, after in zip(looks, looks[1:]):
        if TRAY[before["tray"]] <= 1 and after["tray"] == "plenty":
            filled = datetime.fromisoformat(after["seen_at"])
    level = TRAY[tray]
    if level <= 1 and sunrise and sunset and quiet(conn, local, sunrise, sunset) >= QUIET:
        return {"level": 0, "words": "probably out", "seen": seen, "filled": filled}
    words = {3: "plenty", 2: "some left", 1: "a few left", 0: "empty"}[level]
    return {"level": level, "words": words, "seen": seen, "filled": filled}


def seen_words(moment: datetime, local: datetime) -> str:
    """"4:12 PM" today, else the weekday: when the tray was last seen."""
    at = moment.astimezone().replace(tzinfo=None)
    return f"{at:%-I:%M %p}" if at.date() == local.date() else f"{at:%A}"
