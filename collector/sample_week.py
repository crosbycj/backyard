# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Fill the archive with a made-up week, stored exactly like real visits.

Every visit is shaped like a Bird Buddy postcard (feed item, medias with ids,
sizes and URLs, Bird Buddy's guess), its photos are files in the archive, and
it has an identification with a caption, as if Claude had seen it. There is
also a reading of the feeder, a weekly essay and a deck of cards. The photos
are placeholders: put four photos of your own in wall/preview-photos/
(jay-1, jay-2, chickadee, squirrel).

Everything here is source "sample", so it never mixes with real visits and
--clear takes it all out again.

Run:
    uv run collector/sample_week.py          # replace the sample week
    uv run collector/sample_week.py --clear  # remove it
"""

from __future__ import annotations

import argparse
import json
import shutil
from datetime import datetime, timedelta, timezone
from pathlib import Path

import config
import db

BY = "sample"
FEEDER = config.FEEDER
HOME = config.HOME
PHOTOS = Path(__file__).resolve().parent.parent / "wall" / "preview-photos"
SHARED = "https://photos.bird-log.invalid/{}.jpg"
PLACEHOLDERS = {  # local file in wall/preview-photos -> its stand-in public name
    "jay-1": "jay-1",
    "jay-2": "jay-2",
    "chickadee": "chickadee",
    "squirrel": "squirrel",
}
SPECIES = {  # how the captions name them -> (common, scientific, is_bird, photo)
    "Steller's Jay": ("Steller's Jay", "Cyanocitta stelleri", 1, "jay-2"),
    "squirrel": ("Eastern Gray Squirrel", "Sciurus carolinensis", 0, "squirrel"),
    "Black-capped Chickadee": ("Black-capped Chickadee", "Poecile atricapillus", 1, "chickadee"),
    "House Finch": ("House Finch", "Haemorhous mexicanus", 1, "jay-2"),
    "Dark-eyed Junco": ("Dark-eyed Junco", "Junco hyemalis", 1, "jay-2"),
    "Mourning Dove": ("Mourning Dove", "Zenaida macroura", 1, "jay-2"),
}
COUNTS = {"a": 1, "an": 1, "the": 1, "two": 2, "three": 3, "four": 4, "five": 5,
          "pair": 2}

# (days ago, clock time, caption). Times before 7 are afternoon.
WEEK = [
    (0, "11:52", "The **Steller's Jay** came for the fifth morning this week."),
    (0, "11:20", "A gray **squirrel** hung upside down from the feeder and ate for ten minutes."),
    (0, "10:05", "Two **Black-capped Chickadees** took turns at the tray."),
    (0, "9:31", "Two **House Finches** fed together for six minutes."),
    (0, "8:40", "Two **Dark-eyed Juncos** picked seed off the tray for the first time in months."),
    (0, "8:12", "A male **House Finch** was the first bird of the day."),
    (1, "4:51", "A female **Mourning Dove** fed on the ground, then on the tray."),
    (1, "2:30", "Two **Black-capped Chickadees** came in after the rain stopped."),
    (1, "10:44", "The **Steller's Jay** filled its beak and flew off."),
    (1, "9:02", "Five **House Finches** crowded the tray at once."),
    (1, "8:30", "A pair of **House Finches** came first, before the rain."),
    (2, "5:12", "Two **House Finches** came in the last light."),
    (2, "3:40", "A **Black-capped Chickadee** hid a seed in the bark of a tree."),
    (2, "9:40", "The **Steller's Jay** chased a finch off the tray."),
    (2, "8:55", "Four **House Finches** came and went for two hours."),
    (3, "4:20", "A gray **squirrel** emptied a third of the seed."),
    (3, "10:12", "The **Steller's Jay** came for the first time this week."),
    (3, "9:15", "Three **House Finches** waited nearby for the squirrel to leave."),
    (3, "8:02", "A **Black-capped Chickadee** came at first light, alone."),
    (4, "3:30", "A female **House Finch** fed for twelve minutes, the longest visit of the week."),
    (4, "11:10", "Two **Mourning Doves** sat under the feeder and picked up what fell."),
    (4, "8:45", "The **Steller's Jay** called twice from a tree before it came down."),
]

ESSAY = [
    ("A **Steller's Jay** came five mornings out of seven, always before eleven. "
     ""
     "It takes seed by the beakful to hide, carrying several at once in its throat.",
     "Cyanocitta stelleri", "jay-1"),
    ("The **Black-capped Chickadees** have come six mornings in a row, usually in "
     "pairs. Each one takes a single seed, flies to a branch, and hammers it open, "
     "or tucks it into bark to find later.", "Poecile atricapillus", "chickadee"),
    ("The **House Finches** still run the place, with more than half of all visits. "
     "The juncos came back on Thursday for the first time in months.", None, None),
]

CARDS = [  # (deck, label, text, species, month_from, month_to)
    ("species", "Did you know", "A male House Finch gets his red from what he eats, "
     "and females choose the reddest males.", "Haemorhous mexicanus", None, None),
    ("species", "Did you know", "Black-capped Chickadees grow new brain cells each "
     "fall, which helps them remember where they hid their seeds.",
     "Poecile atricapillus", None, None),
    ("species", "Did you know", "Steller's Jays can imitate the scream of a "
     "Red-tailed Hawk, sometimes to clear other birds off a feeder.",
     "Cyanocitta stelleri", None, None),
    ("species", "Did you know", "A Mourning Dove's wings whistle when it takes off "
     "in a hurry, which warns other doves nearby.", "Zenaida macroura", None, None),
    ("season", "Listen for", "Barred Owls call more on autumn nights, so listen "
     "after dark for “who cooks for you.”", None, 9, 11),
    ("season", "Look for", "Juncos flash white outer tail feathers when they fly "
     "up from the ground, which makes them easy to spot.", None, 10, 3),
    ("season", "Look for", "Juncos often turn up at feeders "
     "with the first cold nights.", None, 10, 11),
    ("practical", "A note", "In winter, clean the feeder every couple of weeks, "
     "because Pine Siskins are prone to salmonella.", None, 11, 3),
]


def at(days_ago: int, clock: str, today) -> datetime:
    hour, minute = map(int, clock.split(":"))
    if hour < 7:
        hour += 12
    local = datetime.combine(today - timedelta(days=days_ago), datetime.min.time())
    return local.replace(hour=hour, minute=minute).astimezone()


def species_of(caption: str) -> tuple[str, int]:
    """The caption's bird, singular, and how many."""
    lead, bird, _ = caption.split("**")
    name = next(k for k in SPECIES if bird.startswith(k.rstrip("h").rstrip("e")) or k in bird)
    words = lead.lower().split()
    count = next((COUNTS[w] for w in words if w in COUNTS), 1)
    return name, count


def clear(conn) -> None:
    ids = [r[0] for r in conn.execute("SELECT id FROM visits WHERE source = 'sample'")]
    marks = ",".join("?" * len(ids))
    if ids:
        idents = [r[0] for r in conn.execute(
            f"SELECT id FROM identifications WHERE visit_id IN ({marks})", ids)]
        if idents:
            conn.execute(f"DELETE FROM sightings WHERE identification_id IN "
                         f"({','.join('?' * len(idents))})", idents)
        conn.execute(f"DELETE FROM identifications WHERE visit_id IN ({marks})", ids)
        conn.execute(f"DELETE FROM media WHERE visit_id IN ({marks})", ids)
        conn.execute(f"DELETE FROM visits WHERE id IN ({marks})", ids)
    for table, col in (("essays", "by"), ("cards", "made_by"), ("feeder_state", "feeder")):
        conn.execute(f"DELETE FROM {table} WHERE {col} = ?",
                     (FEEDER + " (sample)" if table == "feeder_state" else BY,))
    shutil.rmtree(db.ARCHIVE / "sample", ignore_errors=True)


def fill(conn) -> None:
    today = datetime.now().date()
    now = db.now()
    essay_media: dict[str, str] = {}
    for i, (days_ago, clock, caption) in enumerate(WEEK):
        seen = at(days_ago, clock, today)
        name, count = species_of(caption)
        common, sci, is_bird, photo = SPECIES[name]
        visit_id, media_id = f"sample:{i:02d}", f"sample-media:{i:02d}"
        folder = db.ARCHIVE / "sample" / f"{seen:%Y-%m-%d_%H%M%S}"
        folder.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(PHOTOS / f"{photo}.jpg", folder / "00_photo.jpg")
        url = SHARED.format(PLACEHOLDERS[photo])
        stamp = seen.astimezone(timezone.utc).isoformat(timespec="seconds")
        raw = {  # the shape of a FeedItemNewPostcard after "identify"
            "__typename": "FeedItemNewPostcard", "id": visit_id, "createdAt": stamp,
            "feeder": {"__typename": "FeederForMember", "name": FEEDER},
            "mediaImageCount": 1, "hasVideoMedia": False,
            "inferenceConfidenceLevel": "HIGH_CONFIDENCE",
            "medias": [{"__typename": "MediaImage", "id": media_id, "createdAt": stamp,
                        "thumbnailUrl": url, "contentUrl": url,
                        "width": 1200, "height": 630}],
            "sightingReportPreview": {"sightings": [{
                "__typename": "SightingRecognizedBird", "count": count,
                "species": {"name": common, "scientificName": sci}}]},
        }
        conn.execute(
            "INSERT INTO visits (id, source, feeder, seen_at, bb_species, bb_confidence, raw) "
            "VALUES (?, 'sample', ?, ?, ?, 'HIGH_CONFIDENCE', ?)",
            (visit_id, FEEDER, stamp, json.dumps([common]), json.dumps(raw)))
        conn.execute(
            "INSERT INTO media (id, visit_id, kind, taken_at, path, width, height, public_url) "
            "VALUES (?, ?, 'photo', ?, ?, 1200, 630, ?)",
            (media_id, visit_id, stamp, str((folder / "00_photo.jpg").relative_to(db.ARCHIVE)), url))
        cur = conn.execute(
            "INSERT INTO identifications (visit_id, by, prompt_version, made_at, caption, notes) "
            "VALUES (?, ?, 'sample', ?, ?, ?)",
            (visit_id, BY, now, caption, caption.replace("**", "")))
        conn.execute(
            "INSERT INTO sightings (identification_id, common_name, scientific_name, "
            "is_bird, count, confidence, details) VALUES (?, ?, ?, ?, ?, 'high', '')",
            (cur.lastrowid, common, sci, is_bird, count))
        for _, essay_sci, essay_photo in ESSAY:
            if essay_sci == sci and essay_photo == photo and sci not in essay_media:
                essay_media[sci] = media_id

    # The essay's own photos: the week's best shot of each of its birds.
    for text, sci, photo in ESSAY:
        if sci and sci not in essay_media:
            match = conn.execute(
                "SELECT m.id FROM media m JOIN visits v ON v.id = m.visit_id "
                "JOIN current_identifications ci ON ci.visit_id = v.id "
                "JOIN sightings s ON s.identification_id = ci.id "
                "WHERE v.source = 'sample' AND s.scientific_name = ? ORDER BY v.seen_at",
                (sci,)).fetchone()
            essay_media[sci] = match[0]
            conn.execute("UPDATE media SET public_url = ? WHERE id = ?",
                         (SHARED.format(PLACEHOLDERS[photo]), match[0]))
    sunday = today - timedelta(days=(today.weekday() + 1) % 7)
    conn.execute(
        "INSERT INTO essays (written_at, by, dateline, paragraphs) VALUES (?, ?, ?, ?)",
        (now, BY, f"{sunday:%A, %B %-d}.",
         json.dumps([{"text": t, "media_id": essay_media.get(s)} for t, s, _ in ESSAY])))

    conn.executemany(
        "INSERT INTO cards (deck, label, text, species, month_from, month_to, made_by, made_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [(*card, BY, now) for card in CARDS])
    conn.execute(
        "INSERT INTO feeder_state (at, feeder, state, food, battery, charging, signal, "
        "temperature, latitude, longitude) VALUES (?, ?, 'ONLINE', 'MEDIUM', 64, 0, -61, 11.5, ?, ?)",
        (now, FEEDER + " (sample)", *HOME))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--clear", action="store_true", help="remove the sample week")
    args = parser.parse_args()
    conn = db.connect()
    with conn:
        clear(conn)
        if not args.clear:
            fill(conn)
    n = conn.execute("SELECT COUNT(*) FROM visits WHERE source = 'sample'").fetchone()[0]
    print(f"{n} sample visits in the archive.")


if __name__ == "__main__":
    main()
