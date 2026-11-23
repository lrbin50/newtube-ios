# NewTube for iOS (iOS 14 build)

An independent iPhone and iPad port of [NewTube for Android](https://github.com/aleixrodriala/newtube/tree/6f96a1b42bb9272935360d7e5aec34d35f2753f0), originally based on SmartTube.

This fork targets **iOS / iPadOS 14.0 or newer**. It is based on [toofpaste/newtube-ios](https://github.com/toofpaste/newtube-ios) with the UI backported from iOS 17-only SwiftUI APIs to iOS 14 equivalents.

## Download

Grab `NewTube-unsigned.ipa` from [Releases](https://github.com/lrbin50/newtube-ios/releases). It is unsigned: install it with TrollStore or sign it with your preferred iOS signing tool. To verify a download on macOS, place the IPA and `SHA256SUMS.txt` together and run `shasum -a 256 -c SHA256SUMS.txt`.

## Using the port

- Browse and search the mobile YouTube site, or paste a YouTube link into the search field. Tap a video for the native AVKit player. The player supports background audio, lock-screen controls, playback speed, picture-in-picture and AirPlay where the device and stream support them.
- Collapse the player to browse. Use its menu to save to Watch later or download a compatible MP4 or M4A. Local history remembers your position. Long-press a Library entry to enqueue it. Play or shuffle a collection from its toolbar.
- Enable community titles, estimated dislikes and sponsor skipping in Settings. Use the TV code from SmartTube or YouTube to pair a television, then send the current video and queue from the player menu.
- Use the web player for comments or when a native stream is unavailable. Native extraction runs on the device. Stream availability, live playback and download quality depend on YouTube. Downloads use available combined video/audio streams or audio-only streams.
- Browsing uses a persistent WebKit session. Local Watch later, downloads and history are stored on the device. Google's embedded sign-in restrictions can limit access to account pages. Android device-code sign-in, native account sync, Chromecast discovery, advanced codec selection and DeArrow thumbnail replacement are outside this release.

## Building

**Important:** Xcode 26 and newer can only target iOS 15+. To produce an iOS 14 build you must use **Xcode 15** on macOS 13/14.

On macOS with Xcode 15 and XcodeGen installed, run `bash scripts/build-unsigned.sh`. The device IPA and checksum are written to `build/release/`. To run on a simulator, generate the project with `xcodegen generate`, open `NewTube.xcodeproj`, and select the NewTube scheme and an iPhone or iPad simulator.

Every push to main and manual Actions dispatch builds the Release configuration for a generic iOS device using a `macos-13` runner with Xcode 15. CI checks the arm64 executable, target platform, resources, unsigned state and archive integrity before publishing the IPA and SHA-256 checksum to a GitHub Release.

## iOS 14 changes

- `deploymentTarget.iOS` lowered from 17.0 to 14.0 in `project.yml`.
- `NavigationStack` / `ContentUnavailableView` / `LabeledContent` / `ShareLink` replaced with iOS 14-compatible SwiftUI views (see `App/Compat.swift`).
- `AsyncImage` replaced with a small URLSession-backed thumbnail loader.
- Toolbar, alert, action sheet, section headers and button roles backported to iOS 13/14 APIs.
- URLSession async calls bridged through `LegacyNetwork` for older SDK/runtime availability.
- Automatic inline PiP is guarded with `if #available(iOS 14.2, *)`; on iOS 14.0/14.1 PiP still works manually from the player.

## Credits

The port carries over the NewTube app mark and translates the upstream TV pairing protocol. SwiftUI, WebKit, AVKit and [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit/tree/7f75a2299dc329c0b7855afb25d47663a02855cb) supply the iOS interface and media stack. Community data comes from SponsorBlock, DeArrow and Return YouTube Dislike. See [credits](App/Notices/Credits.txt) and the [MIT license](LICENSE).
