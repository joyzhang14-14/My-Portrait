import CoreGraphics
import Foundation
import ImageIO
import os.log

/// 延后 OCR 的独立子进程(10-26 update)。Vision 的识别模型和全分辨率工作缓冲只活在
/// 这个进程里,主进程常驻内存不背这份;一轮补完主进程关掉 stdin,子进程退出,内存全还。
///
/// 子进程就是 app 自己的可执行文件加 `--ocr-helper`,在 `MyPortraitApp.init` 最先拦截,
/// 不起窗口、不起 Services、不碰数据库。协议是一行一个 JSON:
///   主 → 子:`Request`(帧 id + 待 OCR 的 HEIC 路径)
///   子 → 主:`Reply`(OCR 结果 + 换好的 JPG 路径)
/// 写库、删 HEIC 都在主进程(`DeferredOCRWorker`)。
enum OCRHelper {

    static let flag = "--ocr-helper"

    struct Request: Codable {
        let id: Int64
        let path: String
    }

    struct Reply: Codable {
        let id: Int64
        /// false = 图读不出来(文件没了 / 坏了)。
        let readable: Bool
        let ocr: OCRResult?
        /// OCR 后按常规写好的 JPG;写失败为 nil(HEIC 留着)。
        let jpg: String?
    }

    // MARK: - 子进程

    static func runChild() -> Never {
        Task.detached {
            let logger = Logger(subsystem: "com.myportrait.capture", category: "ocr-helper")
            let writer = await MainActor.run { SnapshotWriter(config: .default, reporter: UnimplementedReporter()) }
            while let line = readLine() {
                guard let req = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) else { continue }
                let reply = await process(req, writer: writer, logger: logger)
                guard let data = try? JSONEncoder().encode(reply) else { continue }
                FileHandle.standardOutput.write(data + Data("\n".utf8))
            }
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func process(_ req: Request, writer: SnapshotWriter, logger: Logger) async -> Reply {
        let heic = URL(fileURLWithPath: req.path)
        guard let src = CGImageSourceCreateWithURL(heic as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return Reply(id: req.id, readable: false, ocr: nil, jpg: nil)
        }
        var ocr: OCRResult?
        do {
            ocr = try await OCRService.recognizeUncached(image: image, config: .default)
        } catch {
            logger.warning("frame \(req.id, privacy: .public): OCR failed: \(String(describing: error), privacy: .public)")
        }
        // HEIC → 常规 JPG(1920 宽)。写失败就留着 HEIC(ImageIO 照样读得了)。
        var jpg: String?
        if heic.pathExtension == SnapshotWriter.pendingOCRExt {
            let out = heic.deletingPathExtension().appendingPathExtension("jpg")
            do {
                try await writer.write(image: image, to: out)
                jpg = out.path
            } catch {
                logger.warning("frame \(req.id, privacy: .public): JPG write failed: \(String(describing: error), privacy: .public)")
            }
        }
        return Reply(id: req.id, readable: true, ocr: ocr, jpg: jpg)
    }

    // MARK: - 主进程这头

    /// 一个跑着的子进程。主进程一轮补 OCR 开一个,补完 `close()`。
    actor Connection {
        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator

        init() throws {
            guard let exe = Bundle.main.executableURL else { throw CocoaError(.fileNoSuchFile) }
            process.executableURL = exe
            process.arguments = [OCRHelper.flag]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            lines = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
            try process.run()
        }

        /// 交一帧,等回复。子进程退出了(崩溃 / 被系统杀)返回 nil。
        func run(_ req: Request) async -> Reply? {
            guard process.isRunning, let data = try? JSONEncoder().encode(req) else { return nil }
            do {
                try input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
                // 一次只交一帧(DeferredOCRWorker 串行),拷出来等完再放回不会交错。
                var it = lines
                let line = try await it.next()
                lines = it
                guard let line else { return nil }
                return try JSONDecoder().decode(Reply.self, from: Data(line.utf8))
            } catch {
                return nil
            }
        }

        /// 关 stdin,子进程读到 EOF 自己退出。
        func close() {
            try? input.fileHandleForWriting.close()
        }
    }
}
