// View for DailyDocument.tla (model b, v2): this Mac's window, and iCloud with the other Mac.
const at = (o, k) => (Array.isArray(o) ? o[k - 1] : o[k]);

export const title = "Today's daily note on this Mac across midnight, with iCloud and the other Mac";

const mac = (s) => {
  if (s.shown < s.day) return s.armed ? "Showing yesterday's note, save pending" : "Showing yesterday's note";
  if (s.unavail) return "Waiting for today's note to download";
  if (s.hasPend) return "Outside edit held back";
  if (s.armed) return "Typing, save pending";
  if (s.shown === 1) return "Showing today's note (day 1)";
  return at(s.lf, 2).st === "none" ? "Today's note shown, file not created" : "Today's note open";
};

const cloud = (s) => {
  if (s.hasConf) return "A conflict version of today's file is waiting";
  if (s.dup) return "Today's file plus a numbered duplicate";
  if (s.hasBPend) return "The other Mac created today's file offline";
  if (!at(s.srvMain, 2)) return s.day === 1 ? "Day 1, no day-2 file" : "No file for today in iCloud";
  return "One file for today in iCloud";
};

export const state = (v) => ({ "This Mac": mac(v.s), iCloud: cloud(v.s) });

const labels = {
  Midnight: "the clock passes midnight",
  Type: "the person types in the daily note",
  RewriteTypo: "the person fixes a typo in today's line",
  ClickIntoText: "the person clicks into the daily note",
  GrabTitleBar: "the person grabs the daily note's title bar",
  SwitchAway: "the person switches to another window",
  SaveFires: "the save timer writes the daily note",
  PersonOpensToday: "the person opens today's note on purpose",
  Rollover: "the midnight timer or wake switches to today",
  UnavailableRetry: "the five-second retry looks for the download again",
  WatcherDelivers: "the file watcher reports the change",
  Upload: "iCloud uploads this Mac's file",
  Download: "iCloud downloads the newer file to this Mac",
  Evict: "iCloud turns the synced file into a placeholder",
  SelfConflict: "iCloud keeps an older save of this Mac as a conflict version",
  BEditsOnline: "the other Mac appends a line to the synced file",
  BEditsOffline: "the other Mac's offline edit arrives as a conflict version",
  BCreatesOffline: "the other Mac creates today's file offline",
  BUploads: "iCloud uploads the other Mac's new file",
  DiskFills: "this Mac's disk stops accepting writes",
  DiskFrees: "this Mac's disk accepts writes again",
};

export const step = (action) => labels[action] ?? action;

export const glossary = {
  person: "The owner, using Sticky Notes on this Mac.",
  "save timer": "The 0.4 second pause after typing before the daily note is written.",
  "file watcher": "The part of the app that notices the daily folder changed.",
  "other Mac": "The owner's second Mac, used in turn, not at the same time.",
  iCloud: "iCloud Drive, which syncs the vault between the Macs.",
  placeholder: "A hidden stand-in file iCloud leaves for a file it has not downloaded.",
  "conflict version": "A second copy of the file that iCloud keeps when two saves disagree.",
  "numbered duplicate": "A second file '<date> 2.md' that iCloud makes when two Macs create the same file.",
};
