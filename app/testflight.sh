#!/bin/zsh
# Archive the app and upload it to App Store Connect for TestFlight.
#   cd app && ./testflight.sh
# Each upload's build number is the time (202610281830), so it always goes
# up. Signs with the team's distribution certificate through Xcode's
# signed-in account (-allowProvisioningUpdates); the upload goes to
# App Store Connect, where TestFlight picks it up after processing.
set -e
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")"
build=$(date +%Y%m%d%H%M)
xcodegen -q
xcodebuild -project Backyard.xcodeproj -scheme Backyard -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Backyard.xcarchive \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION=$build archive | grep -E "error:|ARCHIVE" || true
[ -d build/Backyard.xcarchive ] || { echo "No archive."; exit 1; }
cat > build/export.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>YOUR_TEAM_ID</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath build/Backyard.xcarchive -exportOptionsPlist build/export.plist \
  -exportPath build/export -allowProvisioningUpdates
echo "Uploaded build $build."
