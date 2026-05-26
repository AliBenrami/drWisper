import AppKit
import AVFoundation
import ApplicationServices
import Carbon
import Darwin
import Foundation

private let appInstanceLock = SingleInstanceLock(identifier: "dev.drwisper.mac")
private let logger = AppLogger()

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotkeyMonitor: FnKeyMonitor!
    private let recorder = AudioRecorder()
    private let transcriber = TranscriptionClient()
    private let pasteService = PasteService()

    private var isRecording = false
    private var statusText = "Ready"

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.log("launch build=\(AppInfo.build) path=\(AppInfo.executablePath) pid=\(getpid())")
        terminateDuplicateProcesses()
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "drWisper"

        hotkeyMonitor = FnKeyMonitor(
            onPressed: { [weak self] in self?.startRecording() },
            onReleased: { [weak self] in self?.stopRecordingAndTranscribe() }
        )
        hotkeyMonitor.start()

        requestMicrophoneAccess()
        promptForAccessibilityIfNeeded()
        rebuildMenu()
    }

    private func requestMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        default:
            break
        }
    }

    private func promptForAccessibilityIfNeeded() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        logger.log("accessibility_trusted=\(isTrusted)")
    }

    private func startRecording() {
        guard !isRecording else { return }

        do {
            try recorder.start()
            isRecording = true
            logger.log("recording_started")
            statusText = "Recording..."
            statusItem.button?.title = "● drWisper"
            rebuildMenu()
        } catch {
            logger.log("recording_start_failed error=\(error.localizedDescription)")
            showError("Could not start recording", error)
        }
    }

    private func stopRecordingAndTranscribe() {
        guard isRecording else { return }
        isRecording = false
        statusText = "Transcribing..."
        statusItem.button?.title = "… drWisper"
        rebuildMenu()

        do {
            let fileURL = try recorder.stop()
            logger.log("recording_stopped file=\(fileURL.path)")
            Task {
                await transcribeAndPaste(fileURL)
            }
        } catch {
            logger.log("recording_stop_failed error=\(error.localizedDescription)")
            showError("Could not finish recording", error)
        }
    }

    private func transcribeAndPaste(_ fileURL: URL) async {
        do {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? -1
            logger.log("transcription_started file_size=\(fileSize) endpoint=\(transcriber.endpoint.absoluteString)")
            let text = try await transcriber.transcribe(fileURL: fileURL)
            try? FileManager.default.removeItem(at: fileURL)
            logger.log("transcription_succeeded text_length=\(text.count)")

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                statusText = "No speech detected"
                statusItem.button?.title = "drWisper"
                rebuildMenu()
                return
            }

            do {
                try pasteService.paste(text)
                logger.log("paste_succeeded")
                statusText = "Inserted text"
            } catch DrWisperError.accessibilityNotTrusted {
                logger.log("paste_copied_but_accessibility_missing")
                statusText = "Copied text; enable Accessibility to auto-paste"
                statusItem.button?.title = "drWisper"
                rebuildMenu()
                return
            }

            statusItem.button?.title = "drWisper"
            rebuildMenu()
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            logger.log("transcription_or_paste_failed error=\(error.localizedDescription)")
            showError("Transcription failed", error)
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Hold fn to dictate", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Auto-paste: \(AXIsProcessTrusted() ? "Enabled" : "Needs Accessibility")", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Backend: \(transcriber.endpoint.absoluteString)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Build: \(AppInfo.build)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Path: \(AppInfo.executablePath)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Log: \(logger.logFile.path)", action: nil, keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())
        let accessibility = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibility.target = self
        menu.addItem(accessibility)

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func showError(_ title: String, _ error: Error) {
        statusText = title
        statusItem.button?.title = "drWisper"
        rebuildMenu()

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func terminateDuplicateProcesses() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentPath = AppInfo.executablePath

        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier != currentPID else { continue }
            guard app.localizedName == "DrWisperMac" || app.localizedName == "drWisper" else { continue }

            let duplicatePath = app.executableURL?.path ?? "unknown"
            logger.log("terminating_duplicate pid=\(app.processIdentifier) path=\(duplicatePath) current_path=\(currentPath)")
            app.terminate()
        }
    }
}

@MainActor
final class FnKeyMonitor {
    private let onPressed: () -> Void
    private let onReleased: () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false

    init(onPressed: @escaping () -> Void, onReleased: @escaping () -> Void) {
        self.onPressed = onPressed
        self.onReleased = onReleased
    }

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        let isFunctionDown = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.function)

        if isFunctionDown && !isDown {
            isDown = true
            onPressed()
        } else if !isFunctionDown && isDown {
            isDown = false
            onReleased()
        }
    }
}

@MainActor
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?

    func start() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drwisper-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let audioRecorder = try AVAudioRecorder(url: url, settings: settings)
        audioRecorder.delegate = self
        audioRecorder.isMeteringEnabled = true
        audioRecorder.record()

        recorder = audioRecorder
        currentURL = url
    }

    func stop() throws -> URL {
        guard let recorder, let currentURL else {
            throw DrWisperError.noActiveRecording
        }

        recorder.stop()
        self.recorder = nil
        self.currentURL = nil

        return currentURL
    }
}

@MainActor
final class TranscriptionClient {
    let endpoint: URL

    init() {
        let configured = UserDefaults.standard.string(forKey: "BackendURL")
        endpoint = URL(string: configured ?? "http://127.0.0.1:8000/api/transcribe/")!
    }

    func transcribe(fileURL: URL) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: fileURL)
        request.httpBody = makeMultipartBody(
            boundary: boundary,
            fieldName: "file",
            filename: fileURL.lastPathComponent,
            contentType: "audio/wav",
            data: audioData
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No response body"
            throw DrWisperError.badServerResponse(body)
        }

        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return decoded.text
    }

    private func makeMultipartBody(
        boundary: String,
        fieldName: String,
        filename: String,
        contentType: String,
        data: Data
    ) -> Data {
        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        body.appendString("\r\n--\(boundary)--\r\n")
        return body
    }
}

final class PasteService {
    func paste(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw DrWisperError.pasteboardWriteFailed
        }

        guard AXIsProcessTrusted() else {
            throw DrWisperError.accessibilityNotTrusted
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw DrWisperError.eventSourceUnavailable
        }
        let keyCode = CGKeyCode(kVK_ANSI_V)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            throw DrWisperError.keyboardEventUnavailable
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

final class SingleInstanceLock {
    private let fileDescriptor: Int32

    init?(identifier: String) {
        let lockPath = "/tmp/\(identifier).lock"
        fileDescriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)

        guard fileDescriptor >= 0 else {
            return nil
        }

        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(fileDescriptor)
            return nil
        }
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}

enum AppInfo {
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }

    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? "unknown"
    }
}

final class AppLogger {
    let logFile: URL
    private let queue = DispatchQueue(label: "dev.drwisper.mac.logger")
    private let formatter: ISO8601DateFormatter

    init() {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("drWisper", isDirectory: true)

        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        logFile = logsDirectory.appendingPathComponent("drwisper.log")
        formatter = ISO8601DateFormatter()
    }

    func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async { [logFile] in
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logFile.path),
                   let handle = try? FileHandle(forWritingTo: logFile) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                } else {
                    try? data.write(to: logFile)
                }
            }
        }
    }
}

struct TranscriptionResponse: Decodable {
    let text: String
}

enum DrWisperError: LocalizedError {
    case noActiveRecording
    case badServerResponse(String)
    case accessibilityNotTrusted
    case pasteboardWriteFailed
    case eventSourceUnavailable
    case keyboardEventUnavailable

    var errorDescription: String? {
        switch self {
        case .noActiveRecording:
            "No active recording was found."
        case let .badServerResponse(body):
            "Backend returned an error: \(body)"
        case .accessibilityNotTrusted:
            "Accessibility permission is not enabled for drWisper. Enable it in System Settings > Privacy & Security > Accessibility."
        case .pasteboardWriteFailed:
            "Could not write the transcription to the macOS pasteboard."
        case .eventSourceUnavailable:
            "Could not create a macOS keyboard event source for paste."
        case .keyboardEventUnavailable:
            "Could not create the Cmd+V keyboard event."
        }
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()

if appInstanceLock == nil {
    NSApp.terminate(nil)
} else {
    app.delegate = delegate
    app.run()
}
