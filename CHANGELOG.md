# Changelog

All notable changes to Docklane are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Saved window layouts can be renamed, updated with the current windows and deleted (with a
  confirmation) from a menu on each layout. Opening a layout that comes back only in part says
  what is missing ("Not installed on this Mac: …", "Opened no window to put back: …") instead of
  failing silently
- Pin App and Add App buttons (Settings → Apps) pin an app or blur its previews without the
  right-click menu: running apps, or any app from the Applications folder
- Saving a layout without a name or without open windows says why instead of a greyed-out button;
  ⌘Tab as the window switcher shortcut notes that it replaces the macOS app switcher
- C in the window switcher sends the whole app to the Dock: every window of the selected app is
  minimized (full-screen windows leave full screen first). H (hide) is gone. The hint names both
  minimize keys by what they act on: "C send app to Dock", "M minimize window"
- Live pins: Pin Live Preview (panel menu) keeps a live, always-on-top copy of a window on every
  desktop (10 frames a second; once a second for a window on another desktop), up to four
- App rules (Settings → Workspaces): new windows of an app are placed as soon as they open
  (left / right / top / bottom half, center, fill); windows open when Docklane starts are left alone
- Arrange the front window from the keyboard: ⌃⌥←/→/↑/↓ halves, pressing again cycles to a
  third and two thirds; ⌃⌥↩ fill, ⌃⌥C center, ⌃⌥⌘←/→ to the other display (same place, scaled).
  Respects the strip a pinned panel keeps clear; ⌃⌥Z undoes; can be turned off
- Window memory. Workspaces get a shortcut each (⌃⌥⌘1–9), remember which display every
  window was on (and where on it, so they fit another resolution or the laptop screen), wait
  for apps they open to show their windows, and can hide every other app. Docklane also
  remembers the layout of each set of displays and puts windows back when a display is
  connected or disconnected. ⌃⌥Z undoes the last layout change (workspace, display change,
  Move & Resize). Moving windows to another desktop is not possible on current macOS
- Desktop switcher on ⌥Tab: every desktop and full-screen space as a miniature (wallpaper
  with its windows where they are, or the full-screen app), in Mission Control order. Hold ⌥,
  Tab to move, release to go; 1–9 jump straight to one. The first press selects the desktop
  used last, so a quick ⌥Tab toggles between two. Docklane lands on the window last used
  there; an empty desktop is reached with your own Mission Control shortcut (⌃1… or ⌃←/⌃→).
  ⌃⌥Tab when the window switcher uses ⌥Tab; can be turned off in Settings
- ⌘` / ⌘⇧` move through the switcher and ⌘. cancels it, as in the system switcher

### Changed

- New tagline: "Every open window, at a glance." with "See your windows, switch between them and
  keep your layout." in About, the welcome window and the README
- Clearer wording everywhere, one term per thing: Workspaces are now Window Layouts (they
  save and restore window positions; they don't create desktops), "Keep in Dock" is Pin to Panel
  (the macOS Dock is not involved), "Hide Preview" is Blur This App's Previews (previews are
  blurred, per app), "Reset tile order" is Reset Panel Order (now asks first, since it can't be
  undone), App rules are Automatic window placement, and the keyboard placement shortcuts are
  listed one per line. Settings explain what each permission is used for and what stays on the
  Mac; options whose effect wasn't obvious (panel background, desktop labels) have a one-line
  description. All 11 languages updated
- Lighter on the system: no rescan of every app on each focus change while nothing of Docklane
  is on screen, the Space-change scan waits until the slide is over, hot keys and pointer
  monitors are no longer rebuilt on every Space change, the minimized check only asks apps
  with an off-screen window, the audio check runs every 5 s instead of on each scan, app icons
  are cached instead of looked up on every redraw, and the panel and switchers appear first
  and update right after. The large preview is captured at the size it is shown and redrawn
  only when the window changed. Title, desktop and audio labels use a plain dark fill instead
  of a live blur. Idle wake-ups dropped from about one a second to almost none
- Thumbnails are taken only when needed: never while nobody looks (not at start, not for new
  windows, focus or desktop changes); when the panel or a switcher appears, only those older
  than 30 s are taken again, and every 30 s while it stays open. Single frames come from the
  WindowServer (half the CPU of ScreenCaptureKit, measured). macOS shows the purple screen
  recording indicator for any capture; it now lights only for ~6 s after you use the panel
- No animation anywhere: hovering a tile enlarges it instantly (it used to ease in over 0.12 s)
- Lower background load: audio and Dock badges are read only while the panel or a switcher is
  on screen, the safety-net scan runs every 6 s instead of 2 s when nobody looks, focus changes
  no longer capture thumbnails in the background, and pointer movement away from the panel does
  no work. Measured over 15 s: 63 → 16 ms in scans, 42 → 0 ms audio, 13 → 0 ms badges,
  66 → 0 ms drawing, 15 → 1 ms pointer handling
- Minimizing a full-screen window is faster (0.66 → 0.47 s)
- The window and desktop switchers look like the panel: Liquid Glass on macOS 26 (frosted
  before), cards filled by the live thumbnail with the app icon on the corner and the title in a
  pill, a glowing ring for the selection, and a quieter key hint with the keys in bold
- Tiles sit 4 pt from the screen edge, like the Dock (was 16 pt); the far side keeps room
  for shadows, and the app icon's overhang is kept clear on the left and bottom edges
- In a full-screen space, where the menu bar is hidden, a top panel sits at the very top of
  the screen instead of below the empty menu bar area
- Search in the window switcher is now ⌘F (press F while holding ⌘), the macOS Find
  shortcut, on every keyboard layout; "/" still works
- The window switcher is only as wide as its cards, centred, with no empty columns
- The switcher's keyboard hint wraps to up to three lines, breaking only between shortcuts
- v0.1.0 is now signed with a Developer ID and notarized; no Open Anyway step

### Fixed

- Window switcher in long languages: the hint may take a fourth line (Russian lost its last key
  with a single window), the search placeholder stays on one line, and in Arabic every key stays
  next to its label
- Several displays: moving the pointer across the edge two displays share no longer reveals the
  panel on that edge, and the large preview no longer closes on every pointer move because the
  other display's panel is hidden
- A tile dragged out of the panel or cancelled with Esc no longer stays faded, and Finder files
  can be dropped on a tile again afterwards
- The same shortcut chosen for both panel shortcuts, or one taken by another app, is explained
  in Settings instead of silently doing nothing; ⌃⌥Space notes its clash with input sources
- The keyboard navigation shortcut (⌃⌥K) closes navigation when pressed again, and navigation
  ends by itself if macOS doesn't let Docklane take the keyboard
- Dragging the Size slider with the panel always visible moves windows out of the way once,
  when the slider stops, not at every step
- No crash in the window switcher while displays reconfigure and no screen is listed
- The large preview no longer opens over a window's context menu: a right-click closes it and it
  stays closed until the menu is gone
- Menu bar popover: "Panel position" sits above its control like "Panel size", so longer
  translations don't wrap
- Windows of an app that had just launched could take several seconds to appear when the app
  wasn't ready for Accessibility yet; Docklane now retries subscribing after 0.5, 1 and 2 s
- A permission turned off while Docklane runs (in System Settings or by a macOS update) no
  longer fails silently: the menu bar icon gets a dot, the menu bar popover says which
  permission is off and what stops working, with a button to System Settings. Without
  Accessibility the ⌘Tab / ⌥Tab taps are removed so the system switcher works; without Screen
  Recording no captures are attempted. When a permission comes back Docklane picks up again
  (and offers a restart for Screen Recording). Settings → General shows the live state
- Saved data is never lost to a read error: layouts, display layouts, app rules and the panel
  order that can't be read (damaged, or written by a newer Docklane) are kept as a dated backup
  in Docklane's settings before it starts over, and one damaged layout or rule no longer drops
  the others. The manual panel order and window names are cleared after a restart or new login,
  when window numbers point at other windows
- M in the window switcher (and Minimize in the panel menu) works on full-screen windows:
  they leave full screen first, then go to the Dock (macOS won't minimize them directly)
- A panel on the top edge opens every time the pointer is pushed to the top: the topmost
  pixels above the panel count too (the thin strip below the menu bar was easy to skip),
  after a 0.15 s pause so menus stay usable
- An app that stopped responding no longer freezes Docklane: focusing one of its windows
  gives up within half a second (measured 0.52 s) and app notifications use a short timeout
- The window switcher no longer gets stuck open when the ⌘ release is missed; it checks the
  key itself while open
- Q/H/W/M in the switcher only act while ⌘ is held; a key typed after a missed release
  switches and goes to the app instead of quitting or closing something
- Switcher shortcuts follow the keyboard layout: Q/H/W/M are the real letters on AZERTY,
  Turkish F, Dvorak and while a Cyrillic layout is on
- Clicking another app while searching closes the switcher instead of keeping the keyboard
- Focusing and quitting from the switcher run after the key event is released to the system
- One ⌘Tab press now selects the next app; the window you are in is always first and is
  read live when the switcher opens
- Clicking a window sometimes brought only its app forward instead of that exact window;
  focus is now checked and retried once
- Clicking a window of a hidden app (⌘H) now unhides the app
- Choosing a window whose app has quit hands focus back instead of leaving it on Docklane
- Closed windows that the system still reports on no desktop no longer show as ghost tiles
- Windows with the same title (two "New Incognito Tab", two Terminal windows) on another
  desktop are no longer merged into one tile
- A window assigned to all desktops counts as being on the current one
- Thumbnails of apps that quit are released (memory no longer grows over time)
- Thumbnails are captured only as large as a tile or switcher card shows them, and
  CoreGraphics no longer keeps converted copies: memory stays flat after hundreds of windows
- `Scripts/build-app.sh` stops instead of installing an ad-hoc signed copy when the signing
  identity is missing (that broke permissions); `ADHOC=1` allows it

## [0.1.0] — 2026-10-11

First version.

### Added

- Edge panel with live thumbnails of every window on every desktop, including full-screen spaces;
  click to focus that exact window
- Keep apps in the panel, group by app, drag to reorder, rename windows, drop files on a thumbnail
- Dock badges, audio chip, desktop / full-screen chip, focus ring, dimmed minimized windows
- Right-click menu with New Window, Arrange (halves, center, fill), Minimize / Restore, Hide,
  Close, Quit
- Left, top, bottom or right edge, size slider, optional background, one panel per display
- Auto-hide, or keep the panel visible and move windows out of its way
- Large live preview on hover, "only this desktop" filter, keyboard navigation (⌃⌥K) and a
  show/hide shortcut (⌃⌥D)
- ⌘Tab (or ⌥Tab) window switcher in most-recently-used order with `/` search and Q / H / W / M
  actions
- Workspaces: save and restore the set of open windows
- Privacy blur, menu bar quick controls, launch at login, onboarding for permissions
- 11 languages with an in-app language choice: English, Chinese (Simplified), Hindi, Spanish,
  Arabic, French, Bengali, Portuguese, Russian, Indonesian and Turkish
- App icon and a matching menu bar glyph

[Unreleased]: https://github.com/mertdurukan/docklane/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mertdurukan/docklane/releases/tag/v0.1.0
