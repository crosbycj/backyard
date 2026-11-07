# Backyard

A Bird Buddy feeder takes a photo of every bird that lands on it, but its app is pretty bad at saying what the bird is. Backyard reads each visit through Bird Buddy's unofficial API, has Claude identify the birds and write about them, and shows the yard on a [TRMNL](https://usetrmnl.com) e-ink display and in an iPhone app.

More, with pictures: [cooper.computer/backyard](https://cooper.computer/backyard/)

This is the source as a starting point, not a product. It's shared as is, with no support, and it isn't affiliated with Bird Buddy or TRMNL. Bird Buddy's API is unofficial (through [pybirdbuddy](https://github.com/jhansche/pybirdbuddy)) and could break at any time.

## The pieces

- **`collector/`** (Python, run with [uv](https://docs.astral.sh/uv/)): every ten minutes it reads new visits from Bird Buddy, keeps every photo and video in `archive/`, has Claude identify each visit from the photos, writes the day's note and the week's story, and publishes the board's data and the app's feed. `collect.py` is the entry point; `bird-log.collect.plist` runs it under launchd.
- **`wall/`**: the TRMNL board, a private plugin fed by webhook. Preview and push it with [trmnlp](https://github.com/usetrmnl/trmnlp).
- **`app/`** (Swift, iOS 18 and later): the iPhone app, its widget and its notification extension. The Xcode project is generated from `app/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Setting it up

1. Fill in `collector/config.py`: your town, your feeder's name, your town's latitude and longitude, your Cloudflare R2 bucket, and your Apple team and bundle id for notifications. Each can also come from an environment variable.
2. Put the keys in the macOS Keychain. Each script's docstring has the exact command: `birdbuddy` (your Bird Buddy login), `anthropic` (an API key), `r2-backyard` (R2 access keys), `trmnl-webhook` and `trmnl-api` (TRMNL), and `apns-backyard` (an Apple push key).
3. Run `uv run collector/collect.py` once by hand, then install the launchd plist (set its paths first).
4. For the app, set `YardFeedURL` and `DEVELOPMENT_TEAM` in `app/project.yml`, then `cd app && xcodegen`.

Claude calls cost money; `collector/costs.py` reports what they've cost so far.

## License

MIT. See `LICENSE`.
