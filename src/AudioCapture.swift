//
//  AudioCapture.swift
//  书办 · 听录
//
//  干嘛的：把麦克风收进来，存成一个 m4a，录完交给听录列表。
//
//  为什么用 AVAudioRecorder 而不是 AVAudioEngine：这里只要「录一条能听的
//  语音」，不需要分轨、不需要实时处理、不需要写文件格式。AVAudioRecorder
//  自带 AAC 编码、自带电平表（averagePower）、自带 currentTime，正是这套
//  需求的最小可用件；改用 AVAudioEngine 得自己接 AVAudioFile 和 tap 回调，
//  多出来的是复杂度，不是能力。
//
//  和录屏的关系：录屏也吃麦克风（screencapture -g）。两边同时开，后开的那
//  个要么拿不到设备、要么录出一段静音 —— 所以谁先谁后由上层（AudioBoard）
//  闸住，这一层只管自己。
//

import AVFoundation
import Foundation

// 注：不是 @MainActor 类（和 AudioBoard 一致）。所有状态改动都发生在主线程：
// 界面调用、主队列 async、主队列 asyncAfter 递归。改之前先确认这条前提还在。

final class AudioCapture: ObservableObject {

    /// 录音台的状态。armed = 麦克风授权弹窗还挂着，等人点。
    enum Phase: Equatable {
        case idle
        case armed
        case recording
        case failed(String)

        var isRecording: Bool { self == .recording }
        var isArmed: Bool { self == .armed }
        var isBusy: Bool { isRecording || isArmed }
    }

    @Published private(set) var phase: Phase = .idle
    /// 已经录了多久（秒）。跟着电平一起 20Hz 刷
    @Published private(set) var seconds: Double = 0
    /// 当前电平 0…1（归过一的），给电平条
    @Published private(set) var level: Float = 0
    /// 最近一串电平，画成小波形。定长，新的从右边进
    @Published private(set) var history: [Float] = []
    /// 录成的那条（成功时才有）
    @Published private(set) var lastURL: URL?

    /// 录完了：把文件交给上层入列表
    var onFinish: ((URL, Double) -> Void)?
    /// 不值得留的情况（太短、一个字节都没有）—— 提示一句，不进列表
    var onDrop: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    /// 只报「进 / 出录音态」。电平不走这个口子，否则外层整页 20Hz 重画
    var onPhase: ((Bool) -> Void)?

    /// 录音落在哪。默认 `~/Music/书办录音`，和录屏落 `~/Movies/屏幕录制` 对称
    private(set) var outDir: URL?

    private var recorder: AVAudioRecorder?
    private var gen = 0
    private let historyLen = 48

    // MARK: 路径

    /// 验收钩子：`WECAL_AUDIO_REC` 换走录音输出目录，用例不许往菲哥真实的录音夹里写
    func configure(projectDir: URL?) {
        guard outDir == nil else { return }
        if let d = ProcessInfo.processInfo.environment["WECAL_AUDIO_REC"], !d.isEmpty {
            outDir = URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
            return
        }
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music", isDirectory: true)
        outDir = music.appendingPathComponent("书办录音", isDirectory: true)
    }

    /// 文件名：`录音 2026-11-24 22-53-12.m4a`。
    /// 不用冒号（Finder 里会显示成斜杠，拷到别处还容易出事），也不带斜杠。
    nonisolated static func fileName(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return "录音 \(f.string(from: d)).m4a"
    }

    /// 同名就往后加号，绝不覆盖已经录好的东西
    nonisolated static func uniqueURL(_ want: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: want.path) else { return want }
        let dir = want.deletingLastPathComponent()
        let base = want.deletingPathExtension().lastPathComponent
        let ext = want.pathExtension
        for i in 2...999 {
            let u = dir.appendingPathComponent("\(base) \(i).\(ext)")
            if !fm.fileExists(atPath: u.path) { return u }
        }
        return dir.appendingPathComponent("\(base) \(UUID().uuidString.prefix(4)).\(ext)")
    }

    // MARK: 纯函数（好钉用例）

    /// 分贝 → 0…1。人说话大约落在 -35…-12 dB，静音在 -60 以下
    nonisolated static func norm(_ db: Float) -> Float {
        if !db.isFinite { return 0 }
        if db <= -60 { return 0 }
        return min(1, max(0, (db + 60) / 60))
    }

    /// 短于 0.6 秒 = 误触。留个 0.3 秒的文件在列表里，比什么都不提示更烦人
    nonisolated static func tooShort(_ sec: Double) -> Bool { sec < 0.6 }

    var isRecording: Bool { phase.isRecording }
    var isBusy: Bool { phase.isBusy }

    /// 默认输入设备的名字（录音台上写「正在录 · MacBook 麦克风」，
    /// 让人确认没走错设备 —— 外接耳机麦和内置麦录出来完全两回事）
    var inputName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "默认输入"
    }

    // MARK: 起录

    func start() {
        guard !phase.isBusy else { return }
        guard let dir = outDir else {
            phase = .failed("没配好录音目录")
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin()
        case .notDetermined:
            // 系统弹窗会挂着，这里不能装死，也不能卡住主线程等它 —— 摆出「等授权」的态
            phase = .armed
            onPhase?(true)
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { [weak self] in self?.awaitAuth() }
            }
        default:
            phase = .failed("麦克风没授权：系统设置 → 隐私与安全性 → 麦克风，把书办勾上")
            onLog?("录音起不来：麦克风未授权")
        }
    }

    /// 等授权弹窗被点掉（最多 20 秒）。授权了就开录，拒绝了就直说。
    /// 同样用 asyncAfter 递归，不用 Timer（理由见 tickNext）
    private func awaitAuth(_ wait: Double = 0) {
        guard phase.isArmed else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized { begin(); return }
        if status == .denied {
            phase = .failed("麦克风没授权：系统设置 → 隐私与安全性 → 麦克风，把书办勾上")
            onPhase?(false)
            onLog?("录音起不来：授权被拒")
            return
        }
        if wait >= 20 {
            phase = .failed("等了 20 秒没等到麦克风授权，再点一次「录音」吧")
            onPhase?(false)
            onLog?("录音起不来：等授权超时")
            return
        }
        // 还没点：每 0.25 秒探一次。phase 一离开 armed（取消 / 重开）这条链自己断
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.phase.isArmed else { return }
            self.awaitAuth(wait + 0.25)
        }
    }

    private func begin() {
        guard let dir = outDir else { return }
        let want = dir.appendingPathComponent(AudioCapture.fileName())
        let url = AudioCapture.uniqueURL(want)
        // AAC 单声道 44.1k / 96kbps：一分钟约 700KB，语音够清楚，也不至于占地方
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else {
                throw NSError(domain: "ShuBan.Audio", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "系统不肯开麦（可能没有输入设备）"])
            }
            recorder = r
            seconds = 0
            level = 0
            history = Array(repeating: 0, count: historyLen)
            phase = .recording
            onPhase?(true)
            onLog?("开始录音 → \(url.lastPathComponent)")
            tickStart()
        } catch {
            phase = .failed("录音起不来：\(error.localizedDescription)")
            onPhase?(false)
            onLog?("录音起不来：\(error.localizedDescription)")
        }
    }

    // MARK: 电平与计时

    private func tickStart() {
        gen += 1
        tickNext(gen)
    }

    /// 用 asyncAfter 递归而不是 Timer：Timer 的 block 是 @Sendable，
    /// 闭包里碰 @MainActor 的 self 会顶出 warning（本项目零 warning 是硬线）
    private func tickNext(_ g: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.gen == g, let r = self.recorder else { return }
            // 设备被拔掉、系统掐掉之类：recorder 自己停了，这一层得收尾
            if !r.isRecording {
                self.finish()
                return
            }
            r.updateMeters()
            self.seconds = r.currentTime
            let lv = AudioCapture.norm(r.averagePower(forChannel: 0))
            // 落得快、起得慢：纯粹为了电平条看着不抽搐
            self.level = max(lv, self.level * 0.72)
            self.history = Array(self.history.dropFirst()) + [self.level]
            self.tickNext(g)
        }
    }

    private func stopTicks() {
        gen += 1
        level = 0
    }

    // MARK: 停

    /// 停止并保存。太短的直接丢掉（并说一句），不留垃圾文件
    func stop() {
        guard phase.isRecording, let r = recorder else { return }
        let sec = r.currentTime
        r.stop()
        stopTicks()
        recorder = nil
        phase = .idle
        onPhase?(false)
        let url = r.url
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if AudioCapture.tooShort(sec) || size == 0 {
            try? FileManager.default.removeItem(at: url)
            let msg = size == 0
                ? "什么都没录到：检查一下默认输入设备选了没"
                : String(format: "只录到 %.1f 秒，太短没留", sec)
            onDrop?(msg)
            onLog?("录音丢弃：\(msg)")
            return
        }
        lastURL = url
        onFinish?(url, sec)
    }

    /// 取消：停 + 删文件，什么都不留
    func cancel() {
        guard phase.isRecording, let r = recorder else {
            if phase.isArmed { phase = .idle; onPhase?(false) }
            return
        }
        r.stop()
        stopTicks()
        recorder = nil
        phase = .idle
        onPhase?(false)
        try? FileManager.default.removeItem(at: r.url)
        onLog?("录音已取消（文件删除）")
    }

    /// 意外停（设备消失）走这里：能留就留，留不下就报
    private func finish() {
        stop()
    }
}
