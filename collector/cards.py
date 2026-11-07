# /// script
# requires-python = ">=3.10"
# dependencies = ["anthropic>=2.1"]
# ///
"""Write the note cards the board deals from.

Species cards are written once, the first time a species visits: two "Did you
know" facts and a "Listen for" card whose QR code plays its recording. Claude
writes them from Bird Buddy's profile of the species and what it knows,
in our voice, not Bird Buddy's. Season cards for your area are kept here,
each with the months it's true in.

Run:
    uv run collector/cards.py   # write cards for any new species
"""

from __future__ import annotations

import config
import claude
import db

SEASON = [  # (label, text, month_from, month_to, link)
    ("Listen for", "Barred Owls call more on autumn nights, so listen after dark for "
     "“who cooks for you, who cooks for you-all.”", 9, 11,
     "https://www.allaboutbirds.org/guide/Barred_Owl/sounds"),
    ("Look for", "Juncos flash white outer tail feathers when they fly up from the "
     "ground, which makes them easy to spot.", 10, 3, None),
    ("A note", "In winter, clean the feeder every couple of weeks, because Pine Siskins "
     "are prone to salmonella.", 11, 3, None),
]
SEASON_BY = "claude (session, 2026-10-22)"

SYSTEM = """You write small note cards for an e-ink board about a backyard \
bird feeder in """ + config.PLACE + """. Each card is one or two complete \
sentences, at most 150 characters, plain and warm, with no exclamation marks. \
Only state facts you are sure of. Never copy the profile's wording; it is \
Bird Buddy's, and it's only there to remind you what's notable. If a species \
is unusual there, it's fine to say so carefully."""

SCHEMA = {
    "type": "object",
    "properties": {
        "facts": {"type": "array", "items": {"type": "string"}},
        "listen": {"type": "string"},
    },
    "required": ["facts", "listen"],
    "additionalProperties": False,
}


def write_season(conn) -> int:
    if conn.execute("SELECT 1 FROM cards WHERE deck = 'season'").fetchone():
        return 0
    with conn:
        conn.executemany(
            "INSERT INTO cards (deck, label, text, month_from, month_to, link, made_by, made_at) "
            "VALUES ('season', ?, ?, ?, ?, ?, ?, ?)",
            [(*card, SEASON_BY, db.now()) for card in SEASON])
    return len(SEASON)


def write_missing(conn) -> int:
    """Cards for every species we know of that has none yet."""
    made = write_season(conn)
    todo = conn.execute(
        "SELECT * FROM species_info si WHERE NOT EXISTS (SELECT 1 FROM cards c "
        "WHERE c.deck = 'species' AND c.species = si.scientific_name AND c.made_by != 'sample')"
    ).fetchall()
    if not todo:
        return made
    api = claude.client()
    for sp in todo:
        prompt = (f"Species: {sp['common_name']} ({sp['scientific_name']}).\n"
                  f"Bird Buddy's profile, for reference only:\n{sp['description'] or '(none)'}\n\n"
                  "Write two different 'Did you know' facts about this species, and one "
                  "'Listen for' card that tells someone what its song or call sounds like, "
                  "in words, so they'd recognize it in the yard.")
        answer, _ = claude.ask_json(api, purpose="cards", system=SYSTEM, schema=SCHEMA, effort="medium",
                                    content=[{"type": "text", "text": prompt}])
        if not answer:
            continue
        rows = [("Did you know", fact, None) for fact in answer["facts"][:2]]
        rows.append(("Listen for", answer["listen"], sp["song_url"]))
        with conn:
            conn.executemany(
                "INSERT INTO cards (deck, label, text, species, link, made_by, made_at) "
                "VALUES ('species', ?, ?, ?, ?, ?, ?)",
                [(label, text, sp["scientific_name"], link, claude.MODEL, db.now())
                 for label, text, link in rows])
        made += len(rows)
        print(f"  {sp['common_name']}: {len(rows)} cards")
    return made


if __name__ == "__main__":
    print(f"{write_missing(db.connect())} cards written")
