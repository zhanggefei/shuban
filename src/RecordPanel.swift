//
//  RecordPanel.swift
//  书办（ShuBan）· 录屏面板
//
//  独立录屏工具那套「墨蓝 + 电光蓝」的深色界面整体舍弃，全部改用书办的语言：
//  宣纸暖白打底、中国红主色、金线点缀、宋体印章、字号统一走 Fnt/S 的缩放体系。
//  形态上也刻意不另开窗口 —— 它就是书办面板的一个态，和「日程 / 待办」并列，
//  从底栏那颗红点进来，从左上角回去。
//

import SwiftUI
import AppKit

struct RecordPanel: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var rec: Recorder
    /// 最近三条成片。面板高的时候下面本来是一片空白，拿它填上既有用又不打乱布局
    @State private var recents: [RecentClip] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            ribbonDivider
            ScrollView(showsIndicators: false) {
                VStack(spacing: S(9)) {
                    content
                }
                .padding(.horizontal, S(13))
                .padding(.top, S(10))
                .padding(.bottom, S(14))
            }
            footer
        }
        .onAppear {
            rec.refreshPermission()
            // 没权限就顺手向系统登记一次：不然系统设置里根本找不到「书办」这一项，
            // 用户点「去开启」进去也只能对着空列表发呆。
            rec.ensureRegisteredOnce()
            loadRecents()
        }
        .onChange(of: rec.phase) { _ in loadRecents() }
    }

    // MARK: 头部

    private var header: some View {
        VStack(spacing: 0) {
            Theme.ribbon.frame(height: S(3))
            HStack(alignment: .center, spacing: S(9)) {
                Button { store.mode = 0 } label: {
                    Image(systemName: "chevron.left")
                        .font(Fnt.s(11, .bold))
                        .foregroundColor(Theme.inkSoft)
                        .frame(width: S(22), height: S(22))
                        .background(Circle().fill(Color.black.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .help("回到日历")

                ZStack {
                    RoundedRectangle(cornerRadius: S(8), style: .continuous)
                        .fill(Theme.redGradient)
                        .frame(width: S(29), height: S(29))
                        .shadow(color: Theme.redDeep.opacity(0.45), radius: S(3), y: S(1.5))
                    RoundedRectangle(cornerRadius: S(8), style: .continuous)
                        .strokeBorder(Theme.todo.opacity(0.75), lineWidth: 0.9)
                        .frame(width: S(26), height: S(26))
                    Text("录")
                        .font(Fnt.s(15, .bold, .serif))
                        .foregroundColor(.white)
                        .offset(y: S(-0.5))
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("录 屏").font(Fnt.s(21, .heavy, .rounded)).foregroundColor(Theme.sched)
                        Text("书办子功能")
                            .font(Fnt.s(8.5, .semibold, .rounded))
                            .foregroundColor(Theme.goldDeep)
                            .padding(.horizontal, S(4))
                            .padding(.vertical, S(1))
                            .background(Capsule().fill(Theme.todo.opacity(0.18)))
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "record.circle")
                            .font(Fnt.s(8.5, .semibold))
                            .foregroundColor(Theme.sched.opacity(0.75))
                        Text(subTitle).font(Fnt.s(10)).foregroundColor(Theme.inkSoft).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if rec.isRecording {
                    HStack(spacing: S(4)) {
                        Circle().fill(.white).frame(width: S(5), height: S(5))
                        Text(rec.timerText)
                            .font(Fnt.s(12, .bold, .rounded)).monospacedDigit()
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, S(7)).padding(.vertical, S(3))
                    .background(Capsule().fill(Theme.redGradient))
                }
            }
            .padding(.horizontal, S(13))
            .padding(.top, S(8))
            .padding(.bottom, S(7))
        }
    }

    private var subTitle: String {
        if !rec.granted { return "还差「屏幕录制」权限" }
        return "屏幕 · 麦克风 · 一键成片"
    }

    private var ribbonDivider: some View {
        Theme.ribbon.frame(height: S(1.2)).opacity(0.55).padding(.horizontal, S(12))
    }

    // MARK: 主体按阶段切换

    @ViewBuilder
    private var content: some View {
        switch rec.phase {
        case .countdown(let n): countdownStage(n)
        case .recording:       recordingStage
        case .finishing:       finishingStage
        default:               setupStage
        }
    }

    // MARK: 设置态

    @ViewBuilder
    private var setupStage: some View {
        if !rec.granted { permCard }
        if case .done(let r) = rec.phase { resultCard(r) }
        if case .failed(let msg) = rec.phase { failCard(msg) }
        if !rec.checkLines.isEmpty { checkCard }
        rangeCard
        optionCard
        startButton
        tailActions
        if !recents.isEmpty { recentCard }
    }

    private var permCard: some View {
        card(tint: Theme.todo.opacity(0.12), border: Theme.todo.opacity(0.45)) {
            VStack(alignment: .leading, spacing: S(6)) {
                HStack(spacing: S(5)) {
                    Image(systemName: "lock.shield.fill")
                        .font(Fnt.s(11)).foregroundColor(Theme.goldDeep)
                    Text("需要「屏幕录制」权限").font(Fnt.s(11, .bold)).foregroundColor(Theme.ink)
                }
                Text(" macOS 的规定：勾上之后必须重启书办才生效。授权一次，以后不用再管。")
                    .font(Fnt.s(9.5)).foregroundColor(Theme.inkSoft).fixedSize(horizontal: false, vertical: true)
                Text("在「系统设置 → 隐私与安全性 → 屏幕录制」里勾上「书办」，再点「重启书办」。"
                     + "列表里没有它就先点「去开启」。勾上了这里会在两秒内自动消失。")
                    .font(Fnt.s(9)).foregroundColor(Theme.inkSoft.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: S(6)) {
                    ghostButton("去开启", icon: "arrow.up.forward.square") {
                        rec.openPrivacy("Privacy_ScreenCapture")
                    }
                    ghostButton("重启书办", icon: "arrow.triangle.2.circlepath") { rec.relaunch() }
                }
            }
        }
    }

    private var rangeCard: some View {
        card {
            VStack(alignment: .leading, spacing: S(7)) {
                sectionLabel("录制范围", right: rec.targetText)
                HStack(spacing: S(5)) {
                    ForEach(RecRange.allCases) { r in rangeChip(r) }
                }
                Text(hintText).font(Fnt.s(9)).foregroundColor(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                if rec.range == .region {
                    HStack(spacing: S(6)) {
                        if let rg = rec.region {
                            Text("已框选 \(Int(rg.width)) × \(Int(rg.height))")
                                .font(Fnt.s(9.5, .semibold, .rounded))
                                .foregroundColor(Theme.goldDeep)
                        }
                        ghostButton(rec.region == nil ? "框选区域" : "重新框选",
                                    icon: "rectangle.dashed") { rec.pickRegion() }
                    }
                }
            }
        }
    }

    private var hintText: String {
        if rec.range == .second && !rec.hasSecondScreen { return "只检测到一块屏幕，插上第二块屏再选这项。" }
        return rec.range.hint
    }

    private func rangeChip(_ r: RecRange) -> some View {
        let on = rec.range == r
        let dead = (r == .second && !rec.hasSecondScreen)
        return Button {
            if r == .region && rec.region == nil { rec.pickRegion() } else { rec.range = r }
        } label: {
            VStack(spacing: S(2)) {
                Image(systemName: icon(r))
                    .font(Fnt.s(11, .semibold))
                Text(r.label).font(Fnt.s(10, on ? .bold : .medium))
            }
            .foregroundColor(on ? .white : (dead ? Theme.inkSoft.opacity(0.45) : Theme.inkSoft))
            .frame(maxWidth: .infinity)
            .padding(.vertical, S(8))
            .background(
                RoundedRectangle(cornerRadius: S(10), style: .continuous)
                    .fill(on ? AnyShapeStyle(Theme.redGradient) : AnyShapeStyle(Color.black.opacity(0.05)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: S(10), style: .continuous)
                    .stroke(on ? Theme.todo.opacity(0.55) : Color.clear, lineWidth: 0.9)
            )
        }
        .buttonStyle(.plain)
        .disabled(dead)
    }

    private func icon(_ r: RecRange) -> String {
        switch r {
        case .full: return "rectangle.inset.filled"
        case .region: return "rectangle.dashed"
        case .second: return "display"
        }
    }

    private var optionCard: some View {
        card {
            VStack(spacing: S(7)) {
                optionRow("waveform", "麦克风",
                          rec.audio && !rec.micGranted
                            ? "系统没给麦克风授权 · 这次只录画面"
                            : "解说、会议声音一起录进去") {
                    RecSwitch(on: rec.audio) { rec.audio = $0 }
                }
                divider
                optionRow("cursorarrow.click", "点击高亮", "鼠标点哪儿，成片里一圈水波纹") {
                    RecSwitch(on: rec.clicks) { rec.clicks = $0 }
                }
                divider
                optionRow("timer", "开始倒计时", "给自己留出摆画面的时间") {
                    HStack(spacing: S(3)) {
                        ForEach([0, 3, 5], id: \.self) { n in
                            miniChip(n == 0 ? "关" : "\(n) 秒", on: rec.countdown == n) { rec.countdown = n }
                        }
                    }
                }
                divider
                optionRow("folder", "录完打开 Finder", "顺手把文件挑出来，方便发人") {
                    RecSwitch(on: rec.reveal) { rec.reveal = $0 }
                }
            }
        }
    }

    private var startButton: some View {
        Button { rec.start() } label: {
            HStack(spacing: S(6)) {
                Image(systemName: "largecircle.fill.circle")
                    .font(Fnt.s(14, .semibold))
                Text("开始录制").font(Fnt.s(13.5, .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, S(11))
            .background(RoundedRectangle(cornerRadius: S(12), style: .continuous).fill(Theme.redGradient))
            .overlay(RoundedRectangle(cornerRadius: S(12), style: .continuous)
                .stroke(Theme.todo.opacity(0.55), lineWidth: 1))
            .shadow(color: Theme.redDeep.opacity(0.35), radius: S(7), y: S(2))
        }
        .buttonStyle(.plain)
    }

    private var tailActions: some View {
        HStack(spacing: S(6)) {
            ghostButton(rec.checking ? "检查中…" : "检查权限与设备",
                        icon: "checklist") { rec.selfCheck() }
                .disabled(rec.checking)
            ghostButton("录制文件夹", icon: "folder") { rec.openFolder() }
            Spacer(minLength: 0)
        }
    }

    private var recentCard: some View {
        card {
            VStack(alignment: .leading, spacing: S(6)) {
                sectionLabel("最近录制", right: "\(recents.count) 条")
                ForEach(Array(recents.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { divider }
                    HStack(spacing: S(6)) {
                        Image(systemName: "film")
                            .font(Fnt.s(10, .semibold))
                            .foregroundColor(Theme.sched.opacity(0.75))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(c.name)
                                .font(Fnt.s(9.5, .semibold)).foregroundColor(Theme.ink)
                                .lineLimit(1).truncationMode(.middle)
                            Text("\(Media.fmtSize(c.size)) · \(RelativeDate.text(c.date))")
                                .font(Fnt.s(8.5)).foregroundColor(Theme.inkSoft)
                        }
                        Spacer(minLength: 0)
                        Button { rec.open(c.url) } label: {
                            Image(systemName: "play.circle.fill")
                                .font(Fnt.s(13)).foregroundColor(Theme.sched)
                        }
                        .buttonStyle(.plain)
                        .help("播放")
                        Button { rec.reveal(c.url) } label: {
                            Image(systemName: "magnifyingglass.circle")
                                .font(Fnt.s(13)).foregroundColor(Theme.inkSoft)
                        }
                        .buttonStyle(.plain)
                        .help("在 Finder 里显示")
                    }
                }
            }
        }
    }

    private func loadRecents() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: rec.outDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { recents = []; return }
        let list: [RecentClip] = items.compactMap { u in
            guard u.pathExtension.lowercased() == "mp4" else { return nil }
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let d = v?.contentModificationDate else { return nil }
            return RecentClip(url: u, size: v?.fileSize ?? 0, date: d)
        }
        recents = Array(list.sorted { $0.date > $1.date }.prefix(3))
    }

    // MARK: 倒计时 / 录制中 / 收尾

    private func countdownStage(_ n: Int) -> some View {
        VStack(spacing: S(12)) {
            ZStack {
                Circle().fill(Theme.sched.opacity(0.10)).frame(width: S(96), height: S(96))
                Circle().stroke(Theme.todo.opacity(0.5), lineWidth: 1.2)
                    .frame(width: S(96), height: S(96))
                Text("\(n)")
                    .font(Fnt.s(46, .bold, .rounded)).monospacedDigit()
                    .foregroundColor(Theme.sched)
            }
            Text("准备开始 · \(rec.range.label) \(rec.targetText)")
                .font(Fnt.s(10)).foregroundColor(Theme.inkSoft)
            ghostButton("取消", icon: "xmark") { rec.cancelCountdown() }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, S(30))
    }

    private var recordingStage: some View {
        VStack(spacing: S(10)) {
            card {
                VStack(spacing: S(8)) {
                    HStack(spacing: S(5)) {
                        PulseDot()
                        Text("正在录制").font(Fnt.s(11, .bold)).foregroundColor(Theme.sched)
                        Spacer(minLength: 0)
                        Text(rec.targetText)
                            .font(Fnt.s(9.5, .semibold, .rounded))
                            .foregroundColor(Theme.goldDeep)
                    }
                    Text(rec.timerText)
                        .font(Fnt.s(44, .semibold, .rounded)).monospacedDigit()
                        .foregroundColor(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text("screencapture 是停止时才封装写文件，中途文件大小为 0 属正常")
                        .font(Fnt.s(8.5)).foregroundColor(Theme.inkSoft.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button { rec.stop() } label: {
                HStack(spacing: S(6)) {
                    Image(systemName: "stop.fill").font(Fnt.s(12, .bold))
                    Text("停止并保存").font(Fnt.s(13.5, .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, S(11))
                .background(RoundedRectangle(cornerRadius: S(12), style: .continuous)
                    .fill(LinearGradient(colors: [Theme.redDeep, Theme.warn],
                                         startPoint: .top, endPoint: .bottom)))
                .overlay(RoundedRectangle(cornerRadius: S(12), style: .continuous)
                    .stroke(Theme.todo.opacity(0.45), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Text("也可以点屏幕上方悬浮条里的「停止」；书办自己和悬浮条都不参与屏幕采集，成片里不会出现")
                .font(Fnt.s(8.5)).foregroundColor(Theme.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, S(6))
    }

    private var finishingStage: some View {
        VStack(spacing: S(10)) {
            ProgressView().progressViewStyle(.circular).controlSize(.large).tint(Theme.sched)
                .padding(.top, S(24))
            Text(rec.statusLine.isEmpty ? "正在封装写入文件…" : rec.statusLine)
                .font(Fnt.s(11, .semibold)).foregroundColor(Theme.ink)
            Text("刚结束，正在算时长、体检画面和声音")
                .font(Fnt.s(9)).foregroundColor(Theme.inkSoft)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 结果 / 失败 / 自检

    private func resultCard(_ r: RecResult) -> some View {
        card(tint: Theme.ok.opacity(0.08), border: Theme.ok.opacity(0.35)) {
            VStack(alignment: .leading, spacing: S(6)) {
                HStack(spacing: S(5)) {
                    ZStack {
                        Circle().fill(Theme.ok).frame(width: S(16), height: S(16))
                        Image(systemName: "checkmark").font(Fnt.s(8.5, .bold)).foregroundColor(.white)
                    }
                    Text("录制完成").font(Fnt.s(11.5, .bold)).foregroundColor(Theme.ink)
                    Spacer(minLength: 0)
                    Text(Media.fmtDuration(r.seconds))
                        .font(Fnt.s(11, .bold, .rounded)).monospacedDigit()
                        .foregroundColor(Theme.goldDeep)
                }
                Text(r.path.lastPathComponent)
                    .font(Fnt.s(10.5, .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                Text("\(Media.fmtSize(r.bytes))　·　\(r.hasAudio ? "含语音" : "无音频")　·　"
                     + r.path.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(Fnt.s(8.5)).foregroundColor(Theme.inkSoft).lineLimit(1)
                if !r.note.isEmpty {
                    Text(r.note)
                        .font(Fnt.s(9)).foregroundColor(Theme.warn)
                        .padding(S(6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: S(7), style: .continuous)
                            .fill(Theme.warn.opacity(0.10)))
                }
                HStack(spacing: S(5)) {
                    ghostButton("播放", icon: "play.fill", solid: true) { rec.open(r.path) }
                    ghostButton("Finder", icon: "folder") { rec.reveal(r.path) }
                    if rec.compressing {
                        HStack(spacing: S(4)) {
                            ProgressView().controlSize(.small).tint(Theme.sched)
                            Text("压缩中…").font(Fnt.s(9.5, .semibold)).foregroundColor(Theme.inkSoft)
                        }
                    } else {
                        ghostButton(r.shared == nil ? "生成分享版" : "分享版已生成",
                                    icon: "square.and.arrow.up") {
                            if let s = r.shared { rec.reveal(s) } else { rec.compressShare() }
                        }
                    }
                }
                .padding(.top, S(2))
                if let s = r.shared {
                    Text("分享版 \(Media.fmtSize(Media.bytes(of: s))) · 画面压到 1080p，发微信/邮件够用")
                        .font(Fnt.s(8.5)).foregroundColor(Theme.goldDeep)
                }
            }
        }
    }

    private func failCard(_ msg: String) -> some View {
        card(tint: Theme.sched.opacity(0.07), border: Theme.sched.opacity(0.30)) {
            VStack(alignment: .leading, spacing: S(6)) {
                HStack(spacing: S(5)) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Fnt.s(11)).foregroundColor(Theme.sched)
                    Text("录制没成").font(Fnt.s(11, .bold)).foregroundColor(Theme.ink)
                }
                Text(msg).font(Fnt.s(9.5)).foregroundColor(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: S(5)) {
                    ghostButton("去开启权限", icon: "lock.open") {
                        rec.openPrivacy("Privacy_ScreenCapture")
                    }
                    ghostButton("重启书办", icon: "arrow.triangle.2.circlepath") { rec.relaunch() }
                    ghostButton("知道了", icon: "xmark") { rec.reset() }
                }
            }
        }
    }

    private var checkCard: some View {
        card {
            VStack(alignment: .leading, spacing: S(4)) {
                sectionLabel("自检结果")
                ForEach(rec.checkLines, id: \.self) { l in
                    Text(l)
                        .font(Fnt.s(9.5, l.hasPrefix("✗") ? .semibold : .regular))
                        .foregroundColor(l.hasPrefix("✗") ? Theme.sched
                                            : (l.hasPrefix("!") ? Theme.goldDeep : Theme.inkSoft))
                }
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(rec.isRecording ? Theme.sched : (rec.granted ? Theme.ok : Theme.todo))
                .frame(width: S(5), height: S(5))
            Text(rec.statusLine.isEmpty ? "成片默认存到 ~/Movies/屏幕录制" : rec.statusLine)
                .font(Fnt.s(9.5)).foregroundColor(Theme.inkSoft).lineLimit(1)
            Spacer(minLength: 0)
            Button { store.mode = 0 } label: {
                Text("回日历").font(Fnt.s(8.5, .semibold)).foregroundColor(Theme.sched)
                    .padding(.horizontal, S(6)).padding(.vertical, S(2))
                    .background(Capsule().fill(Theme.sched.opacity(0.10)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, S(16))
        .padding(.vertical, S(7))
        .background(Theme.cream.opacity(0.92))
        .overlay(alignment: .top) { Theme.ribbon.frame(height: S(1)).opacity(0.45) }
    }

    // MARK: 通用件

    private func card<Content: View>(tint: Color = Theme.cream,
                                    border: Color = Theme.sched.opacity(0.13),
                                    @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, S(11)).padding(.vertical, S(9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: S(12), style: .continuous).fill(tint))
            .overlay(RoundedRectangle(cornerRadius: S(12), style: .continuous)
                .stroke(border, lineWidth: 0.9))
    }

    private func sectionLabel(_ t: String, right: String = "") -> some View {
        HStack(spacing: S(5)) {
            Rectangle().fill(Theme.todo).frame(width: S(2), height: S(9))
            Text(t).font(Fnt.s(9.5, .semibold)).foregroundColor(Theme.goldDeep)
            Spacer(minLength: 0)
            if !right.isEmpty {
                Text(right).font(Fnt.s(9, .semibold, .rounded)).foregroundColor(Theme.inkSoft)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.sched.opacity(0.08)).frame(height: 0.8)
    }

    private func optionRow(_ icon: String, _ title: String, _ sub: String,
                           @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: S(7)) {
            Image(systemName: icon)
                .font(Fnt.s(11, .semibold))
                .foregroundColor(Theme.sched.opacity(0.8))
                .frame(width: S(16))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(Fnt.s(10.5, .semibold)).foregroundColor(Theme.ink)
                Text(sub).font(Fnt.s(8.5)).foregroundColor(Theme.inkSoft).lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing()
        }
    }

    private func miniChip(_ t: String, on: Bool, select: @escaping () -> Void) -> some View {
        Button { select() } label: {
            Text(t)
                .font(Fnt.s(9, on ? .bold : .regular))
                .foregroundColor(on ? .white : Theme.inkSoft)
                .padding(.horizontal, S(7)).padding(.vertical, S(2.5))
                .background(Capsule().fill(on ? AnyShapeStyle(Theme.redGradient)
                                              : AnyShapeStyle(Color.black.opacity(0.06))))
        }
        .buttonStyle(.plain)
    }

    private func ghostButton(_ t: String, icon: String, solid: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            HStack(spacing: S(3.5)) {
                Image(systemName: icon).font(Fnt.s(9, .semibold))
                Text(t).font(Fnt.s(9.5, .semibold))
            }
            .foregroundColor(solid ? .white : Theme.sched)
            .padding(.horizontal, S(8)).padding(.vertical, S(4.5))
            .background(
                RoundedRectangle(cornerRadius: S(7), style: .continuous)
                    .fill(solid ? AnyShapeStyle(Theme.redGradient) : AnyShapeStyle(Theme.sched.opacity(0.08)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: S(7), style: .continuous)
                    .stroke(solid ? Theme.todo.opacity(0.5) : Theme.sched.opacity(0.22), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }
}

struct RecentClip: Identifiable {
    let url: URL
    let size: Int
    let date: Date
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// 「3 分钟前 / 昨天 / 11月20日」——比裸时间戳更像人话
enum RelativeDate {
    private static let fmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }()
    static func text(_ d: Date) -> String {
        if Date().timeIntervalSince(d) < 60 * 60 * 24 {
            return fmt.localizedString(for: d, relativeTo: Date())
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }
}

// MARK: - 小控件

/// 书办风格的拨杆开关（不用系统 Switch，系统控件在暖白底上会串色）
struct RecSwitch: View {
    let on: Bool
    let action: (Bool) -> Void

    var body: some View {
        Button { action(!on) } label: {
            ZStack {
                Capsule()
                    .fill(on ? AnyShapeStyle(Theme.redGradient) : AnyShapeStyle(Color.black.opacity(0.13)))
                    .frame(width: S(30), height: S(17))
                Circle()
                    .fill(.white)
                    .frame(width: S(13), height: S(13))
                    .shadow(color: .black.opacity(0.18), radius: 0.8, y: 0.5)
                    .offset(x: on ? S(6) : -S(6))
            }
        }
        .buttonStyle(.plain)
        .help(on ? "点一下关掉" : "点一下打开")
    }
}

/// 录制中的呼吸红点
struct PulseDot: View {
    @State private var on = false
    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.sched.opacity(0.35))
                .frame(width: S(7), height: S(7))
                .scaleEffect(on ? 2.2 : 1)
                .opacity(on ? 0 : 1)
            Circle().fill(Theme.sched).frame(width: S(7), height: S(7))
        }
        .frame(width: S(18), height: S(18))
        .onAppear {
            withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) { on = true }
        }
    }
}
