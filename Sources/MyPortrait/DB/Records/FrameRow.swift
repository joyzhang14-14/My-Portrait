import Foundation
import GRDB

/// `frames` 表行。Codable + GRDB protocol，**不是 Record 子类**（GRDB 7 推荐）。
///
/// 列名靠 `convertToSnakeCase` 自动映射：`timestampMs ⇌ timestamp_ms`。
/// 字段顺序 = 表创建顺序，便于直接对照 Schema.swift。
struct FrameRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var id: Int64?
    var timestampMs: Int64
    var appName: String
    var windowName: String?
    var browserUrl: String?
    var focused: Bool
    var deviceName: String
    var snapshotPath: String?
    var videoChunkId: Int64?
    var offsetMs: Int?
    var captureTrigger: String?
    var fullText: String?
    var ocrWordsJson: String?
    var ocrConfidence: Double?
    var textSource: String?
    var createdAtMs: Int64
    var windowsJson: String?

    static let databaseTableName = "frames"

    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy = .convertToSnakeCase
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy = .convertFromSnakeCase

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
