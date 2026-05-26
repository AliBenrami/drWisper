import AppKit
import AVFoundation
import ApplicationServices
import Carbon
import Foundation

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
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func startRecording() {
        guard !isRecording else { return }

        do {
            try recorder.start()
            isRecording = true
            statusText = "Recording..."
            statusItem.button?.title = "● drWisper"
            rebuildMenu()
        } catch {
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
            Task {
                await transcribeAndPaste(fileURL)
            }
        } catch {
            showError("Could not finish recording", error)
        }
    }

    private func transcribeAndPaste(_ fileURL: URL) async {
        do {
            let text = try await transcriber.transcribe(fileURL: fileURL)
            try? FileManager.default.removeItem(at: fileURL)

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                statusText = "No speech detected"
                statusItem.button?.title = "drWisper"
                rebuildMenu()
                return
            }

            pasteService.paste(text)
            statusText = "Inserted text"
            statusItem.button?.title = "drWisper"
            rebuildMenu()
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
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
        menu.addItem(NSMenuItem(title: "Backend: \(transcriber.endpoint.absoluteString)", action: nil, keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
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
    func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let keyCode = CGKeyCode(kVK_ANSI_V)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

struct TranscriptionResponse: Decodable {
    let text: String
}

enum DrWisperError: LocalizedError {
    case noActiveRecording
    case badServerResponse(String)

    var errorDescription: String? {
        switch self {
        case .noActiveRecording:
            "No active recording was found."
        case let .badServerResponse(body):
            "Backend returned an error: \(body)"
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
app.delegate = delegate
app.run()
