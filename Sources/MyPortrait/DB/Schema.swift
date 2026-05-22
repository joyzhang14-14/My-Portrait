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

        return m
    }
}
