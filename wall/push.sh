#!/bin/sh
# Send the board's layout (wall/src) to the Backyard Birds plugin on TRMNL,
# so a layout change shows up without pasting into TRMNL's editor. Data
# still goes by webhook (collector/publish.py); this is only the markup and
# the plugin's settings.
#
#   wall/push.sh         upload src/ (overwrites the plugin)
#   wall/push.sh pull    download the plugin into src/
#
# The TRMNL API key comes from the Keychain (service "trmnl-api", account
# your macOS user name) and goes to trmnlp as an environment variable; it's never printed.
# --tmpfs /tmp: the trmnlp image ships a stale X lock that hangs it otherwise.
set -e
cd "$(dirname "$0")"
TRMNL_API_KEY=$(/usr/bin/security find-generic-password -s trmnl-api -a "$USER" -w)
export TRMNL_API_KEY
exec docker run --rm --tmpfs /tmp:exec,mode=1777 -e TRMNL_API_KEY --volume "$PWD:/plugin" trmnl/trmnlp "${1:-push}" --id "${TRMNL_PLUGIN_ID:?set TRMNL_PLUGIN_ID to your plugin id}" --force
