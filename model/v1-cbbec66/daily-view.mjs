// View for DailyRollover.tla (model b): one region per Mac, one for iCloud.
export const title = "Today's daily note on two Macs across midnight";

const mac = (s, m) => {
  const d = s.shown[m];
  if (d < s.day) return "Showing yesterday's note";
  if (s.unavail[m]) return "Waiting for today's note to download";
  if (s.hasPend[m]) return "Outside edit held back";
  if (s.armed[m]) return "Typing, save pending";
  const f = s.lf[m][d];
  if (d === 1) return "Showing today's note (day 1)";
  if (f.st === "none") return "Today's note shown, file not created";
  return "Today's note open";
};

const cloud = (s) => {
  if (!s.srvMain[2]) return s.day === 1 ? "Day 1, no day-2 file" : "No file for today in iCloud";
  if (s.dup) return "Today's file plus a numbered duplicate";
  return "One file for today in iCloud";
};

export const state = (v) => ({ "Mac A": mac(v.s, "A"), "Mac B": mac(v.s, "B"), iCloud: cloud(v.s) });

const labels = {
  Midnight: "the clock passes midnight",
  Type: "the person types in the daily note",
  ClickIntoText: "the person clicks into the daily note",
  GrabTitleBar: "the person grabs the daily note's title bar",
  SwitchAway: "the person switches to another window",
  SaveFires: "the save timer writes the daily note",
  PersonOpensToday: "the person opens today's note from the menu",
  Rollover: "the midnight timer or wake switches to today",
  UnavailableRetry: "the five-second retry reloads today's note",
  WatcherDelivers: "the file watcher reports the change",
  DupGone: "iCloud removes the trashed duplicate",
  Upload: "iCloud uploads the local change",
  Download: "iCloud downloads the newer file",
  Evict: "iCloud evicts the file to free space",
};
export const step = (action) => labels[action] ?? action;

export const glossary = {
  person: "The owner, at whichever Mac they are using.",
  "daily note": "The vault file for today's date, shown in its own floating window.",
  "save timer": "The pause after typing before the daily note is written.",
  "file watcher": "The part of the app that notices the daily folder changed.",
  "numbered duplicate": "'<date> 2.md', which iCloud makes when two Macs each create the same new file.",
  "outside edit": "A change to the file from the other Mac or Obsidian.",
  evicts: "iCloud replaces the local file with a placeholder until it is read again.",
  "five-second retry": "The reload the app schedules while it waits for a download.",
};
