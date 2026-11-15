import CryptoKit
import Foundation

/// The exact bytes of one note file. A document keeps the fingerprint of the
/// file it last read or wrote and hands it back with its next save; the store
/// writes only if the file still has those bytes.
///
/// Separate from `WriteLineage`'s hash on purpose. The lineage hashes the text
/// a merge keeps (body, title, labels) so iCloud's older copies of our own saves
/// can be told apart from other people's text. A fingerprint hashes the whole
/// file, geometry and timestamps included, because any change to the file
/// means the writer has not seen it. Neither is derived from the other.
struct Fingerprint: Hashable {
    let digest: String

    init(of data: Data) {
        digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A note together with the fingerprint of the bytes it was parsed from, read
/// from disk and never from the cache, so the two always describe one file.
struct NoteSnapshot {
    let note: Note
    let fingerprint: Fingerprint
}

enum SaveError: Error {
    /// The file exists but cannot be read or parsed, so nothing can be judged
    /// about it and it is not overwritten.
    case unreadableOnDisk
}

enum SaveResult {
    /// The file now holds the note; the fingerprint is of what was written.
    case saved(Fingerprint)
    /// The file is not what the writer last saw, or it exists when the writer
    /// expected to create it. Nothing was written. `fingerprint` describes
    /// `onDisk`: merge into it, then save again expecting that fingerprint.
    case conflict(onDisk: Note, fingerprint: Fingerprint)
    /// The note's file was deleted, archived or renamed away. Nothing was
    /// written, because that would resurrect it.
    case gone
    /// Nothing reached disk, or the file on disk could not be checked.
    case failed(Error)
}
