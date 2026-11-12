# OmniDrop

OmniDrop is a local file-sharing app for Android and Windows. It discovers OmniDrop devices on a local network and supports trusted, encrypted transfers, resumable file sends, chats, and clipboard sharing. Android can also host a Wi-Fi Direct group when the device supports it.

## Features

- Nearby-device radar and pairing with a verification code.
- Same-Wi-Fi and Wi-Fi Direct transport choices.
- Encrypted transfers with progress, pause/resume, cancellation, and retry support.
- Incoming-transfer approval and a configurable Downloads/OmniDrop destination.
- Transfer records with direction, peer names, transfer date, duration, size, and location.
- Private chat, shared clipboard, profile, themes, and a built-in file explorer.

## Download the built apps

Release files are in [`dist/`](dist/):

- `OmniDrop-Android.apk` — Android installer.
- `OmniDrop-Windows.zip` — complete portable Windows app. Extract the ZIP and run `omni_drop.exe`.
- `OmniDrop.exe` — the Windows application executable; keep it beside the DLL files and `data/` folder included in the ZIP.

The app creates `Downloads/OmniDrop` the first time it runs. Android uses the Downloads media store on current Android versions.

## Build from source

Requirements: Flutter SDK, Android SDK and Java 17 for Android builds, plus Visual Studio C++ desktop build tools for Windows builds.

```powershell
flutter pub get
flutter build apk --release
flutter build windows --release
```

Android output: `build/app/outputs/flutter-apk/app-release.apk`  
Windows output: `build/windows/x64/runner/Release/`

## Security

Pairing establishes a per-device secret stored through the platform secure store. Trusted file transfers authenticate the paired peer and encrypt file contents in transit. Incoming transfers require approval. Only pair with devices you recognize and approve verification codes that match on both screens.
