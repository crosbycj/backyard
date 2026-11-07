# /// script
# requires-python = ">=3.10"
# dependencies = ["anthropic>=2.1"]
# ///
"""Keep the board's story: what the last seven days at the feeder add up to.

The story is a dateline and two or three paragraphs, each naming one bird in
**bold** so the board can put its picture beside it. It isn't rewritten on a
schedule. Every so often Claude rereads the current story against the last
seven days and what's happened since it was written, and decides: keep it
(most of the time), revise it (same story, updated), or write a new one (the
story has changed). It may continue the earlier story or start fresh. Each
change is a new row in `essays`, dated when it was written; each look,
changed or not, is a row in `essay_checks`.

Run:
    uv run collector/essay.py          # reconsider the story now
"""

from __future__ import annotations

import json
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

import config
import claude
import db
import weather

SYSTEM = """You keep the story on an e-ink board about a \
backyard bird feeder in """ + config.PLACE + """: what the last seven days add up \
to, right now. It sits beside a feed of every visit, so don't list visits; tell \
the week. The story is two short paragraphs about the birds with the best story \
(a bird new to the yard above all, then a rare or surprising visitor, a \
regular doing something, a change), then a short third paragraph about everyone else. Complete sentences \
only, plain and warm, no exclamation marks. Each paragraph names its bird once \
in **bold**, using the names as given. About 480 characters in all.

You'll see the current story, when it was written, and the week as it stands, \
with what's new since. Decide:
- "keep" if it still tells the week truthfully. This is the usual answer; \
a story shouldn't churn with every finch.
- "revise" if the story is right but a fact has moved (a count, a newcomer \
stuck around, a hedge can be dropped).
- "new" if the week's story has changed, or the current one has gone stale or \
is about birds no longer in the last seven days. A new story may pick up the \
thread of the old one ("The mockingbird never came back...") or stand alone.
When you keep, return no paragraphs.

The board shows the week's photos beside the story, so lead with what the \
camera saw: the two main paragraphs are about birds marked [photographed], \
which a Claude model identified from the photos. Visits identified by \
"bird-buddy" are Bird Buddy's hourly counts, with no photo and Bird Buddy's own \
label, which the owner doesn't trust: use them only as background (how often, \
which days), never lead with a bird only they report, and hedge a surprising \
one (a species rare in the area). A photographed bird marked medium or low \
confidence is probable, not certain: hedge it the same way, and never call it \
a first or a rarity as fact. Counts are visits, not birds. Only state \
natural-history facts you are sure of.

The weather by day and the seed's outlook are there in case they help tell \
the week (a busy morning before the rain, a refill the birds found fast). \
Leave them out when they don't."""

SCHEMA = {
    "type": "object",
    "properties": {
        "decision": {"type": "string", "enum": ["keep", "revise", "new"]},
        "reason": {"type": "string"},
        "paragraphs": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"text": {"type": "string"},
                               "scientific_name": {"type": "string"}},
                "required": ["text", "scientific_name"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["decision", "reason", "paragraphs"],
    "additionalProperties": False,
}


def week_dossier(conn, now: datetime, since_story: str | None) -> str:
    since = (now - timedelta(days=7)).isoformat(timespec="seconds")
    rows = conn.execute(
        "SELECT v.seen_at, v.source, ci.by, ci.caption, s.common_name, s.scientific_name, "
        "  s.confidence "
        "FROM visits v JOIN current_identifications ci ON ci.visit_id = v.id "
        "LEFT JOIN sightings s ON s.identification_id = ci.id "
        "WHERE v.seen_at >= ? AND v.source != 'sample' ORDER BY v.seen_at", (since,)).fetchall()
    tally = Counter(r["common_name"] for r in rows)
    first = {}
    by_day = defaultdict(list)
    for r in rows:
        when = datetime.fromisoformat(r["seen_at"]).astimezone()
        first.setdefault(r["common_name"], when)
        new = " [new since the story]" if since_story and r["seen_at"] > since_story else ""
        seen = " [photographed]" if r["source"] != "bb-report" else ""
        if r["source"] != "bb-report" and r["confidence"] not in (None, "high"):
            seen += f" [{r['confidence']} confidence: {r['common_name']} is probable, not sure]"
        by_day[f"{when:%A %b %-d}"].append(
            f"{when:%-I:%M %p}: {(r['caption'] or '').replace('**', '')} "
            f"(identified by {r['by']}){seen}{new}")
    names = {r["common_name"]: r["scientific_name"] for r in rows}
    state = conn.execute("SELECT * FROM feeder_state ORDER BY at DESC LIMIT 1").fetchone()
    lines = [f"Now: {now.astimezone():%A, %B %-d, %Y, %-I %p}. The last seven days at the feeder:",
             "Species (scientific name): visits this week, first seen this week"]
    for name, n in tally.most_common():
        lines.append(f"- {name} ({names[name]}): {n}, first {first[name]:%A %-I %p}")
    # The seed as Claude last saw the tray (db.seed).
    local = now.astimezone().replace(tzinfo=None)
    if seed := db.seed(conn, local):
        lines.append(f"The seed tray, as last seen {db.seen_words(seed['seen'], local)}: {seed['words']}.")
        if seed["filled"]:
            lines.append(f"It was refilled {seed['filled'].astimezone():%A %-I %p}.")
    days = weather.week(*((state["latitude"], state["longitude"])
                          if state and state["latitude"] else config.HOME))
    if days:
        lines.append("Weather by day: " + "; ".join(f"{d:%a %b %-d} {w}" for d, w in days) + ".")
    yard = db.yard(conn, now)
    if yard["species"]:
        since = datetime.fromisoformat(yard["since"]).astimezone()
        lines.append(f"The yard list (birds Claude has seen in the feeder's photos): "
                     f"{len(yard['species'])} species since {since:%B %Y}.")
    for species, n in yard["new"].items():
        lines.append(f"NEW TO THE YARD this week, species No. {n}: {yard['names'][species]}. "
                     "Never seen here before; lead with it.")
    for n, at in yard["milestones"]:
        lines.append(f"Milestone: the feeder's {n}th photographed visit came "
                     f"{datetime.fromisoformat(at).astimezone():%A}.")
    lines.append("\nEvery visit, by day:")
    for day, items in by_day.items():
        lines.append(day)
        lines += [f"  {i}" for i in items]
    return "\n".join(lines)


def reconsider(conn) -> str:
    """Look at the story against the week; returns keep, revise or new."""
    now = datetime.now(timezone.utc)
    current = conn.execute(
        "SELECT * FROM essays WHERE by != 'sample' ORDER BY written_at DESC LIMIT 1").fetchone()
    if current:
        written = datetime.fromisoformat(current["written_at"]).astimezone()
        story = "\n\n".join(p["text"] for p in json.loads(current["paragraphs"]))
        header = (f"The current story, written {written:%A %B %-d at %-I %p} "
                  f"({(now - written).days} days ago):\n\n{story}\n\n")
    else:
        header = "There is no story yet; write the first one (decision \"new\").\n\n"
    dossier = week_dossier(conn, now, current["written_at"] if current else None)
    answer, _ = claude.ask_json(claude.client(), purpose="story", system=SYSTEM, schema=SCHEMA, effort="high",
                                content=[{"type": "text", "text": header + dossier}])
    if not answer:
        return "keep"
    decision = answer["decision"] if current else "new"
    with conn:
        if decision != "keep" and answer["paragraphs"]:
            paragraphs = [{"text": p["text"], "species": p["scientific_name"]}
                          for p in answer["paragraphs"]]
            conn.execute(
                "INSERT INTO essays (written_at, by, dateline, paragraphs) VALUES (?, ?, ?, ?)",
                (db.now(), claude.MODEL, f"{now.astimezone():%A, %B %-d}.",
                 json.dumps(paragraphs)))
        else:
            decision = "keep"
        conn.execute("INSERT INTO essay_checks (at, decision, reason) VALUES (?, ?, ?)",
                     (db.now(), decision, answer["reason"]))
    return decision


def due(conn, changed: bool) -> bool:
    """Reconsider after new visits, at most every two hours, and at least
    once a day regardless."""
    last = conn.execute("SELECT MAX(at) FROM essay_checks").fetchone()[0]
    if not last:
        return True
    age = datetime.now(timezone.utc) - datetime.fromisoformat(last)
    return (changed and age >= timedelta(hours=2)) or age >= timedelta(days=1)


if __name__ == "__main__":
    conn = db.connect()
    print(reconsider(conn))
    for r in conn.execute("SELECT * FROM essay_checks ORDER BY at DESC LIMIT 1"):
        print(r["reason"])
    essay = conn.execute("SELECT * FROM essays ORDER BY written_at DESC LIMIT 1").fetchone()
    print(f"\n{essay['dateline']}")
    for p in json.loads(essay["paragraphs"]):
        print(f"\n[{p['species']}] {p['text']}")
