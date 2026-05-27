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
open build/drWisper.app
```

The app appears in the macOS menu bar. Hold `fn` to record, release it to send the WAV recording to:

```text
http://127.0.0.1:8000/api/transcribe/
```

The generated app bundle allows HTTP traffic because the development backend runs on a private Tailscale/local address instead of HTTPS.

## Update

Use the packaged app for normal testing. Quit any running copy before opening the rebuilt app:

```bash
pkill -f 'Contents/MacOS/(DrWisperMac|drWisper)'
./build-app.sh
open build/drWisper.app
```

The menu shows the packaged Git build and executable path. If the path is not `~/Applications/drWisper.app/Contents/MacOS/drWisper` after running `update-and-run.sh`, an old development executable is still running.

Or use the one-command update runner:

```bash
./update-and-run.sh
```

The update runner installs the app at `~/Applications/drWisper.app`. Grant Accessibility permission to that installed app, not to the temporary build output.

For local development, create a stable signing identity once before rebuilding the app repeatedly:

```bash
./setup-local-signing.sh
./update-and-run.sh
```

Without a stable signing identity, macOS may reset Accessibility permission after each rebuild because the ad-hoc code signature changes.

When the backend returns text, the app puts it on the pasteboard and simulates `Cmd+V` into the active text field.

## Permissions

macOS needs:

- Microphone permission for recording.
- Accessibility permission for global key listening and simulated paste.

If paste does not work, open System Settings -> Privacy & Security -> Accessibility and enable `~/Applications/drWisper.app`. If you run from SwiftPM instead, enable the terminal app that launched `swift run`.

## Backend URL

Override the endpoint with:

```bash
defaults write DrWisperMac BackendURL "http://YOUR_BACKEND_HOST:8000/api/transcribe/"
```
