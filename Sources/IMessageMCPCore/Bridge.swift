import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downscales an image file (HEIC, PNG, ...) to a JPEG no larger than `maxPixels` on its long side.
func jpegData(fromImageAt path: String, maxPixels: Int) -> Data? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? out as Data : nil
}

struct ProcessResult {
    let status: Int32
    let output: String
    let timedOut: Bool
}

func runProcess(_ path: String, _ arguments: [String], input: String, timeout: TimeInterval) -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    do {
        try process.run()
    } catch {
        return ProcessResult(status: 127, output: "\(error.localizedDescription)", timedOut: false)
    }
    stdin.fileHandleForWriting.write(Data(input.utf8))
    try? stdin.fileHandleForWriting.close()
    if done.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        return ProcessResult(status: 1, output: "timed out after \(Int(timeout))s", timedOut: true)
    }
    let pipe = process.terminationStatus == 0 ? stdout : stderr
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return ProcessResult(
        status: process.terminationStatus,
        output: text.trimmingCharacters(in: .whitespacesAndNewlines),
        timedOut: false)
}

/// The real Mac: a native confirmation dialog, and AppleScript to the Messages app.
public final class LiveBridge: SystemBridge {
    /// Seconds the dialog waits before giving up without sending.
    public var confirmTimeout: TimeInterval = 300

    public init() {}

    static let sendScript = """
        on run argv
            set theText to item 1 of argv
            set theTarget to item 2 of argv
            set theMode to item 3 of argv
            tell application "Messages"
                if theMode is "chat" then
                    send theText to chat id theTarget
                else if theMode is "sms" then
                    send theText to participant theTarget of (1st account whose service type = SMS)
                else
                    send theText to participant theTarget of (1st account whose service type = iMessage)
                end if
            end tell
        end run
        """

    public func send(text: String, target: String, mode: String) -> (ok: Bool, output: String) {
        let result = runProcess("/usr/bin/osascript", ["-", text, target, mode], input: LiveBridge.sendScript, timeout: 60)
        return (result.status == 0 && !result.timedOut, result.output)
    }

    /// Runs `work` on a worker thread, exits when it returns, and leaves the main
    /// thread to AppKit.
    ///
    /// A tool call blocks its thread for a long time: reading stdin, waiting on
    /// osascript, polling for delivery. If that were the main thread, the
    /// confirmation dialog could not close after a click (it stays on screen,
    /// frozen, with a beach ball) because nothing is running the event loop.
    public static func runOffMainThread(_ work: @escaping () -> Void) -> Never {
        let thread = Thread {
            work()
            exit(0)
        }
        thread.stackSize = 8 << 20  // same as a main thread
        thread.start()
        CFRunLoopRun()
        exit(0)
    }

    private var appStarted = false

    public func confirm(text: String, recipient: String) -> ConfirmAnswer {
        if Thread.isMainThread { return present(text: text, recipient: recipient) }
        // Start the app's event loop the first time a dialog is needed. It never
        // returns; the dialog runs inside it. These are run loop blocks, not
        // DispatchQueue.main ones: a main-queue block that never returns would
        // stall that queue.
        //
        // Wait for that block to start before queueing the dialog. The run loop
        // takes its pending blocks as one batch, so a dialog block in the same
        // batch as the never-returning one would never run.
        let loopReady = DispatchSemaphore(value: 0)
        onMainRunLoop {
            guard !self.appStarted else {
                loopReady.signal()
                return
            }
            self.appStarted = true
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            loopReady.signal()
            app.run()
        }
        loopReady.wait()
        var answer = ConfirmAnswer.timedOut
        let done = DispatchSemaphore(value: 0)
        onMainRunLoop {
            answer = self.present(text: text, recipient: recipient)
            done.signal()
        }
        done.wait()
        return answer
    }

    private func onMainRunLoop(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func present(text: String, recipient: String) -> ConfirmAnswer {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let shown = text.count > 3000
            ? String(text.prefix(3000)) + "\n\n(\(text.count - 3000) more characters not shown)" : text
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Send this text?"
        alert.informativeText =
            "To: \(recipient)\n\n\(shown)\n\n"
            + "Always Allow sends it and lets Claude text this conversation without asking again."
        let send = alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Always Allow")
        let cancel = alert.addButton(withTitle: "Don't Send")
        // Return must never send a text by accident: make Don't Send the default.
        send.keyEquivalent = ""
        cancel.keyEquivalent = "\r"

        let timer = Timer(timeInterval: confirmTimeout, repeats: false) { _ in app.abortModal() }
        RunLoop.main.add(timer, forMode: .common)
        alert.window.level = .floating
        app.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        timer.invalidate()
        alert.window.orderOut(nil)

        switch response {
        case .alertFirstButtonReturn: return .send
        case .alertSecondButtonReturn: return .alwaysAllow
        case .alertThirdButtonReturn: return .dontSend
        default: return .timedOut
        }
    }
}
