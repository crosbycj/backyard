# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow>=10", "boto3>=1.34"]
# ///
"""Send the screen its data: the last seven days, as TRMNL's webhook takes it.

Builds the payload the wall draws (the masthead's readings, the feed of
visits, the photo plates, the dated essay and the notes) and posts it to the
local preview (trmnlp at localhost:4567), the real TRMNL, or both. The device
needs its webhook URL in the Keychain (service "trmnl-webhook").
wall/sample-week.json shows the full shape.

Run:
    uv run collector/publish.py           # from the archive
    uv run collector/publish.py --sample  # the made-up week
    uv run collector/publish.py --print   # show, don't send
    uv run collector/publish.py --to device  # the real TRMNL
"""

from __future__ import annotations

import argparse
import html
import json
import subprocess
import urllib.request
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

import config
import db
import photos
import weather

FACE = Path(__file__).resolve().parent.parent / "wall"
LOCAL_WEBHOOK = "http://localhost:4567/webhook"
LIMIT_BYTES = 5 * 1024  # TRMNL's limit without TRMNL+
DAYS = 7
PLATES = 3  # the big photo and two medium ones under it
NUMBERS = ["", "A", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"]


def day_label(dt: datetime, today) -> str:
    if dt.date() == today:
        return "Today"
    if dt.date() == today - timedelta(days=1):
        return "Yesterday"
    return f"{dt:%A}"




def plural(name: str) -> str:
    return name + ("es" if name.endswith(("ch", "sh", "s", "x")) else "s")


def bold(text: str) -> dict:
    """Split "A **Steller's Jay** came." into the parts the screen bolds."""
    parts = text.split("**")
    if len(parts) < 3:
        return {"lead": text, "bird": "", "rest": ""}
    return {"lead": parts[0], "bird": parts[1], "rest": "".join(parts[2:])}


def fallback(name: str, count: int) -> str:
    """A plain sentence for a visit with no caption yet."""
    count = max(count or 1, 1)
    lead = NUMBERS[count] if count < len(NUMBERS) else str(count)
    return f"{lead} **{name if count == 1 else plural(name)}** came to the feeder."


def instruments(conn, now: datetime) -> dict:
    """The masthead's readings: weather, seed, the sun (sunset by day,
    sunrise by night), and anything wrong."""
    state = conn.execute(
        "SELECT * FROM feeder_state ORDER BY at DESC LIMIT 1").fetchone()
    lat, lon = ((state["latitude"], state["longitude"])
                if state and state["latitude"] else config.HOME)
    sky = weather.now(lat, lon)
    readings = {"weather": sky["words"]} if sky else {}
    local = now.astimezone().replace(tzinfo=None)
    if sky:
        if sky["sunrise"][0] <= local < sky["sunset"][0]:
            readings["sunset"] = f"{sky['sunset'][0]:%-I:%M}"
        else:
            rise = next((t for t in sky["sunrise"] if t > local), sky["sunrise"][-1])
            readings["sunrise"] = f"{rise:%-I:%M}"
    readings["as_of"] = f"{now.astimezone():%a, %b %-d · %-I:%M %p}"
    # The seed as Claude last saw the tray (db.seed), not Bird Buddy's sensor.
    if seed := db.seed(conn, local, *((sky["sunrise"][0], sky["sunset"][0]) if sky else ())):
        readings |= {"seed": seed["level"], "seed_of": 3, "seed_until": seed["words"],
                     "seed_seen": db.seen_words(seed["seen"], local)}
    if state:
        if state["state"] == "OFFLINE":
            readings["alert"] = "The feeder is offline."
        elif state["battery"] is not None and state["battery"] < 20:
            readings["alert"] = f"The feeder's battery is at {state['battery']} percent."
    return readings




def slug(name: str) -> str:
    return "".join(ch if ch.isalnum() else "-" for ch in name.lower()).strip("-")


def short_link(conn, species: str | None, link: str | None) -> str | None:
    """A short address for a species' recording beside the week page, so
    its QR code stays coarse enough to scan from a small square."""
    if not (species and link):
        return link
    row = conn.execute("SELECT common_name FROM species_info WHERE scientific_name = ? "
                       "AND song_url = ?", (species, link)).fetchone()
    return f"{photos.site_base()}s/{slug(row['common_name'])}.html" if row else link


def week_url() -> str:
    """Where phones find the week in color: its page in the R2 bucket."""
    return f"{photos.site_base()}index.html"


def visits(conn, now: datetime) -> list[dict]:
    """Every visit of the last seven days, newest first: its caption, its
    species, how many visits it stands for, and its picture (a real photo,
    or the species' illustration until we have one). An hour of Bird Buddy's
    report is dropped when a postcard covers the same bird in that hour."""
    since = (now - timedelta(days=DAYS)).isoformat(timespec="seconds")
    rows = conn.execute(
        "SELECT v.id, v.source, v.seen_at, v.raw, ci.caption, s.common_name, "
        "  json_extract(ci.raw, '$.photo_score') AS score, "
        "  s.scientific_name, s.count, si.icon_url, si.song_url, "
        # Claude's pick of the visit's photos first, else the first one.
        # (SQLite won't let a subquery's ORDER BY see the view's columns.)
        "  COALESCE((SELECT m.public_url FROM media m WHERE m.id = ci.best_media), "
        "    (SELECT m.public_url FROM media m WHERE m.visit_id = v.id "
        "     AND m.kind = 'photo' AND m.public_url IS NOT NULL ORDER BY m.id LIMIT 1)) AS photo, "
        "  COALESCE((SELECT m.path FROM media m WHERE m.id = ci.best_media), "
        "    (SELECT m.path FROM media m WHERE m.visit_id = v.id "
        "     AND m.kind = 'photo' ORDER BY m.id LIMIT 1)) AS path "
        "FROM visits v JOIN current_identifications ci ON ci.visit_id = v.id "
        "LEFT JOIN sightings s ON s.identification_id = ci.id "
        "LEFT JOIN species_info si ON si.scientific_name = s.scientific_name "
        "WHERE v.seen_at >= ? GROUP BY v.id ORDER BY v.seen_at DESC", (since,)).fetchall()
    # Every species a real visit saw, by hour: Bird Buddy's hourly row for
    # the same bird in the same hour is that visit, so it's left out.
    covered = set()
    for c in conn.execute(
            "SELECT v.seen_at, s.scientific_name FROM visits v "
            "JOIN current_identifications ci ON ci.visit_id = v.id "
            "JOIN sightings s ON s.identification_id = ci.id "
            "WHERE v.source != 'bb-report' AND v.seen_at >= ?", (since,)):
        when = datetime.fromisoformat(c["seen_at"]).astimezone()
        covered.add((when.date(), when.hour, db.binomial(c["scientific_name"])))
    out = []
    for r in rows:
        when = datetime.fromisoformat(r["seen_at"]).astimezone()
        if r["source"] == "bb-report" and (
                when.date(), when.hour, db.binomial(r["scientific_name"])) in covered:
            continue
        raw = json.loads(r["raw"]) if r["raw"] else {}
        out.append({
            "id": r["id"], "when": when, "source": r["source"],
            "name": r["common_name"], "species": r["scientific_name"],
            "visits": raw.get("visits", 1) if r["source"] == "bb-report" else 1,
            "caption": r["caption"] or fallback(r["common_name"] or "visitor", r["count"]),
            "photo": r["photo"], "path": r["path"], "icon": r["icon_url"], "score": r["score"],
            "song": r["song_url"]})
    return out


def listen_label(conn, note: dict) -> str:
    """"Listen for the jay": a call card names its bird, since the card's
    text often doesn't. The short name keeps the label on one line."""
    if note["label"] != "Listen for" or not note.get("species"):
        return note["label"]
    row = conn.execute("SELECT common_name FROM species_info WHERE scientific_name = ?",
                       (note["species"],)).fetchone()
    return f"Listen for the {row['common_name'].split()[-1].lower()}" if row else note["label"]


def article(name: str) -> str:
    return "an" if name[:1].upper() in "AEIOU" else "a"


def quiet_line(conn, week: list[dict], now: datetime, readings: dict) -> str | None:
    """A sentence for the top of today's feed when the feeder is quiet. None
    while birds come. Overnight: tonight's note from Claude (daynote.py),
    or the day in numbers until it's written. Before sunrise, or by day
    before the first bird: the day ahead."""
    local = now.astimezone()
    today = [v for v in week if v["when"].date() == local.date()]
    if "sunrise" not in readings:  # day
        return None if today else day_ahead(conn, week, now)
    if local.hour < 12:  # after midnight, before sunrise
        return day_ahead(conn, week, now, readings["sunrise"])
    row = conn.execute("SELECT text FROM day_notes WHERE day = ?",
                       (local.date().isoformat(),)).fetchone()
    return row["text"] if row else day_numbers(week, now)


def day_numbers(week: list[dict], now: datetime) -> str:
    """Today's photographed visits, counted."""
    today = [v for v in week if v["when"].date() == now.astimezone().date()
             and v["source"] != "bb-report" and v["name"]]
    if not today:
        return "No birds came to the feeder today."
    per = Counter(v["name"] for v in today)
    top, n = per.most_common(1)[0]
    if len(today) == 1:
        return f"Today brought a single visit, {article(top)} **{top}**."
    if len(per) == 1:
        return f"Today brought {len(today)} visits, all **{plural(top)}**."
    return (f"Today brought {len(today)} visits from {len(per)} kinds of bird, "
            f"and **{plural(top)}** made {n} of them.")


def usual_first(week: list[dict], now: datetime) -> tuple[str, str] | None:
    """The bird that usually comes first in the morning, and about when,
    from earlier days' first photographed visits. None with under three days."""
    firsts: dict = {}
    for v in sorted(week, key=lambda v: v["when"]):
        day = v["when"].date()
        if day < now.astimezone().date() and v["source"] != "bb-report" and v["name"]:
            firsts.setdefault(day, v)
    if len(firsts) < 3:
        return None
    name, n = Counter(v["name"] for v in firsts.values()).most_common(1)[0]
    if n < 2:
        return None
    minutes = [v["when"].hour * 60 + v["when"].minute for v in firsts.values() if v["name"] == name]
    at = round(sum(minutes) / len(minutes) / 5) * 5
    return name, f"{at // 60 % 12 or 12}:{at % 60:02d}"


def day_ahead(conn, week: list[dict], now: datetime, sunrise: str | None = None) -> str:
    """Before the first bird: sunrise, rain on the way, and who usually comes first."""
    parts = [f"The feeder is asleep until sunrise at {sunrise}." if sunrise
             else "No birds yet today."]
    forecast = weather.ahead(*db.place(conn))
    local = now.astimezone().replace(tzinfo=None)
    if forecast and forecast[0]["rain_from"] and forecast[0]["rain_from"] >= local:
        parts.append(f"Rain is likely from about {forecast[0]['rain_from']:%-I %p}.")
    if usual := usual_first(week, now):
        parts.append(f"**{plural(usual[0])}** usually come first, around {usual[1]}.")
    return " ".join(parts)


def numbers_card(week: list[dict], yard_size: int = 0) -> dict | None:
    """A live "By the numbers" card from this week's visits."""
    counts: dict[str, int] = {}
    for v in week:
        if v["name"]:
            counts[v["name"]] = counts.get(v["name"], 0) + v["visits"]
    if not counts:
        return None
    total = sum(counts.values())
    top, n = max(counts.items(), key=lambda kv: kv[1])
    hours: dict[int, int] = {}
    for v in week:
        hours[v["when"].hour] = hours.get(v["when"].hour, 0) + v["visits"]
    busiest = max(hours, key=hours.get)
    at = datetime(2000, 1, 1, busiest)
    return {"label": "By the numbers",
            "text": f"{plural(top)} made {n} of this week's {total} visits, "
                    f"and {at:%-I %p} was the busiest hour."
                    + (f" The yard list stands at {yard_size} species." if yard_size else "")}


def deal(conn, now: datetime, seen_species: set[str], week: list[dict],
         yard_size: int = 0) -> list[dict]:
    """Two notes. The first is a card with a link (a call to listen to); the
    second rotates through the rest and the live numbers. Cards about birds
    seen this week and cards for this time of year only, least recently
    shown first."""
    month = now.astimezone().month
    cards = conn.execute("SELECT * FROM cards WHERE retired = 0").fetchall()

    def in_season(c) -> bool:
        lo, hi = c["month_from"], c["month_to"]
        if lo is None:
            return True
        return lo <= month <= hi if lo <= hi else month >= lo or month <= hi

    usable = [c for c in cards if in_season(c)
              and (c["species"] is None or c["species"] in seen_species)]
    usable.sort(key=lambda c: (c["last_shown_at"] or "", c["id"]))
    linked = next((c for c in usable if c["link"]), None)
    rest = [c for c in usable if c is not linked and c["label"] != "Listen for"]
    picked = [c for c in (linked, rest[0] if rest else None) if c]
    notes = [{"label": c["label"], "text": c["text"], "link": c["link"],
              "species": c["species"]} for c in picked]
    live = numbers_card(week, yard_size)
    if live and now.astimezone().hour % 2 == 0:  # every other hour, the numbers
        notes = notes[:1] + [live]
        picked = picked[:1]
    with conn:
        conn.executemany(
            "UPDATE cards SET shown_count = shown_count + 1, last_shown_at = ? WHERE id = ?",
            [(now.isoformat(timespec="seconds"), c["id"]) for c in picked])
    return notes


def from_archive() -> dict:
    """The board, from the archive: the readings, the week's visits, the
    plates, the latest essay, two dealt notes, and the week page's address."""
    conn = db.connect()
    now = datetime.now(timezone.utc)
    week = visits(conn, now)
    icons = {r["scientific_name"]: r["icon_url"] for r in conn.execute(
        "SELECT scientific_name, icon_url FROM species_info")}

    # The plates are the week's own photos, by Claude's print score: plate
    # 1, the big one (below), then the best photo of each other bird, then
    # the next best of any. A bird no photo shows (one only Bird Buddy's
    # hourly counts report) gets no plate. With no photos yet, the story's
    # birds are drawn instead. Each plate is labeled with its bird and when
    # ("House Finch · 10:22", with the day if not today).
    essay = conn.execute("SELECT * FROM essays ORDER BY written_at DESC LIMIT 1").fetchone()
    paragraphs = json.loads(essay["paragraphs"]) if essay else []
    today = now.astimezone().date()
    score = lambda v: 2 if v["score"] is None else v["score"]  # not yet rated: middling
    photos = sorted((v for v in week if v["photo"] and score(v) > 1),
                    key=lambda v: (score(v), v["when"]), reverse=True)
    # The big photo: a bird new to the yard first; else the best good photo
    # (3 or more) of the last day, so it changes as the days go; else the
    # week's best.
    firsts = db.yard(conn, now)
    newcomer = next((v for v in photos if db.binomial(v["species"]) in firsts["new"]), None)
    recent = next((v for v in photos if v["when"] >= now - timedelta(days=1) and score(v) >= 3),
                  None)
    hero = newcomer or recent or (photos[0] if photos else None)
    picked, birds = ([hero], {db.binomial(hero["species"])}) if hero else ([], set())
    for v in photos:
        if db.binomial(v["species"]) not in birds:
            birds.add(db.binomial(v["species"]))
            picked.append(v)
    picked += [v for v in photos if v not in picked]
    plates, plate_of_species, plate_of_visit = [], {}, {}
    for v in picked[:PLATES]:
        name = (v["name"] or "").split(" (")[0]
        label = (f"{name} · " if name else "") + f"{v['when']:%-I:%M}" + (
            "" if v["when"].date() == today else f" {v['when']:%a}")
        plates.append({"n": len(plates) + 1, "photo": v["photo"], "t": label})
        if v is newcomer:
            plates[-1]["new"] = f"New to the yard · No. {firsts['new'][db.binomial(v['species'])]}"
        plate_of_visit[v["id"]] = len(plates)
        plate_of_species.setdefault(db.binomial(v["species"]), len(plates))
    if not plates:
        for para in paragraphs[:2]:
            if icons.get(para.get("species")):
                plates.append({"n": len(plates) + 1, "photo": icons[para["species"]],
                               "kind": "illustration"})
                plate_of_species.setdefault(db.binomial(para["species"]), len(plates))

    feed: list[dict] = []
    for v in week:
        label = day_label(v["when"], today)
        if not feed or feed[-1]["day"] != label:
            feed.append({"day": label, "rows": []})
        row = {"t": f"{v['when']:%-I:%M}", **bold(v["caption"])}
        if v["id"] in plate_of_visit:
            row["plate"] = plate_of_visit[v["id"]]
        feed[-1]["rows"].append(row)
    readings = instruments(conn, now)
    if line := quiet_line(conn, week, now, readings):
        if not feed or feed[0]["day"] != "Today":
            feed.insert(0, {"day": "Today", "rows": []})
        feed[0]["rows"].insert(0, {"t": "", "quiet": 1, **bold(line)})

    # Cards only for birds Claude has seen in this week's photos, not ones
    # only Bird Buddy's hourly counts name.
    seen = {v["species"] for v in week if v["species"] and v["source"] != "bb-report"}
    return {
        "title": "Backyard Birds",
        "place": f"{config.FEEDER}, {config.PLACE}",
        "now": readings,
        "feed": feed,
        "plates": plates,
        "week_url": week_url(),
        "essay": {
            "dateline": essay["dateline"] if essay else None,
            "paragraphs": [{**bold(p["text"]),
                            "plate": plate_of_species.get(db.binomial(p.get("species")))}
                           for p in paragraphs],
        },
        "notes": [{"label": listen_label(conn, n), "text": n["text"],
                   "link": short_link(conn, n.get("species"), n.get("link"))}
                  for n in deal(conn, now, seen, week, len(firsts["species"]))],
    }


SITE_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Backyard Birds: this week</title>
<style>
  :root {{ --ink: #1d1d1b; --soft: #6b6a64; --paper: #f6f4ee; --rule: #d9d6cc; }}
  body {{ margin: 0; background: var(--paper); color: var(--ink);
         font: 17px/1.5 -apple-system, BlinkMacSystemFont, "Inter", sans-serif; }}
  main {{ max-width: 640px; margin: 0 auto; padding: 24px 16px 64px; }}
  h1 {{ font-size: 32px; line-height: 1.1; margin: 0; }}
  .place, .now {{ color: var(--soft); font-size: 15px; }}
  h2 {{ font-size: 13px; letter-spacing: .08em; text-transform: uppercase; color: var(--soft);
       border-bottom: 1px solid var(--ink); padding-bottom: 4px; margin: 32px 0 8px; }}
  .essay p {{ margin: 0 0 14px; }}
  .essay figure {{ margin: 0 0 8px; }}
  .essay img {{ width: 140px; height: 140px; object-fit: contain; background: white;
               border-radius: 8px; float: right; margin: 0 0 8px 12px; }}
  .visit {{ display: grid; grid-template-columns: 56px 1fr 64px; gap: 12px; align-items: center;
           padding: 8px 0; border-bottom: 1px solid var(--rule); }}
  .visit time {{ font-weight: 700; font-variant-numeric: tabular-nums; }}
  .visit img {{ width: 64px; height: 64px; object-fit: cover; border-radius: 6px; background: white; }}
  .visit img.illo {{ object-fit: contain; }}
  .day {{ font-weight: 700; margin: 18px 0 2px; }}
  .song {{ padding: 10px 0; border-bottom: 1px solid var(--rule); }}
  .song audio {{ width: 100%; margin-top: 6px; }}
  .fine {{ color: var(--soft); font-size: 13px; margin-top: 32px; }}
</style></head>
<body><main>
<h1>Backyard Birds</h1>
<div class="place">{place}</div>
<div class="now">{now}</div>
<h2>This week</h2>
<div class="essay">{essay}</div>
<h2>Every visit</h2>
{visits}
<h2>Hear them</h2>
{songs}
<p class="fine">Pictures are drawings of each species until the feeder's own photos come in.
Visits marked by Bird Buddy are its own identifications. Recordings from xeno-canto,
by the recordists named. Updated {updated}. {costs}</p>
</main></body></html>
"""


def cost_line(conn) -> str:
    """One sentence on what Claude has cost this month, for the phone page."""
    import costs
    m = costs.month(conn)
    if not m["calls"]:
        return ""
    return (f"Claude has cost ${m['total']:.2f} so far in {m['month'].split()[0]}, "
            f"about ${m['projected']:.2f} for the month at this pace.")


def build_site(conn, payload: dict) -> Path:
    """The week in color, for phones: the essay with its pictures, every
    visit of the week, and each species' song. photos.publish_site puts it
    online."""
    site = db.ARCHIVE / "site"
    (site / "photos").mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc)
    week = visits(conn, now)
    icons = {r["scientific_name"]: r for r in conn.execute("SELECT * FROM species_info")}

    def picture(v) -> tuple[str, str]:
        if v["path"]:
            src = db.ARCHIVE / v["path"]
            name = f"{v['id'].replace(':', '_')}{src.suffix}"
            if not (site / "photos" / name).exists():
                (site / "photos" / name).write_bytes(src.read_bytes())
            return f"photos/{name}", ""
        return (v["icon"] or ""), "illo"

    def strong(text: str) -> str:
        parts = html.escape(text).split("**")
        return "".join(f"<b>{p}</b>" if i % 2 else p for i, p in enumerate(parts))

    essay = conn.execute("SELECT * FROM essays ORDER BY written_at DESC LIMIT 1").fetchone()
    essay_html = ""
    for i, para in enumerate(json.loads(essay["paragraphs"]) if essay else []):
        sp = icons.get(para.get("species"))
        img = f'<img src="{sp["icon_url"]}" alt="">' if sp and sp["icon_url"] and i < 2 else ""
        lead = f"<i>{html.escape(essay['dateline'])}</i> " if i == 0 else ""
        essay_html += f"<p>{img}{lead}{strong(para['text'])}</p>"

    rows, day = [], None
    for v in week:
        label = day_label(v["when"], now.astimezone().date())
        if label != day:
            rows.append(f'<div class="day">{label}</div>')
            day = label
        src, cls = picture(v)
        img = f'<img class="{cls}" src="{src}" alt="">' if src else "<span></span>"
        rows.append(f'<div class="visit"><time>{v["when"]:%-I:%M}</time>'
                    f'<span>{strong(v["caption"])}</span>{img}</div>')

    songs = ""
    for name in dict.fromkeys(v["species"] for v in week if v["species"]):
        sp = icons.get(name)
        if sp and sp["song_url"]:
            credit = f" · recorded by {html.escape(sp['song_author'])}" if sp["song_author"] else ""
            songs += (f'<div class="song"><b>{html.escape(sp["common_name"])}</b>{credit}'
                      f'<audio controls preload="none" src="{sp["song_url"]}"></audio></div>')

    # Short links that forward to each recording, for the call QR codes.
    (site / "s").mkdir(exist_ok=True)
    for sp in icons.values():
        if sp["song_url"]:
            (site / "s" / f"{slug(sp['common_name'])}.html").write_text(
                f'<!doctype html><meta charset="utf-8"><meta name="viewport" '
                f'content="width=device-width, initial-scale=1"><meta http-equiv="refresh" '
                f'content="0;url={sp["song_url"]}"><title>{html.escape(sp["common_name"])}</title>'
                f'<p><a href="{sp["song_url"]}">{html.escape(sp["common_name"])}</a></p>')

    readings = payload.get("now", {})
    now_line = " · ".join(x for x in (readings.get("weather"),
                                      f"Sunset {readings['sunset']}" if readings.get("sunset") else None,
                                      f"Seed: {readings['seed_until']}" if readings.get("seed", 3) <= 1 else None) if x)
    (site / "index.html").write_text(SITE_PAGE.format(place=html.escape(f"{config.FEEDER}, {config.PLACE}"), 
        now=html.escape(now_line), essay=essay_html, visits="\n".join(rows),
        songs=songs or "<p>No recordings yet.</p>",
        costs=cost_line(conn),
        updated=f"{now.astimezone():%A %-I:%M %p}"))
    return site / "index.html"


def device_webhook() -> str | None:
    """The TRMNL plugin's webhook URL, from the Keychain (service
    "trmnl-webhook"), or None until the plugin exists on the device."""
    found = subprocess.run(
        ["security", "find-generic-password", "-s", "trmnl-webhook", "-w"],
        capture_output=True, text=True)
    return found.stdout.strip() or None


def send(payload: dict, url: str = LOCAL_WEBHOOK) -> int:
    """Post the payload as TRMNL's webhook takes it; returns its size."""
    payload = {k: v for k, v in payload.items() if k != "_about"}
    payload["feed"] = [dict(day, rows=list(day["rows"])) for day in payload.get("feed", [])]

    def size() -> int:
        return len(json.dumps(payload, separators=(",", ":")).encode())

    # Over TRMNL's limit, the oldest visits go first; they're the ones the
    # screen has least room for anyway.
    while size() > LIMIT_BYTES and payload["feed"]:
        payload["feed"][-1]["rows"].pop()
        if not payload["feed"][-1]["rows"]:
            payload["feed"].pop()
    # TRMNL's Cloudflare refuses Python's default user agent (error 1010).
    request = urllib.request.Request(
        url, data=json.dumps({"merge_variables": payload}).encode(),
        method="POST", headers={"Content-Type": "application/json",
                                "User-Agent": "bird-log/0.1 (TRMNL private plugin)"})
    with urllib.request.urlopen(request, timeout=10):
        return size()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--sample", action="store_true",
                        help="send the made-up week in wall/sample-week.json")
    parser.add_argument("--print", action="store_true",
                        help="print the payload instead of sending it")
    parser.add_argument("--to", choices=["preview", "device", "both"],
                        default="preview", help="where to send it")
    args = parser.parse_args()

    payload = (json.loads((FACE / "sample-week.json").read_text())
               if args.sample else from_archive())
    if args.print:
        print(json.dumps(payload, indent=2))
        return
    if args.to in ("preview", "both"):
        print(f"Sent {send(payload)} bytes to the preview.")
    if args.to in ("device", "both"):
        url = device_webhook()
        if not url:
            raise SystemExit("No device webhook yet. Add it with:\n"
                             "  security add-generic-password -s trmnl-webhook -a bird-log -w")
        print(f"Sent {send(payload, url)} bytes to the TRMNL.")


if __name__ == "__main__":
    main()
