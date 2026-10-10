#!/bin/zsh
# Maintainer script: builds a Developer ID–signed, notarized Hoot.app, and optionally publishes it
# as a GitHub release and updates the Homebrew cask. The version comes from extension/manifest.json.
#
#   scripts/release.sh                   build → dist/Hoot-<version>.zip
#   scripts/release.sh --publish         build, then publish (GitHub release + cask)
#   scripts/release.sh --publish-only    publish an already-built dist/Hoot-<version>.zip
#   add --dry-run to --publish/--publish-only to print the publish steps without running them
#
# Building needs a "Developer ID Application" certificate for your team and a notarytool keychain
# profile, created once with:
#   xcrun notarytool store-credentials <profile> --apple-id <you> --team-id <team> --password <app-specific password>
#
# Settings come from the environment or scripts/release.local.sh (git-ignored), e.g.:
#   HOOT_TEAM=ABCDE12345                  # Apple developer team ID (build)
#   HOOT_NOTARY_PROFILE=my-notary-profile # notarytool keychain profile (build)
#   HOOT_TAP=yourname/tap                 # Homebrew tap holding Casks/hoot.rb (publish)
#   HOOT_GH_USER=yourname                 # gh account to publish as, if you have several (publish)
#   HOOT_NOTES_FILE=notes.md              # release notes (publish; default: GitHub-generated)
set -euo pipefail
cd "${0:A:h}/.."

BUILD=1 PUBLISH=0 DRY=0
for arg in "$@"; do
  case $arg in
    --publish) PUBLISH=1 ;;
    --publish-only) PUBLISH=1 BUILD=0 ;;
    --dry-run) DRY=1 ;;
    *) print -u2 "Unknown option: $arg"; exit 2 ;;
  esac
done

[[ -f scripts/release.local.sh ]] && source scripts/release.local.sh
VERSION=$(plutil -extract version raw -o - extension/manifest.json)
WORK="dist/work-$VERSION"
ZIP="dist/Hoot-$VERSION.zip"

step() { print -P "\n%B==> $1%b"; }
fail() { print -P "%F{red}$1%f" >&2; exit 1; }
# Publish commands go through `run` so --dry-run can show them instead.
run() { if (( DRY )); then print "  would run: ${(q-)@}"; else "$@"; fi; }

build() {
  local team="${HOOT_TEAM:?Set HOOT_TEAM (your Apple developer team ID); see the top of this script}"
  local profile="${HOOT_NOTARY_PROFILE:?Set HOOT_NOTARY_PROFILE (your notarytool keychain profile); see the top of this script}"
  local build_number=$(git rev-list --count HEAD)

  # ---------- Preflight ----------
  [[ -z "$(git status --porcelain)" ]] || fail "Commit or stash your changes first; releases are built from a clean tree."
  # (Capture output before matching: `cmd | grep -q` can fail spuriously under pipefail.)
  [[ "$(security find-identity -v -p codesigning)" == *"Developer ID Application:"*"($team)"* ]] \
    || fail "No valid \"Developer ID Application\" certificate for team $team in your keychain."
  xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
    || fail "notarytool keychain profile \"$profile\" is missing or can't sign in (see the comment at the top)."

  rm -rf "$WORK"
  mkdir -p "$WORK"

  # ---------- Archive ----------
  step "Archiving Hoot $VERSION (build $build_number)"
  xcodebuild -project Hoot/Hoot.xcodeproj -scheme Hoot -configuration Release \
    -destination "generic/platform=macOS" -archivePath "$WORK/Hoot.xcarchive" -derivedDataPath "$WORK/DerivedData" \
    DEVELOPMENT_TEAM="$team" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$build_number" \
    -allowProvisioningUpdates -quiet archive

  # ---------- Export (Developer ID) ----------
  step "Exporting with Developer ID signing"
  cat > "$WORK/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
EOF
  xcodebuild -exportArchive -archivePath "$WORK/Hoot.xcarchive" -exportPath "$WORK/export" \
    -exportOptionsPlist "$WORK/ExportOptions.plist" -allowProvisioningUpdates -quiet
  local app="$WORK/export/Hoot.app"
  codesign --verify --deep --strict "$app" || fail "Exported app failed signature verification."
  [[ "$(codesign -dv --verbose=2 "$app" 2>&1)" == *"Authority=Developer ID Application"* ]] \
    || fail "Exported app isn't signed with Developer ID."

  # ---------- Notarize ----------
  step "Notarizing with Apple (usually a few minutes)"
  ditto -c -k --keepParent "$app" "$WORK/Hoot-notarize.zip"
  xcrun notarytool submit "$WORK/Hoot-notarize.zip" --keychain-profile "$profile" --wait | tee "$WORK/notarize.log"
  if ! grep -q "status: Accepted" "$WORK/notarize.log"; then
    local id=$(awk '/^  id:/ {print $2; exit}' "$WORK/notarize.log")
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$profile" | tee "$WORK/notarize-detail.json"
    fail "Notarization was not accepted; details above and in $WORK/."
  fi

  # ---------- Staple & package ----------
  step "Stapling and packaging"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute -vv "$app"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$app" "$ZIP"
  print "$(shasum -a 256 "$ZIP" | awk '{print $1}')  ${ZIP:t}" > "$ZIP.sha256"
  git rev-parse HEAD > "$ZIP.commit"  # publish checks it tags the commit the zip was built from

  # Building registers these copies with macOS (sometimes a moment later); unregister them so Safari
  # doesn't pick up a stray Hoot alongside the one you actually use.
  local lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  sleep 3
  for a in "$WORK"/**/*.app(N/); do "$lsregister" -u "$a" 2>/dev/null || true; done
  for a in "$WORK"/**/*.appex(N/); do pluginkit -r "$a" 2>/dev/null || true; done

  step "Built $ZIP"
  print "  sha256 $(cut -d' ' -f1 "$ZIP.sha256")"
}

publish() {
  local tap="${HOOT_TAP:?Set HOOT_TAP (your Homebrew tap, e.g. yourname/tap); see the top of this script}"
  [[ -n "${HOOT_GH_USER:-}" ]] && export GH_TOKEN=$(gh auth token --user "$HOOT_GH_USER")
  local tag="v$VERSION"
  local sha=$(cut -d' ' -f1 "$ZIP.sha256" 2>/dev/null || true)
  local tap_dir=$(brew --repository "$tap")
  local cask="$tap_dir/Casks/hoot.rb"
  local repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  (( DRY )) && step "Dry run: nothing below is changed"

  # ---------- Preflight ----------
  step "Checking $repo and $tap before publishing $tag"
  [[ -f "$ZIP" && -n "$sha" ]] || fail "No built $ZIP; run without --publish-only first."
  [[ "$(shasum -a 256 "$ZIP" | awk '{print $1}')" == "$sha" ]] || fail "$ZIP doesn't match $ZIP.sha256; rebuild it."
  [[ "$(cat "$ZIP.commit" 2>/dev/null)" == "$(git rev-parse HEAD)" ]] \
    || fail "$ZIP was built from a different commit than HEAD; rebuild it from the commit you're releasing."
  [[ -z "$(git status --porcelain)" ]] || fail "Commit or stash your changes first."
  git fetch -q origin
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse '@{u}')" ]] || fail "Push your commits first; HEAD isn't on $(git rev-parse --abbrev-ref '@{u}')."
  if [[ -n "$(git ls-remote --tags origin "refs/tags/$tag")" ]]; then
    (( DRY )) && print "  (a real run would stop here: $tag already exists on GitHub; bump the version first)" \
               || fail "$tag already exists on GitHub; bump the version in extension/manifest.json first."
  fi
  [[ -f "$cask" ]] || fail "No cask at $cask."
  [[ -z "$(git -C "$tap_dir" status --porcelain)" ]] || fail "The tap at $tap_dir has uncommitted changes."
  run git -C "$tap_dir" pull -q --ff-only

  # ---------- GitHub release ----------
  local title="Hoot $VERSION" prerelease=()
  [[ $VERSION == 0.* ]] && { title+=" (beta)"; prerelease=(--prerelease); }
  local notes=(--generate-notes)
  [[ -n "${HOOT_NOTES_FILE:-}" ]] && notes=(--notes-file "$HOOT_NOTES_FILE")
  step "Creating the $tag GitHub release"
  run git tag "$tag"
  run git push -q origin "$tag"
  run gh release create "$tag" "$ZIP" --repo "$repo" --verify-tag --title "$title" $prerelease $notes

  # ---------- Homebrew cask ----------
  step "Updating the cask in $tap"
  local updated=$(sed -E "s/^(  version )\"[^\"]*\"/\1\"$VERSION\"/; s/^(  sha256 )\"[^\"]*\"/\1\"$sha\"/" "$cask")
  if (( DRY )); then
    diff -u "$cask" <(print -r -- "$updated") | sed 's/^/  /' || true
  else
    print -r -- "$updated" > "$cask"
  fi
  run brew style --cask "$tap/hoot"
  run git -C "$tap_dir" commit -q -am "Hoot $VERSION"
  run git -C "$tap_dir" push -q

  # ---------- Verify ----------
  step "Checking Homebrew can download and verify the release"
  run env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_AUTOREMOVE=1 brew fetch --cask --force "$tap/hoot"

  step "Published Hoot $VERSION"
  print "  https://github.com/$repo/releases/tag/$tag"
  print "  brew upgrade --cask hoot"
}

(( BUILD )) && build
(( PUBLISH )) && publish
true
