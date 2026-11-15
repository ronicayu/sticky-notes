// View for NoteDocument.tla (model a, v2). Labels are in the note owner's words.
const len = (x) => (Array.isArray(x) ? x.length : Object.keys(x).length);

export const title = "One sticky note: typing, saving, outside edits, conflict versions, archive and Trash";

export const state = (v) => {
  const s = v.s;
  if (s.app === "quit") return "App quit, note on disk";
  const where = s.loc.length === 0 ? "none" : s.loc[0];
  if (s.win === "closed") {
    if (where === "archive") return "Note in the archive, window closed";
    if (where === "trash") return "Note in the Trash, window closed";
    if (where === "none") return "No note file, window closed";
    return "Note on disk, window closed";
  }
  if (where === "archive") return "Window open, note moved to the archive";
  if (where === "trash") return "Window open, note moved to the Trash";
  if (where === "none")
    return s.hasFile ? "Window open, note file gone"
      : len(s.buf) === 0 ? "New note, no file yet" : "New note with text, not written yet";
  if (s.diskFull) return "Disk not accepting writes, note open";
  if (!s.listed) return "Note file cannot be read";
  if (s.hasConf)
    return s.confKind === "own" || s.confKind === "self"
      ? "Older own save kept as a conflict version"
      : "Other Mac's conflict version waiting";
  if (s.hasPend) return "Outside edit held back";
  if (s.armed)
    return s.focus === "typing" ? "Typing, save pending"
      : s.focus === "titlebar" ? "Typing, save pending, caret out of the text"
      : "Save pending, person in another window";
  if (s.unseen) return "File changed, window not told yet";
  return "Note open, nothing pending";
};

export const group = (v) => {
  const s = v.s;
  if (s.app === "quit" || s.win === "closed" || !s.loc.includes("active")) return "stored";
  if (s.hasConf || s.hasPend || s.unseen || !s.listed) return "syncing";
  return "editing";
};

export const colors = { editing: "blue", syncing: "orange", stored: "teal" };

const labels = {
  Type: "the person types in the note",
  EraseAll: "the person deletes all the text",
  ClickIntoText: "the person clicks into the text",
  GrabTitleBar: "the person grabs the note's title bar",
  SwitchAway: "the person switches to another window",
  SaveFires: "the half-second save timer writes the note",
  CloseNote: "the person clicks the note's close button",
  PanelArchive: "the person archives the note from the notes panel",
  Quit: "the person quits the app",
  Relaunch: "the person launches the app",
  Restore: "the person restores the note from the archive",
  DeleteForever: "the person deletes the note permanently",
  RestoreFromTrash: "the person restores the note from the Trash",
  MonthPasses: "the calendar moves past the 30-day retention",
  WindowHears: "the file watcher reports the change to the window",
  Reconcile: "the desk checks its windows against the notes folder",
  ConflictSweep: "the conflict sweep merges the conflict version",
  ExternalEdit: "Obsidian or the other Mac appends a line to the file",
  ExternalMetaWrite: "Obsidian rewrites the note's properties, not its text",
  ObsidianStaleRewrite: "Obsidian rewrites the file from an older copy",
  ExternalConflict: "the other Mac's offline edit arrives as a conflict version",
  ICloudSelfConflict: "iCloud keeps an older save as a conflict version",
  ExternalMove: "the other Mac archives, trashes or deletes the file",
  FileVanishes: "iCloud hides or locks the file for a while",
  FileReturns: "iCloud shows the file again",
  PlaceholderAppears: "iCloud leaves a download placeholder in the notes folders",
  PlaceholderGoes: "the placeholder finishes downloading",
  DiskFills: "the disk stops accepting writes",
  DiskFrees: "the disk accepts writes again",
};

export const step = (action, from, to) => {
  if (action === "Done") return null;
  const a = from.s, b = to.s;
  if (action === "WindowHears" || action === "ConflictSweep") {
    const base = labels[action];
    if (b.hasPend && !a.hasPend) return `${base} [the window holds it back]`;
    if (b.hasPend) return `${base} [it replaces the held-back edit]`;
    return `${base} [the window shows it]`;
  }
  if (action === "Reconcile") {
    if (a.win === "open" && b.win === "closed") return "the desk closes the window of a note that is gone";
    if (a.win === "closed" && b.win === "open") return "the desk opens a window for a note that is back";
    return "the desk finds nothing to change";
  }
  if (action === "CloseNote")
    return b.win === "open" ? "the person clicks the note's close button [the close is refused]" : labels[action];
  return labels[action] ?? action;
};

export const glossary = {
  person: "The owner, using Sticky Notes on this Mac.",
  "save timer": "The half-second pause after typing before the note is written to its file.",
  "file watcher": "The part of the app that notices the note's file changed on disk.",
  desk: "The app part that keeps one window per active note.",
  "outside edit": "A change to the note's file made by Obsidian, the other Mac or iCloud.",
  "conflict version": "A second copy of the file that iCloud keeps when two saves disagree.",
  "conflict sweep": "The app step that merges conflict versions back into the file.",
  "other Mac": "The owner's second Mac, used in turn, not at the same time.",
  Obsidian: "The notes app that shares the vault folder.",
  iCloud: "iCloud Drive, which syncs the vault between the Macs.",
  placeholder: "A hidden stand-in file iCloud leaves for a file it has not downloaded.",
  archive: "Closed notes, still listed in the notes panel.",
  Trash: "Notes deleted from the archive, kept 30 days.",
};
