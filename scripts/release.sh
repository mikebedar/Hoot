#!/bin/zsh
# Maintainer script: builds a Developer ID–signed, notarized Hoot.app and zips it for a GitHub
# release and the Homebrew cask. The version comes from extension/manifest.json.
#
#   scripts/release.sh     →  dist/Hoot-<version>.zip  (+ .sha256)
#
# Needs a "Developer ID Application" certificate for your team and a notarytool keychain profile,
# created once with:
#   xcrun notarytool store-credentials <profile> --apple-id <you> --team-id <team> --password <app-specific password>
#
# Set HOOT_TEAM and HOOT_NOTARY_PROFILE in the environment, or put them in scripts/release.local.sh
# (git-ignored), e.g.:
#   HOOT_TEAM=ABCDE12345
#   HOOT_NOTARY_PROFILE=my-notary-profile
set -euo pipefail
cd "${0:A:h}/.."

[[ -f scripts/release.local.sh ]] && source scripts/release.local.sh
TEAM="${HOOT_TEAM:?Set HOOT_TEAM (your Apple developer team ID); see the top of this script}"
PROFILE="${HOOT_NOTARY_PROFILE:?Set HOOT_NOTARY_PROFILE (your notarytool keychain profile); see the top of this script}"
VERSION=$(plutil -extract version raw -o - extension/manifest.json)
BUILD_NUMBER=$(git rev-list --count HEAD)
WORK="dist/work-$VERSION"
ZIP="dist/Hoot-$VERSION.zip"

step() { print -P "\n%B==> $1%b"; }
fail() { print -P "%F{red}$1%f" >&2; exit 1; }

# ---------- Preflight ----------
[[ -z "$(git status --porcelain)" ]] || fail "Commit or stash your changes first; releases are built from a clean tree."
# (Capture output before matching: `cmd | grep -q` can fail spuriously under pipefail.)
[[ "$(security find-identity -v -p codesigning)" == *"Developer ID Application:"*"($TEAM)"* ]] \
  || fail "No valid \"Developer ID Application\" certificate for team $TEAM in your keychain."
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || fail "notarytool keychain profile \"$PROFILE\" is missing or can't sign in (see the comment at the top)."

rm -rf "$WORK"
mkdir -p "$WORK"

# ---------- Archive ----------
step "Archiving Hoot $VERSION (build $BUILD_NUMBER)"
xcodebuild -project Hoot/Hoot.xcodeproj -scheme Hoot -configuration Release \
  -destination "generic/platform=macOS" -archivePath "$WORK/Hoot.xcarchive" -derivedDataPath "$WORK/DerivedData" \
  DEVELOPMENT_TEAM="$TEAM" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates -quiet archive

# ---------- Export (Developer ID) ----------
step "Exporting with Developer ID signing"
cat > "$WORK/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$WORK/Hoot.xcarchive" -exportPath "$WORK/export" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" -allowProvisioningUpdates -quiet
APP="$WORK/export/Hoot.app"
codesign --verify --deep --strict "$APP" || fail "Exported app failed signature verification."
[[ "$(codesign -dv --verbose=2 "$APP" 2>&1)" == *"Authority=Developer ID Application"* ]] \
  || fail "Exported app isn't signed with Developer ID."

# ---------- Notarize ----------
step "Notarizing with Apple (usually a few minutes)"
ditto -c -k --keepParent "$APP" "$WORK/Hoot-notarize.zip"
xcrun notarytool submit "$WORK/Hoot-notarize.zip" --keychain-profile "$PROFILE" --wait | tee "$WORK/notarize.log"
if ! grep -q "status: Accepted" "$WORK/notarize.log"; then
  id=$(awk '/^  id:/ {print $2; exit}' "$WORK/notarize.log")
  [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" | tee "$WORK/notarize-detail.json"
  fail "Notarization was not accepted; details above and in $WORK/."
fi

# ---------- Staple & package ----------
step "Stapling and packaging"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
print "$SHA  ${ZIP:t}" > "$ZIP.sha256"

# Building registers these copies with macOS (sometimes a moment later); unregister them so Safari
# doesn't pick up a stray Hoot alongside the one you actually use.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
sleep 3
for app in "$WORK"/**/*.app(N/); do "$LSREGISTER" -u "$app" 2>/dev/null || true; done
for appex in "$WORK"/**/*.appex(N/); do pluginkit -r "$appex" 2>/dev/null || true; done

step "Done"
print "  $ZIP"
print "  sha256 $SHA"
