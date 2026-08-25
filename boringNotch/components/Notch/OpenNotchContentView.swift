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
                    Text(task.provider.displayName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(statusColor)
                    Text(task.status.title)
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
