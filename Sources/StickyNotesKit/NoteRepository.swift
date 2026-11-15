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
}

extension NoteStore: NoteRepository {}
