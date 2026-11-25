import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var playback: Playback
    @EnvironmentObject var tv: Television
    @ObservedObject private var l10n = L10n.shared
    @AppStorage("sponsorBlock") private var skip = true
    @AppStorage("deArrow") private var titles = false
    @AppStorage("showDislikes") private var votes = false
    @AppStorage("speed") private var speed = 1.0
    @State private var code = ""
    @State private var pairing = false
    @State private var confirmClear = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(L10n.tr("settings.language"))) {
                    Picker(L10n.tr("settings.language"), selection: $l10n.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.label).tag(lang)
                        }
                    }
                    .pickerStyle(DefaultPickerStyle())
                }
                Section(header: Text(L10n.tr("settings.playback"))) {
                    Picker(L10n.tr("settings.defaultSpeed"), selection: $speed) {
                        ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { value in
                            Text("\(value, specifier: "%g")×").tag(value)
                        }
                    }
                }
                Section(
                    header: Text(L10n.tr("settings.community")),
                    footer: Text(L10n.tr("settings.community.footer"))
                ) {
                    Toggle(L10n.tr("settings.skipSponsors"), isOn: $skip)
                    Toggle(L10n.tr("settings.dearrow"), isOn: $titles)
                    Toggle(L10n.tr("settings.dislikes"), isOn: $votes)
                }
                Section(
                    header: Text(L10n.tr("settings.playOnTV")),
                    footer: Text(L10n.tr("settings.tv.footer"))
                ) {
                    if let name = tv.name {
                        HStack {
                            Text(L10n.tr("settings.pairedTV"))
                            Spacer()
                            Text(name).foregroundColor(.secondary)
                        }
                        Button(L10n.tr("settings.forgetTV")) { tv.forget() }.foregroundColor(.red)
                    } else {
                        TextField(L10n.tr("settings.tvCode"), text: $code).keyboardType(.numberPad)
                        Button(pairing ? L10n.tr("settings.pairing") : L10n.tr("settings.pairTV")) {
                            pairing = true
                            Task {
                                defer { pairing = false }
                                do { try await tv.pair(code); code = "" }
                                catch { playback.message = "TV pairing failed. Check the code on your TV and try again." }
                            }
                        }.disabled(pairing || code.filter(\.isNumber).count != 12)
                    }
                }
                Section(header: Text(L10n.tr("settings.library"))) {
                    Button(L10n.tr("settings.clearHistory")) { confirmClear = true }.foregroundColor(.red)
                }
                Section(header: Text(L10n.tr("settings.about"))) {
                    Link("NewTube for iOS", destination: URL(string: "https://github.com/toofpaste/newtube-ios")!)
                    Link("Original Android app", destination: URL(string: "https://github.com/aleixrodriala/newtube")!)
                    NavigationLink(L10n.tr("settings.credits")) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                ForEach(["Credits", "NewTube", "YouTubeKit"], id: \.self) { name in
                                    if let file = Bundle.main.url(forResource: name, withExtension: "txt"),
                                       let contents = try? String(contentsOf: file, encoding: .utf8) {
                                        Text(contents).font(.footnote)
                                    }
                                }
                            }.padding()
                        }.navigationTitle(L10n.tr("settings.credits"))
                    }
                }
            }
            .navigationTitle(L10n.tr("settings.title"))
            .onChange(of: speed) { _ in if playback.playing { playback.resume() } }
            .onChange(of: skip) { _ in playback.refreshCommunity() }
            .onChange(of: titles) { _ in playback.refreshCommunity() }
            .onChange(of: votes) { _ in playback.refreshCommunity() }
            .actionSheet(isPresented: $confirmClear) {
                ActionSheet(
                    title: Text(L10n.shared.effective == .simplifiedChinese
                        ? "清除此设备上的观看历史和播放进度？"
                        : "Clear watch history and resume positions on this device?"),
                    buttons: [
                        .destructive(Text(L10n.shared.effective == .simplifiedChinese ? "清除历史" : "Clear history")) {
                            library.clearHistory()
                        },
                        .cancel()
                    ]
                )
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
