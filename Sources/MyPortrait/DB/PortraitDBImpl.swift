import Foundation
import GRDB
import os.log

/// `PortraitDB` 协议的真正实现。actor 隔离的 `DatabasePool`（WAL 模式 →
/// 多 reader + 单 writer 不阻塞），跑 `DBSchema.migrator()` 完成 schema。
///
/// 默认路径：`~/.portrait/portrait.sqlite`。测试可注入 `:memory:`。
///
/// 写入策略：所有方法都 `try await dbPool.write { ... }`，actor 保证只有一个
/// writer 同时跑，WAL 允许 reader 并发读不阻塞。
actor PortraitDBImpl: PortraitDB {

    private let logger = Logger(subsystem: "com.myportrait.db", category: "impl")

    /// 内部可见的 pool 引用。SearchEngine 实现共用此 pool（WAL 下多 reader 安全）。
    /// `nonisolated let` —— DatabasePool 是 Sendable，跨 actor 边界传零成本。
    nonisolated let dbPool: DatabasePool

    init(path: String = Storage.portraitDBPath) throws {
        // 确保父目录存在（首启时 ~/.portrait/ 可能还没建好）。
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var config = Configuration()
        config.prepareDatabase { db in
            // WAL：写不阻塞读，崩溃恢复用 .wal 文件
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            // NORMAL：WAL 下足够安全（FULL 慢 10×），系统/电源故障最多丢最近一次提交
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            // 默认 SQLite 不强制外键，必须显式开
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            // mmap_size:256MB 虚拟地址空间映射 DB 文件,读 query 走 mmap
            // 直接读页,免去 read syscall + buffer copy。TimelineSidebar /
            // OCR 文本搜索这种大表读密集场景能快 2-5x。注:虚拟内存,
            // 实际物理内存按需 page-in。
            try db.execute(sql: "PRAGMA mmap_size = 268435456")
            // cache_size:负值 = KB,-64000 = 64MB page cache。默认 ~2MB
            // 对几百 MB 大表完全不够,JOIN / FTS5 重排都得反复 page-in。
            try db.execute(sql: "PRAGMA cache_size = -65536")
            // 注册 Foundation 后端的 ICU 分词器，FTS5 表才能识别 tokenizer="foundation_icu"。
            // 见 FoundationTokenizer.swift —— Foundation enumerateSubstrings(.byWords)
            // 在 Darwin 上是 ICU-backed，等价于"直接用 ICU 分词器"。
            db.add(tokenizer: FoundationTokenizer.self)
        }

        self.dbPool = try DatabasePool(path: path, configuration: config)
        try DBSchema.migrator().migrate(self.dbPool)
        logger.info("PortraitDB opened: \(path, privacy: .public)")
    }

    // MARK: - P1: 屏幕帧

    func insertFrame(_ record: FrameRecord) async throws -> Int64 {
        try await dbPool.write { db in
            var row = FrameRow.fromRecord(record)
            try row.insert(db)
            return row.id ?? 0
        }
    }

    func insertFrameWithOCR(_ record: FrameRecord, ocr: OCRResult?) async throws -> Int64 {
        let ocrFields = try Self.encodeOCRFields(ocr)
        return try await dbPool.write { db in
            var row = FrameRow.fromRecord(record, ocr: ocrFields)
            try row.insert(db)
            return row.id ?? 0
        }
    }

    func updateFrameOCR(frameId: Int64, ocr: OCRResult) async throws {
        let ocrFields = try Self.encodeOCRFields(ocr)
        try await dbPool.write { db in
            try db.execute(
                sql: """
                UPDATE frames
                SET full_text = :fullText, ocr_words_json = :wordsJson,
                    ocr_confidence = :confidence, text_source = :textSource
                WHERE id = :frameId
                """,
                arguments: [
                    "fullText": ocrFields?.fullText,
                    "wordsJson": ocrFields?.wordsJson,
                    "confidence": ocrFields?.confidence,
                    "textSource": ocrFields?.textSource,
                    "frameId": frameId,
                ]
            )
        }
    }

    // MARK: - P3: MP4 压缩

    func framesToCompact(olderThanMs: Int64, limit: Int) async throws -> [FrameForCompaction] {
        let (frames, deadIds): ([FrameForCompaction], [Int64]) = try await dbPool.read { db in
            let sql = """
            SELECT id, timestamp_ms, snapshot_path, device_name
            FROM frames
            WHERE snapshot_path IS NOT NULL
              AND timestamp_ms < :olderThanMs
            ORDER BY device_name, timestamp_ms
            LIMIT :limit
            """
            // dict-form StatementArguments —— 绕过 [Int64,Int64] 数组字面量
            // 走 [any DatabaseValueConvertible] 的隐式 existential 转换
            // (该路径在 Swift runtime _getWitnessTable 偶发死循环,
            // 真实卡死 sample 拍到过)。
            let rows = try Row.fetchAll(
                db, sql: sql,
                arguments: ["olderThanMs": olderThanMs, "limit": Int64(limit)])
            var frames: [FrameForCompaction] = []
            var dead: [Int64] = []
            for row in rows {
                guard let id: Int64 = row["id"],
                      let ts: Int64 = row["timestamp_ms"],
                      let rawPath: String = row["snapshot_path"],
                      let device: String = row["device_name"]
                else { continue }
                // resolve to absolute. File missing on disk → 死行:JPG 不会
                // 自己回来(磁盘满期间写盘失败但行照插 / 损坏被跳过后删除 /
                // 用户手动删过日目录),收集起来下面统一置 NULL。
                if let path = AssetPath.resolve(rawPath) {
                    frames.append(FrameForCompaction(
                        id: id, timestampMs: ts, snapshotPath: path, deviceName: device
                    ))
                } else {
                    dead.append(id)
                }
            }
            return (frames, dead)
        }

        // 死行中和:不置 NULL 的话,死行按最老时间戳**永久霸占 LIMIT 窗口最
        // 前端**,每 5 分钟被重复查出/stat/丢弃;攒满 limit 后查询永远返回空
        // 的有效集 → 新 JPG 再也不被压缩,磁盘失控且无告警。置 NULL 后行上
        // 的 OCR 文本保留(与 mediaOnly retention 的终态一致)。
        //
        // 护栏:这一批**全是**死行且量不小 → 八成是系统性的文件不可达(自定义
        // 数据目录在外置盘上没挂载之类),不是真死行,不动,只告警。
        if !deadIds.isEmpty {
            if frames.isEmpty, deadIds.count > 50 {
                logger.warning("framesToCompact: all \(deadIds.count, privacy: .public) candidate JPGs missing on disk — looks systemic (unmounted volume?), not marking dead rows")
            } else {
                try await dbPool.write { db in
                    var start = 0
                    while start < deadIds.count {
                        let end = min(start + 500, deadIds.count)   // 999 绑定变量上限,分批
                        let batch = Array(deadIds[start..<end])
                        start = end
                        let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                        // 动态变长 IN 子句:显式 StatementArguments 包装(铁律)。
                        try db.execute(
                            sql: "UPDATE frames SET snapshot_path = NULL WHERE id IN (\(placeholders))",
                            arguments: StatementArguments(batch)
                        )
                    }
                }
                logger.warning("framesToCompact: neutralized \(deadIds.count, privacy: .public) dead frame row(s) (snapshot_path set but file missing)")
            }
        }
        return frames
    }

    func replaceFramesWithVideoChunk(
        chunk: VideoChunkRecord,
        frames: [(frameId: Int64, offsetMs: Int)]
    ) async throws -> Int64 {
        let chunkRow = VideoChunkRow(
            id: nil,
            filePath: AssetPath.normalize(chunk.filePath),
            deviceName: chunk.deviceName,
            fps: chunk.fps,
            startTsMs: chunk.startTsMs,
            endTsMs: chunk.endTsMs,
            frameCount: chunk.frameCount,
            createdAtMs: Self.nowMs()
        )
        return try await dbPool.write { db in
            var row = chunkRow
            try row.insert(db)
            let chunkId = row.id ?? 0
            // 批量 UPDATE frames，预编译语句循环。
            let stmt = try db.makeStatement(sql: """
                UPDATE frames
                SET video_chunk_id = :chunkId, offset_ms = :offset, snapshot_path = NULL
                WHERE id = :frameId
                """)
            for (frameId, offset) in frames {
                try stmt.execute(arguments: ["chunkId": chunkId, "offset": Int64(offset), "frameId": frameId])
            }
            return chunkId
        }
    }

    // MARK: - P4: 音频

    func insertAudioChunk(_ record: AudioChunkRecord) async throws -> Int64 {
        try await dbPool.write { db in
            var row = AudioChunkRow(
                id: nil,
                filePath: AssetPath.normalize(record.filePath),
                recordedAtMs: record.recordedAtMs,
                durationS: record.durationS,
                device: record.device,
                isInput: record.isInput,
                status: record.status.rawValue,
                createdAtMs: Self.nowMs()
            )
            try row.insert(db)
            return row.id ?? 0
        }
    }

    func updateAudioChunkStatus(chunkId: Int64, status: AudioChunkStatus) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE audio_chunks SET status = :status WHERE id = :chunkId",
                arguments: ["status": status.rawValue, "chunkId": chunkId]
            )
        }
    }

    func insertTranscription(_ record: TranscriptionRecord) async throws {
        try await dbPool.write { db in
            var row = TranscriptionRow(
                id: nil,
                audioChunkId: record.audioChunkId,
                startS: record.startS,
                endS: record.endS,
                text: record.text,
                speakerId: record.speakerId,
                engine: record.engine,
                transcribedAtMs: record.transcribedAtMs
            )
            try row.insert(db)
        }
    }

    func pendingAudioChunks(limit: Int) async throws -> [AudioChunkRecord] {
        try await dbPool.read { db in
            let rows = try AudioChunkRow
                .filter(Column("status") == AudioChunkStatus.pending.rawValue)
                .order(Column("recorded_at_ms"))
                .limit(limit)
                .fetchAll(db)
            return rows.map { row -> AudioChunkRecord in
                // 文件存在 → resolve 出绝对路径;不存在 → 用原始路径放行。
                // **绝不静默过滤缺文件的 chunk** —— 否则它的 status 永远不变、永远卡在
                // pending 占着队列计数(僵尸 chunk)。放行让它进 transcribeOne,读不出
                // → 标 done 退出队列。
                let path = AssetPath.resolve(row.filePath) ?? row.filePath
                return AudioChunkRecord(
                    id: row.id,
                    filePath: path,
                    recordedAtMs: row.recordedAtMs,
                    durationS: row.durationS,
                    device: row.device,
                    isInput: row.isInput,
                    status: AudioChunkStatus(rawValue: row.status) ?? .pending
                )
            }
        }
    }

    func audioBacklogStats() async throws -> (pendingCount: Int, oldestRecordedAtMs: Int64?) {
        try await dbPool.read { db in
            // 单次查询拿 COUNT + MIN,索引扫描代价 ~ms 级。pending 表 ~1e3
            // 量级时也不会成为热点(Driver 30s 一次)。
            let row = try Row.fetchOne(
                db,
                sql: "SELECT COUNT(*) AS cnt, MIN(recorded_at_ms) AS oldest FROM audio_chunks WHERE status = :status",
                arguments: ["status": AudioChunkStatus.pending.rawValue]
            )
            let count: Int = row?["cnt"] ?? 0
            let oldest: Int64? = row?["oldest"]
            return (count, count > 0 ? oldest : nil)
        }
    }

    func recordAudioChunkFailure(chunkId: Int64) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE audio_chunks SET status = :status, retry_count = retry_count + 1 WHERE id = :chunkId",
                arguments: ["status": AudioChunkStatus.failed.rawValue, "chunkId": chunkId]
            )
        }
    }

    func resetInProgressAudioChunks() async throws -> Int {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE audio_chunks SET status = :newStatus WHERE status = :oldStatus",
                arguments: ["newStatus": AudioChunkStatus.pending.rawValue, "oldStatus": AudioChunkStatus.inProgress.rawValue]
            )
            return db.changesCount
        }
    }

    func resetRetryableFailedAudioChunks() async throws -> Int {
        try await dbPool.write { db in
            // retry_count < 3：重试上限，超过的保持 failed 不再重跑。
            try db.execute(
                sql: "UPDATE audio_chunks SET status = :newStatus WHERE status = :oldStatus AND retry_count < 3",
                arguments: ["newStatus": AudioChunkStatus.pending.rawValue, "oldStatus": AudioChunkStatus.failed.rawValue]
            )
            return db.changesCount
        }
    }

    // MARK: - 孤儿媒体清扫(CompactionWorker 启动期)

    func referencedSnapshotPaths(in paths: [String]) async throws -> Set<String> {
        try await referencedPaths(column: "snapshot_path", table: "frames", paths: paths)
    }

    func referencedVideoPaths(in paths: [String]) async throws -> Set<String> {
        try await referencedPaths(column: "file_path", table: "video_chunks", paths: paths)
    }

    /// column/table 由上面两个调用方写死,不接受外部输入(无注入面)。
    private func referencedPaths(column: String, table: String, paths: [String]) async throws -> Set<String> {
        guard !paths.isEmpty else { return [] }
        return try await dbPool.read { db in
            var found = Set<String>()
            // SQLite 默认绑定变量上限 999 → 分批。动态变长 IN 子句显式
            // StatementArguments 包装(铁律,不能用数组字面量)。
            var start = 0
            while start < paths.count {
                let end = min(start + 500, paths.count)
                let batch = Array(paths[start..<end])
                start = end
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let rows = try String.fetchAll(
                    db,
                    sql: "SELECT \(column) FROM \(table) WHERE \(column) IN (\(placeholders))",
                    arguments: StatementArguments(batch)
                )
                found.formUnion(rows)
            }
            return found
        }
    }

    // MARK: - 跨通道转录去重(外放回录,见 TranscriptDeduper)

    func transcriptionsForDedup(isInput: Bool, fromMs: Int64, toMs: Int64) async throws -> [TranscriptDeduper.Segment] {
        try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id AS tid, t.text AS text, t.speaker_id AS speakerId,
                       ac.recorded_at_ms AS recMs, t.start_s AS startS, t.end_s AS endS
                FROM audio_transcriptions t
                JOIN audio_chunks ac ON ac.id = t.audio_chunk_id
                WHERE ac.is_input = :isInput
                  AND ac.recorded_at_ms >= :fromMs AND ac.recorded_at_ms <= :toMs
                """, arguments: ["isInput": isInput, "fromMs": fromMs, "toMs": toMs])
            return rows.map { row in
                let recMs: Int64 = row["recMs"]
                let startS: Double = row["startS"]
                let endS: Double = row["endS"]
                return TranscriptDeduper.Segment(
                    id: row["tid"],
                    absStartMs: recMs + Int64(startS * 1000),
                    absEndMs: recMs + Int64(endS * 1000),
                    speakerId: row["speakerId"],
                    text: row["text"]
                )
            }
        }
    }

    func deleteTranscriptions(ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        try await dbPool.write { db in
            // 动态变长 IN 子句:显式 StatementArguments 包装(铁律,不能用数组字面量)。
            // dbPool 在 init 时注册了 FoundationTokenizer,transcriptions_fts 的
            // 同步删除触发器在这条连接上能跑。
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM audio_transcriptions WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
        }
    }

    func audioChunkTimeRangeMs() async throws -> (minMs: Int64, maxMs: Int64)? {
        try await dbPool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT MIN(recorded_at_ms) AS lo, MAX(recorded_at_ms) AS hi FROM audio_chunks")
            guard let row else { return nil }
            let lo: Int64? = row["lo"]
            let hi: Int64? = row["hi"]
            guard let lo, let hi else { return nil }   // 空表时 MIN/MAX 为 NULL
            return (lo, hi)
        }
    }

    // MARK: - 说话人识别（speaker diarization）

    /// 余弦相似度阈值。> 此值判定同一说话人（对齐 screenpipe 的 0.45）。
    private static let speakerMatchThreshold: Float = 0.45
    /// 判别裕度:命中者必须比「最强异名候选」高出这么多,否则判 ambiguous —— 防
    /// Joy/Stan 声纹接近时把边界段标反(宁可留空也别认错)。
    private static let speakerMargin: Float = 0.10
    /// 每个说话人最多保留的样本向量数。
    private static let maxEmbeddingsPerSpeaker = 10
    /// centroid 指数移动平均的有效计数上限——防止老说话人 centroid 僵化。
    private static let centroidEMACap = 50

    func matchSpeaker(embedding: [Float], model: String) async throws -> SpeakerMatch {
        try await dbPool.read { db in
            // **best-of-N 匹配**(对齐 screenpipe `get_speaker_from_embedding`):
            // 每个说话人取「存的多条 embedding + 质心」里**最接近的一条**的相似度。
            //
            // 为什么不只用质心:质心是平均值,太严。同一个人在不同条件下(干净训练
            // 录音 vs 嘈杂真实采集 vs 系统音频)声纹方差大,跟平均质心的余弦会掉到
            // 阈值以下 → 不匹配 → 不停建新簇(碎片化)。比「某条同条件样本」才抓得住。
            // screenpipe #2969 治的就是这个「输出音频堆出一堆重复簇」。
            // 过度合并的风险用下面的判别裕度(margin)挡:跟两个不同人都接近就留空。
            var best: [Int64: (name: String?, sim: Float)] = [:]
            // 1) 质心 —— 覆盖没存样本的说话人(刚训练 / seeded)。
            let cRows = try Row.fetchAll(db, sql: """
                SELECT id, name, centroid FROM speakers
                WHERE hallucination = 0 AND centroid IS NOT NULL AND embedding_model = :model
                """, arguments: ["model": model])
            for row in cRows {
                guard let blob: Data = row["centroid"], let vec = blob.asFloats,
                      vec.count == embedding.count else { continue }
                let id: Int64 = row["id"]
                let sim = VectorMath.cosineSimilarity(embedding, vec)
                if sim > (best[id]?.sim ?? -2) { best[id] = (row["name"], sim) }
            }
            // 2) 每条存的样本,取最接近的(best-of-N)。
            let eRows = try Row.fetchAll(db, sql: """
                SELECT e.speaker_id AS sid, s.name AS name, e.embedding AS emb
                FROM speaker_embeddings e JOIN speakers s ON s.id = e.speaker_id
                WHERE s.hallucination = 0 AND s.embedding_model = :model
                """, arguments: ["model": model])
            for row in eRows {
                guard let blob: Data = row["emb"], let vec = blob.asFloats,
                      vec.count == embedding.count else { continue }
                let id: Int64 = row["sid"]
                let sim = VectorMath.cosineSimilarity(embedding, vec)
                if sim > (best[id]?.sim ?? -2) { best[id] = (row["name"], sim) }
            }
            let cands: [(id: Int64, name: String?, sim: Float)] = best.compactMap {
                $0.value.sim > Self.speakerMatchThreshold ? ($0.key, $0.value.name, $0.value.sim) : nil
            }
            guard let winner = cands.max(by: { $0.sim < $1.sim }) else { return .none }
            // 判别裕度:找「跟 winner 不同名(= 不同人)」的最强候选。同名簇(同一人被
            // 拆成多簇)不算竞争。异名候选跟 winner 的相似度差 < margin → 两人分不开
            // → .ambiguous(别硬猜、也别当新人 enroll,留空标签)。
            let rival = cands
                .filter { $0.id != winner.id && !Self.sameSpeakerName($0.name, winner.name) }
                .map(\.sim).max()
            if let rival, winner.sim - rival < Self.speakerMargin {
                return .ambiguous
            }
            return .matched(winner.id)
        }
    }

    /// 两个 speaker 名是否同一人(忽略大小写/首尾空白)。任一无名 → 当作不同人
    /// (保守:无名簇不跟具名簇算"同人")。
    private static func sameSpeakerName(_ a: String?, _ b: String?) -> Bool {
        guard let x = a?.trimmingCharacters(in: .whitespaces).lowercased(), !x.isEmpty,
              let y = b?.trimmingCharacters(in: .whitespaces).lowercased(), !y.isEmpty
        else { return false }
        return x == y
    }

    func enrollSpeaker(embedding: [Float], model: String) async throws -> Int64 {
        let blob = Data(floats: embedding)
        let now = Self.nowMs()
        return try await dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO speakers (name, centroid, embedding_count, hallucination, created_at_ms, updated_at_ms, embedding_model)
                VALUES (NULL, :blob, 1, 0, :createdAt, :updatedAt, :model)
                """, arguments: ["blob": blob, "createdAt": now, "updatedAt": now, "model": model])
            let sid = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO speaker_embeddings (speaker_id, embedding, created_at_ms) VALUES (:sid, :blob, :createdAt)
                """, arguments: ["sid": sid, "blob": blob, "createdAt": now])
            return sid
        }
    }

    func addEmbeddingToSpeaker(speakerId: Int64, embedding: [Float]) async throws {
        let now = Self.nowMs()
        try await dbPool.write { db in
            guard let row = try Row.fetchOne(db, sql:
                "SELECT centroid, embedding_count FROM speakers WHERE id = :speakerId", arguments: ["speakerId": speakerId])
            else { return }
            let count: Int = row["embedding_count"] ?? 0
            let centroid: [Float]
            if let blob: Data = row["centroid"], let c = blob.asFloats, c.count == embedding.count {
                centroid = c
            } else {
                centroid = embedding
            }
            // centroid 指数移动平均，有效计数上限 centroidEMACap。
            let eff = Float(min(count, Self.centroidEMACap))
            var next = [Float](repeating: 0, count: embedding.count)
            for i in 0..<embedding.count {
                next[i] = (centroid[i] * eff + embedding[i]) / (eff + 1)
            }
            VectorMath.l2Normalize(&next)
            try db.execute(sql: """
                UPDATE speakers SET centroid = :centroid, embedding_count = embedding_count + 1, updated_at_ms = :updatedAt
                WHERE id = :speakerId
                """, arguments: ["centroid": Data(floats: next), "updatedAt": now, "speakerId": speakerId])
            try db.execute(sql:
                "INSERT INTO speaker_embeddings (speaker_id, embedding, created_at_ms) VALUES (:speakerId, :embedding, :createdAt)",
                arguments: ["speakerId": speakerId, "embedding": Data(floats: embedding), "createdAt": now])
            // 样本超上限 → 删掉最接近 centroid 的（最冗余）。
            let embRows = try Row.fetchAll(db, sql:
                "SELECT id, embedding FROM speaker_embeddings WHERE speaker_id = :speakerId", arguments: ["speakerId": speakerId])
            if embRows.count > Self.maxEmbeddingsPerSpeaker {
                var closest: (id: Int64, sim: Float)?
                for r in embRows {
                    guard let blob: Data = r["embedding"], let v = blob.asFloats,
                          v.count == next.count else { continue }
                    let sim = VectorMath.cosineSimilarity(next, v)
                    if sim > (closest?.sim ?? -2) { closest = (r["id"], sim) }
                }
                if let c = closest {
                    try db.execute(sql: "DELETE FROM speaker_embeddings WHERE id = :id", arguments: ["id": c.id])
                }
            }
        }
    }

    func nameSpeakerIfUnnamed(speakerId: Int64, name: String) async throws {
        let now = Self.nowMs()
        try await dbPool.write { db in
            try db.execute(sql: """
                UPDATE speakers SET name = :name, updated_at_ms = :updatedAt
                WHERE id = :speakerId AND (name IS NULL OR name = '')
                """, arguments: ["name": name, "updatedAt": now, "speakerId": speakerId])
        }
    }

    // MARK: - Retention

    func mediaPathsBefore(ms: Int64, excludeUntranscribedAudio: Bool) async throws -> RetentionFileList {
        try await dbPool.read { db in
            // Pull raw paths from each table, then resolve. Files that
            // already vanished off disk are dropped — retention has
            // nothing to delete for them.
            let rawSnapshots = try String.fetchAll(db, sql: """
                SELECT snapshot_path FROM frames
                WHERE snapshot_path IS NOT NULL AND timestamp_ms < :ms
                """, arguments: ["ms": ms])
            let rawVideoChunks = try String.fetchAll(db, sql: """
                SELECT file_path FROM video_chunks
                WHERE end_ts_ms < :ms
                """, arguments: ["ms": ms])
            // wait_for_transcription 开 → 只删「转录完(done)或永久放弃
            // (failed 且重试次数耗尽,见 resetRetryableFailedAudioChunks 的
            // retry_count < 3)」的音频;pending / in_progress / 还会重试的
            // failed 留到转录产出文本后的下一轮。
            // **id 一并取回**:applyRetention 按这批 id 快照删行,不二次求值
            // status(文件清单与行删除之间 status 会被转录管线推进)。
            let audioFilter = excludeUntranscribedAudio
                ? "AND (status = :done OR (status = :failed AND retry_count >= 3))"
                : ""
            let audioRows = try Row.fetchAll(db, sql: """
                SELECT id, file_path FROM audio_chunks
                WHERE recorded_at_ms < :ms \(audioFilter)
                """, arguments: excludeUntranscribedAudio
                    ? ["ms": ms,
                       "done": AudioChunkStatus.done.rawValue,
                       "failed": AudioChunkStatus.failed.rawValue]
                    : ["ms": ms])
            // id 不跟文件存在性挂钩:文件已丢的行照样要删(否则永远残留)。
            let audioIds = audioRows.compactMap { $0["id"] as Int64? }
            let rawAudio = audioRows.compactMap { $0["file_path"] as String? }

            return RetentionFileList(
                snapshotPaths: rawSnapshots.compactMap(AssetPath.resolve),
                videoChunkPaths: rawVideoChunks.compactMap(AssetPath.resolve),
                audioPaths: rawAudio.compactMap(AssetPath.resolve),
                audioChunkIds: audioIds
            )
        }
    }

    // MARK: - 读（UI 用）

    func framesForDay(_ day: Date) async throws -> [TimelineFrame] {
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let startMs = Int64(dayStart.timeIntervalSince1970 * 1000)
        let endMs = Int64(dayEnd.timeIntervalSince1970 * 1000)

        return try await dbPool.read { db in
            // **screenpipe import 的帧 snapshot_path/video_chunk_id 都 NULL**
            // 但 device_name='imported',加进 WHERE 让 timeline UI 也显示。
            // 渲染层 TimelineView 有 NoMediaPlaceholder 兜底无媒体帧。
            let sql = """
            SELECT f.id, f.timestamp_ms, f.app_name, f.window_name, f.browser_url,
                   f.snapshot_path, v.file_path AS video_path, f.offset_ms,
                   COALESCE(v.fps, 1.0) AS fps
            FROM frames f
            LEFT JOIN video_chunks v ON v.id = f.video_chunk_id
            WHERE (f.snapshot_path IS NOT NULL
                   OR f.video_chunk_id IS NOT NULL
                   OR f.device_name = 'imported')
              AND f.timestamp_ms >= :startMs AND f.timestamp_ms < :endMs
            ORDER BY f.timestamp_ms ASC
            """
            let rows = try Row.fetchAll(
                db, sql: sql,
                arguments: ["startMs": startMs, "endMs": endMs])
            return rows.map { row -> TimelineFrame in
                let id: Int64 = row["id"] ?? 0
                let ts: Int64 = row["timestamp_ms"] ?? 0
                let app: String = row["app_name"] ?? ""
                let win: String = row["window_name"] ?? ""
                let url: String? = row["browser_url"]
                // Paths in DB are stored relative to Storage.rootURL.
                // AssetPath.resolve gives back absolute paths + nil-out
                // anything whose file is missing — so callers can treat the
                // value as "ready to load or nothing's there".
                let snap: String? = AssetPath.resolve(row["snapshot_path"])
                let vpath: String? = AssetPath.resolve(row["video_path"])
                let offsetMs: Int = row["offset_ms"] ?? 0
                let fps: Double = row["fps"] ?? 1.0

                return TimelineFrame(
                    id: id,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(ts) / 1000),
                    appName: app,
                    windowName: win,
                    browserUrl: url,
                    snapshotPath: snap,
                    videoPath: vpath,
                    videoOffsetMs: Int(offsetMs),
                    videoFps: fps
                )
            }
        }
    }

    func activeAppsAround(timestamp: Date, windowSeconds: TimeInterval) async throws -> [ActiveAppEntry] {
        let ms = Int64(timestamp.timeIntervalSince1970 * 1000)
        let startMs = ms - Int64(windowSeconds * 1000)
        let endMs = ms + Int64(windowSeconds * 1000)

        return try await dbPool.read { db in
            let sql = """
            SELECT app_name,
                   COALESCE(window_name, '') AS window_name,
                   COALESCE(browser_url, '') AS browser_url,
                   MAX(timestamp_ms) AS latest
            FROM frames
            WHERE timestamp_ms >= :startMs AND timestamp_ms <= :endMs
              AND app_name IS NOT NULL AND app_name != ''
            GROUP BY app_name, window_name
            ORDER BY latest DESC
            LIMIT 30
            """
            let rows = try Row.fetchAll(
                db, sql: sql,
                arguments: ["startMs": startMs, "endMs": endMs])
            return rows.map { row -> ActiveAppEntry in
                let app: String = row["app_name"] ?? ""
                let win: String = row["window_name"] ?? ""
                let url: String = row["browser_url"] ?? ""
                let latest: Int64 = row["latest"] ?? 0
                return ActiveAppEntry(
                    appName: app,
                    windowName: win,
                    browserUrl: url.isEmpty ? nil : url,
                    lastSeen: Date(timeIntervalSince1970: TimeInterval(latest) / 1000)
                )
            }
        }
    }

    func audioTranscriptsAround(
        timestamp: Date,
        beforeSeconds: TimeInterval,
        afterSeconds: TimeInterval
    ) async throws -> [AudioTranscriptEntry] {
        let ms = Int64(timestamp.timeIntervalSince1970 * 1000)
        let startMs = ms - Int64(beforeSeconds * 1000)
        let endMs = ms + Int64(afterSeconds * 1000)

        return try await dbPool.read { db in
            // JOIN audio_chunks 拿 recorded_at_ms + device；LEFT JOIN speakers 拿名字
            // (hallucination=0 才出名,匿名/误判簇出 NULL → 上层回退 "Speaker <id>")。
            let sql = """
            SELECT c.recorded_at_ms AS ts_ms,
                   t.text,
                   c.device,
                   c.is_input,
                   t.speaker_id,
                   s.name AS speaker_name,
                   COALESCE(t.start_s, 0) AS start_s
            FROM audio_transcriptions t
            JOIN audio_chunks c ON c.id = t.audio_chunk_id
            LEFT JOIN speakers s ON s.id = t.speaker_id AND s.hallucination = 0
            WHERE c.recorded_at_ms >= :startMs AND c.recorded_at_ms <= :endMs
              AND t.text IS NOT NULL AND t.text != ''
            ORDER BY c.recorded_at_ms ASC
            LIMIT 60
            """
            let rows = try Row.fetchAll(
                db, sql: sql,
                arguments: ["startMs": startMs, "endMs": endMs])
            return rows.map { row -> AudioTranscriptEntry in
                let tsMs: Int64 = row["ts_ms"] ?? 0
                let text: String = row["text"] ?? ""
                let device: String = row["device"] ?? ""
                let isInput: Bool = row["is_input"] ?? true
                let speakerId: Int? = row["speaker_id"]
                let speakerName: String? = row["speaker_name"]
                let startS: Double = row["start_s"] ?? 0
                return AudioTranscriptEntry(
                    timestamp: Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000),
                    text: text,
                    device: device,
                    isInput: isInput,
                    speakerId: speakerId,
                    speakerName: speakerName,
                    startS: startS
                )
            }
        }
    }

    func applyRetention(mode: RetentionMode, beforeMs: Int64, audioChunkIds: [Int64]) async throws -> RetentionStats {
        try await dbPool.write { db in
            switch mode {
            case .mediaOnly:
                // 1. NULL 掉 frames 的媒体引用（保留 OCR 文本）
                try db.execute(sql: """
                    UPDATE frames
                    SET snapshot_path = NULL, video_chunk_id = NULL, offset_ms = NULL
                    WHERE timestamp_ms < :beforeMs
                    """, arguments: ["beforeMs": beforeMs])
                let framesAffected = db.changesCount

                // 2. 删旧的 video_chunks 行（frames 已经 NULL 了 video_chunk_id 引用）
                try db.execute(sql: """
                    DELETE FROM video_chunks WHERE end_ts_ms < :beforeMs
                    """, arguments: ["beforeMs": beforeMs])
                let videoChunksDeleted = db.changesCount

                // mediaOnly：audio_chunks 保留（含 transcriptions 关联），文件由 worker 删。
                return RetentionStats(
                    framesAffected: framesAffected,
                    videoChunksDeleted: videoChunksDeleted,
                    audioChunksDeleted: 0
                )

            case .everything:
                try db.execute(sql: """
                    DELETE FROM frames WHERE timestamp_ms < :beforeMs
                    """, arguments: ["beforeMs": beforeMs])
                let framesAffected = db.changesCount

                try db.execute(sql: """
                    DELETE FROM video_chunks WHERE end_ts_ms < :beforeMs
                    """, arguments: ["beforeMs": beforeMs])
                let videoChunksDeleted = db.changesCount

                // CASCADE 删 transcriptions。只删 mediaPathsBefore 同一轮快照
                // 里的 id —— 不重新按 status/时间求值,保证「删的行」恰是
                // 「文件清单里那批 chunk」,与盘上删除严格一致。
                var audioChunksDeleted = 0
                var start = 0
                while start < audioChunkIds.count {
                    let end = min(start + 500, audioChunkIds.count)   // 999 绑定变量上限,分批
                    let batch = Array(audioChunkIds[start..<end])
                    start = end
                    let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                    // 动态变长 IN 子句:显式 StatementArguments 包装(铁律)。
                    try db.execute(
                        sql: "DELETE FROM audio_chunks WHERE id IN (\(placeholders))",
                        arguments: StatementArguments(batch)
                    )
                    audioChunksDeleted += db.changesCount
                }

                return RetentionStats(
                    framesAffected: framesAffected,
                    videoChunksDeleted: videoChunksDeleted,
                    audioChunksDeleted: audioChunksDeleted
                )
            }
        }
    }

    // MARK: - 私有

    /// ocr.words 编码器复用 —— updateFrameOCR 每帧 OCR 写盘都调一次,别每次新建。
    /// JSONEncoder 默认配置,encode 线程安全。
    private static let ocrWordsEncoder = JSONEncoder()

    /// 把 OCRResult 拆成 4 个列要存的字符串/数字。失败抛错（JSON encode 不应该失败）。
    private static func encodeOCRFields(_ ocr: OCRResult?) throws -> OCRFields? {
        guard let ocr else { return nil }
        let wordsJson: String?
        if ocr.words.isEmpty {
            wordsJson = nil   // 空数组省一行 JSON ("[]")，让 NULL 表示"无 bbox"
        } else {
            let data = try Self.ocrWordsEncoder.encode(ocr.words)
            wordsJson = String(data: data, encoding: .utf8)
        }
        return OCRFields(
            fullText: ocr.fullText,
            wordsJson: wordsJson,
            confidence: ocr.avgConfidence,
            textSource: ocr.textSource.rawValue
        )
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

/// 编码后的 OCR 列值组合。文件作用域，PortraitDBImpl 和 FrameRow 扩展共用。
fileprivate struct OCRFields {
    let fullText: String
    let wordsJson: String?
    let confidence: Double
    let textSource: String
}

// MARK: - FrameRow / FrameRecord 转换

private extension FrameRow {
    /// 从 FrameRecord 构造行（OCR 字段空）。用于 `insertFrame` 占位路径。
    static func fromRecord(_ record: FrameRecord) -> FrameRow {
        FrameRow(
            id: nil,
            timestampMs: record.timestampMs,
            appName: record.appName,
            windowName: record.windowName,
            browserUrl: record.browserUrl,
            focused: record.focused,
            deviceName: record.deviceName,
            snapshotPath: AssetPath.normalize(record.snapshotPath),
            videoChunkId: nil,
            offsetMs: nil,
            captureTrigger: record.captureTrigger,
            fullText: nil,
            ocrWordsJson: nil,
            ocrConfidence: nil,
            textSource: nil,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// 从 FrameRecord + OCR 字段构造行（一次性写入 + OCR 路径）。
    static func fromRecord(_ record: FrameRecord, ocr: OCRFields?) -> FrameRow {
        FrameRow(
            id: nil,
            timestampMs: record.timestampMs,
            appName: record.appName,
            windowName: record.windowName,
            browserUrl: record.browserUrl,
            focused: record.focused,
            deviceName: record.deviceName,
            snapshotPath: AssetPath.normalize(record.snapshotPath),
            videoChunkId: nil,
            offsetMs: nil,
            captureTrigger: record.captureTrigger,
            fullText: ocr?.fullText,
            ocrWordsJson: ocr?.wordsJson,
            ocrConfidence: ocr?.confidence,
            textSource: ocr?.textSource,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }
}
