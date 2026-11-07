"""Your feeder. Everything particular to one yard lives here; fill it in.

Each value can also come from the environment (BACKYARD_PLACE and so on),
which is handy under launchd. Secrets never go here: the Anthropic, Bird
Buddy, R2, TRMNL and Apple push keys are read from the macOS Keychain by
the scripts that use them (see each one's docstring).
"""

from __future__ import annotations

import os


def _get(name: str, default: str) -> str:
    return os.environ.get(f"BACKYARD_{name}", default)


# Where the feeder is, in words, for Claude's prompts ("Springfield, Illinois").
PLACE = _get("PLACE", "your town")
# What the board calls the feeder.
FEEDER = _get("FEEDER", "Backyard feeder")
# Your town's latitude and longitude, for the weather and the sun until the
# feeder reports its own position.
HOME = (float(_get("LAT", "0")), float(_get("LON", "0")))
# Your time zone (an IANA name).
TZ = _get("TZ", "UTC")

# Cloudflare R2, where photos and the app's feed are published.
R2_ACCOUNT = _get("R2_ACCOUNT", "")          # your Cloudflare account id
R2_BUCKET = _get("R2_BUCKET", "backyard")
R2_PUBLIC = _get("R2_PUBLIC", "")            # the bucket's public URL

# Apple push notifications for the iPhone app.
APNS_TEAM = _get("APNS_TEAM", "")            # your Apple developer team id
APNS_TOPIC = _get("APNS_TOPIC", "com.example.backyard")  # the app's bundle id
