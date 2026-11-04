#!/bin/bash
# Usage: scripts/release.sh [--notes-file <notes.md>] [--publish]
# Builds a notarized, stapled YeeHaw release in release/: YeeHaw.app, the installer
# YeeHaw-<version>.dmg (made with create-dmg; the background is drawn by
# render-dmg-background.swift), and appcast.xml, the update feed installed copies read.
#
# The DMG is also the update Sparkle downloads. Every update is signed with YeeHaw's Sparkle key,
# kept in the login Keychain under the account com.zapps.yeehaw; the script refuses to go on if
# that key isn't the one whose public half is in Resources/Info.plist.
# --notes-file: Markdown release notes, shown in YeeHaw's update window and on the GitHub release.
# --publish: tags v<version>, pushes the tag, and creates the GitHub release with the DMG and
# appcast.xml. Installed copies see the update as soon as the release exists. It needs a clean,
# pushed tree and --notes-file. Without --publish, the command is printed.
#
# Signing: only Developer ID Application certificates from team V2P99VF75Q sign releases; any
# other certificate is refused. YEEHAW_SIGNING_IDENTITY may name one (a SHA-1 hash or the team
# ID); by default the team's only Developer ID Application certificate is used.
# Notarization: NOTARY_PROFILE names an `xcrun notarytool store-credentials` keychain profile
# ("notary" by default). Credentials stay in the Keychain; none are read or written here.
set -euo pipefail

TEAM_ID="V2P99VF75Q"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
REPO="umzcio/YeeHaw"
SPARKLE_ACCOUNT="com.zapps.yeehaw"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"

die() {
    echo "release: $*" >&2
    exit 1
}
step() { echo "==> $*"; }

notes_file=""
publish=0
while (($#)); do
    case "$1" in
        --notes-file)
            (($# >= 2)) || die "--notes-file needs a path"
            notes_file="$2"
            shift 2
            ;;
        --publish) publish=1; shift ;;
        -h | --help) sed -n '2,15p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

cd "$(dirname "$0")/.."

for tool in swift codesign xcrun ditto security spctl plutil hdiutil; do
    command -v "$tool" >/dev/null || die "$tool is missing"
done
command -v create-dmg >/dev/null || die "create-dmg is missing (brew install create-dmg)"
if [[ -n "$notes_file" ]]; then [[ -s "$notes_file" ]] || die "no notes in $notes_file"; fi
if ((publish)); then
    command -v gh >/dev/null || die "--publish needs the GitHub CLI (brew install gh)"
    [[ -n "$notes_file" ]] || die "--publish needs --notes-file"
    [[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "commit your changes first; --publish releases the current commit"
fi

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

version="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
build="$(plutil -extract CFBundleVersion raw Resources/Info.plist)"
tag="v$version"
if ((publish)); then
    ! gh release view "$tag" --repo "$REPO" >/dev/null 2>&1 || die "$REPO already has a $tag release; bump the version first"
fi

# ---- Update key --------------------------------------------------------------------------------

swift package resolve >/dev/null
app_key="$(plutil -extract SUPublicEDKey raw Resources/Info.plist)"
keychain_key="$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p)" ||
    die "no Sparkle key for $SPARKLE_ACCOUNT in the Keychain"
[[ "$app_key" == "$keychain_key" ]] || die "the Sparkle key in the Keychain isn't the one in Info.plist; updates would be refused"

# ---- Build -------------------------------------------------------------------------------------
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

# ---- Notarize the app --------------------------------------------------------------------------

# Submits $1 and waits; dies unless Apple accepts it.
notarize() {
    local file="$1" result_file status submission
    step "Notarizing $file with the \"$NOTARY_PROFILE\" profile (this waits for Apple)"
    result_file="$(mktemp -t yeehaw-notary)"
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json >"$result_file" ||
        die "notarytool couldn't submit $file (is \"$NOTARY_PROFILE\" a notarytool keychain profile?)"
    status="$(plutil -extract status raw "$result_file" 2>/dev/null || echo unknown)"
    submission="$(plutil -extract id raw "$result_file" 2>/dev/null || echo unknown)"
    rm -f "$result_file"
    if [[ "$status" != "Accepted" ]]; then
        die "notarization ended as \"$status\"; see: xcrun notarytool log $submission --keychain-profile \"$NOTARY_PROFILE\""
    fi
    echo "Notarization accepted (submission $submission)"
}

work="$(mktemp -d -t yeehaw-release)"
trap 'rm -rf "$work"' EXIT
rm -rf release
mkdir -p release
app="release/YeeHaw.app"
ditto "$built" "$app"
# The app is notarized and stapled on its own first, so a copy dragged out of the DMG opens
# without a network check.
ditto -c -k --keepParent "$app" "$work/YeeHaw.zip"
notarize "$work/YeeHaw.zip"
step "Stapling the ticket to $app"
xcrun stapler staple "$app"
xcrun stapler validate "$app"

assessment="$(spctl -a -vv -t execute "$app" 2>&1)" || die "Gatekeeper rejects $app: $assessment"
grep -q "source=Notarized Developer ID" <<<"$assessment" || die "Gatekeeper doesn't see $app as notarized: $assessment"
grep -q "origin=.*($TEAM_ID)" <<<"$assessment" || die "Gatekeeper reports another team for $app"

# ---- DMG ---------------------------------------------------------------------------------------

dmg="release/YeeHaw-$version.dmg"
stage="$work/stage"
mkdir -p "$stage"
ditto "$app" "$stage/YeeHaw.app"
swift scripts/render-dmg-background.swift "$work/background.png"

step "Making $dmg"
# Icon positions must match the arrow and label pills in render-dmg-background.swift. The window
# is 68 pt taller than the 440 pt picture: Finder's title and path bars take that much on 27.2.
create-dmg \
    --volname "Install YeeHaw" \
    --volicon "$app/Contents/Resources/AppIcon.icns" \
    --background "$work/background.png" \
    --window-pos 240 180 \
    --window-size 720 508 \
    --icon-size 112 \
    --text-size 14 \
    --icon "YeeHaw.app" 200 218 \
    --hide-extension "YeeHaw.app" \
    --app-drop-link 520 218 \
    --format UDZO \
    --filesystem HFS+ \
    --no-internet-enable \
    --hdiutil-quiet \
    "$dmg" "$stage"
[[ -f "$dmg" ]] || die "create-dmg made no $dmg"

codesign --force --timestamp --sign "$identity" "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
# Right after stapling, Gatekeeper once refused a freshly notarized DMG (v0.0.3) and accepted it
# moments later, so it's asked a few times before giving up.
for attempt in 1 2 3 4 5; do
    assessment="$(spctl -a -vv -t open --context context:primary-signature "$dmg" 2>&1)" &&
        grep -q "source=Notarized Developer ID" <<<"$assessment" && break
    ((attempt < 5)) || die "Gatekeeper doesn't see $dmg as notarized: $assessment"
    echo "Gatekeeper doesn't accept $dmg yet; asking again in 5 s"
    sleep 5
done

# ---- Update feed -------------------------------------------------------------------------------

# generate_appcast reads every archive in the folder; this one holds only the new DMG and its notes
# (same name, .md), so the feed lists this version, whose download is this release's DMG.
step "Writing release/appcast.xml"
updates="$work/updates"
mkdir -p "$updates"
cp "$dmg" "$updates/"
appcast_args=(--account "$SPARKLE_ACCOUNT" --download-url-prefix "https://github.com/$REPO/releases/download/$tag/"
    -o "$updates/appcast.xml")
if [[ -n "$notes_file" ]]; then
    cp "$notes_file" "$updates/YeeHaw-$version.md"
    appcast_args+=(--embed-release-notes)
fi
"$SPARKLE_BIN/generate_appcast" "${appcast_args[@]}" "$updates"
cp "$updates/appcast.xml" release/appcast.xml
grep -q "sparkle:edSignature=" release/appcast.xml || die "appcast.xml has no update signature"
grep -q "<sparkle:shortVersionString>$version</sparkle:shortVersionString>" release/appcast.xml ||
    die "appcast.xml doesn't list $version"

step "Done: YeeHaw $version ($build)"
ls -lh release

# ---- Publish -----------------------------------------------------------------------------------

gh_cmd=(gh release create "$tag" "$dmg" release/appcast.xml --repo "$REPO" --title "YeeHaw $version"
    --notes-file "${notes_file:-/dev/null}")
if ((publish)); then
    step "Tagging $tag and publishing the release"
    git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git tag -a "$tag" -m "YeeHaw $version"
    git push origin "refs/tags/$tag"
    "${gh_cmd[@]}"
else
    echo
    echo "Not published. To publish (push the commit first):"
    printf '  '
    printf '%q ' "${gh_cmd[@]}"
    echo
fi
