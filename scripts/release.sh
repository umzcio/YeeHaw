#!/bin/bash
# Usage: scripts/release.sh
# Builds a notarized, stapled YeeHaw release in release/: YeeHaw.app and YeeHaw.zip.
#
# Signing: only Developer ID Application certificates from team V2P99VF75Q sign releases; any
# other certificate is refused. YEEHAW_SIGNING_IDENTITY may name one (a SHA-1 hash or the team
# ID); by default the team's only Developer ID Application certificate is used.
# Notarization: NOTARY_PROFILE names an `xcrun notarytool store-credentials` keychain profile
# ("notary" by default). Credentials stay in the Keychain; none are read or written here.
set -euo pipefail

TEAM_ID="V2P99VF75Q"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"

die() {
    echo "release: $*" >&2
    exit 1
}
step() { echo "==> $*"; }

cd "$(dirname "$0")/.."

for tool in swift codesign xcrun ditto security spctl plutil; do
    command -v "$tool" >/dev/null || die "$tool is missing"
done

# ---- Signing identity --------------------------------------------------------------------------

# Developer ID Application certificates whose name ends in "(TEAM_ID)". Only the SHA-1 hash is
# kept, so no certificate name is ever printed or stored.
team_hashes="$(security find-identity -v -p codesigning |
    awk -v team="($TEAM_ID)\"" '/"Developer ID Application: / && index($0, team) { print $2 }')"
if [[ -n "${YEEHAW_SIGNING_IDENTITY:-}" ]]; then
    wanted="$YEEHAW_SIGNING_IDENTITY"
    match="$(security find-identity -v -p codesigning | grep -F -- "$wanted" || true)"
    [[ -n "$match" ]] || die "no valid signing identity matches \"$wanted\""
    (($(grep -c . <<<"$match") == 1)) || die "\"$wanted\" matches more than one signing identity; use its SHA-1 hash"
    identity="$(awk '{ print $2 }' <<<"$match")"
    grep -qx "$identity" <<<"$team_hashes" ||
        die "refusing to sign with a certificate that isn't a Developer ID Application certificate from team $TEAM_ID"
else
    [[ -n "$team_hashes" ]] || die "no Developer ID Application certificate from team $TEAM_ID is in the keychain"
    (($(grep -c . <<<"$team_hashes") == 1)) ||
        die "team $TEAM_ID has more than one Developer ID Application certificate; set YEEHAW_SIGNING_IDENTITY to one's SHA-1 hash"
    identity="$team_hashes"
fi
echo "Signing with team $TEAM_ID's Developer ID Application certificate ($identity)"

# ---- Build -------------------------------------------------------------------------------------

version="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
build="$(plutil -extract CFBundleVersion raw Resources/Info.plist)"
step "Building YeeHaw $version ($build) from $(git rev-parse --short HEAD 2>/dev/null || echo "an unknown commit")$(
    [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]] && echo " with uncommitted changes")"
YEEHAW_SIGNING_IDENTITY="$identity" scripts/build-app.sh

built="dist/YeeHaw.app"
[[ -d "$built" ]] || die "the build made no $built"

# The signature must come from the team, with the hardened runtime and a secure timestamp, or
# notarization fails (or worse, a foreign certificate ships).
signed_info="$(codesign -dvv "$built" 2>&1)"
grep -qx "TeamIdentifier=$TEAM_ID" <<<"$signed_info" || die "$built is not signed by team $TEAM_ID; refusing to continue"
grep -q "^Authority=Developer ID Application: " <<<"$signed_info" || die "$built is not signed with a Developer ID Application certificate"
grep -q "^Timestamp=" <<<"$signed_info" || die "$built has no secure timestamp"
grep -Eq "^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime.*\)" <<<"$signed_info" || die "$built is not signed with the hardened runtime"
codesign --verify --deep --strict "$built" || die "$built's signature doesn't verify"

# ---- Zip and notarize ----------------------------------------------------------------------------

rm -rf release
mkdir -p release
app="release/YeeHaw.app"
zip="release/YeeHaw.zip"
ditto "$built" "$app"
ditto -c -k --keepParent "$app" "$zip"

step "Notarizing $zip with the \"$NOTARY_PROFILE\" profile (this waits for Apple)"
result_file="$(mktemp -t yeehaw-notary)"
trap 'rm -f "$result_file"' EXIT
xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json >"$result_file" ||
    die "notarytool couldn't submit $zip (is \"$NOTARY_PROFILE\" a notarytool keychain profile?)"
status="$(plutil -extract status raw "$result_file" 2>/dev/null || echo unknown)"
submission="$(plutil -extract id raw "$result_file" 2>/dev/null || echo unknown)"
if [[ "$status" != "Accepted" ]]; then
    die "notarization ended as \"$status\"; see: xcrun notarytool log $submission --keychain-profile \"$NOTARY_PROFILE\""
fi
echo "Notarization accepted (submission $submission)"

# ---- Staple and re-zip -------------------------------------------------------------------------

step "Stapling the ticket to $app"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

assessment="$(spctl -a -vv -t execute "$app" 2>&1)" || die "Gatekeeper rejects $app: $assessment"
grep -q "source=Notarized Developer ID" <<<"$assessment" || die "Gatekeeper doesn't see $app as notarized: $assessment"
grep -q "origin=.*($TEAM_ID)" <<<"$assessment" || die "Gatekeeper reports another team for $app"

step "Done: YeeHaw $version ($build)"
ls -lh "$zip"
echo "$app is notarized and stapled; $zip holds it."
