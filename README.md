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
- **Links** — bare URLs and `[text](url)` render as links. `⌘`-click one to open it, or click it in a note that isn't focused. Pasting a URL over selected text turns the selection into a markdown link.
- **Editor shortcuts** — `⌘B` / `⌘I` / `⌘E` wrap the selection in bold, italic, or code (press again to unwrap). `⌘↩` turns the current line into a task, then checks and unchecks it. `⇥` / `⇧⇥` indent and outdent list items. `↩` continues a list and exits it on an empty item.
- **Task progress** — notes with checkboxes show a `2/5` count in the notes panel and quick switcher.
- **Collapse / expand** — double-click a note's header to collapse it into a slim title bar; double-click again to expand.
- **Color picker** — 7 vibrant pastels (yellow, pink, orange, green, blue, purple, gray).
- **Auto-fade** — notes dim when not focused, snap back to full opacity on hover or focus.
- **Dark mode** — notes follow the system appearance, with deep desaturated paper rather than dimmed pastels. The stored color name doesn't change, so a note is the same color on a light Mac and a dark one.
- **Tidy desk** — dragging a note snaps it to screen edges and to nearby notes (hold `⌥` to place it freely). **Arrange Notes** in the menu bar packs everything into a grid or a cascade.
- **Float level** — per note, from the palette button: float above every app (the default) or stick to the desktop, classic-Stickies style.
- **Auto-save** — every edit, move, resize, recolor, and collapse is debounced and persisted to disk as a per-note JSON file.
- **Notes panel** — lists every active and archived note with previews, plus search, a label filter, and sorting by last edited / created / title / color. `↩` opens the selected note, `⌘⌫` archives it. Restore or permanently delete archived notes.
- **Labels** — tag a note by typing `#label`, with autocomplete. Hide a whole label's notes from the menu bar (**Show Labels**) to put `#work` away for the evening without archiving anything.
- **iCloud Drive sync** — opt in from Settings to sync notes across your Macs through iCloud Drive.
- **Obsidian vault mode** — point Settings at a vault and notes become `.md` files with YAML frontmatter, editable from Obsidian and synced back live.
- **Daily note** — open today's Obsidian daily note as a floating window; it rolls over to the new day on its own.
- **Launch at login** — toggle from Settings.
- **Recoverable delete** — "Delete permanently" moves a note to a **Trash** tab in the notes panel, where it stays put-back-able for 30 days before being swept on launch.
- **Conflict-safe sync** — when two Macs edit the same note before syncing, the versions are merged rather than one silently winning: the newest leads and every other version's text is appended under a dated divider. Labels are unioned.
- **Accessibility** — icon-only controls carry VoiceOver labels, and Reduce Motion and Reduce Transparency are respected: animations become instant, and unfocused notes stay fully opaque.
- **Local-first storage** — notes are plain files under `~/Library/Application Support/StickyNotes/` (or your iCloud Drive folder / Obsidian vault).

## Install

Grab the latest `StickyNotes.app` from the [Releases](../../releases) page, drag it into `/Applications`, and launch it.

Because the released build is ad-hoc signed (no Apple Developer account), macOS will block the first launch. Either:

- Right-click the app → **Open** → confirm, or
- Open **System Settings → Privacy & Security**, scroll down, and click **"Open Anyway"** for StickyNotes.

If you do have a Developer ID, `build-app.sh` will sign and notarize properly, and that block goes away:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=notary-profile \
./scripts/build-app.sh
```

(`NOTARY_PROFILE` comes from `xcrun notarytool store-credentials`. Omit it to sign without notarizing.)

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

## Automation

Sticky Notes registers a `stickynotes://` URL scheme, so Raycast, Alfred, Shortcuts, or a shell script can drive it:

```bash
open "stickynotes://new?text=buy%20milk&color=blue&labels=home,errands"
open "stickynotes://new?title=Standup&body=blocked%20on%20the%20migration"
open "stickynotes://search?q=groceries"   # opens the quick switcher, pre-filled
open "stickynotes://daily"                # opens today's daily note
```

`text` and `body` are interchangeable, as are `search` and `find`. Labels are normalized the same way typed ones are, unknown parameters are ignored, and `+` decodes as a space.

There's also a **New Sticky Note** entry in every app's Services menu that turns the current selection into a note, and `⌥⌘⇧V` makes a note from the clipboard — including images, which are saved as attachments.

Services and the URL scheme both need the built `.app` bundle; neither works under bare `swift run`, which has no `Info.plist` for the system to read.

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
├── archive/
│   └── {uuid}.json          # archived notes (closed via the × button)
├── attachments/             # images and files pasted into notes
└── .trash/
    └── {uuid}.json          # deleted notes, purged after 30 days
```

Each file holds the note's content, position, size, color, labels, collapsed flag, and timestamps. Files are mutated atomically and per-note, so iCloud Drive can sync them without merge conflicts.

In Obsidian vault mode the same tree holds `.md` files named `{yyyy-MM-dd HHmmss}-{id}.md`, with the metadata in YAML frontmatter and the note body as plain Markdown — readable and editable directly in Obsidian. Edits made outside the app are picked up live.

## License

[MIT](LICENSE)
