import Foundation
import GRDB

struct TranscriptionRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var id: Int64?
    var audioChunkId: Int64
    var startS: Double
    var endS: Double
    var text: String
    var speakerId: Int?
    var engine: String
    var transcribedAtMs: Int64

    static let databaseTableName = "audio_transcriptions"

    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
