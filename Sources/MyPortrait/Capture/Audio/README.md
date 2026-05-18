# Audio/ — 音频采集 + 转录（P4）

待实现：麦克风常开 → VAD 分段 → 每段独立 wav → 插电时跑 WhisperKit 转录。

设计来源：design doc 第二节"音频采集策略" + "延迟转录策略"。

## 待新增文件

- `AudioCaptureService.swift` — `AVAudioEngine` 采麦克风，16kHz PCM
- `VADSegmenter.swift` — 端点检测，静音超阈值切段
- `WhisperKitWrapper.swift` — WhisperKit 转录调用（依赖 Power 模块决定何时跑）

## 阈值（抄 My-Orphies）

| 参数 | 值 |
|---|---|
| 段长 | 30s（2s 重叠） |
| 采样率 | 16 kHz |
| VAD 语音阈值 (mac) | 0.5 |
| VAD 静音阈值 | 0.35 |
| 最少语音帧 | 3 |
| 触发转录的最低语音比 | 2% |

## 文件布局

```
~/.portrait/audio_queue/
├── seg_2026-05-17T11-00-15.wav
├── seg_2026-05-17T11-00-15.meta.json
└── seg_2026-05-17T11-00-15.transcript.json
```

## 外部依赖

- WhisperKit（argmaxinc/WhisperKit，纯 Swift，CoreML/Neural Engine 加速）
  加入 `Package.swift` 的时机：P4 开始前。

## 调用 DB

- `insertAudioChunk` / `updateAudioChunkStatus`
- `insertTranscription`
- `pendingAudioChunks(limit:)`（PowerAwareScheduler 拿待转录列表）
