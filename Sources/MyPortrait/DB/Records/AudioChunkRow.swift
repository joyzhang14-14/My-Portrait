import Foundation
import GRDB

struct AudioChunkRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var id: Int64?
    var filePath: String
    var recordedAtMs: Int64
    var durationS: Double
    var device: String
    var isInput: Bool
    /// 文本形式存：pending/in_progress/done/failed。AudioChunkStatus.rawValue。
    var status: String
    var createdAtMs: Int64

    static let databaseTableName = "audio_chunks"

    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
