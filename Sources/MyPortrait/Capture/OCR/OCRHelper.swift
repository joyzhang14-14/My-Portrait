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

    /// 交一帧的结果。
    enum Outcome {
        case reply(Reply)
        /// 没交出去:子进程已经不在 / 写管道失败。跟这帧无关。
        case notDelivered
        /// 交出去了,但处理这帧时子进程退出、超时被结束,或回复读不出来。
        case died(timedOut: Bool)
    }

    /// 一帧最多等这么久。平时几秒;文字特别多的整屏也远用不到,只防 Vision / 解码卡死。
    static let replyTimeout: Duration = .seconds(300)

    /// 一个跑着的子进程。主进程一轮补 OCR 开一个,补完 `close()`。
    actor Connection {
        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private var bytes: FileHandle.AsyncBytes.AsyncIterator

        init() throws {
            guard let exe = Bundle.main.executableURL else { throw CocoaError(.fileNoSuchFile) }
            process.executableURL = exe
            process.arguments = [OCRHelper.flag]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            bytes = output.fileHandleForReading.bytes.makeAsyncIterator()
            try process.run()
        }

        /// 交一帧,等回复。
        func run(_ req: Request) async -> Outcome {
            guard process.isRunning, let data = try? JSONEncoder().encode(req) else { return .notDelivered }
            do {
                try input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
            } catch {
                return .notDelivered
            }
            // 超时就结束手上这个子进程,管道随之 EOF,下面的读取返回。
            let proc = UncheckedProcess(process)
            let watchdog = Task {
                try await Task.sleep(for: OCRHelper.replyTimeout)
                if proc.process.isRunning { proc.process.terminate() }
                return true
            }
            defer { watchdog.cancel() }
            // 自己按 \n 切行:系统的按行读取还会在 U+2028 / U+2029 / U+0085 处断开,
            // 而 JSON 不转义这几个字符,OCR 文字里一出现就会把一条回复切成两半。
            // 一次只交一帧(DeferredOCRWorker 串行),拷出来等完再放回不会交错。
            var it = bytes
            var line: [UInt8] = []
            var eof = false
            do {
                while true {
                    guard let b = try await it.next() else { eof = true; break }
                    if b == 0x0A { break }
                    line.append(b)
                }
            } catch {
                eof = true
            }
            bytes = it
            if eof {
                watchdog.cancel()
                let timedOut = (try? await watchdog.value) == true
                return .died(timedOut: timedOut)
            }
            guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(line)) else { return .died(timedOut: false) }
            return .reply(reply)
        }

        /// 关 stdin,子进程读到 EOF 自己退出。
        func close() {
            try? input.fileHandleForWriting.close()
        }
    }

    /// Process 不是 Sendable;超时任务里只读 isRunning、调 terminate(),都是线程安全的。
    private struct UncheckedProcess: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }
}
