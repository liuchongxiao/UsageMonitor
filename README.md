# UsageMonitor

UsageMonitor is a macOS menu bar app with a WidgetKit widget for tracking Codex and Claude usage.

## Downloads

Prebuilt release artifacts are checked into `dist/`:

- `dist/UsageMonitor-0.1.0-macos.dmg`
- `dist/UsageMonitor-0.1.0-macos.zip`
- `dist/UsageMonitor-0.1.0-checksums.txt`

## What it does

- Shows Codex and Claude usage in the menu bar
- Shows a macOS widget with the same data
- Reads Codex usage from the local Codex app-server and Claude usage from the local Claude Code account endpoint / cache
- Keeps the widget data local on your machine

## Privacy

UsageMonitor does not bundle your Codex or Claude credentials.

- It does not upload your local `.codex/` or `.claude/` folders
- It does not send prompts or model turns to either service
- The widget reads only the local snapshot written by the app

Each user authorizes with their own installed tools:

- Codex: sign in to your own Codex.app installation
- Claude: sign in to your own Claude Code installation and allow Keychain access to `Claude Code-credentials` if prompted

## Build

```sh
xcodebuild -project UsageMonitor.xcodeproj -scheme UsageMonitor -configuration Debug -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
```

## Notes

The repository contains both source and release artifacts. Build locally from the Xcode project if you want to regenerate them.
