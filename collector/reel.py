"""The day in under a minute: each visit's best few seconds, one after
another, as one short video for the app ("Today in 40 seconds").

A visit's moment is around Claude's best photo: its photos were taken
during its video, so the photo's time says where in the video to look (a
still Claude picked from the video says its second in its id). Each clip
runs from 1.5 s before that moment to 2 s after, with the time and the bird
written in the corner, and fades in and out. Made with ffmpeg from the
videos the archive already keeps, so the phone only plays a file.

Built by feed.publish when a day's clips change, kept in archive/reels/.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path

import db

VERSION = 1           # bump to rebuild every reel
BEFORE, AFTER = 1.5, 2.0
FADE = 0.25
SIZE = (720, 960)     # 3:4, like the camera
FONT = "/System/Library/Fonts/Supplemental/Georgia.ttf"
FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"
FOLDER = db.ARCHIVE / "reels"


def probe(path: Path) -> tuple[float, bool]:
    """A video's length in seconds, and whether it has sound."""
    out = subprocess.run([FFPROBE, "-v", "error", "-show_entries", "format=duration:stream=codec_type",
                          "-of", "json", str(path)], capture_output=True, text=True, check=True)
    info = json.loads(out.stdout)
    return float(info["format"]["duration"]), any(s["codec_type"] == "audio" for s in info["streams"])


def clips(conn, day: str) -> list[dict]:
    """The day's visits with a video, oldest first, each with the second of
    its best moment and a label ("8:30 AM · House Finch")."""
    out = []
    rows = conn.execute(
        "SELECT v.id, v.seen_at, ci.best_media, "
        "  (SELECT s.common_name FROM sightings s WHERE s.identification_id = ci.id "
        "   ORDER BY s.rowid LIMIT 1) AS bird "
        "FROM visits v JOIN current_identifications ci ON ci.visit_id = v.id "
        "WHERE v.source = 'birdbuddy' ORDER BY v.seen_at").fetchall()
    for r in rows:
        seen = datetime.fromisoformat(r["seen_at"]).astimezone()
        if seen.strftime("%Y-%m-%d") != day:
            continue
        video = conn.execute("SELECT * FROM media WHERE visit_id = ? AND kind = 'video' LIMIT 1",
                             (r["id"],)).fetchone()
        if not video or not (db.ARCHIVE / video["path"]).exists():
            continue
        best = r["best_media"] or ""
        if ":frame:" in best:
            moment = float(best.rsplit(":", 1)[1])
        else:
            photo = conn.execute("SELECT taken_at FROM media WHERE id = ?", (best,)).fetchone()
            if not (photo and photo["taken_at"] and video["taken_at"]):
                continue
            moment = (datetime.fromisoformat(photo["taken_at"])
                      - datetime.fromisoformat(video["taken_at"])).total_seconds()
        when = datetime.fromisoformat(video["taken_at"]).astimezone() if video["taken_at"] else seen
        out.append({"visit": r["id"], "path": db.ARCHIVE / video["path"], "moment": moment,
                    "label": f"{when:%-I:%M %p} · {r['bird'] or 'A visitor'}"})
    return out


def key(day_clips: list[dict]) -> str:
    """What a reel is made of; a new visit or a new best photo changes it."""
    body = json.dumps([VERSION] + [(c["visit"], round(c["moment"], 1), c["label"]) for c in day_clips])
    return hashlib.sha256(body.encode()).hexdigest()[:12]


def make(day: str, day_clips: list[dict]) -> tuple[Path, float]:
    """Build the reel (or reuse it if nothing changed). Returns its file and length."""
    FOLDER.mkdir(exist_ok=True)
    k = key(day_clips)
    out = FOLDER / f"{day}-{k}.mp4"
    length = len(day_clips) * (BEFORE + AFTER)
    if out.exists():
        return out, length
    w, h = SIZE
    args, filters, parts = [FFMPEG, "-v", "error", "-y"], [], []
    with tempfile.TemporaryDirectory() as tmp:
        for i, c in enumerate(day_clips):
            duration, sound = probe(c["path"])
            start = min(max(c["moment"] - BEFORE, 0), max(duration - BEFORE - AFTER, 0))
            span = BEFORE + AFTER
            args += ["-ss", f"{start:.2f}", "-t", f"{span:.2f}", "-i", str(c["path"])]
            label = Path(tmp) / f"{i}.txt"
            label.write_text(c["label"])
            filters.append(
                f"[{len(parts)}:v]scale={w}:{h}:force_original_aspect_ratio=increase,crop={w}:{h},"
                f"fps=30,setsar=1,drawtext=fontfile='{FONT}':textfile='{label}':x=36:y=h-84:"
                f"fontsize=34:fontcolor=white:shadowcolor=black@0.6:shadowx=0:shadowy=2,"
                f"fade=t=in:st=0:d={FADE},fade=t=out:st={span - FADE:.2f}:d={FADE}[v{i}]")
            video_input = len(parts)
            parts.append(i)
            if sound:
                filters.append(f"[{video_input}:a]aresample=44100,aformat=channel_layouts=stereo,"
                               f"afade=t=in:st=0:d={FADE},afade=t=out:st={span - FADE:.2f}:d={FADE}[a{i}]")
            else:
                args += ["-f", "lavfi", "-t", f"{span:.2f}", "-i", "anullsrc=r=44100:cl=stereo"]
                filters.append(f"[{len(parts)}:a]anull[a{i}]")
                parts.append(None)
        joined = "".join(f"[v{i}][a{i}]" for i in range(len(day_clips)))
        filters.append(f"{joined}concat=n={len(day_clips)}:v=1:a=1[v][a]")
        args += ["-filter_complex", ";".join(filters), "-map", "[v]", "-map", "[a]",
                 "-c:v", "libx264", "-preset", "veryfast", "-crf", "26", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", str(out)]
        subprocess.run(args, check=True)
    for old in FOLDER.glob(f"{day}-*.mp4"):
        if old != out:
            old.unlink()
    return out, length
