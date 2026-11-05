import Defaults
import SwiftUI

struct OpenNotchContentView: View {
    private static let permissionViewportHeight = max(0, openNotchSize.height - 12)

    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var coordinator = BoringViewCoordinator.shared

    let albumArtNamespace: Namespace.ID
    let horizontalMediaGestureFeedback: CGFloat
    @Binding var isHoveringMusicArea: Bool
    let gestureProgress: CGFloat
    let permissionNotification: CodexJobNotification?

    var body: some View {
        VStack {
            if let permissionNotification {
                CodexPermissionApprovalView(
                    notification: permissionNotification
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: Self.permissionViewportHeight, alignment: .topLeading)
            } else {
                switch selectedDestination {
                case .home:
                    NotchHomeView(
                        albumArtNamespace: albumArtNamespace,
                        horizontalMediaGestureFeedback: horizontalMediaGestureFeedback,
                        isHoveringMusicArea: $isHoveringMusicArea
                    )
                case .shelf:
                    ShelfView()
                case .agent:
                    AgentTasksPanelView()
                case .pomodoro:
                    PomodoroNotchView()
                case nil:
                    EmptyView()
                }
            }
        }
        .frame(
            maxWidth: permissionNotification == nil ? nil : .infinity,
            alignment: .topLeading
        )
        .frame(
            height: permissionNotification == nil ? nil : Self.permissionViewportHeight,
            alignment: .topLeading
        )
        .transition(contentTransition)
        .zIndex(1)
        .allowsHitTesting(vm.notchState == .open)
        .opacity(gestureProgress == 0 ? 1 : 1 - min(abs(gestureProgress) * 0.1, 0.3))
    }

    private var selectedDestination: NotchViews? {
        let availableDestinations = NotchDestinationDescriptor.availableBuiltIn
        return availableDestinations.first {
            $0.destination == coordinator.currentView
        }?.destination ?? availableDestinations.first?.destination
    }

    private var contentTransition: AnyTransition {
        if permissionNotification != nil {
            return .opacity
                .combined(with: .scale(scale: 0.9, anchor: .top))
        }
        return .scale(scale: 0.8, anchor: .top)
            .combined(with: .opacity)
            .animation(.smooth(duration: 0.35))
    }
}

private struct AgentTasksPanelView: View {
    @ObservedObject private var manager = CodexNotificationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if manager.agentTasks.isEmpty {
                Spacer(minLength: 0)
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(manager.agentTasks) { task in
                            AgentTaskRow(task: task) {
                                manager.dismissAgentTask(id: task.id)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AgentTaskRow: View {
    let task: AgentTaskRecord
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(statusColor.opacity(0.18))
                Image(systemName: task.provider.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(task.provider.imperialDisplayName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(statusColor)
                    Text(task.status.imperialShortTitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Text(task.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(task.projectName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove task")
        }
        .padding(8)
        .background(.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        switch task.status {
        case .running: .cyan
        case .needsAction(.permission): .orange
        case .needsAction(.decision): .purple
        case .needsAction(.manualCheck): .blue
        case .failed: .red
        case .succeeded: .green
        }
    }
}

@MainActor
final class PomodoroManager: ObservableObject {
    static let shared = PomodoroManager()

    @Published private(set) var phase: PomodoroPhase = .focus
    @Published private(set) var isRunning = false
    @Published private(set) var secondsRemaining = 0
    @Published private(set) var completedToday: Int
    @Published private(set) var phaseStartedAt = Date.distantPast
    @Published var pendingPrompt: PomodoroPrompt?

    private var timerTask: Task<Void, Never>?
    private var pushSession: PomodoroPushSession?
    private let pushSessionKey = "pomodoroPushSessionV1"

    private init() {
        _ = PomodoroPushService.shared
        Self.resetDailyCountIfNeeded()
        completedToday = Defaults[.pomodoroCompletedToday]
        if let data = UserDefaults.standard.data(forKey: pushSessionKey) {
            pushSession = try? JSONDecoder().decode(PomodoroPushSession.self, from: data)
        }
        if !restoreCachedState() {
            pushSession = nil
            secondsRemaining = Self.duration(for: .focus)
            cacheState()
        } else if pendingPrompt == nil, pushSession != nil {
            push("restore")
        }
    }

    func start() {
        guard pendingPrompt == nil, !isRunning else { return }
        let action = pushSession == nil ? "start" : "resume"
        if pushSession == nil {
            pushSession = PomodoroPushSession(phase: phase.rawValue, plannedSeconds: secondsRemaining)
        }
        Self.resetDailyCountIfNeeded()
        completedToday = Defaults[.pomodoroCompletedToday]
        isRunning = true
        phaseStartedAt = Date()
        cacheState()
        push(action)
        scheduleTimer()
    }

    func pause() {
        guard isRunning else { return }
        stopTimer()
        push("pause")
        cacheState()
    }

    private func stopTimer() {
        isRunning = false
        timerTask?.cancel()
        timerTask = nil
        cacheState()
    }

    func reset() {
        stopTimer()
        push("reset")
        pushSession = nil
        pendingPrompt = nil
        phase = .focus
        secondsRemaining = Self.duration(for: .focus)
        phaseStartedAt = .distantPast
        cacheState()
    }

    func confirmPendingPrompt() {
        guard let prompt = pendingPrompt else { return }
        pendingPrompt = nil
        phase = prompt.nextPhase
        secondsRemaining = Self.duration(for: prompt.nextPhase)
        pushSession = PomodoroPushSession(phase: phase.rawValue, plannedSeconds: secondsRemaining)
        isRunning = true
        phaseStartedAt = Date()
        cacheState()
        push("start")
        scheduleTimer()
    }

    func applySettingsIfIdle() {
        guard !isRunning, pendingPrompt == nil, pushSession == nil else { return }
        secondsRemaining = min(secondsRemaining, Self.duration(for: phase))
        if secondsRemaining <= 0 {
            secondsRemaining = Self.duration(for: phase)
        }
        cacheState()
    }

    func flushPersistence() {
        if isRunning { push("shutdown") }
        cacheState()
        UserDefaults.standard.synchronize()
    }

    var totalSeconds: Int {
        pushSession?.plannedSeconds ?? Self.duration(for: phase)
    }

    private func scheduleTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
    }

    private func tick() {
        guard isRunning, pendingPrompt == nil else { return }
        if secondsRemaining > 1 {
            secondsRemaining -= 1
            cacheState()
            if let pushSession, (pushSession.plannedSeconds - secondsRemaining) % 60 == 0 {
                push("progress")
            }
            return
        }
        secondsRemaining = 0
        cacheState()
        finishCurrentPhase()
    }

    private func finishCurrentPhase() {
        stopTimer()
        switch phase {
        case .focus:
            Self.resetDailyCountIfNeeded()
            Defaults[.pomodoroCompletedToday] += 1
            completedToday = Defaults[.pomodoroCompletedToday]

            let target = max(1, Defaults[.pomodoroDailyTarget])
            let shouldTakeLongBreak = completedToday % 4 == 0 || completedToday == target
            let nextPhase: PomodoroPhase = shouldTakeLongBreak ? .longBreak : .shortBreak
            pendingPrompt = PomodoroPrompt(
                title: "陛下该歇息了",
                message: shouldTakeLongBreak
                    ? "陛下今日已批不少奏折，该去运动、喝茶，舒展筋骨，否则龙体抱恙。"
                    : "陛下小憩片刻吧，该喝茶、起身走走了，否则龙体抱恙。",
                confirmTitle: "准奏，开始休息",
                nextPhase: nextPhase
            )
        case .shortBreak, .longBreak:
            pendingPrompt = PomodoroPrompt(
                title: "陛下休息结束",
                message: "陛下，茶已温好，精神也该回来了。请继续批阅奏折。",
                confirmTitle: "继续批阅",
                nextPhase: .focus
            )
        }
        push("complete")
        cacheState()
    }

    private func push(_ action: String) {
        guard let pushSession else { return }
        PomodoroPushService.shared.enqueue(pushSession.event(
            action, remainingSeconds: secondsRemaining, completedToday: completedToday, isRunning: isRunning
        ))
    }

    private func restoreCachedState(now: Date = Date()) -> Bool {
        let today = Self.dayStamp(for: now)
        guard Defaults[.pomodoroCacheDate] == today else {
            Self.clearCachedState(for: today)
            return false
        }

        let pendingNextPhase = PomodoroPhase(rawValue: Defaults[.pomodoroCachedPendingNextPhase])
        guard let cachedPhase = PomodoroPhase(rawValue: Defaults[.pomodoroCachedPhase]) else {
            Self.clearCachedState(for: today)
            return false
        }
        guard Defaults[.pomodoroCachedSecondsRemaining] > 0 || pendingNextPhase != nil else {
            Self.clearCachedState(for: today)
            return false
        }

        phase = cachedPhase
        completedToday = Defaults[.pomodoroCompletedToday]
        phaseStartedAt = Defaults[.pomodoroCachedPhaseStartedAt] > 0
            ? Date(timeIntervalSinceReferenceDate: Defaults[.pomodoroCachedPhaseStartedAt])
            : .distantPast

        if let pendingNextPhase {
            isRunning = false
            secondsRemaining = max(0, Defaults[.pomodoroCachedSecondsRemaining])
            pendingPrompt = Self.prompt(forNextPhase: pendingNextPhase, completedToday: completedToday)
            return true
        }

        let cachedRemaining = Defaults[.pomodoroCachedSecondsRemaining]
        let wasRunning = Defaults[.pomodoroCachedIsRunning]
        if pushSession == nil, wasRunning {
            pushSession = PomodoroPushSession(
                phase: phase.rawValue, plannedSeconds: max(cachedRemaining, Self.duration(for: phase)),
                startedAt: phaseStartedAt == .distantPast ? now : phaseStartedAt
            )
        }
        if wasRunning {
            let savedAt = Date(timeIntervalSinceReferenceDate: Defaults[.pomodoroCachedSavedAt])
            let elapsed = max(0, Int(now.timeIntervalSince(savedAt)))
            secondsRemaining = max(0, cachedRemaining - elapsed)
            isRunning = secondsRemaining > 0
            if secondsRemaining > 0 {
                scheduleTimer()
            } else {
                finishCurrentPhase()
            }
        } else {
            secondsRemaining = cachedRemaining
            isRunning = false
        }

        return true
    }

    private func cacheState(now: Date = Date()) {
        if let pushSession, let data = try? JSONEncoder().encode(pushSession) {
            UserDefaults.standard.set(data, forKey: pushSessionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: pushSessionKey)
        }
        Defaults[.pomodoroCacheDate] = Self.dayStamp(for: now)
        Defaults[.pomodoroCachedPhase] = phase.rawValue
        Defaults[.pomodoroCachedSecondsRemaining] = secondsRemaining
        Defaults[.pomodoroCachedIsRunning] = isRunning
        Defaults[.pomodoroCachedPhaseStartedAt] = phaseStartedAt == .distantPast
            ? 0
            : phaseStartedAt.timeIntervalSinceReferenceDate
        Defaults[.pomodoroCachedSavedAt] = now.timeIntervalSinceReferenceDate
        Defaults[.pomodoroCachedPendingNextPhase] = pendingPrompt?.nextPhase.rawValue ?? ""
    }

    private static func clearCachedState(for dayStamp: String) {
        Defaults[.pomodoroCacheDate] = dayStamp
        Defaults[.pomodoroCachedPhase] = ""
        Defaults[.pomodoroCachedSecondsRemaining] = 0
        Defaults[.pomodoroCachedIsRunning] = false
        Defaults[.pomodoroCachedPhaseStartedAt] = 0
        Defaults[.pomodoroCachedSavedAt] = 0
        Defaults[.pomodoroCachedPendingNextPhase] = ""
    }

    private static func prompt(
        forNextPhase nextPhase: PomodoroPhase,
        completedToday: Int
    ) -> PomodoroPrompt {
        switch nextPhase {
        case .shortBreak, .longBreak:
            let shouldTakeLongBreak = nextPhase == .longBreak
            return PomodoroPrompt(
                title: "陛下该歇息了",
                message: shouldTakeLongBreak
                    ? "陛下今日已批不少奏折，该去运动、喝茶，舒展筋骨，否则龙体抱恙。"
                    : "陛下小憩片刻吧，该喝茶、起身走走了，否则龙体抱恙。",
                confirmTitle: "准奏，开始休息",
                nextPhase: nextPhase
            )
        case .focus:
            return PomodoroPrompt(
                title: "陛下休息结束",
                message: "陛下，茶已温好，精神也该回来了。请继续批阅奏折。",
                confirmTitle: "继续批阅",
                nextPhase: .focus
            )
        }
    }

    private static func duration(for phase: PomodoroPhase) -> Int {
        switch phase {
        case .focus:
            max(1, Defaults[.pomodoroFocusMinutes]) * 60
        case .shortBreak:
            max(1, Defaults[.pomodoroShortBreakMinutes]) * 60
        case .longBreak:
            max(1, Defaults[.pomodoroLongBreakMinutes]) * 60
        }
    }

    private static func resetDailyCountIfNeeded(now: Date = Date()) {
        let today = dayStamp(for: now)
        guard Defaults[.pomodoroCompletedDate] != today else { return }
        Defaults[.pomodoroCompletedDate] = today
        Defaults[.pomodoroCompletedToday] = 0
    }

    private static func dayStamp(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
}

enum PomodoroPhase: String {
    case focus
    case shortBreak
    case longBreak

    var title: String {
        switch self {
        case .focus: "批阅奏折"
        case .shortBreak: "小休"
        case .longBreak: "大休"
        }
    }

    var icon: String {
        switch self {
        case .focus: "scroll.fill"
        case .shortBreak: "cup.and.saucer.fill"
        case .longBreak: "figure.walk"
        }
    }

    var tint: Color {
        switch self {
        case .focus: .cyan
        case .shortBreak: .mint
        case .longBreak: .orange
        }
    }
}

struct PomodoroPrompt: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let nextPhase: PomodoroPhase
}

private struct PomodoroNotchView: View {
    @ObservedObject private var manager = PomodoroManager.shared

    var body: some View {
        VStack(spacing: 10) {
            header
            timerDisplay
            progress
            controls
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: manager.phase.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(manager.phase.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(manager.pendingPrompt?.title ?? manager.phase.title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Text("\(manager.completedToday)/\(Defaults[.pomodoroDailyTarget])")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(manager.phase.tint)
        }
    }

    private var timerDisplay: some View {
        Text(timeString(manager.secondsRemaining))
            .font(.system(size: 36, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .minimumScaleFactor(0.7)
    }

    private var progress: some View {
        ProgressView(value: progressValue)
            .tint(manager.phase.tint)
            .controlSize(.small)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if manager.pendingPrompt != nil {
                Button {
                    manager.confirmPendingPrompt()
                } label: {
                    Label(manager.pendingPrompt?.confirmTitle ?? "确认", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.effectiveAccent)
            } else {
                Button {
                    if manager.isRunning {
                        manager.pause()
                    } else {
                        manager.start()
                    }
                } label: {
                    Label(
                        manager.isRunning ? "暂停" : "开始",
                        systemImage: manager.isRunning ? "pause.fill" : "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.effectiveAccent)

                Button {
                    manager.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("重置番茄钟")
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var subtitle: String {
        if let prompt = manager.pendingPrompt {
            return prompt.message
        }
        return manager.isRunning ? "启奏陛下，正在计时。" : "番茄钟待命，请陛下发落。"
    }

    private var progressValue: Double {
        let total = max(1, totalSeconds)
        return 1 - Double(manager.secondsRemaining) / Double(total)
    }

    private var totalSeconds: Int {
        manager.totalSeconds
    }

    private func timeString(_ seconds: Int) -> String {
        String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }
}

private extension AgentTaskProvider {
    var imperialDisplayName: String {
        switch self {
        case .codex: "小GPT"
        case .openCode: "小OpenCode"
        case .zCode: "小ZCode"
        }
    }
}

private extension CodexJobStatus {
    var imperialShortTitle: String {
        switch self {
        case .running: "为陛下批阅中"
        case .succeeded: "请陛下查验"
        case .failed: "请陛下御览"
        case .needsAction(.permission): "请陛下用印"
        case .needsAction(.decision): "候陛下定夺"
        case .needsAction(.manualCheck): "待陛下御览"
        }
    }
}
