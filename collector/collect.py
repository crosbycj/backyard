# /// script
# requires-python = ">=3.10"
# dependencies = ["pybirdbuddy>=0.1.0", "anthropic>=2.1", "pillow>=10", "boto3>=1.34",
#                 "httpx[http2]>=0.27", "pyjwt[crypto]>=2.8"]
# ///
"""Bring new feeder visits into the archive, identify them, update the screen.

Signs in to Bird Buddy as the collector account, reads the feed back a
little past the newest visit we already have, and for each new postcard
downloads every photo and video at full size (the links expire), then
records the visit. New visits are identified and the screen's data is sent
to the preview and, once its webhook is in the Keychain, the TRMNL. Runs every 10 minutes under launchd (see
bird-log.collect.plist); safe to run by hand any time.

Credentials come from the macOS Keychain (service "birdbuddy"):
    security add-generic-password -s birdbuddy -a <email> -w

Run:
    uv run collector/collect.py
"""

from __future__ import annotations

import asyncio
import json
import re
import sqlite3
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

from birdbuddy.client import BirdBuddy

import config
import db
import identify
import publish

VISITS = db.ARCHIVE / "visits"
POSTCARD_TYPES = {"FeedItemNewPostcard", "FeedItemCollectedPostcard"}
LOOKBACK = timedelta(hours=6)    # how far past our newest visit to reread
FIRST_RUN = timedelta(days=7)    # how far back to look with an empty archive


def log(message: str) -> None:
    print(f"{datetime.now():%Y-%m-%d %H:%M:%S}  {message}", flush=True)


def keychain_login() -> tuple[str, str]:
    """The Bird Buddy email and password, from the Keychain."""
    try:
        attrs = subprocess.run(
            ["security", "find-generic-password", "-s", "birdbuddy"],
            capture_output=True, text=True, check=True).stdout
        password = subprocess.run(
            ["security", "find-generic-password", "-s", "birdbuddy", "-w"],
            capture_output=True, text=True, check=True).stdout.strip()
    except subprocess.CalledProcessError:
        sys.exit("No Keychain item 'birdbuddy'. Add it with:\n"
                 "  security add-generic-password -s birdbuddy -a <email> -w")
    return re.search(r'"acct"<blob>="([^"]*)"', attrs).group(1), password


def when(node: dict) -> datetime:
    return datetime.fromisoformat(node["createdAt"].replace("Z", "+00:00"))


def species_names(node: dict) -> list[str]:
    """Bird Buddy's guesses, from either a collected postcard or an analysis."""
    names = [s.get("name") for s in node.get("species") or [] if s.get("name")]
    preview = node.get("sightingReportPreview") or {}
    for sighting in preview.get("sightings") or []:
        if (s := sighting.get("species")) and s.get("name"):
            names.append(s["name"])
    return list(dict.fromkeys(names))


def download(url: str, dest) -> None:
    if dest.exists() and dest.stat().st_size > 0:
        return
    with urllib.request.urlopen(url, timeout=60) as response:
        dest.write_bytes(response.read())


async def new_postcards(bb: BirdBuddy, conn) -> list[dict]:
    newest = conn.execute(
        "SELECT MAX(seen_at) FROM visits WHERE source = 'birdbuddy'").fetchone()[0]
    cutoff = (datetime.fromisoformat(newest) - LOOKBACK if newest
              else datetime.now(timezone.utc) - FIRST_RUN)

    found: list[dict] = []
    async for page in bb._feed_pages():  # noqa: SLF001 — no public all-pages call
        nodes = [edge["node"] for edge in page.get("edges") or []]
        found += [n for n in nodes
                  if n.get("__typename") in POSTCARD_TYPES and n.get("createdAt")]
        dates = [when(n) for n in nodes if n.get("createdAt")]
        if dates and min(dates) < cutoff:
            break

    known = {row[0] for row in conn.execute("SELECT id FROM visits")}
    fresh = [n for n in found if n["id"] not in known and when(n) >= cutoff]
    return sorted(fresh, key=when)


async def save_visit(bb: BirdBuddy, conn, node: dict) -> bool:
    """Download a postcard's media and record it. False if we already have
    its media under another feed item (a postcard that's since been collected)."""
    detail = node
    if node["__typename"] == "FeedItemNewPostcard":
        # New postcards carry no media in the feed; "Identify this visitor"
        # returns it without collecting the postcard.
        detail = dict(await bb.identify_postcard(node["id"]))
    medias = detail.get("medias") or []
    ids = [m["id"] for m in medias]
    if ids and conn.execute(
            f"SELECT 1 FROM media WHERE id IN ({','.join('?' * len(ids))})",
            ids).fetchone():
        return False

    seen = when(node)
    folder = VISITS / f"{seen.astimezone():%Y-%m-%d_%H%M%S}_{node['id'][:8]}"
    folder.mkdir(parents=True, exist_ok=True)
    rows = []
    for i, m in enumerate(medias):
        kind = "video" if m.get("__typename") == "MediaVideo" else "photo"
        dest = folder / f"{i:02d}_{kind}{'.mp4' if kind == 'video' else '.jpg'}"
        download(m.get("contentUrl") or m["thumbnailUrl"], dest)
        rows.append((m["id"], node["id"], kind, m.get("createdAt"),
                     str(dest.relative_to(db.ARCHIVE)), m.get("width"), m.get("height")))

    with conn:
        conn.execute(
            "INSERT INTO visits (id, source, feeder, seen_at, bb_species, "
            "bb_confidence, raw) VALUES (?, 'birdbuddy', ?, ?, ?, ?, ?)",
            (node["id"], (detail.get("feeder") or {}).get("name"),
             seen.isoformat(timespec="seconds"), json.dumps(species_names(detail)),
             detail.get("inferenceConfidenceLevel"),
             json.dumps({"feed": node, "detail": detail}, default=str)))
        conn.executemany(
            "INSERT OR IGNORE INTO media (id, visit_id, kind, taken_at, path, "
            "width, height) VALUES (?, ?, ?, ?, ?, ?, ?)", rows)
    kinds = [r[2] for r in rows]
    log(f"visit {seen.astimezone():%b %-d %-I:%M %p}: {kinds.count('photo')} photos, "
        f"{kinds.count('video')} videos; Bird Buddy says "
        f"{', '.join(species_names(detail)) or 'nothing'}")
    return True


FEEDER_QUERY = """query { me { user { id } feeders { __typename
  ... on FeederForMember { id name state battery { percentage charging }
    food { state } signal { value } temperature { value } location { latitude longitude } }
  ... on FeederForOwner { id name state battery { percentage charging }
    food { state } signal { value } temperature { value } } } } }"""

REPORT_QUERY = """query($f: ID, $u: ID!, $s: DateTime, $e: DateTime) {
  userFeederReport(feederId: $f, userId: $u, start: $s, end: $e) {
    visitAggregateMetrics { totalNumberOfVisits
      speciesVisitSummaries { speciesId speciesLabel numberOfVisits } } } }"""

SPECIES_QUERY = """query($s: ID!) { species(speciesId: $s) { ... on SpeciesBird {
  name scientificName description iconUrl
  sounds { ... on SpeciesSoundSong { url authorName } ... on SpeciesSoundCall { url authorName } } } } }"""

REPORT_DAYS = 6           # Bird Buddy answers about the last five days or so
DAYLIGHT = range(5, 22)   # hours worth asking about; the feeder sleeps at night
HOUR_WORDS = ["midnight", "one", "two", "three", "four", "five", "six", "seven",
              "eight", "nine", "ten", "eleven", "noon"]
TIMES = {2: "twice", 3: "three times", 4: "four times", 5: "five times",
         6: "six times", 7: "seven times", 8: "eight times", 9: "nine times"}


def tidy_name(name: str) -> str:
    """Bird Buddy writes "Dark-Eyed Junco" and "Steller’s Jay"."""
    name = name.replace("’", "'")
    head, *rest = name.split("-")
    return "-".join([head] + [w[:1].lower() + w[1:] for w in rest])


def plural(name: str) -> str:
    return name + ("es" if name.endswith(("ch", "sh", "s", "x")) else "s")


def report_caption(name: str, visits: int, hour: int) -> str:
    """A sentence for an hour of Bird Buddy's report: a species, how many
    visits, roughly when."""
    around = HOUR_WORDS[hour if hour <= 12 else hour - 12]
    if visits == 1:
        article = "An" if name[0] in "AEIOU" else "A"
        return f"{article} **{name}** came around {around}."
    return f"**{plural(name)}** came {TIMES.get(visits, f'{visits} times')} around {around}."


async def read_feeder(bb: BirdBuddy, conn) -> tuple[str, str]:
    """Record the feeder's readings; return (feeder id, user id)."""
    me = (await bb._make_request(query=FEEDER_QUERY, variables={}))["me"]  # noqa: SLF001
    feeder = me["feeders"][0]
    location = feeder.get("location") or {}
    with conn:
        conn.execute(
            "INSERT INTO feeder_state (at, feeder, state, food, battery, charging, "
            "signal, temperature, latitude, longitude) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (db.now(), feeder["name"], feeder.get("state"),
             (feeder.get("food") or {}).get("state"),
             (feeder.get("battery") or {}).get("percentage"),
             int(bool((feeder.get("battery") or {}).get("charging"))),
             (feeder.get("signal") or {}).get("value"),
             (feeder.get("temperature") or {}).get("value"),
             location.get("latitude"), location.get("longitude")))
    return feeder["id"], me["user"]["id"]


async def species_info(bb: BirdBuddy, conn, bb_id: str, label: str) -> sqlite3.Row:
    """Bird Buddy's profile of a species, fetched the first time we meet it."""
    row = conn.execute("SELECT * FROM species_info WHERE bb_id = ?", (bb_id,)).fetchone()
    if row:
        return row
    try:
        sp = (await bb._make_request(query=SPECIES_QUERY,  # noqa: SLF001
                                     variables={"s": bb_id}))["species"] or {}
    except Exception as err:  # noqa: BLE001
        log(f"no profile for {label}: {err!r}")
        sp = {}
    song = next((s for s in sp.get("sounds") or [] if s.get("url")), {})
    with conn:
        conn.execute(
            "INSERT OR REPLACE INTO species_info (bb_id, common_name, scientific_name, "
            "description, icon_url, song_url, song_author, fetched_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (bb_id, tidy_name(sp.get("name") or label), sp.get("scientificName"),
             sp.get("description"), sp.get("iconUrl"), song.get("url"),
             song.get("authorName"), db.now()))
    return conn.execute("SELECT * FROM species_info WHERE bb_id = ?", (bb_id,)).fetchone()


async def read_reports(bb: BirdBuddy, conn, feeder_id: str, user_id: str) -> int:
    """Bird Buddy's visit counts, hour by hour, for the last few days.

    Each species in each hour becomes a visit (source "bb-report") with no
    photo and Bird Buddy's label. A finished hour is asked for once; the
    last two hours are asked again each run. Returns how many hours changed.
    """
    local_now = datetime.now().astimezone()
    done = {r[0] for r in conn.execute("SELECT hour_start FROM report_hours")}
    hour = (local_now - timedelta(days=REPORT_DAYS)).replace(
        hour=0, minute=0, second=0, microsecond=0)
    changed = 0
    while hour < local_now:
        start = hour.astimezone(timezone.utc).isoformat(timespec="seconds")
        final = hour + timedelta(hours=2) <= local_now
        this_hour, hour = hour, hour + timedelta(hours=1)
        if this_hour.hour not in DAYLIGHT or (final and start in done):
            continue
        try:
            data = await bb._make_request(query=REPORT_QUERY, variables={  # noqa: SLF001
                "f": feeder_id, "u": user_id, "s": start,
                "e": (this_hour + timedelta(hours=1)).isoformat()})
        except Exception:  # noqa: BLE001 — older days answer with an error
            continue
        metrics = (data.get("userFeederReport") or {}).get("visitAggregateMetrics") or {}
        prefix = f"report:{start}:"
        old = {r[0]: r[1] for r in conn.execute(
            "SELECT v.id, ci.caption FROM visits v "
            "JOIN current_identifications ci ON ci.visit_id = v.id WHERE v.id LIKE ?",
            (prefix + "%",))}
        new = {}
        for s in metrics.get("speciesVisitSummaries") or []:
            sp = await species_info(bb, conn, s["speciesId"], s["speciesLabel"])
            new[prefix + s["speciesId"]] = (sp, s["numberOfVisits"],
                                            report_caption(sp["common_name"], s["numberOfVisits"],
                                                           this_hour.hour))
        if {k: v[2] for k, v in new.items()} != old:
            changed += 1
            with conn:
                for visit_id in old:
                    conn.execute("DELETE FROM sightings WHERE identification_id IN "
                                 "(SELECT id FROM identifications WHERE visit_id = ?)", (visit_id,))
                    conn.execute("DELETE FROM identifications WHERE visit_id = ?", (visit_id,))
                    conn.execute("DELETE FROM visits WHERE id = ?", (visit_id,))
                for visit_id, (sp, visits, caption) in new.items():
                    conn.execute(
                        "INSERT INTO visits (id, source, feeder, seen_at, bb_species, raw) "
                        "VALUES (?, 'bb-report', ?, ?, ?, ?)",
                        (visit_id, config.FEEDER, start,
                         json.dumps([sp["common_name"]]), json.dumps({"visits": visits})))
                    cur = conn.execute(
                        "INSERT INTO identifications (visit_id, by, prompt_version, made_at, caption) "
                        "VALUES (?, 'bird-buddy', 'report', ?, ?)", (visit_id, db.now(), caption))
                    conn.execute(
                        "INSERT INTO sightings (identification_id, common_name, scientific_name, "
                        "is_bird, count, confidence) VALUES (?, ?, ?, 1, 1, 'bird-buddy')",
                        (cur.lastrowid, sp["common_name"], sp["scientific_name"]))
        if final:
            with conn:
                conn.execute("INSERT OR REPLACE INTO report_hours VALUES (?, ?, ?)",
                             (start, metrics.get("totalNumberOfVisits") or 0, db.now()))
    return changed


async def collect(conn) -> tuple[int, int]:
    """New postcards saved, and report hours that changed."""
    email, password = keychain_login()
    bb = BirdBuddy(email, password)
    await bb.refresh()
    saved = 0
    for node in await new_postcards(bb, conn):
        try:
            saved += await save_visit(bb, conn, node)
        except Exception as err:  # noqa: BLE001 — one bad postcard can't stop the rest
            log(f"postcard {node['id']} failed: {err!r}")
    changed = 0
    try:
        feeder_id, user_id = await read_feeder(bb, conn)
        changed = await read_reports(bb, conn, feeder_id, user_id)
    except Exception as err:  # noqa: BLE001 — the report is extra; postcards come first
        log(f"feeder or report read failed: {err!r}")
    return saved, changed


def notify_phones(conn) -> None:
    """Tell the phones what they asked to hear about (notify.py)."""
    import notify
    try:
        if n := notify.run(conn):
            log(f"sent {n} notification(s)")
    except Exception as err:  # noqa: BLE001 — they wait for the next run
        log(f"notifications failed: {err!r}")


def main() -> None:
    conn = db.connect()
    try:
        saved, changed = asyncio.run(collect(conn))
    except Exception:
        # Bird Buddy unreachable: the phones that asked hear about it, once.
        notify_phones(conn)
        raise
    try:
        main_after_collect(conn, saved, changed)
    finally:
        notify_phones(conn)


def main_after_collect(conn, saved: int, changed: int) -> None:
    log(f"{saved} new visit(s); {changed} report hour(s) changed")
    if conn.execute("SELECT 1 FROM visits WHERE source = 'sample'").fetchone() \
            and conn.execute("SELECT 1 FROM visits WHERE source != 'sample' "
                             "AND seen_at >= ?", ((datetime.now(timezone.utc)
                             - timedelta(days=7)).isoformat(),)).fetchone():
        # Real visits replace the made-up week.
        import sample_week
        with conn:
            sample_week.clear(conn)
        log("cleared the sample week; real visits are in")
    if saved:
        identify.identify_pending(conn)
    import feed
    try:
        if corrected := feed.take_inbox(conn):
            log(f"applied {corrected} correction(s) from the app")
            changed += corrected  # a corrected visit is news for the board and the story
    except Exception as err:  # noqa: BLE001 — the inbox waits for the next run
        log(f"app inbox failed: {err!r}")
    import daynote
    import essay
    note_due = daynote.due(conn)
    if not (saved or changed) and datetime.now().minute >= 10 \
            and not essay.due(conn, False) and not note_due:
        return  # nothing new; the board is refreshed once an hour regardless
    import cards
    cards.write_missing(conn)
    import likely
    try:
        if n := likely.write(conn):
            log(f"wrote {n} likely bird(s) for the month")
    except Exception as err:  # noqa: BLE001 — the month's list can wait for the next run
        log(f"likely birds failed: {err!r}")
    if essay.due(conn, changed=bool(saved or changed)):
        log(f"reconsidered the story: {essay.reconsider(conn)}")
    if note_due:
        log(f"wrote tonight's note: {daynote.write(conn)}")
    import photos
    try:
        if n := photos.publish_photos(conn):
            log(f"uploaded {n} plate photo(s)")
    except Exception as err:  # noqa: BLE001 — no photo is better than no board
        log(f"plate upload failed: {err!r}")
    payload = publish.from_archive()
    site = publish.build_site(conn, payload).parent
    try:
        if n := photos.publish_site(site):
            log(f"uploaded {n} week page file(s)")
    except Exception as err:  # noqa: BLE001 — the board matters more than the page
        log(f"week page upload failed: {err!r}")
    try:
        log(f"sent {publish.send(payload)} bytes to the preview")
    except (urllib.error.URLError, ConnectionError):
        log("preview isn't running; screen data not sent there")
    if url := publish.device_webhook():
        try:
            log(f"sent {publish.send(payload, url)} bytes to the TRMNL")
        except urllib.error.HTTPError as err:
            log(f"TRMNL refused the update: {err.code} {err.reason}")
    try:
        counts = feed.publish(conn, wall=payload)
        log(f"app feed: sent {counts['json']} JSON and {counts['media']} media file(s)")
    except Exception as err:  # noqa: BLE001 — the app catches up next run
        log(f"app feed upload failed: {err!r}")


if __name__ == "__main__":
    main()
