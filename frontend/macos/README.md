# drWisper macOS

Minimal native macOS dictation client for the FastAPI backend.

## Run

```bash
cd frontend/macos
swift run DrWisperMac
```

Or build a small `.app` bundle:

```bash
cd frontend/macos
chmod +x build-app.sh
./build-app.sh
open build/DrWisper.app
```

The app appears in the macOS menu bar. Hold `fn` to record, release it to send the WAV recording to:

```text
http://127.0.0.1:8000/api/transcribe/
```

When the backend returns text, the app puts it on the pasteboard and simulates `Cmd+V` into the active text field.

## Permissions

macOS needs:

- Microphone permission for recording.
- Accessibility permission for global key listening and simulated paste.

If paste does not work, open System Settings -> Privacy & Security -> Accessibility and enable the terminal or app host running `swift run`.

## Backend URL

Override the endpoint with:

```bash
defaults write DrWisperMac BackendURL "http://YOUR_BACKEND_HOST:8000/api/transcribe/"
```
