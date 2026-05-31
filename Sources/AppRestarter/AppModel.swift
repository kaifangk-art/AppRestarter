import AppKit
import Combine
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var managedApps: [ManagedApp] = []
    @Published private(set) var runAtDate: Date
    @Published private(set) var scheduleEnabled: Bool
    @Published private(set) var nextRunDate: Date?
    @Published private(set) var isRestarting = false
    @Published private(set) var lastRunDate: Date?
    @Published private(set) var activityLog: [String] = []
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var lockedUseEnabled: Bool
    @Published private(set) var lockedUseActive = false

    private let appsKey = "managedApps"
    private let hourKey = "runHour"
    private let minuteKey = "runMinute"
    private let scheduleEnabledKey = "scheduleEnabled"
    private let lastRunDateKey = "lastRunDate"
    private let lockedUseEnabledKey = "lockedUseEnabled"

    private var scheduledTimer: Timer?
    private var missedRunTimer: Timer?
    private var scheduleArmedDate: Date?
    private var lockedUseActivity: NSObjectProtocol?
    private let calendar = Calendar.current

    init() {
        let defaults = UserDefaults.standard
        scheduleEnabled = defaults.object(forKey: scheduleEnabledKey) as? Bool ?? true
        lockedUseEnabled = defaults.object(forKey: lockedUseEnabledKey) as? Bool ?? true

        let hour = defaults.object(forKey: hourKey) as? Int ?? 13
        let minute = defaults.object(forKey: minuteKey) as? Int ?? 0
        runAtDate = Self.dateForTime(hour: hour, minute: minute)
        lastRunDate = defaults.object(forKey: lastRunDateKey) as? Date

        if let data = defaults.data(forKey: appsKey),
           let decoded = try? JSONDecoder().decode([ManagedApp].self, from: data) {
            managedApps = decoded.filter { FileManager.default.fileExists(atPath: $0.path) }
        }

        refreshLoginItemState()
        configureSchedule()
    }

    func addApplications() {
        let panel = NSOpenPanel()
        panel.title = "选择要自动重启的 App"
        panel.prompt = "添加"
        panel.message = "可以一次选择多个 .app。"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]

        guard panel.runModal() == .OK else {
            return
        }

        let currentPaths = Set(managedApps.map { $0.url.standardizedFileURL.path })
        let additions = panel.urls.compactMap { url -> ManagedApp? in
            let appURL = url.standardizedFileURL
            guard appURL.pathExtension == "app", !currentPaths.contains(appURL.path) else {
                return nil
            }

            let name = (try? appURL.resourceValues(forKeys: [.localizedNameKey]).localizedName)
                ?? appURL.deletingPathExtension().lastPathComponent
            let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier

            return ManagedApp(name: name, path: appURL.path, bundleIdentifier: bundleIdentifier)
        }

        guard !additions.isEmpty else {
            appendLog("没有新增 App，可能已经在列表中。")
            return
        }

        managedApps.append(contentsOf: additions)
        saveApps()
        appendLog("已添加 \(additions.count) 个 App。")
        configureSchedule()
    }

    func removeApplications(with ids: Set<ManagedApp.ID>) {
        guard !ids.isEmpty else {
            return
        }

        managedApps.removeAll { ids.contains($0.id) }
        saveApps()
        appendLog("已移除 \(ids.count) 个 App。")
        configureSchedule()
    }

    func setScheduleEnabled(_ enabled: Bool) {
        scheduleEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: scheduleEnabledKey)
        appendLog(enabled ? "已开启每日自动重启。" : "已暂停每日自动重启。")
        configureSchedule()
    }

    func updateRunTime(_ date: Date) {
        runAtDate = date
        let components = calendar.dateComponents([.hour, .minute], from: date)
        UserDefaults.standard.set(components.hour ?? 13, forKey: hourKey)
        UserDefaults.standard.set(components.minute ?? 0, forKey: minuteKey)
        appendLog("每日时间已更新为 \(Self.timeFormatter.string(from: runAtDate))。")
        configureSchedule()
    }

    func restartNow() {
        guard !isRestarting else {
            return
        }

        Task {
            await restartSelectedApps(trigger: "手动")
            configureSchedule()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            appendLog("当前系统不支持应用内配置开机启动。")
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLoginItemState()
            appendLog(enabled ? "已设置开机启动。" : "已关闭开机启动。")
        } catch {
            refreshLoginItemState()
            appendLog("开机启动设置失败：\(error.localizedDescription)")
        }
    }

    func setLockedUseEnabled(_ enabled: Bool) {
        lockedUseEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: lockedUseEnabledKey)
        configureRuntimeGuards()
        appendLog(enabled ? "已开启锁屏期间保活。" : "已关闭锁屏期间保活。")
    }

    func refreshLoginItemState() {
        if #available(macOS 13.0, *) {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        } else {
            launchAtLoginEnabled = false
        }
    }

    private func configureSchedule() {
        scheduledTimer?.invalidate()
        scheduledTimer = nil
        scheduleArmedDate = nil

        guard scheduleEnabled, !managedApps.isEmpty else {
            nextRunDate = nil
            configureRuntimeGuards()
            return
        }

        let components = calendar.dateComponents([.hour, .minute], from: runAtDate)
        let nextDate = Self.nextDate(hour: components.hour ?? 13, minute: components.minute ?? 0)
        nextRunDate = nextDate
        scheduleArmedDate = Date()

        let timer = Timer(fire: nextDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }

                await self.restartSelectedApps(trigger: "定时")
                self.configureSchedule()
            }
        }

        scheduledTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        configureRuntimeGuards()
    }

    private func configureRuntimeGuards() {
        configureLockedUseActivity()
        configureMissedRunMonitor()
    }

    private func configureLockedUseActivity() {
        let shouldBeActive = lockedUseEnabled && scheduleEnabled && !managedApps.isEmpty

        if shouldBeActive, lockedUseActivity == nil {
            lockedUseActivity = ProcessInfo.processInfo.beginActivity(
                options: [
                    .idleSystemSleepDisabled,
                    .automaticTerminationDisabled,
                    .suddenTerminationDisabled
                ],
                reason: "Keep App Restarter scheduled tasks available while the user session is locked."
            )
            lockedUseActive = true
            return
        }

        if !shouldBeActive, let lockedUseActivity {
            ProcessInfo.processInfo.endActivity(lockedUseActivity)
            self.lockedUseActivity = nil
            lockedUseActive = false
        }
    }

    private func configureMissedRunMonitor() {
        missedRunTimer?.invalidate()
        missedRunTimer = nil

        guard scheduleEnabled, !managedApps.isEmpty else {
            return
        }

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.runMissedScheduledTaskIfNeeded()
            }
        }

        timer.tolerance = 5
        missedRunTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func restartSelectedApps(trigger: String) async {
        guard !isRestarting else {
            return
        }

        guard !managedApps.isEmpty else {
            appendLog("没有选择任何 App。")
            return
        }

        isRestarting = true
        let appsToRestart = managedApps
        appendLog("\(trigger)任务开始：准备重启 \(appsToRestart.count) 个 App。")

        for app in appsToRestart {
            await terminate(app)
        }

        appendLog("全部关闭请求已发送，等待 5 秒后重启。")
        try? await Task.sleep(for: .seconds(5))

        for app in appsToRestart {
            await launch(app)
        }

        lastRunDate = Date()
        UserDefaults.standard.set(lastRunDate, forKey: lastRunDateKey)
        isRestarting = false
        appendLog("\(trigger)任务完成。")
    }

    private func runMissedScheduledTaskIfNeeded() async {
        guard scheduleEnabled, !managedApps.isEmpty, !isRestarting else {
            return
        }

        let now = Date()
        let components = calendar.dateComponents([.hour, .minute], from: runAtDate)
        guard let scheduledToday = calendar.date(
            bySettingHour: components.hour ?? 13,
            minute: components.minute ?? 0,
            second: 0,
            of: now
        ) else {
            return
        }

        guard now >= scheduledToday else {
            return
        }

        guard let scheduleArmedDate, scheduleArmedDate <= scheduledToday else {
            return
        }

        if let lastRunDate, lastRunDate >= scheduledToday {
            return
        }

        appendLog("检测到今日定时任务未执行，开始补跑。")
        await restartSelectedApps(trigger: "补跑")
        configureSchedule()
    }

    private func terminate(_ app: ManagedApp) async {
        let runningApps = runningApplications(for: app)

        guard !runningApps.isEmpty else {
            appendLog("\(app.name) 未运行，将在 5 秒后直接启动。")
            return
        }

        appendLog("正在关闭 \(app.name)。")
        for runningApp in runningApps {
            if !runningApp.terminate() {
                runningApp.forceTerminate()
            }
        }

        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if runningApplications(for: app).isEmpty {
                appendLog("\(app.name) 已关闭。")
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        let stubbornApps = runningApplications(for: app)
        if stubbornApps.isEmpty {
            appendLog("\(app.name) 已关闭。")
            return
        }

        appendLog("\(app.name) 未及时退出，尝试强制关闭。")
        for stubbornApp in stubbornApps {
            stubbornApp.forceTerminate()
        }
    }

    private func launch(_ app: ManagedApp) async {
        guard FileManager.default.fileExists(atPath: app.path) else {
            appendLog("\(app.name) 不存在：\(app.path)")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false

        await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { [weak self] _, error in
                Task { @MainActor in
                    if let error {
                        self?.appendLog("\(app.name) 启动失败：\(error.localizedDescription)")
                    } else {
                        self?.appendLog("\(app.name) 已启动。")
                    }
                    continuation.resume()
                }
            }
        }
    }

    private func runningApplications(for app: ManagedApp) -> [NSRunningApplication] {
        if let bundleIdentifier = app.bundleIdentifier {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        }

        let targetPath = app.url.standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.filter { runningApp in
            runningApp.bundleURL?.standardizedFileURL.path == targetPath
        }
    }

    private func saveApps() {
        guard let encoded = try? JSONEncoder().encode(managedApps) else {
            appendLog("保存 App 列表失败。")
            return
        }
        UserDefaults.standard.set(encoded, forKey: appsKey)
    }

    private func appendLog(_ message: String) {
        let line = "\(Self.logFormatter.string(from: Date()))  \(message)"
        activityLog.insert(line, at: 0)
        if activityLog.count > 80 {
            activityLog.removeLast(activityLog.count - 80)
        }
    }

    private static func dateForTime(hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        let now = Date()
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
    }

    private static func nextDate(hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now

        if today > now {
            return today
        }

        return calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(24 * 60 * 60)
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
