import AVFoundation
import AppKit
import Foundation

/// EventSession 引擎的抽帧入口(引擎环境变量 `MP_FRAME_EXTRACTOR` 指向本 app 可执行文件,参数同 ffmpeg 那条:
/// `--extract-frame <mp4> <偏移秒> <输出 jpg>`)。从视频片段里取那一刻的帧存成 JPG,成功退出码 0。
/// 不跑迁移、不开库、不起窗口(在 App.init 最前面拦下)。
enum FrameExtractor {
    static let flag = "--extract-frame"

    static func runChild() -> Never {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), args.count > i + 3, let sec = Double(args[i + 2]) else { exit(2) }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: args[i + 1])))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        gen.generateCGImageAsynchronously(for: CMTime(seconds: sec, preferredTimescale: 600)) { cg, _, _ in
            if let cg, let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                ok = (try? data.write(to: URL(fileURLWithPath: args[i + 3]))) != nil
            }
            sem.signal()
        }
        sem.wait()
        exit(ok ? 0 : 1)
    }
}
