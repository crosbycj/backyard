# /// script
# requires-python = ">=3.10"
# dependencies = ["anthropic>=2.1"]
# ///
"""Tonight's note: the day at the feeder, summed up, written once after sunset.

It sits at the top of today's feed overnight, above the day's visits, so it
doesn't repeat them. Claude sees every photographed visit today (caption,
notes, how sure), how the last week's days went, tomorrow's forecast and
the seed, and writes two or three sentences: the day in numbers, how it
compared, one thing worth noticing, and tomorrow if it matters. One row per
day in `day_notes`.

Run:
    uv run collector/daynote.py          # write today's now
"""

from __future__ import annotations

from collections import Counter
from datetime import datetime, timedelta, timezone

import config
import claude
import db
import weather

SYSTEM = """You write tonight's note on an e-ink board about a \
backyard bird feeder in """ + config.PLACE + """. After sunset it sits at \
the top of today's feed, above every visit of the day, so don't retell a \
visit: sum the day up.

In two or three complete sentences, at most 240 characters in all: how many \
visits came today and from which birds; how today compared with the other \
days, only where the numbers show it (busier or quieter, a regular missing, \
a bird earlier or later than usual); one thing worth noticing from today's \
notes, if there is one; and tomorrow, briefly, if it matters at the feeder \
(rain, cold, the seed running out). Name at most one bird in **bold**. Plain \
and warm, no exclamation marks. Only say what the numbers and notes show. A \
bird marked probable stays probable. Counts are visits, not birds."""

SCHEMA = {
    "type": "object",
    "properties": {"note": {"type": "string"}},
    "required": ["note"],
    "additionalProperties": False,
}


def days(conn, now: datetime, n: int = 8) -> dict:
    """The last n local days of photographed visits: {date: [visit rows]}."""
    start = (now.astimezone() - timedelta(days=n - 1)).replace(hour=0, minute=0, second=0,
                                                                microsecond=0)
    out: dict = {}
    for r in conn.execute(
            "SELECT v.id, v.seen_at, ci.caption, ci.notes, s.common_name, s.confidence "
            "FROM visits v JOIN current_identifications ci ON ci.visit_id = v.id "
            "LEFT JOIN sightings s ON s.identification_id = ci.id "
            "WHERE v.source = 'birdbuddy' AND v.seen_at >= ? ORDER BY v.seen_at",
            (start.astimezone(timezone.utc).isoformat(timespec="seconds"),)):
        when = datetime.fromisoformat(r["seen_at"]).astimezone()
        out.setdefault(when.date(), []).append({**dict(r), "when": when})
    return out


def dossier(conn, now: datetime) -> str:
    today = now.astimezone().date()
    by_day = days(conn, now)
    lines = [f"Today is {now.astimezone():%A, %B %-d}."]
    visits = by_day.get(today, [])
    seen = {}
    for v in visits:
        seen.setdefault(v["id"], v)
    lines.append(f"\nToday: {len(seen)} photographed visits.")
    for v in visits:
        sure = "" if v["confidence"] in (None, "high") else f" [{v['confidence']} confidence: probable]"
        lines.append(f"- {v['when']:%-I:%M %p} {v['common_name']}{sure}: "
                     f"{(v['caption'] or '').replace('**', '')} Notes: {v['notes'] or ''}")
    lines.append("\nEach day this past week (photographed visits; species: visits):")
    for day in sorted(by_day):
        rows = by_day[day]
        per = Counter(r["common_name"] for r in rows)
        first, last = rows[0]["when"], rows[-1]["when"]
        lines.append(f"- {day:%a %b %-d}: {len({r['id'] for r in rows})} visits; "
                     + ", ".join(f"{k}: {n}" for k, n in per.most_common())
                     + f"; first {first:%-I:%M %p}, last {last:%-I:%M %p}")
    for d in weather.ahead(*db.place(conn))[1:]:
        rain = (f", rain likely from about {d['rain_from']:%-I %p} ({d['rain_mm']:g} mm)"
                if d["rain_from"] else "")
        lines.append(f"\nTomorrow: {d['words']}, {d['low']}–{d['high']}°{rain}.")
    # The seed as Claude last saw the tray, and the daylight since (db.seed).
    sky = weather.now(*db.place(conn))
    local = now.astimezone().replace(tzinfo=None)
    if seed := db.seed(conn, local, *((sky["sunrise"][0], sky["sunset"][0]) if sky else ())):
        lines.append(f"The seed tray: {seed['words']} (last seen {db.seen_words(seed['seen'], local)}"
                     + (", and no birds for hours of daylight since" if seed["words"] == "probably out" else "")
                     + (f"; refilled {db.seen_words(seed['filled'], local)}" if seed["filled"]
                        and seed["filled"].astimezone().date() == local.date() else "") + ").")
    yard = db.yard(conn, now)
    for species, n in yard["new"].items():
        lines.append(f"New to the yard this week: {yard['names'][species]} (species No. {n}).")
    return "\n".join(lines)


def write(conn, now: datetime | None = None) -> str:
    now = now or datetime.now(timezone.utc)
    answer, _ = claude.ask_json(claude.client(), purpose="day note", system=SYSTEM,
                                schema=SCHEMA, effort="high",
                                content=[{"type": "text", "text": dossier(conn, now)}])
    if not answer:
        return ""
    with conn:
        conn.execute("INSERT OR REPLACE INTO day_notes (day, written_at, by, text) "
                     "VALUES (?, ?, ?, ?)", (now.astimezone().date().isoformat(), db.now(),
                                             claude.MODEL, answer["note"]))
    return answer["note"]


def tonight(conn, now: datetime) -> str | None:
    """Today's note, if it's been written."""
    row = conn.execute("SELECT text FROM day_notes WHERE day = ?",
                       (now.astimezone().date().isoformat(),)).fetchone()
    return row["text"] if row else None


def due(conn, now: datetime | None = None) -> bool:
    """After sunset, once a day."""
    now = now or datetime.now(timezone.utc)
    local = now.astimezone()
    if local.hour < 15 or tonight(conn, now):
        return False
    sky = weather.now(*db.place(conn))
    return bool(sky) and local.replace(tzinfo=None) >= sky["sunset"][0]


if __name__ == "__main__":
    print(write(db.connect()))
