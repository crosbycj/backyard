# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Add photos from disk to the log as one visit.

For photos that didn't come through the collector: ones saved from the
Bird Buddy app, or test pictures. The photos are copied into the archive.

Run:
    uv run collector/import_photos.py PHOTO [PHOTO ...] \
        [--at 2026-10-02T16:54:00-07:00] [--feeder "Backyard feeder"]
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
from datetime import datetime, timezone
from pathlib import Path

import db


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("photos", nargs="+", type=Path)
    parser.add_argument("--at", help="when the visit happened (ISO 8601); "
                        "defaults to the first photo's file time")
    parser.add_argument("--feeder")
    args = parser.parse_args()

    hashes = [hashlib.sha256(p.read_bytes()).hexdigest() for p in args.photos]
    visit_id = "import:" + hashlib.sha256("".join(hashes).encode()).hexdigest()[:16]
    seen_at = (datetime.fromisoformat(args.at) if args.at
               else datetime.fromtimestamp(args.photos[0].stat().st_mtime))
    seen_at = seen_at.astimezone(timezone.utc).isoformat(timespec="seconds")

    folder = db.ARCHIVE / "imports" / visit_id.removeprefix("import:")
    folder.mkdir(parents=True, exist_ok=True)

    conn = db.connect()
    with conn:
        conn.execute(
            "INSERT OR IGNORE INTO visits (id, source, feeder, seen_at) "
            "VALUES (?, 'import', ?, ?)", (visit_id, args.feeder, seen_at))
        for photo, digest in zip(args.photos, hashes):
            dest = folder / f"{digest[:12]}{photo.suffix.lower()}"
            shutil.copyfile(photo, dest)
            conn.execute(
                "INSERT OR IGNORE INTO media (id, visit_id, kind, taken_at, path) "
                "VALUES (?, ?, 'photo', ?, ?)",
                (digest, visit_id, seen_at, str(dest.relative_to(db.ARCHIVE))))
    print(f"{visit_id}  {seen_at}  {len(args.photos)} photo(s)")


if __name__ == "__main__":
    main()
