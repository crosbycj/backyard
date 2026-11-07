# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow>=10", "boto3>=1.34"]
# ///
"""The app's feed: the whole archive as JSON files and photos in R2.

The iPhone app keeps its own copy of the yard and syncs it from here. The
feed lives in the same bucket as the board's plates, under app/<an
unguessable name>/ (made once, in archive/feed-token):

    v1/index.json            what's in the feed, each file with its hash,
                             and the feeder now
    v1/days/<date>.json      one local day: tonight's note, its best photos,
                             every visit with its caption, notes, birds, media
    v1/weeks/<monday>.json   one week (Monday to Sunday): the story as it
                             stood at the week's end, and the week's days
    v1/birds/<slug>.json     one species: its names, call, cards, firsts,
                             and every visit it was in
    m/<media id>/s.jpg       each photo for lists (SMALL px on the long edge)
    m/<media id>/l.jpg       ...and for the screen (LARGE px)
    m/<media id>/v.mp4       each video, as Bird Buddy sent it

The app reads index.json, then fetches only the files whose hash changed.
Only what changed is uploaded too: archive/feed-sent.json remembers the hash
of every file sent, and media are sent once. "v1" is the shape; a change the
app can't read bumps it, and the old version stays until the app moves.

Run (the collector runs it after publishing the board):
    uv run collector/feed.py            # build and upload what changed
    uv run collector/feed.py --dry-run  # build and say what would go
"""

from __future__ import annotations

import argparse
import hashlib
import html
import io
import json
import re
import secrets
import sqlite3
from datetime import date, datetime, timedelta, timezone

from PIL import Image, ImageOps

import config
import db
import photos

VERSION = 1
TOKEN = db.ARCHIVE / "feed-token"
SENT = db.ARCHIVE / "feed-sent.json"
SMALL = 640    # px, long edge: a third of the phone's width at 3x
LARGE = 2048   # px, long edge: full screen, with room to zoom
SOURCES = {"birdbuddy": "postcard", "bb-report": "report", "import": "import"}
# Where phones leave what people did in the app (kept visits, corrected
# birds) and what they want to be told (notify.py): one file each phone
# reads, merges its own into, and writes back through a signed address in
# the index. The collector reads it every run.
INBOX = "inbox/marks.json"
INBOX_DAYS = 7  # how long the signed address lasts; it's renewed every run


def base() -> str:
    """The feed's folder in the bucket, e.g. "app/Xy12…/"."""
    if not TOKEN.exists():
        TOKEN.write_text(secrets.token_urlsafe(12))
    return f"app/{TOKEN.read_text().strip()}/"


def url() -> str:
    """Where the app finds the feed."""
    return f"{photos.PUBLIC}/{base()}v{VERSION}/index.json"


def slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower().replace("'", "")).strip("-")


def local(iso: str) -> datetime:
    return datetime.fromisoformat(iso).astimezone()


def stamp(iso: str | None) -> str | None:
    return local(iso).isoformat(timespec="seconds") if iso else None


def monday(day: date) -> date:
    return day - timedelta(days=day.weekday())


def guide(name: str) -> str:
    """The species' page in Cornell's All About Birds."""
    return "https://www.allaboutbirds.org/guide/" + re.sub(r"[^A-Za-z0-9-]+", "_", name.replace("'", ""))


def safe(name: str) -> str:
    """An id as a file name; ids have colons ("import:…", "<visit>:frame:52.5")."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", name)


def folder(media_id: str) -> str:
    """A media file's folder."""
    return "m/" + safe(media_id)


def media_ref(m) -> dict:
    ref = {"id": m["id"], "kind": m["kind"]}
    if m["width"] and m["height"]:
        ref |= {"w": m["width"], "h": m["height"]}
    # When it was taken: the photos are moments inside the visit's video.
    if m["taken_at"]:
        ref["at"] = stamp(m["taken_at"])
    if m["kind"] == "video":
        ref["video"] = f"{folder(m['id'])}/v.mp4"
    else:
        ref |= {"small": f"{folder(m['id'])}/s.jpg", "large": f"{folder(m['id'])}/l.jpg"}
    return ref


def visits(conn) -> list[dict]:
    """Every visit, oldest first, as the app reads it. An hour of Bird
    Buddy's report is left out when a postcard saw the same bird in that
    hour, as on the wall. A visit new to the archive gets its number here."""
    db.number_visits(conn)
    rows = conn.execute(
        "SELECT v.id, v.source, v.seen_at, v.number, v.raw AS visit_raw, ci.id AS ident, ci.by, "
        "  ci.made_at, ci.caption, ci.notes, ci.best_media, ci.raw "
        "FROM visits v JOIN current_identifications ci ON ci.visit_id = v.id "
        "WHERE v.source IN ('birdbuddy', 'bb-report', 'import') ORDER BY v.seen_at").fetchall()
    sightings: dict[int, list] = {}
    for s in conn.execute("SELECT rowid, * FROM sightings ORDER BY rowid"):
        sightings.setdefault(s["identification_id"], []).append(s)
    media: dict[str, list] = {}
    for m in conn.execute("SELECT * FROM media ORDER BY path"):
        media.setdefault(m["visit_id"], []).append(m)

    covered = set()
    for r in rows:
        if r["source"] != "bb-report":
            hour = local(r["seen_at"]).replace(minute=0, second=0)
            covered |= {(hour, db.binomial(s["scientific_name"])) for s in sightings.get(r["ident"], [])}

    out = []
    for r in rows:
        birds = sightings.get(r["ident"], [])
        if r["source"] == "bb-report" and all(
                (local(r["seen_at"]), db.binomial(s["scientific_name"])) in covered for s in birds):
            continue
        raw = json.loads(r["raw"]) if r["raw"] else {}
        visit = {
            "id": r["id"], "at": stamp(r["seen_at"]), "source": SOURCES[r["source"]],
            "caption": r["caption"], "notes": r["notes"],
            "by": r["by"], "written_at": stamp(r["made_at"]),
            "confidence": birds[0]["confidence"] if birds else None,
            "birds": [{"name": s["common_name"], "scientific": db.binomial(s["scientific_name"]),
                       "bird": slug(s["common_name"]) if s["is_bird"] else None,
                       "count": s["count"], "confidence": s["confidence"],
                       "details": s["details"]} for s in birds],
            "media": [media_ref(m) for m in media.get(r["id"], [])],
        }
        if r["source"] == "bb-report":
            visit["reported"] = json.loads(r["visit_raw"] or "{}").get("visits", 1)
        else:
            visit["page"] = f"p/v/{safe(r['id'])}.html"
        if r["number"]:
            visit["number"] = r["number"]
        if r["best_media"]:
            visit["best"] = r["best_media"]
        if raw.get("photo_score") is not None:
            visit["score"] = raw["photo_score"]
        if raw.get("bird_box"):
            visit["box"] = raw["bird_box"]
        out.append(visit)
    return out


def best_photos(day_visits: list[dict], n: int = 4) -> list[str]:
    """A day's best photos by Claude's score, one per bird before any second
    of the same bird. A score of 1 (a back, a blur) never leads."""
    scored = sorted((v for v in day_visits if v.get("best") and v.get("score", 2) > 1),
                    key=lambda v: (v.get("score", 2), v["at"]), reverse=True)
    picked, birds = [], set()
    for v in scored:
        bird = v["birds"][0]["bird"] if v["birds"] else None
        if bird not in birds:
            birds.add(bird)
            picked.append(v)
    picked += [v for v in scored if v not in picked]
    return [v["best"] for v in picked[:n]]


def build(conn, reels: dict[str, dict] | None = None) -> dict[str, dict]:
    """Every JSON file of the feed, by its path under v<VERSION>/. `reels`
    are the days' reels as published ({day: {"video", "length", "clips"}})."""
    all_visits = visits(conn)
    by_day: dict[str, list] = {}
    for v in all_visits:
        by_day.setdefault(v["at"][:10], []).append(v)
    notes = {r["day"]: r for r in conn.execute("SELECT * FROM day_notes")}
    for day in notes:
        by_day.setdefault(day, [])
    files: dict[str, dict] = {}
    for day, vs in sorted(by_day.items()):
        note = notes.get(day)
        files[f"days/{day}.json"] = {
            "day": day,
            "note": {"text": note["text"], "by": note["by"], "written_at": stamp(note["written_at"])}
            if note else None,
            "best": best_photos(vs),
            "visits": vs,
            **({"reel": reels[day]} if reels and day in reels else {}),
        }

    # Weeks: the story as it stood when the week ended (or now).
    essays = conn.execute("SELECT * FROM essays ORDER BY written_at").fetchall()
    weeks = sorted({monday(date.fromisoformat(d)) for d in by_day}
                   | {monday(local(e["written_at"]).date()) for e in essays})
    for start in weeks:
        end = start + timedelta(days=7)
        story = next((e for e in reversed(essays) if start <= local(e["written_at"]).date() < end), None)
        days = [d for d in sorted(by_day) if start <= date.fromisoformat(d) < end]
        files[f"weeks/{start}.json"] = {
            "week": str(start), "end": str(end - timedelta(days=1)), "days": days,
            "story": {"dateline": story["dateline"], "by": story["by"],
                      "written_at": stamp(story["written_at"]),
                      "versions": sum(start <= local(e["written_at"]).date() < end for e in essays),
                      "paragraphs": [{"text": p["text"],
                                      "bird": None,
                                      "scientific": db.binomial(p.get("species")) or None}
                                     for p in json.loads(story["paragraphs"])]}
            if story else None,
        }

    # Birds: every species anyone saw, with Bird Buddy's call and Claude's cards.
    info = {db.binomial(r["scientific_name"]): r for r in conn.execute("SELECT * FROM species_info")}
    cards: dict[str, list] = {}
    for c in conn.execute("SELECT * FROM cards WHERE retired = 0 AND species IS NOT NULL ORDER BY id"):
        cards.setdefault(db.binomial(c["species"]), []).append(
            {"label": c["label"], "text": c["text"], "link": c["link"]})
    yard = db.yard(conn, datetime.now(timezone.utc))
    yard_no = {s: yard["species"].index(n) + 1 for s, n in yard["names"].items()}
    birds: dict[str, dict] = {}
    for v in all_visits:
        for s in v["birds"]:
            if not s["bird"]:
                continue
            b = birds.setdefault(s["bird"], {
                "key": s["bird"], "name": s["name"], "scientific": s["scientific"],
                "visits": [], "photographed": 0})
            if v["id"] not in [x["id"] for x in b["visits"]]:
                b["visits"].append({"id": v["id"], "at": v["at"], "confidence": s["confidence"],
                                    "best": v.get("best"), "score": v.get("score")})
                b["photographed"] += v["source"] != "report"
    for key, b in birds.items():
        sp = info.get(b["scientific"])
        # Paragraphs name the bird by scientific name; give them its key.
        for f in files.values():
            for p in (f.get("story") or {}).get("paragraphs", []):
                if p["scientific"] == b["scientific"]:
                    p["bird"] = key
        top = sorted((x for x in b["visits"] if x["best"] and (x["score"] or 2) > 1),
                     key=lambda x: (x["score"] or 2, x["at"]), reverse=True)
        files[f"birds/{key}.json"] = {
            **b, "first_seen": b["visits"][0]["at"], "last_seen": b["visits"][-1]["at"],
            "yard_no": yard_no.get(b["scientific"]),
            "icon": sp["icon_url"] if sp else None,
            "call": {"url": sp["song_url"], "by": sp["song_author"]} if sp and sp["song_url"] else None,
            "cards": cards.get(b["scientific"], []),
            "guide": guide(b["name"]),
            "best": [x["best"] for x in top[:6]],
            "page": f"p/b/{key}.html",
        }

    state = conn.execute("SELECT * FROM feeder_state ORDER BY at DESC LIMIT 1").fetchone()
    index = {
        "version": VERSION, "generated_at": stamp(db.now()),
        "media": f"{photos.PUBLIC}/{base()}",
        "place": f"{config.FEEDER}, {config.PLACE}", "tz": config.TZ,
        "now": {"at": stamp(state["at"]), "state": state["state"], "food": state["food"],
                "battery": state["battery"]} if state else None,
        "yard_list": [slug(n) for n in yard["species"]],
    }
    # The birds likely this month that haven't come yet, for Birds (likely.py).
    import likely
    if season := likely.current(conn):
        index["likely"] = {"month": season["month"], "birds": [
            {"name": b["common_name"], "scientific": b["scientific_name"], "chance": b["chance"],
             "note": b["note"], "guide": guide(b["common_name"])}
            for b in season["birds"] if b["common_name"] not in yard["species"]]}
    hashes = {path: digest(body) for path, body in files.items()}
    for kind in ("days", "weeks", "birds"):
        index[kind] = [{"key": p.split("/")[1].removesuffix(".json"), "hash": hashes[p],
                        **({"visits": len(files[p]["visits"])} if kind != "weeks" else {})}
                       for p in sorted(files) if p.startswith(kind + "/")]
    files["index.json"] = index
    return files


def encode(body: dict) -> bytes:
    return json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()


def digest(body: dict) -> str:
    return hashlib.sha256(encode(body)).hexdigest()[:16]


def resized(path, edge: int, quality: int) -> bytes:
    image = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    image.thumbnail((edge, edge), Image.LANCZOS)
    out = io.BytesIO()
    image.save(out, "JPEG", quality=quality, optimize=True, progressive=True)
    return out.getvalue()


PAGE = """<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{description}">
<style>body{{font:17px/1.5 Georgia,serif;max-width:40em;margin:2em auto;padding:0 1em;color:#1d1d1b;background:#f6f4ee}}
h1{{font-size:1.6em;line-height:1.2}}img{{max-width:100%;border-radius:8px}}li{{margin:.4em 0}}
.soft{{color:#6b6a64;font:15px/1.4 system-ui,sans-serif}}</style>
{body}
<p class="soft">From a backyard bird feeder: a Bird Buddy camera, its photos
identified by Claude. Kept in its own archive.</p>
</html>
"""


def plain(text: str | None) -> str:
    return (text or "").replace("**", "")


def when(iso: str) -> str:
    t = datetime.fromisoformat(iso)
    return f"{t:%A, %B %-d, %Y at %-I:%M %p}"


def visit_page(v: dict, media_base: str, has_bird_page) -> str:
    """One visit as a page a person, or Claude, can read: when, what was
    seen and how sure, what was happening, and the photos."""
    e = html.escape
    birds = "".join(
        f"<li><b>{e(s['name'])}</b>"
        + (f" (<i>{e(s['scientific'])}</i>)" if s.get("scientific") else "")
        + (f", {s['count']} at once" if (s.get("count") or 1) > 1 else "")
        + (f", {CONFIDENCE.get(s.get('confidence'), '')}" if s.get("confidence") else "")
        + (f". {e(s['details'])}" if s.get("details") else "")
        + (f' <a href="../b/{e(s["bird"])}.html">More about it in this yard</a>' if has_bird_page(s.get("bird")) else "")
        + "</li>" for s in v["birds"])
    who = ("Corrected by the owner; written by Claude from the photos." if v.get("by") == "owner"
           else "Identified by Claude from the photos alone.")
    photos = "".join(f'<p><a href="{e(media_base + m["large"])}"><img src="{e(media_base + m["large"])}" '
                     f'alt="Photo {i} of the visit"></a></p>'
                     for i, m in enumerate((m for m in v["media"] if m.get("large")), 1))
    video = "".join(f'<p><a href="{e(media_base + m["video"])}">The visit\'s video</a></p>'
                    for m in v["media"] if m.get("video"))
    first = v["birds"][0]["name"] if v["birds"] else "A visitor"
    body = (f"<h1>{e(plain(v.get('caption')) or first)}</h1>"
            f"<p>{e(when(v['at']))}.</p>"
            + (f"<h2>What was seen</h2><ul>{birds}</ul>" if birds else "")
            + (f"<h2>What was happening</h2><p>{e(plain(v.get('notes')))}</p>" if v.get("notes") else "")
            + f"<p class=\"soft\">{who}</p><h2>Photos</h2>{photos}{video}")
    return PAGE.format(title=e(f"{first} at the feeder, {when(v['at'])}"),
                       description=e(plain(v.get("caption")) or first), body=body)


def bird_page(b: dict, visits_by_id: dict) -> str:
    """One bird in this yard: how often and when it comes, what Claude
    noticed, and every visit with a link to its page."""
    e = html.escape
    rows = "".join(
        f'<li>{e(when(x["at"]))}: '
        + (f'<a href="../v/{safe(x["id"])}.html">{e(plain(visits_by_id[x["id"]].get("caption")) or "a visit")}</a>'
           if visits_by_id.get(x["id"], {}).get("page") else "counted by Bird Buddy (no photo)")
        + "</li>" for x in reversed(b["visits"]))
    cards = "".join(f"<li><b>{e(c['label'])}:</b> {e(c['text'])}</li>" for c in b.get("cards", []))
    body = (f"<h1>{e(b['name'])}</h1>"
            + (f"<p><i>{e(b['scientific'])}</i></p>" if b.get("scientific") else "")
            + f"<p>{b['photographed']} visit(s) with photos; first seen {e(when(b['first_seen']))}, "
              f"last seen {e(when(b['last_seen']))}."
            + (f" Number {b['yard_no']} on the yard list." if b.get("yard_no") else "") + "</p>"
            + (f"<h2>Notes</h2><ul>{cards}</ul>" if cards else "")
            + f'<p><a href="{e(b["guide"])}">All About Birds</a></p>'
            + f"<h2>Its visits</h2><ul>{rows}</ul>")
    return PAGE.format(title=e(f"{b['name']} in the backyard"),
                       description=e(f"Every visit of the {b['name']} to one backyard feeder"), body=body)


CONFIDENCE = {"high": "sure", "medium": "probably", "low": "maybe", "bird-buddy": "Bird Buddy's guess"}


def pages(files: dict[str, dict]) -> dict[str, str]:
    """The readable pages: one per photographed visit and one per bird."""
    media_base = f"{photos.PUBLIC}/{base()}"
    all_visits = {v["id"]: v for path, f in files.items() if path.startswith("days/") for v in f["visits"]}
    birds = {f["key"]: f for path, f in files.items() if path.startswith("birds/")}
    out = {}
    for v in all_visits.values():
        if v.get("page"):
            out[v["page"]] = visit_page(v, media_base, lambda key: key in birds)
    for b in birds.values():
        out[b["page"]] = bird_page(b, all_visits)
    return out


def wall_of(payload: dict) -> dict:
    """What the board knows right now, for the app's Today: the readings
    (weather, seed, the sun), the day's line (tonight's note, today in
    numbers, or the day ahead) and the cards it dealt."""
    today = next((d for d in payload.get("feed", []) if d.get("day") == "Today"), None)
    quiet = next((r for r in (today or {}).get("rows", []) if r.get("quiet")), None)
    line = (f"{quiet['lead']}**{quiet['bird']}**{quiet['rest']}" if quiet and quiet.get("bird")
            else (quiet or {}).get("lead", "") + (quiet or {}).get("rest", "")) if quiet else None
    return {"now": payload.get("now"), "line": line or None, "notes": payload.get("notes", [])}


def take_inbox(conn) -> int:
    """Read what the phones sent and apply it: each new correction becomes
    the owner's identification (identify.correct), each keep is recorded, and
    each phone's notification settings are saved (notify.save_devices).
    Returns how many corrections were applied."""
    import identify
    s3 = photos.bucket()
    try:
        body = s3.get_object(Bucket=photos.BUCKET, Key=base() + INBOX)["Body"].read()
    except s3.exceptions.NoSuchKey:
        return 0
    inbox = json.loads(body)
    # Each phone's notification settings and push token (notify.py).
    import notify
    notify.save_devices(conn, inbox.get("devices", []))
    applied = 0
    for m in inbox.get("marks", []):
        if not (m.get("id") and m.get("visit") and m.get("kind") in ("keep", "correct")):
            continue
        row = conn.execute("SELECT applied_at FROM phone_marks WHERE id = ?", (m["id"],)).fetchone()
        if row and (m["kind"] == "keep" or row["applied_at"]):
            continue
        with conn:
            conn.execute("INSERT OR IGNORE INTO phone_marks (id, kind, visit_id, body, received_at) "
                         "VALUES (?, ?, ?, ?, ?)",
                         (m["id"], m["kind"], m["visit"], json.dumps(m), db.now()))
        if m["kind"] == "correct" and (m.get("name") or "").strip():
            if identify.correct(conn, m["visit"], m["name"].strip()):
                with conn:
                    conn.execute("UPDATE phone_marks SET applied_at = ? WHERE id = ?",
                                 (db.now(), m["id"]))
                applied += 1
    return applied


def publish(conn, dry_run: bool = False, wall: dict | None = None) -> dict:
    """Upload what changed. Returns counts of JSON files and media sent.
    `wall` is the board's payload from the same run, for Today."""
    prefix = base()
    sent = json.loads(SENT.read_text()) if SENT.exists() else None
    s3 = None if dry_run else photos.bucket()
    if sent is None:
        # No record: what's already in the bucket counts as sent (media only;
        # every JSON file goes again).
        sent = {} if dry_run else {
            o["Key"]: "" for page in s3.get_paginator("list_objects_v2").paginate(
                Bucket=photos.BUCKET, Prefix=prefix + "m/") for o in page.get("Contents", [])}

    def put(key: str, body: bytes, kind: str, cache: str, mark: str) -> None:
        if not dry_run:
            s3.put_object(Bucket=photos.BUCKET, Key=prefix + key, Body=body,
                          ContentType=kind, CacheControl=cache)
            sent[prefix + key] = mark
            SENT.write_text(json.dumps(sent, indent=0, sort_keys=True))

    counts = {"json": 0, "media": 0, "bytes": 0}
    sizes = []  # photos whose width and height the archive doesn't know yet
    for m in conn.execute("SELECT * FROM media WHERE visit_id IN "
                          "(SELECT id FROM visits WHERE source IN ('birdbuddy', 'import'))").fetchall():
        src = db.ARCHIVE / m["path"]
        if not src.exists():
            continue
        wanted = ([("v.mp4", None)] if m["kind"] == "video"
                  else [("s.jpg", (SMALL, 78)), ("l.jpg", (LARGE, 84))])
        for name, size in wanted:
            key = f"{folder(m['id'])}/{name}"
            if prefix + key in sent:
                continue
            counts["media"] += 1
            if dry_run:
                continue
            body = src.read_bytes() if size is None else resized(src, *size)
            put(key, body, "video/mp4" if size is None else "image/jpeg",
                "public, max-age=31536000, immutable", "media")
            counts["bytes"] += len(body)
        if not (m["width"] and m["height"]) and m["kind"] != "video":
            with Image.open(src) as image:
                sizes.append((*ImageOps.exif_transpose(image).size, m["id"]))
    if sizes and not dry_run:
        try:
            with conn:
                conn.executemany("UPDATE media SET width = ?, height = ? WHERE id = ?", sizes)
        except sqlite3.OperationalError:
            pass  # the collector is writing; the sizes go in next run

    # Each day's reel (two or more visits with video), made when its clips change.
    import reel
    reels: dict[str, dict] = {}
    days = sorted({local(r["seen_at"]).strftime("%Y-%m-%d") for r in conn.execute(
        "SELECT seen_at FROM visits WHERE source = 'birdbuddy'")})
    for day in days:
        day_clips = reel.clips(conn, day)
        if len(day_clips) < 2:
            continue
        try:
            path, length = reel.make(day, day_clips)
        except Exception as err:  # noqa: BLE001 — a day without its reel still has its visits
            print(f"reel for {day} failed: {err!r}")
            continue
        key = f"r/{path.name}"
        if prefix + key not in sent:
            counts["media"] += 1
            if not dry_run:
                put(key, path.read_bytes(), "video/mp4", "public, max-age=31536000, immutable", "media")
        reels[day] = {"video": key, "length": round(length, 1), "clips": len(day_clips)}

    files = build(conn, reels)
    index = files.pop("index.json")
    for path, body in sorted(files.items()):
        key, h = f"v{VERSION}/{path}", digest(body)
        if sent.get(prefix + key) != h:
            data = encode(body)
            put(key, data, "application/json; charset=utf-8", "no-cache", h)
            counts["json"] += 1
            counts["bytes"] += len(data)
    # The readable pages, for "Ask Claude" and for anyone given a link.
    for path, page in sorted(pages(files).items()):
        data = page.encode()
        h = hashlib.sha256(data).hexdigest()[:16]
        if sent.get(prefix + path) != h:
            put(path, data, "text/html; charset=utf-8", "no-cache", h)
            counts["json"] += 1
            counts["bytes"] += len(data)
    if wall:
        index["wall"] = wall_of(wall)
    if not dry_run:
        index["inbox"] = {
            "get": f"{photos.PUBLIC}/{prefix}{INBOX}",
            "put": s3.generate_presigned_url(
                "put_object", ExpiresIn=INBOX_DAYS * 86_400,
                Params={"Bucket": photos.BUCKET, "Key": prefix + INBOX,
                        "ContentType": "application/json"}),
        }
    data = encode(index)
    # The index changes with the feeder's state, so it goes every run.
    put(f"v{VERSION}/index.json", data, "application/json; charset=utf-8", "no-cache", digest(index))
    counts["json"] += 1
    return counts


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true", help="build, upload nothing")
    parser.add_argument("--print", metavar="PATH", help="print one file, e.g. index.json")
    args = parser.parse_args()
    conn = db.connect()
    if args.print:
        print(json.dumps(build(conn)[args.print], indent=2, ensure_ascii=False))
        return
    counts = publish(conn, args.dry_run)
    print(f"{'would send' if args.dry_run else 'sent'} {counts['json']} JSON file(s) and "
          f"{counts['media']} media file(s), {counts['bytes'] / 1e6:.1f} MB; feed at {url()}")


if __name__ == "__main__":
    main()
