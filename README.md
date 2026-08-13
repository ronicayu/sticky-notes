# Sticky Notes

A lightweight macOS sticky notes app that floats over every window, captures notes instantly via a global hotkey, and lets you tidy them up at your own pace.

Built with AppKit. Two dependencies: [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) for the global hotkeys and [`swift-markdown`](https://github.com/apple/swift-markdown) for the live-preview parser.

## Features

- **Global hotkeys**
  - `⌘⇧S` — new note (cursor focused, ready to type)
  - `⌘⇧F` — find a note (quick switcher)
  - `⌘⇧L` — open the Notes panel (active + archived)
  - `⌘⇧H` — hide/show all notes
- **Quick switcher** — `⌘⇧F` opens a Spotlight-style palette that searches titles, labels, and text across active *and* archived notes. Arrows to move, `↩` to open, `esc` to close. Type `#label` to narrow to a label. Picking an archived note restores it.
- **Floating windows** — every note stays above all other windows and follows you across Spaces.
- **Live Markdown** — `# heading`, `**bold**`, `*italic*`, `` `code` ``, `~~strike~~`, `- list`. Markers hide automatically when the cursor is not inside the element, like Obsidian / TickTick live preview.
- **Collapse / expand** — double-click a note's header to collapse it into a slim title bar; double-click again to expand.
- **Color picker** — 7 vibrant pastels (yellow, pink, orange, green, blue, purple, gray).
- **Auto-fade** — notes dim when not focused, snap back to full opacity on hover or focus.
- **Auto-save** — every edit, move, resize, recolor, and collapse is debounced and persisted to disk as a per-note JSON file.
- **Notes panel** — lists every active and archived note with previews, plus search, a label filter, and sorting by last edited / created / title / color. `↩` opens the selected note, `⌘⌫` archives it. Restore or permanently delete archived notes.
- **Labels** — tag a note by typing `#label`, with autocomplete. Hide a whole label's notes from the menu bar (**Show Labels**) to put `#work` away for the evening without archiving anything.
- **iCloud Drive sync** — opt in from Settings to sync notes across your Macs through iCloud Drive.
- **Obsidian vault mode** — point Settings at a vault and notes become `.md` files with YAML frontmatter, editable from Obsidian and synced back live.
- **Daily note** — open today's Obsidian daily note as a floating window; it rolls over to the new day on its own.
- **Launch at login** — toggle from Settings.
- **Local-first storage** — notes are plain files under `~/Library/Application Support/StickyNotes/` (or your iCloud Drive folder / Obsidian vault).

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

## Settings

Open with `⌘,` or **Settings…** in the menu bar. Three panes:

- **General** — default note color, launch at login, and rebindable hotkeys for every global shortcut.
- **Storage** — where notes live: local, iCloud Drive, or an Obsidian vault (Markdown mode).
- **Daily note** — the vault-relative path pattern and optional template.

Hotkeys are registered through `KeyboardShortcuts` and persisted to `UserDefaults`.

## Storage layout

```
~/Library/Application Support/StickyNotes/      (or iCloud Drive root, or <vault>/StickyNotes/)
├── notes/
│   └── {uuid}.json          # one file per active note
└── archive/
    └── {uuid}.json          # archived notes (closed via the × button)
```

Each file holds the note's content, position, size, color, labels, collapsed flag, and timestamps. Files are mutated atomically and per-note, so iCloud Drive can sync them without merge conflicts.

In Obsidian vault mode the same tree holds `.md` files named `{yyyy-MM-dd HHmmss}-{id}.md`, with the metadata in YAML frontmatter and the note body as plain Markdown — readable and editable directly in Obsidian. Edits made outside the app are picked up live.

## License

[MIT](LICENSE)
