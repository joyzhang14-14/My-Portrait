import Foundation
import GRDB

struct VideoChunkRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var id: Int64?
    var filePath: String
    var deviceName: String
    var fps: Double
    var startTsMs: Int64
    var endTsMs: Int64
    var frameCount: Int
    var createdAtMs: Int64

    static let databaseTableName = "video_chunks"

    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
