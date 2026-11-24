//
//  FeatureWindow.swift
//  书办（ShuBan）· 子功能的独立窗口
//
//  2026-11-22 重构：录屏和记事本原来都是「主面板的一个态」（store.mode = 1 / 2），
//  共用同一个 384 宽、520 高的窗口，靠底栏两颗胶囊换页。问题是这两件事对版式的
//  要求完全不一样：录屏是一列竖着的高级设置，记事本要一个横向的树 + 正文。
//  挤在同一个壳里，谁也没法按自己的意思长 —— 记事本的树只能压到 142pt 宽，
//  录屏为了塞进窄屏把说明文字写得极短。
//
//  所以拆成独立窗口：各自定尺寸、各自记住位置、各自适应布局。主面板只管日历和待办，
//  底栏不再需要换页胶囊，入口收到顶部那颗「功能」里。
//

import SwiftUI
import AppKit

/// 书办的子功能。每个都是独立窗口，不再挤在主面板里换页。
enum FeaturePane: Int, CaseIterable, Identifiable {
    case record = 1
    case notes = 2
    case audio = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .record: return "录屏"
        case .notes:  return "记事本"
        case .audio:  return "听录"
        }
    }

    /// 只在「功能」菜单里出现的一行说明：一眼看清进去能干什么，比光一个词强
    var blurb: String {
        switch self {
        case .record: return "主屏 / 选区 / 副屏，带麦克风与点击高亮"
        case .notes:  return "自己的目录树，正文可贴图"
        case .audio:  return "现录一段，或把 WMA 拖进来听"
        }
    }

    var icon: String {
        switch self {
        case .record: return "record.circle"
        case .notes:  return "square.and.pencil"
        case .audio:  return "headphones"
        }
    }

    var defaultSize: NSSize {
        switch self {
        // 录屏是横着铺的桌面工具窗：左右两栏（设置 / 记录），主按钮沉在右下角
        case .record: return NSSize(width: 620, height: 690)
        // 记事本要横向铺开：左边树、右边正文，384 的家底装不下
        case .notes:  return NSSize(width: 780, height: 640)
        // 听录：左曲目列表 + 右正在播放，底下通一条传输栏
        case .audio:  return NSSize(width: 720, height: 620)
        }
    }

    var minSize: NSSize {
        switch self {
        // 再窄「录制范围 | 选项」两栏就挤了：倒计时胶囊会折行、选项说明全被截断
        case .record: return NSSize(width: 600, height: 520)
        case .notes:  return NSSize(width: 620, height: 440)
        // 再窄「曲目 | 正在播放」就叠一块了，音量条也会被挤没
        case .audio:  return NSSize(width: 620, height: 520)
        }
    }

    var maxSize: NSSize {
        switch self {
        case .record: return NSSize(width: 900, height: 1000)
        case .notes:  return NSSize(width: 1200, height: 1000)
        case .audio:  return NSSize(width: 1100, height: 1000)
        }
    }

    /// 各存各的位置，互不影响。主面板仍是 wecal.frame
    var frameKey: String {
        switch self {
        case .record: return "wecal.frame.record"
        case .notes:  return "wecal.frame.notes"
        case .audio:  return "wecal.frame.audio"
        }
    }

    /// 窗口内部识别名（标题栏是隐的，不进存档）。和 frameKey 分开是因为
    /// 存档键当年已经写进用户默认值了，改名等于丢位置
    var panelName: String {
        switch self {
        case .record: return "record"
        case .notes:  return "notes"
        case .audio:  return "audio"
        }
    }

    /// 这一扇窗此刻是不是摊在屏幕上。
    ///
    /// 子窗里的「对盘」轮询都得拿它挡一道：关窗只是 orderOut，SwiftUI 的 onDisappear
    /// 不一定来，不挡的话一条 2 秒的定时器会在后台空转到天荒地老。
    /// 靠窗口 identifier 认人（= 存档键，makePanel 里挂的）—— 不能拿标题认，
    /// 标题是自由字符串，改起来没约束。
    var isOpen: Bool {
        let id = NSUserInterfaceItemIdentifier(frameKey)
        return NSApp.windows.contains { $0.identifier == id && $0.isVisible }
    }
}

// MARK: - 关闭动作

/// 子功能窗口里那颗「关闭」按钮要关的是自己这个窗口，而同一个 Store 被三个窗口共享，
/// 所以不能挂在 Store 上，走环境值按窗口下发。
private struct CloseFeatureKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var closeFeaturePane: () -> Void {
        get { self[CloseFeatureKey.self] }
        set { self[CloseFeatureKey.self] = newValue }
    }
}

// MARK: - 窗口外壳

/// 子功能窗口那块底。
///
/// 窗口本身是透明的（`backgroundColor = .clear` + `isOpaque = false`，为了让圆角外面
/// 不出现一圈灰底）。代价是 **SwiftUI 没画到的地方会直接透出桌面**：录屏窗和记事本窗的
/// 根视图本来就是一堆卡片，卡片之间、滚动区底下、两栏之间的缝都没人铺底 —— 实测录屏窗
/// 33.6%、记事本窗 98.1% 的像素是透明的，等于直接看壁纸。
///
/// 这层壳负责把整块底铺满（宣纸白 + 顶部一点提亮），再切圆角、描一圈白边，
/// 质感和日历窗对齐。**别指望子面板自己画背景**：它们换来换去都是卡片，
/// 谁也不会记得铺底，一漏就是一片透。
struct FeatureShell<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                ZStack {
                    // 不透明的一层打底，上面才是渐变 —— 光渐变不够，0.9 的白还是有透明
                    Theme.cream
                    LinearGradient(colors: [Color.white.opacity(0.95), Color.white.opacity(0.30)],
                                   startPoint: .top, endPoint: .bottom)
                }
            )
            // 标题栏是透明的，SwiftUI 默认把标题栏那 28pt 当安全区留白，
            // 不铺满的话顶部会漏一条桌面壁纸出来
            .ignoresSafeArea(.all)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.85), lineWidth: 1)
            )
    }
}
