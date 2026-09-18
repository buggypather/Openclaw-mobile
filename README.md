# OpenClaw Mobile 0.8.0-dev

OpenClaw Gateway client with **Android as the primary target**, plus iOS, CLI, and lightweight Windows/macOS/Linux desktop clients.

## 0.8 Android-first size milestone

The Android app stays native and deliberately avoids heavyweight UI/runtime stacks.

- No Compose, AppCompat, Activity-KTX, Core-KTX, embedded WebView/Chromium, Electron, or desktop GUI runtime in the APK.
- `MainActivity` now uses platform `android.app.Activity` and platform widgets.
- Multi-file selection uses `ACTION_OPEN_DOCUMENT` directly.
- Device identity and Gateway tokens are encrypted with an AES/GCM key held by Android Keystore, removing the AndroidX Security runtime.
- Release builds enable R8 optimization/minification and resource shrinking.
- Unneeded third-party JAR metadata is excluded from release packaging.
- Android runtime dependencies are reduced to OkHttp and Bouncy Castle. Bouncy Castle remains for Ed25519 compatibility below Android 13, where platform `Signature` support for Ed25519 is not guaranteed.
- GitHub Actions builds `assembleRelease`, uploads the APK, reports its exact compressed size, and enforces an **8 MiB release APK budget**.
- FLTK and all desktop-only code are separate CMake targets and cannot enter the Android application package.

The exact optimized APK size is measured in GitHub Actions. This workspace does not have the Android SDK/Gradle installation required to produce a trustworthy local APK measurement.

## Android chat client

- User/assistant conversation bubbles.
- Streaming assistant text.
- **Copy**, **Continue**, and **Retry** actions under assistant replies.
- **Pause / Stop** while an agent run is active. OpenClaw exposes `chat.abort`, so Pause stops the active run while preserving the session for a later continuation.
- Multi-file attachment picker with removable attachment chips.
- Native `chat.send.attachments` support.
- Gateway-advertised attachment and payload size checks.
- Session browser backed by `sessions.subscribe` and `chat.history` hydration.
- Active-run tracking.
- Connecting, connected, reconnecting, offline, and pairing-required states.
- Sequence-gap recovery and authoritative history rehydration.
- Per-Gateway local transcript/session cache for offline reading.
- Persistent Ed25519 device identity and stored Gateway device token.

### Build Android

From the `android/` directory with Android SDK 35, JDK 17, and Gradle available:

```sh
gradle :app:assembleRelease
```

On GitHub, run the **build** workflow. The Android job uploads the `openclaw-android-release` artifact and writes the exact APK size into the workflow summary. It intentionally fails if the compressed release APK exceeds 8 MiB.

## Native core / CLI

Requirements: CMake 3.20+, C++20 compiler, OpenSSL development headers, Boost headers, and pthreads.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DOPENCLAW_BUILD_GUI=OFF
cmake --build build -j2
ctest --test-dir build --output-on-failure
```

Examples:

```sh
export OPENCLAW_GATEWAY_URL=ws://127.0.0.1:18789
export OPENCLAW_GATEWAY_TOKEN='bootstrap-token' # first pairing/bootstrap only

./build/openclaw-mobile connect
./build/openclaw-mobile sessions
./build/openclaw-mobile chat main "Hello"
./build/openclaw-mobile chat-file main "Read this" ./notes.pdf application/pdf
./build/openclaw-mobile abort main
./build/openclaw-mobile shell
```

On first connection the Gateway may return `PAIRING_REQUIRED`. Approve the exact request ID on the Gateway host with:

```sh
openclaw devices approve <requestId>
```

The resulting device token is then persisted and reused.

## 0.8 lightweight desktop GUI

`gui/main.cpp` is now a functional **FLTK** Gateway client for Windows, macOS, and Linux rather than a placeholder. It provides:

- Gateway URL and session selection.
- Persistent OpenClaw device identity/token through the shared native core.
- Connect/authenticate/pairing status.
- Session history hydration.
- Message sending.
- Live Gateway event display.
- **Pause / Stop** through `chat.abort`.
- Background Gateway I/O so the desktop UI remains responsive.

FLTK is desktop-only; nothing from FLTK is linked or packaged into Android.

### Build desktop GUI

Install FLTK plus the native CLI requirements, then:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DOPENCLAW_BUILD_GUI=ON
cmake --build build --target openclaw-gui -j2
```

The same GUI source builds on Linux, macOS, and Windows. CI jobs produce platform artifacts for all three. If FLTK is unavailable, use `-DOPENCLAW_BUILD_GUI=OFF` to build only the core/CLI.

## iOS / iPadOS

The native SwiftUI client remains under `ios/` and mirrors the main Android chat workflow: sessions, streaming transcript, attachments, offline cache, connection state, pairing, and Copy / Continue / Retry actions.

- CryptoKit Ed25519 identity.
- Keychain private-key and device-token storage.
- `URLSessionWebSocketTask` transport.
- Reconnect/backoff and history hydration.
- Multi-file picker and attachment size checks.
- Pause mapped to `chat.abort`.

Build with Xcode 16+ or CI:

```sh
xcodebuild -project ios/OpenClawMobile.xcodeproj \
  -scheme OpenClawMobile \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

A physical iPhone/iPad requires your Apple Development Team for signing.

## Protocol target

This build targets Gateway wire protocol v4 with challenge-first Ed25519 device authentication, persistent device tokens, `sessions.subscribe`, `sessions.messages.subscribe`, `chat.history`, `chat.send`, and `chat.abort`.

## CI targets

The GitHub Actions workflow now validates/builds:

- Native C++ core + tests on Linux.
- Optimized Android release APK + APK-size budget/report.
- Linux FLTK desktop executable.
- macOS FLTK application bundle.
- Windows FLTK executable.
- iOS simulator application.
