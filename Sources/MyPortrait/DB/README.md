# DB/ — 持久层

`PortraitDB`：屏幕帧 + 视频块 + 音频段 + 转录的本地 SQLite 持久层 + 全文搜索（FTS5）。

> **语义/向量搜索已移除。** 旧版蓝图里的 bge-m3 向量、`HybridSearchEngine`、RRF 融合、
> `NLEmbedding` / `VectorEmbedder` / `EmbeddingWorker` 全部下线。**当前搜索 = 纯
> FTS5 关键词检索**，由 `FTSSearchEngine` 一肩挑。

## 技术栈

- **GRDB.swift 7** — Swift-native SQLite，async/await 原生支持
- **SQLite (系统自带)** — macOS 自带版本，**只编进了 FTS5，没有 ICU / LOAD_EXTENSION**
- **Foundation 后端的自定义分词器** — 因为系统 sqlite3 没编 ICU，我们用
  `String.enumerateSubstrings(.byWords)`（Darwin 上**内部就是 ICU**）写了一个
  FTS5CustomTokenizer，效果等价于 ICU 分词器
- **WAL 模式** — 多读单写并发不阻塞

## 文件位置

数据库：`~/.portrait/portrait.sqlite`（+ `.wal` / `.shm` 同目录）。

## Schema（migrations）

```
v1_screen_capture         video_chunks + frames + frames_fts (FTS5 + custom tokenizer)
v2_audio_capture          audio_chunks + audio_transcriptions
v3_transcriptions_fts     transcriptions_fts (FTS5 + same tokenizer)
```

详见 [Schema.swift](Schema.swift)。**Migration 一旦发布就不改**，新 schema 加新 migration。

> **残留列说明：** `frames.embedding` / `audio_transcriptions.embedding`（BLOB）及其
> `embedding_model`（TEXT）列、对应的 `*_embedding_null` 部分索引，是已移除的语义搜索
> 子系统留下的（v4_embeddings / v5_embedding_model）。migration 只能追加、不能回删，所以
> 列还在，但**没有任何代码写入或读取它们**（BLOB 落 overflow page，不读 = 0 成本）。
> （`PortraitDB` 协议里那批 embedding 读写方法 + `FrameMetadata`/`TranscriptionMetadata`
> 已随子系统一并删除，只剩这几列因 migration 锁定而保留。）
> （注意：v7_speakers 的 `speakers.centroid` / `speaker_embeddings.embedding` 属于
> **说话人声纹**系统，正在使用，跟这里的文本 embedding 残留无关。）

## 模块文件

| 文件 | 职责 |
|---|---|
| `Schema.swift` | DatabaseMigrator —— v1/v2/v3 起，含残留的 v4/v5 embedding 列 |
| `PortraitDBImpl.swift` | `PortraitDB` 协议实现，actor + DatabasePool (WAL) |
| `FoundationTokenizer.swift` | 自定义 FTS5 分词器（ICU 通过 Foundation 借道） |
| `RetentionWorker.swift` | 自动删除，24h cadence，读 ConfigStore.snapshot 的 retentionDays / autoDeleteMode |
| `ScreenpipeImporter.swift` | 从 screenpipe 库导入历史数据（只读 copy，不动源库） |
| `ScreenpipeImportCLI.swift` | 上面导入流程的 CLI 入口 |
| `Records/*.swift` | GRDB record struct（Codable + Persistable，**不是 Record 子类**） |
| `Search/SearchEngine.swift` | 搜索协议 + result 类型 |
| `Search/FTSSearchEngine.swift` | 纯 FTS5 + bm25 + snippet，搜 frames / transcriptions |
| `Vectors/VectorMath.swift` | Accelerate(vDSP) cosine + Float32 BLOB 编解码（**活跃工具**：说话人声纹系统的 cosine 与 BLOB 编解码底座，被 PortraitDBImpl / TimelineDB / SpeakerOnnx / SileroVAD 多处调用） |
| `Vectors/EmbedDumpCLI.swift` | 调试 CLI：`--rebuild-frames-fts` 重建 FTS5 表 + `--embed-search-test` eyeball 召回 |

## 搜索：单层 FTS5

```
query
  │
  └─→ FTS5 (字面匹配) ← FTSSearchEngine：bm25 排序 + snippet 高亮
          ↓
      [FrameSearchResult] / [TranscriptionSearchResult]（按 score 倒序）
```

`searchEngine` 类型声明为 `SearchEngine` 协议，`Services.init` 里实例化的是
`FTSSearchEngine(dbPool: dbImpl.dbPool)`——**和 DB 共用同一个 GRDB `DatabasePool`**。
保留协议这层抽象的意义：UI 永远只调 `services.searchEngine.searchFrames(...)`，
将来若换实现，UI 零改动。（当前唯一实现就是 `FTSSearchEngine`，不再有 Hybrid。）

> **`Vectors/` 目录为什么还在**：`VectorMath.swift` 不是残留——它是**说话人声纹系统**
> （`matchSpeaker` / `enrollSpeaker` / `addEmbeddingToSpeaker` / `VoiceTrainer` / `SpeakerOnnx`）
> 的 cosine 与 Float32 BLOB 编解码底座（`Data(floats:)` / `.asFloats`），被
> `PortraitDBImpl` / `TimelineDB` / `SpeakerOnnx` / `SileroVAD` 等多处调用，**正在使用**。
> 它跟**文本**语义搜索的移除无关——死掉的是文本 embedding 那条线，VectorMath 本身没死。
> `EmbedDumpCLI.swift` 名义上在 `Vectors/` 下，实际干的是 **重建 `frames_fts`（FTS5 表）** 和跑搜索召回测试，
> **不再依赖 bge-m3 embedder**，但文件仍 `import MLX` 并在入口 `eval(MLXArray(0))` 预热；
> 由 `App.swift` 的 `--rebuild-frames-fts` / `--embed-search-test` 两个命令调起，**仍然 live**。

## 实施阶段

| Phase | 任务 | 状态 |
|---|---|---|
| 1 | 建库 + schema + GRDB 7 | ✅ |
| 2 | `FTSSearchEngine` + UI 能搜 | ✅ |
| — | 语义/向量后端（bge-m3 / NLEmbedding / Hybrid / RRF） | ❌ 已移除 |

## 几个非显然的约定

1. **时间戳全 INTEGER UTC ms** —— 索引快、不解析 ISO，`Date(timeIntervalSince1970: ms/1000)` 一行互转
2. **永远不 `SELECT *`** —— 主表有 `ocr_words_json` 列（每帧可能 KB 级），
   SQLite overflow page 机制让"不读 = 0 成本"，明确列名拿到性能
3. **`focused` 字段保留** —— 即使单显示器，它仍然区分"主动操作"和"背景常驻"
4. **`StubPortraitDB` 已删** —— 仅在未来的 Tests target 中重建。Sources/ 永远是真 DB
5. **screenpipe 历史数据直接 import 进 `portrait.sqlite` 的 `frames` 表** —— 用
   `device_name='imported'` 标记区分（不复制媒体文件），写盘只动 `portrait.sqlite` / `raw_data/`

## 调用方进入点

```swift
// 写（采集层走）
let frameId = try await services.db.insertFrameWithOCR(record, ocr: result)

// 读（采集层走）
let pending = try await services.db.pendingAudioChunks(limit: 4)

// 搜索（UI 走）
let hits = try await services.searchEngine.searchFrames(query: "力矩传感器", limit: 50)
// 返回按 score 倒序的 [FrameSearchResult]，含 snippet 高亮
```

## 调试

```bash
# 看库内容
sqlite3 ~/.portrait/portrait.sqlite
> .schema frames
> SELECT COUNT(*) FROM frames;
> SELECT app_name, full_text FROM frames ORDER BY id DESC LIMIT 5;

# 看 FTS5 内部
> SELECT * FROM frames_fts WHERE frames_fts MATCH '"hello"';

# 重建 frames_fts（migration / import 把它丢了时）
# 通过 app 的 --rebuild-frames-fts 命令走 EmbedDumpCLI.runRebuildFramesFts
```
