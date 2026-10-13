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
                                if let d = items[i].detail { Text(d).font(.caption).foregroundStyle(.secondary) }
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

    struct Takeaway: Decodable { var title: String; var detail: String? }
    func decodeTakeaways() -> [Takeaway]? {
        guard let s = episode.takeawaysJSON, let d = s.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = j["takeaways"] as? [[String: Any]] else { return nil }
        return arr.compactMap { o in
            guard let t = o["title"] as? String else { return nil }
            return Takeaway(title: t, detail: o["detail"] as? String)
        }
    }
    func decodeChapters() -> [Chapter]? {
        guard let s = episode.chaptersJSON, let d = s.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = j["chapters"] as? [[String: Any]] else { return nil }
        return arr.compactMap { o in
            guard let t = o["title"] as? String else { return nil }
            let start = (o["start"] as? Double) ?? Double(o["start"] as? Int ?? 0)
            return Chapter(start: start, title: t, summary: o["summary"] as? String)
        }
    }
    func decodeMindmap() -> MindNode? {
        guard let s = episode.mindmapJSON, let d = s.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        func node(_ o: [String: Any]) -> MindNode {
            let kids = (o["children"] as? [[String: Any]])?.map(node)
            return MindNode(label: (o["label"] as? String) ?? "", children: kids)
        }
        let topic = (j["topic"] as? String) ?? "主題"
        let branches = (j["branches"] as? [[String: Any]])?.map(node) ?? []
        return MindNode(label: topic, children: branches)
    }
    func decodeInsights() -> [(String, String)]? {
        guard let s = episode.insightsJSON, let d = s.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = j["insights"] as? [[String: Any]] else { return nil }
        return arr.compactMap { o in
            guard let t = o["title"] as? String else { return nil }
            return (t, (o["body"] as? String) ?? "")
        }
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
                .disabled(input.isEmpty || thinking || !episode.hasTranscript)
            }
            .padding()
        }
        .onAppear {
            if messages.isEmpty {
                messages.append((false, "我是這集的 AI 助手，問我任何內容（會附時間引用）。"))
            }
        }
    }

    func ask() async {
        let q = input; input = ""; thinking = true
        messages.append((true, q))
        do {
            let ctx = Prompts.timestamped(episode.segments)
            let (s, u) = Prompts.ask(question: q, context: ctx)
            let ans = try await AIClient(config: .load()).chat(system: s, user: u)
            messages.append((false, ans))
        } catch {
            messages.append((false, "出錯：\(error.localizedDescription)"))
        }
        thinking = false
    }
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
                    if let n = snip.aiNote { Text(n).font(.caption).foregroundStyle(.purple) }
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
        "# Snip — \(s.episodeTitle)\n\n⏱ \(fmtTime(s.atTime))\n\n> \(s.text)\n\n\(s.aiNote ?? "")\n"
    }
}
