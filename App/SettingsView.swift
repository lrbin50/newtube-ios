import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var playback: Playback
    @EnvironmentObject var tv: Television
    @AppStorage("sponsorBlock") private var skip = true
    @AppStorage("deArrow") private var titles = false
    @AppStorage("showDislikes") private var votes = false
    @AppStorage("speed") private var speed = 1.0
    @State private var code = ""
    @State private var pairing = false
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    Picker("Default speed", selection: $speed) {
                        ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { value in
                            Text("\(value.formatted())×").tag(value)
                        }
                    }
                }
                Section {
                    Toggle("Skip sponsors and self-promotion", isOn: $skip)
                    Toggle("Show DeArrow titles", isOn: $titles)
                    Toggle("Show estimated dislikes", isOn: $votes)
                } header: { Text("Community services") } footer: {
                    Text("Enabled services receive the current video ID. SponsorBlock supplies segments, DeArrow supplies titles, and Return YouTube Dislike supplies counts.")
                }
                Section {
                    if let name = tv.name {
                        LabeledContent("Paired TV", value: name)
                        Button("Forget TV", role: .destructive) { tv.forget() }
                    } else {
                        TextField("12-digit TV code", text: $code).keyboardType(.numberPad)
                        Button(pairing ? "Pairing…" : "Pair TV") {
                            pairing = true
                            Task {
                                defer { pairing = false }
                                do { try await tv.pair(code); code = "" }
                                catch { playback.message = "TV pairing failed. Check the code on your TV and try again." }
                            }
                        }.disabled(pairing || code.filter(\.isNumber).count != 12)
                    }
                } header: { Text("Play on TV") } footer: {
                    Text("Find the pairing code in SmartTube or YouTube on your TV. After pairing, select your TV in the player menu.")
                }
                Section("Library") {
                    Button("Clear local watch history", role: .destructive) { confirmClear = true }
                }
                Section("About") {
                    Link("NewTube for iOS", destination: URL(string: "https://github.com/toofpaste/newtube-ios")!)
                    Link("Original Android app", destination: URL(string: "https://github.com/aleixrodriala/newtube")!)
                    NavigationLink("Credits and licenses") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                ForEach(["Credits", "NewTube", "YouTubeKit"], id: \.self) { name in
                                    if let file = Bundle.main.url(forResource: name, withExtension: "txt"),
                                       let contents = try? String(contentsOf: file, encoding: .utf8) {
                                        Text(contents).font(.footnote).textSelection(.enabled)
                                    }
                                }
                            }.padding()
                        }.navigationTitle("Credits and licenses")
                    }
                }
            }.navigationTitle("Settings")
            .onChange(of: speed) { if playback.playing { playback.resume() } }
            .onChange(of: skip) { playback.refreshCommunity() }
            .onChange(of: titles) { playback.refreshCommunity() }
            .onChange(of: votes) { playback.refreshCommunity() }
            .confirmationDialog("Clear watch history and resume positions on this device?", isPresented: $confirmClear) {
                Button("Clear history", role: .destructive) { library.clearHistory() }
            }
        }
    }
}
