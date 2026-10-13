import Foundation

/// Runs the AI pipeline for an episode: summary → takeaways → chapters → mindmap → insights.
@MainActor
final class SummaryPipeline: ObservableObject {
    @Published var stage: String = ""
    @Published var running = false

    func runAll(episode: EpisodeItem, client: AIClient) async {
        guard running == false else { return }
        running = true
        defer { running = false; stage = "" }
        let segs = episode.segments
        guard !segs.isEmpty else { stage = "沒有逐字稿，先轉寫"; return }
        let full = segs.map { $0.text }.joined()
        let compact = Prompts.compact(full)
        let stamped = Prompts.timestamped(segs)

        do {
            stage = "總覽…"
            let (s1, u1) = Prompts.miniSummary(transcript: compact)
            let mini = try await client.chat(system: s1, user: u1, jsonMode: true)
            if let d = mini.data(using: .utf8),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let sum = (j["summary"] as? String) ?? ""
                let guests = (j["guests"] as? String) ?? ""
                let topics = (j["topics"] as? [String] ?? []).map { "- \($0)" }.joined(separator: "\n")
                episode.summaryMarkdown = "## 總覽\n\n\(sum)\n\n來賓：\(guests)\n\n### 主題\n\(topics)"
            } else {
                episode.summaryMarkdown = mini
            }

            stage = "要點…"
            let (s2, u2) = Prompts.takeaways(transcript: compact)
            episode.takeawaysJSON = try await client.chat(system: s2, user: u2, jsonMode: true)

            stage = "章節…"
            let (s3, u3) = Prompts.chapters(transcript: stamped, totalSeconds: episode.duration)
            episode.chaptersJSON = try await client.chat(system: s3, user: u3, jsonMode: true)

            stage = "心智圖…"
            let (s4, u4) = Prompts.mindmap(transcript: compact)
            episode.mindmapJSON = try await client.chat(system: s4, user: u4, jsonMode: true)

            stage = "洞見…"
            let (s5, u5) = Prompts.insights(transcript: compact)
            episode.insightsJSON = try await client.chat(system: s5, user: u5, jsonMode: true)

            stage = "完成"
        } catch {
            stage = "失敗：\(error.localizedDescription)"
        }
    }
}
