import SwiftUI

/// Compact settings menu anchored under the player's gear icon.
///
/// iOS 14 has no reliable `popover` anchor for SwiftUI, so this is a plain
/// floating panel drawn inside the player view. It replaces the full-screen
/// `PlayerSettingsSheet`: quality is expanded in place instead of hiding a
/// second "More" page, and the redundant "More" row is gone.
///
/// NOTE: quality is UI-only for now. Playback still uses the single itag18
/// progressive stream; selecting a value only records the preference.
struct PlayerSettingsPopover: View {
    @AppStorage("playerQuality") private var quality = "auto"
    @AppStorage("playerSubtitles") private var subtitles = false
    @AppStorage("speed") private var speed = 1.0
    @State private var showQuality = false

    private let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    private let qualities: [(key: String, label: String)] = [
        ("auto", "player.auto"), ("1080", "1080p"), ("720", "720p"),
        ("480", "480p"), ("360", "360p")
    ]
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.tr("player.settings", fallback: "Settings"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Button(action: close) {
                    Text(L10n.tr("common.ok", fallback: "Done"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.red)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)

            Divider().background(Color.white.opacity(0.12))

            // Quality — tap to expand options in place.
            Button {
                withAnimation(.easeOut(duration: 0.18)) { showQuality.toggle() }
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14)).foregroundColor(.primary)
                    Text(L10n.tr("player.quality")).font(.system(size: 13)).foregroundColor(.primary)
                    Spacer()
                    Text(qualityLabel).font(.system(size: 12)).foregroundColor(.secondary)
                    Image(systemName: showQuality ? "chevron.up" : "chevron.right")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if showQuality {
                VStack(spacing: 0) {
                    ForEach(qualities, id: \.key) { item in
                        Button {
                            quality = item.key
                        } label: {
                            HStack {
                                Text(qualityTitle(item)).font(.system(size: 12))
                                    .foregroundColor(quality == item.key ? .primary : .secondary)
                                Spacer()
                                if quality == item.key {
                                    Image(systemName: "checkmark").font(.system(size: 12)).foregroundColor(.red)
                                }
                            }
                            .padding(.horizontal, 30).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color.black.opacity(0.25))
                .transition(.opacity)
            }

            Divider().background(Color.white.opacity(0.12))

            Toggle(isOn: $subtitles) {
                HStack {
                    Image(systemName: "captions.bubble").font(.system(size: 14)).foregroundColor(.primary)
                    Text(L10n.tr("player.subtitles")).font(.system(size: 13)).foregroundColor(.primary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)

            Divider().background(Color.white.opacity(0.12))

            HStack {
                Image(systemName: "speedometer").font(.system(size: 14)).foregroundColor(.primary)
                Text(L10n.tr("player.speed")).font(.system(size: 13)).foregroundColor(.primary)
                Spacer()
                Picker("", selection: $speed) {
                    ForEach(speeds, id: \.self) { value in
                        Text(speedLabel(value)).tag(value)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .labelsHidden()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)

            Divider().background(Color.white.opacity(0.12))

            Button(action: close) {
                HStack {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 14)).foregroundColor(.primary)
                    Text(L10n.tr("player.pip")).font(.system(size: 13)).foregroundColor(.primary)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 300)
        .background(Color(red: 0.15, green: 0.15, blue: 0.16))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.14), lineWidth: 0.5))
    }

    private func qualityTitle(_ item: (key: String, label: String)) -> String {
        item.key == "auto" ? L10n.tr("player.auto", fallback: "Auto") : item.label
    }

    private var qualityLabel: String {
        switch quality {
        case "1080": return "1080p"
        case "720": return "720p"
        case "480": return "480p"
        case "360": return "360p"
        default: return L10n.tr("player.auto", fallback: "Auto")
        }
    }

    private func speedLabel(_ value: Double) -> String {
        value == 1 ? L10n.tr("player.normal", fallback: "Normal") : "\(value)×"
    }
}
