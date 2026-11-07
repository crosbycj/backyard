# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow>=10", "boto3>=1.34"]
# ///
"""Put the feeder's photos where the TRMNL and phones can reach them.

TRMNL draws the board in its own cloud, so a photo on the board needs a
public link. For every visit whose best photo isn't up yet, this crops the
photo square around the bird (Claude's box), shrinks it to plate size, turns
it to greys, and uploads it to the Cloudflare R2 bucket in config.R2_BUCKET
under an unguessable name. The original stays in the archive; only the small
plate version is public. Its link goes in `media.public_url`.

The week page in color (publish.build_site) goes to the same bucket, under
w/<an unguessable name>/, with its photos at phone size, so its QR code
opens on any phone, not only at home.

Keys come from the Keychain (service "r2-backyard", accounts
"access-key-id" and "secret-access-key").

Run:
    uv run collector/photos.py
"""

from __future__ import annotations

import io
import json
import secrets
import subprocess

import boto3
from PIL import Image, ImageFilter, ImageOps

import config
import db

ACCOUNT = config.R2_ACCOUNT
BUCKET = config.R2_BUCKET
PUBLIC = config.R2_PUBLIC
SIZE = 720     # px square: sharp on the X's biggest plate, small to fetch
MARGIN = 0.35  # room around the bird, as a share of the box
GAMMA = 0.8    # under 1 lifts the midtones; the X shows photos darker than a screen


def keychain(account: str) -> str:
    return subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", "r2-backyard",
         "-a", account, "-w"], capture_output=True, text=True, check=True).stdout.strip()


def bucket():
    return boto3.client(
        "s3", endpoint_url=f"https://{ACCOUNT}.r2.cloudflarestorage.com",
        aws_access_key_id=keychain("access-key-id"),
        aws_secret_access_key=keychain("secret-access-key"), region_name="auto")


def plate(path, box: dict | None) -> bytes:
    """A square, grey, plate-sized JPEG of the bird."""
    image = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    w, h = image.size
    if box:
        cx, cy = (box["left"] + box["right"]) / 2 * w, (box["top"] + box["bottom"]) / 2 * h
        side = max((box["right"] - box["left"]) * w, (box["bottom"] - box["top"]) * h)
        side = min(side * (1 + 2 * MARGIN), w, h)
    else:
        cx, cy, side = w / 2, h / 2, min(w, h)
    left = min(max(cx - side / 2, 0), w - side)
    top = min(max(cy - side / 2, 0), h - side)
    square = image.crop((round(left), round(top), round(left + side), round(top + side)))
    # For e-ink, which prints darker and flatter than a screen: stretch the
    # greys, lift the midtones, and sharpen the feathers a little.
    grey = ImageOps.autocontrast(square.resize((SIZE, SIZE), Image.LANCZOS).convert("L"),
                                 cutoff=2)
    grey = grey.point(lambda x: round(255 * (x / 255) ** GAMMA))
    grey = grey.filter(ImageFilter.UnsharpMask(radius=2, percent=60, threshold=3))
    out = io.BytesIO()
    grey.save(out, "JPEG", quality=85, optimize=True, progressive=True)
    return out.getvalue()


def publish_photos(conn) -> int:
    """Upload a plate for every identified visit whose best photo has none."""
    todo = conn.execute(
        "SELECT m.id, m.path, ci.raw FROM current_identifications ci "
        "JOIN media m ON m.id = ci.best_media "
        "WHERE m.public_url IS NULL AND m.kind IN ('photo', 'frame')").fetchall()
    if not todo:
        return 0
    s3 = bucket()
    for row in todo:
        raw = json.loads(row["raw"]) if row["raw"] else {}
        data = plate(db.ARCHIVE / row["path"], raw.get("bird_box"))
        key = f"plates/{secrets.token_urlsafe(12)}.jpg"
        s3.put_object(Bucket=BUCKET, Key=key, Body=data, ContentType="image/jpeg",
                      CacheControl="public, max-age=31536000, immutable")
        with conn:
            conn.execute("UPDATE media SET public_url = ? WHERE id = ?",
                         (f"{PUBLIC}/{key}", row["id"]))
    return len(todo)


SITE_TOKEN = db.ARCHIVE / "site-token"
WEB = 1200  # px on the long edge: sharp on a phone, light to load


def site_base() -> str:
    """The week page's public folder in the bucket. Its name is unguessable,
    made once and kept, so the board's QR codes never change."""
    if not SITE_TOKEN.exists():
        SITE_TOKEN.write_text(secrets.token_urlsafe(8))
    return f"{PUBLIC}/w/{SITE_TOKEN.read_text().strip()}/"


def web(path) -> bytes:
    """A color photo at phone size."""
    image = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    image.thumbnail((WEB, WEB), Image.LANCZOS)
    out = io.BytesIO()
    image.save(out, "JPEG", quality=82, optimize=True, progressive=True)
    return out.getvalue()


def publish_site(site) -> int:
    """Upload the week page (archive/site) to its public folder: the page
    every time, each photo and song link once. Returns how many files went."""
    prefix = site_base().removeprefix(f"{PUBLIC}/")
    s3 = bucket()
    have = {o["Key"] for page in s3.get_paginator("list_objects_v2").paginate(
        Bucket=BUCKET, Prefix=prefix) for o in page.get("Contents", [])}
    sent = 0
    for path in sorted(p for p in site.rglob("*") if p.is_file()):
        key = prefix + path.relative_to(site).as_posix()
        if path.name != "index.html" and key in have:
            continue
        page = path.suffix == ".html"
        s3.put_object(Bucket=BUCKET, Key=key, Body=path.read_bytes() if page else web(path),
                      ContentType="text/html; charset=utf-8" if page else "image/jpeg",
                      CacheControl="no-cache" if path.name == "index.html"
                      else "public, max-age=86400")
        sent += 1
    return sent


if __name__ == "__main__":
    print(f"{publish_photos(db.connect())} plate photo(s) uploaded")
