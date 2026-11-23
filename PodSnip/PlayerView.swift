import SwiftUI
import SwiftData

func fmtTime(_ s: Double) -> String {
    guard s.isFinite, s >= 0, s <= Double(Int.max / 2) else { return "0:00" }
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
    @State private var snipFailed = false

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
                if let f = snipFlash {
                    Text(f).font(.caption).foregroundStyle(snipFailed ? Color.orange : Color.green)
                }
            }
            .padding(.vertical, 8)

            // Pipeline actions
            HStack(spacing: 12) {
                Button(busy.isEmpty ? "轉寫" : busy) {
                    Task { await doTranscribe() }
                }
                .disabled(!busy.isEmpty || episode.hasTranscript)
                Button(pipeline.running ? pipeline.stage : "AI 全套") {
                    Task {
                        let service = ApplicationAIService(config: .load())
                        await pipeline.runAll(episode: episode, service: service)
                        pipeline.persist(context)
                    }
                }
                .disabled(pipeline.running || !episode.hasTranscript)
            }
            .buttonStyle(.bordered)
            .font(.caption)
            if case .failed(let message) = pipeline.saveState {
                VStack(spacing: 4) {
                    Text(message).font(.caption).foregroundStyle(.red)
                    HStack {
                        Button("重試儲存") { pipeline.retryPersist(context) }
                        Button("清除未儲存變更") { pipeline.clearUnsaved(episode) }
                    }
                    .font(.caption)
                }
            }
            if !pipeline.stage.isEmpty {
                Text(pipeline.stage).font(.caption)
                    .foregroundStyle(pipeline.stage.hasPrefix("失敗") ? Color.red : Color.secondary)
                    .padding(.horizontal)
                    .accessibilityIdentifier("aiPipelineStatus")
            }
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
                Task { @MainActor in _ = await Snack.shared.snip(episodeID: id, title: t) }
            }
            if player.episode?.id != episode.id {
                player.play(episode, localURL: library.localAudioURL(for: episode))
            }
        }
    }

    private func doTranscribe() async {
        busy = "下載音檔…"
        defer { busy = ""; progress = 0 }
        do {
            try await library.download(episode)
            try context.save()
            guard let url = library.localAudioURL(for: episode) else { return }
            busy = "轉寫中…"
            let segs = try await SpeechTranscriber.shared.transcribe(audioFileURL: url) { p in
                Task { @MainActor in progress = p }
            }
            episode.segments = segs
            try context.save()
        } catch {
            busy = "失敗：\(error.localizedDescription)"
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func doSnip() async {
        let snip = await Snack.shared.snip(episodeID: episode.id, title: episode.title)
        snipFailed = snip == nil || snip?.aiError != nil
        if let snip {
            let failure = UserFacingAIError.shareLine(stored: snip.aiError)
            snipFlash = failure.isEmpty ? "已擷取 ✓" : "已擷取；\(failure)"
        } else {
            snipFlash = "擷取儲存失敗，請重試"
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        snipFlash = nil
    }
}

/// Headphone/remote snip helper (needs modelContext via main actor hop).
@MainActor
final class Snack {
    static let shared = Snack()
    var context: ModelContext?

    init(context: ModelContext? = nil) { self.context = context }

    /// Test hook. Production uses `ModelContext.save()`.
    var saveChanges: (ModelContext) throws -> Void = { try $0.save() }

    @discardableResult
    func snip(episodeID: UUID, title: String, service: ApplicationAIService? = nil,
              captureTime: Double? = nil) async -> Snip? {
        // The injected time avoids touching playback in local fixture tests.
        let time = captureTime ?? AudioPlayer.shared.currentTime
        let selectedService = service ?? ApplicationAIService(config: .load())
        guard let ctx = context,
              let episode = try? ctx.fetch(FetchDescriptor<EpisodeItem>(
                predicate: #Predicate { $0.id == episodeID })).first else { return nil }
        let nearby = episode.segments.filter { abs($0.start - time) < 45 }
        let hasText = !nearby.isEmpty
        let text = hasText ? nearby.map(\.text).joined(separator: " ") : "（無逐字稿）"
        let snip = Snip(episodeID: episodeID, episodeTitle: title, atTime: time, text: text)
        ctx.insert(snip)
        // Raw capture is durable before any provider is contacted.
        do { try saveChanges(ctx) }
        catch {
            discardUnsavedInsert(snip, in: ctx)
            return nil
        }

        let note: Result<String, Error>
        do {
            guard hasText else { throw AIServiceError.context("擷取已儲存，但附近沒有逐字稿可產生筆記") }
            note = .success(try await selectedService.note(segment: text).note)
        } catch {
            note = .failure(error)
        }
        return commit(note, to: snip, in: ctx)
    }

    func retryNote(_ snip: Snip, service: ApplicationAIService? = nil) async {
        guard let ctx = context else { return }
        if snip.aiError == UserFacingAIError.saveFailure(), let note = snip.aiNote, !note.isEmpty {
            snip.aiError = nil
            do { try saveChanges(ctx) }
            catch { snip.aiError = UserFacingAIError.saveFailure() }
            return
        }
        let selected = service ?? ApplicationAIService(config: .load())
        let trimmed = snip.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let note: Result<String, Error>
        if trimmed.isEmpty || trimmed == "（無逐字稿）" {
            note = .failure(AIServiceError.context("擷取已儲存，但附近沒有逐字稿可產生筆記"))
        } else {
            do { note = .success(try await selected.note(segment: snip.text).note) }
            catch { note = .failure(error) }
        }
        _ = commit(note, to: snip, in: ctx)
    }

    /// Clears a persisted note failure. A failed clear puts that failure back on
    /// the snip and leaves other unsaved edits alone.
    @discardableResult
    func clearFailure(_ snip: Snip) -> Bool {
        guard let ctx = context, let previous = snip.aiError else { return false }
        snip.aiError = nil
        do {
            try saveChanges(ctx)
            return true
        } catch {
            snip.aiError = previous
            return false
        }
    }

    private func commit(_ note: Result<String, Error>, to snip: Snip, in context: ModelContext) -> Snip? {
        let generatedNote: String?
        switch note {
        case .success(let text):
            snip.aiNote = text
            snip.aiError = nil
            generatedNote = text
        case .failure(let error):
            snip.aiNote = nil
            snip.aiError = UserFacingAIError.message(for: error)
            generatedNote = nil
        }
        do {
            try saveChanges(context)
            return snip
        } catch {
            // Keep a note the provider already returned. Record the save failure
            // without rolling back unrelated edits in this context.
            if let generatedNote { snip.aiNote = generatedNote }
            snip.aiError = UserFacingAIError.saveFailure()
            do {
                try saveChanges(context)
                return snip
            } catch {
                return snip
            }
        }
    }

    private func discardUnsavedInsert(_ snip: Snip, in context: ModelContext) {
        context.delete(snip)
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
