import SwiftUI
import SwiftData

struct SummaryView: View {
    var episode: EpisodeItem

    var body: some View {
        if !episode.hasSummary && episode.takeawaysJSON == nil {
            ContentUnavailableView("尚無 AI 摘要", systemImage: "sparkles",
                                   description: Text("轉寫完成後按「AI 全套」"))
        } else {
            List {
                if let md = episode.summaryMarkdown {
                    Section("總覽") { Text(.init(md)).font(.subheadline) }
                }
                if let items = decodeTakeaways() {
                    Section("要點") {
                        ForEach(items.indices, id: \.self) { i in
                            VStack(alignment: .leading) {
                                Text(items[i].title).font(.subheadline).bold()
                                Text(items[i].detail).font(.caption).foregroundStyle(.secondary)
                                Text(fmtTime(items[i].at)).font(.caption2).foregroundStyle(.blue)
                            }
                        }
                    }
                }
                if let chs = decodeChapters() {
                    Section("章節") {
                        ForEach(chs) { c in
                            VStack(alignment: .leading) {
                                Text("\(fmtTime(c.start))  \(c.title)").font(.subheadline)
                                if let s = c.summary { Text(s).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                if let root = decodeMindmap() {
                    Section("心智圖") { MindNodeView(node: root, depth: 0) }
                }
                if let ins = decodeInsights() {
                    Section("洞見") {
                        ForEach(ins.indices, id: \.self) { i in
                            VStack(alignment: .leading) {
                                Text(ins[i].0).font(.subheadline).bold()
                                Text(ins[i].1).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    func decodeTakeaways() -> [TakeawayOutput]? {
        SummaryArchive.takeaways(from: episode.takeawaysJSON)
    }

    func decodeChapters() -> [Chapter]? {
        SummaryArchive.chapters(from: episode.chaptersJSON)
    }

    func decodeMindmap() -> MindNode? {
        SummaryArchive.mindmap(from: episode.mindmapJSON)
    }

    func decodeInsights() -> [(String, String)]? {
        SummaryArchive.insights(from: episode.insightsJSON)
    }
}

struct MindNodeView: View {
    var node: MindNode
    var depth: Int
    var body: some View {
        DisclosureGroup {
            ForEach(node.children ?? []) { c in MindNodeView(node: c, depth: depth + 1) }
        } label: {
            Text(node.label).font(depth == 0 ? .headline : .subheadline)
        }
    }
}

struct ChatView: View {
    var episode: EpisodeItem
    @State private var messages: [(me: Bool, text: String)] = []
    @State private var input = ""
    @State private var thinking = false

    var body: some View {
        VStack {
            List(messages.indices, id: \.self) { i in
                HStack {
                    if messages[i].me { Spacer() }
                    Text(messages[i].text)
                        .padding(10)
                        .background(messages[i].me ? Color.blue.opacity(0.85) : Color.gray.opacity(0.2))
                        .foregroundStyle(messages[i].me ? .white : .primary)
                        .cornerRadius(12)
                    if !messages[i].me { Spacer() }
                }
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            HStack {
                TextField("問這集…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .disabled(thinking)
                Button("送出") {
                    Task { await ask() }
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || thinking || !episode.hasTranscript)
            }
            .padding()
        }
        .onAppear {
            if messages.isEmpty {
                messages.append((false, "回答只根據每次選取的逐字稿片段，會顯示引用與涵蓋範圍；逐字稿以外的內容無法確認。"))
            }
        }
    }

    func ask() async {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !thinking else { return }
        let service = ApplicationAIService(config: .load())
        input = ""
        thinking = true
        defer { thinking = false }
        messages.append((true, question))
        do {
            let answer = try await service.answer(question: question, segments: episode.segments)
            messages.append((false, answer))
        } catch {
            messages.append((false, "\(service.route.title) 出錯：\(error.localizedDescription)"))
        }
    }
}

/// Notes written by earlier versions were stored as the whole JSON object.
/// Decode that known shape for display/export without changing persisted content.
func displayedSnipNote(_ value: String) -> String {
    guard let data = value.data(using: .utf8),
          let output = try? JSONDecoder().decode(NoteOutput.self, from: data),
          nonblank(output.note) else { return value }
    return output.note
}

struct SnipListView: View {
    @Query(sort: \Snip.createdAt, order: .reverse) var snips: [Snip]
    @Environment(\.modelContext) var context

    var body: some View {
        NavigationStack {
            List(snips) { snip in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(fmtTime(snip.atTime)).font(.caption).monospacedDigit().foregroundStyle(.blue)
                        Text(snip.episodeTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(snip.text).font(.subheadline).lineLimit(4)
                    if let note = snip.aiNote { Text(displayedSnipNote(note)).font(.caption).foregroundStyle(.purple) }
                    if let error = snip.aiError {
                        Text(UserFacingAIError.shareLine(stored: error)).font(.caption).foregroundStyle(.orange)
                        HStack {
                            Button("重試") { Task { await Snack.shared.retryNote(snip) } }
                            Button("清除") { Snack.shared.clearFailure(snip) }
                        }
                        .font(.caption)
                    }
                    ShareLink(item: markdown(for: snip), preview: SharePreview("分享擷取")) {
                        Label("分享", systemImage: "square.and.arrow.up").font(.caption)
                    }
                }
                .swipeActions { Button("刪除", role: .destructive) { context.delete(snip) } }
            }
            .navigationTitle("我的擷取")
            .overlay {
                if snips.isEmpty {
                    ContentUnavailableView("還沒有擷取", systemImage: "bookmark",
                                           description: Text("播放時按 Snip，或按耳機收藏鍵"))
                }
            }
        }
    }

    func markdown(for s: Snip) -> String {
        snipShareMarkdown(episodeTitle: s.episodeTitle, atTime: s.atTime, text: s.text, aiNote: s.aiNote, aiError: s.aiError)
    }
}

func snipShareMarkdown(episodeTitle: String, atTime: Double, text: String, aiNote: String?, aiError: String?) -> String {
    let note = aiNote.map(displayedSnipNote) ?? ""
    let failure = UserFacingAIError.shareLine(stored: aiError)
    return "# Snip — \(episodeTitle)\n\n⏱ \(fmtTime(atTime))\n\n> \(text)\n\n\(note)\n\(failure)\n"
}
