//
//  AudioBoard.swift
//  书办（ShuBan）· 听录（WMA 等格式的音频播放）
//
//  为什么要有它：macOS 自带的「音乐 / QuickTime / AVFoundation」都不认 WMA。
//  菲哥手里的原料是企业微信 WeDrive 和 Downloads 里的通话录音、管培录音，
//  清一色 WMA（实测编码是 wmav2 / wmapro），必须先借 ffmpeg 解码。
//
//  架构选择（详见 README 设计取舍 22）：**ffmpeg 整条解码成临时 WAV，交给 AVAudioPlayer 播**，
//  而不是自己起子进程边解边喂 PCM。理由是自己喂那条路上有两个必踩的坑 ——
//  缓冲写满丢数据（后半段声音乱）、以及位置数不准（进度条跳）。
//  AVAudioPlayer 白送 currentTime / duration / volume / 任意定位，代码少一大截且不出声噪。
//  代价是「解码要等一会儿」+「临时 WAV 占盘」，用缓存复用 + LRU 清理压住。
//
//  ⚠️ 一条血的教训（上一版 Python 实现踩过，这里必须记住）：
//  **解码子进程的 stderr 绝不能是没被读走的 PIPE。** wmapro 这类解码器会刷大量
//  "frame would have to skip" 的 error 级日志，写满 64KB 管道后 ffmpeg 直接阻塞，
//  表现是「播半秒就卡死」。所以解码时 stderr 一律重定向到临时文件，只在出错时读尾部。
//

import Foundation
import AppKit
import AVFoundation
import CoreAudio

// MARK: - 列表里的一条录音

/// 一条录音。**列表是盘上的镜像，不是内存账本** —— 每次刷新都以文件现状为准，
/// 被删掉、被挪走的自己掉出去（沿用录屏「最近录制」那条经验）。
struct ListenTrack: Identifiable, Equatable, Codable {
    var url: URL
    var size: Int
    var mtime: Date
    /// 探测出来的时长（秒）。0 = 还没探或探不出
    var dur: Double
    var title: String?
    var artist: String?
    var album: String?
    var hasArt: Bool

    var id: String { url.path }
    var ext: String { url.pathExtension.lowercased() }

    /// 显示名：优先标签里的标题，否则去掉扩展名的文件名。
    /// 通话录音基本没有标签，所以绝大多数时候看到的就是文件名 —— 那正是想要的。
    var name: String {
        if let t = title, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
        return url.deletingPathExtension().lastPathComponent
    }
}

// MARK: - 播放状态

enum ListenState: Equatable {
    case idle                       /// 没在放（也可能列表就是空的）
    case decoding(Double)           /// 正在解码，带百分比；探不到就 0（界面显示「解码中…」）
    case playing
    case paused
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .decoding, .playing: return true
        default: return false
        }
    }
}

// MARK: - 引擎

/// 听录的引擎 + 列表。一个窗口一个实例的假设不成立 —— 它是全局唯一的，
/// 因为**关掉窗口声音还得接着放**（菲哥的用法是边听录音边干活）。
final class AudioBoard: NSObject, ObservableObject, AVAudioPlayerDelegate {

    @Published private(set) var tracks: [ListenTrack] = []
    /// 正在放/选中哪一条；-1 = 没有
    @Published private(set) var index: Int = -1
    @Published private(set) var state: ListenState = .idle
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    /// 当前这条的封面 PNG 路径（有内嵌封面才解出来）
    @Published private(set) var coverURL: URL?
    /// 播放设备情况：一个都没有的时候 AVAudioPlayer 能「播」但听不见，得说清楚
    @Published private(set) var hasOutput: Bool = true

    /// 音量 0~1，跟系统各放各的：书办只调自己这条
    @Published var volume: Float { didSet {
        ud.set(Double(volume), forKey: "shuban.audio.volume")
        player?.volume = volume
    }}
    /// 放完自动切下一条（听一长串管培录音时的关键开关）
    @Published var autoNext: Bool { didSet { ud.set(autoNext, forKey: "shuban.audio.autoNext") } }

    /// 关键动作写 data/ui.log（点了什么、ffmpeg 什么返回码，事后无从判断时全靠它）
    var onLog: ((String) -> Void)?

    // MARK: 录音

    /// 录音台。电平、计时这些 20Hz 变的值都在它自己身上，
    /// 只有「进 / 出录音态」这一个布尔往回流 —— 否则整页会跟着电平 20Hz 重画
    let capture = AudioCapture()
    /// 此刻是不是在录音（界面据此把右边那张卡换成录音台）
    @Published private(set) var recActive = false
    /// 录音相关的最后一句话（「只录到 0.3 秒，太短没留」这种），下一动作就清掉
    @Published private(set) var recNote = ""
    /// 录屏正在跑：麦克风在它手里，这时候不许起录（会拿不到设备或录一段静音）
    @Published var screenRecording = false

    // MARK: 路径

    /// 解码缓存目录。默认放 Caches（系统会在盘紧时清），验收用 WECAL_AUDIO_CACHE 换走
    let cacheDir: URL = {
        if let d = ProcessInfo.processInfo.environment["WECAL_AUDIO_CACHE"], !d.isEmpty {
            return URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("书办/听录", isDirectory: true)
    }()

    /// 列表存档（只存路径顺序）。跟笔记一样放 data 下，拷走就是备份
    private var listDir: URL?
    private var configured = false
    private let ud = UserDefaults.standard

    // MARK: 播放

    private var player: AVAudioPlayer?
    private var posTimer: Timer?
    /// 解码代际号：换曲目时旧的解码结果必须作废，否则旧的先回来会把新的覆盖掉
    private var generation = 0
    private var decodeProc: Process?
    private var partialURL: URL?
    /// 串行解码队列：同一时刻只解一条，别把 CPU 抢满
    private let workQ = DispatchQueue(label: "shuban.audio.decode", qos: .userInitiated)

    /// 解码缓存最多留几条。语音录音一条几十 MB，留太多就是在占盘
    static let cacheKeep = 5

    override init() {
        volume = Float(ud.object(forKey: "shuban.audio.volume") as? Double ?? 0.85)
        autoNext = ud.object(forKey: "shuban.audio.autoNext") as? Bool ?? true
        super.init()
        hasOutput = AudioBoard.haveOutputDevice()
    }

    /// 配好存档位置后才读列表（和记事本一个套路：AppDelegate 知道工程目录才调用）
    ///
    /// 验收钩子：`WECAL_AUDIO_DIR` 换走列表存档目录。端到端用例要往列表里加临时样本、
    /// 删文件、清空列表 —— 不换走的话就是在拿菲哥真的曲目列表做试验田。
    func configure(projectDir: URL?) {
        guard !configured else { return }
        configured = true
        if let d = ProcessInfo.processInfo.environment["WECAL_AUDIO_DIR"], !d.isEmpty {
            listDir = URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let base = projectDir ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/ShuBan", isDirectory: true)
            listDir = base.appendingPathComponent("data/listen", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        load()
        refresh(silent: true)
        // 上次存的列表只记了路径，时长/标题是当场探出来的 —— 不补这一刀，
        // 重启之后整列都写着「时长未知」，要点开每条才一条条长回来（2026-11-24 拍图时发现）
        probeAll()
        // 录音台：录完的文件直接进列表，不经过用户手里的「添加」
        capture.configure(projectDir: projectDir)
        capture.onLog = { [weak self] line in self?.onLog?(line) }
        capture.onPhase = { [weak self] on in self?.recActive = on }
        capture.onFinish = { [weak self] url, sec in self?.absorbRecording(url, sec) }
        capture.onDrop = { [weak self] msg in self?.recNote = msg }
    }

    // MARK: - 录音

    /// 起录。返回 false = 没开成（界面据此保持原样）。
    ///
    /// 两件事必须先做掉：
    /// 1. **停掉正在放的声音** —— 否则外放会被自己录进去，回放时听到的是双重人声；
    /// 2. **让开录屏** —— 麦克风只能被一方拿住，硬抢的结果是「两个都没声音」。
    @discardableResult
    func beginRecording() -> Bool {
        guard !capture.isBusy else { return false }
        if screenRecording {
            state = .failed("录屏正占着麦克风：先把录屏停下，再来录音")
            onLog?("录音未开始：录屏进行中")
            return false
        }
        stop()
        recNote = ""
        capture.start()
        return true
    }

    /// 停录并保存（正常路径）
    func endRecording() { capture.stop() }

    /// 取消：连文件一起删
    func cancelRecording() { capture.cancel() }

    /// 外面（录屏 / 关窗）要收走麦克风时的统一入口：**录到的保住**，只停不删。
    /// 录音和「正在播放」不一样 —— 播放中断是少听一段，录音中断是丢现场。
    func yieldRecording(to why: String) {
        if capture.isRecording {
            capture.stop()
            onLog?("\(why) → 录音已保存并停止")
        } else if capture.phase.isArmed {
            capture.cancel()
        }
    }

    /// 录完的文件入列表。
    /// **不自动播** —— 录完往往是接着说的，突然从喇叭里放出自己的声音很怪；
    /// 选中高亮就好，要听自己点。
    private func absorbRecording(_ url: URL, _ sec: Double) {
        add([url])
        if let i = tracks.firstIndex(where: { $0.url.path == url.path }) {
            selectTrack(i, play: false)
        }
        recNote = ""
        onLog?("听录录到一条 \(url.lastPathComponent)（\(Media.fmtDuration(sec))）")
    }

    // MARK: - 列表：盘上的镜像

    /// 支持的后缀。ffmpeg 能解的远不止这些，但白名单能让「拖进来没反应」变成
    /// 「这条不支持」这种说得清的结果。
    static let playableExts: Set<String> = [
        "wma", "wav", "mp3", "m4a", "aac", "flac", "ogg", "oga", "opus",
        "aiff", "aif", "wv", "amr", "3gp", "mp2", "mka", "m4b", "ac3", "ape",
    ]

    static func isPlayable(_ url: URL) -> Bool {
        playableExts.contains(url.pathExtension.lowercased())
    }

    /// 收文件进列表：过滤不支持的、去重、保留已有条目的探测结果（不重复探）
    func add(_ urls: [URL], select: Bool = false) {
        let ok = urls.filter { AudioBoard.isPlayable($0) && FileManager.default.fileExists(atPath: $0.path) }
        let skipped = urls.count - ok.count
        var added = 0
        for u in ok where !tracks.contains(where: { $0.url.path == u.path }) {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            tracks.append(ListenTrack(url: u,
                                      size: v?.fileSize ?? Media.bytes(of: u),
                                      mtime: v?.contentModificationDate ?? Date(),
                                      dur: 0, title: nil, artist: nil, album: nil, hasArt: false))
            added += 1
        }
        if added > 0 {
            onLog?("听录加入 \(added) 条" + (skipped > 0 ? "（跳过 \(skipped) 个不支持的）" : ""))
            save()
            // 新加的探一遍元数据（时长/标题），后台做，别卡界面
            probeAll()
        } else if skipped > 0 {
            state = .failed("这 \(skipped) 个格式不支持（支持 WMA / MP3 / WAV / M4A / FLAC …）")
        }
        if select, let last = tracks.indices.last { selectTrack(last) }
    }

    /// 从列表移除。**只移出列表，绝不删文件** —— 这是录音原件，删了就没了
    func remove(_ t: ListenTrack) {
        guard let i = tracks.firstIndex(where: { $0.id == t.id }) else { return }
        tracks.remove(at: i)
        if index == i {
            stop()
            index = tracks.isEmpty ? -1 : min(i, tracks.count - 1)
        } else if index > i {
            index -= 1
        }
        save()
        onLog?("听录移出 \(t.name)（文件没动）")
    }

    func clearList() {
        stop()
        tracks = []
        index = -1
        save()
        onLog?("听录清空列表")
    }

    /// 重扫盘：文件被删/挪走 → 这一条自己掉；大小或 mtime 变了 → 缓存签名跟着变
    func refresh(silent: Bool = false) {
        guard !tracks.isEmpty else { return }
        var keep: [ListenTrack] = []
        var lost = 0
        for t in tracks {
            guard FileManager.default.fileExists(atPath: t.url.path) else { lost += 1; continue }
            var n = t
            let v = try? t.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            n.size = v?.fileSize ?? t.size
            n.mtime = v?.contentModificationDate ?? t.mtime
            keep.append(n)
        }
        guard keep.count != tracks.count || lost > 0 else {
            tracks = keep
            return
        }
        let wasPlaying = current?.id
        tracks = keep
        if let id = wasPlaying, !keep.contains(where: { $0.id == id }) {
            // 正在放的录音没了：停下来说清楚，别让进度条空转
            stop()
            index = keep.isEmpty ? -1 : 0
            state = keep.isEmpty ? .idle : .failed("正在放的录音已经不在了")
        } else if let i = keep.firstIndex(where: { $0.id == wasPlaying }) {
            index = i
        } else {
            index = min(max(index, 0), max(keep.count - 1, 0))
            if keep.isEmpty { index = -1 }
        }
        if lost > 0 {
            save()
            if !silent { onLog?("听录列表掉 \(lost) 条：文件不在了") }
        }
    }

    var current: ListenTrack? {
        (0..<tracks.count).contains(index) ? tracks[index] : nil
    }

    // MARK: - 播放控制

    /// 选中并（可选）开始放。播放中途换曲目 = 起新解码
    func selectTrack(_ i: Int, play: Bool = true) {
        guard (0..<tracks.count).contains(i) else { return }
        let same = (i == index)
        index = i
        let t = tracks[i]
        duration = t.dur
        position = 0
        coverURL = nil
        if play || state.isBusy || (same && state == .paused) {
            start(t)
        }
    }

    func toggle() {
        switch state {
        case .playing:
            player?.pause()
            state = .paused
            onLog?("听录暂停 \(current?.name ?? "")")
        case .paused:
            player?.play()
            state = .playing
            tickStart()
        case .decoding:
            break        // 解码中不响应，免得点一下把解码掐了
        case .failed, .idle:
            if let t = current { start(t) }
            else if !tracks.isEmpty { selectTrack(0) }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        posTimer?.invalidate()
        posTimer = nil
        killDecode()
        position = 0
        state = .idle
        coverURL = nil
    }

    func next() {
        guard !tracks.isEmpty else { return }
        selectTrack(min(index + 1, tracks.count - 1))
    }

    func prev() {
        guard !tracks.isEmpty else { return }
        // 听了 3 秒以上再点「上一首」= 回到这条开头，这是音乐播放器的通行做法
        if position > 3 { seek(0); return }
        selectTrack(max(index - 1, 0))
    }

    /// 拖动定位。WAV 是本地文件，定位瞬时，不需要像流式那样重启解码器
    func seek(_ sec: Double) {
        let s = max(0, min(sec, duration > 0 ? duration : sec))
        position = s
        player?.currentTime = s
    }

    // MARK: 解码 + 起播

    private func start(_ t: ListenTrack) {
        guard let ff = Media.ffmpeg else {
            state = .failed("没找到 ffmpeg。WMA 得靠它解码：装一下 brew install ffmpeg")
            return
        }
        killDecode()
        generation += 1
        let gen = generation
        player?.stop()
        player = nil
        posTimer?.invalidate()
        posTimer = nil
        position = 0
        coverURL = nil

        let out = AudioBoard.cachedWav(for: t, in: cacheDir)
        if FileManager.default.fileExists(atPath: out.path), Media.bytes(of: out) > 44 {
            state = .decoding(1.0)
            startPlayer(out, t: t, gen: gen)
            return
        }
        state = .decoding(0)
        let src = t.url
        let dur = t.dur
        let info = AudioBoard.parseInfo(AudioBoard.rawInfo(ff: ff, src: src))
        onLog?("听录开始解码 \(t.name)（\(Int(info.duration)) 秒，\(info.sampleRate) Hz \(info.channels) 声道）")
        workQ.async { [weak self] in
            guard let self else { return }
            self.runDecode(ffmpeg: ff, src: src, out: out, expect: info)
            DispatchQueue.main.async {
                guard self.generation == gen else { return }   // 期间换曲了，结果作废
                if FileManager.default.fileExists(atPath: out.path), Media.bytes(of: out) > 44 {
                    self.pruneCache(keep: AudioBoard.cacheKeep)
                    self.startPlayer(out, t: t, gen: gen)
                } else {
                    self.state = .failed("解码没出东西：" + Self.tailOf(out))
                    self.onLog?("听录解码失败 \(t.name)，期望 \(Self.human(dur)) 的 wav")
                }
            }
        }
        // 顺手探一次元数据（第一次放的时候补上时长/标题）
        if t.dur <= 0 {
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                let m = AudioBoard.parseInfo(AudioBoard.rawInfo(ff: ff, src: src))
                DispatchQueue.main.async {
                    guard let i = self.tracks.firstIndex(where: { $0.id == t.id }) else { return }
                    self.tracks[i].dur = m.duration
                    self.tracks[i].title = m.title
                    self.tracks[i].artist = m.artist
                    self.tracks[i].album = m.album
                    self.tracks[i].hasArt = m.hasArt
                    if self.index == i { self.duration = m.duration }
                    self.save()
                    if m.hasArt { self.loadCover(ffmpeg: ff, src: src, track: t) }
                }
            }
        } else if t.hasArt, coverURL == nil {
            loadCover(ffmpeg: ff, src: src, track: t)
        }
    }

    /// 起播。解码是异步的，回来时用户可能已经换了曲目 —— gen 不对就整包丢弃
    private func startPlayer(_ wav: URL, t: ListenTrack, gen: Int) {
        do {
            let p = try AVAudioPlayer(contentsOf: wav)
            p.delegate = self
            p.volume = volume
            p.prepareToPlay()
            player = p
            if p.play() {
                state = .playing
                duration = duration > 0 ? duration : p.duration
                tickStart()
                onLog?("听录播放 \(t.name)（\(Media.fmtDuration(p.duration))）")
            } else {
                state = .failed("放不出来：系统没给音频输出通道（接上耳机/音箱再试）")
            }
            hasOutput = AudioBoard.haveOutputDevice()
        } catch {
            state = .failed("解码文件读不出来：\(error.localizedDescription)")
        }
        _ = gen
    }

    /// 后台解码：ffmpeg → wav。stderr 进临时文件（见文件头那条教训），进度靠输出文件大小估
    private func runDecode(ffmpeg: String, src: URL, out: URL, expect: AudioBoard.Info) {
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: out)
        let tmp = out.appendingPathExtension("part")
        let errFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shuban-ffmpeg-\(UUID().uuidString).log")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        // 保留源采样率与声道，别一律 44.1k 双声道 —— 通话录音多是单声道低采样率，
        // 强行升上去只是把缓存撑大几倍，音质一点不涨
        p.arguments = ["-y", "-v", "error", "-i", src.path,
                       "-vn", "-sn", "-acodec", "pcm_s16le", "-f", "wav", tmp.path]
        p.standardOutput = FileHandle.nullDevice
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        // ⚠️ 见文件头那条教训：stderr 必须是**文件**，不能是没被读走的 PIPE
        p.standardError = (try? FileHandle(forWritingTo: errFile)) ?? FileHandle.nullDevice
        let flag = ExitFlag()
        p.terminationHandler = { proc in flag.done = true; _ = proc }
        decodeProc = p
        partialURL = tmp
        do {
            try p.run()
        } catch {
            // onLog 背后是 Store（@MainActor）在写 data/ui.log，
            // 这条跑在解码队列上，必须回主线程再说
            let msg = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.onLog?("听录解码起不来：\(msg)") }
            return
        }
        // 估个百分比：已知采样率/声道/时长就按体积算，不知道就一律报 0（界面显示「解码中…」）
        let bps = Double(expect.sampleRate * max(expect.channels, 1) * 2)
        let expectBytes = expect.duration > 0 && bps > 0 ? expect.duration * bps : 0
        while !flag.done {
            if expectBytes > 0 {
                let got = Double(Media.bytes(of: tmp))
                let pct = min(0.99, max(0, got / expectBytes))
                DispatchQueue.main.async { [weak self] in
                    guard let self, case .decoding = self.state else { return }
                    self.state = .decoding(pct)
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        p.waitUntilExit()
        DispatchQueue.main.async { [weak self] in self?.decodeProc = nil }
        let rc = p.terminationStatus
        let tail: String
        if rc == 0 {
            tail = ""
        } else {
            tail = Self.readTail(errFile)
            let log = "听录 ffmpeg rc=\(rc) stderr=\(tail.suffix(300))"
            DispatchQueue.main.async { [weak self] in self?.onLog?(log) }
        }
        try? fm.removeItem(at: errFile)
        if rc == 0, Media.bytes(of: tmp) > 44 {
            try? fm.removeItem(at: out)
            try? fm.moveItem(at: tmp, to: out)     // 全好了才改正式名，中途死掉不留半截货
        } else {
            try? fm.removeItem(at: tmp)
        }
        DispatchQueue.main.async { [weak self] in self?.partialURL = nil }
    }

    private func killDecode() {
        guard let p = decodeProc else { return }
        decodeProc = nil
        if let t = partialURL { try? FileManager.default.removeItem(at: t) }
        if p.isRunning { p.interrupt() }   // SIGINT：ffmpeg 收到就收摊，比 SIGKILL 干净
    }

    // MARK: 进度

    private func tickStart() {
        posTimer?.invalidate()
        posTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let p = self.player, p.isPlaying else { return }
            self.position = p.currentTime
        }
    }

    // MARK: AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        posTimer?.invalidate()
        posTimer = nil
        position = 0
        if autoNext, index < tracks.count - 1 {
            next()
        } else {
            state = .idle
            onLog?("听录放完了 \(current?.name ?? "")")
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        state = .failed("播放中途出错：" + (error?.localizedDescription ?? "未知"))
    }

    // MARK: - 封面

    private func loadCover(ffmpeg: String, src: URL, track: ListenTrack) {
        let out = cacheDir.appendingPathComponent(
            "cover-" + AudioBoard.signature(track) + ".png")
        if FileManager.default.fileExists(atPath: out.path) {
            DispatchQueue.main.async { self.coverURL = out }
            return
        }
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-y", "-v", "error", "-i", src.path, "-map", "0:v:0",
                           "-frames:v", "1", "-vf", "scale=320:-1", out.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else { return }
            DispatchQueue.main.async { self.coverURL = out }
        }
    }

    // MARK: - 存档

    private var listFile: URL? { listDir?.appendingPathComponent("playlist.json") }

    private func load() {
        guard let f = listFile, let raw = try? Data(contentsOf: f) else { return }
        struct Doc: Codable { var version: Int?; var paths: [String]? }
        if let doc = try? JSONDecoder().decode(Doc.self, from: raw), let paths = doc.paths {
            let now = Date()
            tracks = paths.compactMap { p in
                let u = URL(fileURLWithPath: p)
                guard FileManager.default.fileExists(atPath: p), AudioBoard.isPlayable(u) else { return nil }
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return ListenTrack(url: u,
                                   size: v?.fileSize ?? 0,
                                   mtime: v?.contentModificationDate ?? now,
                                   dur: 0, title: nil, artist: nil, album: nil, hasArt: false)
            }
        }
        if index >= tracks.count { index = -1 }
    }

    func save() {
        guard let f = listFile else { return }
        struct Doc: Codable { var version: Int = 1; var paths: [String] }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? enc.encode(Doc(paths: tracks.map(\.url.path))) else { return }
        do {
            if let d = listDir { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            try data.write(to: f, options: .atomic)
        } catch {
            onLog?("听录列表保存失败：\(error.localizedDescription)")
        }
    }

    private func probeAll() {
        guard let ff = Media.ffmpeg else { return }
        // 只认「时长还没探出来」这一个条件。别再写 `|| title == nil`：
        // 通话录音九成都没有标签，那样写等于每次刷新都把全列重探一遍 ffmpeg
        let todo = tracks.filter { $0.dur <= 0 }
        guard !todo.isEmpty else { return }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            for t in todo {
                let m = AudioBoard.parseInfo(AudioBoard.rawInfo(ff: ff, src: t.url))
                DispatchQueue.main.async {
                    guard let i = self.tracks.firstIndex(where: { $0.id == t.id }) else { return }
                    self.tracks[i].dur = m.duration
                    self.tracks[i].title = m.title
                    self.tracks[i].artist = m.artist
                    self.tracks[i].album = m.album
                    self.tracks[i].hasArt = m.hasArt
                    if self.index == i {
                        if self.duration <= 0 { self.duration = m.duration }
                        if m.hasArt && self.coverURL == nil {
                            self.loadCover(ffmpeg: ff, src: t.url, track: self.tracks[i])
                        }
                    }
                }
            }
            DispatchQueue.main.async { self.save() }
        }
    }

    // MARK: - 纯函数（验收直接调这些）

    /// 缓存文件名带源文件签名：改了名的录音、重新导出的同名录音都不会错拿旧缓存
    static func cachedWav(for t: ListenTrack, in dir: URL) -> URL {
        dir.appendingPathComponent(cacheName(t))
    }

    static func cacheName(_ t: ListenTrack) -> String {
        let stem = t.url.deletingPathExtension().lastPathComponent
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0.value > 0x2E80 ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
        let short = String(stem.prefix(40))
        return "\(short)-\(signature(t)).wav"
    }

    /// 签名 = mtime(秒) + 字节数。够区分「同名的不同文件」，又不至于每次都变
    static func signature(_ t: ListenTrack) -> String {
        "\(Int(t.mtime.timeIntervalSince1970))_\(t.size)"
    }

    /// 缓存里超出 keep 的（按最近使用）列出来，供清理
    static func prunePlan(_ files: [URL], keep: Int) -> [URL] {
        guard files.count > keep else { return [] }
        let sorted = files.sorted { a, b in
            (a.contentModificationDate ?? .distantPast) > (b.contentModificationDate ?? .distantPast)
        }
        return Array(sorted.dropFirst(max(keep, 0)))
    }

    private func pruneCache(keep: Int) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        let wavs = items.filter { $0.pathExtension.lowercased() == "wav" }
        for u in AudioBoard.prunePlan(wavs, keep: keep) {
            try? fm.removeItem(at: u)
        }
    }

    /// 缓存占用（字节，仅 wav + 封面）
    var cacheBytes: Int {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return items.reduce(0) { $0 + Media.bytes(of: $1) }
    }

    /// 手动清缓存（正在放的那条的 wav 留着，否则等会儿还得重解）
    func clearCache() {
        let keep = current.map { AudioBoard.cachedWav(for: $0, in: cacheDir).path }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var n = 0
        for u in items where u.path != keep {
            try? FileManager.default.removeItem(at: u)
            n += 1
        }
        onLog?("听录清理缓存 \(n) 个文件")
    }

    private static func human(_ sec: Double) -> String { Media.fmtDuration(sec) }

    // MARK: 诊断

    private static func tailOf(_ url: URL) -> String {
        let v = Media.tail(url, 200)
        return v.isEmpty ? "输出文件不存在或为空" : v
    }

    private static func readTail(_ url: URL) -> String {
        guard let d = try? Data(contentsOf: url), let s = String(data: d, encoding: .utf8) else { return "" }
        return String(s.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600))
    }

    /// 有没有音频输出设备。没有的时候「播放成功」是假象，得提前告诉用户
    private static func haveOutputDevice() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var dev = AudioDeviceID(0)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &dev) == noErr else { return false }
        return dev != AudioDeviceID(kAudioObjectUnknown)
    }

    // MARK: - ffmpeg 探测（无 ffprobe 时解析 `ffmpeg -i` 的 stderr）

    /// 本机是精简版 ffmpeg，没有 ffprobe，所以元数据从 `-i` 打印的信息块里抠
    struct Info: Equatable {
        var duration: Double = 0
        var title: String?
        var artist: String?
        var album: String?
        var hasArt = false
        var sampleRate: Int = 0
        var channels: Int = 0
    }

    /// 跑一次 `ffmpeg -hide_banner -i <文件>` 把它写到 stderr 的信息块取回来
    static func rawInfo(ff: String, src: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-hide_banner", "-i", src.path]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        // 这条必须把管道读空再等退出：信息块很短，读法不对就会像解码那样堵死
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 从信息块里抠时长 / 标签 / 采样率 / 声道 / 有无封面。
    /// 真实输出长这样（缩进是四空格）：
    /// ```
    ///   Metadata:
    ///     title           : 吴亚歧 李老师录音
    ///     artist          : 飞致云
    ///   Duration: 00:00:03.00, start: 0.000000, bitrate: 78 kb/s
    ///   Stream #0:0: Audio: wmav2 (a[1][0][0] / 0x0161), 48000 Hz, stereo, fltp, 64 kb/s
    /// ```
    static func parseInfo(_ s: String) -> Info {
        var i = Info()
        // 时长
        if let r = s.range(of: "Duration:"),
           let comma = s[r.upperBound...].firstIndex(of: ",") {
            i.duration = parseClock(String(s[r.upperBound..<comma]).trimmingCharacters(in: .whitespaces))
        }
        // 音频流：采样率 + 声道。形如 `Audio: wmav2 (a[1][0][0] / 0x0161), 48000 Hz, stereo, fltp, 64 kb/s`
        // 只往后看 160 个字符就够 —— 信息块里这行后面还可能跟着别的流
        if let ar = s.range(of: "Audio:") {
            let from = s.index(ar.upperBound, offsetBy: 0)
            let stop = s.index(from, offsetBy: 160, limitedBy: s.endIndex) ?? s.endIndex
            let seg = String(s[from..<stop])
            if let hr = seg.range(of: " Hz") {
                let before = seg[seg.startIndex..<hr.lowerBound]
                let digits = String(before.reversed().prefix(while: { $0.isNumber }).reversed())
                i.sampleRate = Int(digits) ?? 0
            }
            let low = seg.lowercased()
            if low.contains("mono") { i.channels = 1 }
            else if low.contains("stereo") { i.channels = 2 }
            else if let cr = low.range(of: " channels") {
                let head = low[low.startIndex..<cr.lowerBound]
                let tok = head.split(separator: " ").last ?? ""
                let parts = tok.split(separator: ".")
                if let n = Int(parts.first ?? "") {
                    // 「5.1 channels」「7.1 channels」这种写法：小数点那位是 LFE 低音炮，
                    // 也算一条声道。直接 Int("5.1") 会变 nil → 0，进度和缓存体积估算就全歪了
                    i.channels = n + (parts.count > 1 && parts[1] != "0" ? 1 : 0)
                }
            }
        }
        // 标签：形如 `    title : xxx` 的行
        var tags: [String: String] = [:]
        for line in s.split(separator: "\n") {
            let indent = line.prefix(while: { $0 == " " }).count
            guard indent >= 4, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" "), key != "encoder" else { continue }
            tags[key] = val
        }
        i.title = tags["title"]
        i.artist = tags["artist"] ?? tags["author"] ?? tags["album_artist"] ?? tags["wm/albumartist"]
        i.album = tags["album"] ?? tags["wm/albumtitle"]
        if s.range(of: "Video:") != nil,
           s.lowercased().range(of: "attached pic") != nil
            || s.lowercased().range(of: "mjpeg") != nil
            || s.lowercased().range(of: "png ") != nil {
            i.hasArt = true
        }
        return i
    }

    /// "00:03:12.24" → 192.24
    static func parseClock(_ t: String) -> Double {
        let parts = t.split(separator: ":")
        guard parts.count == 3 else { return 0 }
        let h = Double(parts[0]) ?? 0, m = Double(parts[1]) ?? 0, sec = Double(parts[2]) ?? 0
        return h * 3600 + m * 60 + sec
    }
}

private extension URL {
    var contentModificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
