import Foundation
import OSLog

struct PomodoroPushSession: Codable {
    let id: UUID
    let phase: String
    let plannedSeconds: Int
    let startedAt: Date

    init(phase: String, plannedSeconds: Int, startedAt: Date = Date()) {
        id = UUID()
        self.phase = phase
        self.plannedSeconds = plannedSeconds
        self.startedAt = startedAt
    }

    func event(_ action: String, remainingSeconds: Int, completedToday: Int, isRunning: Bool = false, now: Date = Date()) -> PomodoroPushEvent {
        let remaining = min(plannedSeconds, max(0, remainingSeconds))
        return PomodoroPushEvent(
            event_id: UUID(), session_id: id, event: action,
            phase: phase, activity: phase == "focus" ? "work" : "break",
            occurred_at: Self.timestamp(now), session_started_at: Self.timestamp(startedAt),
            planned_seconds: plannedSeconds, elapsed_seconds: plannedSeconds - remaining,
            remaining_seconds: remaining, completed_today: completedToday, is_running: isRunning
        )
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

struct PomodoroPushEvent: Codable {
    var schema_version = 1
    var source = "boring_notch"
    let event_id: UUID
    let session_id: UUID
    let event: String
    let phase: String
    let activity: String
    let occurred_at: String
    let session_started_at: String
    let planned_seconds: Int
    let elapsed_seconds: Int
    let remaining_seconds: Int
    let completed_today: Int
    let is_running: Bool
}

// Never forward the key to another host through a server redirect.
private final class PomodoroRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class PomodoroPushService {
    static let shared = PomodoroPushService()
    private let logger = Logger(subsystem: "theboringteam.boringnotch", category: "PomodoroPush")
    private let directory: URL
    private var queue: [PomodoroPushEvent] = []
    private var deliveryTask: Task<Void, Never>?
    private let client: URLSession

    private var queueURL: URL { directory.appendingPathComponent("push-queue.json") }

    init(directory storageDirectory: URL? = nil, client: URLSession? = nil) {
        self.client = client ?? URLSession(configuration: .ephemeral, delegate: PomodoroRedirectPolicy(), delegateQueue: nil)
        self.directory = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("boringNotch/Pomodoro", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: queueURL.path) {
                queue = try JSONDecoder().decode([PomodoroPushEvent].self, from: Data(contentsOf: queueURL))
            }
        } catch {
            logger.error("Unable to load Pomodoro push queue")
        }
        deliverPending()
    }

    func enqueue(_ event: PomodoroPushEvent) {
        queue.append(event)
        persistQueue()
        deliverPending()
    }

    private func persistQueue() {
        do {
            try JSONEncoder().encode(queue).write(to: queueURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            logger.error("Unable to save Pomodoro push queue")
        }
    }

    private func request(for event: PomodoroPushEvent) throws -> URLRequest {
        let configuration = try String(contentsOf: directory.appendingPathComponent(".env"), encoding: .utf8)
        let token = configuration.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("POMODORO_PUSH_KEY=") }?
            .dropFirst("POMODORO_PUSH_KEY=".count).trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
        var url = URLComponents(string: "https://clawapi.5bug.eu.org/pomo")!
        url.queryItems = [URLQueryItem(name: "key", value: token)]
        var request = URLRequest(url: url.url!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(event.event_id.uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONEncoder().encode(event)
        return request
    }

    private func deliverPending() {
        guard deliveryTask == nil, !queue.isEmpty else { return }
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            defer { deliveryTask = nil }
            var retrySeconds = 30
            while !Task.isCancelled, let event = queue.first {
                do {
                    let (_, response) = try await client.data(for: request(for: event))
                    guard let response = response as? HTTPURLResponse,
                          (200..<300).contains(response.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    queue.removeFirst()
                    persistQueue()
                    retrySeconds = 30
                } catch {
                    // URLSession errors may contain the authenticated URL; log no error details.
                    logger.warning("Pomodoro push pending; retry scheduled")
                    do { try await Task.sleep(for: .seconds(retrySeconds)) }
                    catch { return }
                    retrySeconds = min(retrySeconds * 2, 300)
                }
            }
        }
    }
}
