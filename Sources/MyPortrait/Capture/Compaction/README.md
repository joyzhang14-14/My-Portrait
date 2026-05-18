# Compaction/ — JPG → MP4 后台压缩（P3）

待实现：把 10 分钟前的 JPG 批量压成 HEVC MP4，删除原 JPG，更新 DB
让 frames 行指向 MP4 + offset_ms。

## 待新增文件

- `CompactionWorker.swift` — 后台循环（5 分钟一次，电池模式跳过）
- `HEVCEncoder.swift` — `AVAssetWriter` 包装，硬编（VideoToolbox）

## 触发参数（抄 My-Orphies）

| 参数 | 值 |
|---|---|
| 触发延迟（JPG 多久后压） | 10 分钟 |
| 巡逻周期 | 5 分钟 |
| 每块帧数 | 100（thermal Serious/Critical 时 50） |
| 帧率上限 | 30 fps |
| 电池模式 | 跳过 |
| 大量积压（5000+） + AC | 加速到 5s 一轮 |

## 调用 DB

- `framesToCompact(olderThanMs:, limit: 5000)`
- `replaceFramesWithVideoChunk(chunk:, frames:)`（事务）
- 事务 commit 后，调用方删 JPG
