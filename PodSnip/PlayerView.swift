import SwiftUI
import SwiftData

func fmtTime(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let m = Int(s) / 60, sec = Int(s) % 60
    let h = m / 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m % 60, sec) : String(format: "%d:%02d", m, sec)
}

struct PlayerView: View {
    var episode: EpisodeItem
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var library: PodcastLibrary
    @EnvironmentObject var pipeline: SummaryPipeline
    @Environment(\.modelContext) var context
    @State private var tab = 0
    @State private var busy = ""
    @State private var progress: Double = 0
    @State private var snipFlash: String?

    var body: some View {
        VStack(spacing: 0) {
            // Transport
            VStack(spacing: 8) {
                Text(episode.title).font(.headline).lineLimit(2).padding(.horizontal)
                Slider(value: Binding(get: { player.currentTime },
                                       set: { player.seek(to: $0) }),
                       in: 0...(max(player.duration, episode.duration, 1)))
                    .padding(.horizontal)
                HStack {
                    Text(fmtTime(player.currentTime)).font(.caption).monospacedDigit()
                    Spacer()
                    Text(fmtTime(player.duration > 0 ? player.duration : episode.duration)).font(.caption).monospacedDigit()
                }
                .padding(.horizontal)
                HStack(spacing: 28) {
                    Button { player.skip(by: -15) } label: { Image(systemName: "gobackward.15").font(.title2) }
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 56))
                    }
                    Button { player.skip(by: 30) } label: { Image(systemName: "goforward.30").font(.title2) }
                }
                // One-tap Snip (in-app + headphones 🔖 + control center)
                Button {
                    Task { await doSnip() }
                } label: {
                    Label("Snip 這一段", systemImage: "bookmark.fill")
                        .font(.headline).padding(.horizontal, 24).padding(.vertical, 10)
                        .background(.yellow.opacity(0.9)).foregroundStyle(.black).cornerRadius(20)
                }
                .padding(.top, 4)
                if let f = snipFlash { Text(f).font(.caption).foregroundStyle(.green) }
            }
            .padding(.vertical, 8)

            // Pipeline actions
            HStack(spacing: 12) {
                Button(busy.isEmpty ? "轉寫" : busy) {
                    Task { await doTranscribe() }
                }
                .disabled(!busy.isEmpty || episode.hasTranscript)
                Button(pipeline.running ? pipeline.stage : "AI 全套") {
                    Task { await pipeline.runAll(episode: episode, client: AIClient(config: .load())); try? context.save() }
                }
                .disabled(pipeline.running || !episode.hasTranscript)
            }
            .buttonStyle(.bordered)
            .font(.caption)
            if progress > 0 && progress < 1 { ProgressView(value: progress).padding(.horizontal) }

            Picker("", selection: $tab) {
                Text("逐字稿").tag(0); Text("摘要").tag(1); Text("問答").tag(2)
            }
            .pickerStyle(.segmented).padding(.horizontal)

            TabView(selection: $tab) {
                TranscriptListView(episode: episode).tag(0)
                SummaryView(episode: episode).tag(1)
                ChatView(episode: episode).tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            player.onSnip = { [t = episode.title, id = episode.id] _ in
                Task { @MainActor in await Snack.shared.snip(episodeID: id, title: t) }
            }
            if player.episode?.id != episode.id {
                player.play(episode, localURL: library.localAudioURL(for: episode))
            }
        }
    }

    private func doTranscribe() async {
        busy = "下載音檔…"
        do {
            try await library.download(episode)
            try context.save()
            guard let url = library.localAudioURL(for: episode) else { busy = ""; return }
            busy = "轉寫中…"
            let segs = try await SpeechTranscriber.shared.transcribe(audioFileURL: url) { p in
                Task { @MainActor in progress = p }
            }
            episode.segments = segs
            try context.save()
            progress = 0
        } catch {
            busy = "失敗：\(error.localizedDescription)"
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if episode.hasTranscript { busy = "" }
    }

    private func doSnip() async {
        await Snack.shared.snip(episodeID: episode.id, title: episode.title)
        snipFlash = "已擷取 ✓"
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        snipFlash = nil
    }
}

/// Headphone/remote snip helper (needs modelContext via main actor hop).
@MainActor
final class Snack {
    static let shared = Snack()
    var context: ModelContext?
    func snip(episodeID: UUID, title: String) async {
        // Resolve via player time; context wired from ContentView onAppear.
        let t = AudioPlayer.shared.currentTime
        guard let ctx = context else { return }
        // Find surrounding transcript text
        var text = "（無逐字稿）"
        if let ep = try? ctx.fetch(FetchDescriptor<EpisodeItem>(
            predicate: #Predicate { $0.id == episodeID })).first {
            let near = ep.segments.filter { abs($0.start - t) < 45 }
            if !near.isEmpty { text = near.map { $0.text }.joined(separator: " ") }
            var note: String?
            if AIConfig.load().isConfigured {
                let (s, u) = Prompts.snipNote(segment: String(text.prefix(600)))
                note = try? await AIClient(config: .load()).chat(system: s, user: u, jsonMode: true, maxTokens: 256)
            }
            ctx.insert(Snip(episodeID: episodeID, episodeTitle: title, atTime: t, text: text, aiNote: note))
            try? ctx.save()
        }
    }
}

struct TranscriptListView: View {
    var episode: EpisodeItem
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        let segs = episode.segments
        if segs.isEmpty {
            ContentUnavailableView("尚無逐字稿", systemImage: "text.quote",
                                   description: Text("先按「轉寫」"))
        } else {
            ScrollViewReader { proxy in
                List(segs) { s in
                    Button {
                        player.seek(to: max(0, s.start - 1))
                    } label: {
                        HStack(alignment: .top) {
                            Text(fmtTime(s.start)).font(.caption).monospacedDigit()
                                .foregroundStyle(.blue).frame(width: 44, alignment: .leading)
                            Text(s.text).font(.subheadline)
                        }
                    }
                    .id(s.id)
                    .listRowBackground(player.currentTime >= s.start && player.currentTime < s.end
                                       ? Color.yellow.opacity(0.25) : Color.clear)
                }
                .listStyle(.plain)
                .onChange(of: Int(player.currentTime)) {
                    if let cur = segs.last(where: { $0.start <= player.currentTime }) {
                        withAnimation { proxy.scrollTo(cur.id, anchor: .center) }
                    }
                }
            }
        }
    }
}
