import XCTest
@testable import PomodoroPush

private final class PushURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Int)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let status = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class PomodoroPushTests: XCTestCase {
    func testCumulativeSecondsExcludePauseAndKeepSessionAfterRestore() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = PomodoroPushSession(phase: "focus", plannedSeconds: 1500, startedAt: start)
        let paused = session.event("pause", remainingSeconds: 1200, completedToday: 0, now: start.addingTimeInterval(300))
        let restored = try JSONDecoder().decode(PomodoroPushSession.self, from: JSONEncoder().encode(session))
        let resumed = restored.event("resume", remainingSeconds: 1200, completedToday: 0, now: start.addingTimeInterval(900))
        XCTAssertEqual(paused.elapsed_seconds, 300)
        XCTAssertEqual(resumed.elapsed_seconds, 300)
        XCTAssertEqual(paused.session_id, resumed.session_id)
        XCTAssertNotEqual(paused.event_id, resumed.event_id)
        XCTAssertEqual(paused.activity, "work")
        XCTAssertTrue(paused.occurred_at.hasSuffix("+08:00"))
        XCTAssertEqual(restored.event("complete", remainingSeconds: 0, completedToday: 1).elapsed_seconds, 1500)
    }

    func testBreakJSONContractAndBounds() throws {
        for phase in ["shortBreak", "longBreak"] {
            let session = PomodoroPushSession(phase: phase, plannedSeconds: 600)
            let event = session.event("reset", remainingSeconds: 420, completedToday: 2)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
            XCTAssertEqual(json["activity"] as? String, "break")
            XCTAssertEqual(json["schema_version"] as? Int, 1)
            XCTAssertEqual(json["elapsed_seconds"] as? Int, 180)
            XCTAssertEqual(session.event("complete", remainingSeconds: -10, completedToday: 2).elapsed_seconds, 600)
            XCTAssertEqual(session.event("start", remainingSeconds: 700, completedToday: 2).elapsed_seconds, 0)
            XCTAssertNil(json["key"])
        }
    }

    @MainActor
    func testPOSTUsesConfiguredKeyAndAcknowledgedEventLeavesQueue() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = base.appendingPathComponent("boringNotch/Pomodoro")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "POMODORO_PUSH_KEY=test-only-key\n".write(to: directory.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let event = PomodoroPushSession(phase: "focus", plannedSeconds: 1500).event("start", remainingSeconds: 1500, completedToday: 0)
        let received = expectation(description: "POST received")
        PushURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), event.event_id.uuidString)
            XCTAssertEqual(request.url?.host, "clawapi.5bug.eu.org")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "test-only-key")
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            XCTAssertEqual(try JSONDecoder().decode(PomodoroPushEvent.self, from: body).event_id, event.event_id)
            received.fulfill()
            return 204
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PushURLProtocol.self]
        let client = URLSession(configuration: config)
        defer { client.invalidateAndCancel() }
        let service = PomodoroPushService(directory: directory, client: client)
        service.enqueue(event)
        await fulfillment(of: [received], timeout: 3)
        // Let the response resume the delivery task before inspecting its durable queue.
        for _ in 0..<100 {
            let data = try Data(contentsOf: directory.appendingPathComponent("push-queue.json"))
            if try JSONDecoder().decode([PomodoroPushEvent].self, from: data).isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Acknowledged event was not removed")
    }

    @MainActor
    func testFailedRequestSurvivesRestartWithSameEventID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "POMODORO_PUSH_KEY=test-only-key\n".write(to: directory.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PushURLProtocol.self]
        let client = URLSession(configuration: config)
        defer { client.invalidateAndCancel() }
        let event = PomodoroPushSession(phase: "longBreak", plannedSeconds: 1200).event("pause", remainingSeconds: 600, completedToday: 4)
        let failed = expectation(description: "server rejected event")
        PushURLProtocol.handler = { _ in failed.fulfill(); return 503 }
        let first = PomodoroPushService(directory: directory, client: client)
        first.enqueue(event)
        await fulfillment(of: [failed], timeout: 3)
        let pending = try JSONDecoder().decode([PomodoroPushEvent].self, from: Data(contentsOf: directory.appendingPathComponent("push-queue.json")))
        XCTAssertEqual(pending.map(\.event_id), [event.event_id])
        let retried = expectation(description: "restored queue delivered")
        PushURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), event.event_id.uuidString)
            retried.fulfill()
            return 200
        }
        let restarted = PomodoroPushService(directory: directory, client: client)
        await fulfillment(of: [retried], timeout: 3)
        withExtendedLifetime(restarted) {}
    }
}
