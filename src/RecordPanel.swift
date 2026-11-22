//
//  RecordPanel.swift
//  书办（ShuBan）· 录屏面板
//
//  独立录屏工具那套「墨蓝 + 电光蓝」的深色界面整体舍弃，全部改用书办的语言：
//  宣纸暖白打底、中国红主色、金线点缀、宋体印章、字号统一走 Fnt/S 的缩放体系。
//  形态上：它是独立窗口（2026-11-22 重构），不再是主面板的一个态。
//  录屏的内容是一列竖排设置卡，要窄而高；主面板是日历，要方。挤在一个壳里谁都别扭。
//  从主面板顶部的「功能」菜单进来，左上角 ✕ 关掉。
//

import SwiftUI
import AppKit

// MARK: - 这一页自己的字号与尺寸档

/// 录屏窗口是独立窗口，尺寸自己定（默认 620×690），所以不再跟随主面板的全局缩放档
/// —— 那个档位是主面板宽度的函数，两个窗口各拖各的会互相抢。
/// 这里给录屏窗钉一个固定档，窗口拉大时只是留白变多，字号不动。
private let panelZoom: CGFloat = 1.15

/// 长度：把基准版的固定尺寸换算到本窗口的档位
@inline(__always)
private func PZ(_ v: CGFloat) -> CGFloat { v * panelZoom }

/// 字号：同 PZ，但直接产出 Font
private func PF(_ size: CGFloat,
                _ weight: Font.Weight = .regular,
                _ design: Font.Design = .default) -> Font {
    .system(size: (size * panelZoom * 2).rounded() / 2, weight: weight, design: design)
}

/// 最近录制那一列的节拍器。文件是「盘上的东西」，随时可能在 Finder 里被删掉、
/// 被微信挪走，光靠 onAppear / 换阶段拉一次是不够的 —— 拉一次之后就一直是旧快照。
private let recentsTicker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

struct RecordPanel: View {
    @Environment(\.closeFeaturePane) private var closePane
    @EnvironmentObject var rec: Recorder
    /// 最近十来条成片。窗口拉高时它撑满下半区，不再留一大片空白
    @State private var recents: [RecentClip] = []
    /// 正在问「真要删？」的那一行。删除是不可撤销动作里的头一号，
    /// 点一下就没了太糙；这里用行内二次确认，不用弹窗（这个窗是非激活面板，弹窗很别扭）
    @State private var confirmingDelete: String?
    /// 二次确认的自动收回（切去看别的、忘了点，5 秒后自己复位）
    @State private var confirmFallback: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 0) {
            header
            ribbonDivider
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            actionBar
        }
        .onAppear {
            rec.refreshPermission()
            // 没权限就顺手向系统登记一次：不然系统设置里根本找不到「书办」这一项，
            // 用户点「去开启」进去也只能对着空列表发呆。
            rec.ensureRegisteredOnce()
            loadRecents()
            // 只给拍图验收用：WECAL_REC_CONFIRM=1 把第一行摆成「正问要不要删」那个态。
            // 这个态平时只有鼠标点得出来，不摆出来的话排版没人验过。
            if ProcessInfo.processInfo.environment["WECAL_REC_CONFIRM"] == "1",
               let f = recents.first {
                confirmingDelete = f.id
            }
        }
        .onChange(of: rec.phase) { _ in loadRecents() }
        // 盘面对一遍：文件被别处删掉 → 这一行自己消失，别留个点开就报错的僵尸行。
        // 只在窗口真在屏幕上时才跑：关掉只是 orderOut，视图还活着，
        // 不挡这一下的话，一条两秒的轮询会在后台一直空转。
        .onReceive(recentsTicker) { _ in
            guard paneIsOpen else { return }
            // 录制中 / 封装中盘上那个文件是 0 字节的临时件，跟着抖没意义
            switch rec.phase {
            case .recording, .countdown, .finishing: return
            default: break
            }
            loadRecents()
        }
    }

    /// 录屏窗现在是不是摊在屏幕上。窗口在 makePanel 里挂了 identifier（= 存档键），
    /// 拿它认人 —— 不能用标题，标题是给内部识别用的普通字符串，改起来没约束。
    private var paneIsOpen: Bool {
        let id = NSUserInterfaceItemIdentifier(FeaturePane.record.frameKey)
        return NSApp.windows.contains { $0.identifier == id && $0.isVisible }
    }

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
                .help("关闭录屏窗口")

                ZStack {
                    RoundedRectangle(cornerRadius: PZ(8), style: .continuous)
                        .fill(Theme.redGradient)
                        .frame(width: PZ(29), height: PZ(29))
                        .shadow(color: Theme.redDeep.opacity(0.45), radius: PZ(3), y: PZ(1.5))
                    RoundedRectangle(cornerRadius: PZ(8), style: .continuous)
                        .strokeBorder(Theme.todo.opacity(0.75), lineWidth: 0.9)
                        .frame(width: PZ(26), height: PZ(26))
                    Text("录")
                        .font(PF(15, .bold, .serif))
                        .foregroundColor(.white)
                        .offset(y: PZ(-0.5))
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("录 屏").font(PF(21, .heavy, .rounded)).foregroundColor(Theme.sched)
                        Text("书办子功能")
                            .font(PF(8.5, .semibold, .rounded))
                            .foregroundColor(Theme.goldDeep)
                            .padding(.horizontal, PZ(4))
                            .padding(.vertical, PZ(1))
                            .background(Capsule().fill(Theme.todo.opacity(0.18)))
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "record.circle")
                            .font(PF(8.5, .semibold))
                            .foregroundColor(Theme.sched.opacity(0.75))
                        Text(subTitle).font(PF(10)).foregroundColor(Theme.inkSoft).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if rec.isRecording {
                    HStack(spacing: PZ(4)) {
                        Circle().fill(.white).frame(width: PZ(5), height: PZ(5))
                        Text(rec.timerText)
                            .font(PF(12, .bold, .rounded)).monospacedDigit()
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, PZ(7)).padding(.vertical, PZ(3))
                    .background(Capsule().fill(Theme.redGradient))
                }
            }
            .padding(.horizontal, PZ(13))
            .padding(.top, PZ(8))
            .padding(.bottom, PZ(7))
        }
    }

    private var subTitle: String {
        if !rec.granted { return "还差「屏幕录制」权限" }
        return "屏幕 · 麦克风 · 一键成片"
    }

    private var ribbonDivider: some View {
        Theme.ribbon.frame(height: PZ(1.2)).opacity(0.55).padding(.horizontal, PZ(12))
    }

    // MARK: 主体按阶段切换

    /// 倒计时 / 录制中 / 收尾 都是「正在发生」，占满中间整块；
    /// 其余回设置态 —— 设置态是宽窗口里的两栏，才像个桌面工具。
    @ViewBuilder
    private var stage: some View {
        switch rec.phase {
        case .countdown(let n): countdownStage(n)
        case .recording:       recordingStage
        case .finishing:       finishingStage
        default:               setupStage
        }
    }

    // MARK: 设置态

    /// 宽窗口：上面横贯的状态卡（权限 / 结果 / 失败 / 自检），
    /// 中间「录制范围 | 选项」并排，下面最近录制。主按钮在底栏右下角。
    private var setupStage: some View {
        // GeometryReader 是为了「不足一屏也铺满」：ScrollView 里的子视图拿到的是
        // 理想高度，给它 maxHeight 没用，卡片照样顶在上边、底下留一片空。
        // 用视口高度当下限，最近录制那张卡才会一直长到底。
        GeometryReader { geo in
        ScrollView(showsIndicators: false) {
            VStack(spacing: PZ(10)) {
                if !rec.granted { permCard }
                if case .done(let r) = rec.phase { resultCard(r) }
                if case .failed(let msg) = rec.phase { failCard(msg) }
                if !rec.checkLines.isEmpty { checkCard }
                HStack(alignment: .top, spacing: PZ(10)) {
                    rangeCard
                    optionCard
                }
                // 这一行只取自己的固有高度（两张卡片互相对齐到较高那张），
                // 不然 rangeCard 的 maxHeight 会把这个横排也拉成可伸缩的，
                // 结果上面顶出一大块空白、下面最近录制反而被挤扁
                .fixedSize(horizontal: false, vertical: true)
                // 剩下的高度全给最近录制：窗口高一点就多看几条，
                // 而不是底下空一大块 —— 桌面软件的主列表本来就该跟着窗口长
                recentCard
            }
            .frame(minHeight: max(0, geo.size.height - PZ(25)), alignment: .top)
            .padding(.horizontal, PZ(14))
            .padding(.top, PZ(11))
            .padding(.bottom, PZ(14))
        }
        }
    }

    private var permCard: some View {
        card(tint: Theme.todo.opacity(0.12), border: Theme.todo.opacity(0.45)) {
            VStack(alignment: .leading, spacing: PZ(6)) {
                HStack(spacing: PZ(5)) {
                    Image(systemName: "lock.shield.fill")
                        .font(PF(11)).foregroundColor(Theme.goldDeep)
                    Text("需要「屏幕录制」权限").font(PF(11, .bold)).foregroundColor(Theme.ink)
                }
                Text(" macOS 的规定：勾上之后必须重启书办才生效。授权一次，以后不用再管。")
                    .font(PF(9.5)).foregroundColor(Theme.inkSoft).fixedSize(horizontal: false, vertical: true)
                Text("在「系统设置 → 隐私与安全性 → 屏幕录制」里勾上「书办」，再点「重启书办」。"
                     + "列表里没有它就先点「去开启」。勾上了这里会在两秒内自动消失。")
                    .font(PF(9)).foregroundColor(Theme.inkSoft.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: PZ(6)) {
                    ghostButton("去开启", icon: "arrow.up.forward.square") {
                        rec.openPrivacy("Privacy_ScreenCapture")
                    }
                    ghostButton("重启书办", icon: "arrow.triangle.2.circlepath") { rec.relaunch() }
                }
            }
        }
    }

    private var rangeCard: some View {
        card(stretch: true) {
            VStack(alignment: .leading, spacing: PZ(7)) {
                sectionLabel("录制范围", right: rec.targetText)
                HStack(spacing: PZ(5)) {
                    ForEach(RecRange.allCases) { r in rangeChip(r) }
                }
                Text(hintText).font(PF(9)).foregroundColor(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                if rec.range == .region {
                    HStack(spacing: PZ(6)) {
                        if let rg = rec.region {
                            Text("已框选 \(Int(rg.width)) × \(Int(rg.height))")
                                .font(PF(9.5, .semibold, .rounded))
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
            VStack(spacing: PZ(2)) {
                Image(systemName: icon(r))
                    .font(PF(11, .semibold))
                Text(r.label).font(PF(10, on ? .bold : .medium))
            }
            .foregroundColor(on ? .white : (dead ? Theme.inkSoft.opacity(0.45) : Theme.inkSoft))
            .frame(maxWidth: .infinity)
            .padding(.vertical, PZ(8))
            .background(
                RoundedRectangle(cornerRadius: PZ(10), style: .continuous)
                    .fill(on ? AnyShapeStyle(Theme.redGradient) : AnyShapeStyle(Color.black.opacity(0.05)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PZ(10), style: .continuous)
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
            VStack(spacing: PZ(7)) {
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
                    HStack(spacing: PZ(3)) {
                        ForEach([0, 3, 5], id: \.self) { n in
                            miniChip(n == 0 ? "关" : "\(n) 秒", on: rec.countdown == n) { rec.countdown = n }
                        }
                    }
                    // 窗口缩到最小的时候，别让这三个胶囊被挤成两行「3 / 秒」——
                    // 宁可左边那行说明文字被截断（它有 lineLimit(1) 兜着）
                    .fixedSize()
                }
                divider
                optionRow("folder", "录完打开 Finder", "顺手把文件挑出来，方便发人") {
                    RecSwitch(on: rec.reveal) { rec.reveal = $0 }
                }
            }
        }
    }

    private var recentCard: some View {
        card(stretch: true) {
            VStack(alignment: .leading, spacing: PZ(6)) {
                sectionLabel("最近录制", right: "\(recents.count) 条")
                if recents.isEmpty {
                    // 空列表也留这张卡：删掉最后一条之后整块塌掉，看着像出了 bug，
                    // 而不是「这里本来就没东西」
                    HStack(spacing: PZ(5)) {
                        Image(systemName: "tray")
                            .font(PF(10)).foregroundColor(Theme.inkSoft.opacity(0.55))
                        Text("还没有成片 · 录一段就有了")
                            .font(PF(9.5)).foregroundColor(Theme.inkSoft.opacity(0.85))
                    }
                    .padding(.top, PZ(2))
                }
                ForEach(Array(recents.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { divider }
                    HStack(spacing: PZ(6)) {
                        Image(systemName: c.isShare ? "square.and.arrow.up.on.square" : "film")
                            .font(PF(10, .semibold))
                            .foregroundColor((c.isShare ? Theme.goldDeep : Theme.sched).opacity(0.75))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(c.name)
                                .font(PF(9.5, .semibold)).foregroundColor(Theme.ink)
                                .lineLimit(1).truncationMode(.middle)
                                .help(c.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            Text("\(Media.fmtSize(c.size)) · \(RelativeDate.text(c.date))"
                                 + (c.isShare ? " · 分享版" : ""))
                                .font(PF(8.5)).foregroundColor(Theme.inkSoft)
                        }
                        Spacer(minLength: PZ(4))
                        // 问「真要删？」的这一行：两枚小胶囊换掉那三个图标，
                        // 位置固定，不会把整行挤得跳一下
                        if confirmingDelete == c.id {
                            actionChip("移到废纸篓", color: Theme.warn) { remove(c) }
                            actionChip("算了", color: Theme.inkSoft) { cancelConfirm() }
                        } else {
                            iconButton("play.circle.fill", tint: Theme.sched, help: "播放") {
                                rec.open(c.url)
                            }
                            iconButton("magnifyingglass.circle", tint: Theme.inkSoft,
                                       help: "在 Finder 里显示") { rec.reveal(c.url) }
                            iconButton("trash", tint: Theme.inkSoft.opacity(0.6), help: "移到废纸篓") {
                                askRemove(c)
                            }
                        }
                    }
                }
            }
        }
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

    // MARK: 删一条成片

    /// 先问一句。删除没有撤销键，误点一下原片就进废纸篓了 ——
    /// 虽然废纸篓能捞回来，但多数人不会想到去翻。
    private func askRemove(_ c: RecentClip) {
        confirmingDelete = c.id
        confirmFallback?.cancel()
        let w = DispatchWorkItem { if confirmingDelete == c.id { confirmingDelete = nil } }
        confirmFallback = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    private func cancelConfirm() {
        confirmFallback?.cancel()
        confirmingDelete = nil
    }

    private func remove(_ c: RecentClip) {
        cancelConfirm()
        // 「xxx_分享版.mp4」是同一条录制压出来的子件。删原片时一起收走，
        // 不然列表里会留个孤儿分享版，谁也认不出它从哪来。
        let targets = [c.url] + Self.shareCompanions(of: c.url)
        var failed: String?
        for u in targets where FileManager.default.fileExists(atPath: u.path) {
            do {
                try FileManager.default.trashItem(at: u, resultingItemURL: nil)
            } catch {
                failed = u.lastPathComponent + "：" + error.localizedDescription
            }
        }
        // 删掉的正好是「录制完成」那张卡在说的那条 → 那张卡也就没话可说了
        if let last = rec.lastResultPath,
           last.standardizedFileURL.path == c.url.standardizedFileURL.path {
            rec.reset()
        }
        loadRecents()
        if let msg = failed {
            rec.statusLine = "有文件没删掉（\(msg)）"
        } else if recents.isEmpty {
            rec.statusLine = "已移入废纸篓，录屏文件夹现在空了"
        } else {
            rec.statusLine = "已移入废纸篓：\(c.name)"
        }
        rec.onLog?("删除成片 \(c.name)")
    }

    /// 一条录制名下的分享版（`原片名_分享版.mp4`）。传进来的自己就是分享版时返回空 ——
    /// 删分享版不该顺手把原片也带走。
    static func shareCompanions(of url: URL) -> [URL] {
        let base = url.deletingPathExtension()
        guard !base.lastPathComponent.hasSuffix("_分享版") else { return [] }
        let share = base.deletingLastPathComponent()
            .appendingPathComponent(base.lastPathComponent + "_分享版.mp4")
        return FileManager.default.fileExists(atPath: share.path) ? [share] : []
    }

    /// 扫一个目录里最新的成片。抽成静态的，是为了让验收能脱离窗口直接验它 ——
    /// 「文件被删了要不要消失」这种逻辑光看界面看不出来。
    static func scan(_ dir: URL, limit: Int = 12) -> [RecentClip] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return [] }
        let list: [RecentClip] = items.compactMap { u in
            guard u.pathExtension.lowercased() == "mp4" else { return nil }
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let d = v?.contentModificationDate else { return nil }
            return RecentClip(url: u, size: v?.fileSize ?? 0, date: d)
        }
        return Array(list.sorted { $0.date > $1.date }.prefix(limit))
    }

    private func loadRecents() {
        recents = Self.scan(rec.outDir)
        RecordPanel.debugRecents = recents
    }

    /// 测试接缝：界面此刻拿的是哪几条成片。
    /// 「文件被别处删掉 → 这一行自己消失」这条链子，光验 scan 是假通过 ——
    /// scan 是纯函数，本来就对；真会坏的是轮询没跑、或者窗口认错了人根本没刷。
    /// 所以要有一处能回答「屏幕上现在列着什么」。
    static var debugRecents: [RecentClip] = []

    // MARK: 倒计时 / 录制中 / 收尾

    private func countdownStage(_ n: Int) -> some View {
        VStack(spacing: PZ(12)) {
            ZStack {
                Circle().fill(Theme.sched.opacity(0.10)).frame(width: PZ(96), height: PZ(96))
                Circle().stroke(Theme.todo.opacity(0.5), lineWidth: 1.2)
                    .frame(width: PZ(96), height: PZ(96))
                Text("\(n)")
                    .font(PF(46, .bold, .rounded)).monospacedDigit()
                    .foregroundColor(Theme.sched)
            }
            Text("准备开始 · \(rec.range.label) \(rec.targetText)")
                .font(PF(10)).foregroundColor(Theme.inkSoft)
            Text("把要讲的窗口摆好，倒计时结束就开始录")
                .font(PF(8.5)).foregroundColor(Theme.inkSoft.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recordingStage: some View {
        VStack(spacing: PZ(10)) {
            card {
                VStack(spacing: PZ(8)) {
                    HStack(spacing: PZ(5)) {
                        PulseDot()
                        Text("正在录制").font(PF(11, .bold)).foregroundColor(Theme.sched)
                        Spacer(minLength: 0)
                        Text(rec.targetText)
                            .font(PF(9.5, .semibold, .rounded))
                            .foregroundColor(Theme.goldDeep)
                    }
                    Text(rec.timerText)
                        .font(PF(44, .semibold, .rounded)).monospacedDigit()
                        .foregroundColor(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text("screencapture 是停止时才封装写文件，中途文件大小为 0 属正常")
                        .font(PF(8.5)).foregroundColor(Theme.inkSoft.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("也可以点屏幕上方悬浮条里的「停止」；书办自己和悬浮条都不参与屏幕采集，成片里不会出现")
                .font(PF(8.5)).foregroundColor(Theme.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        // 宽窗口里别把计时卡拉成通栏，收在 420pt 上下更像个计时器
        .frame(maxWidth: PZ(420), maxHeight: .infinity)
        .padding(.horizontal, PZ(14))
    }

    private var finishingStage: some View {
        VStack(spacing: PZ(10)) {
            ProgressView().progressViewStyle(.circular).controlSize(.large).tint(Theme.sched)
            Text(rec.statusLine.isEmpty ? "正在封装写入文件…" : rec.statusLine)
                .font(PF(11, .semibold)).foregroundColor(Theme.ink)
            Text("刚结束，正在算时长、体检画面和声音")
                .font(PF(9)).foregroundColor(Theme.inkSoft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 结果 / 失败 / 自检

    private func resultCard(_ r: RecResult) -> some View {
        card(tint: Theme.ok.opacity(0.08), border: Theme.ok.opacity(0.35)) {
            VStack(alignment: .leading, spacing: PZ(6)) {
                HStack(spacing: PZ(5)) {
                    ZStack {
                        Circle().fill(Theme.ok).frame(width: PZ(16), height: PZ(16))
                        Image(systemName: "checkmark").font(PF(8.5, .bold)).foregroundColor(.white)
                    }
                    Text("录制完成").font(PF(11.5, .bold)).foregroundColor(Theme.ink)
                    Spacer(minLength: 0)
                    Text(Media.fmtDuration(r.seconds))
                        .font(PF(11, .bold, .rounded)).monospacedDigit()
                        .foregroundColor(Theme.goldDeep)
                }
                Text(r.path.lastPathComponent)
                    .font(PF(10.5, .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                Text("\(Media.fmtSize(r.bytes))　·　\(r.hasAudio ? "含语音" : "无音频")　·　"
                     + r.path.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(PF(8.5)).foregroundColor(Theme.inkSoft).lineLimit(1)
                if !r.note.isEmpty {
                    Text(r.note)
                        .font(PF(9)).foregroundColor(Theme.warn)
                        .padding(PZ(6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: PZ(7), style: .continuous)
                            .fill(Theme.warn.opacity(0.10)))
                }
                HStack(spacing: PZ(5)) {
                    ghostButton("播放", icon: "play.fill", solid: true) { rec.open(r.path) }
                    ghostButton("Finder", icon: "folder") { rec.reveal(r.path) }
                    if rec.compressing {
                        HStack(spacing: PZ(4)) {
                            ProgressView().controlSize(.small).tint(Theme.sched)
                            Text("压缩中…").font(PF(9.5, .semibold)).foregroundColor(Theme.inkSoft)
                        }
                    } else {
                        ghostButton(r.shared == nil ? "生成分享版" : "分享版已生成",
                                    icon: "square.and.arrow.up") {
                            if let s = r.shared { rec.reveal(s) } else { rec.compressShare() }
                        }
                    }
                }
                .padding(.top, PZ(2))
                if let s = r.shared {
                    Text("分享版 \(Media.fmtSize(Media.bytes(of: s))) · 画面压到 1080p，发微信/邮件够用")
                        .font(PF(8.5)).foregroundColor(Theme.goldDeep)
                }
            }
        }
    }

    private func failCard(_ msg: String) -> some View {
        card(tint: Theme.sched.opacity(0.07), border: Theme.sched.opacity(0.30)) {
            VStack(alignment: .leading, spacing: PZ(6)) {
                HStack(spacing: PZ(5)) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(PF(11)).foregroundColor(Theme.sched)
                    Text("录制没成").font(PF(11, .bold)).foregroundColor(Theme.ink)
                }
                Text(msg).font(PF(9.5)).foregroundColor(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: PZ(5)) {
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
            VStack(alignment: .leading, spacing: PZ(4)) {
                sectionLabel("自检结果")
                ForEach(rec.checkLines, id: \.self) { l in
                    Text(l)
                        .font(PF(9.5, l.hasPrefix("✗") ? .semibold : .regular))
                        .foregroundColor(l.hasPrefix("✗") ? Theme.sched
                                            : (l.hasPrefix("!") ? Theme.goldDeep : Theme.inkSoft))
                }
            }
        }
    }

    // MARK: 底栏

    /// 底栏 = 左边状态、右边主操作。桌面软件的惯例是主按钮沉在右下角，
    /// 而且在录制 / 倒计时 / 封装这三种进行态里，同一条栏给出的动作正好是此刻唯一该做的那个。
    private var actionBar: some View {
        HStack(spacing: PZ(7)) {
            Circle()
                .fill(rec.isRecording ? Theme.sched : (rec.granted ? Theme.ok : Theme.todo))
                .frame(width: PZ(5), height: PZ(5))
            Text(rec.statusLine.isEmpty ? "成片默认存到 ~/Movies/屏幕录制" : rec.statusLine)
                .font(PF(9.5)).foregroundColor(Theme.inkSoft).lineLimit(1)
            Spacer(minLength: PZ(8))
            actionBarButtons
        }
        .padding(.horizontal, PZ(16))
        .padding(.vertical, PZ(8))
        .background(Theme.cream.opacity(0.92))
        .overlay(alignment: .top) { Theme.ribbon.frame(height: PZ(1)).opacity(0.45) }
    }

    @ViewBuilder
    private var actionBarButtons: some View {
        switch rec.phase {
        case .recording:
            primaryButton("停止并保存", icon: "stop.fill", fill: stopGradient) { rec.stop() }
        case .countdown:
            ghostButton("取消倒计时", icon: "xmark") { rec.cancelCountdown() }
        case .finishing:
            HStack(spacing: PZ(5)) {
                ProgressView().controlSize(.small).tint(Theme.sched)
                Text("正在封装…").font(PF(9.5, .semibold)).foregroundColor(Theme.inkSoft)
            }
        default:
            ghostButton(rec.checking ? "检查中…" : "检查设备", icon: "checklist") { rec.selfCheck() }
                .disabled(rec.checking)
            ghostButton("录制文件夹", icon: "folder") { rec.openFolder() }
            primaryButton("开始录制", icon: "largecircle.fill.circle") { rec.start() }
        }
    }

    private var stopGradient: LinearGradient {
        LinearGradient(colors: [Theme.redDeep, Theme.warn], startPoint: .top, endPoint: .bottom)
    }

    private func primaryButton(_ t: String, icon: String,
                               fill: LinearGradient = Theme.redGradient,
                               action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            HStack(spacing: PZ(4)) {
                Image(systemName: icon).font(PF(10.5, .semibold))
                Text(t).font(PF(11.5, .bold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, PZ(14)).padding(.vertical, PZ(6))
            .background(RoundedRectangle(cornerRadius: PZ(9), style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: PZ(9), style: .continuous)
                .stroke(Theme.todo.opacity(0.55), lineWidth: 0.9))
            .shadow(color: Theme.redDeep.opacity(0.3), radius: PZ(4), y: PZ(1.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: 通用件

    /// stretch = 让卡片撑满可用高度。背景是画在 frame 之后的，
    /// 所以只在外层加 maxHeight 没用 —— 卡片只会顶在上边，底下照样是空的。
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

    private func sectionLabel(_ t: String, right: String = "") -> some View {
        HStack(spacing: PZ(5)) {
            Rectangle().fill(Theme.todo).frame(width: PZ(2), height: PZ(9))
            Text(t).font(PF(9.5, .semibold)).foregroundColor(Theme.goldDeep)
            Spacer(minLength: 0)
            if !right.isEmpty {
                Text(right).font(PF(9, .semibold, .rounded)).foregroundColor(Theme.inkSoft)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.sched.opacity(0.08)).frame(height: 0.8)
    }

    private func optionRow(_ icon: String, _ title: String, _ sub: String,
                           @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: PZ(7)) {
            Image(systemName: icon)
                .font(PF(11, .semibold))
                .foregroundColor(Theme.sched.opacity(0.8))
                .frame(width: PZ(16))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(PF(10.5, .semibold)).foregroundColor(Theme.ink)
                Text(sub).font(PF(8.5)).foregroundColor(Theme.inkSoft).lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing()
        }
    }

    private func miniChip(_ t: String, on: Bool, select: @escaping () -> Void) -> some View {
        Button { select() } label: {
            Text(t)
                .font(PF(9, on ? .bold : .regular))
                .foregroundColor(on ? .white : Theme.inkSoft)
                .padding(.horizontal, PZ(7)).padding(.vertical, PZ(2.5))
                .background(Capsule().fill(on ? AnyShapeStyle(Theme.redGradient)
                                              : AnyShapeStyle(Color.black.opacity(0.06))))
        }
        .buttonStyle(.plain)
    }

    private func ghostButton(_ t: String, icon: String, solid: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            HStack(spacing: PZ(3.5)) {
                Image(systemName: icon).font(PF(9, .semibold))
                Text(t).font(PF(9.5, .semibold))
            }
            .foregroundColor(solid ? .white : Theme.sched)
            .padding(.horizontal, PZ(8)).padding(.vertical, PZ(4.5))
            .background(
                RoundedRectangle(cornerRadius: PZ(7), style: .continuous)
                    .fill(solid ? AnyShapeStyle(Theme.redGradient) : AnyShapeStyle(Theme.sched.opacity(0.08)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PZ(7), style: .continuous)
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
    /// 「xxx_分享版.mp4」是同一条录制压出来的分享子件，界面上要跟原片区分开
    var isShare: Bool { url.deletingPathExtension().lastPathComponent.hasSuffix("_分享版") }
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
        let gap = Date().timeIntervalSince(d)
        // 刚落盘的东西 RelativeDateTimeFormatter 会说「0秒后」——那是在夸自己手快吗
        if abs(gap) < 60 { return "刚刚" }
        if gap < 60 * 60 * 24 {
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
                    .frame(width: PZ(30), height: PZ(17))
                Circle()
                    .fill(.white)
                    .frame(width: PZ(13), height: PZ(13))
                    .shadow(color: .black.opacity(0.18), radius: 0.8, y: 0.5)
                    .offset(x: on ? PZ(6) : -PZ(6))
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
                .frame(width: PZ(7), height: PZ(7))
                .scaleEffect(on ? 2.2 : 1)
                .opacity(on ? 0 : 1)
            Circle().fill(Theme.sched).frame(width: PZ(7), height: PZ(7))
        }
        .frame(width: PZ(18), height: PZ(18))
        .onAppear {
            withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) { on = true }
        }
    }
}
