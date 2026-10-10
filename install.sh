#!/bin/zsh
# Builds Hoot and installs it into ~/Applications.
#
# Needs Xcode, with your Apple ID added under Xcode → Settings → Accounts (a free Apple ID is
# enough). Override anything below with environment variables, e.g.
#   DEVELOPMENT_TEAM=ABCDE12345 BUNDLE_ID_PREFIX=com.yourname ./install.sh
set -euo pipefail
cd "${0:A:h}"

say()  { print -P "%B$1%b"; }
fail() { print -P "%F{red}$1%f" >&2; exit 1; }

if ! xcodebuild -version >/dev/null 2>&1; then
  fail "Hoot is built with Xcode. Install Xcode from the Mac App Store, open it once, then run ./install.sh again."
fi

# ---------- Signing team ----------
# Xcode creates an "Apple Development" certificate for each team you're signed in to. Look only
# at valid ones, and read the team ID (OU) and team name (O) from each.
pick_team() {
  local -A names
  local hashes hash pem subject ou org
  hashes=(${(f)"$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2}')"})
  for hash in $hashes; do
    pem=$(security find-certificate -a -Z -p 2>/dev/null | awk -v h="$hash" '
      /^SHA-1 hash:/ { keep = ($3 == h) } keep && /BEGIN CERT/ { p = 1 } p && keep { print } /END CERT/ { if (p && keep) exit; p = 0 }')
    subject=$(print -r -- "$pem" | openssl x509 -noout -subject -nameopt multiline 2>/dev/null) || continue
    ou=$(print -r -- "$subject" | awk -F' = ' '/organizationalUnitName/ {print $2}')
    org=$(print -r -- "$subject" | awk -F' = ' '/organizationName/ {print $2}')
    [[ -n "$ou" ]] && names[$ou]="$org"
  done

  local teams=(${(k)names})
  if (( ${#teams} == 0 )); then
    return 1
  elif (( ${#teams} == 1 )); then
    REPLY=$teams[1]
  else
    say "You're signed in to more than one Apple developer team. Which one should sign Hoot?"
    local i=1 t
    for t in $teams; do print "  $i) ${names[$t]} ($t)"; (( i++ )); done
    read "choice?Team number: "
    [[ "$choice" == <-> ]] && (( choice >= 1 && choice <= ${#teams} )) || fail "Please enter a number from 1 to ${#teams}."
    REPLY=$teams[$choice]
  fi
}

TEAM="${DEVELOPMENT_TEAM:-}"
if [[ -z "$TEAM" ]] && pick_team; then TEAM=$REPLY; fi

if [[ -n "$TEAM" ]]; then
  # Bundle IDs must be unique per developer team, so derive one from the team unless given.
  PREFIX="${BUNDLE_ID_PREFIX:-local.hoot.${(L)TEAM}}"
  say "Building Hoot (team $TEAM, bundle ID $PREFIX.Hoot)…"
  SIGNING=(DEVELOPMENT_TEAM="$TEAM" BUNDLE_ID_PREFIX="$PREFIX" -allowProvisioningUpdates)
else
  say "No Apple developer team found, so Hoot will be built unsigned."
  print "  To avoid that, add your Apple ID in Xcode → Settings → Accounts and run this again."
  SIGNING=(CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="")
fi

[[ -n "${HOOT_DRY_RUN:-}" ]] && { print "Dry run: ${SIGNING[*]}"; exit 0; }

xcodebuild -project Hoot/Hoot.xcodeproj -scheme Hoot -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath build -quiet "${SIGNING[@]}" build

# ---------- Install ----------
DEST="${HOOT_INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$DEST"
osascript -e 'tell application "Hoot" to quit' >/dev/null 2>&1 || true
rm -rf "$DEST/Hoot.app"
ditto build/Build/Products/Release/Hoot.app "$DEST/Hoot.app"
[[ -z "${HOOT_NO_OPEN:-}" ]] && open "$DEST/Hoot.app"

say "Hoot is installed in $DEST."
print "Next: in Safari, open Settings → Extensions, turn on Hoot, and allow it on youtube.com."
if [[ -z "$TEAM" ]]; then
  print "Because this build is unsigned, also turn on Safari → Develop → Allow Unsigned Extensions"
  print "(Safari turns that setting off each time it quits)."
fi
