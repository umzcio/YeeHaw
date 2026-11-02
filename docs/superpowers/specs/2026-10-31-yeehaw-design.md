# YeeHaw — design

Date: 2026-10-31
Status: draft for approval

## What it is, and why

YeeHaw is a small menu bar manager for macOS 27.2 and later. It does three things:

1. **Hides menu bar icons you don't need.** Hidden icons leave the menu bar. You click YeeHaw's own
   menu bar icon to open a floating strip just below the menu bar, like Thaw's "Thaw Bar". The
   strip shows the hidden icons, and clicking one works as if you'd clicked it in the menu bar.
2. **Sets the order of the icons that stay visible**, through a layout window.
3. **Adjusts the spacing between icons.**

It replaces a fork of Thaw (github.com/umzcio/Thaw). The owner installed Thaw's macOS 27 beta and
found it unusable: icons moved around on their own, vanished or landed in the wrong place, the
strip misbehaved, and apps the owner had switched off in System Settings → Menu Bar (Google
Drive, OneDrive) came back. Thaw is also far bigger than needed: about 194k lines of Swift,
profiles, triggers, scripting, and a closed-source binary at its core.

**The bar for quality:** few features, but every one finished. "Minimal" is not an excuse for
anything to look or feel lazy. The owner said this explicitly.

## Goals

- Hide and show third-party apps' menu bar icons reliably, with a polished strip for reaching the hidden
  ones.
- A layout window for choosing what's hidden and setting the order (mockup "B", below).
- Spacing adjustment with an explicit Apply step.
- Above all, **trustworthy behaviour**:
  - **The layout stays where you put it.** YeeHaw never reshuffles icons on its own.
  - **Apple's switch wins.** An app you switched off in System Settings → Menu Bar doesn't exist
    as far as YeeHaw is concerned. It never appears in the bar, the strip, or the layout window,
    and YeeHaw never switches it back on.
  - **Nothing is lost if YeeHaw quits or crashes.** Icons go back to sitting normally in the menu
    bar.

## Non-goals

These are Thaw features deliberately left out. Some can be added later if they're missed.

- Profiles, triggers, Focus or Space rules, per-display configurations
- Hotkeys, URL schemes, scripting, CLI
- Auto-rehide timers, show-on-hover, an "always hidden" section, search
- Menu bar appearance or tinting, custom spacers or dividers
- Background "repair" or automatic re-arranging of any kind
- Hiding Apple's own items (clock, Wi-Fi, battery and so on). People use System Settings for those.
- Support for anything older than macOS 27.2
- A built-in update mechanism

## Anti-goals: failures even if it technically works

- An icon moves without the user moving it.
- An app the user switched off reappears anywhere.
- The whole menu bar blanks or redraws (no restarting `MenuBarAgent`).
- Apple background processes get quit or restarted.
- Any surface looks unfinished: misaligned, wrong materials, janky animation, placeholder art.

## How macOS 27 works, and what was proven

macOS 27 rebuilt the menu bar. Apple documents none of this; it comes from other developers'
reports and from tests run on the owner's Mac, on macOS 27.0.1 and then 27.2.

- **One process draws the whole bar.** `com.apple.MenuBarAgent` draws everything in one window.
  Status items no longer have windows of their own. The old Ice and Thaw 2 techniques (moving
  item windows, the expanding-spacer trick, `CGWindowList` enumeration) are dead.
- **There's no public API** for hiding, ordering, or listing other apps' items.
- **Hiding is per app, not per icon.** An app's icons all hide together. Every manager on 27 has
  this limit.

### The proof test

A throwaway test app (`com.zapps.yeehaw.spike`, in `~/Applications/YeeHawSpike.app`) checked each
building block. Its source lived in a temporary scratch folder and is gone, so the techniques are
written out below.

| Building block | Result |
|---|---|
| Read which icons are actually drawn (Accessibility) | ✅ on 27.0.1 and 27.2 |
| Hide or show an app live by flipping Apple's Allow switch | ❌ on 27.0.1 (saved but ignored until `MenuBarAgent` restarts). ✅ on 27.2: gone within 5 s, back in the same slot |
| Reorder by writing macOS's layout file | ✅ on 27.2, within 5 s, exact |
| Spacing | ⚠️ works only when each app relaunches; nothing applies live |
| Clicking a hidden icon from the strip | ✅ on 27.2: hide 0.8 s, reveal under 0.1 s, AX press about 0.5 s, re-hide 0.8 s. The owner saw the menu open |

**Why 27.2 is the minimum:** live switching did not work on 27.0.1.

### Technique 1: what is drawn, and who owns it

- **The authority on what's drawn:** the Accessibility children of `MenuBarAgent`'s `AXWindow`.
  - Third-party items appear as `AXButton`s, carrying the frame plus the description or title the app
    set.
  - Apple items appear as `AXMenuBarItem`s with identifiers like `com.apple.menuextra.clock`.
  - An item that isn't in this list is not drawn.
- **Owners:** walk each running app's `kAXExtrasMenuBarAttribute` children (per-app AX timeout of
  about 0.3 s) to get bundle ID, frame, identifier, title and description. Then match each one to
  a drawn button by exact **x and width**. The y values differ between the two trees, so don't
  compare them.
- **Some items have no description or title** (on the owner's Mac, SwarmBar shows only a changing
  title such as "1", and Tailscale shows nothing). Frame matching is the only way to name them, so
  the test's crude list left them as "?".
- **Never trust an app's own reported frame on its own.** On the owner's Mac:
  - Google Drive (switched off) reported x = −1, y = 1317.
  - Malwarebytes (also switched off) still reported a plausible on-bar frame (x = 1564) that
    overlapped another app's real icon.
  - Only exact matching against the drawn list, combined with Apple's Allow list, gets this right.

### Technique 2: hiding with Apple's Allow switch

- **The file:**
  `~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist`,
  key `trackedApplications`.
- **Its format:** a binary plist stored as `Data`. Decoded, it's a flat array of alternating keys
  and values:
  - key: `{bundle: {_0: "<bundle id>"}}`, or an `adhocBinary` form for unsigned dev builds
  - value: `{location, menuItemLocations, isAllowed}`
- **Writing it:** use `CFPreferences` with the file's **absolute path minus `.plist`** as the
  domain, and `kCFPreferencesCurrentUser` / `kCFPreferencesAnyHost`.
  - Synchronize before reading and after writing.
  - Change only `isAllowed` on entries that already exist; `MenuBarAgent` adds entries itself.
  - This is the technique from floweredao/hidden PR #21, and it was verified on the owner's Mac on
    27.2.
- **Access:** the file is protected. The user grants access once by picking it in an `NSOpenPanel`
  pre-pointed at the folder, and YeeHaw keeps a security-scoped bookmark. Reading it with
  `CFPreferences` failed until the pick.

### Technique 3: ordering with macOS's layout file

- **The file:**
  `~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist`,
  key `TrailingItemPreferredPositions`.
- **Its format:** a dictionary of item key → `Double`. The number is the distance from the trailing
  (right) edge, and `module:Clock` is 0, so a **larger number sits further left**.
- **Keys:**
  - `status:<bundle id>::<autosave name or Item-N>` for third-party items, for example
    `status:com.abdurrahim.DigUp::Item-0` and `status:com.nordvpn.macos::nordMenuBarItem`
  - `module:<Name>` for Apple items, for example `module:WiFi`
  - Stale and duplicate keys exist (for example, both `com.google.drivefs::Google Drive` and
    `com.google.drivefs::Item-0`).
- **Writing it:** same `CFPreferences` technique and the same one-time file pick as the Allow list.
  `MenuBarAgent` applies a change within seconds.
- **Pinned items:** Clock and Control Center can't be moved. macOS ignores moves for them, and for
  Live Activities.

### Technique 4: spacing

- **The settings:** `NSStatusItemSpacing` and `NSStatusItemSelectionPadding` in the current-host
  global domain (`defaults -currentHost write -globalDomain …`). Both default to 16.
- **Each app reads them at launch.** On the owner's Mac, writing 4/4 changed nothing on screen.
  Relaunching DigUp made just its icon 12 pt narrower.
- **So applying spacing means relaunching apps.**
  - Thaw's "relaunch wave" also hit Apple background services, and some never came back
    (Spotlight disappearing, Thaw issues #720 and #1070).
  - YeeHaw relaunches only regular third-party apps (see below).

## The product

### YeeHaw's menu bar icon

- One icon, YeeHaw's own.
- **It sits right next to Control Center**, at the right end near the clock. This is the owner's
  choice. YeeHaw places its own icon there once at first run, by writing its own position key just
  left of `module:BentoBox-0`, which appears to be Control Center (to be confirmed). After that the
  owner can move it like any other icon.
- **Click:** opens or closes the strip.
- **Secondary action:** a small menu with Layout…, Settings…, and Quit YeeHaw. Note the macOS 27
  beta reports that right-click and drag events on an app's own status item stopped arriving; use
  whatever works reliably on 27.2.
- **The icon needs real design:** a custom template glyph that suits the name, not a stock SF
  Symbol dropped in.

### The strip

- **Placement:** a floating panel attached just below YeeHaw's icon, as in the owner's screenshot
  of Thaw. It is a bar-height, opaque strip with rounded corners, centred under the icon and
  painted with the menu bar's own colour, so it reads as part of the bar. The colour is sampled with
  ScreenCaptureKit only when Screen Recording is already granted (YeeHaw never prompts); without
  it the strip uses the window background colour. Ink is black or white by contrast. Hidden icons
  show in a single row at menu bar size. (Revised 2026-11-01 after the owner rejected two Liquid
  Glass versions as "disconnected".)
- **Open and close:** fades in and out like the native status menus it sits among (revised
  2026-11-01: the strip reads as a sibling of those menus, which don't spring), and closes on outside
  click, Esc, or after an icon is used. Left and Right light its icons, Return or Space opens one.
  - Respects Reduce Motion and Reduce Transparency, and looks right in light and dark mode.
- **Order:** icons follow the Hidden row of the layout window.
- **Clicking an icon (the owner chose option "B"):** the app's menu can only open from its real
  icon, so the real icon briefly appears **right next to YeeHaw's icon** and its menu opens there,
  just under where the user clicked.
  1. Close the strip.
  2. Write the hidden item's position to sit immediately left of YeeHaw's icon.
  3. Switch the app on.
  4. Wait, polling AX every 50 ms with a timeout of a few seconds, until the item is drawn. This
     took under 0.1 s in the test.
  5. Press it: AX press first, then `AXShowMenu`, then a synthesized click at its frame as a last
     resort.
  6. When its menu or popover closes, switch the app off and restore the item's previous position.
  - **Expect icons to shift:** the icons left of the revealed one slide over by its width while it's
    open, and slide back afterwards. The owner accepted this because it only happens in response to
    their click. It is the one sanctioned exception to "icons never move on their own".
  - **AX press can block:** in the test it once returned success in 0.5 s, and once timed out with
    `-25204` after 1.5 s while the menu was in fact open, apparently because the app was busy
    tracking its menu. Call it off the main thread, and don't treat a timeout as failure. Check
    whether a menu actually appeared before falling back.
  - **The test placed the item at the far left end instead.** That moves nothing, but the menu
    opens away from the strip, and the owner rejected it. Because the temporary position applies
    only to an item that is otherwise hidden, and is always restored, it doesn't break
    "positions are written only on a user edit".
- **Images:**
  - With Screen Recording granted, capture the real glyph whenever the item is drawn (for example,
    just before hiding it, and each time it's revealed) using ScreenCaptureKit on `MenuBarAgent`'s
    window, cropped to the item's AX frame. Cache it per item.
  - Without Screen Recording, show the app's icon (`NSWorkspace.icon(forFile:)`), styled so it sits
    well in the strip.
  - **Never reveal an item just to photograph it.** Thaw did, and it made the bar reflow.

### The layout window (mockup B)

A compact window with two labelled rows of icon tiles: **Menu Bar** and **Hidden**. The mockup the
owner picked is option B in `assets/2026-10-31-arrange-mockups.html`, an HTML fragment from the
brainstorming session. It renders without its frame styling, but the layout is clear.

- **Moving icons:**
  - Drag between rows to hide or show.
  - Drag within the Menu Bar row to reorder; the real bar updates on drop.
  - The Hidden row's order is the strip's order, and YeeHaw keeps it in its own preferences.
- **What's listed:**
  - Third-party apps can be hidden.
  - Apple's items appear in the Menu Bar row so the order makes sense in context. Clock and Control
    Center are shown as fixed.
  - Moving other Apple items by writing their `module:` keys is untested; allow it only if it works,
    and otherwise show them fixed. They can't be dragged to Hidden.
  - **Apps with several icons (my call):** one tile per icon.
    - In the Menu Bar row, each icon is ordered on its own, the way macOS allows.
    - Moving any of an app's tiles to Hidden moves all of them, and they show as a visibly
      grouped cluster in Hidden.
  - Apps switched off in System Settings by the user are not listed at all.
- **Spacing:** a slider with a live preview, a list of the apps that will restart, and an **Apply**
  button.
- **The visual standard:**
  - The mockup is a starting point, not a spec.
  - Native macOS 27 look: proper materials, SF typography, real drag affordances (lift, insertion
    marker, spring settle).
  - Icons shown large enough to read.

### Settings

As little as possible: launch at login (`SMAppService`), the permission statuses with fix-it
buttons, and the spacing control if it doesn't live in the layout window. The builder decides
where spacing goes.

### First run

A short, good-looking onboarding that gets three things in order:

1. **Accessibility.** On macOS 27 it's named **Device Control and Data Access**, and the system
   wording sounds alarming, so say plainly why YeeHaw needs it.
2. **Pick Apple's Allow list file.** Open the panel pre-pointed at the folder with the file
   pre-selected, and explain what's being granted.
3. **Pick macOS's layout file.** Same treatment.

4. **Review apps that are already switched off (the owner agreed).** About 23 apps are off in the
   owner's Allow list today, and some may have been switched off by Thaw rather than by the owner.
   - First run lists them, with their icons, all unticked.
   - Ticked apps go into Hidden, and into the journal so YeeHaw owns them.
   - Unticked apps stay the user's: off, and invisible to YeeHaw from then on.
   - The list can be reopened later from Settings.
5. **Place YeeHaw's icon next to Control Center.**

Thaw is uninstalled on the owner's Mac. As a safeguard (my call), YeeHaw refuses to start, with a
clear message, if Thaw (`com.stonerl.Thaw`) is running, since both would write the same two files.

Screen Recording is offered later and is optional. Permission-flow lessons from the test:
- macOS refused to list an app running from `/private/tmp`.
- Ad-hoc-signed rebuilds lose the Accessibility grant.
- Dev builds must be signed with a stable identity (team `V2P99VF75Q`) and run from a normal
  location.

## State, ownership and edge cases

- **Hidden** = the bundle IDs the user put in the Hidden row. YeeHaw stores this, and it is the
  only source of truth for what YeeHaw hides.
- **The journal** = the bundle IDs YeeHaw itself has switched off, persisted immediately on every
  flip.
  - Anything off in Apple's list that isn't in the journal belongs to the user. YeeHaw never
    touches it and never shows it.
- **Quitting:** switch on everything in the journal and clear it.
- **Launching:**
  - First reconcile: any journal entry left over from a crash is switched back on, unless it's still
    in Hidden.
  - Then hide what's in Hidden.
- **Logout and shutdown (my call):** leave the apps hidden and keep the journal, so the next login
  doesn't flash every icon before YeeHaw starts. This still honours "nothing is lost": the next
  launch reconciles. Only when YeeHaw opens at login (revised 2026-11-01): otherwise nothing would
  start it again, so the apps are switched back on as for an ordinary quit.
- **The user changes Apple's switch while YeeHaw runs.** Watch the Allow list for changes.
  - The user switches **on** an app YeeHaw hid: Apple's switch wins. Remove the app from Hidden and
    from the journal.
  - The user switches **off** an app YeeHaw shows: it disappears from YeeHaw.
- **New apps:**
  - New icons appear in the Menu Bar row wherever macOS puts them. YeeHaw doesn't move them.
  - An app with no `trackedApplications` entry yet can't be hidden until macOS adds one. Show it
    as not yet hideable rather than failing silently.
- **Writing the order:** only on a user edit in the layout window. No timers, no reacting to app
  launches, display changes, or wake.
- **Choosing position numbers:** keep Apple items' existing values. Place a moved item between its
  new neighbours' values, and spread values out if they get too close. Never renumber items the
  user didn't move.
- **Spacing Apply (my call on the details):**
  1. Show the running apps that own a third-party status item, each with a checkbox.
     - Menu-bar-only apps are ticked by default.
     - Apps with open windows (Outlook, Teams and the like) are unticked by default, with a note
       that restarting them interrupts whatever is open.
  2. Write both settings.
  3. Relaunch the ticked apps one at a time.
  4. Never list or relaunch `com.apple.*` processes or apps without a bundle in an Applications
     folder, and never force-quit an app that declines to quit.
  5. Report which apps were restarted and which were skipped. Unticked apps pick up the new
     spacing whenever they next launch.
- **Notch and overflow:** macOS 27 has its own « overflow button. YeeHaw doesn't fight it.
- **Multiple displays:** the strip opens on the display whose menu bar was clicked. Per-display
  settings are a non-goal.

## Constraints

- macOS 27.2+. Swift with SwiftUI plus AppKit where needed (status item, panels, AX).
- Not sandboxed: Accessibility, CFPreferences writes to other domains, and relaunching apps are all
  incompatible with the sandbox.
- Bundle ID `com.zapps.yeehaw`.
- Signed with the personal Developer ID, team `V2P99VF75Q`, and notarized with the `notary`
  keychain profile. Use `~/GitHub/zMail/scripts/release.sh` as the reference, including refusing to
  sign with a certificate from outside the team.
- Never commit the certificate's identity name or any personal name.
- Thaw is GPLv3, so copy no code from it; use it only as a reference for behaviour. The
  floweredao/hidden technique is a public technique, not copied code.

## Risks and things to prove first

1. **The strip click flow.** The basic flow is proven (see the table above). Still open:
   - Detecting reliably that the menu or popover closed, so the app can be hidden again.
   - Revealing the icon next to YeeHaw (option B) rather than at the far left, as the test did.
   - Apps that open a window instead of a menu.

   Prove these first. If the result looks or feels bad, bring it back to the owner before building
   the strip UI around it.
2. **Live switching depends on 27.2 behaviour Apple doesn't document.** A future update could
   break it. YeeHaw should detect when a flip isn't honoured within a few seconds and say so
   clearly, rather than retry in a loop.
3. **Item identity:** apps with no autosave name (`Item-0`), with changing titles, or with several
   icons. Matching by bundle ID plus AX frame should cover the cases above, but test it with the
   owner's actual apps.
4. **Moving Apple's own items** by writing their `module:` keys is untested. That includes
   confirming that `module:BentoBox-0` is Control Center, which matters for placing YeeHaw's icon.

## Left to the builder

- Code structure, module layout, and testing approach
- Exact animation curves, timings, and visual details, within the quality bar above
- How to detect a menu closing, and timeouts
- Where the spacing control lives
- The icon glyph design, within the "real design" requirement
