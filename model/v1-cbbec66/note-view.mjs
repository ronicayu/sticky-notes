// View for NotePersistence.tla (model a). Labels are in the note owner's words.
export const title = "One sticky note: typing, saving, outside edits, archive and Trash";

export const state = (v) => {
  const s = v.s;
  if (s.app === "quit") return "App quit, note on disk";
  const loc = s.loc;
  if (!loc.includes("active")) {
    if (loc.includes("archive")) return "Note in the archive";
    if (loc.includes("trash")) return "Note in the Trash";
    return "Note file deleted";
  }
  if (s.win === "closed") return "Note on disk, window closed";
  if (!s.listed) return "Note file briefly missing";
  if (s.hasConflict)
    return s.conflictKind === "self"
      ? "Older own save kept as a conflict version"
      : "Other Mac's conflict version waiting";
  if (s.hasPending) return "Outside edit held back";
  if (s.armed)
    return s.focus === "typing" ? "Typing, save pending"
      : s.focus === "titlebar" ? "Typing, save pending, caret out of the text"
      : "Save pending, person in another window";
  if (s.unseen) return "File changed, window not told yet";
  return "Note open, nothing pending";
};

export const group = (v) => {
  const s = v.s;
  if (s.app === "quit" || !s.loc.includes("active")) return "stored";
  if (s.win === "closed") return "stored";
  if (s.hasConflict || s.hasPending || s.unseen || !s.listed) return "syncing";
  return "editing";
};

export const colors = { editing: "blue", syncing: "orange", stored: "teal" };

const labels = {
  Type: "the person types in the note",
  ClickIntoText: "the person clicks into the text",
  GrabTitleBar: "the person grabs the note's title bar",
  SwitchAway: "the person switches to another window",
  SaveFires: "the half-second save timer writes the note",
  CloseNote: "the person clicks the note's close button",
  Quit: "the person quits the app",
  Relaunch: "the person launches the app",
  Restore: "the person restores the note from the archive",
  DeleteForever: "the person deletes the note permanently",
  RestoreFromTrash: "the person restores the note from the Trash",
  MonthPasses: "the calendar moves past the 30-day retention",
  PanelArchive: "the person archives the note from the notes panel",
  WatcherDelivers: "the file watcher reports the change",
  ConflictSweep: "the conflict sweep merges the conflict version",
  ExternalEdit: "Obsidian or the other Mac edits the file",
  ExternalConflict: "the other Mac's edit arrives as a conflict version",
  ICloudSelfConflict: "iCloud keeps an older save as a conflict version",
  ObsidianStaleRewrite: "Obsidian rewrites the file from an older copy",
  ExternalArchive: "the other Mac archives the note",
  OtherMacDiscardsEmpty: "the other Mac discards the note as empty",
  FileVanishes: "iCloud hides the file for a moment",
  FileReturns: "iCloud shows the file again",
};

export const step = (action, from, to) => {
  if (action === "Done") return null;
  const a = from.s, b = to.s;
  // Closing an empty note and switching away from an untouched empty one both
  // discard it, so they share one label.
  const discarded = a.loc.includes("active") && !b.loc.includes("active") && !b.loc.includes("archive");
  if ((action === "SwitchAway" || action === "CloseNote") && discarded)
    return "the person leaves an empty note by closing it or switching away";
  if (action === "WatcherDelivers" || action === "ConflictSweep") {
    const base = labels[action];
    if (a.win === "open" && b.win === "closed") return "the file watcher reports the note gone";
    if (a.win === "closed" && b.win === "open") return "the file watcher reports the note back";
    if (b.hasPending && !a.hasPending) return `${base} [the window holds it back]`;
    if (b.hasPending) return `${base} [it replaces the held-back edit]`;
    return `${base} [the window shows it]`;
  }
  if (action === "CloseNote")
    return `${labels[action]} [the note has text]`;
  return labels[action] ?? action;
};

export const glossary = {
  person: "The owner, using Sticky Notes on this Mac.",
  "save timer": "The half-second pause after typing before the note is written to its file.",
  "file watcher": "The part of the app that notices the note's file changed on disk.",
  "outside edit": "A change to the note's file made by Obsidian, the other Mac or iCloud.",
  "conflict version": "A second copy of the file that iCloud keeps when two saves disagree.",
  "conflict sweep": "The app step that merges conflict versions back into the file and appends a 'Conflicted copy' section.",
  "other Mac": "The owner's second Mac, running Sticky Notes on the same vault.",
  Obsidian: "The notes app that shares the vault folder.",
  iCloud: "iCloud Drive, which syncs the vault between the Macs.",
  archive: "Closed notes, still listed in the notes panel.",
  Trash: "Notes deleted from the archive, kept 30 days.",
};
