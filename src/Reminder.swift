//
//  Reminder.swift
//  书办（ShuBan）· 桌面弹出式提醒
//
//  设计目标：中国红主色、多层动画、不打断当前操作（nonactivating），
//  到点自动消失，也可点 × 立即关闭。
//
//  视觉分层（从底到面，全部裁在圆角里）：
//    1. 径向渐变底   —— 左上角偏亮，右下沉到深红，比纯线性更有体积
//    2. 漂移光雾     —— 两团 7.5 秒往复的柔光（一团白、一团金），卡片会「呼吸」
//    3. 上升火星     —— Canvas 画的 18 颗小光点，缓缓升起再淡出
//    4. 斜向扫光     —— 2.4 秒一道，掠过整张卡
//    5. 玻璃高光     —— 上半部白到透明，做出亚克力质感
//    6. 边框流光     —— 金色高光沿圆角边框绕圈（5.2 秒一圈）
//    7. 顶部金线     —— 静态但带发光，压住重心
//

import SwiftUI
import AppKit

struct ReminderItem {
    let subject: String
    let beginText: String      // "10:30"
    let minutesLeft: Int       // 0 表示现在开始
    let attendees: [String]
    let place: String
    var title: String = "日 程 提 醒"   // 待办提醒会改成「待 办 提 醒」
    var caption: String = ""           // 非空则覆盖「N 分钟后开始」那句
    /// 待办 id：非空才显示「延期」按钮（日程是别人的会，延期没意义）
    var todoId: String = ""
}

// MARK: - 弹窗调度

/// 窗口比卡片大一圈，多出来的透明区用来放外发光。
/// 但透明区不该吃点击（会挡住底下窗口的标题栏），所以落在卡片矩形外的点击一律穿透。
final class GlowHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let parent = superview else { return super.hitTest(point) }
        let local = convert(point, from: parent)
        let card = bounds.insetBy(dx: ReminderView.pad, dy: ReminderView.pad)
        // 卡片外的透明区一律穿透；卡片内即使 SwiftUI 说没命中也要兜底返回 self，
        // 否则万一取不到 view，整张卡会变得点不动（× 和延期按钮全废）。
        guard card.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }
}

@MainActor
final class ReminderCenter {
    static let shared = ReminderCenter()
    private var window: NSPanel?

    func show(item: ReminderItem, duration: Double = 22,
              onSnooze: ((Int) -> Void)? = nil) {
        dismiss()

        let root = ReminderView(item: item, duration: duration,
                                onClose: { [weak self] in self?.dismiss() },
                                onSnooze: { [weak self] minutes in
                                    // 点延期：卡片先收起来，再交给上层改时间
                                    self?.dismiss()
                                    onSnooze?(minutes)
                                })
        // 待办卡多一排延期按钮，要高一些；四周再留 pad 给光晕
        let size = ReminderView.windowSize(for: item)
        let host = GlowHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)

        let w = NSPanel(contentRect: host.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false            // 光晕由 SwiftUI 绘制，避免方框阴影
        w.level = .screenSaver         // 盖住全屏应用也能看见
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.contentView = host

        if let scr = NSScreen.main {
            let vf = scr.visibleFrame
            // 让「卡片」上边缘离屏幕顶 36pt（窗口多出来的那段透明边不算）
            let x = vf.midX - size.width / 2
            let y = vf.maxY - 36 + ReminderView.pad - size.height
            w.setFrameOrigin(NSPoint(x: x, y: y))
        }
        w.orderFrontRegardless()
        window = w

        NSSound(named: NSSound.Name("Glass"))?.play()

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.dismiss()
        }
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - 提醒卡片

struct ReminderView: View {
    let item: ReminderItem
    let duration: Double
    let onClose: () -> Void
    var onSnooze: (Int) -> Void = { _ in }

    @State private var appear = false
    @State private var bellSwing = false
    @State private var ringPhase = false
    @State private var sweep = false
    @State private var glow = false
    @State private var progress: CGFloat = 1
    @State private var breathing = false
    @State private var spin = false       // 边框光环 / 铃铛刻度环
    @State private var drift = false      // 光雾漂移

    private let w: CGFloat = 430
    /// 卡片四周留给外发光的透明边。窗口按 w/h + 2*pad 开，
    /// 否则 shadow 画在窗口外面直接被裁掉 —— 之前那圈光晕其实一直没显示出来。
    static let pad: CGFloat = 30
    /// 光晕往外扩散的距离（+ 描边宽度的一半刚好落在 pad 内，不被窗口边裁掉）
    private var glowSpread: CGFloat { 22 }
    /// 待办卡要多一排「延期」按钮，所以比日程卡高。
    /// 数值靠离屏渲染（WECAL_SNAP）量出来的：176 会在卡片底部空出一截。
    static func height(for item: ReminderItem) -> CGFloat {
        item.todoId.isEmpty ? 132 : 158
    }
    /// 窗口尺寸 = 卡片 + 四周发光留白
    static func windowSize(for item: ReminderItem) -> NSSize {
        NSSize(width: 430 + pad * 2, height: height(for: item) + pad * 2)
    }
    private var h: CGFloat { Self.height(for: item) }
    private var corner: CGFloat { 24 }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
    }

    var body: some View {
        ZStack {
            card
            content
        }
        .frame(width: w, height: h)
        // 光晕必须挂 background：放进 ZStack 的话，ZStack 会按光晕的尺寸（比卡片大 44pt）
        // 去建议子视图，而 Shape 会吃满建议尺寸 —— 实测卡片被撑成整窗、透明边全消失。
        .background { halo }
        // 入场：从上往前翻下来 + 微微放大，比单纯淡入更有分量
        .scaleEffect(appear ? 1 : 0.84, anchor: .top)
        .rotation3DEffect(.degrees(appear ? 0 : -26),
                          axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.55)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : -18)
        .padding(Self.pad)          // 最后留出光晕空间，顺序不能提到动画前面
        .onAppear(perform: start)
    }

    // MARK: 卡片

    /// 外发光：用 Canvas 一圈圈往外叠圆角描边（内圈红、外圈金），衰减是手算的。
    /// 试过 `.shadow` 和 `.blur` 两种画法，离屏渲染里都能看出问题：
    /// shadow 在高不透明度大半径下会出现「洋葱环」，blur 的离屏纹理还会切出硬边矩形。
    /// 手画最笨但结果确定，也不受合成顺序影响。
    private var halo: some View {
        Canvas { gc, size in
            let steps = 10
            for i in 0..<steps {
                let t = Double(i) / Double(steps - 1)              // 0 贴边 → 1 最外
                let grow = glowSpread * t
                let rect = CGRect(
                    x: (size.width - w) / 2 - grow,
                    y: (size.height - h) / 2 - grow,
                    width: w + grow * 2, height: h + grow * 2
                )
                let path = Path(roundedRect: rect, cornerRadius: corner + grow, style: .continuous)
                let fade = pow(1 - t, 1.8)
                gc.stroke(path,
                          with: .color(Theme.sched.opacity(fade * (glow ? 0.20 : 0.13))),
                          lineWidth: 15)
                if i < 3 {
                    gc.stroke(path,
                              with: .color(Theme.todo.opacity(fade * (glow ? 0.16 : 0.10))),
                              lineWidth: 7)
                }
            }
        }
        .frame(width: w + glowSpread * 2, height: h + glowSpread * 2)
        .allowsHitTesting(false)
    }

    private var card: some View {
        shape
            .fill(
                RadialGradient(
                    stops: [
                        // 亮核收小：铺得太开整张卡会变橙，失去 #DE2910 中国红的正色
                        .init(color: Color(red: 0.93, green: 0.20, blue: 0.08), location: 0.0),
                        .init(color: Theme.sched, location: 0.30),
                        .init(color: Theme.redDeep, location: 0.74),
                        .init(color: Color(red: 0.50, green: 0.03, blue: 0.10), location: 1.0),
                    ],
                    center: UnitPoint(x: 0.12, y: 0.0),
                    startRadius: 4, endRadius: w * 0.92
                )
            )
            .overlay { driftFog.clipShape(shape) }
            .overlay { embers.clipShape(shape) }
            .overlay { sweepLight.clipShape(shape) }
            .overlay { sheen.clipShape(shape) }
            .overlay { bottomShade.clipShape(shape) }
            .overlay { rimLight }
            .overlay(alignment: .top) { topGoldLine }
            .compositingGroup()
            // 卡片本体只留一点点下投影，主要发光交给 halo
            .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 4)
    }

    /// 两团柔光在卡内往复漂移，让整张卡像在缓慢呼吸。
    /// 透明度刻意压得低：白雾一多整张卡会发橙发白，白字就糊了。
    private var driftFog: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(red: 1.0, green: 0.74, blue: 0.52).opacity(0.13), .clear],
                                     center: .center, startRadius: 0, endRadius: 138))
                .frame(width: 276, height: 276)
                .offset(x: drift ? 42 : -86, y: drift ? -44 : -92)
            Circle()
                .fill(RadialGradient(colors: [Theme.todo.opacity(0.26), .clear],
                                     center: .center, startRadius: 0, endRadius: 126))
                .frame(width: 252, height: 252)
                .offset(x: drift ? w * 0.46 : w * 0.28,
                        y: drift ? h * 0.44 : h * 0.98)
        }
        .allowsHitTesting(false)
    }

    /// 上升火星：位置由 index 的黄金分割小数决定，不存状态也不随机跳动
    private var embers: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                for i in 0..<18 {
                    let s = Double(i) * 0.61803398875
                    let frac = s - floor(s)
                    let speed = 0.055 + frac * 0.075
                    let phase = (t * speed + s).truncatingRemainder(dividingBy: 1.0)
                    let x = size.width * (0.04 + 0.92 * frac)
                        + sin(t * 0.8 + s * 9) * 9
                    let y = size.height * (1.05 - 1.15 * phase)
                    guard y > -4, y < size.height + 4 else { continue }
                    let fade = sin(Double.pi * phase)          // 两头淡、中间亮
                    let r = 0.9 + frac * 1.7
                    let color = frac > 0.45 ? Theme.todo : Color.white
                    gc.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                            with: .color(color.opacity(0.14 + 0.44 * fade)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// 金色流光沿圆角边框绕圈，做成「彗星尾巴」：头亮尾淡。
    /// 之前用「大圆 AngularGradient + 圆角矩形 strokeBorder 做 mask」，
    /// 实测画不出来（四条边带里都找不到高亮弧），改成 Canvas 直接描圆角路径的
    /// trimmedPath —— 结果确定、也不受 mask 与合成顺序影响。
    private var rimLight: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1.2, dy: 1.2)
                let path = Path(roundedRect: rect, cornerRadius: corner - 1.2, style: .continuous)

                // 常亮的极淡金边，保证任何时刻边框都有质感
                gc.stroke(path, with: .color(Theme.todo.opacity(0.30)), lineWidth: 1.1)

                let head = (t / 5.2).truncatingRemainder(dividingBy: 1.0)
                let tail = 0.24
                let steps = 20
                for i in 0..<steps {
                    let k = Double(i) / Double(steps) * tail
                    var a = head - k
                    a -= floor(a)                       // 跨过 0 点要回绕
                    let seg = path.trimmedPath(from: a, to: min(a + 0.014, 1.0))
                    let alpha = pow(1 - k / tail, 1.7)
                    gc.stroke(seg,
                              with: .color(Color(red: 1.0, green: 0.94, blue: 0.74).opacity(0.95 * alpha)),
                              lineWidth: 1.1 + 1.0 * alpha)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var topGoldLine: some View {
        Capsule()
            .fill(LinearGradient(
                colors: [.clear, Theme.todo.opacity(0.9),
                         Color(red: 1.0, green: 0.94, blue: 0.74),
                         Theme.todo.opacity(0.9), .clear],
                startPoint: .leading, endPoint: .trailing))
            .frame(height: 2.5)
            .padding(.horizontal, 26)
            .shadow(color: Theme.todo.opacity(0.9), radius: 6)
            .allowsHitTesting(false)
    }

    /// 下半部压暗，字和按钮不会糊在亮底上
    private var bottomShade: some View {
        LinearGradient(colors: [.clear, Theme.redDeep.opacity(0.52)],
                       startPoint: .center, endPoint: .bottom)
            .allowsHitTesting(false)
    }

    private var sheen: some View {
        LinearGradient(colors: [Color(red: 1.0, green: 0.82, blue: 0.66).opacity(0.10), .clear],
                       startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.52))
            .allowsHitTesting(false)
    }

    private var sweepLight: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(0.32), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.42, height: geo.size.height * 1.8)
                .rotationEffect(.degrees(18))
                .offset(x: sweep ? geo.size.width * 1.2 : -geo.size.width * 0.8,
                        y: -geo.size.height * 0.4)
        }
        .allowsHitTesting(false)
    }

    // MARK: 内容

    private var content: some View {
        HStack(alignment: .center, spacing: 13) {
            bell
            VStack(alignment: .leading, spacing: 2.5) {
                HStack(alignment: .center) {
                    Text(item.title)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.8)
                        .foregroundColor(Color(red: 1.0, green: 0.90, blue: 0.66))
                        .shadow(color: Theme.todo.opacity(0.8), radius: 5)
                    Spacer(minLength: 0)
                    closeButton
                }
                Text(item.subject)
                    .font(.system(size: 16.5, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.28), radius: 3, y: 1)

                HStack(spacing: 6) {
                    Text(item.caption.isEmpty
                         ? (item.minutesLeft <= 0 ? "现在开始" : "\(item.minutesLeft) 分钟后开始")
                         : item.caption)
                        .font(.system(size: 13.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(LinearGradient(
                            colors: [Color(red: 1.0, green: 0.95, blue: 0.72),
                                     Color(red: 1.0, green: 0.80, blue: 0.36)],
                            startPoint: .top, endPoint: .bottom))
                        .shadow(color: Theme.todo.opacity(0.55), radius: 6)
                        .scaleEffect(breathing ? 1.045 : 1.0, anchor: .leading)
                    Text("· \(item.beginText)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.84))
                }

                if !metaText.isEmpty {
                    Text(metaText)
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.74))
                        .lineLimit(1)
                }

                progressBar.padding(.top, 6)
                if !item.todoId.isEmpty { snoozeRow.padding(.top, 7) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // 铃铛 + 双圈波纹 + 外圈反向旋转的金色刻度环
    private var bell: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.todo.opacity(0.5),
                              style: StrokeStyle(lineWidth: 1, dash: [2.5, 4.5]))
                .frame(width: 50, height: 50)
                .rotationEffect(.degrees(spin ? -360 : 0))

            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Color.white.opacity(0.55), lineWidth: 1.4)
                    .scaleEffect(ringPhase ? 1.85 : 0.9)
                    .opacity(ringPhase ? 0 : 0.5)
                    .animation(
                        .easeOut(duration: 2.1)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * 0.6),
                        value: ringPhase
                    )
            }

            Circle()
                .fill(Theme.todo.opacity(0.45))
                .frame(width: 40, height: 40)
                .blur(radius: 7)

            Circle()
                .fill(Color.white)
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.20), radius: 6, y: 2)

            Image(systemName: "bell.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Theme.todo, Theme.redDeep],
                                                startPoint: .top, endPoint: .bottom))
                .rotationEffect(.degrees(bellSwing ? 14 : -14), anchor: .top)
                .animation(.easeInOut(duration: 0.22).repeatForever(autoreverses: true), value: bellSwing)
        }
        .frame(width: 50, height: 50)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.92))
                .frame(width: 19, height: 19)
                .background(Circle().fill(Color.white.opacity(0.18)))
                .overlay(Circle().stroke(Color.white.opacity(0.30), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .help("关闭提醒")
    }

    /// 进度条：暗槽 + 金白渐变 + 尾端一颗发光小圆点
    private var progressBar: some View {
        GeometryReader { geo in
            let filled = max(0, geo.size.width * progress)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.20)).frame(height: 4.5)
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.88, blue: 0.55), .white],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: filled, height: 4.5)
                Circle()
                    .fill(Color.white)
                    .frame(width: 6, height: 6)
                    .shadow(color: .white.opacity(0.95), radius: 4.5)
                    .offset(x: max(0, filled - 3))
            }
        }
        .frame(height: 6)
    }

    /// 延期按钮：点一下把待办往后推，卡片立即消失。
    /// 五个档位按需求定的（1 小时 / 3 小时 / 1 天 / 3 天 / 1 周）。
    /// 实测 430pt 宽下五个完整标签也只占 2/3 行宽，所以不用缩写成「+1 时」。
    private var snoozeRow: some View {
        HStack(spacing: 6) {
            Text("延 期")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.8)
                .foregroundColor(.white.opacity(0.72))
                .fixedSize()
            ForEach(snoozeOptions, id: \.minutes) { opt in
                Button {
                    onSnooze(opt.minutes)
                } label: {
                    Text(opt.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.34), lineWidth: 0.7))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("把这个待办往后推 \(opt.label)")
            }
            Spacer(minLength: 0)
        }
    }

    private var snoozeOptions: [(label: String, minutes: Int)] {
        [("+1 小时", 60), ("+3 小时", 180), ("+1 天", 1440), ("+3 天", 4320), ("+1 周", 10080)]
    }

    private var metaText: String {
        var parts: [String] = []
        if !item.attendees.isEmpty {
            parts.append(item.attendees.prefix(3).joined(separator: "、"))
        }
        if !item.place.isEmpty { parts.append(item.place) }
        return parts.joined(separator: " · ")
    }

    private func start() {
        withAnimation(.spring(response: 0.58, dampingFraction: 0.72)) { appear = true }
        bellSwing = true
        ringPhase = true
        withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) { glow = true }
        withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) { breathing = true }
        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { sweep = true }
        withAnimation(.linear(duration: 5.2).repeatForever(autoreverses: false)) { spin = true }
        withAnimation(.easeInOut(duration: 7.5).repeatForever(autoreverses: true)) { drift = true }
        withAnimation(.linear(duration: duration)) { progress = 0 }
    }
}
