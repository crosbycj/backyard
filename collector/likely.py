# /// script
# requires-python = ">=3.10"
# dependencies = ["anthropic>=2.1"]
# ///
"""The birds likely at the feeder this month that haven't come yet.

Once a month Claude names the birds a backyard feeder with
sunflower seed is most likely to get this month, leaving out the ones on
the yard list, each with how likely and what to watch for. The app shows
them on Birds as empty circles, filled in when they come: the yard list
as a collection. It's knowledge of the season, not of this yard, so it's
asked once a month, not every run.

Run:
    uv run collector/likely.py [--again]   # this month's, if not written yet
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone

import config
import claude
import db

SYSTEM = """You know the birds of """ + config.PLACE + """ well, season by season. \
You help someone with a camera bird feeder in their backyard there, \
stocked with sunflower seed, know which birds to hope for. Only \
name species that really do come to backyard feeders or the ground under \
them in that area in the month asked about. Use current eBird/Clements \
names. Write each note in one plain, warm sentence of at most 110 \
characters: what to look or listen for, or why it's around now. No \
exclamation marks."""

SCHEMA = {
    "type": "object",
    "properties": {
        "birds": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "common_name": {"type": "string"},
                    "scientific_name": {"type": "string"},
                    "chance": {"type": "string", "enum": ["common", "regular", "occasional"]},
                    "note": {"type": "string"},
                },
                "required": ["common_name", "scientific_name", "chance", "note"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["birds"],
    "additionalProperties": False,
}

HOW_MANY = 9


def month_of(now: datetime) -> str:
    return f"{now.astimezone():%Y-%m}"


def write(conn, again: bool = False) -> int:
    """This month's likely birds, if they aren't written yet. Returns how many."""
    now = datetime.now(timezone.utc)
    month = month_of(now)
    if not again and conn.execute("SELECT 1 FROM likely WHERE month = ?", (month,)).fetchone():
        return 0
    seen = db.yard(conn, now)["species"]
    prompt = (f"The month: {now.astimezone():%B}.\n"
              f"Already seen at this feeder: {', '.join(seen) or 'none yet'}.\n\n"
              f"Name the {HOW_MANY} birds most likely to visit this month that aren't "
              "already seen, the most likely first. Say how likely each is at a "
              f"backyard feeder in {config.PLACE} this month (common, regular or occasional), and write its note.")
    answer, response = claude.ask_json(claude.client(), purpose="likely", system=SYSTEM,
                                       content=[{"type": "text", "text": prompt}], schema=SCHEMA,
                                       effort="medium")
    if answer is None:
        return 0
    birds = [b for b in answer["birds"] if b["common_name"] not in seen][:HOW_MANY]
    with conn:
        conn.execute("INSERT OR REPLACE INTO likely (month, birds, by, made_at) VALUES (?, ?, ?, ?)",
                     (month, json.dumps(birds), response.model, db.now()))
    return len(birds)


def current(conn) -> dict | None:
    """This month's list, or the latest one before it's written."""
    row = conn.execute("SELECT * FROM likely ORDER BY month DESC LIMIT 1").fetchone()
    return {"month": row["month"], "birds": json.loads(row["birds"])} if row else None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--again", action="store_true", help="write this month's again")
    args = parser.parse_args()
    conn = db.connect()
    n = write(conn, args.again)
    for b in (current(conn) or {}).get("birds", []):
        print(f"  {b['common_name']} ({b['chance']}): {b['note']}")
    print(f"Wrote {n}." if n else "Already written this month.")


if __name__ == "__main__":
    main()
