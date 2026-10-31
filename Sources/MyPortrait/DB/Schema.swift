import Foundation
import GRDB

/// 四个库各自的迁移器。每个库从一份「基线」开始(`<库>_v1`),直接建出当前的表结构;
/// 以后改表结构就在对应库的迁移器里往后追加新版本,不改已发布的版本。
/// 拆库之前的 v1…v51 迁移已经合进基线,要追溯看 git 历史。
///
/// 列名 snake_case 是 SQLite 习俗;Swift 字段保持 camelCase,靠 GRDB 的
/// `databaseColumnEncodingStrategy = .convertToSnakeCase` 自动映射。
///
/// 时间戳全部 INTEGER(UTC 毫秒),不用 ISO 字符串:索引快、不用解析、与
/// `Date(timeIntervalSince1970: ms/1000)` 一行互转。
///
/// 建表语句照抄拆库前线上库 `sqlite_master` 里的原文,新库和拆出来的库结构一致。
enum DBSchema {

    // MARK: - screen.sqlite

    static func screenMigrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("screen_v1", foreignKeyChecks: .immediate) { db in
            for sql in screenBaseline { try db.execute(sql: sql) }
        }
        return m
    }

    /// 全文索引和三个同步触发器单独列出来:`--rebuild-frames-fts` 手动重建时用同一份文本。
    /// 更新触发器只在进索引的 4 列被改时触发:压缩、保留清理改媒体列不用白付一次重分词。
    static let framesFTS = """
        CREATE VIRTUAL TABLE frames_fts USING fts5(
            app_name, window_name, browser_url, full_text,
            tokenize='''foundation_icu''',
            content='frames', content_rowid='id'
        )
        """
    static let framesFTSTriggers = [
        """
        CREATE TRIGGER __frames_fts_ai AFTER INSERT ON frames BEGIN
            INSERT INTO frames_fts(rowid, app_name, window_name, browser_url, full_text)
            VALUES (new.id, new.app_name, new.window_name, new.browser_url, new.full_text);
        END
        """,
        """
        CREATE TRIGGER __frames_fts_ad AFTER DELETE ON frames BEGIN
            INSERT INTO frames_fts(frames_fts, rowid, app_name, window_name, browser_url, full_text)
            VALUES('delete', old.id, old.app_name, old.window_name, old.browser_url, old.full_text);
        END
        """,
        """
        CREATE TRIGGER "__frames_fts_au" AFTER UPDATE OF "app_name", "window_name", "browser_url", "full_text" ON "frames" BEGIN
          INSERT INTO "frames_fts"("frames_fts", "rowid", "app_name", "window_name", "browser_url", "full_text") VALUES('delete', OLD."rowid", OLD."app_name", OLD."window_name", OLD."browser_url", OLD."full_text");
          INSERT INTO "frames_fts"("rowid", "app_name", "window_name", "browser_url", "full_text") VALUES (NEW."rowid", NEW."app_name", NEW."window_name", NEW."browser_url", NEW."full_text");
        END
        """,
    ]

    static let screenBaseline: [String] = [
        // 视频块:CompactionWorker 把 JPG 压成 MP4 后写入。
        """
        CREATE TABLE "video_chunks" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "file_path" TEXT NOT NULL, "device_name" TEXT NOT NULL DEFAULT 'main', "fps" DOUBLE NOT NULL DEFAULT 1.0, "start_ts_ms" INTEGER NOT NULL, "end_ts_ms" INTEGER NOT NULL, "frame_count" INTEGER NOT NULL, "created_at_ms" INTEGER NOT NULL)
        """,
        #"CREATE INDEX "idx_video_chunks_start_ts" ON "video_chunks"("start_ts_ms")"#,
        // 帧:刚采时 snapshot_path 有值、video_chunk_id 为 NULL;压成 MP4 后反过来。
        //   app_name = 激活 app(菜单栏);visible_app = 画面最前普通窗口所属 app;
        //   focus_state = normal / switching / no_window(见 FrameFocusState);
        //   visible_windows = 露出来的普通窗口 JSON(前 → 后,坐标归一化、原点左上);
        //   ocr_backfill_* = 事后补跑的整帧 OCR。
        """
        CREATE TABLE "frames" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "timestamp_ms" INTEGER NOT NULL, "app_name" TEXT NOT NULL, "window_name" TEXT, "browser_url" TEXT, "focused" BOOLEAN NOT NULL DEFAULT 1, "device_name" TEXT NOT NULL DEFAULT 'main', "snapshot_path" TEXT, "video_chunk_id" INTEGER REFERENCES "video_chunks"("id") ON DELETE SET NULL, "offset_ms" INTEGER, "capture_trigger" TEXT, "full_text" TEXT, "ocr_words_json" TEXT, "ocr_confidence" DOUBLE, "text_source" TEXT, "created_at_ms" INTEGER NOT NULL, "embedding" BLOB, embedding_model TEXT, ocr_backfill_text TEXT, ocr_backfill_words TEXT, visible_app TEXT, focus_state TEXT, visible_windows TEXT)
        """,
        #"CREATE INDEX "idx_frames_timestamp" ON "frames"("timestamp_ms")"#,
        #"CREATE INDEX "idx_frames_app" ON "frames"("app_name")"#,
        #"CREATE INDEX "idx_frames_video_chunk" ON "frames"("video_chunk_id")"#,
        "CREATE INDEX idx_frames_embedding_null ON frames(id) WHERE embedding IS NULL",
        // 还没压成 MP4 的帧只有一千来行,压缩每 5 分钟找一次,靠这个部分索引免得扫全表。
        """
        CREATE INDEX idx_frames_snapshot ON frames(device_name, timestamp_ms)
        WHERE snapshot_path IS NOT NULL
        """,
        framesFTS,
    ] + framesFTSTriggers + [
        // 延后 OCR 的队列:采集时不做 OCR 的帧登记在这里,DeferredOCRWorker 做完一帧删一行。
        // 事件区间封口不越过这里最旧的一帧。没有外键,删帧的地方要顺手清孤儿行。
        """
        CREATE TABLE ocr_pending (
            frame_id INTEGER PRIMARY KEY,
            timestamp_ms INTEGER NOT NULL
        )
        """,
        "CREATE INDEX idx_ocr_pending_ts ON ocr_pending(timestamp_ms)",
        // OCRWordsSlimmer 的进度(单行)。
        """
        CREATE TABLE ocr_words_slim_state (
            id INTEGER PRIMARY KEY CHECK (id = 1), last_id INTEGER NOT NULL, done INTEGER NOT NULL)
        """,
    ]

    // MARK: - audio.sqlite

    static func audioMigrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("audio_v1", foreignKeyChecks: .immediate) { db in
            for sql in audioBaseline { try db.execute(sql: sql) }
        }
        return m
    }

    static let audioBaseline: [String] = [
        // 录音段:file_path 待转录时在 metadata/audio_queue/,转录完搬进 metadata/audio/<日>/。
        """
        CREATE TABLE "audio_chunks" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "file_path" TEXT NOT NULL, "recorded_at_ms" INTEGER NOT NULL, "duration_s" DOUBLE NOT NULL, "device" TEXT NOT NULL, "is_input" BOOLEAN NOT NULL, "status" TEXT NOT NULL DEFAULT 'pending', "created_at_ms" INTEGER NOT NULL, "retry_count" INTEGER NOT NULL DEFAULT 0)
        """,
        #"CREATE INDEX "idx_audio_chunks_recorded" ON "audio_chunks"("recorded_at_ms")"#,
        #"CREATE INDEX "idx_audio_chunks_status" ON "audio_chunks"("status")"#,
        """
        CREATE TABLE "audio_transcriptions" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "audio_chunk_id" INTEGER NOT NULL REFERENCES "audio_chunks"("id") ON DELETE CASCADE, "start_s" DOUBLE NOT NULL, "end_s" DOUBLE NOT NULL, "text" TEXT NOT NULL, "speaker_id" INTEGER, "engine" TEXT NOT NULL DEFAULT 'whisperkit', "transcribed_at_ms" INTEGER NOT NULL, "embedding" BLOB, embedding_model TEXT)
        """,
        #"CREATE INDEX "idx_transcriptions_chunk" ON "audio_transcriptions"("audio_chunk_id")"#,
        "CREATE INDEX idx_transcriptions_embedding_null ON audio_transcriptions(id) WHERE embedding IS NULL",
        #"CREATE INDEX "idx_transcriptions_speaker" ON "audio_transcriptions"("speaker_id", "transcribed_at_ms")"#,
        #"CREATE VIRTUAL TABLE "transcriptions_fts" USING fts5(text, tokenize='''foundation_icu''', content='audio_transcriptions', content_rowid='id')"#,
        """
        CREATE TRIGGER "__transcriptions_fts_ai" AFTER INSERT ON "audio_transcriptions" BEGIN
            INSERT INTO "transcriptions_fts"("rowid", "text") VALUES (new."id", new."text");
        END
        """,
        """
        CREATE TRIGGER "__transcriptions_fts_ad" AFTER DELETE ON "audio_transcriptions" BEGIN
            INSERT INTO "transcriptions_fts"("transcriptions_fts", "rowid", "text") VALUES('delete', old."id", old."text");
        END
        """,
        """
        CREATE TRIGGER "__transcriptions_fts_au" AFTER UPDATE ON "audio_transcriptions" BEGIN
            INSERT INTO "transcriptions_fts"("transcriptions_fts", "rowid", "text") VALUES('delete', old."id", old."text");
            INSERT INTO "transcriptions_fts"("rowid", "text") VALUES (new."id", new."text");
        END
        """,
        // 说话人:hallucination = 识别成「幻听」的簇;trained_at_ms = 声纹训练时间。
        """
        CREATE TABLE "speakers" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT, "centroid" BLOB, "embedding_count" INTEGER NOT NULL DEFAULT 0, "hallucination" BOOLEAN NOT NULL DEFAULT 0, "created_at_ms" INTEGER NOT NULL, "updated_at_ms" INTEGER NOT NULL, "trained_at_ms" INTEGER, "embedding_model" TEXT)
        """,
        """
        CREATE TABLE "speaker_embeddings" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "speaker_id" INTEGER NOT NULL REFERENCES "speakers"("id") ON DELETE CASCADE, "embedding" BLOB NOT NULL, "created_at_ms" INTEGER NOT NULL)
        """,
        #"CREATE INDEX "idx_speaker_embeddings_speaker" ON "speaker_embeddings"("speaker_id")"#,
    ]

    // MARK: - input.sqlite

    static func inputMigrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("input_v1", foreignKeyChecks: .immediate) { db in
            for sql in inputBaseline { try db.execute(sql: sql) }
        }
        return m
    }

    static let inputBaseline: [String] = [
        // 击键:ts_ms = UTC 毫秒;modifiers 掩码;input_source = 当时的输入法。
        """
        CREATE TABLE "keystroke_log" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "ts_ms" INTEGER NOT NULL, "bundle_id" TEXT NOT NULL, "char" TEXT, "is_backspace" INTEGER NOT NULL DEFAULT 0, "modifiers" INTEGER NOT NULL DEFAULT 0, "input_source" TEXT)
        """,
        "CREATE INDEX idx_keystroke_log_ts ON keystroke_log(ts_ms)",
        "CREATE INDEX idx_keystroke_log_app ON keystroke_log(bundle_id, ts_ms)",
        """
        CREATE TABLE "mouse_log" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "ts_ms" INTEGER NOT NULL, "bundle_id" TEXT NOT NULL, "kind" TEXT NOT NULL, "target_pid" INTEGER, "target_bundle_id" TEXT, "x" DOUBLE, "y" DOUBLE, "screen_w" INTEGER, "screen_h" INTEGER, "click_count" INTEGER NOT NULL DEFAULT 1, "modifiers" INTEGER NOT NULL DEFAULT 0)
        """,
        "CREATE INDEX idx_mouse_log_ts ON mouse_log(ts_ms)",
        "CREATE INDEX idx_mouse_log_app ON mouse_log(bundle_id, ts_ms)",
        // AX 订阅采集到的打字事件(一个输入框一段)。
        """
        CREATE TABLE "typing_events" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "bundle_id" TEXT NOT NULL, "element_hash" INTEGER NOT NULL, "started_at" INTEGER NOT NULL, "ended_at" INTEGER NOT NULL, "text" TEXT NOT NULL, "edit_log" TEXT NOT NULL, "total_chars" INTEGER NOT NULL, "session_start" TEXT NOT NULL DEFAULT '', "end_value" TEXT NOT NULL DEFAULT '', "stripped" TEXT NOT NULL DEFAULT '[]', "url" TEXT NOT NULL DEFAULT '')
        """,
        "CREATE INDEX idx_typing_events_app ON typing_events(bundle_id)",
        "CREATE INDEX idx_typing_events_app_element ON typing_events(bundle_id, element_hash)",
        "CREATE INDEX idx_typing_events_time ON typing_events(started_at)",
        // 剪贴板换内容一行,只存摘要(见 ClipboardLogger)。
        """
        CREATE TABLE "clipboard_log" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "ts_ms" INTEGER NOT NULL, "bundle_id" TEXT NOT NULL, "content" TEXT NOT NULL)
        """,
        "CREATE INDEX idx_clipboard_log_ts ON clipboard_log(ts_ms)",
    ]

    // MARK: - workflow.sqlite

    static func workflowMigrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("workflow_v1", foreignKeyChecks: .immediate) { db in
            for sql in workflowBaseline { try db.execute(sql: sql) }
        }
        return m
    }

    static let workflowBaseline: [String] = [
        // 事件区间:按封口切出来的一段段采集时间,事件 workflow 按区间处理。
        """
        CREATE TABLE "event_intervals" ("id" TEXT PRIMARY KEY, "start_ms" INTEGER NOT NULL, "end_ms" INTEGER NOT NULL, "tz_offset_min" INTEGER NOT NULL, "sealed_at_ms" INTEGER NOT NULL, "trigger" TEXT NOT NULL, "frame_count" INTEGER NOT NULL DEFAULT 0, "after_frame_id" INTEGER NOT NULL DEFAULT 0, "max_frame_id" INTEGER NOT NULL DEFAULT 0, "event_status" TEXT NOT NULL DEFAULT 'pending', "impact_status" TEXT NOT NULL DEFAULT 'idle', "retry_count" INTEGER NOT NULL DEFAULT 0, "updated_at_ms" INTEGER NOT NULL DEFAULT 0)
        """,
        #"CREATE INDEX "idx_event_intervals_end" ON "event_intervals"("end_ms")"#,
        // 性格按本地日处理的台账。
        """
        CREATE TABLE "personality_days" ("day" TEXT PRIMARY KEY, "tz_offset_min" INTEGER NOT NULL, "status" TEXT NOT NULL DEFAULT 'pending', "retry_count" INTEGER NOT NULL DEFAULT 0, "updated_at_ms" INTEGER NOT NULL DEFAULT 0)
        """,
        """
        CREATE TABLE "processing_log" ("date" TEXT PRIMARY KEY, "raw_status" TEXT NOT NULL DEFAULT 'idle', "event_status" TEXT NOT NULL DEFAULT 'idle', "impact_status" TEXT NOT NULL DEFAULT 'idle', "distill_status" TEXT NOT NULL DEFAULT 'idle', "active_processor" TEXT, "checkpoint" TEXT, "heartbeat_ms" INTEGER, "updated_at_ms" INTEGER NOT NULL DEFAULT 0, "retry_count" INTEGER NOT NULL DEFAULT 0, "personality_status" TEXT NOT NULL DEFAULT 'idle', "classify_status" TEXT NOT NULL DEFAULT 'idle')
        """,
        """
        CREATE TABLE "pipeline_runs" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "timestamp_ms" INTEGER NOT NULL, "trigger" TEXT NOT NULL, "pipeline" TEXT NOT NULL, "outcome" TEXT NOT NULL, "reason" TEXT)
        """,
        #"CREATE INDEX "idx_pipeline_runs_ts" ON "pipeline_runs"("timestamp_ms")"#,
        """
        CREATE TABLE "distill_changelog" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "entity_id" TEXT NOT NULL, "field_name" TEXT NOT NULL, "before" TEXT, "after" TEXT, "triggered_by_event_id" TEXT, "llm_reasoning" TEXT, "timestamp_ms" INTEGER NOT NULL)
        """,
        #"CREATE INDEX "idx_distill_changelog_entity" ON "distill_changelog"("entity_id")"#,
        // 写作记录:写作风格的输入。
        """
        CREATE TABLE "writing_records" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "start_ts" INTEGER NOT NULL, "end_ts" INTEGER NOT NULL, "app" TEXT NOT NULL, "url" TEXT, "text" TEXT NOT NULL, "edit_log" TEXT NOT NULL, "confidence" DOUBLE NOT NULL, "context_summary" TEXT, "source" TEXT NOT NULL, "reference_typing_event_ids" TEXT, "reference_frame_ids" TEXT, "reference_keystroke_range" TEXT, "raw_output" TEXT, "prompt_id" TEXT, "created_at" INTEGER NOT NULL, "worker_run_id" TEXT, "kind" TEXT NOT NULL DEFAULT 'long_form', "writing_style_processed_at" INTEGER, "location" TEXT)
        """,
        "CREATE INDEX idx_writing_records_date ON writing_records(start_ts)",
        "CREATE INDEX idx_writing_records_app ON writing_records(app)",
        "CREATE INDEX idx_writing_records_run ON writing_records(worker_run_id)",
        "CREATE INDEX idx_writing_records_kind ON writing_records(kind, start_ts)",
        "CREATE INDEX idx_writing_records_ws_pending ON writing_records(writing_style_processed_at)",
        """
        CREATE TABLE "writing_style_runs" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "run_id" TEXT NOT NULL UNIQUE, "mode" TEXT NOT NULL, "status" TEXT NOT NULL, "started_at" INTEGER NOT NULL, "completed_at" INTEGER, "error_message" TEXT, "records_count" INTEGER, "drafts_count" INTEGER, "token_usage" INTEGER, "input_record_ids" TEXT)
        """,
        "CREATE INDEX idx_writing_style_runs_status ON writing_style_runs(status, started_at)",
        """
        CREATE TABLE "writing_style_staged" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "run_id" TEXT NOT NULL, "created_at" INTEGER NOT NULL, "action" TEXT NOT NULL, "slug" TEXT NOT NULL, "title" TEXT NOT NULL, "body" TEXT NOT NULL, "source_record_ids" TEXT NOT NULL, "existing_slug" TEXT, "hidden_at" INTEGER)
        """,
        "CREATE INDEX idx_writing_style_staged_run ON writing_style_staged(run_id)",
    ]
}
