# YeeHaw

YeeHaw is a small menu bar manager for macOS 27.2 and later. It does three things:

- **Hides the menu bar icons you don't need.** Hidden icons leave the menu bar. Click YeeHaw's hat
  icon to open a strip just below the menu bar with the hidden icons in it; clicking one works as
  if you had clicked it in the menu bar.
- **Sets the order of the icons that stay visible**, in the Layout window. Drag icons to reorder
  them, or between rows to hide and show them.
- **Adjusts the spacing between menu bar icons**, with an explicit Apply step that restarts only
  the apps you pick.

It aims to be trustworthy above all:

- **The layout stays where you put it.** YeeHaw writes positions only when you change them.
- **Apple's switch wins.** An app you switched off in System Settings → Menu Bar never appears in
  YeeHaw, and YeeHaw never switches it back on.
- **Nothing is lost if YeeHaw quits or crashes.** Hidden icons go back to the menu bar on quit, and
  the next launch repairs anything a crash left behind.

## Using it

- **Click** the hat to open or close the strip of hidden icons. Esc closes it; the arrow keys and
  Return work in it, and every icon has a VoiceOver label.
- **Right-click** (or Control-click) the hat for **Layout…**, **Settings…** and **Quit YeeHaw**.
- **Layout…** shows the menu bar and the Hidden row. Drag between them, or use each icon's
  actions. Spacing lives at the bottom of the same window.
- **Settings…** has Open at Login, the permission statuses with buttons to fix a missing one, and
  the list of apps you switched off yourself.

## Requirements

- macOS 27.2 or later. YeeHaw shows a message and quits on anything older.
- A Mac where Thaw isn't running: both would write the same files, so YeeHaw won't start alongside
  it.

YeeHaw asks for what it needs in a short first-run guide:

| Permission | Why |
| --- | --- |
| **Accessibility** (called *Device Control and Data Access* on macOS 27) | To see which menu bar icons are drawn and where, and to click a hidden icon for you from the strip. |
| **Access to Apple's Allow list file** (`group.com.apple.controlcenter.plist`) | Hiding an icon is the same switch as System Settings → Menu Bar. You grant access once by choosing the file in an Open panel. |
| **Access to macOS's layout file** (`com.apple.MenuBar.plist`) | Ordering the visible icons writes their positions there. Granted the same way. |
| **Screen Recording** (optional) | Lets the strip show each app's real menu bar glyph and match the menu bar's colour. Without it, the strip shows app icons on a neutral background. YeeHaw never prompts for it; turn it on from Settings if you want it. |

YeeHaw isn't sandboxed: Accessibility, writing other apps' preference files and restarting apps
for spacing all need that.

## Building

You need Xcode 27.2 (Swift 6.2). There are no third-party dependencies.

```sh
swift test                         # unit tests (Swift Testing)
scripts/build-app.sh               # builds and signs dist/YeeHaw.app
scripts/build-app.sh --install     # also installs it to ~/Applications/YeeHaw.app
```

Development builds are always signed with team `V2P99VF75Q`'s certificate, never ad hoc, and run
from `~/Applications`. An ad-hoc rebuild would lose the Accessibility grant, and macOS won't list
apps that run from a temporary folder. `YEEHAW_SIGNING_IDENTITY` picks a different certificate
from the same team (its SHA-1 hash); `build-app.sh` refuses a build that isn't signed by team
`V2P99VF75Q`.

## Releasing

```sh
scripts/release.sh
```

The script:

1. Builds the app with team `V2P99VF75Q`'s Developer ID Application certificate and refuses to
   continue if the signature names any other team, or lacks the hardened runtime or a secure
   timestamp.
2. Zips it and notarizes the zip with `xcrun notarytool submit --keychain-profile notary --wait`.
3. Staples the ticket to the app, zips it again and checks that Gatekeeper reports
   `source=Notarized Developer ID`.

The results are `release/YeeHaw.app` and `release/YeeHaw.zip` (the folder isn't tracked). Notary
credentials live only in the `notary` Keychain profile, created once with
`xcrun notarytool store-credentials notary`; set `NOTARY_PROFILE` to use another profile. Never put
notary keys or passwords in the repository.

## Project layout

- `Sources/YeeHawCore` — the model, with no AppKit: the position table, matching icons to apps,
  the hide/show/move rules and the crash-recovery journal.
- `Sources/YeeHaw` — the app: the status item, strip, Layout, Settings and first-run windows, and
  the system adapters (Accessibility, the two preference files, ScreenCaptureKit).
- `Tests` — Swift Testing suites for both targets.
- `docs/superpowers/specs` — the design.
