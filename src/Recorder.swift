//
//  Recorder.swift
//  书办（ShuBan）· 屏幕录制引擎
//
//  能力来自此前独立做过的一个录屏工具，这里只继承机制、不继承外观，
//  并且整条链路换成 Swift 原生实现（原来那层 Python/tkinter 一行没留）。
//  四件事是这套东西的命门，踩过坑才知道要这么做：
//
//  1) 采集只能用 /usr/sbin/screencapture -v
//     `screencapture -v -x [-g 收麦克风] [-k 点击高亮] [-R x,y,w,h | -D 屏号] [-V 秒] 输出`
//     它是「停止时才封装写出」的模式 —— 录制期间目标文件恒为 0 字节，
//     所以绝不能用文件大小判断「是否在录」（曾经因此把已经成功的录制误判成失败掐掉）。
//     判活性改看进程 CPU 时间增量。
//
//  2) 停止必须走阶梯：SIGINT → SIGTERM → 最后才 SIGKILL
//     SIGINT 让 screencapture 正常写完 moov；SIGKILL 会让系统采集会话释放不掉，
//     之后所有录制（包括别的软件）全变黑屏，只能注销重登。强杀过就要明确告诉用户。
//
//  3) 自家界面不能进成片：NSWindow.sharingType = .none
//     这就是系统给「本机看得见、录屏拿不到」留的正门（密码管理器同款）。
//     悬浮条和书办面板都标上它，录制时不用把界面藏起来也照样干净。
//
//  4) 权限要以「本应用」身份申请
//     子进程 screencapture 不会触发授权弹窗，系统也不会把书办登记进
//     「隐私与安全性 → 屏幕录制」列表（用户在列表里根本找不到可勾的项）。
//     必须主进程自己调 CGRequestScreenCaptureAccess()。
//     授权后不重启不生效 —— 这是系统的硬规定，界面上要直说。
//

import SwiftUI
import AppKit
import CoreGraphics
import AVFoundation

// MARK: - 录制范围

enum RecRange: Int, CaseIterable, Identifiable {
    case full = 0      // 主屏整屏
    case region = 1    // 框选一块
    case second = 2    // 第二块屏

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .full: return "主屏"
        case .region: return "选区"
        case .second: return "副屏"
        }
    }

    var hint: String {
        switch self {
        case .full: return "录整个主屏，最省心"
        case .region: return "只录框出来的一块，做教程干净"
        case .second: return "录第二块屏，主屏留给自己的笔记"
        }
    }
}

// MARK: - 结果

struct RecResult: Equatable {
    let path: URL
    let seconds: Double
    let bytes: Int
    let hasAudio: Bool
    let hasVideo: Bool
    var note: String = ""        // 收尾时的软问题（成片偏短 / 被强杀过）
    var shared: URL? = nil       // 已生成的分享版
}

// MARK: - ffmpeg 侧的杂活（全部 nonisolated，可以丢到后台线程跑）

nonisolated enum Media {
    static let screencapture = "/usr/sbin/screencapture"

    /// Finder/Dock 启动时 PATH 只剩 /usr/bin:/bin:/usr/sbin:/sbin，
    /// 所以必须按绝对路径找，不能靠 which。
    static let ffmpeg: String? = {
        let fm = FileManager.default
        for p in ["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg",
                  "/opt/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        where fm.isExecutableFile(atPath: p) { return p }
        return nil
    }()

    static var hasFFmpeg: Bool { ffmpeg != nil }

    /// 屏幕录制权限：只预检、不弹窗
    static var screenGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// 以本应用身份申请（会把本应用登记进系统授权列表并按需弹窗）
    @discardableResult
    static func requestScreen() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: 麦克风权限（不授权就绝不能带 -g 起采集）

    /// 麦克风已授权
    static var micGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    /// 还没问过：系统弹窗可能正挂着
    static var micUndetermined: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined }
    /// 一次都没申请过（本进程内）就申请一次
    static func requestMic() { AVCaptureDevice.requestAccess(for: .audio) { _ in } }

    /// 等用户把授权弹窗点掉，返回最终是否可用。
    ///
    /// ⚠️ 为什么必须等：`screencapture -g` 在麦克风没授权、弹窗还挂着的时候**不会退出**，
    /// 进程就一直卡在那儿 —— 自检卡在「正在录…」，正式录制则是「停止后文件不存在、stderr 为空」。
    /// 之前那条「偶发录完没文件」的记录，根因大概率就是这个（重建签名后麦克风授权被重置）。
    static func awaitMic(seconds: Double) -> Bool {
        if micGranted { return true }
        if micUndetermined { requestMic() }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if micGranted { return true }
            if !micUndetermined { return false }   // 用户已经拒绝，不用再等
            Thread.sleep(forTimeInterval: 0.2)
        }
        return micGranted
    }

    /// 仍在跑的录制会话。并发录制会互相抢采集通道，表现就是黑屏。
    static func strayCaptures() -> [String] {
        let (rc, out) = run("/bin/pgrep", ["-f", "screencapture -v"], timeout: 8)
        guard rc == 0 else { return [] }
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// 进程累计 CPU 秒（判活的唯一可靠手段，见文件头第 1 条）
    static func cpuSeconds(_ pid: Int32) -> Double? {
        let (rc, out) = run("/bin/ps", ["-o", "cputime=", "-p", "\(pid)"], timeout: 5)
        guard rc == 0 else { return nil }
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let nums = parts.compactMap { Double($0) }
        guard nums.count == parts.count else { return nil }
        if nums.count == 2 { return nums[0] * 60 + nums[1] }
        return nums[0] * 3600 + nums[1] * 60 + nums[2]
    }

    /// 只回参数、不回可执行文件本身：executableURL 已经指了 /usr/sbin/screencapture，
    /// 再把路径塞进 arguments 里，argv 就成了 [exe, exe, -v, ...] ——
    /// 第二个 exe 会被 screencapture 当成输出文件名，报
    /// 「cannot write file to intended destination, /usr/sbin/screencapture」（实测踩过）
    static func captureArgs(rect: CGRect?, display: Int?, audio: Bool,
                            clicks: Bool, limit: Int?, out: String) -> [String] {
        var a = ["-v", "-x"]
        if audio { a.append("-g") }
        if clicks { a.append("-k") }
        if let r = rect {
            a += ["-R", "\(Int(r.minX.rounded())),\(Int(r.minY.rounded())),"
                    + "\(Int(r.width.rounded())),\(Int(r.height.rounded()))"]
        } else if let d = display {
            a.append("-D\(d)")
        }
        // ⚠️ -V 的数值必须紧贴：`-V 2` 会被解析成「-V 没有值 + 2 当输出文件名」，
        // 于是既不限时、又把片子写到名为 "2" 的地方，进程永不退出 ——
        // 表现就是自检永远卡在「正在录…」、强杀后一个文件都没有。
        // 2026-11-22 实测：`-V 2` 8 秒仍无文件，`-V2` 2 秒就正常出片（81690 字节）。
        // （-R 分开写实测可用，保持原样；-D 同样按 usage 里的 `-D<display>` 贴合写法。）
        if let l = limit { a.append("-V\(l)") }
        a.append(out)
        return a
    }

    /// 同步跑一条命令，stdout+stderr 合并返回。超时用 terminate（不是 kill）。
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "\(error)") }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: 成片体检

    static func fmtDuration(_ sec: Double) -> String {
        let s = Int(sec.rounded())
        let h = s / 3600, m = (s % 3600) / 60, ss = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss)
                     : String(format: "%02d:%02d", m, ss)
    }

    static func fmtSize(_ n: Int) -> String {
        let d = Double(n)
        if d < 1024 { return "\(n) B" }
        if d < 1048576 { return String(format: "%.1f KB", d / 1024) }
        if d < 1073741824 { return String(format: "%.1f MB", d / 1048576) }
        return String(format: "%.2f GB", d / 1073741824)
    }

    static func bytes(of url: URL) -> Int {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey])
        return v?.fileSize ?? 0
    }

    static func tail(_ url: URL?, _ limit: Int = 600) -> String {
        guard let url, let d = try? Data(contentsOf: url),
              let s = String(data: d, encoding: .utf8) else { return "" }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > limit ? String(t.suffix(limit)) : t
    }

    // MARK: 体检三件套

    /// (时长, 有视频轨, 有音频轨)
    static func probe(_ path: String) -> (Double?, Bool, Bool) {
        guard let f = ffmpeg else { return (nil, false, false) }
        let (_, txt) = run(f, ["-hide_banner", "-i", path], timeout: 20)
        var dur: Double?
        if let g = group(#"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)"#, txt, 3) {
            dur = (Double(g[0]) ?? 0) * 3600 + (Double(g[1]) ?? 0) * 60 + (Double(g[2]) ?? 0)
        }
        return (dur, txt.contains("Video:"), txt.contains("Audio:"))
    }

    /// 平均亮度：没拿到「屏幕录制」权限时录出来是纯黑，YAVG 会贴着 0。
    /// 阈值 6 沿用之前实测出来的分界（正常桌面再怎么暗也在 20 以上）。
    static func luma(_ path: String) -> Double? {
        guard let f = ffmpeg else { return nil }
        let (_, txt) = run(f, ["-hide_banner", "-v", "error", "-i", path, "-an", "-t", "12",
                               "-vf", "scale=160:-1,signalstats,metadata=print:file=-",
                               "-f", "null", "-"], timeout: 60)
        let vals = matches(#"lavfi\.signalstats\.YAVG=([0-9.]+)"#, txt).compactMap { Double($0) }
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    /// (平均 dB, 峰值 dB)；峰值 nil = 整条音轨静音
    static func volume(_ path: String) -> (Double?, Double?)? {
        guard let f = ffmpeg else { return nil }
        let (_, txt) = run(f, ["-hide_banner", "-i", path, "-vn",
                               "-af", "volumedetect", "-f", "null", "-"], timeout: 90)
        guard txt.contains("mean_volume") else { return nil }
        return (dbValue("mean_volume", txt), dbValue("max_volume", txt))
    }

    private static func dbValue(_ key: String, _ txt: String) -> Double? {
        guard let raw = group(key + #":\s*(-?[\d.]+|-inf)"#, txt, 1) else { return nil }
        return raw[0] == "-inf" ? nil : Double(raw[0])
    }

    private static func group(_ pattern: String, _ text: String, _ n: Int) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var out: [String] = []
        for i in 1...n where i < m.numberOfRanges {
            let r = m.range(at: i)
            guard r.location != NSNotFound else { return nil }
            out.append(ns.substring(with: r))
        }
        return out.count == n ? out : nil
    }

    private static func matches(_ pattern: String, _ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    /// 分享版：硬件编码 + 画面限 1080p + faststart（边下边播，发微信/网页友好）
    static func compress(_ src: URL, _ dst: URL) -> Bool {
        guard let f = ffmpeg else { return false }
        _ = run(f, ["-hide_banner", "-y", "-i", src.path,
                    "-vf", "scale='min(1920,iw)':-2",
                    "-c:v", "h264_videotoolbox", "-b:v", "2500k",
                    "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "128k",
                    "-movflags", "+faststart", dst.path], timeout: 1800)
        return bytes(of: dst) > 4096
    }
}

// MARK: - 录制引擎

@MainActor
final class Recorder: ObservableObject {
    enum Phase: Equatable {
        case idle
        case countdown(Int)
        case recording
        case finishing
        case done(RecResult)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var granted = Media.screenGranted
    /// 已框选的区域（屏幕采集坐标系：原点在主屏左上角、y 向下）
    @Published private(set) var region: CGRect?
    @Published var compressing = false
    @Published var statusLine = ""

    // 设置（持久化）
    @Published var range: RecRange { didSet { save("shuban.rec.range", range.rawValue) } }
    @Published var audio: Bool { didSet { save("shuban.rec.audio", audio) } }
    @Published var clicks: Bool { didSet { save("shuban.rec.clicks", clicks) } }
    @Published var countdown: Int { didSet { save("shuban.rec.countdown", countdown) } }
    @Published var reveal: Bool { didSet { save("shuban.rec.reveal", reveal) } }

    /// 书办主面板：只为「不入镜」这件事做验证时取它的 frame
    weak var mainWindow: NSWindow?
    /// 录制状态翻转 → AppDelegate 把主面板 sharingType 切走/切回
    var onRecordingStateChange: ((Bool) -> Void)?
    /// 出成片了 → 把面板拉到前面，免得用户找不到结果
    var onPresentResult: (() -> Void)?
    /// 点「重启书办」前留个记号（重启回来还落在录屏页，不然看不出重启成功了）
    var onRelaunch: (() -> Void)?
    /// 关键动作写到 data/ui.log：「点了重启」这种事必须留痕，否则事后无从判断点击有没有送达
    var onLog: ((String) -> Void)?

    let outDir: URL = {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("屏幕录制")
    }()

    private var proc: Process?
    private var exited = ExitFlag()
    private var errURL: URL?
    private var outputPath: URL?
    private var startedAt: Date?
    private var timer: Timer?
    private var countdownTimer: Timer?
    private var countLeft = 0
    private var hangDetected = false
    /// 本次实际是否收声：设置里开了、但系统没授权时自动降级成只录画面
    private var audioThisRun = false
    /// 正在等麦克风授权弹窗被点掉（此时不算录制中，但也不许重复点开始）
    private var waitingMic = false
    /// 已经在走重启流程：连点两下不能起两个 helper
    private var relaunching = false
    private var hud: RecHUD?
    private let d = UserDefaults.standard

    var isRecording: Bool { if case .recording = phase { return true }; return false }
    var isBusy: Bool {
        switch phase {
        case .countdown, .recording, .finishing: return true
        default: return false
        }
    }
    var hasSecondScreen: Bool { NSScreen.screens.count >= 2 }
    /// 麦克风到底有没有系统授权（界面据此提示「这次只录画面」）
    var micGranted: Bool { Media.micGranted }

    var timerText: String { Media.fmtDuration(elapsed) }

    /// 验收路径不复用用户偏好，也别让测试把「录完打开 Finder」「倒计时」改掉
    var revealOverride: Bool?
    var countdownOverride: Int?
    var lastResultPath: URL? { if case .done(let r) = phase { return r.path }; return nil }
    /// 悬浮条当前是否在屏上（验收钩子要确认「不入镜的那条确实画出来了」）
    var hudVisible: Bool { hud?.frame != nil }

    /// 面板上那行「录什么」的摘要
    var targetText: String {
        switch range {
        case .full:
            let s = NSScreen.screens.first?.frame.size ?? .zero
            return "\(Int(s.width)) × \(Int(s.height))"
        case .region:
            guard let r = region else { return "还没框选" }
            return "\(Int(r.width)) × \(Int(r.height))"
        case .second:
            guard NSScreen.screens.count >= 2 else { return "没有第二块屏" }
            let s = NSScreen.screens[1].frame.size
            return "\(Int(s.width)) × \(Int(s.height))"
        }
    }

    init() {
        let d = UserDefaults.standard
        range = RecRange(rawValue: (d.object(forKey: "shuban.rec.range") as? Int) ?? 0) ?? .full
        audio = (d.object(forKey: "shuban.rec.audio") as? Bool) ?? true
        clicks = (d.object(forKey: "shuban.rec.clicks") as? Bool) ?? true
        countdown = (d.object(forKey: "shuban.rec.countdown") as? Int) ?? 3
        reveal = (d.object(forKey: "shuban.rec.reveal") as? Bool) ?? true
    }

    private func save(_ key: String, _ v: Any) { d.set(v, forKey: key) }

    // MARK: 权限

    func refreshPermission() { granted = Media.screenGranted }

    func requestPermission() {
        Media.requestScreen()
        refreshPermission()
        if !granted {
            statusLine = "已把「书办」登记进授权列表，去系统设置勾上后重启书办"
            openPrivacy("Privacy_ScreenCapture")
        }
    }

    func openPrivacy(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(u)
        }
    }

    /// 授权改了必须重启才生效，给用户一个一键重启。
    ///
    /// ⚠️ 这个函数踩过一个很阴的坑（2026-11-22，菲哥报「点击重启，并没有重启」）：
    /// 原来写的是「后台队列 sleep 1 秒 → NSWorkspace.open，然后立刻 NSApp.terminate」。
    /// terminate 是同步的，applicationWillTerminate 一返回进程就 exit()，
    /// 后台队列里那个还躺在 Thread.sleep 里的 block 会被一起带走 ——
    /// 只有退出流程本身恰好超过 1 秒（正在录屏要等 shutdownSync、或刷新子进程要收尾）
    /// 那次 open 才跑得到。表现就是「有时能重启、有时点了一点反应都没有」，随机复现。
    /// 正确做法：把「等本进程死掉再拉起」交给一个独立的小 shell。
    /// 子进程在父进程退出后被 launchd 收养，不受 exit() 影响。
    func relaunch() {
        guard !relaunching else { return }
        relaunching = true
        statusLine = "正在重启…"
        onRelaunch?()

        let url = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // $0=sh $1=bundle 路径。kill -0 只探活不发信号；进程一消失立刻拉起。
        // 上限 100 次 × 0.1s：万一退出被卡住，宁可这次没起来，也别让 helper 永久挂着。
        helper.arguments = ["-c",
            "i=0; while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; "
            + "i=$((i+1)); [ $i -gt 100 ] && break; done; "
            + "/usr/bin/open -n \"$1\"", "sh", url.path]
        do {
            try helper.run()
        } catch {
            relaunching = false
            statusLine = "重启失败：\(error.localizedDescription)"
            onLog?("重启失败：\(error.localizedDescription)")
            return
        }
        onLog?("点了「重启书办」：子进程 \(helper.processIdentifier) 等 pid \(pid) 退出后拉起")
        NSApp.terminate(nil)
    }

    // MARK: 框选

    func pickRegion() {
        guard !isBusy else { return }
        RegionPicker.shared.pick { [weak self] rect in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let rect {
                    self.region = rect
                    self.range = .region
                    self.statusLine = "已框选 \(Int(rect.width)) × \(Int(rect.height))"
                }
            }
        }
    }

    // MARK: 开始

    func start() {
        guard !isBusy, !waitingMic else { return }
        hangDetected = false

        guard Media.screenGranted else {
            granted = false
            requestPermission()
            phase = .failed("还差「屏幕录制」权限。系统设置 → 隐私与安全性 → 屏幕录制，"
                            + "勾上「书办」后点「重启书办」。")
            return
        }
        granted = true

        if range == .region && region == nil {
            phase = .failed("先框一块区域再开始。")
            return
        }
        if range == .second && !hasSecondScreen {
            phase = .failed("没检测到第二块屏幕，换「主屏」或「选区」。")
            return
        }
        let stray = Media.strayCaptures()
        if !stray.isEmpty {
            phase = .failed("已经有录屏会话在跑（pid \(stray.joined(separator: " "))）。"
                            + "并发录制会抢同一条采集通道，先把它停掉。")
            return
        }

        audioThisRun = audio
        if audio && !Media.micGranted {
            requestMicOnce()
            if Media.micUndetermined {
                // 弹窗正挂着：这时候起采集必卡死（screencapture -g 会一直不退出）。
                // 等用户点完再走，期间既不算录制中，也不允许重复点开始。
                waitingMic = true
                statusLine = "等你在系统弹窗里点一下「允许」…"
                DispatchQueue.global().async { [weak self] in
                    let ok = Media.awaitMic(seconds: 25)
                    DispatchQueue.main.async {
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.waitingMic = false
                            guard case .idle = self.phase else { return }  // 期间被取消/已开始
                            self.audioThisRun = ok
                            if !ok { self.statusLine = "麦克风没授权，这次只录画面" }
                            self.beginNow()
                        }
                    }
                }
                return
            }
            audioThisRun = false
            statusLine = "麦克风没授权，这次只录画面"
        }
        beginNow()
    }

    /// 权限都问清楚了，按设置走倒计时或直接开录
    private func beginNow() {
        let cd = countdownOverride ?? countdown
        if cd > 0 {
            startCountdown(cd)
        } else {
            reallyStart()
        }
    }

    /// 倒计时。用 Timer + 实例属性计数，而不是在闭包里捕获可变局部变量
    /// （异步闭包捕获 var 在严格并发下会报「captured var 并发可变」）。
    private func startCountdown(_ n: Int) {
        countLeft = n
        phase = .countdown(n)
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.countLeft -= 1
                if self.countLeft <= 0 {
                    self.countdownTimer?.invalidate()
                    self.countdownTimer = nil
                    self.reallyStart()
                } else {
                    self.phase = .countdown(self.countLeft)
                }
            }
        }
    }

    func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        phase = .idle
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    private func reallyStart() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        let fm = FileManager.default
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        let url = outDir.appendingPathComponent("书办录屏_\(Self.stamp.string(from: Date())).mp4")
        let err = FileManager.default.temporaryDirectory
            .appendingPathComponent("shuban_rec_\(Int(Date().timeIntervalSince1970)).log")
        fm.createFile(atPath: err.path, contents: Data())

        let rect: CGRect?
        switch range {
        case .full:
            let s = NSScreen.screens.first?.frame.size ?? CGSize(width: 1440, height: 900)
            rect = CGRect(x: 0, y: 0,
                          width: s.width - s.width.truncatingRemainder(dividingBy: 2),
                          height: s.height - s.height.truncatingRemainder(dividingBy: 2))
        case .region: rect = region
        case .second: rect = nil
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Media.screencapture)
        p.arguments = Media.captureArgs(rect: rect,
                                        display: range == .second ? 2 : nil,
                                        audio: audioThisRun, clicks: clicks,
                                        limit: nil, out: url.path)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = (try? FileHandle(forWritingTo: err)) ?? FileHandle.nullDevice

        if ProcessInfo.processInfo.environment["WECAL_REC_DEBUG"] == "1" {
            print("REC_ARGS \(p.arguments ?? [])")
            print("REC_OUT_DIR \(outDir.path) 可写=\(fm.isWritableFile(atPath: outDir.path))")
            print("REC_HOME \(NSHomeDirectory())")
        }
        let flag = ExitFlag()
        p.terminationHandler = { _ in
            flag.done = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.proc === p else { return }
                self.procDied()
            }
        }
        do {
            try p.run()
        } catch {
            phase = .failed("录屏引擎起不来：\(error.localizedDescription)")
            return
        }

        proc = p
        exited = flag
        errURL = err
        outputPath = url
        startedAt = Date()
        elapsed = 0
        phase = .recording
        onRecordingStateChange?(true)
        hud = RecHUD(recorder: self)
        hud?.show()
        tickTimer()

        // 活性看门狗：录制满 10 秒后，CPU 增量仍贴着 0 → 引擎根本没在干活
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.watchdog() }
        statusLine = "正在录制 · 停止时才会封装写文件"
    }

    private func tickTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard case .recording = self.phase, let t = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(t)
                if self.exited.done { self.procDied() }   // 秒退 = 权限没给
            }
        }
    }

    private func watchdog() {
        guard isRecording, let pid = proc?.processIdentifier else { return }
        let first = Media.cpuSeconds(pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.isRecording else { return }
            guard let a = first, let b = Media.cpuSeconds(pid) else {
                self.watchdog(); return            // 采样不可用：宁可放过，不可错杀
            }
            if b - a < 0.02 {
                self.hangDetected = true
                self.statusLine = "录制引擎没有响应，正在安全中止…"
                self.stop()
                return
            }
            self.watchdog()
        }
    }

    /// 录制期间进程意外退出（最常见就是权限没给，screencapture 直接秒退）
    private func procDied() {
        guard isRecording else { return }
        timer?.invalidate(); timer = nil
        hud?.close(); hud = nil
        onRecordingStateChange?(false)
        let err = Media.tail(errURL)
        proc = nil
        phase = .failed("录制引擎启动后就退出了，通常是没有「屏幕录制」权限"
                        + "（改完权限必须重启书办）。"
                        + (err.isEmpty ? "" : "\n\n\(err)"))
        statusLine = "录制失败"
    }

    // MARK: 停止

    func stop() {
        guard isRecording, let p = proc else { return }
        let el = startedAt.map { Date().timeIntervalSince($0) } ?? elapsed
        let err = errURL
        let outPath = outputPath?.path ?? ""
        let fk = exited          // 阶梯结束后可读它的 done
        timer?.invalidate(); timer = nil
        hud?.close(); hud = nil
        proc = nil
        phase = .finishing
        statusLine = "正在封装写入文件…"

        DispatchQueue.global().async { [weak self] in
            var killed = false
            let dbg = ProcessInfo.processInfo.environment["WECAL_REC_DEBUG"] == "1"
            if dbg { print("REC_STOP 进阶梯 running=\(p.isRunning) elapsed=\(String(format: "%.1f", el))") }
            if p.isRunning {
                p.interrupt()                       // SIGINT：正常收尾，moov 写全
                if !Self.waitFor(fk, 8) {
                    p.terminate()                   // SIGTERM
                    if !Self.waitFor(fk, 8) {
                        killed = true               // 最后手段，后果见文件头第 2 条
                        kill(p.processIdentifier, SIGKILL)
                        _ = Self.waitFor(fk, 5)
                    }
                }
            }
            let errText = Media.tail(err)
            if dbg {
                print("REC_STOP 阶梯结束 killed=\(killed) exit=\(p.terminationStatus) "
                      + "size=\(Media.bytes(of: URL(fileURLWithPath: outPath))) "
                      + "err=\(errText.isEmpty ? "空" : errText)")
            }
            DispatchQueue.main.async {
                Task { @MainActor [weak self] in
                    self?.finalize(elapsed: el, forceKilled: killed, errText: errText)
                }
            }
        }
    }

    private nonisolated static func waitFor(_ flag: ExitFlag, _ secs: Double) -> Bool {
        let deadline = Date().addingTimeInterval(secs)
        while !flag.done && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        return flag.done
    }

    private func finalize(elapsed el: Double, forceKilled: Bool, errText: String) {
        guard case .finishing = phase else { return }
        onRecordingStateChange?(false)
        guard let url = outputPath else {
            phase = .failed("内部错误：没有拿到输出路径"); return
        }
        let size = Media.bytes(of: url)
        if ProcessInfo.processInfo.environment["WECAL_REC_DEBUG"] == "1" {
            print("REC_FIN size=\(size) path=\(url.path) 存在=\(FileManager.default.fileExists(atPath: url.path))")
        }
        if size < 4096 {
            granted = Media.screenGranted
            phase = .failed("没有生成有效视频。最常见的就是「屏幕录制」权限没给到书办"
                            + "（改完权限要重启书办）。"
                            + (errText.isEmpty ? "" : "\n\n\(errText)"))
            statusLine = "录制失败"
            return
        }
        if hangDetected {
            hangDetected = false
            phase = .failed("录制引擎中途卡住，已安全中止。若之后录出来是黑屏，"
                            + "说明系统采集通道被占住，注销重登即可恢复。")
            statusLine = "录制中止"
            return
        }

        statusLine = "正在体检成片…"
        DispatchQueue.global().async { [weak self] in
            let (dur, hv, ha) = Media.probe(url.path)
            let luma = hv ? Media.luma(url.path) : nil
            let vol = ha ? Media.volume(url.path) : nil
            DispatchQueue.main.async {
                Task { @MainActor [weak self] in
                    self?.finishCheck(url: url, size: size, dur: dur, hv: hv, ha: ha,
                                      luma: luma, vol: vol, elapsed: el, forceKilled: forceKilled)
                }
            }
        }
    }

    private func finishCheck(url: URL, size: Int, dur: Double?, hv: Bool, ha: Bool,
                             luma: Double?, vol: (Double?, Double?)?,
                             elapsed el: Double, forceKilled: Bool) {
        var notes: [String] = []
        if forceKilled {
            notes.append("录制进程当时拒绝正常退出。若接下来录制出现黑屏，注销重登就能恢复。")
        }
        if let d = dur, hv, el > 3, d < el * 0.6 {
            notes.append("成片 \(Media.fmtDuration(d)) 明显短于实际录制 \(Media.fmtDuration(el))，画面可能有丢帧。")
        }
        if hv, let l = luma, l < 6 {
            notes.append("画面几乎全黑（亮度 \(String(format: "%.0f", l))）——十有八九是屏幕录制权限没生效。")
        }
        if ha, let v = vol, v.1 == nil {
            notes.append("有音轨但全程静音：确认下麦克风权限、以及默认输入设备选没选对。")
        }
        let result = RecResult(path: url, seconds: dur ?? el, bytes: size,
                               hasAudio: ha, hasVideo: hv,
                               note: notes.joined(separator: "\n"))
        phase = .done(result)
        statusLine = "已保存 " + url.lastPathComponent
        if revealOverride ?? reveal {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        onPresentResult?()
    }

    func reset() { phase = .idle; statusLine = "" }

    /// 退出书办时把正在录的那条掐掉。
    /// 不管它的话，screencapture 会变成孤儿：管道断了、成片废掉，
    /// 更糟的是系统采集会话一直被占，之后谁录都是黑屏。
    func shutdownSync() {
        countdownTimer?.invalidate(); countdownTimer = nil
        guard isRecording, let p = proc else { return }
        timer?.invalidate(); timer = nil
        let flag = exited
        p.interrupt()
        let deadline = Date().addingTimeInterval(3)
        while !flag.done && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if !flag.done { p.terminate() }
        hud?.close()
        hud = nil
        proc = nil
    }

    // MARK: 分享版 / 打开

    func compressShare() {
        guard case .done(let r) = phase, !compressing else { return }
        guard Media.hasFFmpeg else {
            statusLine = "没找到 ffmpeg，分享版压缩用不了（录制不受影响）"
            return
        }
        compressing = true
        statusLine = "正在生成分享版…"
        let src = r.path
        let dst = URL(fileURLWithPath: src.deletingPathExtension().path + "_分享版.mp4")
        DispatchQueue.global().async { [weak self] in
            let ok = Media.compress(src, dst)
            DispatchQueue.main.async {
                Task { @MainActor [weak self] in
                    guard let self, case .done(var cur) = self.phase else { return }
                    self.compressing = false
                    if ok {
                        cur.shared = dst
                        self.phase = .done(cur)
                        self.statusLine = "分享版 " + Media.fmtSize(Media.bytes(of: dst))
                            + "（原片 " + Media.fmtSize(Media.bytes(of: src)) + "）"
                        NSWorkspace.shared.activateFileViewerSelecting([dst])
                    } else {
                        self.statusLine = "压缩失败，原片没动"
                    }
                }
            }
        }
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openFolder() {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outDir)
    }

    /// 自检：录 2 秒小片段，把「权限 / 画面 / 麦克风」三件事一次说清
    @Published var checking = false
    @Published var checkLines: [String] = []

    func selfCheck() {
        guard !isBusy, !checking else { return }
        // 申请必须在主线程做（CGRequestScreenCaptureAccess 要弹系统窗）
        if !Media.screenGranted {
            Media.requestScreen()
            granted = Media.screenGranted
            if !granted {
                checkLines = ["✗ 屏幕录制：还没授权。已把「书办」登记进系统列表，"
                              + "勾上之后点「重启书办」才会生效。"]
                statusLine = "自检未通过：缺「屏幕录制」权限"
                openPrivacy("Privacy_ScreenCapture")
                return
            }
        }
        checking = true
        checkLines = []
        statusLine = "正在录 2 秒测试片段验证权限…"
        // 没授权就绝不带 -g：麦克风弹窗挂着时 screencapture 不会退出，自检会永远停在「正在录…」
        if audio && !Media.micGranted && Media.micUndetermined { Media.requestMic() }
        let wantAudioSetting = audio
        let wantAudio = audio && Media.micGranted
        DispatchQueue.global().async { [weak self] in
            var lines: [String] = []
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("shuban_check_\(Int(Date().timeIntervalSince1970)).mp4")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Media.screencapture)
            p.arguments = Media.captureArgs(rect: CGRect(x: 0, y: 0, width: 480, height: 360),
                                            display: nil, audio: wantAudio, clicks: false,
                                            limit: 2, out: tmp.path)
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            // 看门狗：`-V 2` 正常 2 秒就退，卡住说明采集通道或授权有问题。
            // 不能直接 waitUntilExit —— 那会把 checking 永久钉在 true，界面看着像死机。
            var waited = 0.0
            while p.isRunning && waited < 20 {
                Thread.sleep(forTimeInterval: 0.2)
                waited += 0.2
            }
            var hung = false
            if p.isRunning {
                hung = true
                p.terminate()
                Thread.sleep(forTimeInterval: 0.6)
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
            let size = Media.bytes(of: tmp)
            let (dur, hv, ha) = size > 4096 ? Media.probe(tmp.path) : (nil, false, false)
            let luma = hv ? Media.luma(tmp.path) : nil
            let vol = ha ? Media.volume(tmp.path) : nil
            try? FileManager.default.removeItem(at: tmp)
            lines.append(size > 4096 && hv
                ? (luma != nil && luma! < 6
                    ? "✗ 屏幕录制：画面全黑（亮度 \(String(format: "%.0f", luma!))），权限没生效"
                    : "✓ 屏幕录制：正常" + (luma.map { "（亮度 \(String(format: "%.0f", $0))）" } ?? ""))
                : "✗ 屏幕录制：没录到画面，权限没生效")
            if hung {
                lines.append("✗ 采集 20 秒没退出，已强杀：采集通道被占住了，注销重登能彻底恢复")
            }
            if wantAudio {
                if !ha { lines.append("✗ 麦克风：没有音频轨，缺权限或设备被占用") }
                else if let v = vol, v.1 == nil { lines.append("! 麦克风：有音轨但全程静音") }
                else if let v = vol, let mx = v.1 { lines.append("✓ 麦克风：正常（峰值 \(String(format: "%.1f", mx)) dB）") }
                else { lines.append("✓ 麦克风：已录到音轨") }
            } else if wantAudioSetting {
                lines.append(Media.micUndetermined
                    ? "! 麦克风：授权弹窗还没点，这次只验了画面"
                    : "✗ 麦克风：没授权（系统设置 → 隐私与安全性 → 麦克风）；不勾也能只录画面")
            } else {
                lines.append("– 麦克风：按设置不录声音")
            }
            lines.append(Media.hasFFmpeg
                ? "✓ ffmpeg：分享版压缩可用" : "! 没找到 ffmpeg：只能录，不能压分享版")
            if let d = dur {
                lines.append("· 测试片段 \(Media.fmtDuration(d)) · \(Media.fmtSize(size))")
            }
            DispatchQueue.main.async {
                Task { @MainActor [weak self] in
                    self?.checking = false
                    self?.granted = Media.screenGranted
                    self?.checkLines = lines
                    self?.statusLine = "自检完成"
                }
            }
        }
    }

    private var micRequested = false
    private func requestMicOnce() {
        guard !micRequested else { return }
        micRequested = true
        // 麦克风权限同样要以本应用身份申请，否则子进程收声会被系统静默拒绝
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }
}

/// 子进程退出标记：terminationHandler 写、停止阶梯在后台线程轮询
final class ExitFlag: @unchecked Sendable {
    private let q = DispatchQueue(label: "shuban.exitflag")
    private var _done = false
    var done: Bool {
        get { q.sync { _done } }
        set { q.sync { _done = newValue } }
    }
}

// MARK: - 录制中悬浮条

@MainActor
final class RecHUD {
    private var window: NSPanel?
    weak var recorder: Recorder?

    init(recorder: Recorder) {
        self.recorder = recorder
    }

    func show() {
        guard window == nil, let recorder else { return }
        // 卡片 258×52，外面再留 10pt 给 SwiftUI 画的投影（窗口必须比卡片大，否则投影被切）
        let size = NSSize(width: 278, height: 72)
        let host = NSHostingView(rootView: RecHUDView(recorder: recorder))
        host.frame = NSRect(origin: .zero, size: size)

        let w = HUDPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // 关键：悬浮条要录制人看得见、但不能进成片
        w.sharingType = .none
        w.contentView = host
        if let scr = NSScreen.screens.first {
            let vf = scr.visibleFrame
            w.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 18))
        }
        w.orderFrontRegardless()
        window = w
    }

    var frame: NSRect? { window?.frame }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

/// 悬浮条要能点「停止」，所以允许成为 key（非激活面板默认不给）
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct RecHUDView: View {
    @ObservedObject var recorder: Recorder
    @State private var pulse = false

    // 悬浮条是独立窗口，不吃面板那套缩放系数，全部用固定字号
    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(Color.white.opacity(0.55))
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 2.4 : 1)
                    .opacity(pulse ? 0 : 0.9)
                Circle().fill(Color.white).frame(width: 8, height: 8)
            }
            .frame(width: 20, height: 20)
            .onAppear {
                withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) { pulse = true }
            }

            Text(recorder.timerText)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.white)
            Text("录制中")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
            Spacer(minLength: 6)
            Button { recorder.stop() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                    Text("停止").font(.system(size: 11.5, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.20)))
                .overlay(Capsule().stroke(Color.white.opacity(0.40), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 13)
        .frame(width: 258, height: 52)
        .background(
            ZStack {
                LinearGradient(colors: [Theme.sched, Theme.redDeep],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: [Color.white.opacity(0.16), .clear],
                               startPoint: .top, endPoint: .bottom)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Theme.todo.opacity(0.6), lineWidth: 1))
        .shadow(color: Theme.redDeep.opacity(0.5), radius: 10, y: 4)
        .padding(10)     // 给投影留出窗口内的空间
        .frame(width: 278, height: 72)
    }
}

// MARK: - 框选区域

@MainActor
final class RegionPicker {
    static let shared = RegionPicker()
    private var window: NSWindow?
    private var completion: ((CGRect?) -> Void)?

    func pick(_ completion: @escaping (CGRect?) -> Void) {
        guard window == nil else { completion(nil); return }
        self.completion = completion

        // 覆盖所有屏幕的并集，跨屏也能框
        let union = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let w = NSWindow(contentRect: union, styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isMovable = false

        let v = RegionPickView(frame: NSRect(origin: .zero, size: union.size))
        v.onDone = { [weak self] local in self?.finish(local, union: union) }
        w.contentView = v
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    /// 窗口坐标（左下原点）→ screencapture 的采集坐标（主屏左上原点、y 向下）
    private func finish(_ local: CGRect?, union: NSRect) {
        window?.orderOut(nil)
        window = nil
        let cb = completion
        completion = nil
        guard let local else { cb?(nil); return }
        let global = local.offsetBy(dx: union.minX, dy: union.minY)
        let mainMaxY = (NSScreen.screens.first(where: { $0.frame.origin == .zero })
                        ?? NSScreen.main ?? NSScreen.screens.first!).frame.maxY
        var r = CGRect(x: global.minX, y: mainMaxY - global.maxY,
                       width: global.width, height: global.height)
        r.size.width -= r.size.width.truncatingRemainder(dividingBy: 2)   // H.264 要偶数
        r.size.height -= r.size.height.truncatingRemainder(dividingBy: 2)
        cb?(r)
    }
}

final class RegionPickView: NSView {
    var onDone: ((CGRect?) -> Void)?
    private var anchor: NSPoint?
    private var cursor: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: CGRect? {
        guard let a = anchor, let c = cursor else { return nil }
        return CGRect(x: min(a.x, c.x), y: min(a.y, c.y),
                      width: abs(c.x - a.x), height: abs(c.y - a.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.36).setFill()
        bounds.fill()

        // 框内挖空：copy 模式把这块像素置回透明，桌面原样透出来
        if let r = selection {
            NSGraphicsContext.saveGraphicsState()
            NSColor.clear.setFill()
            r.fill(using: .copy)
            NSGraphicsContext.restoreGraphicsState()

            NSColor(Theme.sched).setStroke()
            let p = NSBezierPath(rect: r); p.lineWidth = 2; p.stroke()
            NSColor(Theme.todo).withAlphaComponent(0.9).setStroke()
            let inner = NSBezierPath(rect: r.insetBy(dx: 3.5, dy: 3.5)); inner.lineWidth = 1; inner.stroke()
            drawSizeLabel("\(Int(r.width)) × \(Int(r.height))", near: r)
        }
        drawHint()
    }

    private func label(_ s: String, _ font: NSFont, _ fg: NSColor, _ bg: NSColor) -> NSAttributedString {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        return NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: fg, .backgroundColor: bg, .paragraphStyle: p,
        ])
    }

    private func drawHint() {
        let s = label("拖动框选要录的区域　·　Esc 取消",
                      .systemFont(ofSize: 15, weight: .semibold), .white,
                      NSColor(Theme.sched))
        let size = s.size()
        let x = bounds.midX - size.width / 2 - 14
        let y = bounds.maxY - 66
        let pill = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: size.width + 28, height: size.height + 16),
                                xRadius: (size.height + 16) / 2, yRadius: (size.height + 16) / 2)
        NSColor(Theme.sched).setFill(); pill.fill()
        NSColor(Theme.todo).withAlphaComponent(0.7).setStroke()
        let ring = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: size.width + 28, height: size.height + 16),
                                xRadius: (size.height + 16) / 2, yRadius: (size.height + 16) / 2)
        ring.lineWidth = 1; ring.stroke()
        s.draw(at: NSPoint(x: x + 14, y: y + 8))
    }

    private func drawSizeLabel(_ s: String, near r: CGRect) {
        let a = label(s, .systemFont(ofSize: 12, weight: .bold), .white, NSColor(Theme.redDeep))
        let sz = a.size()
        var box = NSRect(x: r.minX, y: r.maxY + 6, width: sz.width + 16, height: sz.height + 8)
        if box.maxY > bounds.maxY - 4 { box.origin.y = r.maxY - box.height - 6 }
        NSColor(Theme.redDeep).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        a.draw(at: NSPoint(x: box.minX + 8, y: box.minY + 4))
    }

    override func mouseDown(with e: NSEvent) {
        anchor = convert(e.locationInWindow, from: nil)
        cursor = anchor
        needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        cursor = convert(e.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        cursor = convert(e.locationInWindow, from: nil)
        let r = selection
        anchor = nil; cursor = nil
        guard let r, r.width >= 80, r.height >= 60 else { onDone?(nil); return }
        onDone?(r)
    }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { onDone?(nil) } else { super.keyDown(with: e) }
    }
}
