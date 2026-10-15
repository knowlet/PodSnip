import XCTest
@testable import PodSnip

/// URLProtocol intercepts every request in these ephemeral sessions. All hosts,
/// API keys, model names, and responses are synthetic; no endpoint is contacted.
final class AIClientTransportTests: XCTestCase {
    func testPlainTextTransportSendsConfiguredModelMessagesAndTokenLimit() async throws {
        let fixture = try TransportFixture(content: "Synthetic plain response", finishReason: "stop")
        let provider = AIClient(config: fixture.config, session: fixture.session)
        let request = AIRequest(operation: .question, system: "Synthetic system instruction",
                                user: "Synthetic user question", maximumOutputTokens: 384)

        let result = try await provider.text(request)

        XCTAssertEqual(result, "Synthetic plain response")
        let captured = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(captured.url?.path, "/v1/chat/completions")
        XCTAssertEqual(captured.method, "POST")
        XCTAssertEqual(captured.authorization, "Bearer synthetic-transport-key")
        XCTAssertEqual(captured.contentType, "application/json")
        let body = try fixture.body()
        XCTAssertEqual(body["model"] as? String, "synthetic-transport-model")
        XCTAssertEqual(body["max_tokens"] as? Int, 384)
        XCTAssertEqual(body["temperature"] as? Double, 0.3)
        XCTAssertNil(body["response_format"], "Plain text must not require JSON mode")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "system", "content": "Synthetic system instruction"],
                                  ["role": "user", "content": "Synthetic user question"]])
    }

    func testStructuredTransportRequestsJSONAndSharedServiceValidatesItsShape() async throws {
        let json = #"{"summary":"Synthetic transport summary","guests":"","topics":["Synthetic topic"]}"#
        let fixture = try TransportFixture(content: json, finishReason: "stop")
        let provider = AIClient(config: fixture.config, session: fixture.session)
        let service = ApplicationAIService(config: fixture.config, provider: provider)

        let overview = try await service.overview(transcript: "Synthetic transport transcript")

        XCTAssertEqual(overview.summary, "Synthetic transport summary")
        XCTAssertEqual(overview.topics, ["Synthetic topic"])
        let body = try fixture.body()
        XCTAssertEqual(body["response_format"] as? [String: String], ["type": "json_object"])
        XCTAssertEqual(body["max_tokens"] as? Int, AICapabilities.forRoute(.byok).maximumOutputTokens)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testMalformedJSONFromEndpointIsVisibleAndDoesNotRetry() async throws {
        let fixture = try TransportFixture(content: "{malformed synthetic JSON", finishReason: "stop")
        let service = ApplicationAIService(config: fixture.config,
                                           provider: AIClient(config: fixture.config, session: fixture.session))
        do {
            _ = try await service.overview(transcript: "Synthetic transcript")
            XCTFail("Malformed endpoint output must not be stored as a summary")
        } catch AIServiceError.malformed { }
        catch { XCTFail("Expected malformed output, got \(error)") }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testValidJSONWithInvalidSharedShapeIsVisible() async throws {
        let fixture = try TransportFixture(content: #"{"note":"   "}"#, finishReason: "stop")
        let service = ApplicationAIService(config: fixture.config,
                                           provider: AIClient(config: fixture.config, session: fixture.session))
        do {
            _ = try await service.note(segment: "Synthetic excerpt")
            XCTFail("A blank note must fail the shared output contract")
        } catch AIServiceError.malformed { }
        catch { XCTFail("Expected malformed output, got \(error)") }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testLengthFinishReasonSurfacesContextErrorWithoutAcceptingPartialOutput() async throws {
        let fixture = try TransportFixture(content: "Synthetic partial output", finishReason: "length")
        let provider = AIClient(config: fixture.config, session: fixture.session)
        do {
            _ = try await provider.text(textRequest)
            XCTFail("Truncated output must remain a visible context error")
        } catch AIServiceError.context { }
        catch { XCTFail("Expected context error, got \(error)") }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testNonStopFinishReasonSurfacesMalformedOutputWithoutRetry() async throws {
        for reason in ["content_filter", "tool_calls"] {
            let fixture = try TransportFixture(content: "Synthetic incomplete text", finishReason: reason)
            let provider = AIClient(config: fixture.config, session: fixture.session)
            do {
                _ = try await provider.text(textRequest)
                XCTFail("Unfinished \(reason) response must not be accepted")
            } catch AIServiceError.malformed(let message) { XCTAssertTrue(message.contains(reason)) }
            catch { XCTFail("Expected malformed output, got \(error)") }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testCompatibleEndpointMayOmitFinishReason() async throws {
        let fixture = try TransportFixture(content: "Synthetic compatible response", finishReason: nil)
        let provider = AIClient(config: fixture.config, session: fixture.session)
        let result = try await provider.text(textRequest)
        XCTAssertEqual(result, "Synthetic compatible response")
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testHTTPFailurePreservesStatusAndSyntheticResponseBody() async throws {
        let fixture = try TransportFixture(responseData: Data("synthetic rate limit".utf8), status: 429)
        let provider = AIClient(config: fixture.config, session: fixture.session)
        do {
            _ = try await provider.text(textRequest)
            XCTFail("HTTP failure must not be accepted")
        } catch AIError.http(let status, let body) {
            XCTAssertEqual(status, 429)
            XCTAssertEqual(body, "synthetic rate limit")
        } catch { XCTFail("Expected HTTP error, got \(error)") }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    private var textRequest: AIRequest {
        AIRequest(operation: .connectionTest, system: "Synthetic system", user: "Synthetic ping", maximumOutputTokens: 16)
    }
}

private struct CapturedTransportRequest {
    let url: URL?
    let method: String?
    let authorization: String?
    let contentType: String?
    let data: Data
}

private final class TransportState {
    let responseData: Data
    let status: Int
    private let lock = NSLock()
    private var captured: [CapturedTransportRequest] = []

    init(responseData: Data, status: Int) { self.responseData = responseData; self.status = status }

    var requests: [CapturedTransportRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    func capture(_ request: URLRequest) {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        let value = CapturedTransportRequest(url: request.url, method: request.httpMethod,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"), data: data)
        lock.lock(); defer { lock.unlock() }
        captured.append(value)
    }
}

private final class TransportFixture {
    let config: AIConfig
    let session: URLSession
    private let state: TransportState
    private let host: String
    var requests: [CapturedTransportRequest] { state.requests }

    convenience init(content: String, finishReason: String?) throws {
        var choice: [String: Any] = ["message": ["content": content]]
        if let finishReason { choice["finish_reason"] = finishReason }
        let data = try JSONSerialization.data(withJSONObject: ["choices": [choice]])
        try self.init(responseData: data, status: 200)
    }

    init(responseData: Data, status: Int) throws {
        host = UUID().uuidString.lowercased() + ".invalid"
        state = TransportState(responseData: responseData, status: status)
        FixtureURLProtocol.register(state, host: host)
        config = AIConfig(baseURL: "https://\(host)/v1/", apiKey: "synthetic-transport-key",
                          model: "synthetic-transport-model", routeRaw: AIRoute.byok.rawValue)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
        FixtureURLProtocol.unregister(host: host)
    }

    func body() throws -> [String: Any] {
        let request = try XCTUnwrap(requests.first)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: request.data) as? [String: Any])
    }
}

private final class FixtureURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var fixtures: [String: TransportState] = [:]

    static func register(_ state: TransportState, host: String) {
        lock.lock(); defer { lock.unlock() }
        fixtures[host] = state
    }

    static func unregister(host: String) {
        lock.lock(); defer { lock.unlock() }
        fixtures.removeValue(forKey: host)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let state = request.url?.host.flatMap { Self.fixtures[$0] }
        Self.lock.unlock()
        guard let state, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: state.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            // Missing fixtures fail closed inside URLProtocol; never reach a network.
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        state.capture(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: state.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
