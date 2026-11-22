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

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .record: return "录屏"
        case .notes:  return "记事本"
        }
    }

    /// 只在「功能」菜单里出现的一行说明：一眼看清进去能干什么，比光一个词强
    var blurb: String {
        switch self {
        case .record: return "主屏 / 选区 / 副屏，带麦克风与点击高亮"
        case .notes:  return "自己的目录树，正文可贴图"
        }
    }

    var icon: String {
        switch self {
        case .record: return "record.circle"
        case .notes:  return "square.and.pencil"
        }
    }

    var defaultSize: NSSize {
        switch self {
        // 录屏内容是一列竖排的设置卡，窄而高最合适
        case .record: return NSSize(width: 420, height: 640)
        // 记事本要横向铺开：左边树、右边正文，384 的家底装不下
        case .notes:  return NSSize(width: 780, height: 640)
        }
    }

    var minSize: NSSize {
        switch self {
        case .record: return NSSize(width: 380, height: 480)
        case .notes:  return NSSize(width: 620, height: 440)
        }
    }

    var maxSize: NSSize {
        switch self {
        case .record: return NSSize(width: 620, height: 1000)
        case .notes:  return NSSize(width: 1200, height: 1000)
        }
    }

    /// 各存各的位置，互不影响。主面板仍是 wecal.frame
    var frameKey: String {
        switch self {
        case .record: return "wecal.frame.record"
        case .notes:  return "wecal.frame.notes"
        }
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
