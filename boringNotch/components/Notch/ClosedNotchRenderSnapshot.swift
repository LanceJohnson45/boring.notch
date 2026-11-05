import AppKit
import SwiftUI

struct ClosedNotchBatteryRenderData {
    let statusTextKey: String
    let level: Float
    let isCharging: Bool
    let isInLowPowerMode: Bool
    let isPluggedIn: Bool
    let maxAdapterWatts: Int

    var leadingWidth: CGFloat {
        let localizedStatus = NSLocalizedString(statusTextKey, comment: "")
        let font = NSFont.preferredFont(forTextStyle: .subheadline)
        return ceil((localizedStatus as NSString).size(withAttributes: [.font: font]).width)
    }
}

struct ClosedNotchRenderData {
    let music: ClosedNotchMusicRenderData
    let battery: ClosedNotchBatteryRenderData
    let osd: Binding<sneakPeek>
    let pomodoro: ClosedNotchPomodoroRenderData
}

struct ClosedNotchPomodoroRenderData {
    let icon: String
    let secondsRemaining: Int
    let totalSeconds: Int
    let isBreak: Bool
    let isRunning: Bool
    let startedAt: Date
}

struct ClosedNotchSnapshotContext {
    let closedNotchWidth: CGFloat
    let displayHeight: CGFloat
    let idleHeight: CGFloat
    let isHovering: Bool
    let gestureProgress: CGFloat
    let hideOnClosed: Bool
    let showSalaryCalculator: Bool
    let showIdleFace: Bool
    let musicLiveActivityEnabled: Bool
    let musicPlayerIdle: Bool
    let expandingViewVisible: Bool
    let expandingViewType: SneakContentType
    let sneakPeek: sneakPeek
    let sneakPeekVisible: Bool
    let cornerRadiusScalingEnabled: Bool
    let inlineOSDEnabled: Bool
    let powerStatusNotificationsEnabled: Bool
    let sneakPeekStyle: SneakPeekStyle
    let renderData: ClosedNotchRenderData
    let extensionActivities: [ClosedNotchExtensionActivity]
}

struct ClosedNotchRenderSnapshot {
    let presentation: ClosedNotchPresentationState
    let renderData: ClosedNotchRenderData
    let displayHeight: CGFloat
    let cornerRadiusScaleFactor: CGFloat?
    let albumArtWidth: CGFloat
    let spectrumWidth: CGFloat
    let extensionActivities: [String: ClosedNotchExtensionActivity]

    init(context: ClosedNotchSnapshotContext) {
        var extensionActivitiesByID: [String: ClosedNotchExtensionActivity] = [:]
        for activity in context.extensionActivities {
            guard let existing = extensionActivitiesByID[activity.id] else {
                extensionActivitiesByID[activity.id] = activity
                continue
            }
            let isNewerAtSamePriority = activity.priority == existing.priority
                && activity.updatedAt > existing.updatedAt
            if activity.priority > existing.priority || isNewerAtSamePriority {
                extensionActivitiesByID[activity.id] = activity
            }
        }
        let extensionActivities = Array(extensionActivitiesByID.values)
        let idleExtensionActivities = extensionActivities.filter(\.isIdleWidget)
        let regularExtensionActivities = extensionActivities.filter { !$0.isIdleWidget }

        let cornerScale: CGFloat? = context.cornerRadiusScalingEnabled
            && context.displayHeight > 0
            ? context.displayHeight / 38
            : nil
        let albumArtWidth = max(0, context.displayHeight - 12 * (cornerScale ?? 1))
        let spectrumWidth = max(0, context.displayHeight - 12 + context.gestureProgress / 2)
        let musicExpanded = context.expandingViewVisible
            && context.expandingViewType == .music
            && context.sneakPeekStyle == .inline
        let batteryNotificationVisible = context.expandingViewType == .battery
            && context.expandingViewVisible
            && context.powerStatusNotificationsEnabled
        let inlineOSDVisible = context.sneakPeekVisible
            && context.inlineOSDEnabled
            && context.sneakPeek.type != .music
            && context.sneakPeek.type != .battery
        let musicVisible = (!context.expandingViewVisible
            || context.expandingViewType == .music)
            && (context.renderData.music.isPlaying || !context.musicPlayerIdle)
            && context.musicLiveActivityEnabled
            && !context.hideOnClosed
        let salaryCalculatorVisible = !context.expandingViewVisible
            && context.showSalaryCalculator
            && !context.hideOnClosed
        let pomodoroVisible = !context.expandingViewVisible
            && context.renderData.pomodoro.isRunning
            && !context.hideOnClosed
        let idleFaceVisible = !context.expandingViewVisible
            && !context.renderData.music.isPlaying
            && context.musicPlayerIdle
            && context.showIdleFace
            && !context.hideOnClosed
        let idleWidgets = Self.idleWidgets(
            salaryCalculatorVisible: salaryCalculatorVisible,
            pomodoroVisible: pomodoroVisible,
            pomodoroStartedAt: context.renderData.pomodoro.startedAt,
            extensionActivities: idleExtensionActivities
        )
        let idleWidgetsWidth = Self.idleWidgetsWidth(
            idleWidgets.map(\.widget),
            closedNotchWidth: context.closedNotchWidth,
            extensionActivities: extensionActivitiesByID
        )

        let supplemental: ClosedNotchSupplementalPresentation?
        if context.sneakPeekVisible,
           context.sneakPeek.type != .music,
           context.sneakPeek.type != .battery,
           !context.inlineOSDEnabled {
            supplemental = .systemOSD
        } else if context.sneakPeekVisible,
                  context.sneakPeek.type == .music,
                  !context.hideOnClosed,
                  context.sneakPeekStyle == .standard {
            supplemental = .music
        } else {
            supplemental = nil
        }

        let presentationInput = ClosedNotchPresentationInput(
            closedNotchWidth: context.closedNotchWidth,
            height: context.displayHeight,
            idleHeight: context.idleHeight,
            inlineOSDHeight: context.displayHeight + (context.isHovering ? 8 : 0),
            inlineSideWidth: max(
                0,
                100 - (context.isHovering ? 0 : 12) + context.gestureProgress / 2
            ),
            albumArtWidth: albumArtWidth,
            spectrumWidth: spectrumWidth,
            expandedMusicCenterWidth: 380,
            idleFaceTrailingWidth: 20 + 30 * min(1, context.displayHeight / 30),
            batteryLeadingWidth: batteryNotificationVisible
                ? context.renderData.battery.leadingWidth
                : 0,
            idleWidgets: idleWidgets.map(\.widget),
            idleWidgetsWidth: idleWidgetsWidth,
            candidates: [
                .init(.batteryNotification, isVisible: batteryNotificationVisible),
                .init(.inlineOSD, isVisible: inlineOSDVisible),
                .init(.music, isVisible: musicVisible),
                .init(.idleWidgets, isVisible: !idleWidgets.isEmpty),
                .init(.idleFace, isVisible: idleWidgets.isEmpty && idleFaceVisible),
                .init(.idle, isVisible: true)
            ] + regularExtensionActivities.map { activity in
                .init(
                    .extensionActivity(activity.id),
                    isVisible: true,
                    priority: activity.priority,
                    updatedAt: activity.updatedAt,
                    metrics: activity.metrics
                )
            },
            musicExpanded: musicExpanded,
            supplemental: supplemental
        )

        presentation = ClosedNotchPresentationResolver.resolve(presentationInput)
        renderData = context.renderData
        displayHeight = context.displayHeight
        cornerRadiusScaleFactor = cornerScale
        self.albumArtWidth = albumArtWidth
        self.spectrumWidth = spectrumWidth
        self.extensionActivities = extensionActivitiesByID
    }

    private static func idleWidgets(
        salaryCalculatorVisible: Bool,
        pomodoroVisible: Bool,
        pomodoroStartedAt: Date,
        extensionActivities: [ClosedNotchExtensionActivity]
    ) -> [(widget: ClosedNotchIdleWidget, updatedAt: Date)] {
        var widgets: [(widget: ClosedNotchIdleWidget, updatedAt: Date, order: Int)] = []
        var order = 0

        if salaryCalculatorVisible {
            widgets.append((.salaryCalculator, .distantPast, order))
            order += 1
        }

        for activity in extensionActivities.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            widgets.append((.extensionActivity(activity.id), activity.updatedAt, order))
            order += 1
        }

        if pomodoroVisible {
            widgets.append((.pomodoroTimer, pomodoroStartedAt, order))
        }

        return widgets
            .sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt < $1.updatedAt
                }
                return $0.order < $1.order
            }
            .map { (widget: $0.widget, updatedAt: $0.updatedAt) }
    }

    private static func idleWidgetsWidth(
        _ widgets: [ClosedNotchIdleWidget],
        closedNotchWidth: CGFloat,
        extensionActivities: [String: ClosedNotchExtensionActivity]
    ) -> CGFloat {
        guard !widgets.isEmpty else { return closedNotchWidth }

        let contentWidth = widgets.reduce(CGFloat.zero) { width, widget in
            width + idleWidgetWidth(widget, extensionActivities: extensionActivities)
        }
        let spacing = CGFloat(max(0, widgets.count - 1)) * 4
        let horizontalPadding: CGFloat = 12

        return max(closedNotchWidth, contentWidth + spacing + horizontalPadding)
    }

    private static func idleWidgetWidth(
        _ widget: ClosedNotchIdleWidget,
        extensionActivities: [String: ClosedNotchExtensionActivity]
    ) -> CGFloat {
        switch widget {
        case .salaryCalculator:
            return 76
        case .pomodoroTimer:
            return 88
        case .extensionActivity(let id):
            return max(20, extensionActivities[id]?.metrics.totalWidth ?? 22)
        }
    }

    var topCornerRadius: CGFloat {
        let baseRadius = cornerRadiusInsets.closed.top
        guard let cornerRadiusScaleFactor else {
            return displayHeight > 0 ? baseRadius : 0
        }
        return max(0, baseRadius * cornerRadiusScaleFactor)
    }

    var opensNotchOnHover: Bool? {
        guard case .extensionActivity(let id) = presentation.primary,
              let activity = extensionActivities[id] else {
            return nil
        }
        return activity.opensNotchOnHover ? true : nil
    }

    var opensNotchOnTap: Bool {
        guard case .extensionActivity(let id) = presentation.primary,
              let activity = extensionActivities[id] else {
            return true
        }
        return activity.opensNotchOnTap
    }

    var notchShape: NotchShape {
        let baseBottomRadius = cornerRadiusInsets.closed.bottom
        let bottomRadius: CGFloat

        if let cornerRadiusScaleFactor {
            bottomRadius = max(0, baseBottomRadius * cornerRadiusScaleFactor)
        } else {
            bottomRadius = displayHeight > 0 ? baseBottomRadius : 0
        }

        return NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomRadius
        )
    }
}
