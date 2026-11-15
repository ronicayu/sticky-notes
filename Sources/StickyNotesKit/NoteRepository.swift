import Foundation

/// What a `NoteDocument` needs from storage. `NoteStore` is the real one; the
/// protocol keeps the document constructible without a folder on disk.
protocol NoteRepository: AnyObject {
    /// Compare-and-swap: writes only if the file still has the fingerprint the
    /// caller last read or wrote; nil expects no file. See `SaveResult`.
    @discardableResult
    func save(_ note: Note, expecting fingerprint: Fingerprint?) -> SaveResult
    func loadNote(id: UUID, archived: Bool) -> Note?
    func snapshot(id: UUID, archived: Bool) -> NoteSnapshot?
    func archive(_ note: Note)
    func discardActive(_ note: Note)

    /// Whether text typed into a note whose active file is gone can be kept
    /// somewhere else. False for a repository that has only one file, which then
    /// has nowhere else to put it.
    var canKeepTextElsewhere: Bool { get }
    func whereIs(id: UUID) -> NoteStore.Whereabouts
    /// Compare-and-swap into the archive or the trash, where a note that left
    /// the active folder now lives.
    func save(_ note: Note, in folder: NoteStore.Folder, expecting fingerprint: Fingerprint) -> SaveResult
    /// A copy of a note that exists nowhere, written to the trash.
    func saveRecoveredCopy(of note: Note) -> Bool
    /// Whether `body` is exactly the text of an earlier write this Mac made to the
    /// note's file, not the newest. An outside writer that puts such text back is returning an
    /// older copy of the person's own text, not adding new text.
    func isEarlierOwnBody(_ body: String, ofNote id: UUID) -> Bool
    /// A document took `body` as the note's text: it started from the file, or an
    /// outside version replaced `previous`, what it showed. When that left out
    /// lines of the text this Mac last wrote, an earlier write of ours may hold the
    /// only copy of them, and what this Mac wrote stops vouching for itself.
    func textAdopted(_ body: String, over previous: String?, ofNote id: UUID)
}

extension NoteRepository {
    var canKeepTextElsewhere: Bool { false }
    func whereIs(id: UUID) -> NoteStore.Whereabouts { .unknown }
    func save(_ note: Note, in folder: NoteStore.Folder, expecting fingerprint: Fingerprint) -> SaveResult { .gone }
    func saveRecoveredCopy(of note: Note) -> Bool { false }
    func isEarlierOwnBody(_ body: String, ofNote id: UUID) -> Bool { false }
    func textAdopted(_ body: String, over previous: String?, ofNote id: UUID) {}
}

extension NoteStore: NoteRepository {
    var canKeepTextElsewhere: Bool { true }
}
