import Combine
import Defaults
import SwiftUI

@MainActor
enum CodexNotificationExtension {
    static let activityID = "codex.notification"

    static let descriptor = NotchExtensionDescriptor(
        id: "codex.notifications",
        updates: CodexNotificationManager.shared.objectWillChange
            .map { _ in () }
            .eraseToAnyPublisher(),
        start: { CodexNotificationManager.shared.start() },
        stop: { CodexNotificationManager.shared.stop() },
        closedActivities: { context in
            if let notification = CodexNotificationManager.shared.presentedNotification {
                return [notificationActivity(notification: notification, context: context)]
            }

            return CodexNotificationManager.shared.runningAgentTasks.map {
                agentIdleActivity(task: $0, context: context)
            }
        }
    )

    private static func notificationActivity(
        notification: CodexJobNotification,
        context: ClosedNotchExtensionContext
    ) -> ClosedNotchExtensionActivity {
        let height = max(32, context.displayHeight)
        let notchWidth = context.closedNotchWidth + 10
        let launchError = CodexNotificationManager.shared.compactLaunchError(for: notification)
        let promptWidth = notificationPromptWidth(
            notification: notification,
            launchError: launchError
        )
        let isPermissionRequest = notification.status == .needsAction(.permission)
        let tapRouting = CodexClosedActivityTapRouting(status: notification.status)
        let canOpenCodex = !notification.sessionID.hasPrefix("opencode:")
            && !notification.sessionID.hasPrefix("zcode:")
        let metrics = ClosedNotchLayoutMetrics(
            exclusionWidth: notchWidth,
            leadingWidth: 0,
            trailingWidth: promptWidth,
            leadingExclusionMargin: 0,
            trailingExclusionMargin: 0,
            horizontalChromeInset: cornerRadiusInsets.closed.bottom,
            height: height
        )

        return ClosedNotchExtensionActivity(
            id: activityID,
            priority: notification.status.notchPriority,
            updatedAt: notification.createdAt,
            metrics: metrics,
            content: AnyView(CodexClosedNotchPrompt(
                notification: notification,
                presentationSurfaceID: context.surfaceID,
                metrics: metrics
            )),
            opensNotchOnHover: isPermissionRequest,
            opensNotchOnTap: tapRouting == .expandNotch,
            onSelect: tapRouting == .openCodex && canOpenCodex ? {
                CodexNotificationManager.shared.selectCompactActivity(
                    for: notification
                )
            } : nil
        )
    }

    private static func notificationPromptWidth(
        notification: CodexJobNotification,
        launchError: String?
    ) -> CGFloat {
        let provider = AgentTaskProvider.provider(for: notification.sessionID)
        let title = imperialTitle(for: notification.chatTitle)
        let summary: String
        if let launchError {
            summary = "启奏陛下，\(launchError) · Click to retry"
        } else {
            summary = "\(notification.status.imperialSummary(for: provider)) · \(notification.projectName)"
        }

        let textWidth = max(
            estimatedTextWidth(title, fontSize: 11, weight: 0.62),
            estimatedTextWidth(summary, fontSize: 9, weight: 0.58)
        )
        let iconAndPadding: CGFloat = 78
        return min(420, max(236, ceil(textWidth + iconAndPadding)))
    }

    private static func imperialTitle(for rawTitle: String) -> String {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.hasPrefix("陛下") else { return title }
        return "陛下 · \(title)"
    }

    private static func estimatedTextWidth(
        _ text: String,
        fontSize: CGFloat,
        weight: CGFloat
    ) -> CGFloat {
        text.reduce(CGFloat.zero) { width, character in
            if character.isWhitespace {
                return width + fontSize * 0.35
            }
            if character.isASCII {
                return width + fontSize * weight
            }
            return width + fontSize
        }
    }

    private static func agentIdleActivity(
        task: AgentTaskRecord,
        context: ClosedNotchExtensionContext
    ) -> ClosedNotchExtensionActivity {
        let spriteWidth = task.provider == .codex || task.provider == .zCode
            ? max(34, min(46, context.displayHeight + 14))
            : max(22, min(34, context.displayHeight + 4))
        let metrics = ClosedNotchLayoutMetrics(
            exclusionWidth: spriteWidth,
            leadingWidth: 0,
            trailingWidth: 0,
            leadingExclusionMargin: 0,
            trailingExclusionMargin: 0,
            horizontalChromeInset: cornerRadiusInsets.closed.bottom,
            height: context.displayHeight
        )

        return ClosedNotchExtensionActivity(
            id: "\(activityID).idle.\(task.id)",
            priority: Defaults[.agentIdlePriority].closedNotchPriority,
            updatedAt: task.updatedAt,
            metrics: metrics,
            isIdleWidget: true,
            content: AnyView(AgentClosedIdleStatus(
                task: task,
                metrics: metrics
            )),
            opensNotchOnHover: false,
            opensNotchOnTap: true,
            onSelect: nil
        )
    }
}

private extension AgentIdlePriority {
    var closedNotchPriority: ClosedNotchPresentationPriority {
        switch self {
        case .low: .ambient
        case .normal: .activity
        case .high: .system
        }
    }
}

private extension CodexJobStatus {
    var notchIconAssetName: String? {
        if case .needsAction(.permission) = self {
            return "codexPermissionShield"
        }
        return nil
    }

    var notchPriority: ClosedNotchPresentationPriority {
        switch self {
        case .needsAction(.permission), .needsAction(.decision), .failed:
            .critical
        case .needsAction(.manualCheck), .running:
            .system
        case .succeeded:
            .activity
        }
    }

    var tint: Color {
        switch self {
        case .needsAction(.permission): .orange
        case .needsAction(.decision): .purple
        case .needsAction(.manualCheck): .blue
        case .running: .cyan
        case .failed: .red
        case .succeeded: .green
        }
    }

    var pulses: Bool {
        switch self {
        case .needsAction, .running: true
        case .failed, .succeeded: false
        }
    }
}

private struct CodexNotificationStatusIcon: View {
    let status: CodexJobStatus

    @State private var pulsing = false

    @ViewBuilder
    private var iconView: some View {
        if let assetName = status.notchIconAssetName {
            Image(assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(status.tint)
        } else {
            Image(systemName: status.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(status.tint)
        }
    }

    var body: some View {
        ZStack {
            if status.pulses {
                Circle()
                    .fill(status.tint.opacity(0.28))
                    .frame(width: 27, height: 27)
                    .scaleEffect(pulsing ? 1.15 : 0.82)
                    .opacity(pulsing ? 0.15 : 0.8)
                    .accessibilityHidden(true)
            }
            iconView
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onAppear {
            guard status.pulses else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

private struct CodexClosedNotchPrompt: View {
    let notification: CodexJobNotification
    let presentationSurfaceID: String
    let metrics: ClosedNotchLayoutMetrics

    @ObservedObject private var manager = CodexNotificationManager.shared

    private var isPermissionRequest: Bool {
        notification.status == .needsAction(.permission)
    }

    private var canOpenCodex: Bool {
        !notification.sessionID.hasPrefix("opencode:")
            && !notification.sessionID.hasPrefix("zcode:")
    }

    private var launchError: String? {
        manager.compactLaunchError(for: notification)
    }

    private var accessibility: CodexClosedActivityAccessibility {
        CodexClosedActivityAccessibility(
            status: notification.status,
            projectName: notification.projectName,
            launchError: launchError,
            canOpenCodex: canOpenCodex
        )
    }

    var body: some View {
        promptContainer
            .id("\(notification.id):\(notification.createdAt.timeIntervalSinceReferenceDate)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(notification.jobTitle)
            .accessibilityValue(accessibility.value)
            .accessibilityHint(accessibility.hint)
            .onAppear {
                CodexNotificationManager.shared.beginPassivePresentation(
                    for: notification,
                    surfaceID: presentationSurfaceID
                )
            }
            .onDisappear {
                CodexNotificationManager.shared.endPassivePresentation(
                    for: notification,
                    surfaceID: presentationSurfaceID
                )
            }
    }

    private var promptContainer: some View {
        ZStack {
            Color.clear
                .frame(width: metrics.totalWidth, height: metrics.height)
                .accessibilityHidden(true)

            prompt
                .frame(
                    width: metrics.trailingWidth,
                    height: metrics.height,
                    alignment: .center
                )
        }
        .frame(width: metrics.totalWidth, height: metrics.height, alignment: .center)
        .contentShape(Rectangle())
        .onHover { isHovered in
            CodexNotificationManager.shared.setPassivePresentationHovered(
                isHovered,
                for: notification,
                surfaceID: presentationSurfaceID
            )
        }
    }

    private var prompt: some View {
        HStack(spacing: 8) {
            CodexNotificationStatusIcon(status: notification.status)
                .frame(width: 20, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .center, spacing: 1) {
                Text(imperialTitle)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)

                Text(summary)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(notification.status.tint.opacity(0.95))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Color.clear
                .frame(width: 20, height: 28)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var summary: String {
        if let launchError {
            return "启奏陛下，\(launchError) · Click to retry"
        }
        let provider = AgentTaskProvider.provider(for: notification.sessionID)
        return "\(notification.status.imperialSummary(for: provider)) · \(notification.projectName)"
    }

    private var imperialTitle: String {
        let title = notification.chatTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.hasPrefix("陛下") else { return title }
        return "陛下 · \(title)"
    }
}

private struct AgentClosedIdleStatus: View {
    let task: AgentTaskRecord
    let metrics: ClosedNotchLayoutMetrics

    var body: some View {
        Group {
            if task.provider == .codex {
                AgentAssetRunner(
                    assetPrefix: "codexAgentHero",
                    frameCount: 15,
                    direction: .right
                )
            } else if task.provider == .zCode {
                AgentAssetRunner(
                    assetPrefix: "zcodeAgentHero",
                    frameCount: 32,
                    direction: .right
                )
            } else {
                AgentPixelRunner(style: providerHeroStyle, direction: .right)
            }
        }
        .frame(width: metrics.totalWidth, height: metrics.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(task.provider.imperialDisplayName) is working")
        .accessibilityValue("\(task.status.imperialSummary(for: task.provider)). \(task.title)")
    }

    private var providerHeroStyle: AgentPixelHeroStyle {
        switch task.provider {
        case .codex: .techKnight
        case .openCode: .greenRogue
        case .zCode: .solarRunner
        }
    }
}

private struct AgentAssetRunner: View {
    let assetPrefix: String
    let frameCount: Int
    let direction: AgentPixelDirection

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { timeline in
            let frameIndex = Int(timeline.date.timeIntervalSinceReferenceDate * 8.0)
                % max(1, frameCount)
            Image("\(assetPrefix)\(frameIndex)")
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .scaleEffect(x: direction == .left ? -1 : 1, y: 1)
                .padding(.vertical, 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .shadow(color: Color(red: 0.9, green: 0.16, blue: 0.16).opacity(0.55), radius: 2, y: 1)
        .accessibilityHidden(true)
    }
}

private enum AgentPixelHeroStyle {
    case techKnight
    case greenRogue
    case solarRunner

    var main: Color {
        switch self {
        case .techKnight: Color(red: 0.12, green: 0.76, blue: 0.96)
        case .greenRogue: Color(red: 0.16, green: 0.76, blue: 0.28)
        case .solarRunner: Color(red: 0.95, green: 0.18, blue: 0.12)
        }
    }

    var secondary: Color {
        switch self {
        case .techKnight: Color(red: 0.16, green: 0.28, blue: 0.85)
        case .greenRogue: Color(red: 0.54, green: 0.18, blue: 0.78)
        case .solarRunner: Color(red: 1.0, green: 0.82, blue: 0.08)
        }
    }

    var accent: Color {
        switch self {
        case .techKnight: Color(red: 0.82, green: 0.98, blue: 1.0)
        case .greenRogue: Color(red: 0.76, green: 0.96, blue: 0.48)
        case .solarRunner: Color(red: 1.0, green: 0.54, blue: 0.08)
        }
    }

    var glow: Color {
        switch self {
        case .techKnight: .cyan
        case .greenRogue: .green
        case .solarRunner: .orange
        }
    }
}

private enum AgentPixelDirection {
    case left
    case right
}

private struct AgentPixelRunner: View {
    let style: AgentPixelHeroStyle
    let direction: AgentPixelDirection

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.18)) { timeline in
            let frameIndex = Int(timeline.date.timeIntervalSinceReferenceDate * 5.5)
                % Self.frames.count
            PixelSprite(rows: Self.frames[frameIndex], style: style)
                .scaleEffect(x: direction == .left ? -1 : 1, y: 1)
                .offset(y: frameIndex == 1 ? -1 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityHidden(true)
    }

    private static let frames = [
        [
            "....KKKK....",
            "...KMMMMK...",
            "..KMEEMMK...",
            "..KMMMMKK...",
            "..KSSMMK....",
            ".KKMMMMKK...",
            "KAMMSSMMAK..",
            "..KMMMMK....",
            ".KMMKKMMK...",
            ".KMK..KMK...",
            "KSK....KSK..",
            "AA......AA.."
        ],
        [
            "....KKKK....",
            "...KMMMMK...",
            "..KMEEMMK...",
            "..KMMMMKK...",
            "..KSSMMK....",
            ".KKMMMMKK...",
            "AAMMSSMMK...",
            "..KMMMMK....",
            ".KMMKKMMK...",
            "..KMK.KMK...",
            ".KSK..KSK...",
            "AA....AA...."
        ],
        [
            "....KKKK....",
            "...KMMMMK...",
            "..KMEEMMK...",
            "..KMMMMKK...",
            "..KSSMMK....",
            ".KKMMMMKK...",
            "..KMMSSMMAK.",
            "..KMMMMK....",
            ".KMMKKMMK...",
            ".KMK.KMK....",
            "KSK..KSK....",
            ".AA....AA..."
        ]
    ]
}

private struct PixelSprite: View {
    let rows: [String]
    let style: AgentPixelHeroStyle

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, pixel in
                        Rectangle()
                            .fill(color(for: pixel))
                            .frame(width: 1.75, height: 1.75)
                    }
                }
            }
        }
        .shadow(color: style.glow.opacity(0.55), radius: 2, y: 1)
    }

    private func color(for pixel: Character) -> Color {
        switch pixel {
        case "K": Color.black
        case "M": style.main
        case "S": style.secondary
        case "A": style.accent
        case "E": Color.white
        default: .clear
        }
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
    func imperialSummary(for provider: AgentTaskProvider) -> String {
        switch self {
        case .running:
            return "启奏陛下，\(provider.imperialDisplayName)正在为陛下批阅"
        case .succeeded:
            return "启奏陛下，\(provider.imperialDisplayName)折子已毕，请陛下查验"
        case .failed:
            return "启奏陛下，\(provider.imperialDisplayName)折子遇阻，请陛下御览"
        case .needsAction(.permission):
            return "启奏陛下，\(provider.imperialDisplayName)请求陛下用印"
        case .needsAction(.decision):
            return "启奏陛下，\(provider.imperialDisplayName)候陛下定夺"
        case .needsAction(.manualCheck):
            return "启奏陛下，\(provider.imperialDisplayName)请陛下御览"
        }
    }
}

struct CodexPermissionApprovalView: View {
    private static let disclosureCharacterLimit = 140
    private static let viewportHeight = max(0, openNotchSize.height - 12)

    let notification: CodexJobNotification

    @ObservedObject private var manager = CodexNotificationManager.shared
    @State private var isPromptExpanded = false
    @State private var isCommandExpanded = false

    private var isSubmitting: Bool {
        manager.submittingNotificationIDs.contains(notification.id)
    }

    private var details: CodexPermissionDetails {
        notification.permissionDetails
            ?? CodexPermissionDetails(toolName: "Codex")
    }

    private var normalizedToolName: String {
        details.toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var toolDisplayName: String {
        switch normalizedToolName {
        case "bash": "Terminal"
        case "apply_patch": "File changes"
        default: details.toolName
        }
    }

    private var requestDescription: String {
        details.description
            ?? "Codex is requesting permission to use \(toolDisplayName)."
    }

    private var canRespondInNotch: Bool {
        notification.permissionCallback?.isActive() == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            permissionHeader

            permissionDetails
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let error = manager.lastError {
                Text(error)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            permissionActions
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Self.viewportHeight, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex permission request")
    }

    private var permissionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: toolIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(toolDisplayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

        }
    }

    private var permissionDetails: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
                expandablePrompt

                Text(requestDescription)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.94))
                    .fixedSize(horizontal: false, vertical: true)

                if details.command != nil || details.additionalInput != nil {
                    VStack(alignment: .leading, spacing: 5) {
                        if let command = details.command {
                            expandableDetailSection(
                                title: commandDetailTitle,
                                value: command
                            )
                        }
                        if let additionalInput = details.additionalInput {
                            detailSection(title: "Request input", value: additionalInput)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Permission request details")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var permissionActions: some View {
        HStack(spacing: 8) {
            if canRespondInNotch {
                Button("Deny") {
                    submit(.deny)
                }
                .buttonStyle(CodexPermissionButtonStyle(tint: .white.opacity(0.16)))
                .disabled(isSubmitting)
                .accessibilityLabel("Deny Codex permission")

                Button("Allow") {
                    submit(.allow)
                }
                .buttonStyle(CodexPermissionButtonStyle(tint: .green.opacity(0.9)))
                .disabled(isSubmitting)
                .accessibilityLabel("Allow Codex permission")
            }

            Spacer()

            if isSubmitting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Sending decision to Codex")
            }

            Button("Review in Codex") {
                reviewInCodex()
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.blue)
            .buttonStyle(.plain)
            .disabled(isSubmitting)
            .accessibilityLabel("Review this permission in Codex")
        }
    }

    private func reviewInCodex() {
        if canRespondInNotch {
            submit(.reviewInCodex)
        } else {
            Task {
                await manager.openCodex(for: notification)
            }
        }
    }

    private func submit(_ decision: CodexPermissionDecision) {
        Task {
            await manager.submitPermissionDecision(decision, for: notification)
        }
    }

    private var toolIcon: String {
        switch normalizedToolName {
        case "bash": "terminal"
        case "browser": "globe"
        case "apply_patch": "doc.badge.plus"
        default: "lock.shield"
        }
    }

    private var commandDetailTitle: String {
        switch normalizedToolName {
        case "bash": "Command"
        case "apply_patch": "Files"
        default: "Tool input"
        }
    }

    private var expandablePrompt: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(notification.userPrompt)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(promptNeedsDisclosure && !isPromptExpanded ? 2 : nil)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)

            if promptNeedsDisclosure {
                Button(isPromptExpanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isPromptExpanded.toggle()
                    }
                }
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
                .accessibilityLabel(isPromptExpanded ? "Show less user prompt" : "Show full user prompt")
            }
        }
    }

    private var promptNeedsDisclosure: Bool {
        notification.userPrompt.count > Self.disclosureCharacterLimit
    }

    private func expandableDetailSection(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(commandNeedsDisclosure(value) && !isCommandExpanded ? 2 : nil)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if commandNeedsDisclosure(value) {
                Button(isCommandExpanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isCommandExpanded.toggle()
                    }
                }
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
                .accessibilityLabel(isCommandExpanded ? "Show less command" : "Show full command")
            }
        }
    }

    private func commandNeedsDisclosure(_ command: String) -> Bool {
        command.count > Self.disclosureCharacterLimit
    }

    private func detailSection(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct CodexPermissionButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(
                Capsule()
                    .fill(tint.opacity(configuration.isPressed ? 0.72 : 1))
            )
            .contentShape(Capsule())
    }
}
