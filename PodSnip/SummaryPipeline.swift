import Foundation
import SwiftData

enum SummarySaveState: Equatable {
    case idle
    case pending
    case failed(String)
}

struct SummaryFieldSnapshot {
    var summaryMarkdown: String?
    var takeawaysJSON: String?
    var chaptersJSON: String?
    var mindmapJSON: String?
    var insightsJSON: String?

    init(_ episode: EpisodeItem) {
        summaryMarkdown = episode.summaryMarkdown
        takeawaysJSON = episode.takeawaysJSON
        chaptersJSON = episode.chaptersJSON
        mindmapJSON = episode.mindmapJSON
        insightsJSON = episode.insightsJSON
    }

    func restore(_ episode: EpisodeItem) {
        episode.summaryMarkdown = summaryMarkdown
        episode.takeawaysJSON = takeawaysJSON
        episode.chaptersJSON = chaptersJSON
        episode.mindmapJSON = mindmapJSON
        episode.insightsJSON = insightsJSON
    }
}

/// Processes every supplied transcript chunk with one immutable provider selection.
@MainActor
final class SummaryPipeline: ObservableObject {
    @Published var stage: String = ""
    @Published var running = false
    @Published private(set) var saveState: SummarySaveState = .idle
    private var summaryBaseline: SummaryFieldSnapshot?
    private var summaryEpisodeID: UUID?

    func runAll(episode: EpisodeItem, service: ApplicationAIService) async {
        guard !running else { return }
        running = true
        defer { running = false }
        rememberSummaryBaseline(episode)
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

    /// Writes the in-memory summary. A thrown save moves to `.failed` and keeps
    /// the unsaved changes so they can be retried; it does not stay `.pending`.
    /// Records the summary fields before a new publish. A failed save keeps this
    /// baseline so clear can restore it without rolling back the whole context.
    func rememberSummaryBaseline(_ episode: EpisodeItem) {
        guard saveState != .failed else { return }
        summaryEpisodeID = episode.id
        summaryBaseline = SummaryFieldSnapshot(episode)
    }

    func persist(_ context: ModelContext, save: (ModelContext) throws -> Void = { try $0.save() }) {
        saveState = .pending
        do {
            try save(context)
            saveState = .idle
            summaryBaseline = nil
        } catch {
            saveState = .failed("儲存失敗。")
        }
    }

    func retryPersist(_ context: ModelContext, save: (ModelContext) throws -> Void = { try $0.save() }) {
        guard case .failed = saveState else { return }
        persist(context, save: save)
    }

    /// Restores the summary fields captured before the failed publish.
    /// Other unsaved edits in the context stay in place.
    func clearUnsaved(_ episode: EpisodeItem) {
        guard case .failed = saveState,
              episode.id == summaryEpisodeID,
              let summaryBaseline else { return }
        summaryBaseline.restore(episode)
        self.summaryBaseline = nil
        saveState = .idle
    }

    private func encoded<T: AIOutput>(_ output: T) throws -> String {
        try output.validate()
        return try SummaryArchive.persist(output)
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
