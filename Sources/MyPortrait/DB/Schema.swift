import Foundation
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

        // ═══════════════════════════════════════════════════════════
        // v6 — 转录失败重试计数（retry_count）
        // ═══════════════════════════════════════════════════════════
        //
        // WhisperKit 转录失败时 chunk 标 failed。没这一列时 failed 是终态、
        // 永不重试，偶发错误（临时资源不足等）会永久丢掉转录文本。
        //
        // 有了 retry_count：失败时 +1，启动时把 failed AND retry_count < 3 的
        // 行回退 pending 重跑；retry_count >= 3 保持 failed 不再重试（有上限）。
        //
        // NOT NULL DEFAULT 0：ALTER ADD COLUMN 自动给现有行补 0。
        m.registerMigration("v6_audio_chunk_retry_count") { db in
            try db.alter(table: "audio_chunks") { t in
                t.add(column: "retry_count", .integer).notNull().defaults(to: 0)
            }
        }

        // ═══════════════════════════════════════════════════════════
        // v7 — 说话人识别（speakers + speaker_embeddings）
        // ═══════════════════════════════════════════════════════════
        //
        // 复刻 screenpipe：CAM++ 音色向量（512 维）+ 余弦聚类。
        //   - speakers：每个说话人一行，centroid = 运行平均向量（L2 归一化）。
        //   - speaker_embeddings：每个说话人最多保留 10 个样本向量，满了轮换掉
        //     最接近 centroid 的（保多样性）。
        //
        // 向量都存 BLOB（512 × Float32 = 2048 字节），跟 frames.embedding 一样
        // 走 Swift 端暴力 cosine，不依赖 sqlite-vec。
        // audio_transcriptions.speaker_id（v2 已有列）写入这里的 speakers.id。
        m.registerMigration("v7_speakers") { db in
            try db.create(table: "speakers") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text)                                  // NULL = 未命名簇
                t.column("centroid", .blob)                              // 512 float32，NULL 直到首个样本
                t.column("embedding_count", .integer).notNull().defaults(to: 0)
                t.column("hidden", .boolean).notNull().defaults(to: false) // 1 = 标记为幻听
                t.column("created_at_ms", .integer).notNull()
                t.column("updated_at_ms", .integer).notNull()
            }
            try db.create(table: "speaker_embeddings") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("speaker_id", .integer).notNull()
                    .references("speakers", onDelete: .cascade)
                t.column("embedding", .blob).notNull()                   // 512 float32
                t.column("created_at_ms", .integer).notNull()
            }
            try db.create(index: "idx_speaker_embeddings_speaker",
                          on: "speaker_embeddings", columns: ["speaker_id"])
        }

        // v8: memory-pipeline scheduler bookkeeping.
        // 一行一个 UTC 日，四个处理阶段各一状态列：
        //   raw   = 当天屏幕原始数据是否收齐（纯时间判定）
        //   event = backfill / EventBuilder 聚类
        //   impact= ImpactScorer 评分
        //   distill = PortraitDistiller 蒸馏
        // 每列状态机 idle → pending → in_progress → complete | failed | partial。
        // 全局同一时刻只允许一个 (date, processor) 处于 in_progress：
        //   active_processor 非空即"有处理器在跑"，配 heartbeat 做并发保护，
        //   checkpoint 存已处理 event id 列表用于崩溃续跑。
        m.registerMigration("v8_processing_log") { db in
            try db.create(table: "processing_log") { t in
                t.column("date", .text).primaryKey()              // UTC yyyy-MM-dd
                t.column("raw_status", .text).notNull().defaults(to: "idle")
                t.column("event_status", .text).notNull().defaults(to: "idle")
                t.column("impact_status", .text).notNull().defaults(to: "idle")
                t.column("distill_status", .text).notNull().defaults(to: "idle")
                t.column("active_processor", .text)               // NULL = 无锁
                t.column("checkpoint", .text)                     // JSON [event id]
                t.column("heartbeat_ms", .integer)                // UTC ms
                t.column("updated_at_ms", .integer).notNull().defaults(to: 0)
            }
            // distiller 改字段的审计日志，用于 debug / 潜在回滚。
            try db.create(table: "distill_changelog") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("entity_id", .text).notNull()            // portrait 文件相对路径
                t.column("field_name", .text).notNull()           // 现仅 "body"
                t.column("before", .text)
                t.column("after", .text)
                t.column("triggered_by_event_id", .text)
                t.column("llm_reasoning", .text)
                t.column("timestamp_ms", .integer).notNull()
            }
            try db.create(index: "idx_distill_changelog_entity",
                          on: "distill_changelog", columns: ["entity_id"])
        }

        // ═══════════════════════════════════════════════════════════
        // v9 — processing_log 失败重试计数（retry_count）
        // ═══════════════════════════════════════════════════════════
        //
        // 没这一列时 failed 是终态、永不封顶：反复崩溃的日会无限重试。
        // 有了 retry_count：每次失败（含崩溃恢复）+1，retry_count >= 3 转
        // dead_letter（status 列写 "dead_letter"），不再进入 7 天 cap 筛选。
        // budget_deferred（额度耗尽）不计入 retry_count。
        //
        // NOT NULL DEFAULT 0：ALTER ADD COLUMN 自动给现有行补 0。
        m.registerMigration("v9_processing_log_retry_count") { db in
            try db.alter(table: "processing_log") { t in
                t.add(column: "retry_count", .integer).notNull().defaults(to: 0)
            }
        }

        // ═══════════════════════════════════════════════════════════
        // v10 — typing capture（AX 订阅采集真实打字数据）
        // ═══════════════════════════════════════════════════════════
        //
        // 独立模块，跟 capture / backfill / impact / distill 流水线解耦。
        // TypingObserver 通过 Accessibility API 订阅 focused text element
        // 的值变化，diff 出 insert / delete / replace 写进这张表。
        // 共用同一个 portrait.sqlite，不另建文件。
        m.registerMigration("v10_typing_events") { db in
            try db.create(table: "typing_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp_ms", .integer).notNull()   // UTC ms
                t.column("bundle_id", .text).notNull()         // com.tinyspeck.slackmacgap
                t.column("app_name", .text)                    // "Slack"
                t.column("element_role", .text)                // AXTextField / AXTextArea / ...
                t.column("element_hint", .text)                // focused 元素 label / placeholder
                t.column("kind", .text).notNull()              // insert | delete | replace
                t.column("text", .text).notNull()              // 插入或删除的内容
                t.column("replaced_text", .text)               // replace 时被替换的原文，否则 NULL
                t.column("language_hint", .text)               // cjk | latin | mixed
            }
            try db.create(index: "idx_typing_events_ts",
                          on: "typing_events", columns: ["timestamp_ms"])
            try db.create(index: "idx_typing_events_bundle",
                          on: "typing_events", columns: ["bundle_id"])
            try db.create(index: "idx_typing_events_bundle_ts",
                          on: "typing_events", columns: ["bundle_id", "timestamp_ms"])
        }

        // ═══════════════════════════════════════════════════════════
        // v11 — typing_events 重塑（DROP 重建成最终 schema）
        // ═══════════════════════════════════════════════════════════
        //
        // v10 建的列结构（timestamp_ms / kind / replaced_text ...）是早期
        // diff 事件模型，跟最终的"一段连续输入即一条记录"设计不符。表里没有
        // 任何真实数据，所以直接 DROP 重建——不拷数据、不备份，最干净。
        //
        // 新模型：每条记录是一次输入会话（started_at_ms ~ ended_at_ms），
        // 带 thread_id 把同一上下文的多条串起来，text 是这段完整输入内容。
        m.registerMigration("v11_typing_events_reshape") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS typing_events")

            try db.create(table: "typing_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("started_at_ms", .integer).notNull()   // UTC ms，输入开始
                t.column("ended_at_ms", .integer).notNull()     // UTC ms，输入结束
                t.column("bundle_id", .text).notNull()          // com.tinyspeck.slackmacgap
                t.column("app_name", .text)                     // "Slack"
                t.column("window_title", .text)                 // 窗口标题
                t.column("url", .text)                          // 浏览器 URL（如有）
                t.column("element_role", .text)                 // AXTextField / AXTextArea / ...
                t.column("thread_id", .text).notNull()          // 同上下文串联用
                t.column("text", .text).notNull()               // 这段输入的完整内容
                t.column("char_count", .integer).notNull()      // text 字符数
                t.column("language_hint", .text)                // cjk | latin | mixed
                t.column("created_at_ms", .integer).notNull()   // UTC ms，写入时刻
            }

            // 索引带 DESC / partial(WHERE)，GRDB create(index:) 不好表达，
            // 直接 raw SQL（v4 已有此先例）。
            try db.execute(sql: """
                CREATE INDEX idx_typing_app ON typing_events(bundle_id, started_at_ms DESC)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_typing_time ON typing_events(started_at_ms DESC)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_typing_url ON typing_events(url) WHERE url IS NOT NULL
                """)
            try db.execute(sql: """
                CREATE INDEX idx_typing_thread ON typing_events(thread_id)
                """)
        }

        // ═══════════════════════════════════════════════════════════
        // v12 — typing_events edit_log（占位 / no-op）
        // ═══════════════════════════════════════════════════════════
        //
        // 这一槽位曾被一版 typing observer M4 实现占用（带 close_reason /
        // edit_log 的 session schema）。该实现有根本性 bug 已整体 revert。
        //
        // 但**线上库的 `grdb_migrations` 表已记录 `v12_typing_events_edit_log`
        // 这个 identifier**——GRDB 按 identifier 字符串去重，不可复用此名做新
        // 迁移（会被当成"已应用"直接跳过）。故保留一个同名空迁移：
        //   - 线上库：已应用 → 跳过；
        //   - 全新库：执行空 body（no-op），typing_events 维持 v11 形态，
        //     真正的重塑由紧随其后的 v13 完成。
        // 这样注册表与磁盘账本始终前缀一致，真正的工作全在 v13。
        m.registerMigration("v12_typing_events_edit_log") { _ in
            // 故意为空 —— 见上方注释。
        }

        // ═══════════════════════════════════════════════════════════
        // v13 — typing_events 重塑为 master record per app
        // ═══════════════════════════════════════════════════════════
        //
        // 新模型：一个 app 一条主记录（bundle_id 主键）。`text` 是用户在该
        // app 累积的最终输入内容，`edit_log` 是 commit/delete 的 JSON 流水。
        // 废弃 session / thread_id / close_reason 等概念。旧表数据全部是
        // buggy 数据，直接 DROP 重建——不迁移。
        m.registerMigration("v13_typing_events_master_record") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS typing_events")

            try db.create(table: "typing_events") { t in
                t.column("bundle_id", .text).primaryKey()        // 一个 app 一条
                t.column("text", .text).notNull().defaults(to: "")
                t.column("edit_log", .text).notNull().defaults(to: "[]")  // JSON [EditEntry]
                t.column("time_start", .integer).notNull()       // UTC ms，首次记录
                t.column("last_updated", .integer).notNull()     // UTC ms，最近 flush
                t.column("total_chars", .integer).notNull().defaults(to: 0)  // text.count
            }
        }

        // ═══════════════════════════════════════════════════════════
        // v14 — typing_events 重塑为 append-only event log
        // ═══════════════════════════════════════════════════════════
        //
        // v13 的 master-record-per-app（bundle_id 主键、UPSERT 累加）有两个
        // 同根缺陷：KI-1 中段编辑字符错位、KI-2 切窗口后大段删除丢失 ——
        // 根子都是「累加文本 ≠ 输入框真实内容」。
        //
        // v14 改成 event log：每次 flush INSERT 一条新 record，一条 record =
        // 一个 (app, element) 的一段输入 session。record immutable，不再 UPSERT。
        // 配套 splice 算法（baseline + 就地 splice）让 text 始终等于输入框真实
        // 内容。旧数据是 buggy 模型，直接 DROP 不迁移。
        m.registerMigration("v14_typing_events_event_log") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS typing_events")

            try db.create(table: "typing_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bundle_id", .text).notNull()
                t.column("element_hash", .integer).notNull()
                t.column("started_at", .integer).notNull()       // UTC ms
                t.column("ended_at", .integer).notNull()         // UTC ms
                t.column("text", .text).notNull()                // 本次 session 真实输入
                t.column("edit_log", .text).notNull()            // JSON [EditEntry]
                t.column("total_chars", .integer).notNull()
            }
            try db.execute(sql:
                "CREATE INDEX idx_typing_events_app ON typing_events(bundle_id)")
            try db.execute(sql:
                "CREATE INDEX idx_typing_events_app_element ON typing_events(bundle_id, element_hash)")
            try db.execute(sql:
                "CREATE INDEX idx_typing_events_time ON typing_events(started_at)")
        }

        // ═══════════════════════════════════════════════════════════
        // v15 — typing_events 加 continuation 锚点
        // ═══════════════════════════════════════════════════════════
        //
        // 一段输入因 5s 静默 / 切窗口被 flush 成多条 record，但其实是同一段
        // 连续编辑。v15 给 record 加两个锚点：`session_start`（这段 session
        // 开始时 element 的完整内容）、`end_value`（结束时的完整内容）。
        // 新 session flush 时，若它起点内容跟某条 record 的 end_value 首尾
        // 各 100 字都「接得上」→ 合并进那条 record（见 TypingRecordWriter）。
        m.registerMigration("v15_typing_events_continuation_anchors") { db in
            try db.alter(table: "typing_events") { t in
                t.add(column: "session_start", .text).notNull().defaults(to: "")
                t.add(column: "end_value", .text).notNull().defaults(to: "")
            }
        }

        // ═══════════════════════════════════════════════════════════
        // v16 — typing_events 记住自己剔除过的噪声段
        // ═══════════════════════════════════════════════════════════
        //
        // 黑名单（粘贴 / burst / 程序输出）只在内存里、有 1h TTL、app 重启即失。
        // continuation 合并时 `text` 从原始快照重算，若噪声段的黑名单条目已
        // 过期 → 噪声会复活进 `text`。`stripped`（JSON 字符串数组）让每条
        // record 记住自己实际剔掉过的段，重算时一并剔除，不靠内存黑名单存活。
        m.registerMigration("v16_typing_events_stripped") { db in
            try db.alter(table: "typing_events") { t in
                t.add(column: "stripped", .text).notNull().defaults(to: "[]")
            }
        }

        // ═══════════════════════════════════════════════════════════
        // v17 — typing_events 记浏览器 URL
        // ═══════════════════════════════════════════════════════════
        //
        // 浏览器 app 里，光按 bundle_id 分太粗（一个 Safari 混了所有页面）。
        // v17 加 `url` 列：浏览器 record 记下输入时所在页面的 URL（取自焦点
        // 窗口的 AXDocument，跟 frames.url 同路子）。非浏览器 url 为空。
        // Input 页据此把浏览器拆成 per-URL 分组。
        m.registerMigration("v17_typing_events_url") { db in
            try db.alter(table: "typing_events") { t in
                t.add(column: "url", .text).notNull().defaults(to: "")
            }
        }

        // ═══════════════════════════════════════════════════════════
        // v18 — processing_log 第五阶段:personality
        // ═══════════════════════════════════════════════════════════
        //
        // personality 是 distill 之后的最后一站,把 events / 其他 portrait /
        // 当天 OCR 三源汇聚成 personality concept。anchor-row 设计跟 distill
        // 一致(`_personality_anchor` 行,只用 `personality_status` 列)。
        // NOT NULL DEFAULT 'idle':现有行自动 idle。
        m.registerMigration("v18_processing_log_personality") { db in
            try db.alter(table: "processing_log") { t in
                t.add(column: "personality_status", .text).notNull().defaults(to: "idle")
            }
        }

        // ═══════════════════════════════════════════════════════════
        // v19 — keystroke_log:全局击键字符日志(写作采集 L3)
        // ═══════════════════════════════════════════════════════════
        //
        // KeystrokeCharLogger 写入。挂在跟 KeystrokeLedger 同一个 CGEventTap
        // callback,但职责拆分:ledger 只存 ts ring buffer 给 hasKeystroke 用,
        // char logger 抓 unicode 字符 + bundle_id 入 DB,给 LLM Pass 2 当 L3 输入。
        //
        // 中文 IME 的限制实测过:CGEventKeyboardGetUnicodeString 拿到的是
        // 拼音字母 + 选词数字键,**拿不到合成的汉字**。所以 keystroke_log 里
        // 中文 char 永远是 latin 字母,真中文得靠 typing_events / OCR。
        //
        // 详见 canvas-editor-capture-design-final.md §3.2, §9.1。
        m.registerMigration("v19_keystroke_log") { db in
            try db.create(table: "keystroke_log") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts_ms", .integer).notNull()
                t.column("bundle_id", .text).notNull()
                t.column("char", .text)                       // nullable for pure backspace
                t.column("is_backspace", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql:
                "CREATE INDEX idx_keystroke_log_ts ON keystroke_log(ts_ms)")
            try db.execute(sql:
                "CREATE INDEX idx_keystroke_log_app ON keystroke_log(bundle_id, ts_ms)")
        }

        // ═══════════════════════════════════════════════════════════
        // v20 — writing_records:LLM 融合后的最终写作记录
        // ═══════════════════════════════════════════════════════════
        //
        // Pass 2 Approve 后落地的表。Personality / Writing Style 分析以这里
        // 为输入源。raw 三张表(typing_events / keystroke_log / frames)仍各自
        // 独立保留,通过 reference_*_ids 反向链当训练对。
        //
        // source enum: "ax_cleaned"(普通 app) | "canvas_fusion"(canvas) | "merged"
        // prompt_id = sha256(prompt 文本)[..16],阶段三训练数据版本追踪。
        m.registerMigration("v20_writing_records") { db in
            try db.create(table: "writing_records") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("start_ts", .integer).notNull()
                t.column("end_ts", .integer).notNull()
                t.column("app", .text).notNull()
                t.column("url", .text)
                t.column("text", .text).notNull()
                t.column("edit_log", .text).notNull()         // JSON [{kind, text, ts}]
                t.column("confidence", .double).notNull()
                t.column("context_summary", .text)            // ≤ 100 chars
                t.column("source", .text).notNull()           // ax_cleaned | canvas_fusion | merged
                t.column("reference_typing_event_ids", .text) // JSON array
                t.column("reference_frame_ids", .text)        // JSON array
                t.column("reference_keystroke_range", .text)  // JSON {start, end}
                t.column("raw_output", .text)                 // LLM raw JSON
                t.column("prompt_id", .text)                  // sha256(prompt)[..16]
                t.column("created_at", .integer).notNull()
                t.column("worker_run_id", .text)
            }
            try db.execute(sql:
                "CREATE INDEX idx_writing_records_date ON writing_records(start_ts)")
            try db.execute(sql:
                "CREATE INDEX idx_writing_records_app ON writing_records(app)")
            try db.execute(sql:
                "CREATE INDEX idx_writing_records_run ON writing_records(worker_run_id)")
        }

        // ═══════════════════════════════════════════════════════════
        // v21 — writing_records_staged:Pending review 暂存
        // ═══════════════════════════════════════════════════════════
        //
        // worker 跑完先写这张表,等用户 Approve 才拷到 writing_records。
        // schema 跟 writing_records 一致 + 加 `date_utc` 字段方便按天 cleanup。
        // Reject 时按 worker_run_id / date_utc 清这张表的对应行。
        m.registerMigration("v21_writing_records_staged") { db in
            try db.create(table: "writing_records_staged") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("date_utc", .text).notNull()         // 'YYYY-MM-DD'
                t.column("start_ts", .integer).notNull()
                t.column("end_ts", .integer).notNull()
                t.column("app", .text).notNull()
                t.column("url", .text)
                t.column("text", .text).notNull()
                t.column("edit_log", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("context_summary", .text)
                t.column("source", .text).notNull()
                t.column("reference_typing_event_ids", .text)
                t.column("reference_frame_ids", .text)
                t.column("reference_keystroke_range", .text)
                t.column("raw_output", .text)
                t.column("prompt_id", .text)
                t.column("created_at", .integer).notNull()
                t.column("worker_run_id", .text).notNull()
            }
            try db.execute(sql:
                "CREATE INDEX idx_writing_records_staged_date ON writing_records_staged(date_utc)")
            try db.execute(sql:
                "CREATE INDEX idx_writing_records_staged_run ON writing_records_staged(worker_run_id)")
        }

        // ═══════════════════════════════════════════════════════════
        // v22 — writing_capture_runs:跑过的天 + 状态机
        // ═══════════════════════════════════════════════════════════
        //
        // 一行 = 一个 UTC 日期的处理记录。status 枚举:
        //   pending             — 该天有 raw 但没跑过 / 等下次 Run
        //   processing          — 正在跑(防并发)
        //   pending_review      — LLM 跑完了,staged 有数据,等 Approve/Reject
        //   approved            — Approve 了,数据已落 writing_records
        //   rejected_for_rerun  — Reject 了,raw 不删,下次 Run 重跑
        //   failed              — 跑失败,测试期改源码兜底
        //
        // 「未处理的天」query 看 final 设计文档 §9.2。
        m.registerMigration("v22_writing_capture_runs") { db in
            try db.create(table: "writing_capture_runs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("date_utc", .text).notNull().unique()  // 'YYYY-MM-DD'
                t.column("status", .text).notNull()
                t.column("run_id", .text)                       // UUID
                t.column("started_at", .integer)
                t.column("completed_at", .integer)
                t.column("error_message", .text)
                t.column("pass1_token_usage", .integer)
                t.column("pass2_token_usage", .integer)
                t.column("discarded_count", .integer).defaults(to: 0)
                t.column("records_count", .integer).defaults(to: 0)
            }
            try db.execute(sql:
                "CREATE INDEX idx_writing_capture_runs_status ON writing_capture_runs(status)")
        }

        // ═══════════════════════════════════════════════════════════
        // v23 — speakers.hidden 改名 speakers.hallucination
        // ═══════════════════════════════════════════════════════════
        //
        // UI 一直叫 "Mark as hallucination",方法叫 markSpeakerHallucination,
        // 但 DB 列叫 `hidden`、实现内部又叫 `hide()`,三套术语并存。统一成
        // hallucination(UI 已用的词,语义更准:这是"误判出的假说话人簇")。
        m.registerMigration("v23_speakers_hallucination_rename") { db in
            try db.execute(sql:
                "ALTER TABLE speakers RENAME COLUMN hidden TO hallucination")
        }

        // ═══════════════════════════════════════════════════════════
        // v24 — keystroke_log.modifiers(快捷键 bit 字段)
        // ═══════════════════════════════════════════════════════════
        //
        // 没有这字段,LLM 在 Pass 2 看不出 ⌘X / ⌘Z / ⌘A 这种快捷键 —— keystroke
        // 长得跟普通输入字母一样。加 packed Int 字段:
        //   bit 0(0x01) = command
        //   bit 1(0x02) = option / alt
        //   bit 2(0x04) = control
        //   bit 3(0x08) = shift
        // 没有任何修饰键时 = 0。CGEvent.flags 转换详见 KeystrokeCharLogger。
        // 旧行 DEFAULT 0(没修饰键),不影响已有数据。
        m.registerMigration("v24_keystroke_log_modifiers") { db in
            try db.alter(table: "keystroke_log") { t in
                t.add(column: "modifiers", .integer).notNull().defaults(to: 0)
            }
        }

        // ═══════════════════════════════════════════════════════════
        // v25 — writing_records_discarded:持久化 LLM 丢弃的 session
        // ═══════════════════════════════════════════════════════════
        //
        // Pass 2 的 LLM 输出有 records[] 和 discarded[]。原来 discarded 直接
        // 扔了,看 LLM 为啥丢某个 session 没法 debug。落表持久化:
        // - 按天/run_id 查
        // - kind=staged → Reject 时清,Approve 时拷到 kind=committed
        m.registerMigration("v25_writing_records_discarded") { db in
            try db.create(table: "writing_records_discarded") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("date_utc", .text).notNull()           // 'YYYY-MM-DD'
                t.column("reason", .text).notNull()              // "throwaway: ..." 或 LLM 自由文本
                t.column("session_ids", .text).notNull()         // JSON [String]
                t.column("preview", .text)                       // ≤ 80 字
                t.column("worker_run_id", .text).notNull()
                t.column("kind", .text).notNull()                // "staged" | "committed"
                t.column("created_at", .integer).notNull()
            }
            try db.execute(sql:
                "CREATE INDEX idx_writing_records_discarded_date ON writing_records_discarded(date_utc, kind)")
            try db.execute(sql:
                "CREATE INDEX idx_writing_records_discarded_run ON writing_records_discarded(worker_run_id)")
        }

        // ═══════════════════════════════════════════════════════════
        // v26 — writing_records / _staged 加 kind 字段(long_form / short_form / other)
        // ═══════════════════════════════════════════════════════════
        //
        // 大/小 session 双轨:LLM 把每条 record 标 long_form(长文 / 笔记 /
        // 文档)、short_form(聊天消息 / 短社交输出)、other(应答 / 命令等
        // 仍想保留为信号但不是创作)。前端按 kind 分两个 sub-tab 展示。
        // 旧数据 default 'long_form' —— 之前的 records 都是当长文存的。
        m.registerMigration("v26_writing_records_kind") { db in
            try db.alter(table: "writing_records") { t in
                t.add(column: "kind", .text).notNull().defaults(to: "long_form")
            }
            try db.alter(table: "writing_records_staged") { t in
                t.add(column: "kind", .text).notNull().defaults(to: "long_form")
            }
            try db.execute(sql:
                "CREATE INDEX idx_writing_records_kind ON writing_records(kind, start_ts)")
        }

        // v27: 全历史 backlog cursor —— 一个 row,记录"已处理到哪个 ts"。
        // approve 后 cursor 推进到本次 run 处理的 max ts,下次只跑 cursor 之后。
        m.registerMigration("v27_writing_capture_cursor") { db in
            try db.create(table: "writing_capture_cursor") { t in
                t.column("id", .integer).primaryKey()  // 永远 = 1
                t.column("last_processed_ts", .integer).notNull().defaults(to: 0)
                t.check(sql: "id = 1")
            }
            try db.execute(sql:
                "INSERT INTO writing_capture_cursor (id, last_processed_ts) VALUES (1, 0)")
        }

        // ═══════════════════════════════════════════════════════════
        // v28 — writing_records_user_rejected: 用户手动拒过的 record
        // ═══════════════════════════════════════════════════════════
        //
        // 用户在 Pending review UI 点 "Reject this" 标某条 staged 不要时,
        // 把那条的 text/app/kind + 拒绝 reason 写到这里。下次 Pass 2 会
        // 从这表读最近 100 条 OR 90 天内的拒绝记录,塞进 prompt 当 few-shot,
        // LLM 据此判类似 candidate 是否丢 discarded。
        //
        // 同时 writing_records_staged 加 hidden_at 列:被拒的 staged 不删
        // (留着审计),只标 hidden_at,UI 列表过滤掉。
        m.registerMigration("v28_writing_records_user_rejected") { db in
            try db.create(table: "writing_records_user_rejected") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("text", .text).notNull()
                t.column("app", .text).notNull()
                t.column("url", .text)
                t.column("kind", .text).notNull()
                t.column("reason_category", .text).notNull()  // gibberish|private|irrelevant|typo_residue|other
                t.column("reason_text", .text)                 // 自由文本(可空)
                t.column("staged_id", .integer)                // 来源 staged.id(可空,审计)
                t.column("worker_run_id", .text)
                t.column("rejected_at", .integer).notNull()
            }
            try db.execute(sql:
                "CREATE INDEX idx_writing_records_user_rejected_at ON writing_records_user_rejected(rejected_at)")
            try db.alter(table: "writing_records_staged") { t in
                t.add(column: "hidden_at", .integer)
            }
        }

        // ═══════════════════════════════════════════════════════════
        // v29 — speech_style 提炼链路
        // ═══════════════════════════════════════════════════════════
        //
        // 独立于 PortraitDistiller / PersonalityAgent，吃 writing_records 当
        // 输入源。三块改动：
        //   1) writing_records 加 speech_style_processed_at —— 标 completed,
        //      下次跑就跳过这条 record(避免重复喂 LLM)。
        //   2) speech_style_runs —— 每次 run 一行,状态机:processing /
        //      pending_review(manual)/ auto_committed(auto)/ approved /
        //      rejected_for_rerun / failed。
        //   3) speech_style_staged —— manual 模式的 staged 决策行,等
        //      Approve 才落 portrait/speech_style/ 文件。auto 模式直接落
        //      portrait,不入这张表。
        m.registerMigration("v29_speech_style") { db in
            try db.alter(table: "writing_records") { t in
                t.add(column: "speech_style_processed_at", .integer)
            }
            try db.execute(sql:
                "CREATE INDEX idx_writing_records_ss_pending ON writing_records(speech_style_processed_at)")

            try db.create(table: "speech_style_runs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("run_id", .text).notNull().unique()
                t.column("mode", .text).notNull()              // 'manual' | 'auto'
                t.column("status", .text).notNull()
                t.column("started_at", .integer).notNull()
                t.column("completed_at", .integer)
                t.column("error_message", .text)
                t.column("records_count", .integer)            // 喂给 LLM 的 record 数
                t.column("drafts_count", .integer)             // LLM 返回的 draft 数
                t.column("token_usage", .integer)
            }
            try db.execute(sql:
                "CREATE INDEX idx_speech_style_runs_status ON speech_style_runs(status, started_at)")

            try db.create(table: "speech_style_staged") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("run_id", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("action", .text).notNull()            // 'create' | 'update' | 'noop'
                t.column("slug", .text).notNull()              // 目标文件 slug
                t.column("title", .text).notNull()
                t.column("body", .text).notNull()              // markdown 正文
                t.column("source_record_ids", .text).notNull() // JSON [int]
                t.column("existing_slug", .text)               // update 时 = 目标 slug;create/noop 留空
                t.column("hidden_at", .integer)                // 被单条 reject 时标
            }
            try db.execute(sql:
                "CREATE INDEX idx_speech_style_staged_run ON speech_style_staged(run_id)")
        }

        // ═══════════════════════════════════════════════════════════
        // v30 — speech_style_runs.input_record_ids + 历史修复
        // ═══════════════════════════════════════════════════════════
        //
        // bug:approveStaged 只标 LLM 引用过的 records 为 completed,LLM 看完
        // 但决定不归入任何 facet 的 records 仍是 NULL,下次 run 又被喂一次,
        // 浪费 token + 污染判断。
        //
        // 修法:run 时把整批 input 的 record ids 持久化到 runs 表;approve /
        // auto-commit 时按 input 全标 completed。
        //
        // 历史修复:在 migration 里把所有 id ≤ 已 approved run 喂过的最大 id
        // 之前的 NULL records 一次性标 completed(那批它们都被喂过)。
        m.registerMigration("v30_speech_style_input_record_ids") { db in
            try db.alter(table: "speech_style_runs") { t in
                t.add(column: "input_record_ids", .text)   // JSON array of Int64
            }
            // 历史修复:把所有 NULL records 里 id ≤ max(已 processed id) 的
            // 标 completed —— 这些 ids 在某次 approved run 时一定被喂过(LLM
            // 按 start_ts ASC LIMIT 拉,过去 max id 之前的都跑过),只是 LLM
            // 没引用所以漏标。completed_at 用 now 兜底。
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            try db.execute(sql: """
                UPDATE writing_records
                SET speech_style_processed_at = :now
                WHERE speech_style_processed_at IS NULL
                  AND id <= (SELECT MAX(id) FROM writing_records WHERE speech_style_processed_at IS NOT NULL)
                """,
                arguments: ["now": now])
        }

        // v31 — speakers.trained_at_ms:用户真正 voice training 过的标记。
        //
        // 之前 SpeakersView 数 "identified" = "name 非空",但 diarization
        // 阶段被用户 rename 的也算 → 数 dupe / unverified 簇 → 计数偏高。
        // 改用 trained_at_ms 严格只数"用户跑过 voice training 留下 fresh
        // embedding 的"。NULL = 没训练过(diarization 自动建,或仅 rename)。
        // upsertVoiceTrainedSpeaker 写入时 SET trained_at_ms = nowMs。
        m.registerMigration("v31_speakers_trained_at") { db in
            try db.alter(table: "speakers") { t in
                t.add(column: "trained_at_ms", .integer)   // nullable
            }
        }

        // v32 — 回填:把"已有 name 的 speaker"视为 trained。
        //
        // 1.0.x 用户跑过 voice training 的 speaker 当时代码还没写
        // trained_at_ms,迁移后留 NULL → SpeakersView 显示 0 of N
        // identified,跟用户预期不符。
        //
        // 修法:凡是 name != NULL 且非 hallucination 的 speaker,
        // 视为"已识别"(用户至少认过这个人),trained_at = updated_at_ms。
        // 之后用户再跑 voice training 会覆盖 trained_at = now。
        //
        // 副作用:diarization 自动建后用户 rename 但没真训过的 speaker
        // 也被算 trained。但语义上"用户至少认过这是某人"也算合理。
        m.registerMigration("v32_backfill_trained_at") { db in
            try db.execute(sql: """
                UPDATE speakers
                SET trained_at_ms = updated_at_ms
                WHERE trained_at_ms IS NULL
                  AND name IS NOT NULL
                  AND name != ''
                  AND hallucination = 0
                """)
        }

        // v33 — **撤回 v32 的回填**。v32 把"有名字"等同于"已训过",违背了
        // identified 严格语义。用户诉求是:**只有真跑过 voice training 的
        // 算 identified**,diarization 自动建后用户 rename 的不算。
        //
        // 这里把所有 trained_at_ms 清成 NULL。新版 VoiceTrainer 走
        // upsertVoiceTrainedSpeaker 时会重新写 trained_at_ms = now,这是
        // 唯一标记为 trained 的合法路径。
        //
        // 副作用:新版用户如果在 v32 → v33 之间真跑过 voice training,这次
        // 也会被清掉。可接受 — 重训一次即可。
        m.registerMigration("v33_clear_trained_at_backfill") { db in
            try db.execute(sql: "UPDATE speakers SET trained_at_ms = NULL")
        }

        // ═══════════════════════════════════════════════════════════
        // v34 — processing_log.classify_status:event classifier 阶段
        // ═══════════════════════════════════════════════════════════
        //
        // event 之后、distill 之前的新阶段。把 events 按项目维度归到
        // ~/.portrait/events/_folders/*.json,纯 metadata,不动 .md 文件。
        // anchor-row 模式跟 distill / personality 一致(`_classify_anchor` 行,
        // 只用 `classify_status` 列)。
        // NOT NULL DEFAULT 'idle':现有行自动 idle。
        m.registerMigration("v34_processing_log_classify") { db in
            try db.alter(table: "processing_log") { t in
                t.add(column: "classify_status", .text).notNull().defaults(to: "idle")
            }
        }

        // v35 — writing_records.location:CLI 导入数据的会话/项目目录。
        //
        // cli_import(Claude Code / Codex)的 url 一律留空 → 前端按 (app,url)
        // 聚成单一窗口,不再按文件夹炸出一堆窗口。文件夹路径改存这一列,只作
        // 元数据展示,不参与分组。其它来源(OCR 采集)此列 NULL。
        m.registerMigration("v35_writing_records_location") { db in
            try db.alter(table: "writing_records") { t in
                t.add(column: "location", .text)
            }
        }

        // ═══════════════════════════════════════════════════════════
        // v36 — speech_style → writing_style 全量改名
        // ═══════════════════════════════════════════════════════════
        //
        // 「speech_style」链路实际吃 writing_records(打字数据)提炼,名不副实。
        // 全量改名 writing_style:表 / 列 / 索引一次 RENAME。v29/v30 历史迁移
        // 保持原样(已在老用户 DB 上跑过,不能改)。SQLite 3.25+ 支持 RENAME
        // TABLE / RENAME COLUMN,会自动改依赖的 index 定义;索引名本身不变,
        // 这里顺手 DROP + 重建成新名,保持彻底一致。
        //
        // portrait/speech_style/ 文件夹 + 每个 .md frontmatter + config 旧 key
        // 的迁移在文件系统层,不在 DB migration 里(见
        // PortraitPaths.migrateSpeechStyleToWritingStyle / ConfigSchema 旧 key 回退)。
        m.registerMigration("v36_rename_speech_style_to_writing_style") { db in
            try db.execute(sql: "ALTER TABLE speech_style_runs RENAME TO writing_style_runs")
            try db.execute(sql: "ALTER TABLE speech_style_staged RENAME TO writing_style_staged")
            try db.execute(sql:
                "ALTER TABLE writing_records RENAME COLUMN speech_style_processed_at TO writing_style_processed_at")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_writing_records_ss_pending")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_speech_style_runs_status")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_speech_style_staged_run")
            try db.execute(sql:
                "CREATE INDEX idx_writing_records_ws_pending ON writing_records(writing_style_processed_at)")
            try db.execute(sql:
                "CREATE INDEX idx_writing_style_runs_status ON writing_style_runs(status, started_at)")
            try db.execute(sql:
                "CREATE INDEX idx_writing_style_staged_run ON writing_style_staged(run_id)")
        }

        // 给说话人声纹绑定模型:每个 speaker 行属于产它向量的那个 embedding 模型。
        // 不同模型(英文 512 / 中文 192;甚至两个 192 维中文模型)向量空间不兼容,
        // 必须按模型隔离匹配。现存声纹全是英文 CAM++ → 回填 en_campplus。
        m.registerMigration("v37_speakers_embedding_model") { db in
            try db.alter(table: "speakers") { t in
                t.add(column: "embedding_model", .text)   // nullable;NULL 视同 en_campplus
            }
            try db.execute(sql:
                "UPDATE speakers SET embedding_model = 'en_campplus' WHERE embedding_model IS NULL")
        }

        // memory pipeline 每次运行的历史(Run now / 定时;成功 / 失败 / 自动恢复 /
        // 空跑都记)。Changelog 页展示最近 50 条。
        m.registerMigration("v38_pipeline_runs") { db in
            try db.create(table: "pipeline_runs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp_ms", .integer).notNull()
                t.column("trigger", .text).notNull()    // "run-now" | "scheduler"
                t.column("pipeline", .text).notNull()   // UI 名,如 "Event processing"
                t.column("outcome", .text).notNull()    // success | failure | auto-recovering | no-work
                t.column("reason", .text)               // 失败原因;成功 / 空跑为 NULL
            }
            try db.create(index: "idx_pipeline_runs_ts",
                          on: "pipeline_runs", columns: ["timestamp_ms"])
        }

        return m
    }
}
