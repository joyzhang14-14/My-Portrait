import GRDB

/// Centralised migrator. **追加策略**：永远 `registerMigration` 新版本，
/// 不修改已发布的版本。GRDB 自动按顺序应用、记进度。
///
/// 列名 snake_case 是 SQLite 习俗；Swift 字段保持 camelCase，靠 GRDB 的
/// `databaseColumnEncodingStrategy = .convertToSnakeCase` 自动映射。
///
/// 时间戳全部 INTEGER（UTC 毫秒），不用 ISO 字符串：索引快、不用解析、与
/// `Date(timeIntervalSince1970: ms/1000)` 一行互转。
enum DBSchema {

    static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()

        // ═══════════════════════════════════════════════════════════
        // v1 — 屏幕采集（frames + video_chunks + FTS5）
        // ═══════════════════════════════════════════════════════════
        m.registerMigration("v1_screen_capture") { db in

            // ── 视频块（P3 后由 CompactionWorker 写入）
            try db.create(table: "video_chunks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("file_path", .text).notNull()
                t.column("device_name", .text).notNull().defaults(to: "main")
                t.column("fps", .double).notNull().defaults(to: 1.0)
                t.column("start_ts_ms", .integer).notNull()      // UTC ms
                t.column("end_ts_ms", .integer).notNull()
                t.column("frame_count", .integer).notNull()
                t.column("created_at_ms", .integer).notNull()
            }
            try db.create(index: "idx_video_chunks_start_ts",
                          on: "video_chunks", columns: ["start_ts_ms"])

            // ── 帧元数据
            try db.create(table: "frames") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp_ms", .integer).notNull()      // UTC ms
                t.column("app_name", .text).notNull()
                t.column("window_name", .text)
                t.column("browser_url", .text)
                t.column("focused", .boolean).notNull().defaults(to: true)
                t.column("device_name", .text).notNull().defaults(to: "main")

                // P1: snapshot_path 填，video_chunk_id 为 NULL
                // P3: 压完 MP4 后反过来（snapshot_path NULL, video_chunk_id 填）
                t.column("snapshot_path", .text)
                t.column("video_chunk_id", .integer)
                    .references("video_chunks", onDelete: .setNull)
                t.column("offset_ms", .integer)

                t.column("capture_trigger", .text)                // app_switch/typing_pause/...
                t.column("full_text", .text)                      // OCR 或 AX 合并文本
                t.column("ocr_words_json", .text)                 // 词级 bbox JSON (overflow page 友好)
                t.column("ocr_confidence", .double)
                t.column("text_source", .text)                    // ocr/ax/unknown
                t.column("created_at_ms", .integer).notNull()
            }
            try db.create(index: "idx_frames_timestamp",
                          on: "frames", columns: ["timestamp_ms"])
            try db.create(index: "idx_frames_app",
                          on: "frames", columns: ["app_name"])
            try db.create(index: "idx_frames_video_chunk",
                          on: "frames", columns: ["video_chunk_id"])

            // ── FTS5 虚拟表，自动同步 frames(app_name, window_name, browser_url, full_text)。
            // 优先 ICU 分词（Unicode 词边界，中英混合更准）；不支持 ICU 的系统
            // 启动期自动降级 unicode61，由 PortraitDBImpl.init 处理重试。
            //
            // 这里写 unicode61 作 baseline：兼容所有 macOS sqlite3 版本，
            // 后续若 ICU 编进了系统 sqlite3 可以 v3_fts_to_icu migration 升级。
            try db.create(virtualTable: "frames_fts", using: FTS5()) { t in
                t.synchronize(withTable: "frames")
                // ICU-quality word segmentation via Foundation backend。
                // 见 FoundationTokenizer.swift —— enumerateSubstrings(.byWords)
                // 内部就是 ICU，CJK 词分（"力矩传感器" → 力矩 + 传感器）+ 英文
                // lowercase。运行前必须在 PortraitDBImpl 注册此分词器。
                t.tokenizer = FoundationTokenizer.tokenizerDescriptor()
                t.column("app_name")
                t.column("window_name")
                t.column("browser_url")
                t.column("full_text")
            }
        }

        // ═══════════════════════════════════════════════════════════
        // v2 — 音频采集 + 转录
        // ═══════════════════════════════════════════════════════════
        m.registerMigration("v2_audio_capture") { db in

            try db.create(table: "audio_chunks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("file_path", .text).notNull()
                t.column("recorded_at_ms", .integer).notNull()
                t.column("duration_s", .double).notNull()
                t.column("device", .text).notNull()               // default_microphone / system_loopback
                t.column("is_input", .boolean).notNull()
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("created_at_ms", .integer).notNull()
            }
            try db.create(index: "idx_audio_chunks_recorded",
                          on: "audio_chunks", columns: ["recorded_at_ms"])
            try db.create(index: "idx_audio_chunks_status",
                          on: "audio_chunks", columns: ["status"])

            try db.create(table: "audio_transcriptions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("audio_chunk_id", .integer).notNull()
                    .references("audio_chunks", onDelete: .cascade)
                t.column("start_s", .double).notNull()
                t.column("end_s", .double).notNull()
                t.column("text", .text).notNull()
                t.column("speaker_id", .integer)                  // NoopSpeakerDiarizer 永远 nil
                t.column("engine", .text).notNull().defaults(to: "whisperkit")
                t.column("transcribed_at_ms", .integer).notNull()
            }
            try db.create(index: "idx_transcriptions_chunk",
                          on: "audio_transcriptions", columns: ["audio_chunk_id"])
        }

        // ═══════════════════════════════════════════════════════════
        // v3 — transcriptions FTS5（用于全文搜索语音转录）
        // ═══════════════════════════════════════════════════════════
        m.registerMigration("v3_transcriptions_fts") { db in
            try db.create(virtualTable: "transcriptions_fts", using: FTS5()) { t in
                t.synchronize(withTable: "audio_transcriptions")
                t.tokenizer = FoundationTokenizer.tokenizerDescriptor()
                t.column("text")
            }
        }

        // ═══════════════════════════════════════════════════════════
        // v4 — 向量列（Phase 4 Hybrid 搜索）
        // ═══════════════════════════════════════════════════════════
        //
        // BLOB 列存 bge-m3 输出（1024 × Float32 = 4096 字节 / 行）。
        // NULL 表示还没 embed —— EmbeddingWorker 后台拉 NULL 的批量回填。
        //
        // SQLite overflow page 机制让 BLOB 不读时 0 成本：SELECT 其他列时
        // 这 ~4KB 不被加载进主行（只是 indirection 指针）。
        //
        // 不用 sqlite-vec：macOS 系统 sqlite3 关了 LOAD_EXTENSION。我们走
        // "BLOB 列 + Swift 端暴力 cosine"，~7000 向量微秒级。
        m.registerMigration("v4_embeddings") { db in
            try db.alter(table: "frames") { t in
                t.add(column: "embedding", .blob)
            }
            try db.alter(table: "audio_transcriptions") { t in
                t.add(column: "embedding", .blob)
            }
            // 部分索引：NULL 索引零开销但 IS NULL 查询超快
            // (EmbeddingWorker 频繁查"哪些行还没 embed")
            try db.execute(sql: """
                CREATE INDEX idx_frames_embedding_null ON frames(id) WHERE embedding IS NULL
                """)
            try db.execute(sql: """
                CREATE INDEX idx_transcriptions_embedding_null ON audio_transcriptions(id) WHERE embedding IS NULL
                """)
        }

        // ═══════════════════════════════════════════════════════════
        // v5 — 向量来源标识（embedding_model 列）
        // ═══════════════════════════════════════════════════════════
        //
        // 换 embedder（如 NLEmbedding-512 → bge-m3-1024）时，旧向量维度不同，
        // cosine 没法跟新向量比。这一列让 EmbeddingWorker 看出"这行的向量是哪
        // 个模型生成的"，model 不匹配就重算。SearchEngine 同理 filter。
        m.registerMigration("v5_embedding_model") { db in
            try db.execute(sql: "ALTER TABLE frames ADD COLUMN embedding_model TEXT")
            try db.execute(sql: "ALTER TABLE audio_transcriptions ADD COLUMN embedding_model TEXT")
        }

        return m
    }
}
