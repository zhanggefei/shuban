//
//  AudioPanel.swift
//  书办（ShuBan）· 听录窗口
//
//  独立工具那套深色播放器界面整体不进书办，这里全部换成书办的语言：
//  宣纸暖白打底、中国红主色、金线点缀、「听」字印章、字号走本窗自己的档位。
//
//  版式：上面「曲目列表 | 正在播放」两栏，底下通一条传输栏（进度 + ⏮⏯⏭ + 音量）。
//  列表是主界面，所以给它全部余量；正在播放固定在右侧一列，窗口拉宽时它不动，
//  多出来的宽度都给了曲目 —— 录音文件名很长，列表越宽越有用。
//
//  ⚠️ 关掉这个窗口**不会暂停播放**（引擎在 AudioBoard 里，是全局唯一的）。
//  菲哥的用法是「放一段通话录音，边听边干别的」，一关窗就没声等于没这个功能。
//  唯一会主动停的场合是开始录屏：外放会被麦克风收进成片。
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 这一页自己的字号与尺寸档
//
// 同录屏/记事本：字号不能跟主面板共享，那是日历窗宽度的函数，两个窗口各拖各的会互相抢。
// 1.2 档介于录屏(1.15)与记事本(1.25)之间 —— 播放器字少、按钮大，比录屏略松一点正好。
private let panelZoom: CGFloat = 1.2

@inline(__always)
private func PZ(_ v: CGFloat) -> CGFloat { v * panelZoom }

private func PF(_ size: CGFloat,
                _ weight: Font.Weight = .regular,
                _ design: Font.Design = .default) -> Font {
    .system(size: (size * panelZoom * 2).rounded() / 2, weight: weight, design: design)
}

private func clampF(_ x: CGFloat) -> CGFloat { min(max(x, 0), 1) }

/// 曲目列表的节拍器。列表是「盘上的镜像」，录音随时可能在 Finder / WeDrive 里被删掉、
/// 被挪走、被重命名 —— 光靠 onAppear 拉一次，之后就一直显示僵尸行（点开只会报错）。
private let listenTicker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

struct AudioPanel: View {
    @Environment(\.closeFeaturePane) private var closePane
    @EnvironmentObject var audio: AudioBoard

    /// 有文件正悬在这个窗口上方 —— 高亮曲目卡，给一个「松手就进来」的交代
    @State private var dropping = false
    /// 拖动进度条期间的显示位置。松手才真的 seek：
    /// 一边拖一边改 player.currentTime 会把声音切成一串碎头，听着像坏盘
    @State private var scrub: Double?
    /// 一次拖放会来好几个 provider，攒一攒再整包交给引擎 ——
    /// 来一个 add 一次的话，20 个文件就是 20 轮探测 + 20 次落盘
    @State private var pending: [URL] = []
    @State private var pendingFlush: DispatchWorkItem?

    /// 测试接缝：界面此刻列的是哪些曲目。
    /// 引擎那份列表本来就对，真会坏的是「窗口没接上这个引擎对象」——
    /// 所以要有地方能回答「屏幕上现在显示着什么」。
    static var debugRows: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            ribbonDivider
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            transportBar
        }
        .onAppear {
            sync()
            // 只给拍图验收用：WECAL_AUDIO_SHOT=1 把列表第一条摆成「正在播」那个态。
            // 这个态平时只有点过之后才有，不摆出来的话进度条、跳条波形、红色高亮没人排版过。
            if ProcessInfo.processInfo.environment["WECAL_AUDIO_SHOT"] == "1",
               audio.index < 0, !audio.tracks.isEmpty {
                audio.selectTrack(0)
            }
        }
        .onChange(of: audio.tracks) { _ in sync() }
        .onReceive(listenTicker) { _ in
            // 关着的时候别去盘上空转（关窗只是 orderOut，视图还活着）
            guard FeaturePane.audio.isOpen else { return }
            audio.refresh()
            sync()
        }
        // 整个窗口都是落区：拖文件的人瞄的是那块窗，不是里面某张卡
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            acceptDrop(providers)
        }
    }

    private func sync() { AudioPanel.debugRows = audio.tracks.map(\.name) }

    // MARK: 头部

    private var header: some View {
        VStack(spacing: 0) {
            Theme.ribbon.frame(height: PZ(3))
            HStack(alignment: .center, spacing: PZ(9)) {
                Button { closePane() } label: {
                    Image(systemName: "xmark")
                        .font(PF(11, .bold))
                        .foregroundColor(Theme.inkSoft)
                        .frame(width: PZ(22), height: PZ(22))
                        .background(Circle().fill(Color.black.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .help("关闭听录窗口（正在放的声音不会停）")

                ZStack {
                    RoundedRectangle(cornerRadius: PZ(8), style: .continuous)
                        .fill(Theme.redGradient)
                        .frame(width: PZ(29), height: PZ(29))
                        .shadow(color: Theme.redDeep.opacity(0.45), radius: PZ(3), y: PZ(1.5))
                    RoundedRectangle(cornerRadius: PZ(8), style: .continuous)
                        .strokeBorder(Theme.todo.opacity(0.75), lineWidth: 0.9)
                        .frame(width: PZ(26), height: PZ(26))
                    Text("听")
                        .font(PF(15, .bold, .serif))
                        .foregroundColor(.white)
                        .offset(y: PZ(-0.5))
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("听 录").font(PF(21, .heavy, .rounded)).foregroundColor(Theme.sched)
                        Text("书办子功能")
                            .font(PF(8.5, .semibold, .rounded))
                            .foregroundColor(Theme.goldDeep)
                            .padding(.horizontal, PZ(4))
                            .padding(.vertical, PZ(1))
                            .background(Capsule().fill(Theme.todo.opacity(0.18)))
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "headphones")
                            .font(PF(8.5, .semibold))
                            .foregroundColor(Theme.sched.opacity(0.75))
                        Text(subTitle).font(PF(10)).foregroundColor(Theme.inkSoft).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                // 解码是个看得见进度看不见的活儿，给个呼吸的胶囊，
                // 免得人以为点没点着
                if case .decoding(let p) = audio.state {
                    HStack(spacing: PZ(4)) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text(p > 0 ? "解码 \(Int(p * 100))%" : "解码中…")
                            .font(PF(10, .bold, .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, PZ(7)).padding(.vertical, PZ(3))
                    .background(Capsule().fill(Theme.redGradient))
                } else if audio.state == .playing {
                    HStack(spacing: PZ(4)) {
                        WaveBars()
                        Text("正在播放")
                            .font(PF(10, .bold, .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, PZ(7)).padding(.vertical, PZ(3))
                    .background(Capsule().fill(Theme.redGradient))
                } else if !audio.tracks.isEmpty {
                    Text("\(audio.tracks.count) 条")
                        .font(PF(10, .bold, .rounded)).monospacedDigit()
                        .foregroundColor(Theme.goldDeep)
                        .padding(.horizontal, PZ(7)).padding(.vertical, PZ(3))
                        .background(Capsule().fill(Theme.todo.opacity(0.15)))
                }
            }
            .padding(.horizontal, PZ(13))
            .padding(.top, PZ(8))
            .padding(.bottom, PZ(7))
        }
    }

    private var subTitle: String {
        if Media.ffmpeg == nil { return "WMA 需要 ffmpeg 解码 · 请先安装" }
        return "WMA 等格式录音 · 拖进来就能听"
    }

    private var ribbonDivider: some View {
        Theme.ribbon.frame(height: PZ(1.2)).opacity(0.55).padding(.horizontal, PZ(12))
    }

    // MARK: 主体

    private var stage: some View {
        VStack(spacing: PZ(10)) {
            // 出问题的时候别把话藏在状态栏里 —— 这些卡片只在真有事时占地方
            ForEach(Array(noticeLines.enumerated()), id: \.offset) { _, l in
                noticeCard(l)
            }
            HStack(alignment: .top, spacing: PZ(10)) {
                listCard
                nowPlayingCard
                    .frame(width: PZ(258))
            }
        }
        .padding(.horizontal, PZ(14))
        .padding(.top, PZ(11))
        .padding(.bottom, PZ(12))
    }

    /// 需要用户看一眼才知道为什么没声音的几件事
    private var noticeLines: [String] {
        var l: [String] = []
        if Media.ffmpeg == nil {
            l.append("没找到 ffmpeg —— WMA 这类格式必须靠它解码：装一下 brew install ffmpeg")
        }
        if !audio.hasOutput {
            l.append("系统里没有可用的音频输出设备，接上耳机或音箱再试")
        }
        if case .failed(let m) = audio.state { l.append(m) }
        return l
    }

    private func noticeCard(_ msg: String) -> some View {
        card(tint: Theme.sched.opacity(0.07), border: Theme.sched.opacity(0.30)) {
            HStack(alignment: .top, spacing: PZ(6)) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(PF(11)).foregroundColor(Theme.sched)
                Text(msg).font(PF(9.5)).foregroundColor(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if case .failed = audio.state {
                    actionChip("知道了", color: Theme.inkSoft) { audio.stop() }
                }
            }
        }
    }

    // MARK: 曲目列表

    private var listCard: some View {
        card(stretch: true) {
            VStack(alignment: .leading, spacing: PZ(6)) {
                HStack(spacing: PZ(5)) {
                    Rectangle().fill(Theme.todo).frame(width: PZ(2), height: PZ(9))
                    Text("曲目列表").font(PF(9.5, .semibold)).foregroundColor(Theme.goldDeep)
                    Text("\(audio.tracks.count) 条")
                        .font(PF(9, .semibold, .rounded)).foregroundColor(Theme.inkSoft)
                    Spacer(minLength: 0)
                    actionChip(audio.tracks.isEmpty ? "＋ 添加" : "＋ 继续添加",
                               color: Theme.sched) { pickFiles() }
                    if !audio.tracks.isEmpty {
                        actionChip("清空", color: Theme.inkSoft) { audio.clearList() }
                    }
                }
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        if audio.tracks.isEmpty { emptyHint }
                        ForEach(Array(audio.tracks.enumerated()), id: \.element.id) { i, t in
                            if i > 0 { divider }
                            row(i, t)
                        }
                    }
                }
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: PZ(12), style: .continuous)
                    .strokeBorder(Theme.sched.opacity(0.8),
                                  style: StrokeStyle(lineWidth: 1.4, dash: [6, 4]))
                    .background(RoundedRectangle(cornerRadius: PZ(12), style: .continuous)
                        .fill(Theme.sched.opacity(0.05)))
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: PZ(7)) {
            Image(systemName: "arrow.down.doc")
                .font(PF(24, .light))
                .foregroundColor(Theme.sched.opacity(0.45))
            Text("把录音文件拖进来 · 或点「＋ 添加」")
                .font(PF(10.5, .semibold)).foregroundColor(Theme.ink)
            Text("支持 WMA / MP3 / WAV / M4A / FLAC …\n从列表移出不会删你原来的文件")
                .font(PF(9)).foregroundColor(Theme.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        // 在 ScrollView 里给 maxHeight 没用（拿不到视口高度），只能靠上下留白撑出居中感
        .frame(maxWidth: .infinity)
        .padding(.vertical, PZ(30))
    }

    private func row(_ i: Int, _ t: ListenTrack) -> some View {
        let on = audio.index == i
        return HStack(spacing: PZ(6)) {
            // 状态位：正在这条上就摆一根跳动的波形，否则摆序号
            if on && audio.state == .playing {
                WaveBars().frame(width: PZ(13))
            } else if on {
                Image(systemName: "play.circle.fill")
                    .font(PF(11, .semibold)).foregroundColor(Theme.sched)
                    .frame(width: PZ(13))
            } else {
                Text("\(i + 1)")
                    .font(PF(9, .semibold, .rounded)).monospacedDigit()
                    .foregroundColor(Theme.inkSoft.opacity(0.6))
                    .frame(width: PZ(13))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(t.name)
                    .font(PF(9.5, on ? .bold : .semibold))
                    .foregroundColor(on ? Theme.sched : Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                    .help(t.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                          + "\n修改于 " + RelativeDate.text(t.mtime))
                Text(meta(t)).font(PF(8.5)).foregroundColor(Theme.inkSoft).lineLimit(1)
            }
            Spacer(minLength: PZ(4))
            iconButton("magnifyingglass.circle", tint: Theme.inkSoft,
                       help: "在 Finder 里显示") { reveal(t) }
            iconButton("minus.circle", tint: Theme.inkSoft.opacity(0.6),
                       help: "从列表移出（文件不动）") { audio.remove(t) }
        }
        .padding(.horizontal, PZ(4)).padding(.vertical, PZ(4.5))
        .background(
            RoundedRectangle(cornerRadius: PZ(8), style: .continuous)
                .fill(on ? Theme.sched.opacity(0.07) : Color.clear)
        )
        .contentShape(Rectangle())
        // 单击即播：听录音的人点一行就是想听它，不该再让他双击或者找按钮
        .onTapGesture { audio.selectTrack(i) }
    }

    /// 时长 · 大小 · 格式。日期不放进来：窗口拉到 620 宽这一行就会断在「· 2…」上，
    /// 很难看，而录音的日期基本都写在文件名里 —— 日期挪到 hover 提示里。
    private func meta(_ t: ListenTrack) -> String {
        (t.dur > 0 ? Media.fmtDuration(t.dur) : "时长未知")
            + " · " + Media.fmtSize(t.size)
            + " · " + t.ext.uppercased()
    }

    // MARK: 正在播放

    private var nowPlayingCard: some View {
        card(stretch: true) {
            VStack(alignment: .leading, spacing: PZ(7)) {
                sectionLabel("正在播放")
                cover
                VStack(alignment: .leading, spacing: 2) {
                    Text(audio.current?.name ?? "还没有选中录音")
                        .font(PF(11.5, .bold)).foregroundColor(Theme.ink)
                        .lineLimit(2).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(byline).font(PF(9)).foregroundColor(Theme.goldDeep).lineLimit(1)
                    Text(subline).font(PF(8.5)).foregroundColor(Theme.inkSoft)
                        .lineLimit(2).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 没选中录音的时候这两颗按钮点了没反应 —— 空态干脆别摆出来
                if audio.current != nil {
                    divider
                    HStack(spacing: PZ(5)) {
                        ghostButton("Finder", icon: "folder") {
                            if let t = audio.current { reveal(t) }
                        }
                        ghostButton("移出", icon: "minus.circle") {
                            if let t = audio.current { audio.remove(t) }
                        }
                    }
                }
                HStack(spacing: PZ(3)) {
                    Text("解码缓存 \(Media.fmtSize(audio.cacheBytes)) · 留着下次秒开")
                        .font(PF(8)).foregroundColor(Theme.inkSoft.opacity(0.8))
                        .lineLimit(1)
                    // 「清」缩成一颗小圆钮：一年用不上几次，占个按钮位不值，
                    // 但也不能像原先那样用 overlay 压在文字上 —— 拍图看出来是叠字
                    Button { audio.clearCache() } label: {
                        Image(systemName: "trash")
                            .font(PF(6.5, .bold))
                            .foregroundColor(Theme.sched)
                            .frame(width: PZ(13), height: PZ(13))
                            .background(Circle().fill(Theme.sched.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .help("清掉解码缓存（正在放的这条留着）")
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                Text("关掉这个窗口声音不会停 · 开始录屏时会自动暂停")
                    .font(PF(8)).foregroundColor(Theme.inkSoft.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var byline: String {
        guard let t = audio.current else {
            return "点左边任意一条开始"
        }
        let tags = [t.artist, t.album].compactMap { $0 }.filter { !$0.isEmpty }
        return tags.isEmpty ? "无标签 · 显示的是文件名" : tags.joined(separator: " · ")
    }

    private var subline: String {
        guard let t = audio.current else { return "" }
        return "\(t.url.lastPathComponent)　·　\(Media.fmtSize(t.size))　·　\(t.ext.uppercased())"
    }

    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: PZ(12), style: .continuous)
                .fill(Theme.sched.opacity(0.06))
            if let c = audio.coverURL {
                CoverImage(url: c)
            } else {
                // 通话录音九成都没封面，这块宁可小一点也别撑出一大片空 ——
                // 第一版 150 见方 + 「无封面」三个字，拍出来半张卡是空的
                Image(systemName: audio.current == nil ? "music.note.list" : "waveform")
                    .font(PF(26, .light))
                    .foregroundColor(Theme.sched.opacity(0.45))
            }
        }
        .frame(width: PZ(136), height: PZ(136))
        .clipShape(RoundedRectangle(cornerRadius: PZ(12), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PZ(12), style: .continuous)
                .stroke(Theme.sched.opacity(0.14), lineWidth: 0.9)
        )
        .frame(maxWidth: .infinity)
    }

    // MARK: 传输栏

    private var transportBar: some View {
        VStack(spacing: PZ(7)) {
            HStack(spacing: PZ(7)) {
                Text(Media.fmtDuration(scrub ?? audio.position))
                    .font(PF(9.5, .semibold, .rounded)).monospacedDigit()
                    .foregroundColor(Theme.inkSoft)
                bar(frac, height: PZ(5), knob: true, enabled: audio.duration > 0,
                    onChange: { f in
                        guard audio.duration > 0 else { return }
                        scrub = Double(f) * audio.duration
                    },
                    onCommit: { f in
                        guard audio.duration > 0, let s = scrub else { return }
                        audio.seek(s)
                        _ = f
                    })
                    .frame(height: PZ(16))
                Text(Media.fmtDuration(audio.duration))
                    .font(PF(9.5, .semibold, .rounded)).monospacedDigit()
                    .foregroundColor(Theme.inkSoft)
            }
            HStack(spacing: PZ(8)) {
                roundKey("backward.fill", "上一条", enabled: !audio.tracks.isEmpty) { audio.prev() }
                playKey
                roundKey("forward.fill", "下一条", enabled: !audio.tracks.isEmpty) { audio.next() }
                HStack(spacing: PZ(4)) {
                    Circle().fill(dotColor).frame(width: PZ(5), height: PZ(5))
                    Text(statusText).font(PF(9.5)).foregroundColor(Theme.inkSoft).lineLimit(1)
                }
                Spacer(minLength: PZ(6))
                HStack(spacing: PZ(4)) {
                    Text("自动连播").font(PF(8.5)).foregroundColor(Theme.inkSoft)
                    AudioSwitch(on: audio.autoNext) { audio.autoNext = $0 }
                }
                .help("放完这条自己接下一条（听一长串管培录音时省事）")
                Image(systemName: volIcon)
                    .font(PF(9.5, .semibold)).foregroundColor(Theme.inkSoft)
                bar(CGFloat(audio.volume), height: PZ(4), knob: true, enabled: true,
                    onChange: { f in audio.volume = Float(f) })
                    .frame(width: PZ(88), height: PZ(14))
            }
        }
        .padding(.horizontal, PZ(16))
        .padding(.top, PZ(9))
        .padding(.bottom, PZ(10))
        .background(Theme.cream.opacity(0.92))
        .overlay(alignment: .top) { Theme.ribbon.frame(height: PZ(1)).opacity(0.45) }
    }

    private var frac: CGFloat {
        guard audio.duration > 0 else { return 0 }
        return CGFloat(min(max((scrub ?? audio.position) / audio.duration, 0), 1))
    }

    private var isDecoding: Bool {
        if case .decoding = audio.state { return true }
        return false
    }

    private var playKey: some View {
        let busy = audio.state.isBusy
        let dec = isDecoding
        return Button {
            scrub = nil
            audio.toggle()
        } label: {
            ZStack {
                Circle().fill(Theme.redGradient).frame(width: PZ(34), height: PZ(34))
                    .shadow(color: Theme.redDeep.opacity(0.35), radius: PZ(4), y: PZ(1.5))
                Circle().strokeBorder(Theme.todo.opacity(0.6), lineWidth: 0.9)
                    .frame(width: PZ(31), height: PZ(31))
                if dec {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: audio.state == .playing ? "pause.fill" : "play.fill")
                        .font(PF(13, .bold))
                        .foregroundColor(.white)
                        .offset(x: audio.state == .playing ? 0 : PZ(1))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(dec)
        .help(busy && !dec ? "暂停" : "播放 / 暂停")
    }

    private func roundKey(_ icon: String, _ help: String, enabled: Bool,
                          action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            Image(systemName: icon)
                .font(PF(11, .semibold))
                .foregroundColor(enabled ? Theme.sched : Theme.inkSoft.opacity(0.35))
                .frame(width: PZ(26), height: PZ(26))
                .background(Circle().fill(Theme.sched.opacity(enabled ? 0.08 : 0.04)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private var volIcon: String {
        if audio.volume < 0.02 { return "speaker.slash.fill" }
        if audio.volume < 0.45 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private var dotColor: Color {
        switch audio.state {
        case .playing: return Theme.sched
        case .decoding: return Theme.todo
        case .paused: return Theme.goldDeep
        case .failed: return Theme.sched
        case .idle: return Theme.ok
        }
    }

    private var statusText: String {
        switch audio.state {
        case .idle: return audio.tracks.isEmpty ? "把录音拖进来就能听" : "就绪 · 点任意一条开始"
        case .decoding(let p): return p > 0 ? "解码中 \(Int(p * 100))%" : "解码中…"
        case .playing: return "正在播放"
        case .paused: return "已暂停"
        case .failed(let m): return m
        }
    }

    // MARK: 动作

    private func reveal(_ t: ListenTrack) {
        NSWorkspace.shared.selectFile(t.url.path, inFileViewerRootedAtPath: "")
        audio.onLog?("听录在 Finder 里显示 \(t.name)")
    }

    /// 「＋ 添加」那颗按钮。测试时用 WECAL_AUDIO_PICK 直接把文件塞进列表，
    /// 免得自动验收还要人去点系统的文件选择框。
    private func pickFiles() {
        if let pick = ProcessInfo.processInfo.environment["WECAL_AUDIO_PICK"], !pick.isEmpty {
            audio.add(pick.split(separator: ",").map {
                URL(fileURLWithPath: ($0.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath)
            }, select: true)
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = AudioBoard.playableExts.compactMap { UTType(filenameExtension: $0) }
        panel.message = "选择录音文件（WMA / MP3 / WAV / M4A / FLAC …）"
        panel.prompt = "加入列表"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { resp in
            guard resp == .OK else { return }
            audio.add(panel.urls, select: audio.index < 0)
        }
    }

    /// 收拖放。一次拖放会来好几个 provider，各自异步取 URL，
    /// 所以攒一小会儿再整包交给引擎（见 pending 那段注释）。
    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Self.loadURLs(from: providers) { list in
            for u in list { enqueue(u) }
        }
        return true
    }

    private func enqueue(_ u: URL) {
        pending.append(u)
        pendingFlush?.cancel()
        let w = DispatchWorkItem {
            let list = self.pending
            self.pending = []
            guard !list.isEmpty else { return }
            self.audio.add(list, select: self.audio.index < 0)
        }
        pendingFlush = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    /// NSItemProvider → 本地文件 URL。
    ///
    /// 单独抽出来、而且收成「带回调的静态方法」，是为了让验收能**拿真 NSItemProvider 直接喂**，
    /// 不必人肉从 Finder 往窗口上拖一次 —— 那条路平时验不到，恰恰是 WMA 用户的主入口。
    ///
    /// 两条路挨个走：
    /// ① `loadObject(ofClass: NSURL.self)`：正规门，系统自己把归档解开；
    /// ② `loadItem` 取原始数据自己认：Finder 给的 `public.file-url` 数据其实是
    ///    **NSURL 的 keyed archive**（不是路径串！）—— 这是这条路上最坑的一点，
    ///    直接当字符串解 100% 解不出来，界面表现就是「拖了没反应」。
    /// 认不出来就丢：宁可「拖了没反应 + 说不支持」，也不能崩在类型转换上。
    static func loadURLs(from providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var found: [URL] = []
        let lock = NSLock()
        func keep(_ u: URL) {
            // 不存在的文件一律挡在引擎外 —— 这是最后一道闸
            guard FileManager.default.fileExists(atPath: u.path) else { return }
            lock.lock(); found.append(u); lock.unlock()
        }
        for p in providers {
            group.enter()
            if p.canLoadObject(ofClass: NSURL.self) {
                _ = p.loadObject(ofClass: NSURL.self) { obj, _ in
                    if let n = obj as? NSURL, FileManager.default.fileExists(atPath: (n as URL).path) {
                        keep(n as URL)
                        group.leave()
                        return
                    }
                    // 这条路给的东西不靠谱（有时把归档原样吐回来）→ 取原始数据再认一次
                    p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let u = url(from: item) { keep(u) }
                        group.leave()
                    }
                }
                continue
            }
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let u = url(from: item) { keep(u) }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(found) }
    }

    /// 那条 URL 到底长什么形状，系统给的法子不止一种，挨个试。
    static func url(from item: Any?) -> URL? {
        switch item {
        case let u as URL: return u
        case let u as NSURL: return u as URL
        case let arr as [URL]: return arr.first
        case let arr as [Any]: return arr.lazy.compactMap { url(from: $0) }.first
        case let d as Data:
            // ① Finder 的 file-url 数据 = NSURL 的 keyed archive
            if let u = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: d) {
                return u as URL
            }
            // ② 万一是个纯文本路径
            if let s = String(data: d, encoding: .utf8) { return pathURL(s) }
            return nil
        case let s as String: return pathURL(s)
        default: return nil
        }
    }

    private static func pathURL(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("file://"), let u = URL(string: s) { return u }
        if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
        return nil
    }

    // MARK: 通用件（和录屏窗一套形状，字号走本窗档位）

    private func card<Content: View>(tint: Color = Theme.cream,
                                    border: Color = Theme.sched.opacity(0.13),
                                    stretch: Bool = false,
                                    @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, PZ(11)).padding(.vertical, PZ(9))
            .frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: PZ(12), style: .continuous).fill(tint))
            .overlay(RoundedRectangle(cornerRadius: PZ(12), style: .continuous)
                .stroke(border, lineWidth: 0.9))
    }

    private func sectionLabel(_ t: String) -> some View {
        HStack(spacing: PZ(5)) {
            Rectangle().fill(Theme.todo).frame(width: PZ(2), height: PZ(9))
            Text(t).font(PF(9.5, .semibold)).foregroundColor(Theme.goldDeep)
            Spacer(minLength: 0)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.sched.opacity(0.08)).frame(height: 0.8)
    }

    private func iconButton(_ icon: String, tint: Color, help: String,
                            action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            Image(systemName: icon)
                .font(PF(13))
                .foregroundColor(tint)
                .frame(width: PZ(15), height: PZ(15))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func actionChip(_ t: String, color: Color, action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            Text(t)
                .font(PF(8.5, .bold))
                .foregroundColor(color)
                .padding(.horizontal, PZ(6)).padding(.vertical, PZ(2.5))
                .background(Capsule().fill(color.opacity(0.12)))
                .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 0.7))
        }
        .buttonStyle(.plain)
    }

    private func ghostButton(_ t: String, icon: String,
                             action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            HStack(spacing: PZ(3.5)) {
                Image(systemName: icon).font(PF(9, .semibold))
                Text(t).font(PF(9.5, .semibold))
            }
            .foregroundColor(Theme.sched)
            .padding(.horizontal, PZ(8)).padding(.vertical, PZ(4.5))
            .background(
                RoundedRectangle(cornerRadius: PZ(7), style: .continuous)
                    .fill(Theme.sched.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PZ(7), style: .continuous)
                    .stroke(Theme.sched.opacity(0.22), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    /// 暖白底上的自绘滑杆。系统 Slider 在这套配色里会串成系统蓝，
    /// 而且进度条要「拖动时只动指针、松手才 seek」，系统控件不给这个粒度。
    private func bar(_ f: CGFloat, height: CGFloat, knob: Bool, enabled: Bool,
                     onChange: @escaping (CGFloat) -> Void,
                     onCommit: ((CGFloat) -> Void)? = nil) -> some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let k = clampF(f)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.10))
                Capsule().fill(Theme.redGradient)
                    .frame(width: max(height, w * k))
                if knob {
                    Circle()
                        .fill(.white)
                        .overlay(Circle().stroke(Theme.redDeep.opacity(0.55), lineWidth: 1))
                        .shadow(color: .black.opacity(0.16), radius: 1, y: 0.5)
                        .frame(width: height * 2.1, height: height * 2.1)
                        .offset(x: max(0, w * k - height * 1.05))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard enabled else { return }
                        onChange(clampF(g.location.x / w))
                    }
                    .onEnded { g in
                        guard enabled else { return }
                        let v = clampF(g.location.x / w)
                        onChange(v)
                        onCommit?(v)
                    }
            )
        }
    }
}

// MARK: - 小控件

/// 封面。单独一个 View 是为了只读一次盘：
/// 整个面板在播放时每 0.25 秒就重画一次（进度条），在 body 里直接 NSImage(contentsOf:)
/// 等于每秒把那张 PNG 读四遍。
private struct CoverImage: View {
    let url: URL
    @State private var img: NSImage?

    var body: some View {
        Group {
            if let i = img {
                Image(nsImage: i).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.clear
            }
        }
        .task(id: url) { img = NSImage(contentsOf: url) }
    }
}

/// 播放中的小跳条。比转圈诚实 —— 它只在真在放的时候跳
private struct WaveBars: View {
    @State private var on = false
    private let hs: [CGFloat] = [0.35, 0.9, 0.55, 1.0]

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<hs.count, id: \.self) { i in
                Capsule()
                    .fill(Color.white)
                    .frame(width: 1.8, height: PZ(9) * (on ? hs[i] : 0.28))
            }
        }
        .frame(height: PZ(10))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true)) { on = true }
        }
    }
}

/// 书办风格的拨杆开关（同录屏窗一套样子，字号走本窗档位）
private struct AudioSwitch: View {
    let on: Bool
    let action: (Bool) -> Void

    var body: some View {
        Button { action(!on) } label: {
            ZStack {
                Capsule()
                    .fill(on ? AnyShapeStyle(Theme.redGradient) : AnyShapeStyle(Color.black.opacity(0.13)))
                    .frame(width: PZ(26), height: PZ(15))
                Circle()
                    .fill(.white)
                    .frame(width: PZ(11), height: PZ(11))
                    .shadow(color: .black.opacity(0.18), radius: 0.8, y: 0.5)
                    .offset(x: on ? PZ(5.2) : -PZ(5.2))
            }
        }
        .buttonStyle(.plain)
        .help(on ? "点一下关掉" : "点一下打开")
    }
}
