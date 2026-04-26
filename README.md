# Sticky Notes

A lightweight macOS sticky notes app that floats over every window, captures notes instantly via a global hotkey, and lets you tidy them up at your own pace.

Built with SwiftUI + AppKit. No dependencies beyond `KeyboardShortcuts` for the global hotkey.

## Features

- **Global hotkeys**
  - `⌘⇧S` — new note (cursor focused, ready to type)
  - `⌘⇧L` — open the Notes panel (active + archived)
- **Floating windows** — every note stays above all other windows and follows you across Spaces.
- **Live Markdown** — `# heading`, `**bold**`, `*italic*`, `` `code` ``, `~~strike~~`, `- list`. Markers hide automatically when the cursor is not inside the element, like Obsidian / TickTick live preview.
- **Collapse / expand** — double-click a note's header to collapse it into a slim title bar; double-click again to expand.
- **Color picker** — 7 vibrant pastels (yellow, pink, orange, green, blue, purple, gray).
- **Auto-fade** — notes dim when not focused, snap back to full opacity on hover or focus.
- **Auto-save** — every edit, move, resize, recolor, and collapse is debounced and persisted to disk as a per-note JSON file.
- **Notes panel** — lists every active and archived note with previews. Click an active note to bring its window forward; restore or permanently delete archived notes.
- **iCloud Drive sync** — opt in via the menu bar to sync notes across your Macs through iCloud Drive.
- **Launch at login** — toggle from the menu bar.
- **Local-first storage** — notes are plain JSON files under `~/Library/Application Support/StickyNotes/` (or your iCloud Drive folder if sync is enabled).

## Install

Grab the latest `StickyNotes.app` from the [Releases](../../releases) page, drag it into `/Applications`, and launch it.

Because the app is ad-hoc signed (no Apple Developer account), macOS will block the first launch. Either:

- Right-click the app → **Open** → confirm, or
- Open **System Settings → Privacy & Security**, scroll down, and click **"Open Anyway"** for StickyNotes.

The first time you trigger a global hotkey, macOS may also ask you to grant input monitoring or accessibility permissions.

## Build from source

Requirements: macOS 13+, Xcode 15+ (or matching Swift toolchain).

```bash
git clone https://github.com/ronicayu/sticky-notes.git
cd sticky-notes

# Run during development (no .app bundle, runs the binary directly)
swift run

# Produce a distributable .app bundle in ./build
./scripts/build-app.sh

# Install
cp -R build/StickyNotes.app /Applications/
```

## Hotkey configuration

Hotkeys are registered through [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) and persisted to `UserDefaults`. They default to `⌘⇧S` and `⌘⇧L` but can be re-bound at runtime by extending the menu bar with a `KeyboardShortcuts.Recorder` (not included in the current UI).

## Storage layout

```
~/Library/Application Support/StickyNotes/      (or iCloud Drive root)
├── notes/
│   └── {uuid}.json          # one file per active note
└── archive/
    └── {uuid}.json          # archived notes (closed via the × button)
```

Each JSON contains the note's content, position, size, color, collapsed flag, and timestamps. Files are mutated atomically and per-note, which means iCloud Drive can sync them without merge conflicts.

## License

[MIT](LICENSE)
