//
//  SettingsView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import AppKit
import Defaults
import Sparkle
import SwiftUI
import SwiftUIIntrospect

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case media
    case calendar
    case osd
    case battery
    case shelf
    case mirror
    case shortcuts
    case workday
    case codex
    case advanced
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .media: "Media"
        case .calendar: "Calendar"
        case .osd: "OSD"
        case .battery: "Battery"
        case .shelf: "Shelf"
        case .mirror: "Mirror"
        case .shortcuts: "Shortcuts"
        case .workday: "Workday"
        case .codex: "Codex"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gear"
        case .appearance: "eye"
        case .media: "play.laptopcomputer"
        case .calendar: "calendar"
        case .osd: "dial.medium.fill"
        case .battery: "battery.100.bolt"
        case .shelf: "books.vertical"
        case .mirror: "camera"
        case .shortcuts: "keyboard"
        case .workday: "timer"
        case .codex: "bell.badge"
        case .advanced: "gearshape.2"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general
    @State private var accentColorUpdateTrigger = UUID()

    let updaterController: SPUStandardUpdaterController?

    init(updaterController: SPUStandardUpdaterController? = nil) {
        self.updaterController = updaterController
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Group {
                        if tab == .codex {
                            Label {
                                Text(tab.title)
                            } icon: {
                                CodexAppIcon()
                            }
                        } else {
                            Label(tab.title, systemImage: tab.systemImage)
                        }
                    }
                    .tag(tab)
                }
            }
            .listStyle(SidebarListStyle())
            .tint(.effectiveAccent)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(200)
        } detail: {
            Group {
                switch selectedTab {
                case .general:
                    GeneralSettings()
                case .appearance:
                    Appearance()
                case .media:
                    Media()
                case .calendar:
                    CalendarSettings()
                case .osd:
                    OSDSettings()
                case .battery:
                    Charge()
                case .shelf:
                    Shelf()
                case .mirror:
                    MirrorSettings()
                case .shortcuts:
                    Shortcuts()
                case .workday:
                    WorkdaySettings()
                case .codex:
                    CodexNotificationSettings()
                case .advanced:
                    Advanced()
                case .about:
                    if let controller = updaterController {
                        About(updaterController: controller)
                    } else {
                        // Fallback with a default controller
                        About(
                            updaterController: SPUStandardUpdaterController(
                                startingUpdater: false, updaterDelegate: nil,
                                userDriverDelegate: nil))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("")
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 700)
        .background(Color(NSColor.windowBackgroundColor))
        .tint(.effectiveAccent)
        .id(accentColorUpdateTrigger)
        .onReceive(NotificationCenter.default.publisher(for: .accentColorChanged)) { _ in
            accentColorUpdateTrigger = UUID()
        }
    }
}

private struct CodexAppIcon: View {
    var body: some View {
        Image("codexIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 14, height: 14)
            .frame(width: 16, height: 16)
            .offset(x: -1)
            .accessibilityHidden(true)
    }
}

private struct WorkdaySettings: View {
    @Default(.salaryCalculatorEnabled) private var salaryCalculatorEnabled
    @Default(.monthlySalary) private var monthlySalary
    @Default(.monthlyWorkdays) private var monthlyWorkdays
    @Default(.workdayStartMinute) private var workdayStartMinute
    @Default(.workdayEndMinute) private var workdayEndMinute
    @Default(.pomodoroFocusMinutes) private var pomodoroFocusMinutes
    @Default(.pomodoroShortBreakMinutes) private var pomodoroShortBreakMinutes
    @Default(.pomodoroLongBreakMinutes) private var pomodoroLongBreakMinutes
    @Default(.pomodoroDailyTarget) private var pomodoroDailyTarget

    var body: some View {
        Form {
            Section {
                Toggle("Idle salary calculator", isOn: $salaryCalculatorEnabled)
                    .tint(.effectiveAccent)

                TextField("Monthly salary", value: $monthlySalary, format: .number.precision(.fractionLength(2)))

                Stepper(value: $monthlyWorkdays, in: 1...31, step: 0.5) {
                    LabeledContent("Workdays per month") {
                        Text(monthlyWorkdays, format: .number.precision(.fractionLength(1)))
                    }
                }

                DatePicker(
                    "Clock in",
                    selection: workdayTimeBinding(for: $workdayStartMinute),
                    displayedComponents: .hourAndMinute
                )

                DatePicker(
                    "Clock out",
                    selection: workdayTimeBinding(for: $workdayEndMinute),
                    displayedComponents: .hourAndMinute
                )

                LabeledContent("Daily salary") {
                    Text(currencyString(dailySalary))
                        .monospacedDigit()
                }
            } header: {
                Text("薪水计算器")
            } footer: {
                Text("Idle 状态会按上下班时间每秒刷新今日已赚薪水。")
            }

            Section {
                Stepper(value: $pomodoroFocusMinutes, in: 1...180) {
                    LabeledContent("Focus duration") {
                        Text("\(pomodoroFocusMinutes) min")
                    }
                }
                .onChange(of: pomodoroFocusMinutes) {
                    PomodoroManager.shared.applySettingsIfIdle()
                    flushUserDefaults()
                }

                Stepper(value: $pomodoroShortBreakMinutes, in: 1...60) {
                    LabeledContent("Short break") {
                        Text("\(pomodoroShortBreakMinutes) min")
                    }
                }
                .onChange(of: pomodoroShortBreakMinutes) {
                    PomodoroManager.shared.applySettingsIfIdle()
                    flushUserDefaults()
                }

                Stepper(value: $pomodoroLongBreakMinutes, in: 1...120) {
                    LabeledContent("Long break") {
                        Text("\(pomodoroLongBreakMinutes) min")
                    }
                }
                .onChange(of: pomodoroLongBreakMinutes) {
                    PomodoroManager.shared.applySettingsIfIdle()
                    flushUserDefaults()
                }

                Stepper(value: $pomodoroDailyTarget, in: 1...24) {
                    LabeledContent("Daily pomodoros") {
                        Text("\(pomodoroDailyTarget)")
                    }
                }
            } header: {
                Text("Pomodoro")
            } footer: {
                Text("状态变化时 Notch 会展开，请手动确认休息或继续专注。")
            }
        }
        .formStyle(.grouped)
        .accentColor(.effectiveAccent)
        .navigationTitle("Workday")
        .onChange(of: salaryCalculatorEnabled) { flushUserDefaults() }
        .onChange(of: monthlySalary) { flushUserDefaults() }
        .onChange(of: monthlyWorkdays) { flushUserDefaults() }
        .onChange(of: workdayStartMinute) { flushUserDefaults() }
        .onChange(of: workdayEndMinute) { flushUserDefaults() }
        .onChange(of: pomodoroDailyTarget) { flushUserDefaults() }
        .onDisappear(perform: flushUserDefaults)
    }

    private var dailySalary: Double {
        guard monthlySalary > 0, monthlyWorkdays > 0 else { return 0 }
        return monthlySalary / monthlyWorkdays
    }

    private func workdayTimeBinding(for minutes: Binding<Int>) -> Binding<Date> {
        Binding<Date>(
            get: {
                date(fromMinutes: minutes.wrappedValue)
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                minutes.wrappedValue = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }

    private func date(fromMinutes minutes: Int) -> Date {
        Calendar.current.date(
            bySettingHour: minutes / 60,
            minute: minutes % 60,
            second: 0,
            of: Date()
        ) ?? Date()
    }

    private func flushUserDefaults() {
        UserDefaults.standard.synchronize()
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
