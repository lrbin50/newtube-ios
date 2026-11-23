# NewTube for iOS

An independent iPhone and iPad port of [NewTube for Android](https://github.com/aleixrodriala/newtube/tree/6f96a1b42bb9272935360d7e5aec34d35f2753f0), originally based on SmartTube. Requires iOS or iPadOS 17 or newer.

## Download

Get `NewTube-unsigned.ipa` from [Releases](https://github.com/toofpaste/newtube-ios/releases). Sign it with your preferred iOS signing tool before installing it on a device. To check the download on macOS, place the IPA and `SHA256SUMS.txt` together and run `shasum -a 256 -c SHA256SUMS.txt`.

## Using the port

- Browse and search the mobile YouTube site, or paste a YouTube link into the search field. Tap a video for the native AVKit player. The player supports background audio, lock-screen controls, playback speed, picture-in-picture and AirPlay where the device and stream support them.
- Collapse the player to browse. Use its menu to save to Watch later or download a compatible MP4 or M4A. Local history remembers your position. Long-press a Library entry to enqueue it. Play or shuffle a collection from its toolbar.
- Enable community titles, estimated dislikes and sponsor skipping in Settings. Use the TV code from SmartTube or YouTube to pair a television, then send the current video and queue from the player menu.
- Use the web player for comments or when a native stream is unavailable. Native extraction runs on the device. Stream availability, live playback and download quality depend on YouTube. Downloads use available combined video/audio streams or audio-only streams.
- Browsing uses a persistent WebKit session. Local Watch later, downloads and history are stored on the device. Google's embedded sign-in restrictions can limit access to account pages. Android device-code sign-in, native account sync, Chromecast discovery, advanced codec selection and DeArrow thumbnail replacement are outside this release.

## Building

On macOS with Xcode and XcodeGen installed, run `bash scripts/build-unsigned.sh`. The device IPA and checksum are written to `build/release/`. To run on a simulator, generate the project with `xcodegen generate`, open `NewTube.xcodeproj`, and select the NewTube scheme and an iPhone or iPad simulator.

Every push to main and manual Actions dispatch builds the Release configuration for a generic iOS device. CI checks the arm64 executable, target platform, resources, unsigned state and archive integrity before publishing the IPA and SHA-256 checksum to a GitHub Release. [Build runs](https://github.com/toofpaste/newtube-ios/actions/workflows/ios-release.yml)

## Credits

The port carries over the NewTube app mark and translates the upstream TV pairing protocol. SwiftUI, WebKit, AVKit and [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit/tree/7f75a2299dc329c0b7855afb25d47663a02855cb) supply the iOS interface and media stack. Community data comes from SponsorBlock, DeArrow and Return YouTube Dislike. See [credits](App/Notices/Credits.txt) and the [MIT license](LICENSE).
