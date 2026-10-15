import XCTest
import SwiftData
import FoundationModels
@testable import PodSnip

/// Contract tests use authored fixtures and injected providers only. They do not
/// exercise Apple inference, PCC eligibility, a network endpoint, or stored keys.
@MainActor
final class AIServiceTests: XCTestCase {
    func testAllEightOperationsUseOnlyTheSelectedProviderForEveryRoute() async throws {
        for route in AIRoute.allCases {
            let providers = Dictionary(uniqueKeysWithValues: AIRoute.allCases.map {
                ($0, SyntheticAIProvider(route: $0))
            })
            var selectedRoutes: [AIRoute] = []
            let service = ApplicationAIService(config: configuration(route)) { snapshot in
                selectedRoutes.append(snapshot.route)
                return providers[snapshot.route]!
            }

            for operation in AIOperation.allCases {
                try await perform(operation, service: service)
            }

            XCTAssertEqual(selectedRoutes, [route], "Select one provider from an immutable configuration")
            XCTAssertEqual(providers[route]?.requests.map(\.operation), AIOperation.allCases)
            XCTAssertEqual(providers[route]?.kinds, [.overview, .takeaways, .chapters, .mindmap, .insights, .note])
            for otherRoute in AIRoute.allCases where otherRoute != route {
                XCTAssertTrue(providers[otherRoute]!.requests.isEmpty, "No fallback may send content to another route")
            }
        }
    }

    func testAppleOperationsAndConnectionTestDoNotRequireBYOKCredentials() async throws {
        for route in [AIRoute.onDevice, .appleCloud] {
            let provider = SyntheticAIProvider(route: route)
            let service = ApplicationAIService(config: configuration(route, emptyCredentials: true), provider: provider)
            for operation in AIOperation.allCases {
                try await perform(operation, service: service)
            }
            XCTAssertEqual(provider.requests.count, 8)
        }
    }

    func testConfigurationIsSnapshottedAtServiceCreation() async throws {
        var config = configuration(.onDevice, emptyCredentials: true)
        let provider = SyntheticAIProvider(route: .onDevice)
        var snapshots: [AIConfig] = []
        let service = ApplicationAIService(config: config) { snapshot in
            snapshots.append(snapshot)
            return provider
        }
        config.routeRaw = AIRoute.byok.rawValue
        config.baseURL = "https://changed.invalid/v1"
        config.model = "changed-model"
        config.apiKey = "synthetic-changed-key"

        _ = try await service.testConnection()
        _ = try await service.note(segment: "Authored note fixture")

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.route, .onDevice)
        XCTAssertEqual(snapshots.first?.apiKey, "")
        XCTAssertEqual(provider.requests.map(\.operation), [.connectionTest, .note])
    }

    func testInjectedProviderForAnotherRouteIsRejectedBeforeReceivingContent() async {
        let wrongProvider = SyntheticAIProvider(route: .byok)
        let service = ApplicationAIService(config: configuration(.onDevice, emptyCredentials: true), provider: wrongProvider)
        await assertAIError("unavailable") { _ = try await service.note(segment: "Must stay local") }
        XCTAssertTrue(wrongProvider.requests.isEmpty)
    }

    func testUnknownSavedRouteDoesNotFallBackToBYOK() async {
        var config = configuration(.byok)
        config.routeRaw = "future-or-corrupt-route"
        let provider = SyntheticAIProvider(route: .byok)
        let service = ApplicationAIService(config: config, provider: provider)
        for operation in AIOperation.allCases {
            await assertAIError("unavailable") { try await self.perform(operation, service: service) }
        }
        XCTAssertFalse(service.availability.isAvailable)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testUnavailableRouteRejectsEveryOperationWithoutCallingProvider() async {
        for route in AIRoute.allCases {
            let provider = SyntheticAIProvider(route: route)
            provider.availability = AIAvailability(isAvailable: false, reason: "synthetic device or entitlement unavailable")
            let service = ApplicationAIService(config: configuration(route), provider: provider)
            for operation in AIOperation.allCases {
                await assertAIError("unavailable") { try await self.perform(operation, service: service) }
            }
            XCTAssertTrue(provider.requests.isEmpty)
        }
    }

    func testGenerationFailuresRemainVisibleWithoutFallbackOrRetry() async {
        let failures: [(String, AIServiceError)] = [
            ("quota", .quota("synthetic quota limit")),
            ("network", .network("synthetic network failure")),
            ("service", .service("synthetic service unavailable")),
            ("context", .context("synthetic context window exceeded")),
            ("unavailable", .unavailable("synthetic model not ready"))
        ]
        for (kind, failure) in failures {
            let provider = SyntheticAIProvider(route: .appleCloud)
            provider.failure = failure
            let service = ApplicationAIService(config: configuration(.appleCloud, emptyCredentials: true), provider: provider)
            for operation in AIOperation.allCases {
                await assertAIError(kind) { try await self.perform(operation, service: service) }
            }
            XCTAssertEqual(provider.requests.map(\.operation), AIOperation.allCases)
        }
    }

    func testMalformedAndSemanticallyInvalidStructuredOutputsAreRejected() async {
        let invalid: [(AIOutputKind, String)] = [
            (.overview, "not JSON"),
            (.overview, #"{"summary":"","guests":"","topics":["topic"]}"#),
            (.takeaways, #"{"takeaways":[{"title":"point","detail":"detail","at":-1}]}"#),
            (.chapters, #"{"chapters":[{"start":4,"title":"later","summary":"a"},{"start":2,"title":"earlier","summary":"b"}]}"#),
            (.mindmap, #"{"topic":"fixture","branches":[{"label":"empty","children":[]}]}"#),
            (.insights, #"{"insights":[{"title":"","body":"body"}],"open_questions":[]}"#),
            (.note, #"{"note":"  "}"#)
        ]
        for (kind, json) in invalid {
            let provider = SyntheticAIProvider(route: .onDevice)
            provider.overrideStructuredData = Data(json.utf8)
            let service = ApplicationAIService(config: configuration(.onDevice, emptyCredentials: true), provider: provider)
            await assertAIError("malformed") { try await self.perform(operation(for: kind), service: service) }
            XCTAssertEqual(provider.requests.count, 1)
        }
    }

    func testOversizedSingleRequestFailsBeforeProviderSeesContent() async {
        for route in AIRoute.allCases {
            let provider = SyntheticAIProvider(route: route)
            let service = ApplicationAIService(config: configuration(route), provider: provider)
            let huge = String(repeating: "超出上下文的合成文字", count: 10_000)
            await assertAIError("context") { _ = try await service.overview(transcript: huge) }
            await assertAIError("context") {
                _ = try await service.answer(question: huge, segments: self.fixtureSegments)
            }
            XCTAssertTrue(provider.requests.isEmpty)
        }
    }

    func testLongSnipNoteProcessesEveryChunkWithoutDroppingContent() async throws {
        let provider = SyntheticAIProvider(route: .onDevice)
        let service = ApplicationAIService(config: configuration(.onDevice, emptyCredentials: true), provider: provider)
        let segment = String(repeating: "Authored long snip content. ", count: 600) + "END_OF_SNIP"
        let chunks = try TranscriptContext.chunks(segments: [TranscriptSegment(start: 0, end: 0, text: segment)],
                                                  inputByteBudget: service.transcriptByteBudget)

        let result = try await service.note(segment: segment)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(provider.requests.count, chunks.count)
        for (request, chunk) in zip(provider.requests, chunks) {
            XCTAssertEqual(request.operation, .note)
            XCTAssertTrue(request.user.hasSuffix(chunk.text))
            XCTAssertLessThanOrEqual(request.system.utf8.count + request.user.utf8.count, service.capabilities.inputByteBudget)
        }
        XCTAssertTrue(provider.requests.last?.user.contains("END_OF_SNIP") == true)
        XCTAssertEqual(result.note.components(separatedBy: "Synthetic parsed note").count - 1, chunks.count)
    }

    func testChunkingRetainsEveryUnicodeGraphemeAndOriginalTimeBounds() throws {
        let first = String(repeating: "甲👩🏽‍🚀漢字", count: 4_000)
        let second = "AFTER_12000_CHARACTERS_END"
        let segments = [TranscriptSegment(start: 61.5, end: 92, text: first),
                        TranscriptSegment(start: 120, end: 124.5, text: second)]
        let chunks = try TranscriptContext.chunks(segments: segments, inputByteBudget: 280)

        XCTAssertGreaterThan(first.count, 12_000)
        XCTAssertGreaterThan(chunks.count, 1)
        var reconstructed = ""
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.text.utf8.count, 280)
            XCTAssertFalse(chunk.text.contains("省略"))
            for line in chunk.text.split(separator: "\n", omittingEmptySubsequences: true) {
                let boundary = try XCTUnwrap(line.range(of: ") "))
                reconstructed += line[boundary.upperBound...]
                XCTAssertTrue(line.hasPrefix("[01:01] (61.5s–92.0s) ") || line.hasPrefix("[02:00] (120.0s–124.5s) "))
            }
            XCTAssertTrue(chunk.start == 61.5 || chunk.start == 120)
            XCTAssertTrue(chunk.end == 92 || chunk.end == 124.5)
        }
        XCTAssertEqual(reconstructed, first + second)
    }

    func testInvalidTranscriptTimesAndInsufficientBudgetsAreVisible() async {
        let invalid = [TranscriptSegment(start: -.infinity, end: 1, text: "Authored invalid fixture"),
                       TranscriptSegment(start: 4, end: 2, text: "Authored reversed fixture"),
                       TranscriptSegment(start: 0, end: .nan, text: "Authored nonfinite fixture")]
        for segment in invalid {
            await assertAIError("context") {
                _ = try TranscriptContext.chunks(segments: [segment], inputByteBudget: 280)
            }
        }
        await assertAIError("context") {
            _ = try TranscriptContext.chunks(segments: self.fixtureSegments, inputByteBudget: 127)
        }
        await assertAIError("context") {
            _ = try TranscriptContext.chunks(segments: [TranscriptSegment(start: 10, end: 12, text: "Later fixture"),
                                                      TranscriptSegment(start: 4, end: 7, text: "Earlier fixture")],
                                             inputByteBudget: 280)
        }
        await assertAIError("context") {
            _ = try TranscriptContext.chunks(segments: [TranscriptSegment(start: Double.greatestFiniteMagnitude,
                                                                          end: Double.greatestFiniteMagnitude,
                                                                          text: "Huge timestamp fixture")], inputByteBudget: 280)
        }
    }

    func testQuestionSelectionDisclosesExcerptCoverageAndKeepsTimestamp() async throws {
        let provider = SyntheticAIProvider(route: .onDevice)
        let service = ApplicationAIService(config: configuration(.onDevice, emptyCredentials: true), provider: provider)
        var segments: [TranscriptSegment] = []
        for index in 0..<80 {
            let start = Double(index * 10)
            let text: String
            if index == 60 { text = "SYNTHETIC_QUASAR explains the target evidence." }
            else { text = String(repeating: "Authored unrelated transcript. ", count: 5) }
            segments.append(TranscriptSegment(start: start, end: start + 9, text: text))
        }

        let answer = try await service.answer(question: "Explain SYNTHETIC_QUASAR", segments: segments)

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertTrue(provider.requests[0].user.contains("SYNTHETIC_QUASAR explains"))
        XCTAssertTrue(provider.requests[0].user.contains("[10:00]"))
        XCTAssertTrue(answer.contains("其他內容未納入"), answer)
        XCTAssertTrue(answer.contains("可能缺少相關證據"), answer)
        XCTAssertTrue(answer.contains("Synthetic answer [00:00]"))
        XCTAssertLessThanOrEqual(provider.requests[0].system.utf8.count + provider.requests[0].user.utf8.count,
                                 service.capabilities.inputByteBudget)
    }

    func testWholeTranscriptPipelineSendsEveryChunkToAllFiveStages() async throws {
        let provider = SyntheticAIProvider(route: .onDevice)
        let service = ApplicationAIService(config: configuration(.onDevice, emptyCredentials: true), provider: provider)
        let episode = fixtureEpisode()
        episode.duration = 2_000
        var segments: [TranscriptSegment] = []
        let padding = String(repeating: "x", count: 70)
        for index in 0..<200 {
            let start = Double(index * 10)
            let text = "UNIQUE_SYNTHETIC_\(index)_" + padding
            segments.append(TranscriptSegment(start: start, end: start + 9, text: text))
        }
        episode.segments = segments
        let chunks = try TranscriptContext.chunks(segments: episode.segments, inputByteBudget: service.transcriptByteBudget)
        let pipeline = SummaryPipeline()

        await pipeline.runAll(episode: episode, service: service)

        XCTAssertTrue(pipeline.stage.contains("完成"), pipeline.stage)
        XCTAssertGreaterThan(episode.segments.map(\.text).joined().count, 12_000)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(provider.requests.count, chunks.count * 5)
        for operation in [AIOperation.overview, .takeaways, .chapters, .mindmap, .insights] {
            let requests = provider.requests.filter { $0.operation == operation }
            XCTAssertEqual(requests.count, chunks.count)
            for (request, chunk) in zip(requests, chunks) {
                XCTAssertTrue(request.user.hasSuffix(chunk.text), "\(operation) must process the exact bounded chunk")
                XCTAssertLessThanOrEqual(request.system.utf8.count + request.user.utf8.count, service.capabilities.inputByteBudget)
            }
            XCTAssertTrue(requests.last?.user.contains("UNIQUE_SYNTHETIC_199_") == true)
        }
        XCTAssertTrue(episode.summaryMarkdown?.contains("全部 \(chunks.count) 個片段") == true)
        XCTAssertTrue(episode.summaryMarkdown?.contains("摘要不涵蓋未提供的音訊") == true)
    }

    func testAppleGuidedGenerationSchemasFitReservedBudget() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("Foundation Models schemas require iOS 26") }
        for kind in AIOutputKind.allCases {
            let schema = try AppleAIProvider.schema(for: kind)
            let bytes = try JSONEncoder().encode(schema).count
            XCTAssertGreaterThan(bytes, 0)
            for route in [AIRoute.onDevice, .appleCloud] {
                XCTAssertLessThanOrEqual(bytes, AICapabilities.forRoute(route).schemaReserve, kind.rawValue)
            }
        }
    }

    func testIOS26GenerationErrorsMapUsingActualSDKErrorTypes() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("Foundation Models errors require iOS 26") }
        let errors: [(String, Error)] = [
            ("context", LanguageModelSession.GenerationError.exceededContextWindowSize(.init(debugDescription: "synthetic old context"))),
            ("unavailable", LanguageModelSession.GenerationError.assetsUnavailable(.init(debugDescription: "synthetic unavailable assets"))),
            ("malformed", LanguageModelSession.GenerationError.decodingFailure(.init(debugDescription: "synthetic decoding failure")))
        ]
        for (kind, error) in errors {
            await assertAIError(kind) { throw AppleAIProvider.mapError(error) }
        }
    }

    func testIOS27CloudAndContextErrorsMapUsingActualSDKErrorTypes() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("PCC errors require iOS 27") }
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let errors: [(String, Error)] = [
            ("network", PrivateCloudComputeLanguageModel.Error.networkFailure(.init(debugDescription: "synthetic network"))),
            ("service", PrivateCloudComputeLanguageModel.Error.serviceUnavailable(.init(debugDescription: "synthetic service"))),
            ("quota", PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(limitIncreaseSuggestion: nil, resetDate: nil, debugDescription: "synthetic quota"))),
            ("quota", PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(limitIncreaseSuggestion: nil, resetDate: reset, debugDescription: "synthetic quota with reset"))),
            ("context", LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 4097, debugDescription: "synthetic context")))
        ]
        for (kind, error) in errors {
            await assertAIError(kind) { throw AppleAIProvider.mapError(error) }
        }
        let noReset = AppleAIProvider.mapError(errors[2].1).localizedDescription
        XCTAssertTrue(noReset.contains("未提供重置時間"), noReset)
        let withReset = AppleAIProvider.mapError(errors[3].1).localizedDescription
        XCTAssertTrue(withReset.contains("重置時間"), withReset)
        XCTAssertFalse(withReset.contains("每日"), withReset)
    }

    func testSummaryPipelineKeepsSuccessStatusAndWritesValidatedOutputs() async throws {
        let provider = SyntheticAIProvider(route: .onDevice)
        let service = ApplicationAIService(config: configuration(.onDevice, emptyCredentials: true), provider: provider)
        let episode = fixtureEpisode()
        let pipeline = SummaryPipeline()

        await pipeline.runAll(episode: episode, service: service)

        XCTAssertFalse(pipeline.running)
        XCTAssertTrue(pipeline.stage.contains("完成"), pipeline.stage)
        XCTAssertTrue(episode.summaryMarkdown?.contains("Synthetic summary") == true)
        XCTAssertNotNil(episode.takeawaysJSON)
        XCTAssertNotNil(episode.chaptersJSON)
        XCTAssertNotNil(episode.mindmapJSON)
        XCTAssertNotNil(episode.insightsJSON)
        XCTAssertEqual(provider.requests.map(\.operation), [.overview, .takeaways, .chapters, .mindmap, .insights])
        _ = try JSONDecoder().decode(TakeawaysOutput.self, from: Data(try XCTUnwrap(episode.takeawaysJSON).utf8))
        _ = try JSONDecoder().decode(ChaptersOutput.self, from: Data(try XCTUnwrap(episode.chaptersJSON).utf8))
        _ = try JSONDecoder().decode(MindmapOutput.self, from: Data(try XCTUnwrap(episode.mindmapJSON).utf8))
        _ = try JSONDecoder().decode(InsightsOutput.self, from: Data(try XCTUnwrap(episode.insightsJSON).utf8))
    }

    func testSummaryPipelineKeepsFailureStatusAndExistingResults() async {
        let provider = SyntheticAIProvider(route: .appleCloud)
        provider.failure = .quota("synthetic quota limit")
        let service = ApplicationAIService(config: configuration(.appleCloud, emptyCredentials: true), provider: provider)
        let episode = fixtureEpisode()
        episode.summaryMarkdown = "Existing summary"
        episode.takeawaysJSON = "Existing takeaways"
        let pipeline = SummaryPipeline()

        await pipeline.runAll(episode: episode, service: service)

        XCTAssertFalse(pipeline.running)
        XCTAssertTrue(pipeline.stage.contains("失敗"), pipeline.stage)
        XCTAssertTrue(pipeline.stage.contains("synthetic quota limit"), pipeline.stage)
        XCTAssertEqual(episode.summaryMarkdown, "Existing summary")
        XCTAssertEqual(episode.takeawaysJSON, "Existing takeaways")
        XCTAssertEqual(provider.requests.count, 1)
    }

    func testSummaryPipelineKeepsEmptyTranscriptStatus() async {
        let provider = SyntheticAIProvider(route: .onDevice)
        let service = ApplicationAIService(config: configuration(.onDevice), provider: provider)
        let pipeline = SummaryPipeline()
        let episode = EpisodeItem(title: "Synthetic empty episode", audioURL: "https://fixture.invalid/empty.mp3")

        await pipeline.runAll(episode: episode, service: service)

        XCTAssertFalse(pipeline.running)
        XCTAssertFalse(pipeline.stage.isEmpty)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testSnipPersistsRawTextAndVisibleErrorWhenAIThrows() async throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let episode = fixtureEpisode()
        context.insert(episode)
        try context.save()
        let provider = SyntheticAIProvider(route: .appleCloud)
        provider.failure = .quota("synthetic quota limit")
        provider.onRequest = { _ in
            XCTAssertFalse(context.hasChanges, "Raw capture must be saved before a model request begins")
            let raw = try? context.fetch(FetchDescriptor<Snip>())
            XCTAssertEqual(raw?.count, 1)
            XCTAssertEqual(raw?.first?.text, self.fixtureSegments.map(\.text).joined(separator: " "))
            XCTAssertNil(raw?.first?.aiNote)
        }
        let service = ApplicationAIService(config: configuration(.appleCloud, emptyCredentials: true), provider: provider)
        let snack = Snack(context: context)

        let captured = await snack.snip(episodeID: episode.id, title: episode.title, service: service, captureTime: 2)
        let snip = try XCTUnwrap(captured)

        XCTAssertEqual(snip.text, fixtureSegments.map(\.text).joined(separator: " "))
        XCTAssertNil(snip.aiNote)
        XCTAssertTrue(snip.aiError?.contains("synthetic quota limit") == true)
        XCTAssertEqual(provider.requests.map(\.operation), [.note])
        let persisted = try context.fetch(FetchDescriptor<Snip>())
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.text, snip.text)
        XCTAssertEqual(persisted.first?.aiError, snip.aiError)
    }

    func testSnipStoresParsedNoteInsteadOfRawJSON() async throws {
        let container = try inMemoryContainer()
        let context = container.mainContext
        let episode = fixtureEpisode()
        context.insert(episode)
        try context.save()
        let provider = SyntheticAIProvider(route: .onDevice)
        let service = ApplicationAIService(config: configuration(.onDevice, emptyCredentials: true), provider: provider)
        let snack = Snack(context: context)

        let captured = await snack.snip(episodeID: episode.id, title: episode.title, service: service, captureTime: 2)
        let snip = try XCTUnwrap(captured)

        XCTAssertEqual(snip.aiNote, "Synthetic parsed note")
        XCTAssertFalse(snip.aiNote?.contains("{\"note\"") == true)
        XCTAssertNil(snip.aiError)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Snip>()).count, 1)
    }

    func testLegacySnipJSONDisplaysParsedNoteAndPlainTextRemainsReadable() {
        XCTAssertEqual(displayedSnipNote(#"{"note":"Synthetic legacy note"}"#), "Synthetic legacy note")
        XCTAssertEqual(displayedSnipNote("Synthetic plain note"), "Synthetic plain note")
        XCTAssertEqual(displayedSnipNote("{invalid historical value"), "{invalid historical value")
    }

    // MARK: Authored, non-private test inputs

    private var fixtureSegments: [TranscriptSegment] {
        [TranscriptSegment(start: 0, end: 4, text: "Synthetic transcript starts here."),
         TranscriptSegment(start: 4, end: 8, text: "The authored fixture explains a second point.")]
    }

    private func fixtureEpisode() -> EpisodeItem {
        let episode = EpisodeItem(title: "Synthetic episode", audioURL: "https://fixture.invalid/episode.mp3", duration: 8)
        episode.segments = fixtureSegments
        return episode
    }

    private func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(for: EpisodeItem.self, Snip.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func configuration(_ route: AIRoute, emptyCredentials: Bool = false) -> AIConfig {
        AIConfig(baseURL: emptyCredentials ? "" : "https://fixture.invalid/v1",
                 apiKey: emptyCredentials ? "" : "synthetic-test-key",
                 model: emptyCredentials ? "" : "synthetic-model", routeRaw: route.rawValue)
    }

    private func operation(for kind: AIOutputKind) -> AIOperation {
        switch kind {
        case .overview: return .overview
        case .takeaways: return .takeaways
        case .chapters: return .chapters
        case .mindmap: return .mindmap
        case .insights: return .insights
        case .note: return .note
        }
    }

    private func perform(_ operation: AIOperation, service: ApplicationAIService) async throws {
        let transcript = "[00:00] Synthetic transcript starts here.\n[00:04] A second authored point."
        switch operation {
        case .overview: _ = try await service.overview(transcript: transcript)
        case .takeaways: _ = try await service.takeaways(transcript: transcript)
        case .chapters: _ = try await service.chapters(transcript: transcript, totalSeconds: 8)
        case .mindmap: _ = try await service.mindmap(transcript: transcript)
        case .insights: _ = try await service.insights(transcript: transcript)
        case .question: _ = try await service.answer(question: "What is explained?", segments: fixtureSegments)
        case .note: _ = try await service.note(segment: "Synthetic transcript starts here.")
        case .connectionTest: _ = try await service.testConnection()
        }
    }

    private func assertAIError(_ expected: String, file: StaticString = #filePath, line: UInt = #line,
                               _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("Expected AIServiceError.\(expected)", file: file, line: line)
        } catch let error as AIServiceError {
            let actual: String
            switch error {
            case .unavailable: actual = "unavailable"
            case .context: actual = "context"
            case .malformed: actual = "malformed"
            case .quota: actual = "quota"
            case .network: actual = "network"
            case .service: actual = "service"
            }
            XCTAssertEqual(actual, expected, error.localizedDescription, file: file, line: line)
        } catch {
            XCTFail("Expected AIServiceError.\(expected), got \(error)", file: file, line: line)
        }
    }
}

/// A local spy, not a model. Every return value is authored below.
private final class SyntheticAIProvider: AIProvider {
    let route: AIRoute
    var availability = AIAvailability(isAvailable: true, reason: "Synthetic provider available")
    var failure: AIServiceError?
    var overrideStructuredData: Data?
    var onRequest: (@MainActor (AIRequest) -> Void)?
    private(set) var requests: [AIRequest] = []
    private(set) var kinds: [AIOutputKind] = []

    init(route: AIRoute) { self.route = route }

    func text(_ request: AIRequest) async throws -> String {
        requests.append(request)
        await onRequest?(request)
        if let failure { throw failure }
        return request.operation == .connectionTest ? "OK" : "Synthetic answer [00:00]"
    }

    func structured(_ request: AIRequest, kind: AIOutputKind) async throws -> Data {
        requests.append(request)
        await onRequest?(request)
        kinds.append(kind)
        if let failure { throw failure }
        if let overrideStructuredData { return overrideStructuredData }
        let encoder = JSONEncoder()
        switch kind {
        case .overview:
            return try encoder.encode(OverviewOutput(summary: "Synthetic summary", guests: "", topics: ["Synthetic topic"]))
        case .takeaways:
            return try encoder.encode(TakeawaysOutput(takeaways: [TakeawayOutput(title: "Synthetic takeaway", detail: "Authored detail", at: firstTimestamp(in: request.user))]))
        case .chapters:
            return try encoder.encode(ChaptersOutput(chapters: [ChapterOutput(start: firstTimestamp(in: request.user), title: "Synthetic chapter", summary: "Authored chapter summary")]))
        case .mindmap:
            return try encoder.encode(MindmapOutput(topic: "Synthetic topic", branches: [MindBranchOutput(label: "Synthetic branch", children: [MindLeafOutput(label: "Synthetic leaf")])]))
        case .insights:
            return try encoder.encode(InsightsOutput(insights: [InsightOutput(title: "Synthetic insight", body: "Authored insight body")], open_questions: ["Synthetic question?"]))
        case .note:
            return try encoder.encode(NoteOutput(note: "Synthetic parsed note"))
        }
    }

    private func firstTimestamp(in text: String) -> Double {
        guard let expression = try? NSRegularExpression(pattern: #"\((\d+(?:\.\d+)?)s–"#),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return 0 }
        return Double(text[range]) ?? 0
    }
}
