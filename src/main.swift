//
//  WidgetMain.swift
//  书办（ShuBan）· macOS 桌面办公助手
//
//  只读展示：读取 data/data.json（由 refresh.sh 拉取企微日程 + 待办生成），
//  渲染月历、当日日程明细、进行中待办。数据文件变化时自动重载。
//

import SwiftUI
import AppKit

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
    /// 贴边收缩（edge peek）：拖到屏幕边缘后收成一条窄边，鼠标移过去自动展开。
    /// 收缩态由 AppDelegate 控制窗口尺寸，这里只管「现在该画窄条还是画完整界面」。
    @Published var peeking = false
    /// 窄条是竖的还是横的（左右贴边=竖条，上下贴边=横条）
    @Published var peekVertical = true
    /// 功能开关。2026-11-22 定的需求，默认开；菜单里可关。
    @Published var peekEnabled: Bool =
        (UserDefaults.standard.object(forKey: "wecal.peek.enabled") as? Bool) ?? true

    func setPeekEnabled(_ v: Bool) {
        peekEnabled = v
        UserDefaults.standard.set(v, forKey: "wecal.peek.enabled")
    }
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

    init() {
        resolvePaths()
        if let t = ProcessInfo.processInfo.environment["WECAL_TAB"], let v = Int(t), v == 0 || v == 1 {
            tab = v
        }
        if let sc = ProcessInfo.processInfo.environment["WECAL_SCOPE"], let v = Int(sc) {
            scope = v
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

    /// 收缩态窄条：14pt 的红金书脊。左右贴边=竖条，上下贴边=横条。
    /// 只放「书」字 + 待办数（有过期再加一个金点），够扫一眼知道里面有没有事。
    private var peekStrip: some View {
        ZStack {
            Theme.redGradient
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(Theme.todo.opacity(0.5), lineWidth: 1)
                .padding(1.5)
            if store.peekVertical {
                VStack(spacing: 3) {
                    Text("书")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundColor(.white)
                    Rectangle().fill(Theme.todo.opacity(0.75)).frame(width: 6, height: 1)
                    // 竖排逐字渲染时字符串里的空格会占掉一整行，所以这里不写空格
                    verticalText("待办\(store.openTodos.count)")
                    Spacer(minLength: 0)
                    if store.overdueCount > 0 {
                        Circle().fill(Theme.todo).frame(width: 3.5, height: 3.5)
                            .shadow(color: Theme.todo.opacity(0.8), radius: 2)
                    }
                }
                .padding(.vertical, 8)
            } else {
                HStack(spacing: 4) {
                    Text("书").font(.system(size: 8, weight: .heavy)).foregroundColor(.white)
                    Text("待办 \(store.openTodos.count)")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                    if store.overdueCount > 0 {
                        Text("· 已过期 \(store.overdueCount)")
                            .font(.system(size: 7.5, weight: .semibold))
                            .foregroundColor(Theme.todo)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    /// 竖排文字：中文逐字堆叠，比 rotationEffect 干净（也不会被裁掉半行）
    private func verticalText(_ s: String) -> some View {
        VStack(spacing: 1.5) {
            ForEach(Array(s.enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
            }
        }
    }

    var body: some View {
        // 收缩成窄条时换成 peekStrip：窗口只有 14pt 宽，正常布局会被压烂，
        // 所以整块内容直接换掉，而不是让它挤成一团
        Group {
            if store.peeking { peekStrip } else { mainStack }
        }
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
        // 收缩态：窗口只有 14pt 厚，18pt 圆角等于把两头剪成胶囊、字被切，
        // 所以窄条用小圆角（贴边那侧本来也该是方的才贴着屏幕边）
        .clipShape(RoundedRectangle(cornerRadius: store.peeking ? 5 : Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: store.peeking ? 5 : Theme.cardRadius, style: .continuous)
                .stroke(Color.white.opacity(store.peeking ? 0.35 : 0.75), lineWidth: 1)
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
                    HStack(spacing: 3) {
                        Image(systemName: "calendar.badge.clock")
                            .font(Fnt.s(8.5, .semibold))
                            .foregroundColor(Theme.sched.opacity(0.75))
                        Text(daySubtitle).font(Fnt.s(10))
                            .foregroundColor(Theme.inkSoft)
                            .lineLimit(1)
                    }
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
                    moreMenu
                    iconButton("minus") { store.onHide?() }.help("最小化到程序坞")
                }
            }
            .padding(.horizontal, S(13))
            .padding(.top, S(8))
            .padding(.bottom, S(7))
        }
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

    private var moreMenu: some View {
        // .menuStyle(.button) + .plain 按钮样式：不会像 borderlessButton 那样
        // 在大缩放档画出额外的按钮盒子压到相邻翻页键上；.fixedSize 锁住固有尺寸
        Menu {
            Button("回到今天") {
                store.monthAnchor = cal.startOfDay(for: Date())
                store.selectedDay = cal.startOfDay(for: Date())
            }
            Button("打开数据文件夹") {
                if let u = store.dataURL?.deletingLastPathComponent() {
                    NSWorkspace.shared.open(u)
                }
            }
            Divider()
            Button("退出小组件") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(Fnt.s(12, .semibold))
                .foregroundColor(Theme.inkSoft)
                .frame(width: S(22), height: S(22))
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.05)))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多操作")
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
}

// MARK: - 贴边判定的用例表（WECAL_PEEK_TEST=4 跑）
// 真机鼠标位置脚本伪造不了，所以把几何判定抽成纯函数后，用假坐标把规则钉死。
// 注意：这只能证明「判定算得对」，不能证明「事件真的会送到判定里」——后者仍需真机点一下。
enum PeekCase {
    static func runAll() {
        let expanded = NSRect(x: 1000, y: 100, width: 320, height: 833)   // 贴右的展开态
        let stripR   = NSRect(x: 1426, y: 100, width: 14, height: 833)    // 贴右收起后
        let stripT   = NSRect(x: 1000, y: 886, width: 320, height: 14)    // 贴顶收起后
        var fails = 0
        func check(_ name: String, _ got: Bool, _ want: Bool) {
            print("\(got == want ? "PASS" : "FAIL") \(name)（期望 \(want)，实得 \(got)）")
            if got != want { fails += 1 }
        }
        let expR = AppDelegate.peekExpandZone(stripR)
        let expT = AppDelegate.peekExpandZone(stripT)
        // —— 展开态：界面边界就是界线，出界立刻算走开（peekHold 只留 0.15s 防抖） ——
        check("指针在窗口里", expanded.contains(NSPoint(x: 1160, y: 500)), true)
        check("窗口内贴左沿 2pt", expanded.contains(NSPoint(x: 1002, y: 500)), true)
        check("窗口左外 2pt（立刻算走开）", expanded.contains(NSPoint(x: 998, y: 500)), false)
        check("窗口左外 20pt（早该收了）", expanded.contains(NSPoint(x: 980, y: 500)), false)
        check("窗口内贴下沿 2pt", expanded.contains(NSPoint(x: 1160, y: 102)), true)
        check("窗口下外 2pt（立刻算走开）", expanded.contains(NSPoint(x: 1160, y: 98)), false)
        // —— 收起态：什么算「鼠标移过去」 ——
        check("正压在竖窄条上", expR.contains(NSPoint(x: 1433, y: 500)), true)
        check("窄条左外 4pt（留的边，应唤出）", expR.contains(NSPoint(x: 1422, y: 500)), true)
        check("窄条左外 10pt（超出留边，不弹）", expR.contains(NSPoint(x: 1416, y: 500)), false)
        check("指针顶到屏幕最右沿", expR.contains(NSPoint(x: 1439.5, y: 500)), true)
        check("屏幕中间（不该老远就弹开）", expR.contains(NSPoint(x: 700, y: 500)), false)
        // 竖窄条的 y 范围是 100..933，所以「条外」要从 933 往上算
        check("竖条上端外 4pt（留的边）", expR.contains(NSPoint(x: 1433, y: 937)), true)
        check("竖条上端外 10pt（不弹）", expR.contains(NSPoint(x: 1433, y: 943)), false)
        check("竖条下端外 4pt（留的边）", expR.contains(NSPoint(x: 1433, y: 96)), true)
        // —— 贴顶横条 ——
        check("横条下方 4pt（留的边）", expT.contains(NSPoint(x: 1160, y: 882)), true)
        check("横条下方 12pt（超出留边，不弹）", expT.contains(NSPoint(x: 1160, y: 874)), false)
        check("顶边沿", expT.contains(NSPoint(x: 1160, y: 899)), true)
        // —— 贴边判定：窗口拉满一屏高时，几何上上下间隙都是 0，只能靠拖动方向定 ---
        let vf = NSRect(x: 0, y: 0, width: 1440, height: 875)   // 1440×900 屏减掉菜单栏
        func gapsOf(_ f: NSRect) -> [(AppDelegate.PeekEdge, CGFloat)] {
            [(.top, vf.maxY - f.maxY), (.bottom, f.minY - vf.minY),
             (.left, f.minX - vf.minX), (.right, vf.maxX - f.maxX)]
        }
        func decide(_ name: String, _ f: NSRect, bias: AppDelegate.PeekEdge?, drag: CGFloat,
                    _ want: AppDelegate.SnapDecision) {
            let got = AppDelegate.decideSnap(gapsOf(f), bias: bias, drag: drag)
            print("\(got == want ? "PASS" : "FAIL") \(name)（期望 \(want)，实得 \(got)）")
            if got != want { fails += 1 }
        }
        let full = NSRect(x: 336, y: 0, width: 768, height: 875)   // 和可见区一样高
        decide("拉满一屏 + 往上拖 → 贴顶", full, bias: .top, drag: 40, .snap(.top))
        decide("拉满一屏 + 往下拖 → 贴底", full, bias: .bottom, drag: 40, .snap(.bottom))
        decide("拉满一屏 + 没有拖动方向（启动恢复）→ 按优先级贴顶", full, bias: nil, drag: 0, .snap(.top))
        decide("贴顶但这次是横着拖（bias 没贴着）→ 仍贴几何上贴到的边",
               full, bias: .right, drag: 40, .snap(.top))
        decide("只贴左边、拖着方向是往上 → 不能被 bias 掰成贴顶",
               NSRect(x: 0, y: 200, width: 320, height: 520), bias: .top, drag: 30, .snap(.left))
        // 顶边留 30pt（在 18pt 吸附区外）、底边留 145pt、左右各 336pt → 应该什么都不做
        decide("离顶 30pt（在吸附区外）→ 先不动",
               NSRect(x: 336, y: 145, width: 768, height: 700), bias: .top, drag: 40, .hold)
        decide("四边都超过 50pt → 解除贴边态",
               NSRect(x: 336, y: 120, width: 768, height: 600), bias: .top, drag: 40, .release)
        // —— 唤出尺寸不能比屏幕还高（现存那份 768×900 就是） ——
        let fitted = AppDelegate.fitToScreen(NSRect(x: 336, y: 0, width: 768, height: 900), vf)
        check("768×900 在 875 高的可见区里 → 高被夹到 875", abs(fitted.height - 875) < 0.5, true)
        check("夹完不超屏", fitted.maxY <= vf.maxY + 0.5, true)
        let keep = AppDelegate.fitToScreen(NSRect(x: 100, y: 100, width: 384, height: 560), vf)
        check("常规 384×560 原样保留", keep == NSRect(x: 100, y: 100, width: 384, height: 560), true)
        print("PEEK_TEST=4 用例 \(fails == 0 ? "全部通过" : "有 \(fails) 条不通过")")
    }
}

// MARK: - 应用入口

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: Panel!
    let store = Store()
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
    /// 于是在 1440×900 这种屏上能把窗口拉得比可见区还高（现存那份 768×900 就比
    /// 可见区高了约 25pt，顶部压在菜单栏底下），贴边唤出看着就像「自动铺满全屏」。
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

    // MARK: 窗口尺寸持久化（只存展开态）

    private static let frameKey = "wecal.frame"
    private var saveFrameWork: DispatchWorkItem?

    /// 记住窗口位置/大小。收缩态（14pt 窄条）一律不存，否则下次启动就是一条细线。
    func saveFrame() {
        guard let p = panel, !store.peeking else { return }
        let f = p.frame
        guard f.width >= Self.minW - 1, f.height >= Self.minH - 1 else { return }
        UserDefaults.standard.set(NSStringFromRect(f), forKey: Self.frameKey)
    }

    /// 拖动/缩放会连续回调，落盘推迟 0.6 秒，避免每次 mouseDragged 都写一遍
    func scheduleSaveFrame() {
        saveFrameWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveFrame() }
        saveFrameWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    private func restoreFrame(_ p: NSWindow) {
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 第二个来源是旧版本的 NSWindow autosave 键：值正常（不是收缩态的 14 宽）就继承一次
        let saved = [UserDefaults.standard.string(forKey: Self.frameKey),
                     UserDefaults.standard.string(forKey: "NSWindow Frame WeComCalendarWidget")]
        for s in saved.compactMap({ $0 }) {
            var f = NSRectFromString(s)
            guard f.width >= Self.minW - 1, f.height >= Self.minH - 1 else { continue }
            // 恢复时也走一遍屏幕夹紧：老存档可能是「比可见区还高」的尺寸
            f = Self.fitToScreen(f, vf)
            p.setFrame(f, display: false)
            return
        }
        p.setFrameOrigin(NSPoint(x: vf.maxX - width - 20, y: vf.maxY - height - 12))
        p.setContentSize(NSSize(width: width, height: height))
    }

    // MARK: 贴边收缩（edge peek）
    enum PeekEdge: Equatable {
        case left, right, top, bottom
        var vertical: Bool { self == .left || self == .right }
        var name: String {
            switch self {
            case .left: return "贴左"
            case .right: return "贴右"
            case .top: return "贴顶"
            case .bottom: return "贴底"
            }
        }
    }
    /// 当前贴的是哪条边；nil = 没贴边，不做任何自动收起
    private var peekEdge: PeekEdge?
    /// 收起前的完整尺寸，展开时按它恢复
    private var expandedFrame: NSRect = .zero
    private var peekTimer: Timer?
    /// 鼠标离开界面的起始时刻（连续离开超过 peekHold 才收，避免压过一条线就闪）
    private var outsideSince: Date?
    /// 我们自己 setFrame 期间屏蔽「贴边判定」，否则展开动画的中间帧会被判成「离开边缘」
    private var suppressSnapUntil = Date.distantPast
    /// 缩放结束后的这段时间里，跟来的 windowDidMove 一律当缩放的副产品忽略
    private var resizeSettleUntil = Date.distantPast
    nonisolated static let resizeSettle: TimeInterval = 0.5
    /// 上一次 move 到的位置，用来算拖动方向（决定拉满一屏时贴哪条边）
    private var lastFrameOrigin: NSPoint = .zero
    private var dragBias: PeekEdge?
    private var dragDistance: CGFloat = 0
    // 下面几个几何常量被 nonisolated 的纯函数（peekExpandZone / decideSnap）用到，
    // 而整个类是 @MainActor —— 不加 nonisolated 在 Swift 6 严格并发下是编译错误。
    // 它们都是编译期常量，nonisolated 是安全的，也让贴边几何能脱离主线程单测。
    /// 窄条厚度
    nonisolated static let peekThickness: CGFloat = 14
    /// 离边多近算想贴上去 / 离边多远算不贴了
    nonisolated static let snapGap: CGFloat = 18
    nonisolated static let releaseGap: CGFloat = 50
    /// 窄条唤出命中区的外扩量：只要「压到那条线」就算要看，但不能宽到路过就弹
    /// （16pt 时被否掉了：鼠标沿屏幕边走路都会把界面撑开）
    nonisolated static let peekHotSlack: CGFloat = 6
    /// 指针离开界面后到收起的等待。只留一个轮询周期多一点（0.12s/次）做防抖，
    /// 语义上就是「一出界面马上缩回去」
    nonisolated static let peekHold: TimeInterval = 0.15
    private var peekTestMode = false
    /// 只冻结 hover 自动收/展（拍图时用），不影响贴边判定。
    /// 之前共用 peekTestMode 一个开关，把 considerSnap 也一起挡了 ——
    /// 结果链路测试里「往上拖到顶」永远判成不贴边（2026-11-22 由 WECAL_PEEK_TEST=5 抓到）
    private var hoverFrozen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 验收钩子 4：只跑贴边判定的用例表，不建窗口、跑完即退
        if ProcessInfo.processInfo.environment["WECAL_PEEK_TEST"] == "4" {
            PeekCase.runAll()
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        setupMainMenu()

        let host = BleedHostingView(rootView: ContentView().environmentObject(store))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let p = Panel(contentRect: host.frame,
                      styleMask: [.titled, .resizable, .miniaturizable, .nonactivatingPanel, .fullSizeContentView],
                      backing: .buffered,
                      defer: false)
        p.delegate = self
        host.autoresizingMask = [.width, .height]
        // 关键：不让 SwiftUI 内容的固有尺寸反过来当窗口下限，
        // 否则放大档下内容会顶住窗口，宽而扁的形态就缩不出来
        host.sizingOptions = []
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        host.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        host.setContentHuggingPriority(.defaultLow, for: .horizontal)
        host.setContentHuggingPriority(.defaultLow, for: .vertical)
        // 可自由拖拽缩放；上下限与 Fnt 的 0.8~2.0 缩放档对齐
        p.contentMinSize = NSSize(width: Self.minW, height: Self.minH)
        p.contentMaxSize = NSSize(width: Self.maxW, height: Self.maxH)
        p.minSize = NSSize(width: Self.minW, height: Self.minH)
        p.maxSize = NSSize(width: Self.maxW, height: Self.maxH)
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

        // 只有首次启动（无历史尺寸）才用默认尺寸；否则保留用户拖拽后的宽高
        // 尺寸自己存（用户默认值 wecal.frame），不用 NSWindow 的 autosave：
        // autosave 在每次 frame 变化时都会写，收缩成 14pt 窄条那一刻也会写进去，
        // 于是退出时若正处于收起态，下次启动窗口就只有 14 宽（2026-11-22 踩到）。
        restoreFrame(p)
        // 验收用钩子：WECAL_SIZE="480x700" 直接指定内容尺寸（仅调试时用，正常启动不设该变量）
        if let spec = ProcessInfo.processInfo.environment["WECAL_SIZE"] {
            let parts = spec.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                p.setContentSize(NSSize(width: min(max(parts[0], Self.minW), Self.maxW),
                                        height: min(max(parts[1], Self.minH), Self.maxH)))
            }
        }
        // 兜底：恢复出来的位置可能贴着屏幕顶（标题区被菜单栏压住），
        // 或者换过显示器后跑到屏幕外，这里统一拉回可见区域
        if let vf = NSScreen.main?.visibleFrame {
            var f = p.frame
            f.origin.x = min(max(f.origin.x, vf.minX), max(vf.minX, vf.maxX - f.width))
            f.origin.y = min(max(f.origin.y, vf.minY), max(vf.minY, vf.maxY - f.height))
            if f != p.frame { p.setFrame(f, display: false) }
        }
        store.applyZoom(p.contentView?.frame.width ?? width, p.contentView?.frame.height ?? height)
        p.orderFrontRegardless()

        panel = p
        // 拖动方向的基准：不初始化成当前位置的话，第一次 move 会算出一个巨大的位移
        lastFrameOrigin = p.frame.origin

        // 验收钩子 5：把「拖动 vs 缩放」这两条事件链路跑成真证据。
        // 用例表（=4）只能证明纯函数算得对，证明不了事件送得到 —— 这里直接喂 delegate 回调。
        if ProcessInfo.processInfo.environment["WECAL_PEEK_TEST"] == "5" {
            hoverFrozen = true      // 注意：这里不能设 peekTestMode，那会连贴边判定一起挡掉
            runPeekEventChain(p)
        }

        // 验收钩子：WECAL_PEEK_TEST=1 启动后贴右边并收起（拍竖窄条）；=2 收起后再展开（验恢复尺寸）；
        // =3 贴顶收起（拍横窄条，走的是另一套 HStack 布局，最容易溢出）。
        // 鼠标位置没法伪造，所以测试态直接跳过 hover 判定，只验外观与恢复尺寸。
        if let pt = ProcessInfo.processInfo.environment["WECAL_PEEK_TEST"], pt == "1" || pt == "2" || pt == "3" {
            peekTestMode = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                var f = p.frame
                if pt == "3" {
                    f.origin.y = self.visibleFrame.maxY - f.height
                } else {
                    f.origin.x = self.visibleFrame.maxX - f.width
                }
                p.setFrame(f, display: true)
                self.peekEdge = (pt == "3") ? .top : .right
                self.collapse()
                print("PEEK_TEST 收起后 frame=\(p.frame)")
                if pt == "2" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.expand()
                        print("PEEK_TEST 展开后 frame=\(p.frame)")
                    }
                }
            }
        }
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
                // 收缩态窄条只有 14pt 宽，40 的门槛会把主面板自己滤掉 → 验收态放宽到 10
                let minSide: CGFloat = self.peekTestMode ? 10 : 40
                for w in ws {
                    guard let cv = w.contentView else { continue }
                    let b = cv.bounds
                    guard b.width > minSide, b.height > minSide else { continue }
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

        store.onHide = { [weak self] in
            guard let self = self, let p = self.panel else { return }
            p.miniaturize(nil)
        }
        setupStatusItem()
        store.startWatching()
        store.startReminders()
        // 这行漏过一次：startAutoSync 定义了没被调用，结果整夜 8 小时没同步
        // （generated_at 停在 00:29:32）。凡是「加了个 start 方法」的，必须在这看到它的调用点。
        store.startAutoSync()
        installReturnMonitor()
        startPeekWatching()
        // 上次退出时窗口本来就贴在边上：重启后不会再收到 windowDidMove，
        // 不主动判一次的话「贴边」这个状态一重启就丢了（要等下次拖窗口才恢复）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.considerSnap()
        }
    }

    // MARK: 回车兜底

    private var returnMonitor: Any?

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

    func applicationWillTerminate(_ notification: Notification) {
        saveFrame()
        // 重启/退出时把在跑的刷新掐掉，别留孤儿进程写「成功但空」的结果
        store.cancelRefresh()
        if let m = returnMonitor { NSEvent.removeMonitor(m); returnMonitor = nil }
    }

    /// 拖拽缩放时的尺寸闸门：contentMinSize 在 fullSizeContentView 下不生效，改为手动夹紧
    nonisolated func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // 这里不能直接读 sender.screen —— NSWindow.screen 是 MainActor 的，
        // 而本回调在非隔离上下文（AppKit 实际就在主线程调它）。读主线程写好的中转值。
        let vf = VisibleArea.shared.frame
        let upperW = max(AppDelegate.minW, min(AppDelegate.maxW, vf.width))
        let upperH = max(AppDelegate.minH, min(AppDelegate.maxH, vf.height))
        return NSSize(width: min(max(frameSize.width, AppDelegate.minW), upperW),
                      height: min(max(frameSize.height, AppDelegate.minH), upperH))
    }

    /// 拖拽缩放时同步全局缩放档（字号与固定尺寸随之重排）
    nonisolated func windowDidResize(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, let f = self.panel?.contentView?.frame else { return }
            // 从下边往上拖高会同时改 origin.y，AppKit 会跟着补发 windowDidMove ——
            // 那一下不是「他往边上拖」，得压掉，否则「把窗口拉高顶住上边」会被当成贴顶。
            // 用时间窗而不是标志位：两者在同一次拖拽里交替到达，顺序不可靠。
            self.resizeSettleUntil = Date().addingTimeInterval(Self.resizeSettle)
            self.store.applyZoom(f.width, f.height)
            self.scheduleSaveFrame()
        }
    }

    /// 窗口被拖动 → 判断要不要贴边
    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, let p = self.panel else { return }
            self.scheduleSaveFrame()
            if ProcessInfo.processInfo.environment["WECAL_PEEK_TEST"] == "5" {
                print("LINK5   ↳ didMove 到达 y=\(Int(p.frame.minY)) resize抑制中=\(Date() < self.resizeSettleUntil) 贴边抑制中=\(Date() < self.suppressSnapUntil)")
            }
            if Date() < self.resizeSettleUntil { return }   // 缩放带出来的 move，不算停靠
            // 记下这次拖动的方向。窗口拉满一屏高时上下间隙都是 0，「贴哪条边」
            // 光看几何分不出来，只能看他往哪个方向拖。
            let cur = p.frame
            let dx = cur.minX - self.lastFrameOrigin.x
            let dy = cur.minY - self.lastFrameOrigin.y
            self.lastFrameOrigin = cur.origin
            self.dragDistance = max(abs(dx), abs(dy))
            if abs(dx) >= abs(dy) {
                self.dragBias = abs(dx) < 2 ? nil : (dx > 0 ? .right : .left)   // Cocoa x 向右增大
            } else {
                self.dragBias = abs(dy) < 2 ? nil : (dy > 0 ? .top : .bottom)   // y 向上增大
            }
            self.considerSnap()
        }
    }

    // MARK: 贴边收缩实现

    private var visibleFrame: NSRect {
        let r = (panel?.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        VisibleArea.shared.frame = r   // 给非隔离的 windowWillResize 用
        return r
    }

    /// 0.12 秒一次轮询鼠标位置。用 NSEvent.mouseLocation 而不是全局事件监听：
    /// 不需要辅助功能权限，逻辑也集中在一处。
    func startPeekWatching() {
        peekTimer?.invalidate()
        peekTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.peekTick() }
        }
    }

    /// 喂假事件跑贴边链路，逐步打日志（WECAL_PEEK_TEST=5）。
    /// 坐标全部按当前屏幕可见区算，不写死数字。
    private func runPeekEventChain(_ p: NSWindow) {
        let vf = visibleFrame
        var fails = 0
        func say(_ s: String) { print("LINK5 \(s)") }
        func expect(_ name: String, _ want: PeekEdge?, at t: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                let got = self.peekEdge
                if got != want {
                    let vf = self.visibleFrame
                    let f = p.frame
                    say("诊断 @\(String(format: "%.1f", t)) frame=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))×\(Int(f.height))"
                        + " 间隙 顶\(Int(vf.maxY - f.maxY)) 底\(Int(f.minY - vf.minY)) 左\(Int(f.minX - vf.minX)) 右\(Int(vf.maxX - f.maxX))"
                        + " peekEnabled=\(self.store.peekEnabled) peeking=\(self.store.peeking)"
                        + " 抑制中=\(Date() < self.suppressSnapUntil) resize抑制中=\(Date() < self.resizeSettleUntil)"
                        + " 方向=\(self.dragBias.map { $0.name } ?? "nil") 位移=\(Int(self.dragDistance))")
                }
                let ok = got == want
                let w = want.map { $0.name } ?? "nil"
                let g = got.map { $0.name } ?? "nil"
                print("\(ok ? "PASS" : "FAIL") 链路 \(name)（期望 \(w)，实得 \(g)）")
                if !ok { fails += 1 }
            }
        }
        func place(_ r: NSRect) {
            self.suppressSnapUntil = Date().addingTimeInterval(0.05)
            p.setFrame(r, display: true)
        }
        func fakeMove() {
            self.suppressSnapUntil = .distantPast
            self.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: p))
        }
        let w: CGFloat = 560, h: CGFloat = 700
        let mid = NSRect(x: vf.midX - w / 2, y: vf.minY + 60, width: w, height: h)
        let touchTop = NSRect(x: vf.midX - w / 2, y: vf.maxY - h, width: w, height: h)
        let belowTop = NSRect(x: vf.midX - w / 2, y: vf.maxY - h - 20, width: w, height: h)
        say("开始：可见区 \(Int(vf.width))×\(Int(vf.height))，测试窗口 \(Int(w))×\(Int(h))")

        // ① 摆在中间，四条边都没碰 → 不该有任何贴边
        peekEdge = nil
        place(mid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { fakeMove() }
        expect("摆在中间拖着 → 不贴边", nil, at: 1.1)

        // ② 往上拖到顶 → 该判成贴顶（这就是菲哥要的「顶部贴边能收进去」）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.peekEdge = nil
            place(belowTop)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                place(touchTop)
                fakeMove()
            }
        }
        expect("往上拖到顶 → 贴顶", .top, at: 2.6)

        // ③ 把窗口顶边往上拖大（拉高）→ AppKit 会补发 move，这一下不该算停靠
        //    就是 13:01 那次「拉高窗口被收成一条横线弹到屏幕顶」的回归
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.peekEdge = nil
            place(NSRect(x: vf.midX - w / 2, y: vf.maxY - h - 60, width: w, height: h))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                // 拖窗口上边把高度从 700 拉到 760，同时 origin.y 上移 → resize + move 成对出现
                let grown = NSRect(x: vf.midX - w / 2, y: vf.maxY - 760, width: w, height: 760)
                self.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: p))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.suppressSnapUntil = Date().addingTimeInterval(0.05)
                    p.setFrame(grown, display: true)
                    self.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: p))
                }
            }
        }
        expect("拉高顶住上边（resize 带出来的 move）→ 不贴边", nil, at: 4.2)

        // ④ 等 resize 抑制窗过去之后，纯平移（尺寸不变，免得又触发 resize）到顶 → 该贴顶
        //    注意：上一步把窗口拉成了 760 高，这里必须沿用 760，否则 place 本身就是一次缩放
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.6) {
            place(NSRect(x: vf.midX - w / 2, y: vf.maxY - 760 - 20, width: w, height: 760))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                place(NSRect(x: vf.midX - w / 2, y: vf.maxY - 760, width: w, height: 760))
                fakeMove()
            }
        }
        expect("抑制窗过后的纯拖动 → 贴顶", .top, at: 5.6)

        // ⑤ 收起 + 唤出的尺寸：唤出不得比可见区还高（现存存档就是 768×900 > 875）
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            self.peekEdge = .top
            self.collapse()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let f = p.frame
                print("\(abs(f.height - Self.peekThickness) < 1 ? "PASS" : "FAIL") 收起 → \(Int(f.width))×\(Int(f.height))（厚 \(Int(Self.peekThickness))）")
                if abs(f.height - Self.peekThickness) >= 1 { fails += 1 }
                self.expandedFrame = NSRect(x: vf.minX + 300, y: vf.minY - 500, width: 768, height: 900)
                self.expand()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let g = p.frame
                    let ok = g.height <= vf.height + 0.5 && g.maxY <= vf.maxY + 0.5
                    print("\(ok ? "PASS" : "FAIL") 唤出 768×900 → 夹成 \(Int(g.width))×\(Int(g.height))（可见区高 \(Int(vf.height))）")
                    if !ok { fails += 1 }
                    print("LINK5 链路用例 \(fails == 0 ? "全部通过" : "有 \(fails) 条不通过")")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// 拖到边缘附近 → 记住贴哪条边并对齐；拖离边缘超过 releaseGap → 解除贴边态
    func considerSnap() {
        guard let p = panel, p.isVisible, !p.isMiniaturized else { return }
        guard store.peekEnabled else { peekEdge = nil; return }
        if store.peeking { return }
        if peekTestMode || Date() < suppressSnapUntil { return }
        let vf = visibleFrame
        let f = p.frame
        let gaps: [(PeekEdge, CGFloat)] = [
            (.top, vf.maxY - f.maxY),        // 顺序即平票优先级：他最常贴的是顶
            (.bottom, f.minY - vf.minY),
            (.left, f.minX - vf.minX),
            (.right, vf.maxX - f.maxX),
        ]
        switch Self.decideSnap(gaps, bias: dragBias, drag: dragDistance) {
        case .snap(let edge):
            if peekEdge != edge {
                peekEdge = edge
                store.flash("已\(edge.name)：鼠标移开自动收起，压到窄条展开")
            }
            snap(edge)
        case .release:
            peekEdge = nil
            outsideSince = nil
        case .hold:
            break
        }
    }

    // 嵌套类型不继承外层的 actor 隔离，所以不用 nonisolated；
    // 但要能被 nonisolated 的纯函数和文件级用例表用
    enum SnapDecision: Equatable {
        case snap(PeekEdge), hold, release
    }

    /// 贴边判定：抽成纯函数，好用假坐标钉死规则（WECAL_PEEK_TEST=4）。
    /// gaps 的顺序就是平票时的优先级。
    /// bias = 这次拖动的方向。窗口拉满一屏高时上下间隙同为 0，几何上分不出
    /// 「想贴顶」还是「顺便撞边」，只能看他往哪个方向拖 —— 这也是为什么不用
    /// 「该方向占可见区超过 72% 就算顺便」那种占比规则：菲哥的窗口本来就和屏幕
    /// 一样高（768×900 / 可见区 900），占比规则会把他真实的贴顶一起封死（2026-11-22 踩到）。
    nonisolated static func decideSnap(_ gaps: [(PeekEdge, CGFloat)],
                                       bias: PeekEdge?,
                                       drag: CGFloat) -> SnapDecision {
        let touching = gaps.filter { $0.1 <= snapGap }
        if let b = bias, drag > 2, touching.contains(where: { $0.0 == b }) { return .snap(b) }
        if let best = touching.min(by: { $0.1 < $1.1 }) { return .snap(best.0) }
        if let closest = gaps.map({ $0.1 }).min(), closest > releaseGap { return .release }
        return .hold
    }

    /// 把窗口贴紧某条边（只动那个方向的坐标）
    private func snap(_ edge: PeekEdge) {
        guard let p = panel else { return }
        let vf = visibleFrame
        var f = p.frame
        switch edge {
        case .left:   f.origin.x = vf.minX
        case .right:  f.origin.x = vf.maxX - f.width
        case .top:    f.origin.y = vf.maxY - f.height
        case .bottom: f.origin.y = vf.minY
        }
        if f != p.frame {
            suppressSnapUntil = Date().addingTimeInterval(0.2)
            p.setFrame(f, display: true)
        }
    }

    private func peekTick() {
        guard let p = panel, p.isVisible, !p.isMiniaturized else { return }
        guard store.peekEnabled else {
            if store.peeking { expand() }
            peekEdge = nil
            return
        }
        guard peekEdge != nil, !peekTestMode, !hoverFrozen else { return }
        // 按住鼠标（正在拖窗口）时不展开也不收起
        if NSEvent.pressedMouseButtons & 1 != 0 { outsideSince = nil; return }
        let mouse = NSEvent.mouseLocation
        if store.peeking {
            // 窄条只有 14pt，指针要「靠近」就能唤出界面，所以命中区往外垫 16pt；
            // 贴边那侧指针可以顶到屏幕外沿，本来就丢不了
            if Self.peekExpandZone(p.frame).contains(mouse) { expand(); outsideSince = nil }
            return
        }
        // 附属窗口（改期弹层 / 删除确认框 / 菜单）是独立窗口，指针在它们上面时
        // mouseLocation 不在主面板内；不豁免的话一点开就被收走、弹层跟着作废
        if auxiliaryWindowOpen { outsideSince = nil; return }
        // 展开态判定就用窗口边界本身：指针出了界面就开始倒计时（peekHold 只有 0.15s，
        // 相当于立刻缩回）。曾经给过 28pt 缓冲 + 1.6s 延迟，被否掉：
        // 「鼠标移开界面就应该马上缩回去」，缓冲留着反而像界面自己赖着不放。
        if p.frame.contains(mouse) { outsideSince = nil; return }
        if let t = outsideSince {
            if Date().timeIntervalSince(t) > Self.peekHold { collapse() }
        } else {
            outsideSince = Date()
        }
    }

    // MARK: 下面两个判定抽成纯函数：真机鼠标没法用脚本伪造，但几何逻辑可以用假坐标跑用例表

    /// 收起态下指针落在哪片区域就该把界面唤出来
    nonisolated static func peekExpandZone(_ f: NSRect) -> NSRect {
        f.insetBy(dx: -peekHotSlack, dy: -peekHotSlack)
    }
    /// 有没有附属窗口正在被使用（弹层、确认框、菜单）
    private var auxiliaryWindowOpen: Bool {
        for w in NSApp.windows where w.isVisible && w !== panel {
            let cls = String(describing: type(of: w))
            if cls.contains("Popover") || cls.contains("Alert")
                || cls.contains("Sheet") || cls.contains("Menu") { return true }
        }
        return false
    }

    private func collapse() {
        guard let p = panel, let edge = peekEdge, !store.peeking else { return }
        var f = p.frame
        let vf = visibleFrame
        if edge.vertical { f.size.width = Self.peekThickness } else { f.size.height = Self.peekThickness }
        switch edge {
        case .left:   f.origin.x = vf.minX
        case .right:  f.origin.x = vf.maxX - f.size.width
        case .top:    f.origin.y = vf.maxY - f.size.height
        case .bottom: f.origin.y = vf.minY
        }
        // 指针正压在窄条即将占的位置上（贴右、指针顶在屏幕最右边最常见）：
        // 现在收下去下一帧就命中热区又弹回来，来回抖 → 干脆先不收，重置倒计时
        if !peekTestMode,
           Self.peekExpandZone(f).contains(NSEvent.mouseLocation) {
            outsideSince = Date()
            return
        }
        expandedFrame = p.frame
        store.peekVertical = edge.vertical
        store.peeking = true
        outsideSince = nil
        suppressSnapUntil = Date().addingTimeInterval(0.8)
        p.styleMask.remove(.resizable)          // 窄条上别让人拖出个宽条
        p.minSize = NSSize(width: 1, height: 1)  // 否则 setFrame 会被下限夹回去
        p.contentMinSize = NSSize(width: 1, height: 1)
        p.setFrame(f, display: true, animate: true)
        store.logUI("\(edge.name)收起 → \(Int(f.width))×\(Int(f.height))")
    }

    private func expand() {
        guard let p = panel, store.peeking else { return }
        let vf = visibleFrame
        var target = expandedFrame
        if target.width < 100 || target.height < 100 {
            target = NSRect(x: vf.maxX - width, y: vf.maxY - height, width: width, height: height)
        }
        // 唤出尺寸也夹一次屏：老存档可能比可见区还高，那样一唤出就是「铺满全屏」
        target = Self.fitToScreen(target, vf)
        store.peeking = false
        outsideSince = nil
        suppressSnapUntil = Date().addingTimeInterval(0.8)
        p.styleMask.insert(.resizable)
        p.setFrame(target, display: true, animate: true)
        // 尺寸下限要等动画结束再恢复，中途恢复会把窗口夹回 minSize
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let p = self.panel, !self.store.peeking else { return }
            p.minSize = NSSize(width: Self.minW, height: Self.minH)
            p.contentMinSize = NSSize(width: Self.minW, height: Self.minH)
        }
        store.logUI("展开 → \(Int(target.width))×\(Int(target.height))")
    }

    @objc private func togglePeek() {
        store.setPeekEnabled(!store.peekEnabled)
        if store.peekEnabled {
            store.flash("贴边收起已开启：把窗口拖到屏幕边上试试")
        } else {
            peekEdge = nil
            if store.peeking { expand() }
            store.flash("贴边收起已关闭")
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

        let peekItem = sub.addItem(withTitle: "贴边自动收起", action: #selector(togglePeek), keyEquivalent: "")
        peekItem.target = self
        peekItem.state = store.peekEnabled ? .on : .off

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

    // MARK: 菜单栏常驻图标（收起后可从这里找回）

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

    /// 把小组件提到最前（含从最小化/被遮挡状态恢复）
    func bringToFront() {
        guard let p = panel else { return }
        if p.isMiniaturized { p.deminiaturize(nil) }
        p.orderFrontRegardless()
    }

    @objc private func togglePin() {
        store.pinned.toggle()
        panel.level = store.pinned ? .floating : .normal
        panel.isFloatingPanel = store.pinned
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

    @objc private func doRefresh() { store.refresh() }
    @objc private func doQuit() { NSApp.terminate(nil) }

    private func showStatusMenu() {
        guard let b = statusItem?.button else { return }
        let menu = NSMenu()

        let showHide = menu.addItem(withTitle: (panel.isVisible && !panel.isMiniaturized) ? "隐藏小组件" : "显示小组件",
                                   action: #selector(toggleVisibility), keyEquivalent: "")
        showHide.target = self

        let pin = menu.addItem(withTitle: "窗口置顶", action: #selector(togglePin), keyEquivalent: "")
        pin.target = self
        pin.state = store.pinned ? .on : .off

        let peek = menu.addItem(withTitle: "贴边自动收起", action: #selector(togglePeek), keyEquivalent: "")
        peek.target = self
        peek.state = store.peekEnabled ? .on : .off
        peek.toolTip = "把窗口拖到屏幕边缘，鼠标移开会自动收成一条窄边；移回去即展开"

        menu.addItem(.separator())

        let test = menu.addItem(withTitle: "预览提醒动画", action: #selector(doTestReminder), keyEquivalent: "")
        test.target = self

        let refresh = menu.addItem(withTitle: "刷新企微数据", action: #selector(doRefresh), keyEquivalent: "r")
        refresh.target = self

        menu.addItem(.separator())

        let quit = menu.addItem(withTitle: "退出", action: #selector(doQuit), keyEquivalent: "q")
        quit.target = self

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }
}

// MARK: - 换包名后的一次性偏好迁移

/// 包名从 `com.fit2cloud.wecomcalendar.widget` 换成 `com.zhanggefei.shuban` 之后，
/// UserDefaults 会换到全新的 suite —— 不搬的话窗口尺寸、贴边开关、以及**已提醒记录**
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
    if moved > 0 { NSLog("书办：从旧包名迁移了 \(moved) 项偏好（窗口尺寸 / 贴边开关 / 提醒记录）") }
}

// 启动
MainActor.assumeIsolated {
    // 必须在 AppDelegate() 之前：Store 在初始化时就会读贴边开关和提醒记录
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
