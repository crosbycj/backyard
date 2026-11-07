# /// script
# requires-python = ">=3.10"
# dependencies = ["anthropic>=2.1", "pillow>=10"]
# ///
"""Identify what came to the feeder, with Claude looking at the photos.

Finds visits that have photos but no identification yet, oldest first,
shows Claude every photo of each visit with only the place and the time,
and records what it saw: each species, how many, how sure, the feed's
sentence, the visit's best photo, and a note on what's happening. Claude
works blind: neither Bird Buddy's guess nor the feeder's history is shown,
so a call is never pulled toward an earlier one (shown its history, it
once turned a jay into a crow). History belongs in the writing, not the identifying.

A visit is identified once; a new prompt version doesn't redo old visits.
`--again` looks again only for what a newer prompt adds (the best photo,
the box around the bird, the photo's print score) and keeps what was
already said: the species, the caption and the notes. A full redo once
rewrote three morning captions and turned a House Finch into
"passerine sp.".

Each look also reads the seed tray (plenty, some, few, empty), which is
how the seed is known: Bird Buddy's sensor reads LOW whatever the tray
holds. `--trays DAYS` reads only the tray in recent visits that predate it.

Run:
    uv run collector/identify.py [--visit ID] [--again] [--trays DAYS]
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import shutil
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path

import anthropic
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps, ImageStat

import config
import claude
import db

PROMPT_VERSION = "2026-10-28"  # blind; hedged caption when unsure, best photo or frame, box, score; species, not forms; the tray
MAX_PHOTOS = 8  # per visit; a postcard rarely has more
FRAMES = 8  # moments from the visit's video, shown as one contact sheet
TILE = (256, 341)  # each frame on the sheet; the video is 3:4
LONG_EDGE = 1024  # px: plenty to identify a bird, about half the tokens of a full photo
LOCATION = config.PLACE

TRAY = """Read the seed tray too: the tray under the orange rim, at the \
bottom of the photos. Say how much seed is left, judged across all the photos: \
"plenty" (a full or heaped tray), "some" (seed covers part of the tray), "few" \
(scattered seeds, mostly bare tray), "empty" (no seed), or "unseen" (a bird or \
the angle hides the tray in every photo). Count only whole seeds, plump and \
striped; split, flat, empty hulls are not seed, however many there are."""

SYSTEM = f"""You are an expert field birder identifying visitors to a backyard \
bird feeder in {LOCATION} from its camera. The camera sits on the feeder, so \
birds are often very close, partly out of frame, blurred, or backlit.

For each visit you see every photo the camera took, numbered, with the \
date and time. Identify only from what the photos show.

Identify every animal in the photos. Use the current eBird/Clements common \
and scientific names. When the photos can't separate two species, say so and \
give the narrower group you can support (for example "Empidonax sp.") rather \
than guessing. Name the species, not a subspecies or form: "Dark-eyed \
Junco", Junco hyemalis; say "Oregon form" in the details. Count the most individuals of each species visible in any one \
photo. Note sex, age or plumage when the photos show it. Then write a short \
note: what's happening, anything unusual (banding, injury, odd plumage, \
behavior), in plain words a curious non-birder would enjoy. Don't pad it.

Also write the caption: one complete sentence of at most 90 characters for a \
feed of visits, naming the main bird once in **bold** with its count in words \
("A" or "An" for one bird), like "Three **House Finches**, a male and two \
females, argued over the tray." or "A **Steller's Jay** grabbed a beakful and left." \
Say male or female only when the photos show it and the species looks \
different by sex. If you aren't sure of the main bird (medium or low \
confidence), the caption says so, like "A long-tailed gray bird, probably a \
**Northern Mockingbird**, perched on the rim." No time of day; the feed \
shows it. And pick the best photo: \
the clearest view of the bird that would still read well as a small \
black-and-white print, and give the box around the main bird in that photo, \
as fractions of its width and height from the top left (0 to 1), so it can \
be cropped to the bird. Last, score that best photo as a print for the wall, \
1 to 5: 5 is a sharp, well-lit bird, whole or nearly, facing the camera or \
side-on, that would make a striking picture; 3 is clearly the bird but soft, \
cut off or turned away; 1 is a blur, a back, a wing, or mostly feeder.

After the photos there may be a contact sheet of moments from the visit's \
video, labeled F1 to F8, left to right then top to bottom. Use them to \
identify too. If one of those frames would make a better print than every \
photo, give its number as best_frame, and then the box and the score are \
for that frame (the box as fractions of that frame alone, not the sheet). \
Otherwise best_frame is 0.

""" + TRAY

TRAY_FIELD = {"type": "string", "enum": ["plenty", "some", "few", "empty", "unseen"]}

SCHEMA = {
    "type": "object",
    "properties": {
        "sightings": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "common_name": {"type": "string"},
                    "scientific_name": {"type": "string"},
                    "is_bird": {"type": "boolean"},
                    "count": {"type": "integer"},
                    "confidence": {"type": "string",
                                   "enum": ["high", "medium", "low"]},
                    "details": {"type": "string"},
                },
                "required": ["common_name", "scientific_name", "is_bird",
                             "count", "confidence", "details"],
                "additionalProperties": False,
            },
        },
        "notes": {"type": "string"},
        "caption": {"type": "string"},
        "best_photo": {"type": "integer"},
        "photo_score": {"type": "integer"},
        "best_frame": {"type": "integer"},
        "tray": TRAY_FIELD,
        "bird_box": {
            "type": "object",
            "properties": {k: {"type": "number"} for k in ("left", "top", "right", "bottom")},
            "required": ["left", "top", "right", "bottom"],
            "additionalProperties": False,
        },
    },
    "required": ["sightings", "notes", "caption", "best_photo", "bird_box", "photo_score",
                 "best_frame", "tray"],
    "additionalProperties": False,
}

def shrink(path) -> bytes:
    """The photo as a JPEG no longer than LONG_EDGE, so Claude reads fewer tokens."""
    image = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    image.thumbnail((LONG_EDGE, LONG_EDGE), Image.LANCZOS)
    out = io.BytesIO()
    image.save(out, "JPEG", quality=88)
    return out.getvalue()


def video_frames(path) -> list[tuple[float, Image.Image]]:
    """The sharpest frame from each eighth of the video, with its time in
    seconds. Two frames a second are read at full size; sharpness is the
    spread of edges, which skips motion blur but can't tell a bird's face
    from its back, so Claude chooses among them."""
    if not shutil.which("ffmpeg"):
        return []
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-vf", "fps=2",
                        "-q:v", "2", f"{tmp}/%03d.jpg"], check=True)
        files = sorted(Path(tmp).glob("*.jpg"))

        def sharpness(f) -> float:
            edges = Image.open(f).convert("L").resize((270, 360)).filter(ImageFilter.FIND_EDGES)
            return ImageStat.Stat(edges).var[0]

        stretch = max(1, -(-len(files) // FRAMES))  # frames per eighth, rounded up
        best = [max(files[i:i + stretch], key=sharpness) for i in range(0, len(files), stretch)]
        return [((int(f.stem) - 1) / 2, Image.open(f).copy()) for f in best]


def contact_sheet(frames) -> bytes:
    """The frames on one image, four across, labeled F1, F2..."""
    sheet = Image.new("RGB", (TILE[0] * 4, TILE[1] * -(-len(frames) // 4)), "white")
    font = ImageFont.load_default(size=26)
    for i, (_, frame) in enumerate(frames):
        x, y = TILE[0] * (i % 4), TILE[1] * (i // 4)
        sheet.paste(ImageOps.fit(frame, TILE), (x, y))
        draw = ImageDraw.Draw(sheet)
        draw.rectangle((x, y, x + 46, y + 32), fill="black")
        draw.text((x + 6, y + 2), f"F{i + 1}", fill="white", font=font)
    out = io.BytesIO()
    sheet.save(out, "JPEG", quality=88)
    return out.getvalue()


def visit_prompt(visit, photos, sheet: bytes | None = None) -> list[dict]:
    seen = datetime.fromisoformat(visit["seen_at"]).astimezone()
    content: list[dict] = [{
        "type": "text",
        "text": f"This visit: {seen:%A %B %-d, %Y at %-I:%M %p} local time.\n"
                f"{len(photos)} photo(s) follow, numbered from 1.",
    }]
    for i, photo in enumerate(photos, 1):
        content.append({"type": "text", "text": f"Photo {i}:"})
        content.append({"type": "image", "source": {
            "type": "base64", "media_type": "image/jpeg",
            "data": base64.standard_b64encode(shrink(db.ARCHIVE / photo["path"])).decode(),
        }})
    if sheet:
        content.append({"type": "text", "text": f"Moments from the video, F1 to F{FRAMES}:"})
        content.append({"type": "image", "source": {
            "type": "base64", "media_type": "image/jpeg",
            "data": base64.standard_b64encode(sheet).decode()}})
    return content


def kept(conn, earlier, answer: dict) -> dict:
    """A new look with the earlier identification's words: its species,
    caption and notes. Only the new marks (best photo, bird box) are taken."""
    sightings = [dict(s) for s in conn.execute(
        "SELECT common_name, scientific_name, is_bird, count, confidence, details "
        "FROM sightings WHERE identification_id = ?", (earlier["id"],))]
    return {**answer, "sightings": sightings,
            "caption": earlier["caption"] or answer["caption"],
            "notes": earlier["notes"] or answer["notes"], "kept_from": earlier["id"]}


def save_frame(conn, visit, video, seconds: float, frame: Image.Image) -> str:
    """Keep a chosen video frame beside the visit's photos, as media of kind
    "frame", and return its id."""
    path = Path(video["path"]).parent / f"frame_{seconds:04.1f}s.jpg"
    frame.save(db.ARCHIVE / path, "JPEG", quality=92)
    media_id = f"{visit['id']}:frame:{seconds:.1f}"
    with conn:
        conn.execute("INSERT OR IGNORE INTO media (id, visit_id, kind, path, width, height) "
                     "VALUES (?, ?, 'frame', ?, ?, ?)",
                     (media_id, visit["id"], str(path), *frame.size))
    return media_id


def save(conn, visit_id: str, model: str, answer: dict, best_media: str) -> None:
    with conn:
        cur = conn.execute(
            "INSERT INTO identifications "
            "(visit_id, by, prompt_version, made_at, caption, best_media, notes, raw) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (visit_id, model, PROMPT_VERSION, db.now(), answer["caption"], best_media,
             answer["notes"], json.dumps(answer)))
        for s in map(db.species_of, answer["sightings"]):
            conn.execute(
                "INSERT INTO sightings (identification_id, common_name, "
                "scientific_name, is_bird, count, confidence, details) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (cur.lastrowid, s["common_name"], s["scientific_name"],
                 int(s["is_bird"]), s["count"], s["confidence"], s["details"]))


def identify(api: anthropic.Anthropic, conn, visit) -> None:
    photos = conn.execute(
        "SELECT * FROM media WHERE visit_id = ? AND kind = 'photo' "
        "ORDER BY taken_at, id LIMIT ?", (visit["id"], MAX_PHOTOS)).fetchall()

    video = conn.execute("SELECT * FROM media WHERE visit_id = ? AND kind = 'video' "
                         "ORDER BY id LIMIT 1", (visit["id"],)).fetchone()
    frames = video_frames(db.ARCHIVE / video["path"]) if video else []
    answer, response = claude.ask_json(
        api, purpose="identify", system=SYSTEM,
        content=visit_prompt(visit, photos, contact_sheet(frames) if frames else None),
        schema=SCHEMA)
    if answer is None:
        print(f"  {visit['id']}: declined ({response.stop_details})")
        return

    earlier = conn.execute("SELECT * FROM current_identifications WHERE visit_id = ?",
                           (visit["id"],)).fetchone()
    if earlier:
        answer = kept(conn, earlier, answer)
    best = photos[min(max(answer["best_photo"], 1), len(photos)) - 1]["id"]
    if 1 <= answer.get("best_frame", 0) <= len(frames):
        best = save_frame(conn, visit, video, *frames[answer["best_frame"] - 1])
    save(conn, visit["id"], response.model, answer, best)
    db.save_tray(conn, visit["id"], answer["tray"], response.model)

    seen = datetime.fromisoformat(visit["seen_at"]).astimezone()
    names = ", ".join(f"{s['common_name']} ×{s['count']} ({s['confidence']})"
                      for s in answer["sightings"]) or "nothing"
    print(f"  {seen:%b %-d %-I:%M %p}  {names}")
    pick = (f"frame {answer['best_frame']}" if answer.get("best_frame")
            else f"photo {answer['best_photo']}")
    print(f"      {answer['caption']}  (best: {pick}, score {answer.get('photo_score')}, tray {answer['tray']})")


def correct(conn, visit_id: str, told: str) -> str | None:
    """The owner's word on a visit's bird, from the app. Claude looks at the
    photos again, told what the bird is, and rewrites the visit's caption,
    notes and sightings around it. It's saved as the owner's identification,
    so it wins everywhere: the feed, the board, the story and the yard list.
    Returns the new caption, or None if Claude declined."""
    visit = conn.execute("SELECT * FROM visits WHERE id = ?", (visit_id,)).fetchone()
    if not visit:
        return None
    photos = conn.execute(
        "SELECT * FROM media WHERE visit_id = ? AND kind = 'photo' "
        "ORDER BY taken_at, id LIMIT ?", (visit_id, MAX_PHOTOS)).fetchall()
    content = visit_prompt(visit, photos) + [{"type": "text", "text":
        f"The feeder's owner says the main bird in this visit is a {told}. Take that as "
        "given: name it so, with its scientific name, and write the caption, notes and "
        "details around it. Keep anything else you see. Don't argue with it or mention "
        "the correction in the notes."}]
    answer, response = claude.ask_json(claude.client(), purpose="correct", system=SYSTEM,
                                       content=content, schema=SCHEMA)
    if answer is None:
        return None
    sightings = answer["sightings"]
    told_one = next((s for s in sightings if s["common_name"].lower() == told.lower()),
                    sightings[0] if sightings else None)
    if told_one:
        told_one["confidence"] = "high"  # the owner's word
    earlier = conn.execute("SELECT * FROM current_identifications WHERE visit_id = ?",
                           (visit_id,)).fetchone()
    best = (earlier["best_media"] if earlier and earlier["best_media"] else
            photos[min(max(answer["best_photo"], 1), len(photos)) - 1]["id"] if photos else None)
    answer |= {"correction": {"told": told}, "words_by": response.model}
    save(conn, visit_id, "owner", answer, best)
    db.save_tray(conn, visit_id, answer["tray"], response.model)
    return answer["caption"]


TRAY_SYSTEM = f"""You look at photos from a backyard bird feeder's camera in \
{LOCATION}, numbered, with the date and time. {TRAY}"""


def look_at_trays(conn, days: int = 7) -> int:
    """Read the tray (only the tray) in the last few days' visits Claude
    hasn't read it in: for visits identified before the tray was asked
    about. Their birds, captions and best photos are left as they are."""
    visits = conn.execute(
        "SELECT * FROM visits v WHERE v.seen_at >= datetime('now', ?) AND EXISTS "
        "(SELECT 1 FROM media m WHERE m.visit_id = v.id AND m.kind = 'photo') "
        "AND NOT EXISTS (SELECT 1 FROM trays t WHERE t.visit_id = v.id) ORDER BY v.seen_at",
        (f"-{days} days",)).fetchall()
    api = claude.client()
    schema = {"type": "object", "properties": {"tray": TRAY_FIELD}, "required": ["tray"],
              "additionalProperties": False}
    for visit in visits:
        photos = conn.execute("SELECT * FROM media WHERE visit_id = ? AND kind = 'photo' "
                              "ORDER BY taken_at, id LIMIT ?", (visit["id"], MAX_PHOTOS)).fetchall()
        answer, response = claude.ask_json(api, purpose="tray", system=TRAY_SYSTEM,
                                           content=visit_prompt(visit, photos), schema=schema, effort="low")
        if answer:
            db.save_tray(conn, visit["id"], answer["tray"], response.model)
            print(f"  {datetime.fromisoformat(visit['seen_at']).astimezone():%a %-I:%M %p}  {answer['tray']}")
    return len(visits)


def identify_pending(conn, visit_id: str | None = None, again: bool = False) -> int:
    """Identify every visit with photos and no identification, oldest first.
    Returns how many were tried."""
    query = ("SELECT * FROM visits v WHERE EXISTS "
             "(SELECT 1 FROM media m WHERE m.visit_id = v.id AND m.kind = 'photo')")
    params: list = []
    if not again:
        query += " AND NOT EXISTS (SELECT 1 FROM identifications i WHERE i.visit_id = v.id)"
    if visit_id:
        query += " AND v.id = ?"
        params.append(visit_id)
    visits = conn.execute(query + " ORDER BY v.seen_at", params).fetchall()
    if not visits:
        return 0

    print(f"{len(visits)} visit(s) to identify with {claude.MODEL}")
    api = claude.client()
    for visit in visits:
        try:
            identify(api, conn, visit)
        except anthropic.RateLimitError:
            print("Rate limited; the rest wait for the next run.")
            break
        except anthropic.APIStatusError as err:
            print(f"  {visit['id']}: API error {err.status_code}: {err.message}")
    return len(visits)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--visit", help="only this visit")
    parser.add_argument("--again", action="store_true",
                        help="look again for the best photo, bird box and score, keeping what was said")
    parser.add_argument("--trays", type=int, metavar="DAYS",
                        help="read only the seed tray in the last DAYS of visits that haven't had it read")
    args = parser.parse_args()
    if args.trays:
        print(f"Read {look_at_trays(db.connect(), args.trays)} tray(s).")
        return
    if not identify_pending(db.connect(), args.visit, args.again):
        print("Nothing to identify.")


if __name__ == "__main__":
    main()
