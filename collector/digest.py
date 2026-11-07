# /// script
# requires-python = ">=3.10"
# dependencies = ["anthropic>=2.1"]
# ///
"""Write the feeder's rolling digest: a short story of the last 7 and 30 days.

Claude reads the log for the window (every visit, its birds and notes), how
it compares with the window before, and which species are new to the log,
then writes a headline and two or three sentences for the TRMNL screen.
Each run adds a new digest; the screen shows the latest.

Run:
    uv run collector/digest.py [--days 7 30] [--ends ISO]
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from datetime import datetime, timedelta, timezone

import config
import claude
import db

SYSTEM = """You write the digest for a backyard bird feeder in """ + config.PLACE + """, \
shown on a small black-and-white e-ink screen on the wall of the \
house (800×480). The people who live there glance at it in passing.

From the feeder's log for the window, write a headline of a few words and a \
narrative of two or three short sentences, at most about 300 characters. Say \
what stood out: who's been coming, what changed against the window before \
(arrivals, absences, busier or quieter), anything new to the log or unusual \
in the notes, and the season when it explains something. Concrete beats \
general; a specific bird or moment beats a summary of everything. Plain, \
warm, no exclamation marks, no emoji, no filler. The identifications are \
mostly a model's calls and can be wrong; don't overclaim rare birds. If the \
window is empty or nearly so, say so simply."""

SCHEMA = {
    "type": "object",
    "properties": {
        "headline": {"type": "string"},
        "narrative": {"type": "string"},
    },
    "required": ["headline", "narrative"],
    "additionalProperties": False,
}


def window(conn, start: str, end: str):
    return conn.execute(
        "SELECT * FROM log WHERE seen_at >= ? AND seen_at < ? ORDER BY seen_at",
        (start, end)).fetchall()


def tally(rows) -> Counter:
    return Counter(r["common_name"] for r in
                   {(r["visit_id"], r["common_name"]): r for r in rows}.values()
                   if r["is_bird"])


def digest_prompt(conn, days: int, ends: datetime) -> str:
    end = ends.isoformat(timespec="seconds")
    start = (ends - timedelta(days=days)).isoformat(timespec="seconds")
    before = (ends - timedelta(days=2 * days)).isoformat(timespec="seconds")
    rows, prev = window(conn, start, end), window(conn, before, start)
    earlier = {r["scientific_name"] for r in conn.execute(
        "SELECT scientific_name FROM log WHERE seen_at < ?", (start,))}

    now, last = tally(rows), tally(prev)
    local_end = ends.astimezone()
    lines = [f"The last {days} days, to {local_end:%A %B %-d, %Y %-I:%M %p}.",
             f"Visits: {len({r['visit_id'] for r in rows})} "
             f"(the {days} days before: {len({r['visit_id'] for r in prev})}).",
             "Species this window, visits each (the window before):"]
    for name in sorted(set(now) | set(last), key=lambda n: -now[n]):
        lines.append(f"- {name}: {now[name]} ({last[name]})")
    new = sorted({r["common_name"] for r in rows
                  if r["is_bird"] and r["scientific_name"] not in earlier})
    if new:
        lines.append(f"New to the log: {', '.join(new)}.")
    lines.append("\nEvery visit, oldest first:")
    seen_visits = set()
    for r in rows:
        when = datetime.fromisoformat(r["seen_at"]).astimezone()
        line = f"- {when:%a %b %-d %-I:%M %p}: {r['common_name']} ×{r['count']}"
        if r["details"]:
            line += f" ({r['details']})"
        if r["visit_id"] not in seen_visits and r["notes"]:
            line += f"\n  Note: {r['notes']}"
        seen_visits.add(r["visit_id"])
        lines.append(line)
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--days", type=int, nargs="+", default=[7, 30])
    parser.add_argument("--ends", help="end of the window (ISO 8601); default now")
    args = parser.parse_args()
    ends = (datetime.fromisoformat(args.ends) if args.ends
            else datetime.now()).astimezone(timezone.utc)

    conn = db.connect()
    api = claude.client()
    for days in args.days:
        prompt = digest_prompt(conn, days, ends)
        answer, response = claude.ask_json(
            api, purpose="digest", system=SYSTEM, content=[{"type": "text", "text": prompt}],
            schema=SCHEMA, effort="medium")
        if answer is None:
            print(f"{days} days: declined ({response.stop_details})")
            continue
        with conn:
            conn.execute(
                "INSERT INTO digests (days, ends_at, made_at, by, headline, "
                "narrative, raw) VALUES (?, ?, ?, ?, ?, ?, ?)",
                (days, ends.isoformat(timespec="seconds"), db.now(),
                 response.model, answer["headline"], answer["narrative"],
                 json.dumps({"prompt": prompt, "answer": answer})))
        print(f"{days} days: {answer['headline']}\n  {answer['narrative']}\n")


if __name__ == "__main__":
    main()
