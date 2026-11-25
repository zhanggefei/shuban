//
//  RichText.swift
//  书办（ShuBan）· 记事本正文的富文本层
//
//  为什么单开一个文件：格式这件事「坏了不报错」—— 只是看起来不对，或者存回去再打开
//  就变了形。所以这里只放能被离屏断言的东西：属性怎么算、粘贴进来的东西怎么洗、
//  RTF 怎么存取、纯文本投影怎么取。界面只管调，不自己拼属性。
//
//  几条刻意的规矩（别再「顺手优化」掉）：
//  · 字号只走阶梯（11 / 12.5 / 14 / 17 / 21 / 26），不许出现 13.7 这种值。
//    粘贴进来的网页正文常常带 22.5pt，进一次就乱一次，台阶是最好的收敛方式。
//  · 颜色只认四档（墨/红/金/灰）+ 一档高亮。记事本是写字的地方，不是调色板。
//  · 粘贴一律过 `launder`：丢掉字体家族、图片附件、深色主题带进来的白字和白底。
//    不洗的话从网页/微信粘一段过来，正文会出现一块块读不清的白字。
//  · `body`（纯文本投影）永远跟着富文本一起更新 —— 搜索、字数、老数据兼容都指着它。
//

import AppKit

// MARK: - 格式操作

/// 工具栏与「格式」菜单共用的一套动作。名字短，是为了在断言里好写。
enum RichOp: String, CaseIterable, Hashable {
    case bold, italic, underline, strike
    case bigger, smaller
    case bullet
    case clear
}

/// 四档文字色 + 一档高亮。都是 sRGB，和 Theme 里那套红金宣纸对齐。
enum RichPalette {
    static let ink = NSColor(srgbRed: 0.11, green: 0.13, blue: 0.17, alpha: 1)
    static let red = NSColor(srgbRed: 0.871, green: 0.161, blue: 0.063, alpha: 1)
    static let gold = NSColor(srgbRed: 0.663, green: 0.427, blue: 0.098, alpha: 1)
    static let gray = NSColor(srgbRed: 0.42, green: 0.45, blue: 0.50, alpha: 1)
    static let highlight = NSColor(srgbRed: 1.0, green: 0.894, blue: 0.549, alpha: 1)

    /// 供界面画色块用（顺序即工具栏里的顺序）
    static let textColors: [(name: String, color: NSColor)] = [
        ("墨", ink), ("红", red), ("金", gold), ("灰", gray),
    ]
}

// MARK: - 纯逻辑

enum RichText {
    /// 正文字号阶梯。base 是「正文」，粘贴进来的字号一律吸附到最近的一档。
    static let ladder: [CGFloat] = [11, 12.5, 14, 17, 21, 26]
    static let baseSize: CGFloat = 14

    // MARK: 字体

    static func font(size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        var f = bold ? NSFont.systemFont(ofSize: size, weight: .bold) : NSFont.systemFont(ofSize: size)
        if italic {
            let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic))
            if let it = NSFont(descriptor: d, size: size) { f = it }
        }
        return f
    }

    static func isBold(_ f: NSFont) -> Bool {
        NSFontManager.shared.traits(of: f).contains(.boldFontMask)
            || NSFontManager.shared.weight(of: f) >= 8
    }

    static func isItalic(_ f: NSFont) -> Bool {
        NSFontManager.shared.traits(of: f).contains(.italicFontMask)
    }

    /// 吸附到最近的一档。超出上下限就贴边（粘贴 40pt 的标题不会把正文撑爆）
    static func snap(_ size: CGFloat) -> CGFloat {
        ladder.min { abs($0 - size) < abs($1 - size) } ?? baseSize
    }

    static func bigger(_ size: CGFloat) -> CGFloat {
        ladder.first { $0 > size + 0.01 } ?? (ladder.last ?? baseSize)
    }

    static func smaller(_ size: CGFloat) -> CGFloat {
        ladder.last { $0 < size - 0.01 } ?? (ladder.first ?? baseSize)
    }

    // MARK: 段落

    /// `bullet` = 段落前的圆点；`src` 只借它的对齐方式，别的（行距、缩进）一律按我们的来。
    static func paragraphStyle(_ src: NSParagraphStyle? = nil, bullet: Bool = false) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 3
        ps.paragraphSpacing = 5
        ps.alignment = src?.alignment ?? .natural
        if bullet {
            ps.textLists = [NSTextList(markerFormat: .disc, options: 0)]
            ps.firstLineHeadIndent = 4
            ps.headIndent = 21
        }
        return ps
    }

    static func hasBullet(_ ps: NSParagraphStyle?) -> Bool {
        !(ps?.textLists.isEmpty ?? true)
    }

    // MARK: 颜色

    /// 「太浅」= 三个通道都接近满值（白、浅灰）。深色主题网页的正文就是这种，
    /// 搬到宣纸底上等于看不见，一律归墨色。
    ///
    /// ⚠️ 别用 `brightnessComponent` 判：那是 HSB 里的 max(r,g,b)，正红
    /// (0.88, 0.16, 0.06) 的 brightness 是 **0.88** —— 会把正红当成白字一起洗掉。
    /// 这个坑踩过一次（用例现在钉着那一条）。
    static func isTooLight(_ c: NSColor) -> Bool {
        min(c.redComponent, c.greenComponent, c.blueComponent) > 0.86
    }

    /// 四档里最近的那个：界面只给四档，粘进来的杂色也归到这四档，
    /// 免得正文变成一张调色板（红色、金色是书办的强调色，留给人自己选）。
    static func nearestColor(_ c: NSColor?) -> NSColor {
        guard let c = c?.usingColorSpace(.sRGB) else { return RichPalette.ink }
        if isTooLight(c) { return RichPalette.ink }
        var best = RichPalette.ink
        var bestD = CGFloat.greatestFiniteMagnitude
        for (_, p) in RichPalette.textColors {
            let q = p.usingColorSpace(.sRGB) ?? p
            let d = pow(q.redComponent - c.redComponent, 2)
                + pow(q.greenComponent - c.greenComponent, 2)
                + pow(q.blueComponent - c.blueComponent, 2)
            if d < bestD { bestD = d; best = q }
        }
        return best
    }

    static func isHighlight(_ c: NSColor?) -> Bool {
        guard let c = c?.usingColorSpace(.sRGB), let h = RichPalette.highlight.usingColorSpace(.sRGB) else { return false }
        return abs(c.redComponent - h.redComponent) < 0.06
            && abs(c.greenComponent - h.greenComponent) < 0.06
            && abs(c.blueComponent - h.blueComponent) < 0.06
    }

    // MARK: 基础属性 / 单段属性变换

    static func baseAttributes(size: CGFloat = baseSize, bullet: Bool = false) -> [NSAttributedString.Key: Any] {
        [.font: font(size: size, bold: false, italic: false),
         .foregroundColor: RichPalette.ink,
         .paragraphStyle: paragraphStyle(nil, bullet: bullet)]
    }

    /// 把一次格式操作套到「一段属性」上，返回新的一段属性。
    /// 只改自己的键，不认识的键（比如别人写进来的 kern）一律丢掉 —— 保留它们只会
    /// 让同一篇笔记里的排版越来越不一致。
    static func style(_ op: RichOp, onto attrs: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        let f = attrs[.font] as? NSFont
        let size = snap(f?.pointSize ?? baseSize)
        var bold = f.map(isBold) ?? false
        var italic = f.map(isItalic) ?? false
        var underline = (attrs[.underlineStyle] as? Int ?? 0) != 0
        var strike = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
        var textColor = nearestColor(attrs[.foregroundColor] as? NSColor)
        var bg: NSColor? = isHighlight(attrs[.backgroundColor] as? NSColor) ? RichPalette.highlight : nil
        var newSize = size
        let ps = attrs[.paragraphStyle] as? NSParagraphStyle
        var bullet = hasBullet(ps)

        switch op {
        case .bold: bold.toggle()
        case .italic: italic.toggle()
        case .underline: underline.toggle()
        case .strike: strike.toggle()
        case .bigger: newSize = bigger(size)
        case .smaller: newSize = smaller(size)
        case .bullet: bullet.toggle()
        case .clear:
            // 清除格式保留段落列表与对齐：清了「格式」还把人家排好的列表拆掉，手会很痛
            bold = false; italic = false; underline = false; strike = false
            newSize = baseSize; textColor = RichPalette.ink
            bg = nil
        }

        var out: [NSAttributedString.Key: Any] = [
            .font: font(size: newSize, bold: bold, italic: italic),
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle(ps, bullet: bullet),
        ]
        if underline { out[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if strike { out[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let bg { out[.backgroundColor] = bg }
        return out
    }

    // MARK: 粘贴洗白

    /// 把外来的富文本洗成记事本能用的样子。逐段重建，不认识的东西直接丢。
    static func launder(_ src: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let whole = NSRange(location: 0, length: src.length)
        src.enumerateAttributes(in: whole, options: []) { attrs, r, _ in
            // 图片附件不算正文：记事本的图走下面那条图片条，塞进正文会拖垮落盘
            if attrs[.attachment] != nil { return }
            let text = src.attributedSubstring(from: r).string
            if text.isEmpty { return }
            let f = attrs[.font] as? NSFont
            let ps = attrs[.paragraphStyle] as? NSParagraphStyle
            var a: [NSAttributedString.Key: Any] = [
                .font: font(size: snap(f?.pointSize ?? baseSize),
                            bold: f.map(isBold) ?? false,
                            italic: f.map(isItalic) ?? false),
                .foregroundColor: nearestColor(attrs[.foregroundColor] as? NSColor),
                .paragraphStyle: paragraphStyle(ps, bullet: hasBullet(ps)),
            ]
            if (attrs[.underlineStyle] as? Int ?? 0) != 0 {
                a[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 {
                a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if isHighlight(attrs[.backgroundColor] as? NSColor) { a[.backgroundColor] = RichPalette.highlight }
            out.append(NSAttributedString(string: text, attributes: a))
        }
        return out
    }

    /// 老笔记（只有纯文本）→ 富文本。所有段落按基础属性走。
    static func attributed(fromPlain text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: baseAttributes())
    }

    // MARK: RTF 存取

    static func rtfData(_ s: NSAttributedString) -> Data? {
        guard s.length > 0 else { return nil }
        return try? s.data(from: NSRange(location: 0, length: s.length),
                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    static func attributed(fromRTF data: Data) -> NSAttributedString? {
        guard let s = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else { return nil }
        // RTF 往返一趟也要洗：不然存档里混进什么，下次打开就显示什么
        return launder(s)
    }

    // MARK: 在编辑器上执行

    /// 选区上有内容就改选区，没有选区就改「接下来打的字」（typingAttributes）——
    /// 后者是写作者最常用的路径：按 ⌘B 再打字，谁也不会先选中一段。
    @discardableResult
    static func apply(_ op: RichOp, to tv: NSTextView) -> Bool {
        let sel = tv.selectedRange()
        if sel.length == 0 {
            tv.typingAttributes = style(op, onto: tv.typingAttributes)
            return true
        }
        return replace(tv, range: sel) { sub in
            let out = NSMutableAttributedString(attributedString: sub)
            var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
            out.enumerateAttributes(in: NSRange(location: 0, length: out.length), options: []) { attrs, r, _ in
                runs.append((r, style(op, onto: attrs)))
            }
            for (r, a) in runs { out.setAttributes(a, range: r) }
            return out
        }
    }

    /// 换文字色。没选区时同样只改 typingAttributes。
    @discardableResult
    static func applyColor(_ color: NSColor, to tv: NSTextView) -> Bool {
        let c = nearestColor(color)
        let sel = tv.selectedRange()
        if sel.length == 0 {
            var a = tv.typingAttributes
            a[.foregroundColor] = c
            tv.typingAttributes = a
            return true
        }
        return replace(tv, range: sel) { sub in
            let out = NSMutableAttributedString(attributedString: sub)
            out.addAttribute(.foregroundColor, value: c, range: NSRange(location: 0, length: out.length))
            return out
        }
    }

    /// 高亮底色开关：整块已经全是高亮就取消，否则整块刷上。
    @discardableResult
    static func toggleHighlight(to tv: NSTextView) -> Bool {
        let sel = tv.selectedRange()
        if sel.length == 0 {
            var a = tv.typingAttributes
            if isHighlight(a[.backgroundColor] as? NSColor) { a.removeValue(forKey: .backgroundColor) } else {
                a[.backgroundColor] = RichPalette.highlight
            }
            tv.typingAttributes = a
            return true
        }
        let allOn = (tv.textStorage?.attributedSubstring(from: sel).attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor)
            .map(isHighlight) ?? false
        return replace(tv, range: sel) { sub in
            let out = NSMutableAttributedString(attributedString: sub)
            let r = NSRange(location: 0, length: out.length)
            if allOn { out.removeAttribute(.backgroundColor, range: r) } else {
                out.addAttribute(.backgroundColor, value: RichPalette.highlight, range: r)
            }
            return out
        }
    }

    /// 把一段（已经洗过的）富文本插到光标处。
    ///
    /// ⚠️ 别改用 `insertText(_:replacementRange:)`：它会把插入内容的字体换成
    /// `typingAttributes` —— 实测 26pt 的洗白结果进正文变成 14pt，`WECAL_RICH_TEST`
    /// 里「粘外来富文本」那条当场红（查了这一轮才发现）。走 replace 这条路，
    /// 和格式操作同一套：⌘Z 撤得回、字数与落盘也会跟上。
    static func insert(_ s: NSAttributedString, into tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let r = tv.selectedRange()
        guard tv.shouldChangeText(in: r, replacementString: s.string) else { return }
        storage.replaceCharacters(in: r, with: s)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: r.location + s.length, length: 0))
    }

    /// 统一走 shouldChangeText → replace → didChangeText，这样 ⌘Z 能撤、字数与落盘会跟上。
    private static func replace(_ tv: NSTextView, range: NSRange,
                                _ build: (NSAttributedString) -> NSAttributedString) -> Bool {
        guard let storage = tv.textStorage else { return false }
        let sub = storage.attributedSubstring(from: range)
        let out = build(sub)
        guard tv.shouldChangeText(in: range, replacementString: out.string) else { return false }
        storage.replaceCharacters(in: range, with: out)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location, length: range.length))
        return true
    }

    // MARK: 查询（工具栏高亮态）

    static func attributes(at tv: NSTextView) -> [NSAttributedString.Key: Any] {
        let sel = tv.selectedRange()
        if sel.length == 0 { return tv.typingAttributes }
        guard let storage = tv.textStorage, storage.length > 0 else { return baseAttributes() }
        let at = min(sel.location, storage.length - 1)
        return storage.attributes(at: at, effectiveRange: nil)
    }

    static func activeOps(at tv: NSTextView) -> Set<RichOp> {
        let a = attributes(at: tv)
        let f = a[.font] as? NSFont
        var out: Set<RichOp> = []
        if f.map(isBold) ?? false { out.insert(.bold) }
        if f.map(isItalic) ?? false { out.insert(.italic) }
        if (a[.underlineStyle] as? Int ?? 0) != 0 { out.insert(.underline) }
        if (a[.strikethroughStyle] as? Int ?? 0) != 0 { out.insert(.strike) }
        if hasBullet(a[.paragraphStyle] as? NSParagraphStyle) { out.insert(.bullet) }
        return out
    }

    static func size(at tv: NSTextView) -> CGFloat {
        snap((attributes(at: tv)[.font] as? NSFont)?.pointSize ?? baseSize)
    }

    static func color(at tv: NSTextView) -> NSColor {
        nearestColor(attributes(at: tv)[.foregroundColor] as? NSColor)
    }
}

// MARK: - 工具栏 ↔ 编辑器 的桥

/// SwiftUI 的工具条按钮和 AppKit 的文本视图之间需要一根线：按钮不知道当前是哪个
/// NSTextView、光标在哪、选了什么。编辑器把自己挂上来，按钮通过它执行动作，
/// 执行完再把「当前状态」拉一遍给按钮画高亮。
@MainActor
final class RichEditorBridge: ObservableObject {
    weak var textView: NSTextView?
    /// 工具栏上该显示成「按下去」的那些
    @Published private(set) var active: Set<RichOp> = []
    @Published private(set) var size: CGFloat = RichText.baseSize
    @Published private(set) var color: NSColor = RichPalette.ink
    @Published private(set) var highlighted = false

    func attach(_ tv: NSTextView) {
        textView = tv
        refresh()
    }

    /// 把当前状态拉一遍给工具条画高亮。
    ///
    /// ⚠️ 每一项都要**先比再赋值**。`@Published` 只要赋值就发通知（哪怕值一模一样），
    /// 通知会让 SwiftUI 重跑一遍视图、进而走到 `updateNSView`；而选择变化本身就会被
    /// 文本视图反复通报（回写内容、点一下、挪个光标）。无脑赋值 = 白添一轮更新，
    /// 和回写凑在一起就是 100% CPU 的死循环（2026-11-25 踩过，`shouldPush` 那边是前半段）。
    func refresh() {
        guard let tv = textView else { return }
        let a = RichText.attributes(at: tv)
        let newActive = RichText.activeOps(at: tv)
        let newSize = RichText.size(at: tv)
        let newColor = RichText.color(at: tv)
        let newHighlighted = RichText.isHighlight(a[.backgroundColor] as? NSColor)
        if newActive != active { active = newActive }
        if newSize != size { size = newSize }
        if newColor != color { color = newColor }
        if newHighlighted != highlighted { highlighted = newHighlighted }
    }

    func apply(_ op: RichOp) {
        guard let tv = textView else { return }
        RichText.apply(op, to: tv)
        refresh()
    }

    func setColor(_ c: NSColor) {
        guard let tv = textView else { return }
        RichText.applyColor(c, to: tv)
        refresh()
    }

    func toggleHighlight() {
        guard let tv = textView else { return }
        RichText.toggleHighlight(to: tv)
        refresh()
    }
}
