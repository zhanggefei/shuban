//
//  WidgetMain.swift
//  书办（ShuBan）· macOS 桌面办公助手
//
//  只读展示：读取 data/data.json（由 refresh.sh 拉取企微日程 + 待办生成），
//  渲染月历、当日日程明细、进行中待办。数据文件变化时自动重载。
//

import SwiftUI
import AppKit

/// 验收钩子专用的输出。print 在重定向到文件时是块缓冲的，进程还活着就一行都看不到 ——
/// 「重启」这类要跨进程观察的用例如果用它，读到的永远是空文件，很容易误判成「没执行」。
func say(_ s: String) {
    FileHandle.standardOutput.write(Data((s + "\n").utf8))
}

// MARK: - 数据模型

struct ScheduleItem: Codable, Identifiable {
    let subject: String
    let begin: String
    let end: String
    let allDay: Bool
    let attendees: [String]
    let location: String
    let room: String
    let isMeeting: Bool
    let creator: String
    let description: String
    let repeatLabel: String
    let date: String
    let calendar: String
    let own: Bool

    var id: String { subject + "|" + begin + "|" + calendar }

    enum CodingKeys: String, CodingKey {
        case subject, begin, end, attendees, location, room, creator, description, date, calendar, own
        case allDay = "all_day"
        case isMeeting = "is_meeting"
        case repeatLabel = "repeat_label"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subject = c.str(.subject)
        begin = c.str(.begin)
        end = c.str(.end)
        allDay = c.bool(.allDay)
        attendees = c.strs(.attendees)
        location = c.str(.location)
        room = c.str(.room)
        isMeeting = c.bool(.isMeeting)
        creator = c.str(.creator)
        description = c.str(.description)
        repeatLabel = c.str(.repeatLabel)
        date = c.str(.date)
        calendar = c.str(.calendar)
        own = c.bool(.own)
    }
}

struct TodoItem: Codable, Identifiable {
    let todoId: String
    let title: String
    let status: String
    let userStatus: String
    let deadline: String
    let deadlineType: String
    let date: String
    let creator: String
    let followers: [String]
    let source: String
    let description: String
    /// 最后变动时间：已完成列表按它倒序（也就是「什么时候完成的」）
    let updateTime: String

    /// 优先用企业微信的 todo_id 作标识：改完截止时间后标题/日期会变，
    /// 用它们拼 id 会让 ForEach 认为是另一条，勾选动画和列表都会跳
    var id: String { todoId.isEmpty ? (title + "|" + deadline + "|" + creator) : todoId }

    /// 企业微信的完成状态：整体完成或自己那一份完成都算完成
    var finished: Bool { status == "finished" || userStatus == "finished" }
    /// 是否能在小组件里改：企业微信只允许「待办创建者」改，
    /// 机器人只有权改自己创建的（即小组件里新建的），他本人在企微建的会返回 860024
    ///
    /// 注意：企微对接口创建的待办**不返回 source**（实测恒为 null），所以全量刷新后
    /// 本地那条 "桌面小组件" 标记会被覆盖掉。必须同时认创建者名（机器人叫「XX的机器人」），
    /// 否则刷新一次就再也勾不动了
    var editable: Bool {
        guard !todoId.isEmpty else { return false }
        return source == "桌面小组件" || creator.hasSuffix("机器人")
    }

    enum CodingKeys: String, CodingKey {
        case title, status, deadline, date, creator, followers, source, description
        case todoId = "todo_id"
        case userStatus = "user_status"
        case deadlineType = "deadline_type"
        case updateTime = "update_time"
    }

    /// 本地刚建、还没拿到企业微信 id 的待办（乐观插入用）
    var isPending: Bool { todoId.hasPrefix("tmp-") }

    /// 乐观编辑用：拿一条改了几个字段的新副本（字段都是 let，只能整条换）
    func with(title: String? = nil, status: String? = nil, userStatus: String? = nil,
              deadline: String? = nil, deadlineType: String? = nil, date: String? = nil,
              updateTime: String? = nil) -> TodoItem {
        TodoItem(todoId: todoId,
                 title: title ?? self.title,
                 status: status ?? self.status,
                 userStatus: userStatus ?? self.userStatus,
                 deadline: deadline ?? self.deadline,
                 deadlineType: deadlineType ?? self.deadlineType,
                 date: date ?? self.date,
                 creator: creator,
                 followers: followers,
                 source: source,
                 description: description,
                 updateTime: updateTime ?? self.updateTime)
    }

    init(todoId: String, title: String, status: String, userStatus: String,
         deadline: String, deadlineType: String, date: String, creator: String,
         followers: [String], source: String, description: String, updateTime: String) {
        self.todoId = todoId
        self.title = title
        self.status = status
        self.userStatus = userStatus
        self.deadline = deadline
        self.deadlineType = deadlineType
        self.date = date
        self.creator = creator
        self.followers = followers
        self.source = source
        self.description = description
        self.updateTime = updateTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        todoId = c.str(.todoId)
        title = c.str(.title)
        status = c.str(.status)
        userStatus = c.str(.userStatus)
        deadline = c.str(.deadline)
        deadlineType = c.str(.deadlineType)
        date = c.str(.date)
        creator = c.str(.creator)
        followers = c.strs(.followers)
        source = c.str(.source)
        description = c.str(.description)
        updateTime = c.str(.updateTime)
    }
}

struct PayloadError: Codable {
    let module: String
    let code: String
    let message: String
    let url: String?
}

struct Payload: Codable {
    let generatedAt: String
    let schedulesOk: Bool
    let todosOk: Bool
    let schedules: [ScheduleItem]
    let todos: [TodoItem]
    let errors: [PayloadError]?

    enum CodingKeys: String, CodingKey {
        case schedules, todos, errors
        case generatedAt = "generated_at"
        case schedulesOk = "schedules_ok"
        case todosOk = "todos_ok"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = c.str(.generatedAt)
        schedulesOk = c.bool(.schedulesOk)
        todosOk = c.bool(.todosOk)
        schedules = (try? c.decode([ScheduleItem].self, forKey: .schedules)) ?? []
        todos = (try? c.decode([TodoItem].self, forKey: .todos)) ?? []
        errors = try? c.decode([PayloadError].self, forKey: .errors)
    }
}

extension KeyedDecodingContainer {
    func str(_ key: Key) -> String { (try? decode(String.self, forKey: key)) ?? "" }
    func bool(_ key: Key) -> Bool { (try? decode(Bool.self, forKey: key)) ?? false }
    func strs(_ key: Key) -> [String] { (try? decode([String].self, forKey: key)) ?? [] }
}

// MARK: - 日期工具

enum Fmt {
    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
}

var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.firstWeekday = 2
    c.timeZone = .current
    return c
}()

func dayKey(_ d: Date) -> String { Fmt.day.string(from: d) }

func parseTime(_ s: String) -> Date? {
    if s.count >= 19 { return Fmt.iso.date(from: String(s.prefix(19))) }
    if s.count == 10 { return Fmt.day.date(from: s) }
    return nil
}

/// 企微返回 "englishname(中文名)"，界面只留中文名，无括号则原样
func shortName(_ s: String) -> String {
    if let l = s.firstIndex(of: "("), let r = s.lastIndex(of: ")"), l < r {
        let inner = String(s[s.index(after: l)..<r]).trimmingCharacters(in: .whitespaces)
        if !inner.isEmpty { return inner }
    }
    return s
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var payload: Payload?
    @Published var monthAnchor: Date = cal.startOfDay(for: Date())
    @Published var selectedDay: Date = cal.startOfDay(for: Date())
    @Published var tab: Int = 1          // 0=日程 1=待办（默认落在待办：需求要求待办优先）
    @Published var scope: Int = 0        // 0=只看我的日历 1=含团队共享日历
    /// 「待办」页内的二级筛选：0=进行中 1=已完成
    @Published var todoFilter: Int = 0
    @Published var refreshing = false
    @Published var statusText = ""
    /// 回车提交信号。中文输入法下「拼音还没选字就按回车」只是候选上屏，
    /// SwiftUI 的 onSubmit 不会触发（曾踩过一次：敲完按回车没反应）。
    /// 由 AppDelegate 的按键监视器自增，ContentView 监听后执行真正的提交。
    @Published var composerSubmitTick = 0

    func requestComposerSubmit() { composerSubmitTick &+= 1 }
    @Published var pinned = false
    /// 待办回写进行中标记，避免连点发多次请求
    @Published var busyTodo = false
    /// 时钟。SwiftUI 的 body 只在 @Published 变化时重算，时间自己流逝不会触发任何东西
    /// ——实测踩过：23:30 了那条还写着「今天截止 17:43」，就是因为过期判定用的是
    /// 上一次渲染时的 Date()。所有与「现在」有关的判断统一读 clock，由 startClock 推。
    @Published private(set) var clock = Date()
    private var clockTimer: Timer?
    private var clockObs: NSObjectProtocol?
    /// 窗口缩放档位：本身不参与绘制，仅用于驱动视图重建，真正的系数在 Fnt.scale
    @Published private(set) var zoom: CGFloat = 1

    /// 窗口宽度变化 → 更新全局缩放档并触发重排
    func applyZoom(_ width: CGFloat, _ height: CGFloat = 0) {
        Fnt.update(width, height)
        if abs(zoom - Fnt.scale) > 0.008 { zoom = Fnt.scale }
    }
    /// 由 AppDelegate 注入：最小化窗口
    var onHide: (() -> Void)?
    /// 由 AppDelegate 注入：打开某个子功能的独立窗口
    var onOpenFeature: ((FeaturePane) -> Void)?
    @Published var dataURL: URL?
    @Published var refreshScript: URL?
    var projectDir: URL?

    private var lastMTime: Date?
    private var timer: Timer?
    /// 正在跑的刷新子进程，退出时要掐掉
    private var refreshProc: Process?

    // MARK: 乐观层（先显示成功，后台再同步）
    /// 刚建、还没拿到企业微信 id 的待办
    @Published var pendingTodos: [TodoItem] = []
    /// 单条覆盖：改名 / 勾选 / 改期，清掉即回滚
    @Published var optimistic: [String: TodoItem] = [:]
    /// 已删但还在同步的 id，清掉即恢复显示
    @Published var hiddenTodos: Set<String> = []
    /// 正在同步的 id，行尾显示小转圈
    @Published var syncingIds: Set<String> = []

    /// 退出前终止刷新子进程。否则它会变成孤儿继续跑完：输出管道已断，
    /// wecom-cli 在这种情况下返回「成功但是空列表」，把界面提示带歪。
    func cancelRefresh() {
        if let p = refreshProc, p.isRunning { p.terminate() }
        refreshProc = nil
    }

    /// 底部那行提示是不是错误（决定颜色和停留时长）
    func footerIsError(_ s: String) -> Bool {
        for key in ["失败", "未找到", "无法", "无权", "缺少", "错误", "Traceback"] where s.contains(key) {
            return true
        }
        return false
    }

    /// 写操作留痕到底部栏之外的一份日志。界面提示只留几秒，出了问题看不到现场。
    func logUI(_ line: String) {
        guard let dir = projectDir else { return }
        let url = dir.appendingPathComponent("data/ui.log")
        let text = "[\(Fmt.iso.string(from: Date()))] \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(data)
        } else {
            try? data.write(to: url)
        }
    }

    /// 这次启动是「重启书办」拉起来的
    private(set) var justRelaunched = false
    /// 重启前开着的子功能窗口，回来要照原样再开一次（nil = 只开日历）
    private(set) var reopenPane: FeaturePane?

    /// 点「重启书办」时记下自己是从哪个窗口点的。重启是新进程，内存里什么都不剩，
    /// 不落一个一次性键，回来就只剩日历窗，用户会以为「没重启」。
    func markRelaunch(from pane: FeaturePane?) {
        let d = UserDefaults.standard
        d.set(pane?.rawValue ?? 0, forKey: "shuban.reopenPane")
        d.set(Date().timeIntervalSince1970, forKey: "shuban.reopenPaneAt")
    }

    init() {
        resolvePaths()
        if let t = ProcessInfo.processInfo.environment["WECAL_TAB"], let v = Int(t), v == 0 || v == 1 {
            tab = v
        }
        if let sc = ProcessInfo.processInfo.environment["WECAL_SCOPE"], let v = Int(sc) {
            scope = v
        }
        // 点「重启书办」前记下的窗口：一次性键，读完就删，正常退出不会把窗口钉死在录屏上。
        // 只认 90 秒内的记录 —— 万一那次重启没拉起来（键留了下来），
        // 几天后正常启动就会莫名其妙弹出录屏窗，用户只会觉得「怎么老自己蹦出来」。
        let ud = UserDefaults.standard
        if let m = ud.object(forKey: "shuban.reopenPane") as? Int {
            let at = ud.double(forKey: "shuban.reopenPaneAt")
            let fresh = at > 0 && Date().timeIntervalSince1970 - at < 90
            if fresh {
                reopenPane = FeaturePane(rawValue: m)
                justRelaunched = true
            }
            ud.removeObject(forKey: "shuban.reopenPane")
            ud.removeObject(forKey: "shuban.reopenPaneAt")
        }
        // 验收钩子：WECAL_MODE=1/2 启动即打开对应子功能窗口（离屏拍图用，正常启动不设）
        if let m = ProcessInfo.processInfo.environment["WECAL_MODE"], let v = Int(m) {
            reopenPane = FeaturePane(rawValue: v)
        }
        // 拍「正在录音」那张图会真开麦录几秒。不换走输出目录就是往真实的
        // `~/Music/书办录音` 里塞样本（第一版拍图就这么留下了 7 个文件）。
        // 用例那边有「必须在临时目录下」的硬校验，钩子这条路也得自己堵上。
        if ProcessInfo.processInfo.environment["WECAL_AUDIO_SHOT_REC"] == "1",
           (ProcessInfo.processInfo.environment["WECAL_AUDIO_REC"] ?? "").isEmpty {
            setenv("WECAL_AUDIO_REC",
                   (NSTemporaryDirectory() as NSString).appendingPathComponent("shuban-shot-rec"), 1)
        }
        if let ds = ProcessInfo.processInfo.environment["WECAL_DAY"], let dt = Fmt.day.date(from: ds) {
            let day = cal.startOfDay(for: dt)
            selectedDay = day
            monthAnchor = day
        }
    }

    private func resolvePaths() {
        let fm = FileManager.default
        // 1) 环境变量
        if let dir = ProcessInfo.processInfo.environment["WECAL_DIR"], !dir.isEmpty {
            let d = URL(fileURLWithPath: dir)
            let json = d.appendingPathComponent("data/data.json")
            if fm.fileExists(atPath: json.path) {
                dataURL = json
                refreshScript = d.appendingPathComponent("refresh.sh")
                projectDir = d
                statusText = ""
                return
            }
        }
        // 2) Info.plist 注入的工程目录
        if let p = Bundle.main.object(forInfoDictionaryKey: "WECALProjectDir") as? String, !p.isEmpty {
            let d = URL(fileURLWithPath: p)
            let json = d.appendingPathComponent("data/data.json")
            if fm.fileExists(atPath: json.path) {
                dataURL = json
                refreshScript = d.appendingPathComponent("refresh.sh")
                projectDir = d
                return
            }
        }
        // 3) app 包内 Resources 快照（只读兜底）
        if let res = Bundle.main.url(forResource: "data", withExtension: "json") {
            dataURL = res
            return
        }
        statusText = "未找到 data.json，请先运行 refresh.sh"
    }

    func load(force: Bool = false) {
        guard let url = dataURL else { statusText = "未找到 data.json"; return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let m = attrs?[.modificationDate] as? Date
        if !force, let m = m, let last = lastMTime, m == last { return }
        lastMTime = m
        do {
            let raw = try Data(contentsOf: url)
            let p = try JSONDecoder().decode(Payload.self, from: raw)
            payload = p
            statusText = ""
        } catch {
            statusText = "数据解析失败：\(error.localizedDescription)"
        }
    }

    func startWatching() {
        load(force: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
        startClock()
    }

    // MARK: 自动同步

    /// 与企业微信的同步间隔（分钟）。手动点 ↻ 不受这个限制。
    /// 2026-11-21 检查时问「自动同步是多久」——答案是「没有」：之前只有 3 秒的本地文件监听，
    /// 企微里改了/加了待办，小组件不点刷新就一直是旧的。这里补一个静默的定时同步。
    /// WECAL_SYNC_MINUTES 可临时改节拍，用来验收「到点真的会自己刷」（10 分钟太久没法验）。
    private let autoSyncMinutes: Double = ProcessInfo.processInfo.environment["WECAL_SYNC_MINUTES"]
        .flatMap { Double($0) } ?? 10
    private var autoSyncTimer: Timer?
    /// 上次发起同步的时刻（防止「文件还是旧的 → 又刷一次」的连环触发）
    private var lastSyncAt = Date.distantPast

    func startAutoSync() {
        autoSyncTimer?.invalidate()
        // 每 60 秒看一次表，而不是直接挂「每 10 分钟一拍」：
        // 这样手动刷新之后是重新计时，不会刚点完 ↻ 又被自动刷一遍。
        autoSyncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoSyncTick() }
        }
        autoSyncTick()      // 开机/启动时如果本地数据已经过期，立刻补一次
    }

    private func autoSyncTick() {
        guard !refreshing, refreshScript != nil else { return }
        // 以「文件里的 generated_at」和「本次进程内上次同步时刻」两者较新的那个为准：
        // 前者管着开机后数据陈旧的情况，后者管着同步失败不能每 60 秒重试一次
        let fileAge = parseTime(payload?.generatedAt ?? "") ?? Date.distantPast
        let last = max(fileAge, lastSyncAt)
        let gap = Date().timeIntervalSince(last)
        guard gap >= autoSyncMinutes * 60 else { return }
        logUI("自动同步触发（上次同步 \(Int(gap / 60)) 分钟前）")
        refresh(silent: true)
    }

    /// 每 5 秒推一次时钟，让「已过期 / 今天截止 / 明天截止」这类文案自己跟着时间走。
    /// 5 秒是折中：一分钟内必然翻面，也不至于每秒重排整个列表。
    func startClock() {
        clock = Date()
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.clock = Date() }
        }
        // 合盖休眠一整夜后唤醒，定时器可能被推迟；回到前台立刻重算一次
        if let o = clockObs { NotificationCenter.default.removeObserver(o) }
        clockObs = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clock = Date() }
        }
    }

    // MARK: 桌面提醒

    private var reminderTimer: Timer?
    private var reminded: Set<String> = []

    private var remindedKey: String { "wecal.reminded." + dayKey(Date()) }

    func startReminders() {
        reminded = Set(UserDefaults.standard.stringArray(forKey: remindedKey) ?? [])
        reminderTimer?.invalidate()
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkReminders() }
        }
        checkReminders()
    }

    /// 扫描即将到期的待办与即将开始的日程，命中则弹一次桌面提醒
    func checkReminders() {
        let now = Date()

        // 先处理本地「稍后提醒」队列（延期用，见 snooze(todoId:minutes:)）
        if let hit = snoozes.first(where: { $0.fireAt <= now.addingTimeInterval(1) }),
           let t = mergedTodos.first(where: { $0.todoId == hit.todoId }) {
            snoozes.removeAll { $0.todoId == hit.todoId }
            logUI("提醒弹卡（延后）「\(t.title)」→ \(Fmt.hhmm.string(from: hit.fireAt))")
            showTodoReminder(t, now: now, at: hit.fireAt)
            return
        }

        // 待办：「提醒时间」是本人设定的时刻，**到点才弹**。
        // 扫描改成 5 秒一轮，窗口收进 [-10min, +2s]：提前只留 2 秒给定时器抖动，
        // 错过最多 10 分钟补发。之前提前 15 秒 + 20 秒轮询，实测能提前 8 秒弹，
        // 两次反馈「没生效」有一半都是弹早/弹晚造成的错觉。
        for t in (payload?.todos ?? []) where !t.finished {
            guard t.deadlineType == "datetime", let d = parseTime(t.deadline) else { continue }
            let seconds = d.timeIntervalSince(now)
            guard seconds > -600, seconds <= 2 else { continue }
            let key = "todo|" + t.title + "|" + t.deadline
            guard !reminded.contains(key) else { continue }
            reminded.insert(key)
            UserDefaults.standard.set(Array(reminded), forKey: remindedKey)
            // 留痕：不然「改了时间到底有没有弹」永远说不清（此前被问过一次的）
            logUI("提醒弹卡（待办）「\(t.title)」deadline=\(t.deadline) "
                  + (seconds >= 0 ? "提前 \(Int(seconds))s" : "补发，已过 \(Int(-seconds))s"))
            showTodoReminder(t, now: now)
            return
        }

        // 日程：开始前 15 分钟内
        for s in (payload?.schedules ?? []).filter({ $0.own }) {
            guard let b = parseTime(s.begin) else { continue }
            let seconds = b.timeIntervalSince(now)
            guard seconds > 0, seconds <= 15 * 60 else { continue }
            let key = s.subject + "|" + s.begin
            guard !reminded.contains(key) else { continue }
            reminded.insert(key)
            UserDefaults.standard.set(Array(reminded), forKey: remindedKey)
            logUI("提醒弹卡（日程）「\(s.subject)」\(s.begin) 提前 \(Int(seconds / 60)) 分钟")
            ReminderCenter.shared.show(item: reminderItem(s, minutes: Int(seconds / 60)))
            return
        }
    }

    // MARK: 提醒卡上的「延期」

    private struct Snooze {
        let todoId: String
        let fireAt: Date
    }

    /// 本地稍后提醒队列。企业微信不允许机器人改他自己建的待办（860024），
    /// 那种情况改不了截止时间，只能在小组件里自己盯一个时间点重新弹卡。
    private var snoozes: [Snooze] = []

    /// `at` 是「本地稍后提醒」的场景（企微里改不了的待办）：截止时间没动，
    /// 卡上要显示延到几点，而不是那条已经过期的原时间。
    private func todoReminderItem(_ t: TodoItem, now: Date, at: Date? = nil) -> ReminderItem {
        let due = at ?? parseTime(t.deadline)
        let left = max(0, Int((due?.timeIntervalSince(now) ?? 0) / 60))
        let timeText = due.map { Fmt.hhmm.string(from: $0) }
            ?? String(t.deadline.dropFirst(11).prefix(5))
        let cap: String
        if at != nil { cap = "延后提醒" }
        else if left <= 0 { cap = "已到提醒时间" }
        else { cap = "\(left) 分钟后到点" }
        return ReminderItem(subject: t.title,
                            beginText: timeText,
                            minutesLeft: left,
                            attendees: t.followers.map(shortName),
                            place: "待办",
                            title: "待 办 提 醒",
                            caption: cap,
                            todoId: t.todoId)
    }

    private func showTodoReminder(_ t: TodoItem, now: Date, at: Date? = nil) {
        let id = t.todoId
        ReminderCenter.shared.show(item: todoReminderItem(t, now: now, at: at), onSnooze: { minutes in
            Task { @MainActor in self.snooze(todoId: id, minutes: minutes) }
        })
    }

    /// 菜单「预览提醒动画」用：拿一条真实待办弹卡，延期按钮可以真点
    func previewReminder(for t: TodoItem) {
        showTodoReminder(t, now: Date())
    }

    /// 延期：有权限就真改企业微信的截止时间（乐观 + 后台同步）；
    /// 没权限（他自己在企微客户端建的）退化成「只在这个小组件里稍后提醒」。
    func snooze(todoId: String, minutes: Int) {
        guard let t = mergedTodos.first(where: { $0.todoId == todoId }) else { return }
        // 基准取「当前生效的那个时间」：企微里改过就取新截止时间，
        // 本地稍后提醒过就取那个 fireAt，都没有才退回原截止时间。
        // 否则连着点两次 +10 分会都从同一个旧时间算，第二次等于没延。
        let pending = snoozes.last(where: { $0.todoId == todoId })?.fireAt
        let base = pending ?? parseTime(t.deadline) ?? Date()
        let target = max(base, Date()).addingTimeInterval(TimeInterval(minutes * 60))
        let v = Fmt.iso.string(from: target)
        let hhmm = Fmt.hhmm.string(from: target)
        if t.editable {
            setTodoDeadline(t, v)
            flash("已延到 \(hhmm)")
        } else {
            // 覆盖而非追加：同一待办只留最近一次延期
            snoozes.removeAll { $0.todoId == todoId }
            snoozes.append(Snooze(todoId: todoId, fireAt: target))
            flash("已稍后提醒 \(hhmm) · 企微里的截止时间不变")
        }
    }

    /// 底部提示：给定文本，到点自动清掉（除非期间已被别的提示替换）
    func flash(_ text: String, hold: Double = 6) {
        statusText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            if self?.statusText == text { self?.statusText = "" }
        }
    }

    /// 把小组件里写的待办同步到企业微信
    func addTodo(_ title: String, deadline: String?) {
        guard let dir = projectDir else {
            statusText = "未找到工程目录，无法写入企业微信"
            return
        }
        let script = dir.appendingPathComponent("add_todo.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            statusText = "缺少 add_todo.py，无法写入"
            return
        }

        // 先落一条本地的，界面立刻出现 —— 需求要求「先让用户感觉已经成功，后台再同步」。
        // 真实条目拿到之前 todo_id 用 tmp- 前缀，排序时置顶，行尾显示小转圈。
        let when = deadline ?? ""
        let dType = when.isEmpty ? "" : (when.count > 10 ? "datetime" : "date")
        let draft = TodoItem(todoId: "tmp-" + UUID().uuidString,
                             title: title, status: "proceed", userStatus: "proceed",
                             deadline: when, deadlineType: dType,
                             date: String(when.prefix(10)),
                             creator: "桌面小组件", followers: [], source: "",
                             description: "", updateTime: Fmt.iso.string(from: Date()))
        pendingTodos.insert(draft, at: 0)
        syncingIds.insert(draft.todoId)
        statusText = ""

        var args = [script.path, title]
        if !when.isEmpty { args.append(when) }

        Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            var out = ""
            var rc: Int32 = -1
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                out = String(data: data, encoding: .utf8) ?? ""
                p.waitUntilExit()
                rc = p.terminationStatus
            } catch {
                out = "写入失败：" + error.localizedDescription
            }
            let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = rc   // 并发闭包不能捕获可变变量（Swift 6 是硬错误）
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.syncingIds.remove(draft.todoId)
                if code == 0 {
                    // 脚本已把真实条目写进 data.json：先读回来，再撤掉临时那条，
                    // 顺序反了会闪一下「消失又出现」
                    self.load(force: true)
                    self.pendingTodos.removeAll { $0.todoId == draft.todoId }
                    self.logUI("add_todo 「\(title)」成功")
                } else {
                    self.pendingTodos.removeAll { $0.todoId == draft.todoId }   // 失败撤回
                    self.statusText = self.footerIsError(text) || text.isEmpty
                        ? (text.isEmpty ? "写入企业微信失败" : text) : text
                    self.logUI("add_todo 「\(title)」失败：\(text)")
                    self.load(force: true)
                    let shown = self.statusText
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                        if self?.statusText == shown { self?.statusText = "" }
                    }
                }
            }
        }
    }

    // MARK: 编辑待办（标记完成 / 改截止时间）

    /// 调 edit_todo.py 回写企业微信；脚本内部已把改动乐观合进 data.json
    /// - Parameter siteID: 这条操作影响的待办 id。传了就走乐观层：调用方已经把界面改好
    ///   并把它记进 optimistic / hiddenTodos，这里只负责收尾（成功→撤销覆盖层，
    ///   因为磁盘已经是新数据；失败→同样撤销覆盖层，界面自动回滚到原样）。
    private func runTodoEdit(_ args: [String], siteID: String? = nil) {
        guard let dir = projectDir else {
            statusText = "未找到工程目录，无法写入企业微信"
            clearOptimistic(siteID)
            return
        }
        let script = dir.appendingPathComponent("edit_todo.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            statusText = "缺少 edit_todo.py，无法编辑待办"
            clearOptimistic(siteID)
            return
        }
        busyTodo = true
        if let id = siteID { syncingIds.insert(id) }
        // 成功就不再提示了：界面早就变了，再顶一行「已同步」纯属噪音

        Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [script.path] + args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            var out = ""
            do {
                try p.run()
                out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
            } catch {
                out = "操作失败：" + error.localizedDescription
            }
            let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.busyTodo = false
                // 先读盘再清覆盖层，同一轮里完成，界面不会闪回旧值
                self.load(force: true)
                self.clearOptimistic(siteID)
                if !text.isEmpty, !text.hasPrefix("已") {
                    // 失败时脚本会把企业微信的原话带回来（如 860024 仅待办创建者可更新），不做粉饰
                    self.statusText = text
                    self.logUI("edit_todo \(args.joined(separator: " ")) 失败：\(text)")
                    let shown = self.statusText
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                        if self?.statusText == shown { self?.statusText = "" }
                    }
                } else {
                    self.logUI("edit_todo \(args.joined(separator: " ")) 成功")
                }
            }
        }
    }

    private func clearOptimistic(_ id: String?) {
        guard let id else { return }
        optimistic[id] = nil
        hiddenTodos.remove(id)
        syncingIds.remove(id)
    }

    /// 标记完成 / 取消完成。同一个勾选框：没勾就标完成，已完成的走「重新打开」。
    ///
    /// 所有写操作都遵循同一套：**先改界面、再后台同步**（2026-11-21 需求）。
    /// 界面改动记在 optimistic 里，脚本回来时由 clearOptimistic 撤掉：
    /// 成功时磁盘已是新值，撤掉无感；失败时撤掉就是自动回滚。
    func finishTodo(_ t: TodoItem) {
        if t.finished {
            reopenTodo(t)
            return
        }
        guard t.editable else {
            statusText = t.todoId.isEmpty
                ? "这条待办没有企业微信 ID，点 ↻ 刷新后可编辑"
                : "企业微信限制：只有创建者能改，这条需在企微客户端操作"
            return
        }
        guard !syncingIds.contains(t.todoId) else { return }
        optimistic[t.todoId] = t.with(status: "finished", userStatus: "finished",
                                      updateTime: Fmt.iso.string(from: Date()))
        runTodoEdit(["finish", t.todoId, "all"], siteID: t.todoId)
    }

    /// 「恢复到未完成」。企业微信的完成状态不可逆（实测 finish 传 false 报
    /// 「待办已被完成过」，update 根本没有状态字段），所以只能按原标题、原截止时间
    /// 新建一条未完成的，再删掉这条已完成的 —— 2026-11-21 选定这个口径。
    func reopenTodo(_ t: TodoItem) {
        guard t.finished else { return }
        guard t.editable else {
            statusText = "这条是「\(t.creator.isEmpty ? "企微客户端" : t.creator)」建的，"
                + "机器人无权删除，请到企微客户端撤销完成"
            return
        }
        guard !syncingIds.contains(t.todoId) else { return }
        // 乐观地先显示成未完成；实际是新建一条，同步完成后旧 id 消失、新 id 出现
        optimistic[t.todoId] = t.with(status: "proceed", userStatus: "proceed",
                                      updateTime: Fmt.iso.string(from: Date()))
        runTodoEdit(["reopen", t.todoId], siteID: t.todoId)
    }

    /// 改标题。企业微信的 update 接口字段都可选，只传 title 不会动到截止时间/参与人。
    func renameTodo(_ t: TodoItem, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != t.title else { return }
        guard t.editable else {
            statusText = "「\(t.creator.isEmpty ? "企微客户端" : t.creator)」建的这一条，机器人无权改名"
            return
        }
        guard !syncingIds.contains(t.todoId) else { return }
        optimistic[t.todoId] = t.with(title: clean, updateTime: Fmt.iso.string(from: Date()))
        runTodoEdit(["rename", t.todoId, clean], siteID: t.todoId)
    }

    /// 删除待办（企业微信里一并删掉，不可撤销）
    func deleteTodo(_ t: TodoItem) {
        guard t.editable else {
            statusText = "「\(t.creator.isEmpty ? "企微客户端" : t.creator)」建的这一条，机器人无权删除"
            return
        }
        guard !syncingIds.contains(t.todoId) else { return }
        hiddenTodos.insert(t.todoId)          // 先让它从列表里消失
        runTodoEdit(["delete", t.todoId], siteID: t.todoId)
    }

    func setTodoDeadline(_ t: TodoItem, _ value: String) {
        guard t.editable else {
            statusText = t.todoId.isEmpty
                ? "这条待办没有企业微信 ID，点 ↻ 刷新后可编辑"
                : "企业微信限制：只有创建者能改，这条需在企微客户端操作"
            return
        }
        guard !syncingIds.contains(t.todoId) else { return }
        if t.finished {
            statusText = "这条待办已完成，先取消完成状态再改时间"
            return
        }
        // 下面两个拦截都是为了让企微的原始报错不出现在界面上：
        // ① 时间点没变 —— 企微对「设成原来的时间」照样走校验，原时间若已过期就回
        //    860033 截止时间早于当前时间（实测踩过两次），用户却看不出哪里改了。
        // ② 选了过去的时刻 —— 同样必被拒，不如当场说清楚。
        if value != "none", !value.isEmpty {
            if value == t.deadline {
                // 把「跟什么一样」说出来。加了时刻却不生效那种情况，看到这句就能明白
                // 是自己还勾着「只标日期」（date 类型的胶囊文案本来就不带时刻）
                flash("和现在一样（\(humanDeadline(value))），没改动", hold: 4)
                return
            }
            if value.count > 10, let d = parseTime(value), d < Date() {
                flash("这个时间已经过去了，企业微信不接受过去的截止时间")
                return
            }
            if value.count == 10, let d = parseTime(value),
               Fmt.day.string(from: d) < Fmt.day.string(from: Date()) {
                flash("这个日期已经过去了，换一天吧")
                return
            }
        }
        let (dType, dValue, dDate): (String, String, String)
        if value == "none" || value.isEmpty {
            (dType, dValue, dDate) = ("", "", "")
        } else if value.count > 10 {
            (dType, dValue, dDate) = ("datetime", value, String(value.prefix(10)))
        } else {
            (dType, dValue, dDate) = ("date", value, value)
        }
        optimistic[t.todoId] = t.with(deadline: dValue, deadlineType: dType, date: dDate,
                                      updateTime: Fmt.iso.string(from: Date()))
        // 改期成功本来不吭声（见 runTodoEdit 的注释），但「只标日期」那种改法胶囊文案
        // 常常一字不变，于是整次操作毫无反馈 —— 用户据此判「不生效」。这里先给一句
        // 带结果的确认；真失败了，错误提示会在回调里把它覆盖掉。
        flash(value == "none" || value.isEmpty
              ? "已清除截止时间"
              : "已改为 \(humanDeadline(value))", hold: 4)
        runTodoEdit(["deadline", t.todoId, value], siteID: t.todoId)
    }

    /// "2026-11-23" / "2026-11-23 09:00:00" → 人话。用于改期后的确认提示，
    /// 让「写进去的到底是哪个值」直接可读。
    func humanDeadline(_ v: String) -> String {
        guard let d = parseTime(v) else { return v }
        let hm = String(format: "%02d:%02d", cal.component(.hour, from: d),
                        cal.component(.minute, from: d))
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let dayText: String
        if cal.isDateInToday(d) { dayText = "今天" }
        else if cal.isDate(d, inSameDayAs: tomorrow) { dayText = "明天" }
        else { dayText = String(format: "%d/%d", cal.component(.month, from: d),
                                cal.component(.day, from: d)) }
        // 只标日期的必须点明，否则他会以为时刻也一起写进去了
        return v.count > 10 ? "\(dayText) \(hm)" : "\(dayText)（只标日期）"
    }

    func reminderItem(_ s: ScheduleItem, minutes: Int) -> ReminderItem {
        let place: String
        if !s.room.isEmpty {
            place = s.room
        } else if !s.location.isEmpty {
            place = s.location
        } else {
            place = s.calendar.replacingOccurrences(of: "的日历", with: "")
        }
        return ReminderItem(subject: s.subject,
                            beginText: String(s.begin.dropFirst(11).prefix(5)),
                            minutesLeft: minutes,
                            attendees: s.attendees.map(shortName),
                            place: place)
    }

    func refresh(silent: Bool = false) {
        guard !refreshing else { return }
        guard let script = refreshScript else {
            if !silent { statusText = "未找到 refresh.sh，无法刷新" }
            return
        }
        refreshing = true
        lastSyncAt = Date()
        let startedAt = Date()      // 用于日志里记「这次同步花了多久」
        // 自动同步不写「正在拉取…」——每 10 分钟闪一行字很扰人；
        // 但按钮上的转圈留着（refreshing），让人知道数据刚动过
        if !silent { statusText = "正在拉取企微数据…" }
        let path = script.path
        Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [path]
            var out = ""
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do {
                try p.run()
                // 记下来，小组件退出时能掐掉它（见 cancelRefresh）
                await MainActor.run { [weak self] in self?.refreshProc = p }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                out = String(data: data, encoding: .utf8) ?? ""
                p.waitUntilExit()
            } catch {
                out = "启动失败：\(error.localizedDescription)"
            }
            let rc = p.terminationStatus
            let result = out   // 并发闭包不能捕获可变变量（Swift 6 是硬错误）
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.refreshProc = nil
                self.refreshing = false
                self.load(force: true)
                // 权限类错误由底部状态栏按 errors 精确提示，这里只兜底其他异常
                if rc == 0 || result.contains("850003") {
                    // 自动同步成功不该抹掉用户刚看到的提示（比如「已延到 09:00」），
                    // 只把自己之前那条失败提示收掉
                    if !silent || self.statusText.hasPrefix("自动同步") { self.statusText = "" }
                } else {
                    // 优先取脚本里打了 "!!" 的那行，别把「== 刷新书办数据 ==」
                    // 这种标题当成错误提示（之前点刷新失败只看到这行标题，等于没说原因）
                    let lines = result.split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    let msg = lines.first(where: { $0.hasPrefix("!!") })
                        ?? lines.first(where: { !$0.hasPrefix("==") && !$0.hasPrefix("⚠️") })
                        ?? "刷新失败，已保留上次数据"
                    if silent {
                        // 后台失败不该一直挂在界面上：飘 8 秒就收，旧数据继续用
                        self.flash("自动同步没成功，沿用上次数据（\(msg)）", hold: 8)
                    } else {
                        self.statusText = msg
                    }
                }
                self.logUI("刷新\(silent ? "（自动）" : "（手动）") rc=\(rc) → "
                    + (self.statusText.isEmpty ? "正常" : self.statusText))
                // 留痕耗时：全量刷新从十几秒到 100 秒都见过，节拍是否够用要看这个数
                let cost = Int(Date().timeIntervalSince(startedAt))
                self.logUI("本次同步耗时 \(cost)s，待办 \(self.openTodos.count) 条 / 日程 \(self.payload?.schedules.count ?? 0) 条")
            }
        }
    }

    // MARK: 派生数据

    /// 按当前范围过滤后的日程
    var visibleSchedules: [ScheduleItem] {
        let all = payload?.schedules ?? []
        return scope == 0 ? all.filter { $0.own } : all
    }

    var myCount: Int { (payload?.schedules ?? []).filter { $0.own }.count }
    var allCount: Int { (payload?.schedules ?? []).count }

    var schedulesByDay: [String: [ScheduleItem]] {
        Dictionary(grouping: visibleSchedules, by: { $0.date })
    }

    var todosByDay: [String: [TodoItem]] {
        Dictionary(grouping: openTodos.filter { !$0.date.isEmpty }, by: { $0.date })
    }

    /// 未完成的待办。日历圆点、逾期计数、「本日」列表、桌面提醒全部用这个口径，
    /// 否则历史完成项会污染今日视图（逾期数越攒越多）
    /// 渲染用的待办：磁盘数据 + 乐观层
    ///
    /// 核心要求是「先让用户看到成功，后台再同步」。所以所有写操作都先改这一层：
    ///   · `optimistic` 覆盖单条（改名/勾选/改期），清掉即回滚
    ///   · `hiddenTodos` 隐藏已删的，清掉即恢复
    ///   · `pendingTodos` 是刚建、还没拿到企业微信 id 的条目
    /// 等脚本回来、`load(force:)` 读到真实数据后再把这些临时层撤掉，界面不会闪。
    var mergedTodos: [TodoItem] {
        var out: [TodoItem] = []
        out.reserveCapacity((payload?.todos.count ?? 0) + pendingTodos.count)
        out.append(contentsOf: pendingTodos)
        for t in (payload?.todos ?? []) where !hiddenTodos.contains(t.todoId) {
            out.append(optimistic[t.todoId] ?? t)
        }
        return out
    }

    var openTodos: [TodoItem] {
        mergedTodos.filter { !$0.finished }.sorted { a, b in
            // 刚建的排最前，让「已经成功」这个感觉立刻成立
            if a.isPending != b.isPending { return a.isPending }
            let da = a.date.isEmpty ? "9999-99-99" : a.date
            let db = b.date.isEmpty ? "9999-99-99" : b.date
            return da < db
        }
    }

    /// 已完成的待办，按完成时间倒序（取数时已限量，不会无限增长）
    var doneTodos: [TodoItem] {
        mergedTodos.filter { $0.finished }
            .sorted { $0.updateTime > $1.updateTime }
    }

    /// 「待办」页当前这一屏
    var todoPage: [TodoItem] { todoFilter == 1 ? doneTodos : openTodos }

    var overdueCount: Int { openTodos.filter { isOverdue($0) }.count }

    func isOverdue(_ t: TodoItem) -> Bool {
        guard !t.date.isEmpty else { return false }
        let now = clock
        if t.deadlineType == "datetime" {
            if let d = parseTime(t.deadline) { return d < now }
        }
        if let d = Fmt.day.date(from: t.date) {
            let end = cal.date(byAdding: .day, value: 1, to: d) ?? d
            return end <= now
        }
        return false
    }

    func dayLoad(_ d: Date) -> (sched: Int, todo: Int, overdue: Bool) {
        let k = dayKey(d)
        let s = schedulesByDay[k]?.count ?? 0
        let ts = todosByDay[k] ?? []
        return (s, ts.count, ts.contains(where: { isOverdue($0) }))
    }

    var selectedSchedules: [ScheduleItem] {
        (schedulesByDay[dayKey(selectedDay)] ?? []).sorted { $0.begin < $1.begin }
    }

    var selectedTodos: [TodoItem] {
        (todosByDay[dayKey(selectedDay)] ?? []).sorted { $0.deadline < $1.deadline }
    }

    var permError: PayloadError? { (payload?.errors ?? []).first { $0.code == "850003" } }
    var authURL: String? { permError?.url }
    var hasAnyData: Bool {
        guard let p = payload else { return false }
        return !p.schedules.isEmpty || !p.todos.isEmpty
    }
    var isDemo: Bool { (payload?.errors ?? []).contains { $0.code == "demo" } }
    var hasStale: Bool {
        guard let p = payload else { return false }
        return !p.schedulesOk || !p.todosOk
    }
}

// MARK: - 主题

enum Theme {
    static let cardRadius: CGFloat = 18
    /// 中国红 #DE2910 —— 主色（日程、今日、选中态）
    static let sched = Color(red: 0.871, green: 0.161, blue: 0.063)
    /// 深红 #A80F25 —— 强调与渐变收口
    static let redDeep = Color(red: 0.659, green: 0.059, blue: 0.145)
    /// 金 #E6A23C —— 待办点缀，红金搭配
    static let todo = Color(red: 0.902, green: 0.635, blue: 0.235)
    /// 暗金 —— 金色文字要压暗才看得清
    static let goldDeep = Color(red: 0.663, green: 0.427, blue: 0.098)
    /// 暗红 —— 逾期警示
    static let warn = Color(red: 0.545, green: 0.047, blue: 0.098)
    static let ok = Color(red: 0.14, green: 0.63, blue: 0.42)
    static let ink = Color(red: 0.11, green: 0.13, blue: 0.17)
    static let inkSoft = Color(red: 0.42, green: 0.45, blue: 0.50)
    /// 宣纸暖白 —— 卡片底，比纯白更有质感
    static let cream = Color(red: 0.996, green: 0.976, blue: 0.949)

    static var redGradient: LinearGradient {
        LinearGradient(colors: [sched, redDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var goldGradient: LinearGradient {
        LinearGradient(colors: [todo, goldDeep], startPoint: .top, endPoint: .bottom)
    }
    /// 红金细线：分隔与顶饰
    static var ribbon: LinearGradient {
        LinearGradient(colors: [redDeep, sched, todo, sched.opacity(0.15)],
                       startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - 自适应缩放

/// 全局缩放系数：以 384pt 宽为基准，随窗口宽度等比变化。
/// 字号与所有固定尺寸统一走它，保证任意缩放档下排版比例与基准版一致。
enum Fnt {
    static let baseWidth: CGFloat = 384
    static let baseHeight: CGFloat = 520
    private(set) static var scale: CGFloat = 1

    /// 限制在 0.8 ~ 2.0，避免极端尺寸下文字过小或过大
    /// 宽度定字号、高度兜底：只看宽度的话，拉成「又宽又扁」时字号会放大到
    /// 内容总高超出窗口，表头直接被切掉（实测 700x700 就丢掉了整个头部）
    static func update(_ width: CGFloat, _ height: CGFloat = 0) {
        guard width > 1 else { return }
        var s = width / baseWidth
        if height > 1 { s = min(s, height / baseHeight) }
        scale = min(max(s, 0.8), 2.0)
    }

    static func s(_ size: CGFloat,
                  _ weight: Font.Weight = .regular,
                  _ design: Font.Design = .default) -> Font {
        // 取整到 0.5pt，避免奇数小数在小字号下发虚
        .system(size: (size * scale * 2).rounded() / 2, weight: weight, design: design)
    }
}

/// 长度缩放：把基准版里的固定尺寸换算到当前缩放档
@inline(__always)
func S(_ v: CGFloat) -> CGFloat { v * Fnt.scale }

// MARK: - 主视图

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var rec: Recorder
    @State private var draft = ""
    /// 新建待办的提醒时间；nil = 不提醒（建无截止时间的待办）
    @State private var whenAt: Date? = nil
    @State private var whenDateOnly = false      // true = 只标日期、不带时刻（企微 type=date）
    @State private var showWhenPicker = false
    @State private var pickWhen = Date()         // 弹层内的临时值，点「确定」才提交
    @State private var pickDateOnly = false
    /// 当前正在改截止时间的待办 id；nil = 面板未打开
    @State private var editingDeadlineFor: String? = nil
    @FocusState private var composerFocused: Bool
    /// 行尾「⋯」正在展开的那条待办 id
    @State private var menuFor: String? = nil
    @State private var renameDraft = ""
    @State private var pendingDelete: TodoItem? = nil

    /// 完整界面（原来的主体）
    private var mainStack: some View {
        VStack(spacing: 0) {
            header
            if let e = store.permError { authBanner(e) }
            calendarBlock
            // 统计条删掉了（2026-11-21 决定）：三个数分别是下面「待办 N」「本日 N」和右侧
            // 「已过期 N」标签的重复播报，白占一行高度。省出来的高度给列表多看一条。
            ribbonDivider
            detailBlock
            footer
        }
    }

    var body: some View {
        mainStack
        // 对齐到顶部：万一内容仍然超出（极端比例），宁可裁底部也不要切掉表头
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            ZStack {
                VisualEffectBackground()
                LinearGradient(colors: [Color.white.opacity(0.72), Color.white.opacity(0.90)],
                               startPoint: .top, endPoint: .bottom)
            }
        )
        // 标题栏是透明的，但 SwiftUI 默认把标题栏那 28pt 当安全区留白，
        // 结果桌面壁纸从顶部漏出来一条（看着像蓝标题栏）。铺满整窗即可
        .ignoresSafeArea(.all)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Color.white.opacity(0.75), lineWidth: 1)
        )
        // 回车兜底：输入法组字/未组字两种情况都由 AppDelegate 的按键监视器发信号
        .onChange(of: store.composerSubmitTick) { _ in submitTodo() }
        .onAppear(perform: openPanelForTest)
        .alert("删除这条待办？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let t = pendingDelete { store.deleteTodo(t) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("「\(pendingDelete?.title ?? "")」会从企业微信里一起删掉，不能撤销。")
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(spacing: 0) {
            // 顶部红金细饰条：压住窗口上沿，别让壁纸漏出来
            Theme.ribbon.frame(height: S(3))
            HStack(alignment: .center, spacing: S(9)) {
                sealBadge
                VStack(alignment: .leading, spacing: 1) {
                    Button(action: backToToday) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(monthTitle).font(Fnt.s(21, .heavy, .rounded))
                                .foregroundColor(Theme.sched)
                            Text(yearTitle)
                                .font(Fnt.s(9.5, .semibold, .rounded))
                                .foregroundColor(Theme.goldDeep)
                                .padding(.horizontal, S(4))
                                .padding(.vertical, S(1))
                                .background(Capsule().fill(Theme.todo.opacity(0.18)))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("回到今天")
                    subtitleRow
                }
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    iconButton("chevron.left") { shiftMonth(-1) }
                    iconButton("chevron.right") { shiftMonth(1) }
                    iconButton(store.refreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise") {
                        store.refresh()
                    }
                    .rotationEffect(.degrees(store.refreshing ? 360 : 0))
                    .animation(store.refreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                               value: store.refreshing)
                    featureMenu
                    iconButton("minus") { store.onHide?() }.help("最小化到程序坞")
                }
            }
            .padding(.horizontal, S(13))
            .padding(.top, S(8))
            .padding(.bottom, S(7))
        }
    }

    /// 标题下那行小字。录制中整行换成「计时 + 停止」——
    /// 这是当时最该被看见的信息，而且直接复用标题那块的横向空间，不挤按钮。
    @ViewBuilder
    private var subtitleRow: some View {
        if rec.isRecording {
            Button { rec.stop() } label: {
                HStack(spacing: S(4)) {
                    Circle().fill(.white).frame(width: S(5), height: S(5))
                    Text("录制中 \(rec.timerText)")
                        .font(Fnt.s(9.5, .bold, .rounded)).monospacedDigit()
                        .foregroundColor(.white)
                    Text("停止")
                        .font(Fnt.s(9.5, .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, S(5)).padding(.vertical, 0)
                        .background(Capsule().fill(Color.white.opacity(0.22)))
                }
                .padding(.horizontal, S(6)).padding(.vertical, S(2))
                .background(Capsule().fill(Theme.redGradient))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("点这里结束录制")
        } else {
            HStack(spacing: 3) {
                Image(systemName: "calendar.badge.clock")
                    .font(Fnt.s(8.5, .semibold))
                    .foregroundColor(Theme.sched.opacity(0.75))
                Text(daySubtitle).font(Fnt.s(10))
                    .foregroundColor(Theme.inkSoft)
                    .lineLimit(1)
            }
        }
    }

    /// 「功能」入口。子功能各自是独立窗口，所以这里只是把它们叫出来，
    /// 不再需要「回到日历」——关掉那个窗口就回来了。
    /// 以后再加能力（邮件摘要、审批）就是往这个菜单里多塞一行，主面板不用再改版式。
    private var featureMenu: some View {
        Menu {
            ForEach(FeaturePane.allCases) { f in
                Button { store.onOpenFeature?(f) } label: {
                    Label(f.title, systemImage: f.icon)
                }
            }
            Divider()
            Button("回到今天") { backToToday() }
            Button("打开数据文件夹") {
                if let u = store.dataURL?.deletingLastPathComponent() {
                    NSWorkspace.shared.open(u)
                }
            }
            Divider()
            Button("隐藏小组件") { store.onHide?() }
            Button("退出书办") { NSApp.terminate(nil) }
        } label: {
            HStack(spacing: S(3)) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: S(8), weight: .semibold))
                Text("功能")
                    .font(Fnt.s(8.5, .semibold))
            }
            .foregroundColor(Theme.goldDeep)
            .padding(.horizontal, S(7))
            .padding(.vertical, S(4))
            .background(Capsule().fill(Theme.todo.opacity(0.16)))
            .overlay(Capsule().stroke(Theme.todo.opacity(0.45), lineWidth: 0.8))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("录屏、记事本等子功能")
    }

    private func backToToday() {
        store.monthAnchor = cal.startOfDay(for: Date())
        store.selectedDay = cal.startOfDay(for: Date())
    }

    /// 印章式标识：中国红方形 + 金边 + 白字
    private var sealBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: S(8), style: .continuous)
                .fill(Theme.redGradient)
                .frame(width: S(29), height: S(29))
                .shadow(color: Theme.redDeep.opacity(0.45), radius: S(3), y: S(1.5))
            RoundedRectangle(cornerRadius: S(8), style: .continuous)
                .strokeBorder(Theme.todo.opacity(0.75), lineWidth: 0.9)
                .frame(width: S(26), height: S(26))
            Text("书")
                .font(Fnt.s(15, .bold, .serif))
                .foregroundColor(.white)
                .offset(y: S(-0.5))
        }
    }

    /// 红金渐变的 1pt 分隔线
    private var ribbonDivider: some View {
        Theme.ribbon
            .frame(height: S(1.2))
            .opacity(0.55)
            .padding(.horizontal, S(12))
            .padding(.top, S(5))   // 统计条没了，金线跟日历格之间补一点呼吸
    }

    private var monthTitle: String {
        let m = cal.component(.month, from: store.monthAnchor)
        return "\(m)月"
    }
    private var yearTitle: String {
        "\(cal.component(.year, from: store.monthAnchor))"
    }
    private var daySubtitle: String {
        let d = store.selectedDay
        let weekday = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][cal.component(.weekday, from: d) - 1]
        let isToday = cal.isDateInToday(d)
        let s = store.selectedSchedules.count
        let t = store.selectedTodos.count
        let prefix = isToday ? "今天 · " : ""
        if s + t == 0 { return "\(prefix)\(cal.component(.month, from: d))月\(cal.component(.day, from: d))日 \(weekday) · 无安排" }
        return "\(prefix)\(cal.component(.month, from: d))月\(cal.component(.day, from: d))日 \(weekday) · \(s) 日程 \(t) 待办"
    }

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(Fnt.s(12, .semibold))
                .foregroundColor(Theme.inkSoft)
                .frame(width: S(22), height: S(22))
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }

    private func shiftMonth(_ delta: Int) {
        if let d = cal.date(byAdding: .month, value: delta, to: store.monthAnchor) {
            store.monthAnchor = cal.startOfDay(for: d)
        }
    }

    // MARK: 授权提示横幅

    private func authBanner(_ e: PayloadError) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Fnt.s(13))
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.hasAnyData ? "部分数据未同步" : "未同步到企微数据")
                    .font(Fnt.s(11.5, .semibold))
                    .foregroundColor(.white)
                Text("\(e.module)授权已过期，需重新授权")
                    .font(Fnt.s(9.5))
                    .foregroundColor(.white.opacity(0.88))
            }
            Spacer(minLength: 0)
            if let u = e.url, let url = URL(string: u) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text("去授权")
                        .font(Fnt.s(10.5, .semibold))
                        .foregroundColor(Theme.warn)
                        .padding(.horizontal, S(9))
                        .padding(.vertical, S(3.5))
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
                .help("在企业微信侧授予机器人「\(e.module)」权限")
            }
        }
        .padding(.horizontal, S(10))
        .padding(.vertical, S(7))
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.warn.opacity(0.92))
        )
        .padding(.horizontal, S(12))
        .padding(.bottom, S(6))
    }

    // MARK: 日历

    private var calendarBlock: some View {
        VStack(spacing: 1) {
            HStack(spacing: 0) {
                ForEach(Array(["一", "二", "三", "四", "五", "六", "日"].enumerated()), id: \.offset) { i, w in
                    Text(w).font(Fnt.s(9, .semibold, .rounded))
                        .foregroundColor(i >= 5 ? Theme.sched.opacity(0.75) : Theme.inkSoft.opacity(0.85))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, S(10))
            .padding(.bottom, S(3))

            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { c in
                        dayCell(rows[r][c])
                    }
                }
                .padding(.horizontal, S(10))
            }
        }
        .padding(.bottom, S(7))
    }

    private var rows: [[Date?]] {
        let cells = monthGrid(store.monthAnchor)
        var out: [[Date?]] = []
        var i = 0
        while i < cells.count {
            let end = min(i + 7, cells.count)
            var row = Array(cells[i..<end])
            while row.count < 7 { row.append(nil) }
            out.append(row)
            i += 7
        }
        return out.isEmpty ? [[nil, nil, nil, nil, nil, nil, nil]] : out
    }

    private func monthGrid(_ anchor: Date) -> [Date?] {
        let comps = cal.dateComponents([.year, .month], from: anchor)
        guard let first = cal.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) else { return [] }
        let weekday = cal.component(.weekday, from: first)
        var leading = weekday - cal.firstWeekday
        if leading < 0 { leading += 7 }
        var cells: [Date?] = Array(repeating: nil, count: leading)
        let days = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        for d in 0..<days {
            cells.append(cal.date(byAdding: .day, value: d, to: first))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    @ViewBuilder
    private func dayCell(_ date: Date?) -> some View {
        if let date = date {
            let load = store.dayLoad(date)
            let isSel = cal.isDate(date, inSameDayAs: store.selectedDay)
            let isToday = cal.isDateInToday(date)
            let inMonth = cal.isDate(date, equalTo: store.monthAnchor, toGranularity: .month)
            let wk = cal.component(.weekday, from: date)
            let isWeekend = wk == 1 || wk == 7
            let busy = load.sched + load.todo > 0

            VStack(spacing: S(1)) {
                ZStack {
                    // 今天：中国红实心球 + 金色外环
                    if isToday {
                        Circle()
                            .fill(Theme.redGradient)
                            .frame(width: S(23), height: S(23))
                            .shadow(color: Theme.sched.opacity(0.45), radius: S(3), y: S(1))
                        Circle()
                            .strokeBorder(Theme.todo.opacity(0.55), lineWidth: 0.8)
                            .frame(width: S(26), height: S(26))
                    } else if isSel {
                        // 选中（非今天）：白底红环
                        Circle().fill(Color.white).frame(width: S(23), height: S(23))
                            .shadow(color: Theme.sched.opacity(0.18), radius: S(2), y: S(0.5))
                        Circle().strokeBorder(Theme.sched, lineWidth: 1.5)
                            .frame(width: S(23), height: S(23))
                    }
                    Text("\(cal.component(.day, from: date))")
                        .font(Fnt.s(12, isToday || isSel ? .bold : (busy ? .semibold : .regular), .rounded))
                        .foregroundColor(
                            isToday ? .white
                                    : (isSel ? Theme.sched
                                             : (inMonth ? (isWeekend ? Theme.redDeep : Theme.ink)
                                                        : Theme.inkSoft.opacity(0.38)))
                        )
                }
                .frame(height: S(23))

                // 事件指示：有日程一颗红点、有待办一颗金点；两种都有时两颗并排
                HStack(spacing: S(2)) {
                    if load.sched > 0 {
                        Circle().fill(isToday ? Color.white.opacity(0.95) : Theme.sched)
                            .frame(width: S(3.2), height: S(3.2))
                    }
                    if load.todo > 0 {
                        Circle().fill(isToday ? Color.white.opacity(0.95)
                                              : (load.overdue ? Theme.warn : Theme.todo))
                            .frame(width: S(3.2), height: S(3.2))
                    }
                }
                .frame(height: S(4.6))
            }
            .frame(maxWidth: .infinity)
            .frame(height: S(32))
            // 只有「选中日期」才铺底；有事件的日子靠加粗数字 + 双色圆点区分，
            // 全部铺米色会把日历刷成一格格的方块，反而看不出重点
            .background(
                RoundedRectangle(cornerRadius: S(7), style: .continuous)
                    .fill(isSel && !isToday ? Theme.sched.opacity(0.07) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: S(7), style: .continuous)
                    .stroke(isSel && !isToday ? Theme.sched.opacity(0.35) : Color.clear, lineWidth: 0.8)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                // 只切换选中日期，不动当前标签页：在「待办」页点日历仍留在待办
                store.selectedDay = cal.startOfDay(for: date)
            }
        } else {
            Color.clear.frame(maxWidth: .infinity).frame(height: S(32))
        }
    }

    // MARK: 明细

    private var detailBlock: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                // 待办排前面（2026-11-21 需求），索引不动，只调显示顺序
                tabButton("待办 \(store.openTodos.count)", index: 1)
                tabButton("本日 \(store.selectedSchedules.count + store.selectedTodos.count)", index: 0)
                Spacer(minLength: 0)
                // 「我的/全部」只影响日程，放到日程页；待办页这个位置给「进行中/已完成」
                if store.tab == 0 { scopeToggle } else { todoFilterToggle }
                // 统计条删掉后，这个标签成了「已过期」唯一的出口，两个 tab 都留着
                if store.overdueCount > 0 && store.todoFilter == 0 {
                    Text("已过期 \(store.overdueCount)")
                        .font(Fnt.s(10, .semibold))
                        .foregroundColor(Theme.warn)
                        .padding(.horizontal, S(6)).padding(.vertical, S(2))
                        .background(Capsule().fill(Theme.warn.opacity(0.12)))
                }
            }
            .padding(.horizontal, S(14))
            .padding(.top, S(10))
            .padding(.bottom, S(6))

            // 新建入口只在「进行中」这一屏出现
            if store.tab == 1 && store.todoFilter == 0 { todoComposer }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if store.tab == 0 {
                        scheduleList
                    } else {
                        todoList
                    }
                }
                .padding(.horizontal, S(14))
                .padding(.bottom, S(10))
            }
            // 下限给得很小：极端「宽而扁」的窗口里先压列表，别让整体撑破窗口
            // （撑破时 VStack 会上下各溢出一点，头部会被切掉）
            .frame(minHeight: S(60), maxHeight: .infinity)
            .clipped()
        }
        .frame(maxHeight: .infinity)
    }

    // 待办输入区：回车即写入企业微信
    private var todoComposer: some View {
        HStack(spacing: 5) {
            TextField("写条待办，回车同步到企业微信", text: $draft)
                .textFieldStyle(.plain)
                .font(Fnt.s(11.5))
                .focused($composerFocused)
                .onSubmit { submitTodo() }
                .padding(.horizontal, S(8))
                .padding(.vertical, S(5))
                .background(RoundedRectangle(cornerRadius: S(7), style: .continuous)
                    .fill(Color.white.opacity(0.95)))
                .overlay(RoundedRectangle(cornerRadius: S(7), style: .continuous)
                    .stroke(composerFocused ? Theme.sched.opacity(0.55) : Theme.sched.opacity(0.13), lineWidth: 1))
                .onChange(of: composerFocused) { focused in
                    if focused { NSApp.activate(ignoringOtherApps: true) }
                }

            Button {
                // 浮窗是 nonactivatingPanel：不激活的话 NSPopover 起不来（实测点了没反应）
                NSApp.activate(ignoringOtherApps: true)
                pickWhen = whenAt ?? defaultWhen()
                pickDateOnly = whenDateOnly
                showWhenPicker = true
            } label: {
                HStack(spacing: 2.5) {
                    Image(systemName: whenAt == nil ? "bell.slash" : "bell.fill")
                        .font(Fnt.s(8, .semibold))
                    Text(whenButtonLabel)
                        .font(Fnt.s(9.5, .semibold))
                }
                .foregroundColor(whenAt == nil ? Theme.inkSoft : .white)
                .padding(.horizontal, S(6))
                .padding(.vertical, S(4))
                .background(
                    Capsule().fill(whenAt == nil ? AnyShapeStyle(Color.black.opacity(0.06))
                                                 : AnyShapeStyle(Theme.redGradient))
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(whenAt == nil ? "设置提醒日期与时间" : "修改提醒时间（当前 \(whenDetailText)）")
            .popover(isPresented: $showWhenPicker, arrowEdge: .bottom) {
                whenPanel(cancelTitle: "不提醒") { date, only in
                    showWhenPicker = false
                    whenAt = date
                    whenDateOnly = only
                }
            }

            Button(action: submitTodo) {
                let empty = draft.trimmingCharacters(in: .whitespaces).isEmpty
                ZStack {
                    Circle()
                        .fill(empty ? AnyShapeStyle(Color.black.opacity(0.06))
                                    : AnyShapeStyle(Theme.redGradient))
                        .frame(width: S(20), height: S(20))
                        .shadow(color: empty ? .clear : Theme.sched.opacity(0.35), radius: S(2), y: S(1))
                    Image(systemName: "arrow.up")
                        .font(Fnt.s(9.5, .black))
                        .foregroundColor(empty ? Theme.inkSoft.opacity(0.45) : .white)
                }
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("同步到企业微信")
        }
        .padding(.horizontal, S(14))
        .padding(.bottom, S(6))
    }

    // MARK: 提醒时间选择（日期 + 时刻），新建与改期共用一套面板

    /// 验收用：启动即自动给第一条可编辑待办打开改期面板，配合 WECAL_SNAP_WINDOWS 拍弹层。
    /// =1 强制「只标日期」；=2 强制带时刻。两版长什么样，靠这个钩子各拍一张对比。
    private func openPanelForTest() {
        let mode = ProcessInfo.processInfo.environment["WECAL_OPEN_PANEL"]
        guard mode == "1" || mode == "2" else { return }
        // 等 1.2 秒：onAppear 比首次 load 早，那时 openTodos 还是空的
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard let t = store.openTodos.first(where: { $0.editable }) else {
                print("OPEN_PANEL 没找到可编辑待办（openTodos=\(store.openTodos.count)）")
                return
            }
            print("OPEN_PANEL 打开「\(t.title)」id=\(t.id) type=\(t.deadlineType)")
            var when = parseTime(t.deadline) ?? defaultWhen()
            if t.deadlineType != "datetime" { when = mergeTime(when, 9, 0) }
            if when < Date() { when = Date().addingTimeInterval(3600) }
            pickWhen = when
            pickDateOnly = (mode == "1")
            // 先激活再置位：nonactivatingPanel 不是 key 窗口时，NSPopover 直接不出现
            // （点鼠标时是系统帮你激活的，脚本模拟就得自己补这一步）
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                editingDeadlineFor = t.id
            }
        }
    }

    /// 弹层里选中的时间是否已经过去。企业微信对过去的截止时间一律拒绝（860033），
    /// 所以要在点「确定」之前就告诉他，而不是等接口报错。
    /// 「只标日期」按整天比：选今天仍然允许（截止今天是有意义的）。
    private var pickWhenPast: Bool {
        if pickDateOnly {
            return Fmt.day.string(from: pickWhen) < Fmt.day.string(from: Date())
        }
        return pickWhen < Date()
    }

    private func whenPanel(cancelTitle: String,
                           onPick: @escaping (Date?, Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: S(9)) {
            Text("提醒时间")
                .font(Fnt.s(9.5, .semibold))
                .foregroundColor(Theme.inkSoft)

            HStack(spacing: 3) {
                ForEach(quickDays, id: \.label) { d in
                    dayChip(d.label, d.day)
                }
            }

            // 勾了「只标日期」就只留日期控件：时刻那块直接消失，改不动也就不会白改。
            // 2026-11-22 收到「修改时间不生效」的反馈，就是在这里改时刻——值被 whenArg 丢弃了。
            DatePicker("", selection: $pickWhen,
                       displayedComponents: pickDateOnly ? [.date] : [.date, .hourAndMinute])
                .datePickerStyle(.compact)
                .labelsHidden()
                .controlSize(.small)
                .environment(\.locale, Locale(identifier: "zh_CN"))

            HStack(spacing: 3) {
                timeChip("09:00", 9, 0)
                timeChip("12:00", 12, 0)
                timeChip("14:00", 14, 0)
                timeChip("18:00", 18, 0)
                timeChip("20:00", 20, 0)
            }

            Button {
                pickDateOnly.toggle()
                // 从「只标日期」切回「带时刻」时，00:00 是 date 类型解析出来的占位值，
                // 继续留着会让人以为时刻被改成了零点，统一补成 09:00
                if !pickDateOnly,
                   cal.component(.hour, from: pickWhen) == 0,
                   cal.component(.minute, from: pickWhen) == 0 {
                    pickWhen = mergeTime(pickWhen, 9, 0)
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: pickDateOnly ? "checkmark.circle.fill" : "circle")
                        .font(Fnt.s(8.5))
                    Text("只标日期，不设时刻")
                        .font(Fnt.s(9))
                }
                .foregroundColor(pickDateOnly ? Theme.todo : Theme.inkSoft)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("企微里显示「当天截止」，不弹到点提醒；要按点提醒就把这个勾去掉")

            Divider().opacity(0.6)

            // 时间已经过去时，企微会直接拒绝（860033），所以在弹层里就把话说明白、
            // 把「确定」禁掉 —— 以前是点了没反应，用户只能得出「没生效」这个结论。
            if pickWhenPast {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill").font(Fnt.s(8))
                    Text(pickDateOnly ? "这个日期已经过去了" : "这个时间已经过去了")
                        .font(Fnt.s(9))
                }
                .foregroundColor(Theme.sched)
            }

            HStack(spacing: 6) {
                Button {
                    onPick(nil, false)
                } label: {
                    Text(cancelTitle).font(Fnt.s(9.5)).foregroundColor(Theme.inkSoft)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Button {
                    onPick(pickWhen, pickDateOnly)
                } label: {
                    Text("确定")
                        .font(Fnt.s(9.5, .semibold))
                        .foregroundColor(pickWhenPast ? Theme.inkSoft : .white)
                        .padding(.horizontal, S(10))
                        .padding(.vertical, S(3))
                        .background(Capsule().fill(pickWhenPast
                                                   ? AnyShapeStyle(Color.black.opacity(0.08))
                                                   : AnyShapeStyle(Theme.redGradient)))
                }
                .buttonStyle(.plain)
                .disabled(pickWhenPast)
                .help(pickWhenPast ? "企业微信不接受过去的时间" : "保存这个时间")
            }
        }
        .padding(S(11))
        .frame(width: S(232))
    }

    /// 快捷日。同一天只留一个：2026-11-22 是周日，「明天」和「下周一」都是 11/23，
    /// 两个胶囊同时变红，看着像 bug（截图反馈里就是这样）。
    private struct QuickDay: Identifiable {
        let label: String
        let day: Date
        var id: String { label }
    }

    private var quickDays: [QuickDay] {
        var out: [QuickDay] = []
        for (label, day) in [("今天", offsetDay(0)), ("明天", offsetDay(1)),
                             ("后天", offsetDay(2)), ("下周一", upcoming(2))] {
            if !out.contains(where: { cal.isDate($0.day, inSameDayAs: day) }) {
                out.append(QuickDay(label: label, day: day))
            }
        }
        return out
    }

    private func dayChip(_ title: String, _ day: Date) -> some View {
        let active = cal.isDate(pickWhen, inSameDayAs: day)
        return Button {
            pickWhen = mergeDay(pickWhen, day)
        } label: {
            Text(title)
                .font(Fnt.s(9, .medium))
                .foregroundColor(active ? .white : Theme.ink)
                .padding(.horizontal, S(6))
                .padding(.vertical, S(3))
                .background(Capsule().fill(active ? AnyShapeStyle(Theme.redGradient)
                                                  : AnyShapeStyle(Color.black.opacity(0.055))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func timeChip(_ title: String, _ h: Int, _ m: Int) -> some View {
        let active = !pickDateOnly
            && cal.component(.hour, from: pickWhen) == h
            && cal.component(.minute, from: pickWhen) == m
        return Button {
            pickWhen = mergeTime(pickWhen, h, m)
            pickDateOnly = false
        } label: {
            Text(title)
                .font(Fnt.s(9, .medium))
                .foregroundColor(active ? .white : Theme.ink)
                .padding(.horizontal, S(5))
                .padding(.vertical, S(3))
                .background(Capsule().fill(active ? AnyShapeStyle(Theme.todo)
                                                  : AnyShapeStyle(Color.black.opacity(0.055))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var whenButtonLabel: String {
        guard let w = whenAt else { return "不提醒" }
        return whenText(w, dateOnly: whenDateOnly)
    }

    private var whenDetailText: String {
        guard let w = whenAt else { return "不提醒" }
        return whenArg(w, dateOnly: whenDateOnly)
    }

    private func whenText(_ d: Date, dateOnly: Bool) -> String {
        let hm = String(format: "%02d:%02d", cal.component(.hour, from: d), cal.component(.minute, from: d))
        if cal.isDateInToday(d) { return dateOnly ? "今天" : "今天 \(hm)" }
        if cal.isDate(d, inSameDayAs: offsetDay(1)) { return dateOnly ? "明天" : "明天 \(hm)" }
        let md = String(format: "%d/%d", cal.component(.month, from: d), cal.component(.day, from: d))
        return dateOnly ? md : "\(md) \(hm)"
    }

    /// add_todo.py 的入参："YYYY-MM-DD" 或 "YYYY-MM-DD HH:MM:SS"
    private func whenArg(_ d: Date, dateOnly: Bool) -> String {
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        guard !dateOnly else { return day }
        return day + String(format: " %02d:%02d:00", c.hour ?? 18, c.minute ?? 0)
    }

    /// 打开弹层时的默认值：日历上选中的那天 18:00；今天已过 18:00 则顺延到下一小时
    private func defaultWhen() -> Date {
        let base = cal.startOfDay(for: store.selectedDay)
        var hour = 18
        if cal.isDateInToday(base),
           Date() >= (cal.date(bySettingHour: 18, minute: 0, second: 0, of: base) ?? base) {
            hour = min(cal.component(.hour, from: Date()) + 1, 23)
        }
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
    }

    private func mergeDay(_ base: Date, _ day: Date) -> Date {
        let d = cal.dateComponents([.year, .month, .day], from: day)
        var c = cal.dateComponents([.hour, .minute, .second], from: base)
        c.year = d.year; c.month = d.month; c.day = d.day
        return cal.date(from: c) ?? day
    }

    private func mergeTime(_ base: Date, _ h: Int, _ m: Int) -> Date {
        var c = cal.dateComponents([.year, .month, .day], from: base)
        c.hour = h; c.minute = m; c.second = 0
        return cal.date(from: c) ?? base
    }

    private func submitTodo() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let when = whenAt.map { whenArg($0, dateOnly: whenDateOnly) }
        store.addTodo(t, deadline: when)
        draft = ""
        whenAt = nil
        whenDateOnly = false
        composerFocused = false
    }

    private var scopeToggle: some View {
        segment(["我的 \(store.myCount)", "全部 \(store.allCount)"],
                active: store.scope,
                helps: ["只看我自己的日历", "包含团队共享日历"]) { store.scope = $0 }
    }

    /// 通用小号分段控件（「我的/全部」与「进行中/已完成」共用一套样式）
    private func segment(_ titles: [String], active: Int, helps: [String] = [],
                         select: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<titles.count, id: \.self) { i in
                let on = active == i
                Button {
                    select(i)
                } label: {
                    Text(titles[i])
                        .font(Fnt.s(9.5, on ? .semibold : .regular))
                        .foregroundColor(on ? Theme.ink : Theme.inkSoft)
                        .padding(.horizontal, S(6))
                        .padding(.vertical, S(2.5))
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(on ? Color.white : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(i < helps.count ? helps[i] : "")
            }
        }
        .padding(S(1.5))
        .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous).fill(Color.black.opacity(0.06)))
    }

    /// 「待办」页的二级筛选：进行中 / 已完成
    private var todoFilterToggle: some View {
        segment(["进行中 \(store.openTodos.count)", "已完成 \(store.doneTodos.count)"],
                active: store.todoFilter,
                helps: ["未完成的待办", "已完成的待办（可重新打开）"]) { store.todoFilter = $0 }
    }

    private func tabButton(_ title: String, index: Int) -> some View {
        let active = store.tab == index
        return Button {
            store.tab = index
        } label: {
            Text(title)
                .font(Fnt.s(11, active ? .semibold : .medium))
                .foregroundColor(active ? .white : Theme.inkSoft)
                .padding(.horizontal, S(9))
                .padding(.vertical, S(4))
                .background(
                    Capsule().fill(active ? AnyShapeStyle(Theme.redGradient) : AnyShapeStyle(Color.black.opacity(0.05)))
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var scheduleList: some View {
        if store.selectedSchedules.isEmpty && store.selectedTodos.isEmpty {
            emptyHint(store.permError != nil ? "授权后点 ↻ 同步真实日程" : "这一天没有安排")
        } else {
            // 待办优先：同一天里待办排在日程前面
            ForEach(store.selectedTodos) { t in
                todoRow(t)
            }
            ForEach(store.selectedSchedules) { s in
                scheduleRow(s)
            }
        }
    }

    private func scheduleRow(_ s: ScheduleItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 1) {
                Text(s.allDay ? "全天" : Fmt.hhmm.string(from: parseTime(s.begin) ?? Date()))
                    .font(Fnt.s(10.5, .semibold, .rounded))
                    .foregroundColor(Theme.sched)
                if !s.allDay, let e = parseTime(s.end) {
                    Text(Fmt.hhmm.string(from: e))
                        .font(Fnt.s(9.5, .regular, .rounded))
                        .foregroundColor(Theme.inkSoft)
                }
            }
            .frame(width: S(38), alignment: .leading)

            RoundedRectangle(cornerRadius: S(1.6), style: .continuous)
                .fill(s.isMeeting ? AnyShapeStyle(Theme.redGradient)
                                  : AnyShapeStyle(Theme.sched.opacity(0.58)))
                .frame(width: S(3))
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(s.subject)
                        .font(Fnt.s(12, .semibold))
                        .foregroundColor(Theme.ink)
                        .lineLimit(1)
                    if s.isMeeting {
                        tag("会", Theme.sched)
                    }
                    if !s.repeatLabel.isEmpty {
                        // 重复日程用金色标签，保持红金两色体系（绿色在这里太跳）
                        tag(s.repeatLabel, Theme.goldDeep)
                    }
                }
                let meta = metaLine(s)
                if !meta.isEmpty {
                    Text(meta)
                        .font(Fnt.s(10))
                        .foregroundColor(Theme.inkSoft)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, S(6))
        .padding(.horizontal, S(7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: S(8), style: .continuous)
                .fill(Theme.cream.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: S(8), style: .continuous)
                .stroke(Theme.sched.opacity(0.07), lineWidth: 0.8)
        )
    }

    private func metaLine(_ s: ScheduleItem) -> String {
        var parts: [String] = []
        if !s.own, !s.calendar.isEmpty {
            let calName = s.calendar.replacingOccurrences(of: "的日历", with: "")
            // 日历主人同时出现在参与人里就不重复显示
            if !s.attendees.map(shortName).contains(calName) {
                parts.append(calName)
            }
        }
        if !s.room.isEmpty { parts.append(s.room) }
        if !s.location.isEmpty { parts.append(s.location) }
        if !s.attendees.isEmpty { parts.append(s.attendees.prefix(3).map(shortName).joined(separator: "、")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var todoList: some View {
        let items = store.todoPage
        if items.isEmpty {
            emptyHint(store.todoFilter == 1 ? "还没有已完成的待办" : "没有进行中的待办")
        } else {
            ForEach(items) { t in
                todoRow(t)
            }
        }
    }

    /// 行尾「⋯」：改标题 + 删除
    private func todoMenu(_ t: TodoItem) -> some View {
        Button {
            // 浮窗是 nonactivatingPanel，不激活的话 NSPopover 起不来（同提醒时间面板）
            NSApp.activate(ignoringOtherApps: true)
            renameDraft = t.title
            menuFor = t.todoId
        } label: {
            Image(systemName: "ellipsis")
                .font(Fnt.s(9.5, .bold))
                .foregroundColor(Theme.inkSoft.opacity(0.6))
                .frame(width: S(15), height: S(16))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t.editable ? "编辑标题 / 删除这条待办" : "为什么这条改不了？")
        .popover(isPresented: Binding(get: { menuFor == t.todoId },
                                     set: { if !$0 { menuFor = nil } }),
                 arrowEdge: .bottom) {
            editPanel(t)
        }
    }

    private func editPanel(_ t: TodoItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if t.editable {
                Text("编辑待办")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                TextField("标题", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { commitRename(t) }
                HStack(spacing: 10) {
                    Button("取消") { menuFor = nil }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Button("保存") { commitRename(t) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Divider()
                Button {
                    menuFor = nil
                    pendingDelete = t
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash").font(.system(size: 10, weight: .semibold))
                        Text("删除这条待办").font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundColor(Theme.sched)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // 没有权限的也留入口并说清原因：藏起来只会让人以为功能没做
                Text("这条改不了")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("它由「\(t.creator.isEmpty ? "你在企微客户端" : t.creator)」创建。企业微信只允许创建者本人改删（接口返回 860024），机器人建的待办才能在这里改。要改这条请到企微客户端。")
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("知道了") { menuFor = nil }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(width: t.editable ? 208 : 236)
    }

    private func commitRename(_ t: TodoItem) {
        let clean = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        menuFor = nil
        store.renameTodo(t, to: clean)
    }

    private func todoRow(_ t: TodoItem) -> some View {
        let done = t.finished
        // 已完成的不算逾期：结掉了就只是历史，别再给它套红
        let overdue = !done && store.isOverdue(t)
        let isToday = t.date == dayKey(store.clock)
        return HStack(alignment: .top, spacing: S(7)) {
            // 左侧状态竖条：红=待办在身、深红=逾期、淡灰=已办结
            RoundedRectangle(cornerRadius: S(1.6), style: .continuous)
                .fill(done ? AnyShapeStyle(Color.black.opacity(0.10))
                           : AnyShapeStyle(overdue ? AnyShapeStyle(Theme.warn)
                                                   : AnyShapeStyle(Theme.redGradient)))
                .frame(width: S(3))
                .frame(maxHeight: .infinity)

            // 勾选框：没勾 = 标记完成；已勾 = 重新打开（企微完成不可逆，走删旧建新）
            Button {
                if done { store.reopenTodo(t) } else { store.finishTodo(t) }
            } label: {
                ZStack {
                    if done {
                        Circle().fill(Theme.goldGradient).frame(width: S(14), height: S(14))
                            .shadow(color: Theme.todo.opacity(0.5), radius: S(2), y: S(0.5))
                        Image(systemName: "checkmark")
                            .font(Fnt.s(7.5, .black))
                            .foregroundColor(.white)
                    } else {
                        Circle()
                            .strokeBorder(overdue ? Theme.warn
                                                  : (t.editable ? Theme.sched
                                                                : Theme.inkSoft.opacity(0.38)),
                                          lineWidth: 1.5)
                            .frame(width: S(14), height: S(14))
                            .background(Circle().fill(Color.white.opacity(t.editable ? 0.9 : 0.45))
                                .frame(width: S(14), height: S(14)))
                    }
                }
                .frame(width: S(18), height: S(18))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(done
                  ? (t.editable ? "点一下重新打开（企微里换成一条新的未完成待办）"
                                : "已完成 · 这条是企微客户端建的，撤销请到客户端操作")
                  : (t.editable ? "标记完成，同步到企业微信"
                                : "这条由你在企微创建，机器人无权修改"))

            VStack(alignment: .leading, spacing: 2) {
                Text(t.title)
                    .font(Fnt.s(12, .medium))
                    .foregroundColor(done ? Theme.inkSoft.opacity(0.7) : Theme.ink)
                    .strikethrough(done, color: Theme.inkSoft.opacity(0.65))
                    .lineLimit(2)
                HStack(spacing: 5) {
                    deadlinePill(t, overdue: overdue, isToday: isToday)
                    if done, let when = finishedLabel(t) {
                        Text("完成 " + when)
                            .font(Fnt.s(9))
                            .foregroundColor(Theme.goldDeep.opacity(0.9))
                    }
                    if !t.source.isEmpty {
                        Text(t.source)
                            .font(Fnt.s(9))
                            .foregroundColor(Theme.inkSoft.opacity(0.8))
                    }
                    if !t.followers.isEmpty {
                        Text(t.followers.prefix(2).map(shortName).joined(separator: "、"))
                            .font(Fnt.s(9))
                            .foregroundColor(Theme.inkSoft.opacity(0.8))
                            .lineLimit(1)
                    }
                }
            }
            // 已完成的给一个明面的「重新打开」入口：勾选框太小，怕他找不到
            if done && t.editable {
                Button {
                    store.reopenTodo(t)
                } label: {
                    HStack(spacing: 2.5) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(Fnt.s(7.5, .bold))
                        Text("重新打开").font(Fnt.s(9, .semibold))
                    }
                    .foregroundColor(Theme.goldDeep)
                    .padding(.horizontal, S(5))
                    .padding(.vertical, S(2.5))
                    .background(Capsule().fill(Theme.todo.opacity(0.16)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("新建一条同样的未完成待办，并删掉这条已完成记录")
            }
            Spacer(minLength: 0)
            // 正在后台同步的：行尾给个小转圈，其余情况显示「⋯」入口
            if store.syncingIds.contains(t.todoId) {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: S(14), height: S(14))
                    .help("正在同步到企业微信")
            } else if t.isPending {
                Text("同步中")
                    .font(Fnt.s(9, .semibold))
                    .foregroundColor(Theme.goldDeep)
            } else {
                // 改不了的也留入口（面板里说清原因），否则会以为功能没做
                todoMenu(t)
            }
        }
        .padding(.vertical, S(5))
        .padding(.horizontal, S(7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: S(8), style: .continuous)
                .fill(done ? Color.black.opacity(0.025)
                           : (overdue ? Theme.warn.opacity(0.06) : Theme.cream.opacity(0.92)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: S(8), style: .continuous)
                .stroke(overdue ? Theme.warn.opacity(0.20) : Theme.sched.opacity(0.07), lineWidth: 0.8)
        )
    }

    /// 截止时间胶囊：点开「日期 + 时刻」面板，确定即回写企业微信
    private func deadlinePill(_ t: TodoItem, overdue: Bool, isToday: Bool) -> some View {
        let done = t.finished
        // 已完成的不再说「已逾期」——它已经结掉了，只把原截止日标出来
        let label = done
            ? (t.date.isEmpty ? "无截止" : "原截止 " + shortDate(t.date))
            : (deadlineLabel(t, overdue: overdue, isToday: isToday) ?? "无截止")
        return Button {
            NSApp.activate(ignoringOtherApps: true)
            // 过期的那条，默认给「现在 +1 小时」而不是原来那个过去的时刻——
            // 否则点开先看到一片灰（确定键置灰+黄三角），还得多点两下才挑到能用的时间
            var when = parseTime(t.deadline) ?? defaultWhen()
            // 只标日期的待办，deadline 解析出来是当天 00:00；面板里摆个 00:00 没意义，
            // 统一抬到 09:00（他要改时刻时也是从 09:00 起步，不是从零点）
            if t.deadlineType != "datetime" { when = mergeTime(when, 9, 0) }
            if when < Date() { when = Date().addingTimeInterval(3600) }
            pickWhen = when
            pickDateOnly = t.deadlineType != "datetime"
            editingDeadlineFor = t.id
        } label: {
            HStack(spacing: 2.5) {
                Text(label)
                    .font(Fnt.s(9.5, .semibold))
                    .foregroundColor(done ? Theme.inkSoft.opacity(0.65)
                                          : (overdue ? Theme.warn : (isToday ? Theme.todo : Theme.inkSoft)))
                if t.editable && !done {
                    Image(systemName: "chevron.down")
                        .font(Fnt.s(6, .bold))
                        .foregroundColor(Theme.inkSoft.opacity(0.55))
                }
            }
            .padding(.horizontal, S(4))
            .padding(.vertical, S(1.5))
            .background(RoundedRectangle(cornerRadius: S(4))
                .fill(done ? Color.black.opacity(0.025)
                           // 过期用淡红底，别再借用琥珀色——琥珀在别处代表「今天要办」
                           : (overdue ? Theme.warn.opacity(0.13)
                                      : (t.editable ? Theme.todo.opacity(0.14)
                                                    : Color.black.opacity(0.025)))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done || !t.editable)
        .help(t.editable ? "修改截止时间，同步到企业微信"
                         : "这条由你在企微创建，机器人无权修改")
        .popover(isPresented: Binding(
            get: { editingDeadlineFor == t.id },
            set: { if !$0 { editingDeadlineFor = nil } }),
            arrowEdge: .bottom) {
            whenPanel(cancelTitle: "清除截止") { date, only in
                editingDeadlineFor = nil
                if let d = date {
                    store.setTodoDeadline(t, whenArg(d, dateOnly: only))
                } else {
                    store.setTodoDeadline(t, "none")
                }
            }
        }
    }

    /// 从明天起最近的某个星期（weekday: 1=周日 … 7=周六）
    private func upcoming(_ target: Int) -> Date {
        let wd = cal.component(.weekday, from: Date())
        var d = (target - wd + 7) % 7
        if d <= 0 { d += 7 }
        return offsetDay(d)
    }

    private func offsetDay(_ days: Int) -> Date {
        cal.date(byAdding: .day, value: days, to: Date()) ?? Date()
    }

    /// 改期/新建统一交给 whenPanel 产出精确时刻，这里不再做「默认 18:00」的推算

    /// 已完成待办的完成时刻（企微返回的 update_time）：今天/昨天显示到分钟，更早的只显示日期
    private func finishedLabel(_ t: TodoItem) -> String? {
        guard t.updateTime.count >= 16 else { return nil }
        let day = String(t.updateTime.prefix(10))
        let hm = String(t.updateTime.dropFirst(11).prefix(5))
        if day == dayKey(store.clock) { return "今天 " + hm }
        if day == dayKey(cal.date(byAdding: .day, value: -1, to: store.clock) ?? store.clock) { return "昨天 " + hm }
        return shortDate(day)
    }

    private func deadlineLabel(_ t: TodoItem, overdue: Bool, isToday: Bool) -> String? {
        guard !t.date.isEmpty else { return nil }        // 带时刻的截止时间要在标签里露出来，否则「今天 15:30」和「今天 23:59」看起来一样
        let timePart = (t.deadlineType == "datetime" && t.deadline.count >= 16)
            ? " " + String(t.deadline.dropFirst(11).prefix(5)) : ""
        // 2026-11-22 需求：过期就直说「已过期」。原来写「已逾期 · 11/21 17:43」，
        // 23:30 了还挂着 17:43 和当天日期，看上去像「今天还没到」——这是他要改的点。
        if overdue {
            // 当天过期的只留结论；跨天的补一个日期，好知道拖了多久
            return t.date == Fmt.day.string(from: store.clock) ? "已过期" : "已过期 · " + shortDate(t.date)
        }
        if isToday { return "今天截止" + timePart }
        let days = daysFromToday(t.date)
        if days == 1 { return "明天截止" + timePart }
        if days > 1 && days <= 7 { return "\(days) 天后 · \(shortDate(t.date))" + timePart }
        return shortDate(t.date) + timePart
    }

    private func shortDate(_ s: String) -> String {
        guard s.count == 10 else { return s }
        let parts = s.split(separator: "-")
        if parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) { return "\(m)/\(d)" }
        return s
    }

    private func daysFromToday(_ s: String) -> Int {
        guard let d = Fmt.day.date(from: s) else { return 0 }
        return cal.dateComponents([.day], from: cal.startOfDay(for: store.clock), to: d).day ?? 0
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Fnt.s(8.5, .semibold))
            .foregroundColor(color)
            .padding(.horizontal, S(4))
            .padding(.vertical, S(1))
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func emptyHint(_ text: String) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(Theme.todo.opacity(0.14)).frame(width: S(30), height: S(30))
                    Image(systemName: "checkmark")
                        .font(Fnt.s(13, .semibold))
                        .foregroundColor(Theme.goldDeep.opacity(0.85))
                }
                Text(text).font(Fnt.s(11)).foregroundColor(Theme.inkSoft)
            }
            .padding(.vertical, S(22))
            Spacer()
        }
    }

    // MARK: 底部状态

    private var footer: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(store.isDemo ? Theme.warn : (store.hasStale ? Theme.todo : Theme.ok))
                .frame(width: S(5), height: S(5))
            // 写失败必须显眼：以前错误提示和普通状态一个颜色、6 秒就没，等于没提示
            Text(footerText)
                .font(Fnt.s(9.5, store.footerIsError(store.statusText) ? .bold : .regular))
                .foregroundColor(store.footerIsError(store.statusText) ? Theme.sched : Theme.inkSoft)
                .lineLimit(1)
            Spacer(minLength: 0)
            // 这里原来挂着「笔记」「录屏」两颗换页胶囊。子功能拆成独立窗口之后，
            // 底栏就只该干底栏的事：报同步状态。入口在顶部那颗「功能」。
        }
        .padding(.horizontal, S(16))
        .padding(.vertical, S(7))
        .background(Theme.cream.opacity(0.92))
        .overlay(alignment: .top) { Theme.ribbon.frame(height: S(1)).opacity(0.45) }
    }

    private var footerText: String {
        if !store.statusText.isEmpty { return store.statusText }
        if let e = (store.payload?.errors ?? []).first(where: { $0.code == "850003" }) {
            return "\(e.module)权限已过期 · 授权后点 ↻ 刷新"
        }
        if store.isDemo { return "示例数据 · 授权后点 ↻ 拉取真实日程" }
        guard let p = store.payload else { return "未加载数据" }
        let t = p.generatedAt.count >= 16 ? String(p.generatedAt.dropFirst(11).prefix(5)) : p.generatedAt
        let flag = store.hasStale ? "（部分模块沿用旧数据）" : ""
        return "已同步 \(t)\(flag)"
    }
}

// MARK: - 毛玻璃背景

/// 全窗口铺满的宿主视图：把标题栏带来的 28pt 安全区归零，
/// 否则卡片顶部会空出一条，桌面壁纸透进来像蓝色标题栏
final class BleedHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 可见区尺寸的中转站。windowWillResize 必须在非隔离上下文里同步返回夹紧后的尺寸，
/// 却读不到 MainActor 隔离的 NSWindow.screen —— 由主线程写、它读。
/// AppKit 的窗口回调本来就都在主线程，所以 @unchecked 是安全的。
final class VisibleArea: @unchecked Sendable {
    static let shared = VisibleArea()
    var frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    /// 每个窗口自己的宽高上下限。windowWillResize 在非隔离上下文里跑，
    /// 读不到 MainActor 上的窗口对象，只能靠这张表（主线程写、主线程读）。
    var limits: [ObjectIdentifier: (min: NSSize, max: NSSize)] = [:]
}

// MARK: - 应用入口

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 听录用例每一步的答复：还没到点 / 成了 / 不成。
///
/// 「还没到点」和「条件不满足」必须分开。混成一个 Bool 的话，「真坏了」和「慢一点」
/// 长得一模一样，用例只能靠超时假失败 —— 那种红没人看得懂是哪儿坏了。
enum ListenStep {
    case wait
    case ok(String)
    case bad(String)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: Panel!
    let store = Store()
    /// 录屏引擎。整个 app 一份，面板、悬浮条、底栏都读它。
    let recorder = Recorder()
    /// 记事本数据。同样全 app 一份：面板负责画，落盘与树结构都在它里面。
    let notes = NoteStore()
    /// 听录引擎。也全 app 一份，而且**故意不跟着窗口走** ——
    /// 关掉听录窗声音要继续放（边听录音边干活才是这个功能的用法），
    /// 所以它不能是 AudioPanel 的 @StateObject，只能挂在这里。
    let audio = AudioBoard()
    let width: CGFloat = 384
    let height: CGFloat = 520
    /// 可缩放范围（窗口 frame 尺寸），与 Fnt 的 0.8~2.0 缩放档对齐。
    /// NSWindowDelegate 的回调在非隔离上下文里，这几个常量也被它引用，
    /// 所以显式 nonisolated（Swift 6 严格并发下不加就是编译错误）
    nonisolated static let minW: CGFloat = 320
    nonisolated static let maxW: CGFloat = 768
    nonisolated static let minH: CGFloat = 430
    nonisolated static let maxH: CGFloat = 1040

    /// 尺寸上限要再被屏幕可见区夹一道。之前只夹 maxW/maxH（768/1040），
    /// 于是在 1440×900 这种屏上能把窗口拉得比可见区还高（顶部压在菜单栏底下）。
    nonisolated static func fitToScreen(_ f: NSRect, _ vf: NSRect) -> NSRect {
        var g = f
        // 上限 = maxW 与「屏幕可见区」里较小的那个，但不能低于下限本身
        let upperW = max(minW, min(maxW, vf.width))
        let upperH = max(minH, min(maxH, vf.height))
        g.size.width = min(max(f.width, minW), upperW)
        g.size.height = min(max(f.height, minH), upperH)
        g.origin.x = min(max(g.origin.x, vf.minX), max(vf.minX, vf.maxX - g.width))
        g.origin.y = min(max(g.origin.y, vf.minY), max(vf.minY, vf.maxY - g.height))
        return g
    }

    // MARK: 窗口尺寸持久化（每个窗口一个 key）

    private static let frameKey = "wecal.frame"
    /// 窗口 → 存档 key。三个窗口各记各的，互不干扰。
    /// 键用 ObjectIdentifier 而不是 windowNumber：后者在窗口上屏前是 0，会撞。
    private var frameKeys: [ObjectIdentifier: String] = [:]
    /// 窗口 → 落盘防抖任务。拖动三个窗口不能共用一个 work item
    private var saveWorks: [ObjectIdentifier: DispatchWorkItem] = [:]

    private func frameKey(of w: NSWindow) -> String {
        frameKeys[ObjectIdentifier(w)] ?? Self.frameKey
    }

    /// 记住某个窗口的位置/大小
    func saveFrame(_ w: NSWindow) {
        let f = w.frame
        // 太小的不存（拖到极限时中间帧可能是 1×1）
        guard f.width > 120, f.height > 120 else { return }
        UserDefaults.standard.set(NSStringFromRect(f), forKey: frameKey(of: w))
    }

    func saveAllFrames() {
        for w in ([panel] + featurePanels.values).compactMap({ $0 }) { saveFrame(w) }
    }

    /// 拖动/缩放会连续回调，落盘推迟 0.6 秒，避免每次 mouseDragged 都写一遍
    func scheduleSaveFrame(_ w: NSWindow) {
        let n = ObjectIdentifier(w)
        saveWorks[n]?.cancel()
        let item = DispatchWorkItem { [weak self, weak w] in
            guard let self, let w else { return }
            self.saveFrame(w)
        }
        saveWorks[n] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    /// 恢复窗口位置/大小。没有存档时：找得到参照窗口就挨着它摆，否则在屏幕上居中
    private func restoreFrame(_ p: NSWindow, key: String, fallback: NSSize, near anchor: NSRect? = nil) {
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 第二个来源是旧版本的 NSWindow autosave 键：尺寸正常就继承一次（只对主面板有意义）
        var sources = [UserDefaults.standard.string(forKey: key)]
        if key == Self.frameKey {
            sources.append(UserDefaults.standard.string(forKey: "NSWindow Frame WeComCalendarWidget"))
        }
        for s in sources.compactMap({ $0 }) {
            var f = NSRectFromString(s)
            guard f.width > 120, f.height > 120 else { continue }
            // 恢复时也走一遍屏幕夹紧：老存档可能是「比可见区还高」的尺寸
            f = Self.fitToScreen(f, vf)
            // 上下限也夹一道：上下限是会变的（比如录屏窗从 420 宽改成 620），
            // 老存档一旦小于新下限，窗口就会以一个不该存在的尺寸出现
            if let lim = VisibleArea.shared.limits[ObjectIdentifier(p)] {
                let w = min(max(f.width, lim.min.width), lim.max.width)
                let h = min(max(f.height, lim.min.height), lim.max.height)
                if w != f.width { f.origin.x = min(f.origin.x, vf.maxX - w) }
                if h != f.height { f.origin.y = max(f.origin.y, vf.minY) }
                f.size = NSSize(width: w, height: h)
            }
            p.setFrame(f, display: false)
            return
        }
        // 无存档
        if let a = anchor {
            // 摆在参照窗口右侧；右边放不下就摆左侧；再不行居中
            let gap: CGFloat = 12
            var x = a.maxX + gap
            if x + fallback.width > vf.maxX { x = a.minX - gap - fallback.width }
            if x < vf.minX { x = vf.midX - fallback.width / 2 }
            var y = min(a.maxY - fallback.height, vf.maxY - fallback.height)
            y = max(y, vf.minY)
            p.setFrame(NSRect(x: x, y: y, width: fallback.width, height: fallback.height), display: false)
        } else {
            p.setFrameOrigin(NSPoint(x: vf.maxX - fallback.width - 20, y: vf.maxY - fallback.height - 12))
            p.setContentSize(fallback)
        }
    }


    // MARK: 窗口工厂

    /// 书办所有窗口共用一套外壳：透明背景、隐藏红绿灯、可拖背景移动、跟着切桌面。
    /// 区别只在内容、尺寸和存档 key。
    private func makePanel<Content: View>(title: String,
                                          frameKey: String,
                                          size: NSSize,
                                          min: NSSize,
                                          max: NSSize,
                                          @ViewBuilder content: () -> Content) -> Panel {
        let host = BleedHostingView(rootView: content())
        host.frame = NSRect(origin: .zero, size: size)
        let p = Panel(contentRect: host.frame,
                      styleMask: [.titled, .resizable, .miniaturizable, .nonactivatingPanel, .fullSizeContentView],
                      backing: .buffered,
                      defer: false)
        p.delegate = self
        p.title = title          // 标题栏是隐的，只用于内部识别
        // 关掉只是隐藏：窗口对象留着，再打开时滚动位置、选中的笔记都还在原样
        p.isReleasedWhenClosed = false
        host.autoresizingMask = [.width, .height]
        // 关键：不让 SwiftUI 内容的固有尺寸反过来当窗口下限，
        // 否则放大档下内容会顶住窗口，宽而扁的形态就缩不出来
        host.sizingOptions = []
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        host.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        host.setContentHuggingPriority(.defaultLow, for: .horizontal)
        host.setContentHuggingPriority(.defaultLow, for: .vertical)
        p.contentMinSize = min
        p.contentMaxSize = max
        p.minSize = min
        p.maxSize = max
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        // macOS 26 的玻璃标题栏是盖在内容之上、还带系统蓝调的，
        // 只设 titlebarAppearsTransparent 挡不住，直接把标题栏容器整块藏掉
        if let tb = p.standardWindowButton(.closeButton)?.superview?.superview {
            tb.isHidden = true
        }
        p.isMovableByWindowBackground = true
        // 默认普通层级：可被其他窗口遮挡，不强制置顶
        p.isFloatingPanel = false
        p.level = .normal
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = host
        // 挂个身份牌：录屏窗要靠它认出「自己那一扇现在在不在屏幕上」，
        // 决定要不要每两秒去盘一遍成片目录（见 RecordPanel.paneIsOpen）。
        // 不能拿标题认人 —— 标题是内部识别用的自由字符串，改起来没有约束。
        p.identifier = NSUserInterfaceItemIdentifier(frameKey)
        frameKeys[ObjectIdentifier(p)] = frameKey
        VisibleArea.shared.limits[ObjectIdentifier(p)] = (min: min, max: max)
        return p
    }

    // MARK: 子功能窗口

    /// 已建出来的子功能窗口。关掉只是 orderOut，引用留着 —— 再打开时状态还在。
    private var featurePanels: [Int: Panel] = [:]

    func featurePanel(_ f: FeaturePane) -> Panel? { featurePanels[f.rawValue] }

    /// 叫出子功能窗口。已经开着就只提到前面，不重建 —— 重建会丢当前选中项和滚动位置。
    @discardableResult
    func openFeature(_ f: FeaturePane, front: Bool = true) -> Panel {
        if let p = featurePanels[f.rawValue] {
            if front {
                if p.isMiniaturized { p.deminiaturize(nil) }
                p.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return p
        }
        let size = f.defaultSize
        let p = makePanel(title: f.panelName,
                          frameKey: f.frameKey,
                          size: size,
                          min: f.minSize,
                          max: f.maxSize) {
            // 外面这层 FeatureShell 负责铺满不透明的底 —— 窗口是透明的，
            // 少了它卡片之间的缝就直通桌面（2026-11-23 修）
            FeatureShell {
                // 三个子功能各一扇窗，按 FeaturePane 分发。
                // ⚠️ 别再写成 `if f == .record { … } else { … }` 那种两分支：
                // 加第三种子功能时它会静默把新窗当成第二种画（菜单同理，见 action(for:)）
                Group {
                    switch f {
                    case .record: RecordPanel()
                    case .notes:  NotePanel()
                    case .audio:  AudioPanel()
                    }
                }
                .environmentObject(store)
                .environmentObject(recorder)
                .environmentObject(notes)
                .environmentObject(audio)
                .environment(\.closeFeaturePane, { [weak self] in self?.closeFeature(f) })
            }
        }
        // 第一次打开摆在主面板右边；摆不下就左边，再不行居中。之后按存档恢复
        restoreFrame(p, key: f.frameKey, fallback: size, near: panel?.frame)
        p.sharingType = recorder.isRecording ? .none : .readOnly
        if store.pinned { p.level = .floating; p.isFloatingPanel = true }
        featurePanels[f.rawValue] = p
        if front {
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        store.logUI("打开\(f.title)窗口 \(Int(p.frame.width))×\(Int(p.frame.height))")
        return p
    }

    func closeFeature(_ f: FeaturePane) {
        guard let p = featurePanels[f.rawValue] else { return }
        // 笔记的正文是 0.5 秒防抖落盘的，窗一藏 onDisappear 不一定来，这里补一刀
        if f == .notes { notes.saveNow() }
        // 听录**故意不在这里停播放**：关窗继续放才是这个功能的用法（边听录音边干活）。
        // 会真的把声音掐掉的只有一处 —— 开始录屏，因为外放会被麦克风收进成片。
        // 但**录音必须收尾**：窗一关，录音台就看不见了，还在录就是偷偷录 —— 录到的存下来再停。
        if f == .audio { audio.yieldRecording(to: "关闭听录窗口") }
        saveFrame(p)
        p.orderOut(nil)
        let tail = (f == .audio && audio.state.isBusy) ? "（播放继续）" : ""
        store.logUI("关闭\(f.title)窗口\(tail)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 验收钩子：记事本数据层的用例表，临时目录里跑，不建窗口
        if ProcessInfo.processInfo.environment["WECAL_NOTES_TEST"] == "1" {
            NoteStore.runSelfTest()   // 内部 exit(0/1)，不返回
            return
        }
        NSApp.setActivationPolicy(.regular)
        setupMainMenu()

        // 回调要在建窗口之前接好：SwiftUI 的 onAppear 可能在面板第一次上屏的那一刻就触发
        // （录屏页一出现就会登记授权），接晚了那几条日志会丢。
        recorder.onLog = { [weak self] line in self?.store.logUI(line) }
        recorder.onRelaunch = { [weak self] in
            guard let self else { return }
            // 记下是从哪个窗口点的重启：回来要把它原样再开出来，否则看着像「没重启」
            let key = NSApp.keyWindow
            let pane = self.featurePanels.first { $0.value === key }.flatMap { FeaturePane(rawValue: $0.key) }
            self.store.markRelaunch(from: pane)
        }

        // 记事本要先定好目录再建窗口：面板一上屏就会读树，
        // 配晚了第一帧会显示「还没有笔记」，看着像数据丢了。
        notes.configure(projectDir: store.projectDir)
        // 听录同理：上屏就要看到上次的曲目列表（而且读列表时顺手就把不存在的文件剔掉了）
        audio.configure(projectDir: store.projectDir)
        audio.onLog = { [weak self] line in self?.store.logUI(line) }

        let p = makePanel(title: "main", frameKey: Self.frameKey,
                          size: NSSize(width: width, height: height),
                          min: NSSize(width: Self.minW, height: Self.minH),
                          max: NSSize(width: Self.maxW, height: Self.maxH)) {
            ContentView()
                .environmentObject(store)
                .environmentObject(recorder)
                .environmentObject(notes)
        }

        // 只有首次启动（无历史尺寸）才用默认尺寸；否则保留用户拖拽后的宽高。
        // 尺寸自己存（用户默认值 wecal.frame），不用 NSWindow 的 autosave ——
        // autosave 在每次 frame 变化时都会写，保存时机完全不受控。
        restoreFrame(p, key: Self.frameKey, fallback: NSSize(width: width, height: height))
        // 验收用钩子：WECAL_SIZE="480x700" 直接指定内容尺寸（仅调试时用，正常启动不设该变量）
        if let spec = ProcessInfo.processInfo.environment["WECAL_SIZE"] {
            let parts = spec.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                p.setContentSize(NSSize(width: min(max(parts[0], Self.minW), Self.maxW),
                                        height: min(max(parts[1], Self.minH), Self.maxH)))
            }
        }
        // 兜底：恢复出来的位置可能贴着屏幕顶（标题区被菜单栏压住），
        // 或者换过显示器后跑到屏幕外，这里统一拉回可见区域。
        // 顺手把可见区写进中转站，给非隔离的 windowWillResize 用。
        if let vf = NSScreen.main?.visibleFrame {
            VisibleArea.shared.frame = vf
            var f = p.frame
            f.origin.x = min(max(f.origin.x, vf.minX), max(vf.minX, vf.maxX - f.width))
            f.origin.y = min(max(f.origin.y, vf.minY), max(vf.minY, vf.maxY - f.height))
            if f != p.frame { p.setFrame(f, display: false) }
        }
        store.applyZoom(p.contentView?.frame.width ?? width, p.contentView?.frame.height ?? height)
        p.orderFrontRegardless()

        panel = p
        // 录制期间把书办主面板也标成「不参与屏幕采集」：界面照常看得见，
        // 但成片里不会出现（sharingType 就是系统为这事留的正门）。
        recorder.mainWindow = p
        // 录制期间书办的每个窗口都不该进画面：主面板、录屏窗、笔记窗一视同仁
        recorder.onRecordingStateChange = { [weak self] active in
            guard let self else { return }
            self.panel?.sharingType = active ? .none : .readOnly
            for w in self.featurePanels.values { w.sharingType = active ? .none : .readOnly }
            // 录屏带麦克风时外放会被收进成片，所以这是唯一一处「主动替用户按下暂停」
            // 的地方。录完不自动续播 —— 接不接下去听由人决定，机器别擅自出声。
            if active, self.audio.state == .playing {
                self.audio.toggle()
                self.store.logUI("开始录屏 → 听录自动暂停（外放会被麦克风收进成片）")
            }
            // 麦克风只有一个：录屏一开，听录这边的录音就得让位（录到的存下来，不删）
            self.audio.screenRecording = active
            if active { self.audio.yieldRecording(to: "开始录屏") }
        }
        // 出成片了把面板叫回前台，别让用户对着桌面找文件
        recorder.onPresentResult = { [weak self] in
            guard let self else { return }
            self.openFeature(.record)
        }
        // 「重启」这类动作必须留痕：事后只看界面是分不清「没点到」「点了没生效」的
        // （回调已在 applicationDidFinishLaunching 开头接好，这里不再重复赋值）
        // 验收钩子：WECAL_TEST_REMINDER=1 弹日程卡（不该有延期排），
        // =2 弹待办卡（该有延期排）。用环境变量而不是点菜单，避免 CGEvent 误点别的应用。
        if let tv = ProcessInfo.processInfo.environment["WECAL_TEST_REMINDER"], tv == "1" || tv == "2" {
            let wantTodo = (tv == "2")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if wantTodo, let t = self.store.openTodos.first(where: { !$0.todoId.isEmpty }) {
                    self.store.previewReminder(for: t)
                    return
                }
                if wantTodo {
                    ReminderCenter.shared.show(
                        item: ReminderItem(subject: "跟进示例客户 A 的报价单",
                                           beginText: "18:00",
                                           minutesLeft: 0,
                                           attendees: ["张三"],
                                           place: "待办",
                                           title: "待 办 提 醒",
                                           caption: "已到提醒时间",
                                           todoId: "snooze-preview"),
                        duration: 40)
                    return
                }
                ReminderCenter.shared.show(item: ReminderItem(subject: "石横特钢一体机技术交流",
                                                               beginText: "01:20",
                                                               minutesLeft: 12,
                                                               attendees: ["张三", "李四"],
                                                               place: "1605 会议室"),
                                           duration: 26)
            }
        }

        // 离屏渲染钩子：WECAL_SNAP=/tmp/card.png 把提醒卡自己画成 PNG 后退出。
        // 显示器休眠/锁屏时 screencapture 拿到的是全黑（-l 和 -R 都失败），
        // 只有让视图自己画一遍才能验版式。文件名带 .layer.png 的那份走 CALayer 渲染，
        // SwiftUI 是 layer-backed 的，cacheDisplay 有时画不出来，两份都留着手工挑。
        // WECAL_SNAP_FRAMES=3 连拍多帧（间隔 1 秒），用来看动效不同相位有没有画出来。
        if let snapPath = ProcessInfo.processInfo.environment["WECAL_SNAP"], !snapPath.isEmpty {
            let frames = max(1, Int(ProcessInfo.processInfo.environment["WECAL_SNAP_FRAMES"] ?? "1") ?? 1)
            for f in 0..<frames {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.2 + Double(f) * 1.0) {
                    let panels = NSApp.windows.filter { $0.level == .screenSaver && $0.isVisible }
                    guard let cv = panels.first?.contentView else {
                        print("SNAP 没找到提醒卡窗口")
                        if f == frames - 1 { NSApp.terminate(nil) }
                        return
                    }
                    let path = f == 0 ? snapPath
                        : snapPath.replacingOccurrences(of: ".png", with: ".\(f).png")
                    let bounds = cv.bounds
                    if f == 0 { print("SNAP 视图尺寸 \(bounds.width)x\(bounds.height)") }
                    if let rep = cv.bitmapImageRepForCachingDisplay(in: bounds) {
                        cv.cacheDisplay(in: bounds, to: rep)
                        if let d = rep.representation(using: .png, properties: [:]) {
                            try? d.write(to: URL(fileURLWithPath: path))
                        }
                    }
                    if let layer = cv.layer,
                       let ctx = CGContext(data: nil, width: Int(bounds.width) * 2, height: Int(bounds.height) * 2,
                                           bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        ctx.scaleBy(x: 2, y: 2)
                        layer.render(in: ctx)
                        if let cg = ctx.makeImage() {
                            let rep = NSBitmapImageRep(cgImage: cg)
                            if let d = rep.representation(using: .png, properties: [:]) {
                                try? d.write(to: URL(fileURLWithPath: path + ".layer.png"))
                            }
                        }
                    }
                    if f == frames - 1 { NSApp.terminate(nil) }
                }
            }
        }

        // 离屏渲染钩子（主面板）：WECAL_SNAP_MAIN=/tmp/main.png 把整个小组件画成 PNG。
        // WECAL_SNAP_MAIN_FRAMES=6 连拍，WECAL_SNAP_MAIN_STEP=5 是帧间隔秒数（默认 1）。
        // 专门用来验「时间自己流逝后界面有没有跟着变」这类问题——不动鼠标、不依赖屏幕亮着。
        if let mainSnap = ProcessInfo.processInfo.environment["WECAL_SNAP_MAIN"], !mainSnap.isEmpty,
           let panelView = p.contentView {
            let env = ProcessInfo.processInfo.environment
            let frames = max(1, Int(env["WECAL_SNAP_MAIN_FRAMES"] ?? "1") ?? 1)
            let step = max(0.2, Double(env["WECAL_SNAP_MAIN_STEP"] ?? "1") ?? 1)
            for f in 0..<frames {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + Double(f) * step) {
                    let cv = panelView
                    let path = f == 0 ? mainSnap
                        : mainSnap.replacingOccurrences(of: ".png", with: ".\(f).png")
                    let bounds = cv.bounds
                    if f == 0 { print("SNAP_MAIN 视图尺寸 \(bounds.width)x\(bounds.height)") }
                    if let rep = cv.bitmapImageRepForCachingDisplay(in: bounds) {
                        cv.cacheDisplay(in: bounds, to: rep)
                        if let d = rep.representation(using: .png, properties: [:]) {
                            try? d.write(to: URL(fileURLWithPath: path))
                        }
                    }
                    if let layer = cv.layer,
                       let ctx = CGContext(data: nil, width: Int(bounds.width) * 2, height: Int(bounds.height) * 2,
                                           bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        ctx.scaleBy(x: 2, y: 2)
                        layer.render(in: ctx)
                        if let cg = ctx.makeImage() {
                            let rep = NSBitmapImageRep(cgImage: cg)
                            if let d = rep.representation(using: .png, properties: [:]) {
                                try? d.write(to: URL(fileURLWithPath: path + ".layer.png"))
                            }
                        }
                    }
                    if f == frames - 1 { NSApp.terminate(nil) }
                }
            }
        }

        // 离屏渲染钩子（全部窗口）：WECAL_SNAP_WINDOWS=/tmp/w.png 把每个可见窗口各拍一张。
        // NSPopover 弹层是独立窗口，主面板那个钩子拍不到它 —— 验改期面板必须靠这个。
        if let wSnap = ProcessInfo.processInfo.environment["WECAL_SNAP_WINDOWS"], !wSnap.isEmpty {
            let delay = 2.5 + max(0.2, Double(ProcessInfo.processInfo.environment["WECAL_SNAP_MAIN_STEP"] ?? "1.5") ?? 1.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let ws = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
                var n = 0
                for w in ws {
                    guard let cv = w.contentView else { continue }
                    let b = cv.bounds
                    // 太小的（状态栏图标之类）不是要看的界面，滤掉
                    guard b.width > 40, b.height > 40 else { continue }
                    let path = wSnap.replacingOccurrences(of: ".png", with: ".\(n).png")
                    if let rep = cv.bitmapImageRepForCachingDisplay(in: b) {
                        cv.cacheDisplay(in: b, to: rep)
                        if let d = rep.representation(using: .png, properties: [:]) {
                            try? d.write(to: URL(fileURLWithPath: path))
                        }
                    }
                    print("SNAP_WINDOWS[\(n)] \(String(describing: type(of: w))) \(Int(b.width))×\(Int(b.height)) → \(path)")
                    n += 1
                }
                print("SNAP_WINDOWS 拍了 \(n) 个窗口")
                NSApp.terminate(nil)
            }
        }

        // 验收钩子：WECAL_REC_CHECK=1 无界面跑一遍自检（录 2 秒测试片段 + 体检），
        // 把结论行打到 stdout 后退出。用来区分「采集通道坏了」和「停止阶梯坏了」。
        if ProcessInfo.processInfo.environment["WECAL_REC_CHECK"] == "1" {
            // 自检纯粹是后台探测，没必要在桌面上闪一个面板（菲哥正在干活）
            panel?.orderOut(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                self.recorder.selfCheck()
                self.pollCheck(until: Date().addingTimeInterval(50))
            }
        }

        // 验收钩子：WECAL_REC_TEST=6 自动开录、录 6 秒、停、把成片体检结果打到 stdout 后退出。
        // 用来非交互地验证「权限 → 采集 → 阶梯停止 → 封装 → 自检」整条链路，
        // 以及最关键的一条：书办自己和悬浮条到底有没有从成片里排掉。
        if let s = ProcessInfo.processInfo.environment["WECAL_REC_TEST"], let secs = Double(s), secs > 0 {
            recorder.countdownOverride = 0
            recorder.revealOverride = false
            recorder.onPresentResult = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                print("REC_TEST 权限预检 granted=\(Media.screenGranted) "
                      + "残留会话=\(Media.strayCaptures().count) ffmpeg=\(Media.ffmpeg ?? "无")")
                self.recorder.start()
                // 要验的是「录屏窗不进画面」，所以把录屏窗单独提出来当被试。
                // 立刻把它拉到最前并铺在别的窗口之上，整段录制里它都在最上层 ——
                // 它要是被挡住，「成片里没有它」就只能证明被挡了，证不了被排除。
                // 验收期把窗口提到 .floating：只在验收里这么干，正常使用仍留在 .normal
                let recWin = self.openFeature(.record)
                self.panel.orderOut(nil)   // 主面板退场，画面里只留录屏窗
                recWin.level = .floating
                // 对抗性对照：WECAL_REC_SHOW=1 时把窗口切回可被采集，
                // 它必须出现在成片里 —— 这样才证明「看不见」是排除生效，而不是测试本身看不见。
                if ProcessInfo.processInfo.environment["WECAL_REC_SHOW"] == "1" {
                    recWin.sharingType = .readOnly
                }
                recWin.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
                    guard let self else { return }
                    if !self.recorder.isRecording {
                        // start() 走的是失败分支，直接把原因打出来
                        if case .failed(let m) = self.recorder.phase { print("REC_TEST FAIL \(m)") }
                        else { print("REC_TEST FAIL 没进到录制态：\(self.recorder.phase)") }
                        NSApp.terminate(nil)
                        return
                    }
                    print("REC_TEST 录制中，录屏窗 frame=\(recWin.frame) "
                          + "sharingType=\(String(describing: recWin.sharingType)) "
                          + "level=floating 悬浮条=\(self.recorder.hudVisible ? "在" : "无") "
                          + "对照=\(ProcessInfo.processInfo.environment["WECAL_REC_SHOW"] == "1" ? "面板应可见" : "面板应不可见")")
                    self.recorder.stop()
                    // 收尾 + 体检最慢要跑几十秒（signalstats 要抽帧），这里等足再判
                    DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
                        guard let self else { return }
                        switch self.recorder.phase {
                        case .done(let r):
                            print("REC_TEST OK path=\(r.path.path)")
                            print("REC_TEST OK 时长=\(String(format: "%.1f", r.seconds))s "
                                  + "体积=\(Media.fmtSize(r.bytes)) 视频轨=\(r.hasVideo) "
                                  + "音频轨=\(r.hasAudio) note=\(r.note.isEmpty ? "无" : r.note)")
                        case .failed(let m):
                            print("REC_TEST FAIL \(m)")
                        default:
                            print("REC_TEST FAIL 收尾没走完：\(self.recorder.phase)")
                        }
                        NSApp.terminate(nil)
                    }
                }
            }
        }

        // 验收钩子：WECAL_RELAUNCH_TEST=1 —— 真点一次「重启书办」，验「旧进程退出 + 新进程被拉起」。
        // 这个 bug 是随机的（退得快就起不来），所以必须跑多轮，不能只看一次成功就当修好了。
        // 防循环：拉起的新实例若也带着这个环境变量，会在拿到标记文件后退回正常启动
        //（open 通常不传环境变量，但这条兜底不能省，一旦成环就是无限重启）。
        if ProcessInfo.processInfo.environment["WECAL_RELAUNCH_TEST"] == "1" {
            // 标记文件必须落在固定的 /tmp：NSTemporaryDirectory() 是进程私有目录，
            // 从 shell 根本找不到（第一版就写在这里，结果清理不到 → 后两轮全被判成「第 2 个实例」）
            let mark = "/tmp/shuban_relaunch_test.mark"
            if FileManager.default.fileExists(atPath: mark) {
                say("RELAUNCH_TEST 第 2 个实例（标记文件在）：退回正常启动 pid=\(ProcessInfo.processInfo.processIdentifier)")
            } else {
                FileManager.default.createFile(atPath: mark, contents: Data())
                _ = openFeature(.record)
                say("RELAUNCH_TEST 旧 pid=\(ProcessInfo.processInfo.processIdentifier) 2.5 秒后点重启")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    say("RELAUNCH_TEST 触发 relaunch()")
                    self?.recorder.relaunch()
                }
            }
        }

        store.onHide = { [weak self] in
            guard let self = self, let p = self.panel else { return }
            p.miniaturize(nil)
        }
        store.onOpenFeature = { [weak self] f in self?.openFeature(f) }
        setupStatusItem()
        store.startWatching()
        store.startReminders()
        // 这行漏过一次：startAutoSync 定义了没被调用，结果整夜 8 小时没同步
        // （generated_at 停在 00:29:32）。凡是「加了个 start 方法」的，必须在这看到它的调用点。
        store.startAutoSync()
        installReturnMonitor()
        installPasteMonitor()
        // 重启回来 / WECAL_MODE 指定：把那个子功能窗口按原样再开出来
        if let f = store.reopenPane {
            openFeature(f)
            store.logUI("重启回来 → 重新打开\(f.title)窗口")
        }
        // 刚点过「重启书办」：等界面稳住再把窗口摆到前面，否则重启成功了也像「什么都没发生」
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.store.justRelaunched else { return }
            self.bringToFront()
            NSApp.activate(ignoringOtherApps: true)
            self.store.logUI("重启完成：日历窗已展开")
        }

        // 验收钩子：真往正文里按一次回车，看它有没有变成换行。
        // 底栏那个回车监视器是本地监视器，专治「输入法还没上屏」；它一顺手把
        // 笔记正文的回车也吃掉，正文就永远打不出第二段 —— 这种错光看代码看不出来。
        if ProcessInfo.processInfo.environment["WECAL_NOTES_ENTER_TEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.runNotesEnterTest()
            }
        }

        // 验收钩子：验「最近录制」那一列的活气 —— 文件在别处被删掉，这一行要自己消失。
        // 光验 RecordPanel.scan 不够（那是纯函数，本来就对）：真会坏的是
        // ①轮询压根没跑 ②窗口认错了人、只在 onAppear 刷了一次 ③把录制中的 0 字节临时件也列出来。
        // 所以这里开真窗口、从进程外删文件、再问界面「你现在列着什么」。
        if ProcessInfo.processInfo.environment["WECAL_RECENTS_TEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.runRecentsTest()
            }
        }

        // 验收钩子：验「入口叫得出窗口、关掉不丢状态、各窗尺寸互不干扰」。
        // 子功能从主面板的一个态改成独立窗口之后，这三件事光读代码看不出来 ——
        // 尤其「关掉再开」如果变成重建，用户刚选中的笔记、滚到的位置会静悄悄丢掉。
        if ProcessInfo.processInfo.environment["WECAL_FEATURE_TEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.runFeatureTest()
            }
        }

        // 验收钩子：听录。纯函数 + 端到端（现场造一个真 .wma 走完整条链子）。
        if ProcessInfo.processInfo.environment["WECAL_AUDIO_TEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.runAudioTest()
            }
        }
    }

    /// 「最近录制」的自动刷新验收。成片目录必须用 WECAL_REC_DIR 换到临时目录，
    /// 不然就是拿用户真的录屏文件夹做试验田。
    private func runRecentsTest() {
        var pass = 0, fail = 0
        func check(_ ok: Bool, _ label: String) {
            say(ok ? "  ✓ \(label)" : "  ✗ \(label)")
            if ok { pass += 1 } else { fail += 1 }
        }
        func done() {
            say("== 结果：\(pass) 通过 / \(fail) 失败 ==")
            exit(fail == 0 ? 0 : 1)
        }
        say("== 最近录制自动刷新用例 ==")
        guard ProcessInfo.processInfo.environment["WECAL_REC_DIR"] != nil else {
            say("  ✗ 这个用例必须配 WECAL_REC_DIR=<临时目录> 跑：不能拿用户真的录屏目录做试验")
            say("== 结果：0 通过 / 1 失败 ==")
            exit(1)
        }
        let fm = FileManager.default
        let dir = recorder.outDir
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 三条假成片，mtime 拉开，好看排序。内容不重要 —— 列表只认名字、大小、时间
        let now = Date().timeIntervalSince1970
        let plan: [(String, Double)] = [("书办录屏_A.mp4", now - 600),
                                        ("书办录屏_B.mp4", now - 300),
                                        ("书办录屏_C.mp4", now - 60)]
        for (n, t) in plan {
            let u = dir.appendingPathComponent(n)
            fm.createFile(atPath: u.path, contents: Data(repeating: 3, count: 2048))
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: t)], ofItemAtPath: u.path)
        }
        openFeature(.record)

        // 第一步：界面拉到的是这三条、且新在前。
        // 这里不捕 self —— 用例跑完就 exit，捕获 AppDelegate 反而会让编译器以为还要用
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let names = RecordPanel.debugRecents.map(\.name)
            check(names.count == 3, "打开录屏窗 → 列表里是盘上那 3 条（实际 \(names.count)：\(names.joined(separator: "、"))）")
            check(names.first == "书办录屏_C.mp4", "最新那条排最前（\(names.first ?? "—")）")
            // 第二步：从进程外删掉最新的一条 —— 相当于用户在 Finder 里按了删除
            try? fm.removeItem(at: dir.appendingPathComponent("书办录屏_C.mp4"))
            say("    （已在窗口外删掉 书办录屏_C.mp4，等轮询自己发现）")
            // 轮询节拍 2 秒，等 3.5 秒足够它跑两轮
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                let after = RecordPanel.debugRecents.map(\.name)
                check(!after.contains("书办录屏_C.mp4"),
                      "没点任何东西，被外部删掉的那条自己消失了（现在：\(after.joined(separator: "、"))）")
                check(after.count == 2, "条数跟着变成 2（实际 \(after.count)）")

                // 第三步：窗口关掉之后轮询该停下来 —— 不然这条 2 秒的定时器会空转到天荒地老
                // （关掉只是 orderOut，SwiftUI 的 onDisappear 不一定来，不能指望它）。
                // 停没停，看「关着的时候删文件，界面那份快照会不会偷偷跟着变」
                self.closeFeature(.record)
                try? fm.removeItem(at: dir.appendingPathComponent("书办录屏_A.mp4"))
                say("    （已关掉录屏窗，并在窗口外删掉 书办录屏_A.mp4）")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                    guard let self else { return }
                    let frozen = RecordPanel.debugRecents.map(\.name)
                    check(frozen.contains("书办录屏_A.mp4"),
                          "窗口关着时不去盘上空转（快照停在关闭那刻：\(frozen.joined(separator: "、"))）")
                    // 重新打开 → 下一拍就得把关着期间发生的删除补上
                    self.openFeature(.record)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        let back = RecordPanel.debugRecents.map(\.name)
                        check(!back.contains("书办录屏_A.mp4"),
                              "重开录屏窗 → 关着期间删掉的那条自己补上（现在：\(back.joined(separator: "、"))）")
                        try? fm.removeItem(at: dir)
                        done()
                    }
                }
            }
        }
    }

    /// 子功能窗口的验收：菜单 ⌘1/⌘2/⌘3 的挂法、开关是否复用同一个窗口、
    /// 各窗上下限与「改一个窗不带崩另一个窗」。
    private func runFeatureTest() {
        var pass = 0, fail = 0
        func check(_ ok: Bool, _ label: String) {
            say(ok ? "  ✓ \(label)" : "  ✗ \(label)")
            if ok { pass += 1 } else { fail += 1 }
        }
        // 认动作必须走 action(for:)：这张表本身也是被测对象之一，
        // 用例里再抄一份二元判断的话，菜单挂错了用例还会是绿的
        func sel(_ f: FeaturePane) -> Selector { action(for: f) }
        say("== 子功能窗口用例 ==")

        // 1) 主菜单的键位：⌘1 日历 / ⌘2 录屏 / ⌘3 记事本 / ⌘4 听录
        let appSub = NSApp.mainMenu?.items.first?.submenu
        let wanted: [(String, Selector, String)] = [
            ("1", #selector(showCalendar), "日历"),
            ("2", #selector(showRecord), "录屏"),
            ("3", #selector(showNotes), "记事本"),
            ("4", #selector(showAudio), "听录"),
        ]
        for (key, want, name) in wanted {
            let it = appSub?.items.first { $0.keyEquivalent == key }
            let got = it.flatMap { NSStringFromSelector($0.action ?? Selector(("无"))) } ?? "没有这一项"
            check(it?.title == name && it?.action == want && it?.target is AppDelegate,
                  "主菜单 ⌘\(key) 挂的是\(name)（实际标题「\(it?.title ?? "—")」动作\(got)）")
        }

        // 2) 走菜单动作真开一遍，顺便看尺寸有没有被夹在自己的上下限里
        for f in FeaturePane.allCases {
            guard let it = appSub?.items.first(where: { $0.action == sel(f) }) else {
                check(false, "主菜单里找不到\(f.title)入口")
                continue
            }
            NSApp.sendAction(it.action!, to: it.target, from: it)
            guard let p = featurePanel(f) else { check(false, "\(f.title)窗口没建出来"); continue }
            let s = p.frame.size
            check(p.isVisible, "点菜单叫出\(f.title)窗口（\(Int(s.width))×\(Int(s.height))）")
            check(s.width >= f.minSize.width - 1, "\(f.title)窗口没小于下限（\(Int(f.minSize.width))×\(Int(f.minSize.height))）")
            check(s.width <= f.maxSize.width + 1 && s.height <= f.maxSize.height + 1,
                  "\(f.title)窗口没超上限（\(Int(f.maxSize.width))×\(Int(f.maxSize.height))）")
        }

        // 3) 关掉再打开：必须是同一个窗口对象（复用 = 状态还在），不是重建
        for f in FeaturePane.allCases {
            guard let first = featurePanel(f) else { check(false, "\(f.title)窗口不在"); continue }
            closeFeature(f)
            check(!first.isVisible, "关掉\(f.title)窗口 → 收起来了（不是销毁）")
            let again = openFeature(f)
            check(again === first, "再打开\(f.title)还是原来那个窗口，没重建 → 选中项/滚动位置不丢")
            check(again.isVisible, "\(f.title)窗口重新显示")
        }

        // 4) 状态栏菜单（右键图标那个）：两个入口都在，且 on/off 跟着窗口开合走
        let sb = buildStatusMenu()
        for f in FeaturePane.allCases {
            let it = sb.items.first { $0.action == sel(f) }
            check(it?.target is AppDelegate, "状态栏菜单里有「\(f.title)」且能点")
            check(it?.state == NSControl.StateValue.on,
                  "开着\(f.title)时状态栏那项是勾选态")
            closeFeature(f)
            let off = buildStatusMenu().items.first { $0.action == sel(f) }
            check(off?.state == NSControl.StateValue.off, "关掉\(f.title)后勾选态跟着取消")
            openFeature(f)
        }

        // 5) 各窗尺寸互不干扰，也不把主面板的字号档带走
        if let rec = featurePanel(.record), let nt = featurePanel(.notes) {
            let beforeNotes = nt.frame
            let beforeZoom = store.zoom
            rec.setFrame(NSRect(x: rec.frame.origin.x, y: rec.frame.origin.y, width: 560, height: 760),
                         display: true)
            check(nt.frame == beforeNotes, "拖动录屏窗改尺寸，记事本窗不动")
            check(abs(store.zoom - beforeZoom) < 0.008, "改子窗尺寸不改主面板字号档（\(beforeZoom)）")
        }

        // 6) 底色必须是不透的。窗口是透明的（圆角外面要能透），
        //    SwiftUI 少铺一层底，卡片之间的缝就直通桌面 —— 2026-11-23 就出过这问题：
        //    录屏窗 33.6%、记事本窗 98.1% 的像素是透明的，光看代码看不出来。
        for f in FeaturePane.allCases {
            guard let p = featurePanel(f) else { continue }
            let r = Self.translucentRatio(p)
            check(r < 0.02, "\(f.title)窗底色不透桌面（半透明像素 \(String(format: "%.2f", r * 100))%）")
        }

        // 7) 最近录制那一列：删一条、以及在别处把文件删掉之后要自己消失。
        //    这条链子全是「盘上的状态 → 界面上的行」，光点界面看不出逻辑对不对，
        //    所以直接验 RecordPanel.scan / shareCompanions 这两个纯函数，
        //    在临时目录里造素材，不碰用户真的录屏文件夹。
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shuban-recents-test", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        var names: [String] = []
        for i in 0..<3 {
            let u = tmp.appendingPathComponent("书办录屏_00\(i).mp4")
            fm.createFile(atPath: u.path, contents: Data(repeating: 7, count: 120 * (i + 1)))
            // 造出「先后」关系：不设 mtime 的话三条同一秒，排序就没得验了
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_760_000_000 + Double(i) * 60)],
                                  ofItemAtPath: u.path)
            names.append(u.lastPathComponent)
        }
        let scanned = RecordPanel.scan(tmp)
        check(scanned.count == 3, "盘上三条成片都认得出来（实际 \(scanned.count) 条）")
        check(scanned.first?.name == names[2], "列表按时间倒序，最新那条排最前（\(scanned.first?.name ?? "—")）")

        // 模拟「在 Finder 里把文件删了」：轮询下一次就该看不见它
        try? fm.removeItem(at: tmp.appendingPathComponent(names[2]))
        let afterExternal = RecordPanel.scan(tmp)
        check(afterExternal.count == 2, "别处删掉一条 → 再扫只剩 2 条（实际 \(afterExternal.count)）")
        check(!afterExternal.contains { $0.name == names[2] },
              "被删掉的那条不会留在列表里当僵尸行")

        // 分享版是同一条录制的子件：删原片要连它一起收，删分享版则不许碰原片
        let sharePath = tmp.appendingPathComponent("书办录屏_000_分享版.mp4")
        fm.createFile(atPath: sharePath.path, contents: Data(repeating: 7, count: 60))
        let comps = RecordPanel.shareCompanions(of: tmp.appendingPathComponent(names[0]))
        check(comps.count == 1 && comps.first?.lastPathComponent == "书办录屏_000_分享版.mp4",
              "删原片时认得出它的分享版一起收走")
        check(RecordPanel.shareCompanions(of: sharePath).isEmpty, "删分享版不会顺手把原片带走")

        // 删除动作本身：走系统废纸篓（还能捞回来）。验完把扔进废纸篓的那份掏掉，
        // 不在用户的废纸篓里留垃圾。
        let victim = tmp.appendingPathComponent(names[1])
        var trashed: NSURL?
        var trashOK = false
        do {
            try fm.trashItem(at: victim, resultingItemURL: &trashed)
            trashOK = true
        } catch {
            say("    (废纸篓不可用：\(error.localizedDescription))")
        }
        check(trashOK && !fm.fileExists(atPath: victim.path),
              "点删除是「移到废纸篓」（原位置消失、还能捞回来）")
        if let t = trashed { try? fm.removeItem(at: t as URL) }
        try? fm.removeItem(at: tmp)

        say("== 结果：\(pass) 通过 / \(fail) 失败 ==")
        exit(fail == 0 ? 0 : 1)
    }

    // MARK: 听录用例

    /// 听录的验收，两半：
    ///
    /// ① **纯函数**：ffmpeg 信息块的解析、缓存命名与 LRU、拖放数据解码。
    ///    「看着对、其实差一点」最容易藏在这几处 —— 比如 `5.1 channels` 直接 Int() 会变 0，
    ///    比如 Finder 给的 file-url 数据其实是 NSURL 的 keyed archive 而不是路径串。
    /// ② **端到端**：现场造一个真 .wma（本机 ffmpeg 带 wmav2 编码器），把
    ///    「拖进来 → 探测元数据 → 解码成 WAV → AVAudioPlayer 出声 → 位置自己前进」
    ///    整条链子走一遍。这条链子任何一环断了，界面上都只是「点了没声」，看不出来。
    ///
    /// 必须配 `WECAL_AUDIO_DIR` + `WECAL_AUDIO_CACHE`：不许拿人真的曲目列表、
    /// 真的解码缓存做试验田。端到端那几步要真出声设备 —— 没接耳机/音箱的机器
    /// 会红在「起播」那一步，那是预期的响动，不是用例写坏了。
    private func runAudioTest() {
        var pass = 0, fail = 0
        func check(_ ok: Bool, _ label: String) {
            say(ok ? "  ✓ \(label)" : "  ✗ \(label)")
            if ok { pass += 1 } else { fail += 1 }
        }
        func done() {
            say("== 结果：\(pass) 通过 / \(fail) 失败 ==")
            exit(fail == 0 ? 0 : 1)
        }
        say("== 听录用例 ==")
        let env = ProcessInfo.processInfo.environment
        guard env["WECAL_AUDIO_DIR"] != nil, env["WECAL_AUDIO_CACHE"] != nil,
              let recEnv = env["WECAL_AUDIO_REC"], !recEnv.isEmpty else {
            say("  ✗ 必须配 WECAL_AUDIO_DIR / WECAL_AUDIO_CACHE / WECAL_AUDIO_REC 跑：")
            say("    第一个存曲目列表、第二个放解码出来的 WAV、第三个是录音输出目录 ——")
            say("    不换走就是在拿人真的列表和真的录音夹做试验")
            say("== 结果：0 通过 / 1 失败 ==")
            exit(1)
        }
        // 录音那几步是真开麦。测完要能自己收拾干净，所以必须在临时目录里
        guard recEnv.hasPrefix("/tmp/") || recEnv.hasPrefix(NSTemporaryDirectory()) else {
            say("  ✗ WECAL_AUDIO_REC 要指到临时目录（现在：\(recEnv)）—— 用例会往里写样本录音")
            say("== 结果：0 通过 / 1 失败 ==")
            exit(1)
        }
        guard let ff = Media.ffmpeg else {
            say("  ✗ 本机没有 ffmpeg，听录用例没法跑（WMA 全靠它解码）")
            say("== 结果：0 通过 / 1 失败 ==")
            exit(1)
        }
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shuban-audio-src", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let cacheSnap = audio.cacheDir

        // ---- ① 纯函数：ffmpeg 信息块解析 ----
        check(AudioBoard.parseClock("00:03:12.24") == 192.24, "时长串 00:03:12.24 → 192.24 秒")
        check(AudioBoard.parseClock("不知道在说什么") == 0, "时长串认不出来时报 0，不乱猜一个")

        // 这段是从本机 ffmpeg 8.1.2 真实输出抄下来的（缩进四空格，encoder 那行要排除在标签外）
        let block = """
        Input #0, asf, from 'a.wma':
          Metadata:
            title           : 书办验收 通话录音
            artist          : 飞致云
            album           : 验收样本
            encoder         : Lavf62.12.102
          Duration: 00:00:03.00, start: 0.000000, bitrate: 61 kb/s
          Stream #0:0: Audio: wmav2 (a[1][0][0] / 0x0161), 16000 Hz, mono, fltp, 48 kb/s
        """
        let info = AudioBoard.parseInfo(block)
        check(abs(info.duration - 3.0) < 0.01, "真信息块里抠出时长 3 秒（\(info.duration)）")
        check(info.title == "书办验收 通话录音" && info.artist == "飞致云" && info.album == "验收样本",
              "标题/艺术家/专辑都抠到，且 encoder 那行没混进标签")
        check(info.sampleRate == 16000 && info.channels == 1,
              "采样率与声道（\(info.sampleRate) Hz / \(info.channels) 声道）—— 决定缓存多大、进度怎么估")
        check(!info.hasArt, "没有视频流不该被认成「有封面」")
        let long = AudioBoard.parseInfo(
            "  Duration: 01:02:03.50, start: 0.000000\n"
            + "  Stream #0:0: Audio: pcm_s16le, 44100 Hz, stereo, fltp, 1411 kb/s")
        check(abs(long.duration - 3723.5) < 0.01 && long.sampleRate == 44100 && long.channels == 2,
              "一小时 + 立体声也对（\(long.duration) 秒 / \(long.channels) 声道）")
        let surround = AudioBoard.parseInfo("  Stream #0:0: Audio: vorbis, 48000 Hz, 5.1 channels, fltp")
        check(surround.channels == 6, "「5.1 channels」认成 6 条声道（实际 \(surround.channels)）—— Int(\"5.1\") 是 nil")
        check(AudioBoard.parseInfo("").duration == 0, "空信息块不崩、时长记 0")

        // 缓存命名 / 白名单
        let probe = ListenTrack(url: URL(fileURLWithPath: "/tmp/书办 验收 录音_01.WMA"),
                                size: 1234, mtime: Date(timeIntervalSince1970: 1_760_000_000),
                                dur: 3, title: nil, artist: nil, album: nil, hasArt: false)
        check(AudioBoard.isPlayable(probe.url)
                && AudioBoard.isPlayable(URL(fileURLWithPath: "/x/y.MP3"))
                && !AudioBoard.isPlayable(URL(fileURLWithPath: "/x/会议纪要.txt")),
              "后缀白名单：WMA / MP3 认，txt 不认（大小写不算）")
        let cname = AudioBoard.cacheName(probe)
        check(!cname.contains("/") && cname.hasSuffix(".wav") && cname.count < 90,
              "缓存名里没有斜杠、长度收敛（\(cname)）—— 否则能拼出跑到别人目录去的文件名")
        check(AudioBoard.cacheName(probe) == cname, "同一条录音缓存名稳定 → 第二次点播秒开")
        var resized = probe
        resized.size = 999
        check(AudioBoard.cacheName(resized) != cname, "同名文件被改过 → 缓存名跟着变，不错拿旧解码")

        // LRU：造 6 个带先后 mtime 的缓存文件
        let cacheFarm = dir.appendingPathComponent("cache", isDirectory: true)
        try? fm.createDirectory(at: cacheFarm, withIntermediateDirectories: true)
        var wavs: [URL] = []
        for i in 0..<6 {
            let u = cacheFarm.appendingPathComponent("c\(i).wav")
            fm.createFile(atPath: u.path, contents: Data([9]))
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60)],
                                  ofItemAtPath: u.path)
            wavs.append(u)
        }
        let pruned = AudioBoard.prunePlan(wavs, keep: AudioBoard.cacheKeep)
        check(pruned.count == 1 && pruned.first?.lastPathComponent == "c0.wav",
              "缓存超过 \(AudioBoard.cacheKeep) 条只清最旧那条（\(pruned.first?.lastPathComponent ?? "—")）")
        check(AudioBoard.prunePlan(Array(wavs.prefix(3)), keep: AudioBoard.cacheKeep).isEmpty,
              "没超上限就不该删任何东西")

        // ---- ② 端到端：真 .wma 走完整条链子 ----
        let wmaA = dir.appendingPathComponent("书办验收 通话录音_01.wma")
        let wmaB = dir.appendingPathComponent("无标签第二条.wma")
        let notAudio = dir.appendingPathComponent("会议纪要.txt")
        let wmaBad = dir.appendingPathComponent("坏文件.wma")
        func makeWma(_ to: URL, secs: Int, tagged: Bool) -> Bool {
            var args = ["-v", "error", "-y", "-f", "lavfi",
                        "-i", "sine=frequency=440:duration=\(secs)",
                        "-ac", "1", "-ar", "16000", "-c:a", "wmav2", "-b:a", "48k"]
            if tagged {
                args += ["-metadata", "title=书办验收 通话录音", "-metadata", "artist=飞致云",
                         "-metadata", "album=验收样本"]
            }
            args += [to.path]
            let (rc, out) = Media.run(ff, args, timeout: 30)
            if rc != 0 { say("    (造样本失败 rc=\(rc)：\(out.prefix(200)))") }
            return rc == 0 && Media.bytes(of: to) > 1024
        }
        let madeA = makeWma(wmaA, secs: 3, tagged: true)
        let madeB = makeWma(wmaB, secs: 2, tagged: false)
        fm.createFile(atPath: notAudio.path, contents: "一段文字，不是音频".data(using: .utf8))
        check(madeA && madeB, "现场造出两条真 .wma（wmav2 · 16 kHz · 单声道）")
        guard madeA && madeB else {
            say("== 结果：\(pass) 通过 / \(fail) 失败 ==")
            exit(1)
        }

        // 拖放那条路：Finder 给的 public.file-url 数据是 NSURL 的 keyed archive
        if let arch = try? NSKeyedArchiver.archivedData(withRootObject: wmaA as NSURL,
                                                        requiringSecureCoding: true) {
            check(AudioPanel.url(from: arch)?.path == wmaA.path,
                  "Finder 那种 keyed archive 形式的 file-url 数据解得开（不是当字符串硬解）")
        } else {
            check(false, "归档造不出来，无法验拖放数据解码")
        }
        check(AudioPanel.url(from: "/tmp/书办 录音.wma" as NSString)?.path == "/tmp/书办 录音.wma",
              "纯路径串那种形状也认")
        check(AudioPanel.url(from: Data("这玩意儿不是路径".utf8)) == nil,
              "认不出来的数据返回 nil，不硬凑一个 URL 出来")

        // 录音：文件名、去重、电平归一、太短判定 —— 全是纯函数，先钉死
        let stamp = AudioCapture.fileName(Date(timeIntervalSince1970: 1_764_000_000))
        check(!stamp.contains("/") && stamp.hasSuffix(".m4a") && stamp.hasPrefix("录音 "),
              "录音文件名不带斜杠、以 .m4a 结尾（\(stamp)）")
        let dupSeed = dir.appendingPathComponent("dup.m4a")
        fm.createFile(atPath: dupSeed.path, contents: Data("x".utf8))
        let dup2 = AudioCapture.uniqueURL(dupSeed)
        check(dup2.lastPathComponent == "dup 2.m4a",
              "同名录音不覆盖，往后加号（\(dup2.lastPathComponent)）")
        check(AudioCapture.norm(-160) == 0 && AudioCapture.norm(0) > 0.99
                && AudioCapture.norm(-30) > AudioCapture.norm(-50),
              "电平归一：静到 -160dB = 0，满格 ≈ 1，越响越大（-30dB → \(String(format: "%.2f", AudioCapture.norm(-30)))）")
        check(AudioCapture.tooShort(0.3) && !AudioCapture.tooShort(1.2),
              "短于 0.6 秒算误触（0.3 秒该丢，1.2 秒该留）")

        // 曲目列表存档换到临时目录后再动列表
        audio.clearList()

        // 自动连播必须先关掉：样本只有 3 秒，播完它会自己滚到下一条去重新解码，
        // 于是「关窗继续放 / 重开还在放同一句」这两步会偶发红在 decoding（真跑过半次）。
        // 跑完在收尾那步还原 —— `autoNext` 的 didSet 会写 UserDefaults，不改回去就把用户的开关动了。
        let autoNextWas = audio.autoNext
        audio.autoNext = false

        var posAtStart = 0.0
        var posAtClose = 0.0
        var tStart = Date()
        var tClosed = Date()
        var deletedOutside = false
        var dropped: [URL]? = nil
        var rowsAtClose: [String] = []

        // 播放器那条链子每一步都得等（解码、进度、轮询），一路嵌套 asyncAfter 会写成圣诞树。
        // 所以摆成步骤表：每步「先做一次动作，再反复问够不够」，等不到就按超时算失败。
        typealias Step = (label: String, budget: Double, start: () -> Void, body: () -> ListenStep)
        var steps: [Step] = []

        steps.append(("拖进来的文件都进列表 · 不支持的那个不算", 8, {
            self.audio.add([wmaA, wmaB, notAudio])
        }, {
            guard self.audio.tracks.count == 2 else {
                return .bad("变成 \(self.audio.tracks.count) 条了")
            }
            if self.audio.tracks.contains(where: { $0.ext == "txt" }) { return .bad("txt 混进来了") }
            return .ok("两条 · 会议纪要.txt 被挡在门外")
        }))

        steps.append(("两条的时长与标签都探到了（无标签的显示文件名）", 25, {}, {
            guard let a = self.audio.tracks.first(where: { $0.url.path == wmaA.path }), a.dur > 0,
                  let b = self.audio.tracks.first(where: { $0.url.path == wmaB.path }), b.dur > 0 else {
                return .wait
            }
            if a.title != "书办验收 通话录音" { return .bad("标签没拿到（title=\(a.title ?? "nil")）") }
            if b.name != "无标签第二条" { return .bad("没标签时该显示文件名，现在显示「\(b.name)」") }
            if abs(a.dur - 3) > 0.3 { return .bad("时长该是 3 秒，探到 \(a.dur)") }
            return .ok("A \(Media.fmtDuration(a.dur))「\(a.name)」 / B \(Media.fmtDuration(b.dur))「\(b.name)」")
        }))

        steps.append(("打开听录窗 → 屏幕上列的就是引擎那两条", 10, {
            _ = self.openFeature(.audio)
        }, {
            let rows = AudioPanel.debugRows
            guard rows.count == 2 else { return .wait }
            if rows != ["书办验收 通话录音", "无标签第二条"] { return .bad("列成了 \(rows)") }
            return .ok(rows.joined(separator: " / "))
        }))

        steps.append(("点第一条 → 解码成 WAV → 真的开始播", 45, {
            tStart = Date()
            self.audio.selectTrack(0)
        }, {
            if case .failed(let m) = self.audio.state { return .bad(m) }
            if self.audio.state == .playing {
                return .ok("解码 + 起播用了 \(String(format: "%.1f", Date().timeIntervalSince(tStart))) 秒")
            }
            return .wait
        }))

        steps.append(("进度自己往前走 · 总长用的是探测值", 12, {
            posAtStart = self.audio.position
        }, {
            if self.audio.state != .playing { return .bad("中途不播了（\(self.audio.state)）") }
            guard self.audio.position > posAtStart + 0.5 else { return .wait }
            if self.audio.duration <= 0 || abs(self.audio.duration - 3) > 0.35 {
                return .bad("总长不对：\(self.audio.duration)")
            }
            return .ok("位置 \(String(format: "%.2f", self.audio.position)) / 总长 \(String(format: "%.2f", self.audio.duration))")
        }))

        steps.append(("解码结果落在缓存目录里（下次秒开）", 6, {}, {
            guard let cur = self.audio.current else { return .bad("没有正在播的曲目") }
            let wav = AudioBoard.cachedWav(for: cur, in: cacheSnap)
            let b = Media.bytes(of: wav)
            if b <= 44 { return .bad("缓存里没有 WAV（找的是 \(wav.lastPathComponent)）") }
            return .ok("\(wav.lastPathComponent) · \(Media.fmtSize(b))")
        }))

        // 这条是「关掉窗口不暂停」那条设计决定的锁：
        // 哪天有人手滑在 closeFeature 里加一句 audio.stop()，这里立刻变红
        steps.append(("关掉听录窗 · 声音继续放（边听边干活是这个功能的用法）", 12, {
            self.closeFeature(.audio)
            posAtClose = self.audio.position
        }, {
            if self.audio.state != .playing { return .bad("关窗把播放停了（\(self.audio.state)）") }
            guard self.audio.position > posAtClose + 0.6 else { return .wait }
            return .ok("窗口关着，位置从 \(String(format: "%.2f", posAtClose)) 走到 \(String(format: "%.2f", self.audio.position))")
        }))

        steps.append(("再打开还是那扇窗 · 还在放同一句", 10, {
            _ = self.openFeature(.audio)
        }, {
            if self.audio.state != .playing { return .bad("重开就不播了（\(self.audio.state)）") }
            guard AudioPanel.debugRows.count == 2 else { return .wait }
            return .ok(AudioPanel.debugRows.joined(separator: " / "))
        }))

        steps.append(("从列表移出只摘行 · 录音原件还在盘上", 8, {
            if let b = self.audio.tracks.last { self.audio.remove(b) }
        }, {
            if !fm.fileExists(atPath: wmaB.path) { return .bad("文件被删掉了！这是录音原件") }
            guard self.audio.tracks.count == 1 else { return .wait }
            return .ok("列表 1 条 · \(wmaB.lastPathComponent) 还在盘上")
        }))

        // 关掉窗口时那趟 2 秒轮询必须停下来：关着的时候从外面删文件，界面那份快照就该冻住。
        // 去掉 FeaturePane.isOpen 那道闸门，这一条立刻变红（那一行会自己掉出去）。
        //
        // 比的是「关闭那一刻的快照」而不是固定条数 —— 上一步刚移出过一条，
        // 这里再写死 2 条就会因为自己的前一步而假红（第一版就是这么翻车的）。
        steps.append(("关着窗的时候不去盘上空转（轮询有 isOpen 闸门）", 14, {
            self.closeFeature(.audio)
            rowsAtClose = AudioPanel.debugRows
            deletedOutside = false
            tClosed = Date()
        }, {
            if !deletedOutside {
                deletedOutside = true
                // 相当于在 Finder 里删掉正在听的这条
                try? fm.removeItem(atPath: wmaA.path)
                say("    （窗口关着，从进程外删掉 \(wmaA.lastPathComponent)，等 8 秒看快照冻不冻住）")
                return .wait
            }
            guard Date() > tClosed.addingTimeInterval(8) else { return .wait }
            if AudioPanel.debugRows == rowsAtClose {
                return .ok("快照停在关闭那刻：\(rowsAtClose.joined(separator: " / "))")
            }
            return .bad("窗口关着也去刷了盘（\(rowsAtClose) → \(AudioPanel.debugRows)）→ 定时器在后台空转")
        }))

        steps.append(("重开补齐：文件没了那行自己掉 · 播放也停下", 12, {
            _ = self.openFeature(.audio)
        }, {
            guard AudioPanel.debugRows.isEmpty else { return .wait }
            switch self.audio.state {
            case .playing, .decoding: return .bad("录音原件都不在了还在播/还在解 → 进度条空转")
            default: return .ok("列表空了 · 状态 \(self.audio.state)")
            }
        }))

        steps.append(("后缀是 .wma 的坏文件：说得清的错，而不是卡死", 40, {
            fm.createFile(atPath: wmaBad.path, contents: Data((0..<8192).map { _ in UInt8.random(in: 0...255) }))
            self.audio.add([wmaBad])
            self.audio.selectTrack(0)
        }, {
            if case .failed(let m) = self.audio.state {
                return .ok(String(m.prefix(46)))
            }
            if self.audio.state == .playing { return .bad("一堆随机字节居然「播起来了」") }
            return .wait
        }))

        // 拖放那条路平时验不到（要人肉从 Finder 拖），这里直接拿真 NSItemProvider 喂进去。
        // 第二个 provider 指向不存在的文件，应当被挡在门外。
        steps.append(("拖放那条路认得出真文件 · 不存在的挡在门外", 12, {
            let ghost = dir.appendingPathComponent("并不存在.wma")
            dropped = nil
            AudioPanel.loadURLs(from: [NSItemProvider(object: wmaB as NSURL),
                                       NSItemProvider(object: ghost as NSURL)]) { list in
                dropped = list
            }
        }, {
            guard let list = dropped else { return .wait }
            if list == [wmaB] { return .ok("收到 \(wmaB.lastPathComponent) · 不存在的被丢掉") }
            return .bad("解出来是 \(list.map(\.lastPathComponent))")
        }))

        // ---- 录音：真开一次麦 ----
        // 输出目录必须是临时目录：不换走就是往菲哥真实的「书办录音」里写样本
        let recRoot = audio.capture.outDir?.path ?? ""
        var recBlocked = false

        steps.append(("点「录音」真录一段（要麦克风权限）", 10, {
            self.audio.stop()
            self.audio.clearList()
            self.audio.beginRecording()
        }, {
            if case .failed(let m) = self.audio.capture.phase { return .bad("起录失败：\(m)") }
            let s = self.audio.capture.seconds
            if s < 1.5 { return .wait }
            if self.audio.capture.level < 0 { return .bad("电平是负的（\(self.audio.capture.level)）") }
            return .ok(String(format: "录到 %.1f 秒 · 电平 %.2f · %@", s, self.audio.capture.level,
                              self.audio.capture.inputName))
        }))

        // 这条同时在验三件事：文件真写出来了、ffmpeg 认得出自己录的 m4a、录完不擅自出声
        steps.append(("停录 → 文件落盘、进列表、选中但不出声", 20, {
            self.audio.endRecording()
        }, {
            if self.audio.capture.isRecording { return .wait }
            guard self.audio.tracks.count == 1, let t = self.audio.tracks.first else {
                return .bad("列表里没有新录的那条（\(self.audio.tracks.count) 条）")
            }
            if t.ext != "m4a" { return .bad("录出来不是 m4a：\(t.url.lastPathComponent)") }
            if !fm.fileExists(atPath: t.url.path) { return .bad("文件不见了：\(t.url.path)") }
            if t.dur <= 0 { return .wait }              // 等探完时长
            // 录完不许自己出声：连「解码中」也算 —— 否则屏上没声、一秒后突然出声更吓人
            if self.audio.state != .idle {
                return .bad("录完不该开始播/解码（现在是 \(self.audio.state)）—— 会突然从喇叭里放出来")
            }
            if self.audio.index != 0 { return .bad("没选中刚录的这条") }
            let left = (try? fm.contentsOfDirectory(atPath: recRoot))?.filter { $0.hasSuffix(".m4a") } ?? []
            if left.isEmpty { return .bad("目录里一个 m4a 都没有（\(recRoot)）") }
            return .ok("\(t.url.lastPathComponent) · \(Media.fmtDuration(t.dur)) · \(Media.fmtSize(t.size)) · 状态 \(self.audio.state)")
        }))

        steps.append(("太短（0.3 秒）就丢掉，不往列表里塞垃圾文件", 12, {
            self.audio.beginRecording()
        }, {
            if self.audio.capture.isRecording {
                if self.audio.capture.seconds >= 0.3 { self.audio.endRecording() }
                return .wait
            }
            if self.audio.tracks.count != 1 {
                return .bad("短录音也进列表了（\(self.audio.tracks.count) 条）")
            }
            if !self.audio.recNote.contains("太短") {
                return .bad("没说清为什么没留（状态栏写的是「\(self.audio.recNote)」）")
            }
            return .ok(self.audio.recNote)
        }))

        steps.append(("取消：文件一起删，不留半条", 12, {
            self.audio.beginRecording()
        }, {
            if self.audio.capture.isRecording {
                if self.audio.capture.seconds >= 0.3 { self.audio.cancelRecording() }
                return .wait
            }
            if self.audio.tracks.count != 1 { return .bad("取消了还进列表（\(self.audio.tracks.count) 条）") }
            let left = (try? fm.contentsOfDirectory(atPath: recRoot))?.filter { $0.hasSuffix(".m4a") } ?? []
            if left.count != 1 { return .bad("取消后目录里剩 \(left) —— 该只剩正式录的那条") }
            return .ok("只剩正式录的那 1 条")
        }))

        // 麦克风只有一个。录屏在跑的时候起录，要么拿不到设备、要么录一段静音 ——
        // 所以要做的是「明确挡住 + 说清原因」，而不是让它悄悄录出一个空文件
        steps.append(("录屏占着麦克风时点不动「录音」，且说清原因", 8, {
            self.audio.screenRecording = true
            recBlocked = !self.audio.beginRecording()
        }, {
            self.audio.screenRecording = false
            if !recBlocked { return .bad("录屏中居然起录成功了 → 两边会互相抢麦克风") }
            if case .failed(let m) = self.audio.state, m.contains("录屏") { return .ok(m) }
            return .bad("没把原因写出来（state=\(self.audio.state)）")
        }))

        // 窗一关，录音台就从屏幕上消失了 —— 这时候还在录，就是「偷偷录」。
        // 所以 closeFeature 必须收尾：录到的先存下来，只停不删（yieldRecording）。
        // 谁哪天把 closeFeature 里那句 yieldRecording 删了，这一条立刻变红。
        var closedWhileRec = false
        steps.append(("关窗时正在录 → 自动收尾：存下来再停，不留偷偷录", 25, {
            closedWhileRec = false
            _ = self.openFeature(.audio)
            self.audio.beginRecording()
        }, {
            if self.audio.capture.isRecording {
                if closedWhileRec { return .bad("窗口早关了，录音还在跑 —— 这就是偷偷录") }
                if self.audio.capture.seconds < 1.2 { return .wait }
                self.closeFeature(.audio)
                closedWhileRec = true
                return .wait
            }
            if !closedWhileRec {
                if case .failed(let m) = self.audio.capture.phase { return .bad("起录失败：\(m)") }
                return .wait
            }
            guard self.audio.tracks.count == 2, let t = self.audio.tracks.last else {
                return .bad("关窗那会儿录的没存下来（列表里 \(self.audio.tracks.count) 条，该 2 条）")
            }
            if !fm.fileExists(atPath: t.url.path) { return .bad("文件不见了：\(t.url.path)") }
            if t.dur <= 0 { return .wait }
            if self.audio.state != .idle {
                return .bad("关窗收尾时顺手放出来了（\(self.audio.state)）")
            }
            if FeaturePane.audio.isOpen { return .bad("窗口没真关上") }
            return .ok("窗已关 · \(t.url.lastPathComponent) 留下 \(Media.fmtDuration(t.dur))")
        }))

        steps.append(("收尾：停播、清列表、临时样本与缓存都掏干净", 8, {
            self.audio.stop()
            self.audio.clearList()
            self.audio.autoNext = autoNextWas
            try? fm.removeItem(at: dir)
            try? fm.removeItem(at: cacheSnap)
            if !recRoot.isEmpty { try? fm.removeItem(atPath: recRoot) }
        }, {
            var left = 0
            if fm.fileExists(atPath: dir.path) { left += 1 }
            if fm.fileExists(atPath: cacheSnap.path) { left += 1 }
            if !recRoot.isEmpty, fm.fileExists(atPath: recRoot) { left += 1 }
            if left > 0 { return .bad("临时目录没清干净（剩 \(left) 处）") }
            return .ok("")
        }))

        // 步进器本体：每 0.35 秒问一次当前这一步够不够。
        // 用 asyncAfter 自己接自己、而不用 Timer —— Timer 的 block 在并发检查里是 @Sendable 的，
        // 里面要调 @MainActor 的一堆方法，会招来一串「捕获了非 Sendable 的 self」的警告；
        // 本项目要求零警告，asyncAfter 这条路在本仓库里已经验过是干净的。
        var idx = 0
        var started = false
        var deadline = Date()
        func tick() {
            guard idx < steps.count else { done(); return }   // done() 里 exit，不会真回来
            if !started {
                steps[idx].start()
                started = true
                deadline = Date().addingTimeInterval(steps[idx].budget)
            }
            switch steps[idx].body() {
            case .wait:
                if Date() > deadline {
                    check(false, "\(steps[idx].label) —— 等不到（超过 \(Int(steps[idx].budget)) 秒）")
                    idx += 1
                    started = false
                }
            case .ok(let detail):
                check(true, detail.isEmpty ? steps[idx].label : "\(steps[idx].label)（\(detail)）")
                idx += 1
                started = false
            case .bad(let why):
                check(false, "\(steps[idx].label)：\(why)")
                idx += 1
                started = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { tick() }
        }
        tick()
    }

    /// 窗口截图里半透明像素的占比。窗口本身是 .clear 的，只有 SwiftUI 画到的地方才有底色，
    /// 所以这个数就是「有多少面积在透桌面」。圆角那一圈抗锯齿约 0.1%，阈值定 2%。
    static func translucentRatio(_ w: NSWindow) -> Double {
        guard let cv = w.contentView, cv.bounds.width > 10, cv.bounds.height > 10,
              let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) else { return 1 }
        cv.cacheDisplay(in: cv.bounds, to: rep)
        guard let img = rep.cgImage else { return 1 }
        let px = img.width, py = img.height
        var buf = [UInt8](repeating: 0, count: px * py * 4)
        guard let ctx = CGContext(data: &buf, width: px, height: py, bitsPerComponent: 8,
                                  bytesPerRow: px * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: px, height: py))
        var translucent = 0
        for i in stride(from: 3, to: buf.count, by: 4) where buf[i] < 250 { translucent += 1 }
        return Double(translucent) / Double(px * py)
    }

    /// 找到 TextEditor 背后的 NSTextView，塞一句话，投一个真回车，看结果是不是换行
    /// retry：记事本现在是独立窗口，刚 open 出来的那一两帧里 SwiftUI 还没把
    /// TextEditor 挂上（contentView 有、NSTextView 没有），所以要等它长出来
    private func runNotesEnterTest(retry: Int = 0) {
        let p = openFeature(.notes)     // 记事本现在是独立窗口，没开就开出来
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard let tv = Self.findTextView(p.contentView) else {
            guard retry < 10 else {
                say("FAIL 没找到正文背后的 NSTextView（记事本窗口 contentView=\(p.contentView == nil ? "无" : "有")）")
                exit(1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.runNotesEnterTest(retry: retry + 1)
            }
            return
        }
        p.makeFirstResponder(tv)
        tv.string = "第一行"
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        say("== 记事本回车用例 ==")
        var all: [NSTextView] = []
        Self.collectTextViews(p.contentView, &all)
        say("  可编辑 NSTextView \(all.count) 个，选中 \(Int(tv.bounds.width))x\(Int(tv.bounds.height))，"
            + "首响应者=\(p.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")，"
            + "isKey=\(p.isKeyWindow)")
        guard let e = NSEvent.keyEvent(with: .keyDown,
                                       location: .zero,
                                       modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: p.windowNumber,
                                       context: nil,
                                       characters: "\r",
                                       charactersIgnoringModifiers: "\r",
                                       isARepeat: false,
                                       keyCode: 36) else {
            say("FAIL 造不出按键事件")
            exit(1)
        }
        NSApp.postEvent(e, atStart: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let s = tv.string
            let ok = s.contains("\n")
            if ok { say("  ✓ 回车在正文里是换行，没被回车监视器吃掉") }
            else { say("  ✗ 回车被吃掉了，正文还是 \(s.debugDescription)") }
            say("== 结果：\(ok ? "1 通过 / 0 失败" : "0 通过 / 1 失败") ==")
            exit(ok ? 0 : 1)
        }
    }

    static func findTextView(_ v: NSView?) -> NSTextView? {
        var hits: [NSTextView] = []
        collectTextViews(v, &hits)
        // 窗口里可能同时有「搜索框的 field editor」和「正文编辑器」，
        // 认面积最大的那个 —— 正文永远比单行输入框大
        return hits.max { a, b in
            (a.bounds.width * a.bounds.height) < (b.bounds.width * b.bounds.height)
        }
    }

    static func collectTextViews(_ v: NSView?, _ out: inout [NSTextView]) {
        guard let v = v else { return }
        if let tv = v as? NSTextView, tv.isEditable { out.append(tv) }
        for s in v.subviews { collectTextViews(s, &out) }
    }


    /// 结论一出来就走，别按固定 40 秒死等 —— 自检常态 5 秒左右就完了。
    private func pollCheck(until deadline: Date) {
        if !recorder.checking && !recorder.checkLines.isEmpty {
            print("REC_CHECK granted=\(Media.screenGranted) 残留=\(Media.strayCaptures())")
            store.logUI("REC_CHECK granted=\(Media.screenGranted) 残留=\(Media.strayCaptures().count)")
            for l in recorder.checkLines {
                print("REC_CHECK \(l)")
                store.logUI("REC_CHECK \(l)")   // 从 LaunchServices 拉起时 stdout 拿不到，只能看日志
            }
            NSApp.terminate(nil)
            return
        }
        if Date() > deadline {
            print("REC_CHECK granted=\(Media.screenGranted) 残留=\(Media.strayCaptures())")
            print("REC_CHECK 超时：checking=\(recorder.checking) 结论数=\(recorder.checkLines.count) "
                  + "状态=\(recorder.statusLine)")
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.pollCheck(until: deadline)
        }
    }

    // MARK: 回车兜底

    private var returnMonitor: Any?
    /// ⌘V 贴图监视器（只在笔记页生效）
    private var pasteMonitor: Any?

    /// 待办输入框的回车兜底。
    ///
    /// SwiftUI TextField 的 onSubmit 在中文输入法下不可靠：候选词还没上屏时按回车，
    /// 这一次按键被输入法吃掉（只负责「上屏」），不会走到提交，用户就会以为没录进去。
    /// 这里在按键层统一处理：
    ///   · 正在组字 → 先让输入法上屏，上屏完成后自动补一次提交（用户按回车就是想提交，
    ///     单行输入框不存在「用回车换行」的诉求）
    ///   · 没在组字 → 直接提交并吞掉事件，避免和 onSubmit 重复触发
    private func installReturnMonitor() {
        returnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            // 只管日历窗这一个窗口。记事本是独立窗口了（2026-11-22 重构），它的
            // TextEditor 里回车就是换行，绝不能落到这个监视器手里 —— 一接管，正文
            // 就永远打不出第二段。这里按「事件是哪个窗口的」认人，而不是按
            // 「首响应者是不是 NSTextView」：TextEditor 背后也是 NSTextView，认不出来。
            // 已验证：改成不按窗口认人，WECAL_NOTES_ENTER_TEST 立刻变红（回车被吃掉）。
            guard let self, let panel = self.panel, e.window === panel else { return e }
            guard e.keyCode == 36 || e.keyCode == 76 else { return e }          // Return / Enter
            guard e.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return e }
            // 只有焦点在文本输入框（field editor 是 NSTextView）时才接管
            guard let tv = panel.firstResponder as? NSTextView else { return e }
            if tv.hasMarkedText() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak tv] in
                    guard let self, let tv, !tv.hasMarkedText() else { return }
                    self.store.requestComposerSubmit()
                }
                return e
            }
            self.store.requestComposerSubmit()
            return nil
        }
    }

    /// 笔记页的 ⌘V 贴图。
    /// TextEditor 只会把剪贴板里的文本贴进来，图片它不管 —— 所以在按键层截一道：
    /// 剪贴板里确实是图就落盘挂到当前笔记上并吞掉事件，是纯文本就原样放行，
    /// 正文照常粘文字，两种操作不打架。
    private func installPasteMonitor() {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let notesWin = self.featurePanel(.notes), e.window === notesWin else { return e }
            let cmd = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard cmd.contains(.command), cmd.intersection([.option, .control]).isEmpty else { return e }
            guard e.charactersIgnoringModifiers?.lowercased() == "v" else { return e }
            guard let img = NoteStore.imageFromPasteboard() else { return e }
            _ = self.notes.addImage(img)
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveAllFrames()
        recorder.shutdownSync()
        // 笔记的落盘是 0.7 秒防抖的，退出前必须补一刀，否则最后几个字会丢
        notes.saveNow()
        // 重启/退出时把在跑的刷新掐掉，别留孤儿进程写「成功但空」的结果
        store.cancelRefresh()
        if let m = returnMonitor { NSEvent.removeMonitor(m); returnMonitor = nil }
        if let m = pasteMonitor { NSEvent.removeMonitor(m); pasteMonitor = nil }
    }

    /// 拖拽缩放时的尺寸闸门：contentMinSize 在 fullSizeContentView 下不生效，改为手动夹紧。
    /// 每个窗口的上下限不一样（日历 320~768 宽，记事本最宽能到 1200），
    /// 所以按窗口从非隔离的 limits 表里取，不能再写死 AppDelegate.minW。
    nonisolated func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // 这里不能直接读 sender.screen —— NSWindow.screen 是 MainActor 的，
        // 而本回调在非隔离上下文（AppKit 实际就在主线程调它）。读主线程写好的中转值。
        let vf = VisibleArea.shared.frame
        let lim = VisibleArea.shared.limits[ObjectIdentifier(sender)]
            ?? (min: NSSize(width: AppDelegate.minW, height: AppDelegate.minH),
                max: NSSize(width: AppDelegate.maxW, height: AppDelegate.maxH))
        let upperW = max(lim.min.width, min(lim.max.width, vf.width))
        let upperH = max(lim.min.height, min(lim.max.height, vf.height))
        return NSSize(width: min(max(frameSize.width, lim.min.width), upperW),
                      height: min(max(frameSize.height, lim.min.height), upperH))
    }

    /// 缩放：只有日历窗驱动全局字号档，子功能窗口用各自固定的字号（PZ/PF）
    nonisolated func windowDidResize(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, let w = notification.object as? NSWindow, let cv = w.contentView else { return }
            if w === self.panel { self.store.applyZoom(cv.frame.width, cv.frame.height) }
            self.scheduleSaveFrame(w)
        }
    }

    /// 拖到别的显示器上时可见区会变，同步给非隔离的 windowWillResize
    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, let w = notification.object as? NSWindow else { return }
            if w === self.panel, let vf = (w.screen ?? NSScreen.main)?.visibleFrame {
                VisibleArea.shared.frame = vf
            }
            self.scheduleSaveFrame(w)
        }
    }

    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let sub = NSMenu()

        let about = sub.addItem(withTitle: "关于 书办", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        about.target = NSApp
        sub.addItem(.separator())

        let showHide = sub.addItem(withTitle: "显示 / 隐藏小组件", action: #selector(toggleVisibility), keyEquivalent: "")
        showHide.target = self

        sub.addItem(.separator())

        // 子功能都是独立窗口，⌘1 日历 / ⌘2 录屏 / ⌘3 记事本 / ⌘4 听录，比翻菜单快
        let cal = sub.addItem(withTitle: "日历", action: #selector(showCalendar), keyEquivalent: "1")
        cal.target = self
        for f in FeaturePane.allCases {
            let it = sub.addItem(withTitle: f.title,
                                 action: action(for: f),
                                 keyEquivalent: "\(f.rawValue + 1)")
            it.target = self
        }

        sub.addItem(.separator())

        let refresh = sub.addItem(withTitle: "刷新企微数据", action: #selector(doRefresh), keyEquivalent: "r")
        refresh.target = self

        sub.addItem(.separator())
        let quit = sub.addItem(withTitle: "退出 书办", action: #selector(doQuit), keyEquivalent: "q")
        quit.target = self

        appItem.submenu = sub
        NSApp.mainMenu = main
    }

    /// 用 ⌘Tab 或点程序坞切回本应用时，把最小化/隐藏的窗口唤回
    func applicationDidBecomeActive(_ notification: Notification) {
        // 被其他窗口遮挡时 isVisible 仍为 true，必须无条件提到最前，
        // 否则点 Dock 图标无法把压在下面的小组件提回来
        bringToFront()
    }

    /// 点 Dock 图标时，若窗口已被隐藏则重新显示
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // flag 为 true 也可能只是「在屏幕上但被压住」，一律提到最前
        bringToFront()
        return true
    }

    // MARK: 菜单栏常驻图标（窗口被藏起来后可从这儿找回）

    private var statusItem: NSStatusItem?

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = item.button {
            let img = NSImage(systemSymbolName: "calendar", accessibilityDescription: "书办")
            img?.isTemplate = true
            b.image = img
            b.toolTip = "书办（左键显示/隐藏，右键更多）"
            b.target = self
            b.action = #selector(statusBarClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusBarClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            toggleVisibility()
        }
    }

    @objc private func toggleVisibility() {
        guard let p = panel else { return }
        // 被其他窗口压住时 occlusionState 不含 .visible，此时应当「提上来」而不是「藏起来」
        let onScreen = p.isVisible && !p.isMiniaturized
        let unobscured = p.occlusionState.contains(.visible)
        if onScreen && unobscured {
            p.orderOut(nil)
        } else {
            bringToFront()
        }
    }

    /// 把窗口提到最前（含从最小化/被遮挡状态恢复）。子功能窗口开着就一起提，
    /// 否则从别的应用切回来时它们会被压在主面板底下，看着像丢了。
    func bringToFront() {
        guard let p = panel else { return }
        if p.isMiniaturized { p.deminiaturize(nil) }
        p.orderFrontRegardless()
        for w in featurePanels.values where w.isVisible {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.orderFrontRegardless()
        }
    }

    @objc private func togglePin() {
        store.pinned.toggle()
        for w in ([panel] + featurePanels.values).compactMap({ $0 }) {
            w.level = store.pinned ? .floating : .normal
            w.isFloatingPanel = store.pinned
        }
    }

    @objc private func doTestReminder() {
        // 优先拿一条真实待办来预览，这样「延期」按钮是能点的（改了就是真延期）
        if let t = store.openTodos.first(where: { !$0.todoId.isEmpty }) {
            store.previewReminder(for: t)
            return
        }
        ReminderCenter.shared.show(item: ReminderItem(subject: "石横特钢一体机技术交流",
                                                       beginText: "10:30",
                                                       minutesLeft: 12,
                                                       attendees: ["张三", "李四"],
                                                       place: "1605 会议室"),
                                   duration: 30)
    }

    @objc private func showCalendar() {
        bringToFront()
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func showRecord() { openFeature(.record) }
    @objc private func showNotes() { openFeature(.notes) }
    @objc private func showAudio() { openFeature(.audio) }

    /// FeaturePane → 菜单动作。
    ///
    /// ⚠️ 这里曾经是三处硬编码的二元判断 `f == .record ? #selector(showRecord) : #selector(showNotes)`
    /// （主菜单、状态栏菜单、验收用例各一份）。加第三个子功能时它不会报错 ——
    /// 会把「听录」静默挂成「记事本」，点了记事本弹出来，谁也不会想到是菜单挂错。
    /// 所以收成一张表：加 case 时编译器逼在这里补一行。
    private func action(for f: FeaturePane) -> Selector {
        switch f {
        case .record: return #selector(showRecord)
        case .notes:  return #selector(showNotes)
        case .audio:  return #selector(showAudio)
        }
    }

    @objc private func doRefresh() { store.refresh() }
    @objc private func doQuit() { NSApp.terminate(nil) }

    /// 右键图标时的菜单。每次现建 —— 「显示/隐藏」「置顶」「哪些子窗开着」都是即时状态。
    /// 构建和弹出分成两段，是为了让 WECAL_FEATURE_TEST 能在不弹菜单的情况下检查里面有什么。
    private func showStatusMenu() {
        guard let b = statusItem?.button else { return }
        let menu = buildStatusMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()

        let showHide = menu.addItem(withTitle: (panel.isVisible && !panel.isMiniaturized) ? "隐藏小组件" : "显示小组件",
                                   action: #selector(toggleVisibility), keyEquivalent: "")
        showHide.target = self

        let pin = menu.addItem(withTitle: "窗口置顶", action: #selector(togglePin), keyEquivalent: "")
        pin.target = self
        pin.state = store.pinned ? .on : .off

        menu.addItem(.separator())

        for f in FeaturePane.allCases {
            let it = menu.addItem(withTitle: f.title,
                                  action: action(for: f),
                                  keyEquivalent: "")
            it.target = self
            it.image = NSImage(systemSymbolName: f.icon, accessibilityDescription: f.title)
            it.state = featurePanel(f)?.isVisible == true ? .on : .off
        }

        menu.addItem(.separator())

        let test = menu.addItem(withTitle: "预览提醒动画", action: #selector(doTestReminder), keyEquivalent: "")
        test.target = self

        let refresh = menu.addItem(withTitle: "刷新企微数据", action: #selector(doRefresh), keyEquivalent: "r")
        refresh.target = self

        menu.addItem(.separator())

        let quit = menu.addItem(withTitle: "退出", action: #selector(doQuit), keyEquivalent: "q")
        quit.target = self

        return menu
    }
}

// MARK: - 换包名后的一次性偏好迁移

/// 包名从 `com.fit2cloud.wecomcalendar.widget` 换成 `com.zhanggefei.shuban` 之后，
/// UserDefaults 会换到全新的 suite —— 不搬的话窗口尺寸、置顶开关、以及**已提醒记录**
/// 全部归零，而提醒记录归零的直接后果是历史待办的提醒会重新弹一遍。
/// 靠 `wecal.migratedFrom` 标记保证只搬一次。
func migrateLegacyPreferences() {
    let now = UserDefaults.standard
    guard now.string(forKey: "wecal.migratedFrom") == nil else { return }
    guard let old = UserDefaults(suiteName: "com.fit2cloud.wecomcalendar.widget") else { return }
    var moved = 0
    for (k, v) in old.dictionaryRepresentation()
    where k.hasPrefix("wecal.") || k == "NSWindow Frame WeComCalendarWidget" {
        now.set(v, forKey: k)
        moved += 1
    }
    now.set("com.fit2cloud.wecomcalendar.widget", forKey: "wecal.migratedFrom")
    if moved > 0 { NSLog("书办：从旧包名迁移了 \(moved) 项偏好（窗口尺寸 / 置顶开关 / 提醒记录）") }
}

// 启动
MainActor.assumeIsolated {
    // 必须在 AppDelegate() 之前：Store 在初始化时就会读置顶开关和提醒记录
    migrateLegacyPreferences()
    // 单实例。两份同时跑会各持一份 reminded 去重表（只在启动时读一次 UserDefaults），
    // 同一条提醒弹两遍——23:37 实测过：我的验收实例和正式实例撞在一起，
    // 「恒先验收单」10 秒内弹了两次。离屏渲染验收需要多开，用 WECAL_ALLOW_MULTI=1 放行。
    let env = ProcessInfo.processInfo.environment
    if env["WECAL_ALLOW_MULTI"] == nil {
        // 改名前编译的旧包（企微日历.app）还留在磁盘上，包名不同、单实例互不认识，
        // 两份一起跑同样会弹两遍，所以旧包名也要一起查
        let ids = [Bundle.main.bundleIdentifier, "com.fit2cloud.wecomcalendar.widget"].compactMap { $0 }
        let me = NSRunningApplication.current.processIdentifier
        let clash = ids.contains { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .contains(where: { $0.processIdentifier != me })
        }
        if clash {
            // 不弹框抢焦点：原来那份还在桌面上，直接退出即可，系统日志留一条痕迹
            NSLog("书办：已有实例在运行，本次启动退出（重复开会导致提醒弹两遍）")
            return
        }
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
