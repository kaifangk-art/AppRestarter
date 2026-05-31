import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedAppIDs = Set<ManagedApp.ID>()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            appList
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 38))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.teal)

            VStack(alignment: .leading, spacing: 4) {
                Text("App Restarter")
                    .font(.system(size: 24, weight: .semibold))
                Text("每天按设定时间批量关闭并重启选中的 macOS App")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.restartNow()
            } label: {
                Label("立即执行", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.managedApps.isEmpty || model.isRestarting)
        }
        .padding(20)
    }

    private var controls: some View {
        HStack(spacing: 18) {
            Toggle("每日自动执行", isOn: Binding(
                get: { model.scheduleEnabled },
                set: { model.setScheduleEnabled($0) }
            ))
            .toggleStyle(.switch)

            DatePicker(
                "执行时间",
                selection: Binding(
                    get: { model.runAtDate },
                    set: { model.updateRunTime($0) }
                ),
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.field)
            .disabled(!model.scheduleEnabled)

            Spacer()

            Button {
                model.addApplications()
            } label: {
                Label("添加 App", systemImage: "plus")
            }

            Button {
                model.removeApplications(with: selectedAppIDs)
                selectedAppIDs.removeAll()
            } label: {
                Label("移除", systemImage: "minus")
            }
            .disabled(selectedAppIDs.isEmpty || model.isRestarting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var appList: some View {
        HSplitView {
            VStack(spacing: 0) {
                if model.managedApps.isEmpty {
                    emptyState
                } else {
                    List(selection: $selectedAppIDs) {
                        ForEach(model.managedApps) { app in
                            AppRow(app: app)
                                .tag(app.id)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 430)

            VStack(alignment: .leading, spacing: 0) {
                Text("执行记录")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                if model.activityLog.isEmpty {
                    Text("暂无记录")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(model.activityLog, id: \.self) { line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .frame(minWidth: 260)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)

            Text("还没有选择 App")
                .font(.headline)

            Text("点击“添加 App”后可以批量选择 /Applications 或其他位置的 .app。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                model.addApplications()
            } label: {
                Label("添加 App", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            statusItem(
                title: "下次执行",
                value: model.nextRunDate.map(AppModel.fullDateFormatter.string) ?? "未安排"
            )

            statusItem(
                title: "上次执行",
                value: model.lastRunDate.map(AppModel.fullDateFormatter.string) ?? "暂无"
            )

            Spacer()

            if model.isRestarting {
                ProgressView()
                    .controlSize(.small)
                Text("正在执行")
                    .foregroundStyle(.secondary)
            } else {
                Label("就绪", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func statusItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
        }
    }
}

private struct AppRow: View {
    let app: ManagedApp

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let bundleIdentifier = app.bundleIdentifier {
                        Text(bundleIdentifier)
                    } else {
                        Text("无 Bundle ID")
                    }

                    Text("·")

                    Text(app.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置")
                .font(.title2.weight(.semibold))

            Toggle("登录 macOS 后自动打开 App Restarter", isOn: Binding(
                get: { model.launchAtLoginEnabled },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)

            Toggle("锁屏期间保持任务可执行", isOn: Binding(
                get: { model.lockedUseEnabled },
                set: { model.setLockedUseEnabled($0) }
            ))
            .toggleStyle(.switch)

            if model.lockedUseActive {
                Label("已保持后台定时任务活跃", systemImage: "lock.shield")
                    .foregroundStyle(.green)
            } else {
                Label("选择 App 并开启每日自动执行后生效", systemImage: "moon.zzz")
                    .foregroundStyle(.secondary)
            }

            Text("自动重启任务依赖 App Restarter 保持运行。开启登录启动后，日常使用会更稳定；开启锁屏保活后，App 会尽量防止空闲睡眠导致定时器暂停。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct StatusBarMenu: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("显示主窗口") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("立即执行") {
            model.restartNow()
        }
        .disabled(model.managedApps.isEmpty || model.isRestarting)
        Divider()
        if let next = model.nextRunDate {
            Text("下次: \(AppModel.fullDateFormatter.string(from: next))")
        } else {
            Text("未安排执行")
        }
        Text(model.lockedUseActive ? "锁屏保活: 已启用" : "锁屏保活: 未启用")
        Divider()
        Button("设置...") {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")
        Divider()
        Button("退出 App Restarter") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
