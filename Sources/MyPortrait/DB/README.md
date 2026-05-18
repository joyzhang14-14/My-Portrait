# DB/ — 持久层

`PortraitDB`：屏幕帧 + 视频块 + 音频段 + 转录的本地 SQLite 持久层 + 全文搜索 +
（未来）语义检索。

## 技术栈

- **GRDB.swift 7** — Swift-native SQLite，async/await 原生支持
- **SQLite (系统自带)** — macOS 自带版本，**只编进了 FTS5，没有 ICU / LOAD_EXTENSION**
- **Foundation 后端的自定义分词器** — 因为系统 sqlite3 没编 ICU，我们用
  `String.enumerateSubstrings(.byWords)`（Darwin 上**内部就是 ICU**）写了一个
  FTS5CustomTokenizer，效果等价于 ICU 分词器
- **WAL 模式** — 多读单写并发不阻塞

## 文件位置

数据库：`~/.portrait/portrait.sqlite`（+ `.wal` / `.shm` 同目录）。
模型缓存：`~/.portrait/models/bge-m3/`（~2.5 GB，首启自动下载）。

## Schema（migrations）

```
v1_screen_capture         video_chunks + frames + frames_fts (FTS5 + custom tokenizer)
v2_audio_capture          audio_chunks + audio_transcriptions
v3_transcriptions_fts     transcriptions_fts (FTS5 + same tokenizer)
```

详见 [Schema.swift](Schema.swift)。**Migration 一旦发布就不改**，新 schema 加新 migration。

## 模块文件

| 文件 | 职责 |
|---|---|
| `Schema.swift` | DatabaseMigrator —— v1/v2/v3 |
| `PortraitDBImpl.swift` | `PortraitDB` 协议实现，actor + DatabasePool (WAL) |
| `FoundationTokenizer.swift` | 自定义 FTS5 分词器（ICU 通过 Foundation 借道） |
| `RetentionWorker.swift` | 自动删除，24h cadence，读 SettingsKeys.retentionDays/autoDeleteMode |
| `Records/*.swift` | 4 个 GRDB record struct（Codable + Persistable，**不是 Record 子类**） |
| `Search/SearchEngine.swift` | 搜索协议 + result 类型 |
| `Search/FTSSearchEngine.swift` | Phase 2：纯 FTS5 + bm25 + snippet |
| `Vectors/VectorEmbedder.swift` | 向量化协议（推理待 Phase 4） |
| `Vectors/BGEM3ModelManager.swift` | bge-m3 模型下载 + 本地缓存 |
| `Vectors/BGEM3VectorEmbedder.swift` | bge-m3 embedder stub（下载 OK，推理 Phase 4） |

## 搜索分层（Q2 蓝图）

```
query
  │
  ├─→ Layer 1: FTS (字面)        ← 当前：FTSSearchEngine 已实现
  │       ↓
  │   命中文档集 A
  │
  ├─→ Layer 2: 向量 (语义)        ← Phase 3-4：bge-m3 + cosine
  │       ↓
  │   语义近文档集 B
  │
  └─→ Layer 3: RRF 融合            ← Phase 4：HybridSearchEngine
          ↓
      最终结果（A ∪ B 按 RRF 排序）
```

UI 调 `services.searchEngine.searchFrames(...)`。Phase 4 把 `searchEngine`
从 `FTSSearchEngine` 换成 `HybridSearchEngine`，**UI 零改动**。

## 实施阶段

| Phase | 任务 | 状态 |
|---|---|---|
| 1 | 建库 + schema + GRDB 7 | ✅ |
| 2 | FTSSearchEngine + UI 能搜 | ✅ |
| 3 | sqlite-vec 集成 + bge-m3 下载 + 历史回灌 | 模型下载 ✅；推理 ❌；回灌 ❌ |
| 4 | HybridSearchEngine + RRF 排序 | ❌ |

### Phase 3 注意事项

- **sqlite-vec 不可用**：系统 sqlite3 编进了 `OMIT_LOAD_EXTENSION`，不能 load
  外部扩展。替代方案：
  1. 直接在 SQLite 存 BLOB 列（Float32 packed），Swift 端读出来做 cosine
  2. 用 Apple MLX-Swift 跑 bge-m3 推理
  3. 7000 条向量 × 1024 维 ≈ 28 MB，全内存暴力 cosine 微秒级，**不需要专门的向量索引**

### Phase 4 注意事项

- **RRF (Reciprocal Rank Fusion)** 公式：`RRF(d) = Σ 1 / (k + rank_i(d))`，
  k=60 是经验值
- 输入两个排好序的列表（FTS top-N 和向量 top-N），输出融合排名
- HybridSearchEngine = FTSSearchEngine + BGEM3VectorEmbedder + RRF

## 几个非显然的约定

1. **时间戳全 INTEGER UTC ms** —— 索引快、不解析 ISO，`Date(timeIntervalSince1970: ms/1000)` 一行互转
2. **永远不 `SELECT *`** —— 主表有 `ocr_words_json` 列（每帧可能 KB 级），
   SQLite overflow page 机制让"不读 = 0 成本"，明确列名拿到性能
3. **`focused` 字段保留** —— 即使单显示器，它仍然区分"主动操作"和"背景常驻"
4. **`StubPortraitDB` 已删** —— 仅在未来的 Tests target 中重建。Sources/ 永远是真 DB
5. **不动 `~/.screenpipe/`** —— 那是外部 daemon 的数据，要复用只能 copy 不能 mv

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

# 调试模型下载
log stream --predicate 'subsystem == "com.myportrait.db" AND category == "model"' --level info
```
