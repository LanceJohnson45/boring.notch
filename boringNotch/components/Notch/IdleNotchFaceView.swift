import Defaults
import SwiftUI

struct IdleNotchFaceView: View {
    let displayClosedNotchHeight: CGFloat

    var body: some View {
        let faceScale = min(1, displayClosedNotchHeight / 30)

        MinimalFaceFeatures(
            height: 24 * faceScale,
            width: 30 * faceScale
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 20)
    }
}

struct SalaryIdleCounterView: View {
    let metrics: ClosedNotchLayoutMetrics

    @Default(.salaryCalculatorEnabled) private var isEnabled
    @Default(.monthlySalary) private var monthlySalary
    @Default(.monthlyWorkdays) private var monthlyWorkdays
    @Default(.workdayStartMinute) private var workdayStartMinute
    @Default(.workdayEndMinute) private var workdayEndMinute

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            content(at: timeline.date)
        }
        .frame(width: metrics.totalWidth, height: metrics.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("薪水计数器")
        .accessibilityValue(accessibilityValue(at: Date()))
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        if isEnabled {
            Text(counterText(at: date))
                .font(.system(size: valueSize, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.green.opacity(0.96))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .padding(.horizontal, 6)
                .frame(width: metrics.totalWidth, height: metrics.height, alignment: .center)
        } else {
            Color.clear
                .frame(width: metrics.totalWidth, height: metrics.height)
        }
    }

    private var valueSize: CGFloat { max(10, min(15, metrics.height * 0.48)) }

    private var dailySalary: Double {
        guard monthlySalary > 0, monthlyWorkdays > 0 else { return 0 }
        return monthlySalary / monthlyWorkdays
    }

    private var workdayDuration: TimeInterval {
        TimeInterval(max(1, workdayEndMinute - workdayStartMinute) * 60)
    }

    private func counterText(at date: Date) -> String {
        currencyString(monthlySalary > 0 ? earnedToday(at: date) : 0)
    }

    private func accessibilityValue(at date: Date) -> String {
        guard isEnabled else { return "未启用" }
        guard monthlySalary > 0 else { return "请在设置中填写月薪" }
        return "今日已赚 \(currencyString(earnedToday(at: date)))，每日工资 \(currencyString(dailySalary))"
    }

    private func earnedToday(at date: Date) -> Double {
        guard monthlySalary > 0 else { return 0 }
        let calendar = Calendar.current
        let start = calendar.date(
            bySettingHour: workdayStartMinute / 60,
            minute: workdayStartMinute % 60,
            second: 0,
            of: date
        ) ?? date
        let end = calendar.date(
            bySettingHour: workdayEndMinute / 60,
            minute: workdayEndMinute % 60,
            second: 0,
            of: date
        ) ?? start.addingTimeInterval(workdayDuration)

        if date <= start { return 0 }
        if date >= end { return dailySalary }
        return dailySalary * date.timeIntervalSince(start) / max(1, end.timeIntervalSince(start))
    }

    private func currencyString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = .current
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}

struct ClosedIdleWidgetsView: View {
    let metrics: ClosedNotchLayoutMetrics
    let widgets: [ClosedNotchIdleWidget]
    let renderData: ClosedNotchRenderData
    let extensionActivities: [String: ClosedNotchExtensionActivity]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(widgets.enumerated()), id: \.offset) { _, widget in
                widgetView(widget)
            }
        }
        .padding(.horizontal, 6)
        .frame(width: metrics.totalWidth, height: metrics.height, alignment: .center)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func widgetView(_ widget: ClosedNotchIdleWidget) -> some View {
        switch widget {
        case .salaryCalculator:
            SalaryIdleCounterView(metrics: itemMetrics(width: salaryWidth))
                .frame(width: salaryWidth, height: metrics.height)

        case .pomodoroTimer:
            PomodoroClosedTimerView(
                metrics: itemMetrics(width: pomodoroWidth),
                data: renderData.pomodoro
            )
            .frame(width: pomodoroWidth, height: metrics.height)

        case .extensionActivity(let id):
            if let activity = extensionActivities[id] {
                activity.content
                    .frame(
                        width: max(18, activity.metrics.totalWidth),
                        height: metrics.height
                    )
            }
        }
    }

    private var salaryWidth: CGFloat {
        76
    }

    private var pomodoroWidth: CGFloat {
        88
    }

    private func itemMetrics(width: CGFloat) -> ClosedNotchLayoutMetrics {
        .init(
            exclusionWidth: width,
            leadingWidth: 0,
            trailingWidth: 0,
            leadingExclusionMargin: 0,
            trailingExclusionMargin: 0,
            horizontalChromeInset: 0,
            height: metrics.height
        )
    }
}

struct PomodoroClosedTimerView: View {
    let metrics: ClosedNotchLayoutMetrics
    let data: ClosedNotchPomodoroRenderData

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: data.icon)
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(timeString(data.secondsRemaining))
                .font(.system(size: valueSize, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 6)
        .frame(width: metrics.totalWidth, height: metrics.height, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(data.isBreak ? "休息倒计时" : "番茄钟倒计时")
        .accessibilityValue(timeString(data.secondsRemaining))
    }

    private var iconSize: CGFloat { max(10, min(14, metrics.height * 0.42)) }
    private var valueSize: CGFloat { max(10, min(14, metrics.height * 0.46)) }

    private var remainingRatio: Double {
        guard data.totalSeconds > 0 else { return 0 }
        return Double(max(0, data.secondsRemaining)) / Double(data.totalSeconds)
    }

    private var tint: Color {
        if data.isBreak {
            if remainingRatio < 0.2 { return .yellow }
            if remainingRatio < 0.5 { return .mint }
            return .green
        }

        if remainingRatio < 0.2 { return .red }
        if remainingRatio < 0.5 { return .orange }
        return .pink
    }

    private func timeString(_ seconds: Int) -> String {
        String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }
}
