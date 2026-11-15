import Foundation

/// What a `NoteDocument` needs from storage. `NoteStore` is the real one; the
/// protocol keeps the document constructible without a folder on disk.
protocol NoteRepository: AnyObject {
    @discardableResult
    func save(_ note: Note) -> SaveResult
    func loadNote(id: UUID, archived: Bool) -> Note?
    func snapshot(id: UUID, archived: Bool) -> NoteSnapshot?
    func archive(_ note: Note)
    func discardActive(_ note: Note)
}

extension NoteStore: NoteRepository {}
