# /// script
# requires-python = ">=3.10"
# dependencies = ["httpx[http2]>=0.27", "pyjwt[crypto]>=2.8", "boto3>=1.34", "pillow>=10"]
# ///
"""Notifications: what's worth telling each phone, sent through Apple.

Each phone says, through the inbox (feed.take_inbox), which kinds it wants
and which birds it follows; nothing here guesses. The kinds:

    visit   every photographed visit; a bird's repeats within the hour fold
            into one ("House Finches, 3 visits since 9:10 AM"), quietly
    good    the good ones: a photo Claude scored 5, or a bird back after
            two weeks or more
    new     a bird new to the yard list
    follow  a bird the phone follows
    decide  a visit Claude called a maybe, asked as a question with answers
    note    tonight's note (daynote.py), once it's written
    story   the week's story, Sunday evening
    seed    the seed's probably out (db.seed), once, in the day
    broken  the feeder offline or its battery low, or Bird Buddy unreachable

A visit goes once per phone, as the first of new, decide, follow, good,
visit that the phone wants. Visits older than FRESH (the Mac slept, a
postcard came late) fold into one "Earlier at the feeder", except a new
bird and a question. Nothing from before a phone first asked is sent.

The key is Apple's (a .p8 from the developer account, Keys, Apple Push
Notifications service), in the Keychain under service "apns-backyard":
    security add-generic-password -s apns-backyard -a key-id -w <KEY ID>
    security add-generic-password -s apns-backyard -a p8 -w "$(base64 -i AuthKey_<KEY ID>.p8)"
Without it, what would go is recorded as unsent and logged.

Run (the collector runs it every time):
    uv run collector/notify.py --dry-run         # what would go now, sent nowhere
    uv run collector/notify.py --test good       # one of a kind to every phone, now
    uv run collector/notify.py --payload decide  # print one for `xcrun simctl push`
"""

from __future__ import annotations

import argparse
import base64
import json
import subprocess
import time
from datetime import datetime, timedelta, timezone

import config
import db

TEAM = config.APNS_TEAM
TOPIC = config.APNS_TOPIC
HOSTS = {"production": "https://api.push.apple.com", "sandbox": "https://api.sandbox.push.apple.com"}
KINDS = ("visit", "good", "new", "follow", "decide", "note", "story", "seed", "broken")
# A visit goes as the first of these the phone wants.
ORDER = ("new", "decide", "follow", "good", "visit")
FRESH = timedelta(minutes=45)  # older than this, a visit is old news
LOOKBACK = timedelta(hours=12)
BACK_AFTER = timedelta(days=14)  # a bird gone this long is worth a look when it comes back
DAYTIME = range(8, 20)  # local hours a feeder alarm may ring
BATTERY_LOW = 15
BB_SILENT = timedelta(minutes=90)  # no feeder reading this long: Bird Buddy unreachable
OFFLINE_FOR = timedelta(hours=1)

# How each kind arrives. Passive is silent and lands in Notification Center;
# time-sensitive gets through Focus unless the person turned that off.
STYLE = {
    "visit": ("passive", False, 0.3), "good": ("active", False, 0.7),
    "new": ("time-sensitive", True, 1.0), "follow": ("active", True, 0.8),
    "decide": ("active", False, 0.6), "note": ("active", False, 0.5),
    "story": ("active", False, 0.5), "seed": ("active", True, 0.6),
    "broken": ("active", True, 0.6), "earlier": ("passive", False, 0.3),
}


def log(message: str) -> None:
    print(f"{datetime.now():%Y-%m-%d %H:%M:%S}  {message}", flush=True)


# MARK: - Phones

def save_devices(conn, devices: list[dict]) -> int:
    """Record the phones' notification settings from the inbox. Returns how
    many changed."""
    changed = 0
    for d in devices:
        if not d.get("device"):
            continue
        kinds = sorted(k for k in d.get("kinds") or [] if k in KINDS)
        follow = sorted(set(d.get("follow") or []))
        row = conn.execute("SELECT * FROM push_devices WHERE device = ?", (d["device"],)).fetchone()
        fields = (d.get("token"), d.get("env") or "production", d.get("status"),
                  json.dumps(kinds), json.dumps(follow))
        if row and (row["token"], row["env"], row["status"], row["kinds"], row["follow"]) == fields:
            continue
        with conn:
            conn.execute(
                "INSERT INTO push_devices (device, token, env, status, kinds, follow, first_seen, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(device) DO UPDATE SET token = excluded.token, "
                "env = excluded.env, status = excluded.status, kinds = excluded.kinds, "
                "follow = excluded.follow, updated_at = excluded.updated_at",
                (d["device"], *fields, db.now(), db.now()))
        changed += 1
    return changed


def phones(conn) -> list[dict]:
    return [{"device": r["device"], "token": r["token"], "env": r["env"],
             "kinds": set(json.loads(r["kinds"])), "follow": set(json.loads(r["follow"])),
             "since": r["first_seen"]}
            for r in conn.execute("SELECT * FROM push_devices WHERE token IS NOT NULL "
                                  "AND COALESCE(status, '') != 'denied'")]


# MARK: - What's happened

def slug(name: str) -> str:
    import feed
    return feed.slug(name)


def plain(text: str | None) -> str:
    return (text or "").replace("**", "").strip()


def plural(name: str) -> str:
    return name + ("es" if name.endswith(("ch", "sh", "s", "x")) else "s")


def ordinal(n: int) -> str:
    return f"{n}{'th' if 10 <= n % 100 <= 20 else {1: 'st', 2: 'nd', 3: 'rd'}.get(n % 10, 'th')}"


def clock(moment: datetime) -> str:
    return f"{moment.astimezone():%-I:%M %p}"


def image(conn, media_id: str | None) -> str | None:
    """The public address of a visit's photo at screen size, from the feed."""
    if not media_id:
        return None
    import feed
    import photos
    return f"{photos.PUBLIC}/{feed.base()}{feed.folder(media_id)}/l.jpg"


def recent_visits(conn, now: datetime) -> list[dict]:
    """Photographed visits Claude has identified, from LOOKBACK until now,
    with what makes each worth telling."""
    since = (now - LOOKBACK).isoformat(timespec="seconds")
    rows = conn.execute(
        "SELECT v.id, v.seen_at, ci.id AS ident, ci.caption, ci.best_media, ci.raw "
        "FROM visits v JOIN current_identifications ci ON ci.visit_id = v.id "
        "WHERE v.source = 'birdbuddy' AND v.seen_at >= ? ORDER BY v.seen_at", (since,)).fetchall()
    yard = db.yard(conn, now)
    # The visit each new bird was first photographed in, surely.
    firsts = {}
    for species in yard["new"]:
        first = conn.execute(
            "SELECT v.id FROM visits v JOIN current_identifications ci ON ci.visit_id = v.id "
            "JOIN sightings s ON s.identification_id = ci.id WHERE v.source != 'bb-report' "
            "AND s.confidence = 'high' AND (s.scientific_name = ? OR s.scientific_name LIKE ?) "
            "ORDER BY v.seen_at LIMIT 1", (species, species + " %")).fetchone()
        if first:
            firsts[first["id"]] = species
    out = []
    for r in rows:
        birds = [s for s in conn.execute(
            "SELECT * FROM sightings WHERE identification_id = ? ORDER BY rowid", (r["ident"],))
            if s["is_bird"]]
        if not birds:
            continue
        top = birds[0]
        name = top["common_name"].split(" (")[0]
        raw = json.loads(r["raw"] or "{}")
        seen = datetime.fromisoformat(r["seen_at"])
        before = conn.execute(
            "SELECT MAX(v.seen_at) FROM visits v JOIN current_identifications ci ON ci.visit_id = v.id "
            "JOIN sightings s ON s.identification_id = ci.id WHERE v.source != 'bb-report' "
            "AND s.common_name = ? AND v.seen_at < ?", (top["common_name"], r["seen_at"])).fetchone()[0]
        gone = seen - datetime.fromisoformat(before) if before else None
        out.append({
            "id": r["id"], "seen": seen, "name": name, "bird": slug(top["common_name"]),
            "birds": {slug(s["common_name"]) for s in birds},
            "caption": plain(r["caption"]) or f"A {name} at the feeder.",
            "confidence": top["confidence"], "score": raw.get("photo_score"),
            "image": image(conn, r["best_media"]),
            "new": yard["new"].get(firsts[r["id"]]) if r["id"] in firsts else None,
            "back": gone if gone and gone >= BACK_AFTER else None,
        })
    return out


def visit_kind(v: dict, phone: dict) -> str | None:
    """The kind a visit goes to this phone as, if any."""
    wants = phone["kinds"]
    if "new" in wants and v["new"]:
        return "new"
    if "decide" in wants and v["confidence"] == "low":
        return "decide"
    if "follow" in wants and v["birds"] & phone["follow"]:
        return "follow"
    if "good" in wants and ((v["score"] or 0) >= 5 or v["back"]):
        return "good"
    return "visit" if "visit" in wants else None


def visit_note(v: dict, kind: str, repeats: int = 1, first: datetime | None = None) -> dict:
    """A visit as a notification: title, subtitle, body and where it opens."""
    title, subtitle, body = v["name"], None, v["caption"]
    if kind == "new":
        title = f"New to the yard: {v['name']}"
        subtitle = f"The {ordinal(v['new'])} bird on the yard list"
    elif kind == "decide":
        title = f"Is this a {v['name']}?"
        body = f"Claude isn't sure. {v['caption']}"
    elif kind == "good" and v["back"]:
        weeks = v["back"].days // 7
        subtitle = f"Back after {weeks} weeks" if weeks >= 2 else "Back after a while"
    elif kind == "visit" and repeats > 1:
        title = plural(v["name"])
        subtitle = f"{repeats} visits since {clock(first)}"
    return {"title": title, "subtitle": subtitle, "body": body, "open": f"backyard://visit/{v['id']}",
            "image": v["image"], "visit": v["id"], "bird": v["name"]}


def writing(conn, now: datetime) -> list[tuple[str, str, datetime, dict]]:
    """Tonight's note and, on Sunday evening, the week's story: (key, kind,
    when, note)."""
    local = now.astimezone()
    out = []
    note = conn.execute("SELECT * FROM day_notes WHERE day = ?", (local.date().isoformat(),)).fetchone()
    if note:
        out.append((f"note:{note['day']}", "note", datetime.fromisoformat(note["written_at"]),
                    {"title": "Tonight's note", "body": plain(note["text"]),
                     "open": f"backyard://day/{note['day']}"}))
    if local.weekday() == 6 and (note or local.hour >= 18):
        monday = local.date() - timedelta(days=6)
        story = conn.execute("SELECT * FROM essays WHERE written_at >= ? ORDER BY written_at DESC LIMIT 1",
                             (datetime.combine(monday, datetime.min.time()).astimezone()
                              .astimezone(timezone.utc).isoformat(timespec="seconds"),)).fetchone()
        if story:
            first = next((p["text"] for p in json.loads(story["paragraphs"])), "")
            out.append((f"story:{monday}", "story", now,
                        {"title": "The week in the yard", "subtitle": plain(story["dateline"]),
                         "body": plain(first), "open": "backyard://today"}))
    return out


def feeder(conn, now: datetime) -> list[tuple[str, str, datetime, dict]]:
    """The seed and anything broken, in the daytime only: (key, kind, when, note)."""
    local = now.astimezone()
    if local.hour not in DAYTIME:
        return []
    import weather
    out = []
    sky = weather.now(*db.place(conn))
    plain_local = local.replace(tzinfo=None)
    seed = db.seed(conn, plain_local, *((sky["sunrise"][0], sky["sunset"][0]) if sky else ()))
    if seed and seed["level"] == 0:
        seen = db.seen_words(seed["seen"], plain_local)
        body = (f"Claude saw the tray empty at {seen}." if seed["words"] == "empty"
                else f"Claude saw only a few seeds left at {seen}, and no bird has come for hours since.")
        out.append((f"seed:{seed['seen'].isoformat()}", "seed", now,
                    {"title": "The seed's probably out", "body": body, "open": "backyard://today"}))

    readings = conn.execute("SELECT * FROM feeder_state ORDER BY at DESC LIMIT 12").fetchall()
    if readings:
        last = datetime.fromisoformat(readings[0]["at"])
        if now - last >= BB_SILENT:
            out.append((f"broken:bb:{readings[0]['at']}", "broken", now,
                        {"title": "Can't reach Bird Buddy",
                         "body": f"The collector hasn't heard from the feeder since {clock(last)}. "
                                 "Bird Buddy may be down, or the sign-in may have stopped working.",
                         "open": "backyard://today"}))
        if readings[0]["state"] == "OFFLINE":
            since = readings[0]
            for r in readings:
                if r["state"] != "OFFLINE":
                    break
                since = r
            start = datetime.fromisoformat(since["at"])
            if now - start >= OFFLINE_FOR:
                out.append((f"broken:offline:{since['at']}", "broken", now,
                            {"title": "The feeder is offline",
                             "body": f"Since about {clock(start)}. It may need charging, or the Wi-Fi may be down.",
                             "open": "backyard://today"}))
        battery, charging = readings[0]["battery"], readings[0]["charging"]
        if battery is not None and battery <= BATTERY_LOW and not charging:
            out.append((f"broken:battery:{local.date()}", "broken", now,
                        {"title": f"The feeder's battery is at {battery}%",
                         "body": "Time to charge it, or it will stop taking postcards.",
                         "open": "backyard://today"}))
    return out


# MARK: - Deciding

def decide(conn, now: datetime | None = None) -> list[dict]:
    """Everything that should go now, to whom: [{key, device, kind, note,
    phone, folded: [keys]}]. Records nothing."""
    now = now or datetime.now(timezone.utc)
    sent = {(r["key"], r["device"]) for r in conn.execute(
        "SELECT key, device FROM notifications WHERE sent_at >= ?",
        ((now - timedelta(days=30)).isoformat(timespec="seconds"),))}
    visits = recent_visits(conn, now)
    others = writing(conn, now) + feeder(conn, now)
    out = []
    for phone in phones(conn):
        since = datetime.fromisoformat(phone["since"])
        stale: list[tuple[dict, str]] = []
        for v in visits:
            key = f"visit:{v['id']}"
            if (key, phone["device"]) in sent or v["seen"] < since:
                continue
            kind = visit_kind(v, phone)
            if not kind:
                continue
            if now - v["seen"] > FRESH and kind not in ("new", "decide"):
                stale.append((v, kind))
                continue
            repeats, first = 1, v["seen"]
            if kind == "visit":
                # The bird's visits so far this hour, this one included.
                hour = v["seen"].astimezone().replace(minute=0, second=0, microsecond=0)
                same = [x for x in visits if x["bird"] == v["bird"] and x["seen"] <= v["seen"]
                        and x["seen"].astimezone() >= hour]
                repeats, first = len(same), same[0]["seen"]
            note = visit_note(v, kind, repeats, first)
            if kind == "visit":
                note["collapse"] = f"{v['bird']}-{hour:%Y%m%d%H}"[:64]
            note["thread"] = f"visits-{v['seen'].astimezone():%Y-%m-%d}"
            out.append({"key": key, "device": phone["device"], "kind": kind, "note": note,
                        "phone": phone, "folded": []})
        if stale:
            names = list(dict.fromkeys(v["name"] for v, _ in stale))
            counts = {n: sum(v["name"] == n for v, _ in stale) for n in names}
            names.sort(key=lambda n: -counts[n])
            said = [f"{plural(n)} ({counts[n]} visits)" if counts[n] > 1 else f"a {n}" for n in names]
            listed = said[0] if len(said) == 1 else ", ".join(said[:-1]) + " and " + said[-1]
            best = max(stale, key=lambda vk: (vk[0]["score"] or 0))[0]
            visits_word = "visit" if len(stale) == 1 else "visits"
            out.append({"key": f"earlier:{stale[-1][0]['id']}", "device": phone["device"], "kind": "earlier",
                        "note": {"title": "Earlier at the feeder",
                                 "subtitle": f"{len(stale)} {visits_word} since {clock(stale[0][0]['seen'])}",
                                 "body": f"{listed[0].upper()}{listed[1:]}.",
                                 "open": f"backyard://day/{stale[0][0]['seen'].astimezone():%Y-%m-%d}",
                                 "image": best["image"],
                                 "thread": f"visits-{stale[-1][0]['seen'].astimezone():%Y-%m-%d}"},
                        "phone": phone, "folded": [f"visit:{v['id']}" for v, _ in stale]})
        for key, kind, at, note in others:
            if kind not in phone["kinds"] or (key, phone["device"]) in sent or at < since:
                continue
            note["thread"] = "feeder" if kind in ("seed", "broken") else "writing"
            out.append({"key": key, "device": phone["device"], "kind": kind, "note": note,
                        "phone": phone, "folded": []})
    return out


# MARK: - Sending

def payload(kind: str, note: dict) -> dict:
    level, sound, relevance = STYLE[kind]
    alert = {"title": note["title"], "body": note["body"]}
    if note.get("subtitle"):
        alert["subtitle"] = note["subtitle"]
    aps = {"alert": alert, "interruption-level": level, "relevance-score": relevance,
           "thread-id": note.get("thread", kind), "mutable-content": 1}
    if sound:
        aps["sound"] = "default"
    if kind == "decide":
        aps["category"] = "decide"
    body = {"aps": aps, "kind": kind, "open": note["open"]}
    for field in ("image", "visit", "bird"):
        if note.get(field):
            body[field] = note[field]
    return body


def keychain(account: str) -> str | None:
    try:
        return subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "apns-backyard",
                               "-a", account, "-w"], capture_output=True, text=True,
                              check=True).stdout.strip()
    except subprocess.CalledProcessError:
        return None


class Apple:
    """Apple's push service, signed with the team's key (a token good for an hour)."""

    def __init__(self) -> None:
        self.key_id = keychain("key-id")
        p8 = keychain("p8")
        self.key = base64.b64decode(p8).decode() if p8 else None
        self.client = None
        self.token, self.made = None, 0.0

    @property
    def ready(self) -> bool:
        return bool(self.key_id and self.key)

    def bearer(self) -> str:
        if not self.token or time.time() - self.made > 40 * 60:
            import jwt
            self.made = time.time()
            self.token = jwt.encode({"iss": TEAM, "iat": int(self.made)}, self.key,
                                    algorithm="ES256", headers={"kid": self.key_id})
        return self.token

    def send(self, phone: dict, body: dict, collapse: str | None = None) -> tuple[int, str]:
        import httpx
        if self.client is None:
            self.client = httpx.Client(http2=True, timeout=15)
        passive = body["aps"]["interruption-level"] == "passive"
        headers = {"authorization": f"bearer {self.bearer()}", "apns-topic": TOPIC,
                   "apns-push-type": "alert", "apns-priority": "5" if passive else "10",
                   "apns-expiration": str(int(time.time()) + 6 * 3600)}
        if collapse:
            headers["apns-collapse-id"] = collapse
        response = self.client.post(f"{HOSTS.get(phone['env'], HOSTS['production'])}/3/device/{phone['token']}",
                                    json=body, headers=headers)
        reason = "" if response.status_code == 200 else (response.json().get("reason", "") if response.content else "")
        return response.status_code, reason


def run(conn, dry_run: bool = False) -> int:
    """Send what's due. Returns how many went."""
    due = decide(conn)
    if not due:
        return 0
    apple = None if dry_run else Apple()
    went = 0
    for item in due:
        body = payload(item["kind"], item["note"])
        if dry_run:
            print(f"{item['device'][:8]} {item['kind']:8} {body['aps']['alert']['title']}: "
                  f"{body['aps']['alert']['body'][:80]}")
            continue
        if not apple.ready:
            status = "unsent"
        else:
            try:
                code, reason = apple.send(item["phone"], body, item["note"].get("collapse"))
            except Exception as err:  # noqa: BLE001 — try again next run
                log(f"notification to {item['device'][:8]} failed: {err!r}")
                continue
            status = "sent" if code == 200 else f"refused: {code} {reason}"
            if reason in ("BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"):
                with conn:
                    conn.execute("UPDATE push_devices SET token = NULL WHERE device = ?", (item["device"],))
            went += code == 200
        with conn:
            conn.execute("INSERT OR REPLACE INTO notifications (key, device, kind, sent_at, status, payload) "
                         "VALUES (?, ?, ?, ?, ?, ?)",
                         (item["key"], item["device"], item["kind"], db.now(), status, json.dumps(body)))
            for key in item["folded"]:
                conn.execute("INSERT OR IGNORE INTO notifications (key, device, kind, sent_at, status) "
                             "VALUES (?, ?, 'visit', ?, 'folded')", (key, item["device"], db.now()))
    if apple and not apple.ready:
        log(f"no APNs key in the Keychain; {len(due)} notification(s) recorded as unsent")
    return went


# MARK: - Trying it

def sample(conn, kind: str) -> dict:
    """One notification of a kind, from the latest things in the archive."""
    latest = conn.execute("SELECT MAX(seen_at) FROM visits WHERE source = 'birdbuddy'").fetchone()[0]
    visits = recent_visits(conn, datetime.fromisoformat(latest) + timedelta(minutes=1)) if latest else []
    v = visits[-1] if visits else None
    if kind in ("visit", "good", "new", "follow", "decide") and v:
        v = {**v, "new": v["new"] or 12, "back": v["back"] or timedelta(days=21)}
        note = visit_note(v, kind, 3 if kind == "visit" else 1, v["seen"] - timedelta(minutes=40))
        note["thread"] = f"visits-{v['seen'].astimezone():%Y-%m-%d}"
        return payload(kind, note)
    if kind in ("note", "story"):
        row = (conn.execute("SELECT * FROM day_notes ORDER BY day DESC LIMIT 1").fetchone() if kind == "note"
               else conn.execute("SELECT * FROM essays ORDER BY written_at DESC LIMIT 1").fetchone())
        if kind == "note":
            return payload(kind, {"title": "Tonight's note", "body": plain(row["text"]),
                                  "open": f"backyard://day/{row['day']}", "thread": "writing"})
        first = next((p["text"] for p in json.loads(row["paragraphs"])), "")
        return payload(kind, {"title": "The week in the yard", "subtitle": plain(row["dateline"]),
                              "body": plain(first), "open": "backyard://today", "thread": "writing"})
    if kind == "seed":
        return payload(kind, {"title": "The seed's probably out", "open": "backyard://today", "thread": "feeder",
                              "body": "Claude saw only a few seeds left at 1:12 PM, and no bird has come for hours since."})
    return payload("broken", {"title": "The feeder is offline", "open": "backyard://today", "thread": "feeder",
                              "body": "Since about 2:10 PM. It may need charging, or the Wi-Fi may be down."})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true", help="say what would go, send nothing")
    parser.add_argument("--test", metavar="KIND", choices=KINDS, help="send one of a kind to every phone")
    parser.add_argument("--payload", metavar="KIND", choices=KINDS, help="print one, for simctl push")
    args = parser.parse_args()
    conn = db.connect()
    if args.payload:
        print(json.dumps({**sample(conn, args.payload), "Simulator Target Bundle": TOPIC}, indent=2,
                         ensure_ascii=False))
    elif args.test:
        apple = Apple()
        if not apple.ready:
            raise SystemExit("No APNs key in the Keychain (service apns-backyard); see notify.py's docstring.")
        body = sample(conn, args.test)
        for phone in phones(conn):
            code, reason = apple.send(phone, body)
            print(f"{phone['device'][:8]} ({phone['env']}): {code} {reason}")
    else:
        n = run(conn, args.dry_run)
        if not args.dry_run:
            print(f"sent {n}")


if __name__ == "__main__":
    main()
