# NetLab

An in-app network inspector and response editor for iOS apps. NetLab records every request the app makes, learns the app's API from that traffic, and lets a tester change the next response of any endpoint, with no scenarios to write and no sample responses to maintain.

- **Traffic**: every call with headers, bodies, timing, cURL and HAR export.
- **Endpoints**: calls grouped into endpoints such as `GET /payments/{id}/status`, with the responses seen per status code.
- **Overrides**: edit fields of a real response, replace it, or pick a failure (offline, timeout, slow, connection lost, status code, broken body) for the next call, the next N calls or every call. Steps queue per endpoint for polling flows.
- **Saved overrides**: every override you arm from the editor is kept per endpoint, including after a relaunch, so you can arm it again or adjust it without re-adding fields.
- **Presets and learned API**: save and share override setups, and share what NetLab has learned between testers.

Requires iOS 16.

## Installation

Add the package in Xcode or in `Package.swift`:

```swift
.package(url: "https://github.com/aliabdelkhalekY/NetLab.git", branch: "main")
```

and add the `NetLab` product to the app target.

## Usage

Start NetLab when the app launches, in Debug builds:

```swift
import NetLab

#if DEBUG
NetLab.start(.init(
    entry: [.floatingButton, .shake],
    redaction: .default.adding(headers: ["X-Session"], jsonKeys: ["pin"]),
    storage: .memory
))
#endif
```

Open the panel from the floating button, by shaking the device, or from code with `NetLab.present()`.

For app behaviour that never touches the network, register a switch and read it where the behaviour lives:

```swift
NetLab.register(.choice("Token refresh", ["Succeed", "Fail", "Hang"]))
let refresh = NetLab.value(of: "Token refresh")
```

## How overrides stay accurate

An edit is stored as a list of changes (JSON Patch) and applied to the next real response, so IDs, amounts and timestamps stay current. Changes whose fields are missing are reported as skipped. When the real call fails, the override is not used and waits for the next call. Overridden responses are never stored in `URLCache`.

## Privacy

- Recorded calls live in memory only, capped at 500 calls and 1 MB per body.
- Keeping the learned API on the device is opt-in. It is stored in Caches with complete file protection, excluded from backups, and redacted.
- Redaction applies to storage, exports and sharing. Defaults cover authorization, cookies, API keys, tokens, passwords, secrets, card numbers, CVV and IBAN.
- In Release builds every entry point is a no-op: no interception, no recording, no window.

## Coverage

| Traffic | Covered |
|---|---|
| `URLSession.shared`, default and ephemeral sessions | Yes |
| WKWebView pages | No |
| Background sessions | No |
| Sessions that set their own `protocolClasses` | No |

## Modules

| Module | Contents |
|---|---|
| `NetLabCore` | Interception, recorder, endpoint grouping, learned schemas, JSON Patch, override queues, redaction, persistence, export |
| `NetLabUI` | SwiftUI screens, floating button, banner. Every screen has Xcode previews backed by `MockBackend` |
| `NetLab` | Public API: `start`, `present`, `dismiss`, `stop`, `register`, `value(of:)` |

## Tests

```bash
xcodebuild test -scheme NetLab -destination 'platform=iOS Simulator,name=iPhone 15'
```
