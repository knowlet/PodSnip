import Foundation

/// Processes every supplied transcript chunk with one immutable provider selection.
@MainActor
final class SummaryPipeline: ObservableObject {
    @Published var stage: String = ""
    @Published var running = false

    func runAll(episode: EpisodeItem, service: ApplicationAIService) async {
        guard !running else { return }
        running = true
        defer { running = false }
        guard !episode.segments.isEmpty else { stage = "沒有逐字稿，先轉寫"; return }

        stage = "準備逐字稿…"
        do {
            let chunks = try TranscriptContext.chunks(segments: episode.segments,
                                                      inputByteBudget: service.transcriptByteBudget)
            guard !chunks.isEmpty else { throw AIServiceError.context("逐字稿沒有文字內容") }
            var overviews: [OverviewOutput] = []
            var takeaways: [TakeawayOutput] = []
            var chapters: [ChapterOutput] = []
            var branches: [MindBranchOutput] = []
            var insights: [InsightOutput] = []
            var questions: [String] = []

            for (index, chunk) in chunks.enumerated() {
                let position = "（\(index + 1)/\(chunks.count)）"
                stage = "總覽\(position)…"
                overviews.append(try await service.overview(transcript: chunk.text))

                stage = "要點\(position)…"
                let highlights = try await service.takeaways(transcript: chunk.text)
                try requireAI(highlights.takeaways.allSatisfy {
                    $0.at >= chunk.start && $0.at <= chunk.end
                }, "要點時間必須位於提供的片段 \(fmtTime(chunk.start))–\(fmtTime(chunk.end))")
                takeaways.append(contentsOf: highlights.takeaways)

                stage = "章節\(position)…"
                let sections = try await service.chapters(transcript: chunk.text,
                                                           totalSeconds: chunk.end)
                try requireAI(sections.chapters.allSatisfy {
                    $0.start >= chunk.start && $0.start <= chunk.end
                }, "章節時間必須位於提供的片段 \(fmtTime(chunk.start))–\(fmtTime(chunk.end))")
                chapters.append(contentsOf: sections.chapters)

                stage = "心智圖\(position)…"
                let map = try await service.mindmap(transcript: chunk.text)
                branches.append(contentsOf: map.branches.map {
                    MindBranchOutput(label: "[\(fmtTime(chunk.start))–\(fmtTime(chunk.end))] \($0.label)",
                                     children: $0.children)
                })

                stage = "洞見\(position)…"
                let observations = try await service.insights(transcript: chunk.text)
                insights.append(contentsOf: observations.insights)
                questions.append(contentsOf: observations.open_questions)
            }

            let summary = zip(chunks, overviews).map { chunk, overview in
                "### \(fmtTime(chunk.start))–\(fmtTime(chunk.end))\n\n\(overview.summary)"
            }.joined(separator: "\n\n")
            let guests = unique(overviews.map(\.guests).filter(nonblank)).joined(separator: "；")
            let topics = unique(overviews.flatMap(\.topics)).map { "- \($0)" }.joined(separator: "\n")
            let coverage = "來源：\(service.route.title)。已處理所提供逐字稿的全部 \(chunks.count) 個片段；範圍 \(fmtTime(chunks.first?.start ?? 0))–\(fmtTime(chunks.last?.end ?? 0))。逐字稿可能包含空隙；摘要不涵蓋未提供的音訊。"
            let markdown = "\(coverage)\n\n## 總覽\n\n\(summary)\n\n來賓：\(guests.isEmpty ? "未提及" : guests)\n\n### 主題\n\(topics)"
            let sortedTakeaways = takeaways.enumerated().sorted {
                $0.element.at == $1.element.at ? $0.offset < $1.offset : $0.element.at < $1.element.at
            }.map(\.element)
            let allTakeaways = try encoded(TakeawaysOutput(takeaways: sortedTakeaways))
            let allChapters = try encoded(ChaptersOutput(chapters: mergedChapters(chapters)))
            let allMindmap = try encoded(MindmapOutput(topic: episode.title, branches: branches))
            let allInsights = try encoded(InsightsOutput(insights: insights, open_questions: unique(questions)))

            // Publish only after every stage and encoding succeeds. A failed rerun
            // keeps the previous complete result rather than mixing providers/stages.
            episode.summaryMarkdown = markdown
            episode.takeawaysJSON = allTakeaways
            episode.chaptersJSON = allChapters
            episode.mindmapJSON = allMindmap
            episode.insightsJSON = allInsights
            stage = "完成（\(chunks.count) 個逐字稿片段，\(service.route.title)）"
        } catch {
            stage = "失敗（\(stage)）：\(error.localizedDescription)"
        }
    }

    private func encoded<T: AIOutput>(_ output: T) throws -> String {
        try output.validate()
        let data = try JSONEncoder().encode(output)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AIServiceError.malformed("無法儲存 UTF-8 輸出")
        }
        return text
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func mergedChapters(_ chapters: [ChapterOutput]) -> [ChapterOutput] {
        let sorted = chapters.enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        var result: [ChapterOutput] = []
        for chapter in sorted {
            if let last = result.last, last.start == chapter.start {
                result[result.count - 1] = ChapterOutput(
                    start: last.start,
                    title: unique([last.title, chapter.title]).joined(separator: " / "),
                    summary: unique([last.summary, chapter.summary]).joined(separator: "\n"))
            } else {
                result.append(chapter)
            }
        }
        return result
    }
}
