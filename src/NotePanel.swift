//
//  NotePanel.swift
//  书办（ShuBan）· 记事本面板
//
//  形态上：独立窗口（2026-11-22 重构），默认 780×640 —— 树和正文都要宽度，
//  384 的主面板装不下。从主面板顶部的「功能」菜单进来，左上角 ✕ 关掉。
//  视觉沿用书办那套：宣纸暖白、中国红、金线、印章，字号尺寸统一走 Fnt/S。
//
//  版式：左边一条窄的树（142pt 基准宽 × 1.25 档），右边是编辑区。
//  为什么不做成「列表 → 点进去 → 返回」的两级：树一直可见，换条目只要点一下，
//  比来回翻页顺手；独立窗口之后横向空间够，更没必要分两级。
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 这一页自己的字号与尺寸档

/// 记事本窗口是独立窗口（默认 780×640），比主面板宽得多，所以不能跟着主面板的
/// 全局缩放档走 —— 那个档位按 384 宽算，套到 780 宽上字会大得离谱。
/// 这里钉一个固定档：树 142×1.25≈178，正文吃剩下的宽度。
private let panelZoom: CGFloat = 1.25

@inline(__always)
private func PZ(_ v: CGFloat) -> CGFloat { v * panelZoom }

private func PF(_ size: CGFloat,
                _ weight: Font.Weight = .regular,
                _ design: Font.Design = .default) -> Font {
    .system(size: (size * panelZoom * 2).rounded() / 2, weight: weight, design: design)
}

struct NotePanel: View {
    @Environment(\.closeFeaturePane) private var closePane
    @EnvironmentObject var notes: NoteStore

    /// 编辑区草稿。不直接绑 store 里的字段：每敲一个字都写 @Published 会让整棵树重排，
    /// 光标还容易跳。这里先攒着，停手 0.5 秒再回写。
    @State private var draftTitle = ""
    /// 正文（带格式）。`draftBody` 只是它的纯文本投影，用来数字数、做回写时的兜底
    @State private var draftRich = RichText.attributed(fromPlain: "")
    @State private var draftBody = ""
    /// 草稿属于哪个节点。切选中前必须靠它把字存回原来那条，否则刚打的就丢了
    @State private var draftFor: String?
    /// 正在用 loadDraft 灌值：这期间的 onChange 不算用户输入
    @State private var loading = false
    @State private var saveTask: Task<Void, Never>?
    /// 格式工具条 ↔ 文本视图的那根线（按钮要知道当前光标上是什么格式）
    @StateObject private var rich = RichEditorBridge()

    @State private var renaming: String?
    @State private var renameText = ""
    @State private var pendingDelete: NoteNode?

    var body: some View {
        VStack(spacing: 0) {
            header
            ribbonDivider
            HStack(spacing: 0) {
                treeColumn
                    .frame(width: PZ(142))
                Rectangle()
                    .fill(Theme.sched.opacity(0.10))
                    .frame(width: 0.8)
                editorColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            footer
        }
        .overlay(preview)
        .onAppear { loadDraft() }
        .onChange(of: notes.selected) { _ in
            commit(true)
            loadDraft()
        }
        .onDisappear { commit(true) }
        .alert("删除这一项？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let n = pendingDelete {
                    commit(true)
                    notes.remove(n.id)
                    if draftFor == n.id {
                        draftFor = nil
                        draftTitle = ""
                        draftBody = ""
                        draftRich = RichText.attributed(fromPlain: "")
                    }
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteMessage: String {
        guard let n = pendingDelete else { return "" }
        if n.folder {
            let sub = notes.subtree(n.id).count - 1
            return sub > 0
                ? "「\(n.title)」里面还有 \(sub) 项，会一起删掉，不能撤销。"
                : "「\(n.title)」是个空文件夹，删掉不能撤销。"
        }
        return "「\(n.title)」会连同 \(n.images.count) 张图一起删掉，不能撤销。"
    }

    // MARK: - 头部

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
                .help("关闭记事本窗口")

                ZStack {
                    RoundedRectangle(cornerRadius: PZ(8), style: .continuous)
                        .fill(Theme.redGradient)
                        .frame(width: PZ(29), height: PZ(29))
                        .shadow(color: Theme.redDeep.opacity(0.45), radius: PZ(3), y: PZ(1.5))
                    RoundedRectangle(cornerRadius: PZ(8), style: .continuous)
                        .strokeBorder(Theme.todo.opacity(0.75), lineWidth: 0.9)
                        .frame(width: PZ(26), height: PZ(26))
                    Text("记")
                        .font(PF(15, .bold, .serif))
                        .foregroundColor(.white)
                        .offset(y: PZ(-0.5))
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("记 事 本").font(PF(21, .heavy, .rounded)).foregroundColor(Theme.sched)
                        Text("书办子功能")
                            .font(PF(8.5, .semibold, .rounded))
                            .foregroundColor(Theme.goldDeep)
                            .padding(.horizontal, PZ(4))
                            .padding(.vertical, PZ(1))
                            .background(Capsule().fill(Theme.todo.opacity(0.18)))
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "list.bullet.indent")
                            .font(PF(8.5, .semibold))
                            .foregroundColor(Theme.sched.opacity(0.75))
                        Text("\(notes.noteCount) 篇 · 树形目录 · 可贴图")
                            .font(PF(10)).foregroundColor(Theme.inkSoft).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                newNoteButton
                newFolderButton
            }
            .padding(.horizontal, PZ(13))
            .padding(.top, PZ(8))
            .padding(.bottom, PZ(7))
        }
    }

    private var newNoteButton: some View {
        Button { notes.add(folder: false) } label: {
            Image(systemName: "square.and.pencil")
                .font(PF(11, .semibold))
                .foregroundColor(.white)
                .frame(width: PZ(24), height: PZ(24))
                .background(RoundedRectangle(cornerRadius: PZ(7), style: .continuous).fill(Theme.redGradient))
                .overlay(RoundedRectangle(cornerRadius: PZ(7), style: .continuous)
                    .stroke(Theme.todo.opacity(0.5), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .help("新建笔记（建在当前选中的那一层里）")
    }

    private var newFolderButton: some View {
        Button { notes.add(folder: true) } label: {
            Image(systemName: "folder.badge.plus")
                .font(PF(11, .semibold))
                .foregroundColor(Theme.sched)
                .frame(width: PZ(24), height: PZ(24))
                .background(RoundedRectangle(cornerRadius: PZ(7), style: .continuous).fill(Theme.sched.opacity(0.09)))
                .overlay(RoundedRectangle(cornerRadius: PZ(7), style: .continuous)
                    .stroke(Theme.sched.opacity(0.25), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .help("新建文件夹")
    }

    private var ribbonDivider: some View {
        Theme.ribbon.frame(height: PZ(1.2)).opacity(0.55).padding(.horizontal, PZ(12))
    }

    // MARK: - 左边的树

    private struct TreeRow: Identifiable {
        let node: NoteNode
        let depth: Int
        var id: String { node.id }
    }

    private var rows: [TreeRow] {
        var out: [TreeRow] = []
        func walk(_ parent: String?, _ d: Int) {
            guard d <= NoteStore.maxDepth + 1 else { return }
            for n in notes.children(parent) {
                out.append(TreeRow(node: n, depth: d))
                if n.folder && notes.expanded.contains(n.id) { walk(n.id, d + 1) }
            }
        }
        walk(nil, 0)
        return out
    }

    private var treeColumn: some View {
        VStack(spacing: 0) {
            searchRow
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if notes.keyword.isEmpty {
                        if rows.isEmpty { treeEmptyHint } else { ForEach(rows) { r in treeRow(r) } }
                    } else {
                        let hits = notes.searchRows()
                        if hits.isEmpty {
                            Text("没有匹配的笔记")
                                .font(PF(9.5)).foregroundColor(Theme.inkSoft)
                                .frame(maxWidth: .infinity).padding(.top, PZ(18))
                        } else {
                            ForEach(hits, id: \.node.id) { h in hitRow(h.node, h.path) }
                        }
                    }
                }
                .padding(.vertical, PZ(4))
            }
        }
        // 侧栏要比正文暗一档才看得出两栏的分界。以前这层是 cream 0.55、
        // 靠窗口透明透出桌面壁纸才显出层次；窗口铺了实底之后那个做法就只剩一片白
        .background(Color.black.opacity(0.045))
    }

    private var searchRow: some View {
        HStack(spacing: PZ(4)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: PZ(8.5), weight: .semibold))
                .foregroundColor(Theme.inkSoft.opacity(0.8))
            TextField("搜标题和正文", text: $notes.keyword)
                .textFieldStyle(.plain)
                .font(PF(9.5))
                .foregroundColor(Theme.ink)
            if !notes.keyword.isEmpty {
                Button { notes.keyword = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: PZ(9)))
                        .foregroundColor(Theme.inkSoft.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, PZ(6))
        .padding(.vertical, PZ(4))
        .background(RoundedRectangle(cornerRadius: PZ(6), style: .continuous).fill(Color.black.opacity(0.045)))
        .padding(.horizontal, PZ(6))
        .padding(.top, PZ(5))
        .padding(.bottom, PZ(3))
    }

    private var treeEmptyHint: some View {
        VStack(spacing: PZ(6)) {
            Text("还没有笔记")
                .font(PF(9.5)).foregroundColor(Theme.inkSoft)
            Text("点右上角 + 新建")
                .font(PF(8.5)).foregroundColor(Theme.inkSoft.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, PZ(20))
    }

    private func treeRow(_ r: TreeRow) -> some View {
        let n = r.node
        let on = notes.selected == n.id
        let kids = n.folder ? notes.children(n.id).count : 0
        return HStack(spacing: PZ(3)) {
            // 缩进用固定宽度占位，不用 padding —— 深一层就该真的往右挪一格
            Color.clear.frame(width: PZ(6) * CGFloat(r.depth), height: 1)
            if n.folder {
                Button { toggle(n.id) } label: {
                    Image(systemName: notes.expanded.contains(n.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: PZ(6), weight: .bold))
                        .foregroundColor(Theme.inkSoft.opacity(0.9))
                        .frame(width: PZ(10), height: PZ(12))
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: PZ(10), height: 1)
            }
            Image(systemName: n.folder ? "folder.fill" : "doc.text")
                .font(.system(size: PZ(8), weight: .medium))
                .foregroundColor(n.folder ? Theme.todo : Theme.sched.opacity(0.65))
            if renaming == n.id {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(PF(10, .semibold))
                    .foregroundColor(Theme.ink)
                    .onSubmit { commitRename(n.id) }
                    .onExitCommand { renaming = nil }
            } else {
                Text(n.title)
                    .font(PF(10, on ? .semibold : .regular))
                    .foregroundColor(on ? Theme.sched : Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if n.folder && kids > 0 {
                Text("\(kids)")
                    .font(PF(8, .semibold, .rounded))
                    .foregroundColor(on ? Theme.sched.opacity(0.8) : Theme.inkSoft.opacity(0.7))
            }
            if !n.folder && !n.images.isEmpty {
                Image(systemName: "photo")
                    .font(.system(size: PZ(7)))
                    .foregroundColor(Theme.todo.opacity(0.9))
            }
        }
        .padding(.horizontal, PZ(4))
        .frame(height: PZ(21))
        .background(on ? Theme.sched.opacity(0.10) : Color.clear)
        .overlay(alignment: .leading) {
            if on { Rectangle().fill(Theme.sched).frame(width: PZ(2)) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            notes.selected = n.id
            if n.folder { toggle(n.id) }
        }
        .contextMenu { menu(for: n) }
        .onDrag { NSItemProvider(object: n.id as NSString) }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first else { return false }
            let ns = notes
            let target = n.id
            Task { @MainActor in ns.dropItem(id, on: target) }
            return true
        }
    }

    /// 搜索结果行：带上「父 / 父」面包屑，否则一堆同名笔记分不清在哪
    private func hitRow(_ n: NoteNode, _ path: String) -> some View {
        let on = notes.selected == n.id
        return VStack(alignment: .leading, spacing: 0) {
            Text(n.title)
                .font(PF(9.5, .semibold))
                .foregroundColor(on ? Theme.sched : Theme.ink)
                .lineLimit(1)
            Text(path.isEmpty ? "顶层" : path)
                .font(PF(8))
                .foregroundColor(Theme.inkSoft.opacity(0.75))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PZ(6))
        .padding(.vertical, PZ(3))
        .background(on ? Theme.sched.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { notes.selected = n.id }
    }

    @ViewBuilder
    private func menu(for n: NoteNode) -> some View {
        if n.folder {
            Button("新建笔记") { notes.selected = n.id; notes.add(folder: false) }
            Button("新建子文件夹") { notes.selected = n.id; notes.add(folder: true) }
            Divider()
        }
        Button("重命名") { beginRename(n) }
        Button("上移") { notes.nudge(n.id, by: -1) }
        Button("下移") { notes.nudge(n.id, by: 1) }
        if n.parent != nil {
            Button("移到顶层") { notes.move(n.id, to: nil) }
        }
        Divider()
        Button("删除…") { pendingDelete = n }
    }

    private func toggle(_ id: String) {
        notes.toggleExpand(id)
    }

    private func beginRename(_ n: NoteNode) {
        renaming = n.id
        renameText = n.title
    }

    private func commitRename(_ id: String) {
        notes.rename(id, to: renameText)
        renaming = nil
        if draftFor == id { draftTitle = notes.node(id)?.title ?? draftTitle }
    }

    // MARK: - 右边编辑区

    @ViewBuilder
    private var editorColumn: some View {
        if let n = notes.selectedNode {
            if n.folder { folderView(n) } else { noteEditor(n) }
        } else {
            emptyEditor
        }
    }

    private var emptyEditor: some View {
        VStack(spacing: PZ(8)) {
            ZStack {
                Circle().fill(Theme.sched.opacity(0.07)).frame(width: PZ(46), height: PZ(46))
                Image(systemName: "square.and.pencil")
                    .font(PF(18, .light))
                    .foregroundColor(Theme.sched.opacity(0.55))
            }
            Text("左边选一条，或者点右上角 + 新建")
                .font(PF(9.5)).foregroundColor(Theme.inkSoft)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func folderView(_ n: NoteNode) -> some View {
        let kids = notes.children(n.id)
        return VStack(spacing: PZ(9)) {
            ZStack {
                RoundedRectangle(cornerRadius: PZ(14), style: .continuous)
                    .fill(Theme.todo.opacity(0.14))
                    .frame(width: PZ(52), height: PZ(52))
                Image(systemName: "folder.fill")
                    .font(PF(22))
                    .foregroundColor(Theme.todo)
            }
            Text(n.title)
                .font(PF(13, .bold))
                .foregroundColor(Theme.ink)
                .multilineTextAlignment(.center)
            Text("\(kids.count) 项 · 里面 \(kids.filter { !$0.folder }.count) 篇笔记")
                .font(PF(9)).foregroundColor(Theme.inkSoft)
            HStack(spacing: PZ(6)) {
                ghost("新建笔记", "square.and.pencil", solid: true) {
                    notes.selected = n.id
                    notes.add(folder: false)
                }
                ghost("新建子文件夹", "folder.badge.plus") {
                    notes.selected = n.id
                    notes.add(folder: true)
                }
            }
            .padding(.top, PZ(2))
            HStack(spacing: PZ(6)) {
                ghost("重命名", "pencil") { beginRename(n) }
                ghost("删除", "trash") { pendingDelete = n }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(PZ(12))
    }

    private func noteEditor(_ n: NoteNode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("无标题", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(PF(13.5, .bold))
                .foregroundColor(Theme.ink)
                .padding(.horizontal, PZ(12))
                .padding(.top, PZ(8))
                .onSubmit { commit(true) }

            HStack(spacing: PZ(5)) {
                Text("\(draftBody.count) 字")
                Text("·")
                Text("改于 \(RelativeDate.text(Date(timeIntervalSince1970: n.updatedAt)))")
                Spacer(minLength: 0)
            }
            .font(PF(8.5))
            .foregroundColor(Theme.inkSoft.opacity(0.9))
            .padding(.horizontal, PZ(12))
            .padding(.top, PZ(2))

            // 红金细线：和日历那边「表头 / 内容」的分隔保持同一语言
            Theme.ribbon
                .frame(height: PZ(1))
                .opacity(0.5)
                .padding(.horizontal, PZ(12))
                .padding(.top, PZ(6))

            formatBar

            RichEditor(noteID: n.id, text: draftRich, bridge: rich) { attr in
                draftRich = attr
                draftBody = attr.string
                commit(false)
            }
            .padding(.horizontal, PZ(8))
            .padding(.vertical, PZ(4))
            .frame(maxHeight: .infinity)

            if !n.images.isEmpty { imageStrip(n) }
            editorToolbar(n)
        }
        .onChange(of: draftTitle) { _ in commit(false) }
    }

    /// 正文上方那一条格式栏。
    /// 为什么放「上方」而不是沉底：写字的人是先选格式再打字，跟眼下这条工具条——
    /// 贴图和删除——的使用时机不一样，混在一排会互相干扰。
    private var formatBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PZ(3)) {
                formatButton(.bold, "B", font: PF(11.5, .bold, .serif), tip: "粗体 ⌘B")
                formatButton(.italic, "I", font: PF(11.5, .regular, .serif).italic(), tip: "斜体 ⌘I")
                formatButton(.underline, "U", font: PF(11.5, .regular), tip: "下划线 ⌘U", underline: true)
                formatButton(.strike, "S", font: PF(11.5, .regular), tip: "删除线 ⇧⌘X", strike: true)

                barDivider

                stepButton("textformat.size.smaller", "小一点") { rich.apply(.smaller) }
                Text("\(Int(rich.size))")
                    .font(PF(9, .semibold, .rounded))
                    .foregroundColor(Theme.inkSoft)
                    .frame(minWidth: PZ(15))
                stepButton("textformat.size.larger", "大一点") { rich.apply(.bigger) }

                barDivider

                ForEach(RichPalette.textColors, id: \.name) { item in
                    Button { rich.setColor(item.color) } label: {
                        Circle()
                            .fill(Color(nsColor: item.color))
                            .frame(width: PZ(10), height: PZ(10))
                            .overlay(
                                Circle().stroke(Theme.ink.opacity(isSameColor(item.color) ? 0.55 : 0.12),
                                                lineWidth: isSameColor(item.color) ? 1.4 : 0.7)
                            )
                            .frame(width: PZ(15), height: PZ(15))
                    }
                    .buttonStyle(.plain)
                    .help("\(item.name)色")
                }

                Button { rich.toggleHighlight() } label: {
                    Image(systemName: "highlighter")
                        .font(PF(9, .semibold))
                        .foregroundColor(rich.highlighted ? Theme.sched : Theme.inkSoft)
                        .frame(width: PZ(15), height: PZ(15))
                        .background(
                            RoundedRectangle(cornerRadius: PZ(3), style: .continuous)
                                .fill(rich.highlighted ? Color(nsColor: RichPalette.highlight) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help("高亮")

                barDivider

                formatButton(.bullet, "•", font: PF(12, .bold), tip: "项目符号")

                stepButton("eraser", "清除格式") { rich.apply(.clear) }
            }
            .padding(.horizontal, PZ(12))
            .padding(.vertical, PZ(3))
        }
        .frame(height: PZ(21))
    }

    private var barDivider: some View {
        Rectangle()
            .fill(Theme.sched.opacity(0.12))
            .frame(width: 0.8, height: PZ(11))
            .padding(.horizontal, PZ(1.5))
    }

    private func isSameColor(_ c: NSColor) -> Bool {
        let a = rich.color.usingColorSpace(.sRGB), b = c.usingColorSpace(.sRGB)
        guard let a, let b else { return false }
        return abs(a.redComponent - b.redComponent) < 0.04
            && abs(a.greenComponent - b.greenComponent) < 0.04
            && abs(a.blueComponent - b.blueComponent) < 0.04
    }

    private func formatButton(_ op: RichOp, _ label: String, font: Font,
                              tip: String, underline: Bool = false,
                              strike: Bool = false) -> some View {
        let on = rich.active.contains(op)
        return Button { rich.apply(op) } label: {
            Text(label)
                .font(font)
                .foregroundColor(on ? .white : Theme.ink)
                .frame(width: PZ(17), height: PZ(16))
                .background(
                    RoundedRectangle(cornerRadius: PZ(4), style: .continuous)
                        .fill(on ? AnyShapeStyle(Theme.redGradient) : AnyShapeStyle(Color.clear))
                )
                .overlay(
                    Text(label)
                        .font(font)
                        .foregroundColor(.clear)
                        .overlay(alignment: .bottom) {
                            if underline || strike {
                                Rectangle()
                                    .fill(on ? Color.white : Theme.ink)
                                    .frame(height: 0.8)
                                    .offset(y: strike ? PZ(-4) : 0)
                            }
                        }
                )
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    private func stepButton(_ icon: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(PF(9, .semibold))
                .foregroundColor(Theme.inkSoft)
                .frame(width: PZ(16), height: PZ(16))
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    private func imageStrip(_ n: NoteNode) -> some View {
        // 读一下 galleryTick：NSImage 不是值类型，删图后不靠这个 tick 视图不会重取
        let tick = notes.galleryTick
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PZ(5)) {
                ForEach(n.images, id: \.self) { name in
                    ZStack(alignment: .topTrailing) {
                        if let img = notes.image(name) {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: PZ(54), height: PZ(40))
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: PZ(5), style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: PZ(5), style: .continuous)
                                    .stroke(Theme.sched.opacity(0.18), lineWidth: 0.8))
                                .onTapGesture { notes.previewImage = name }
                        }
                        Button { notes.removeImage(name, from: n.id) } label: {
                            ZStack {
                                Circle().fill(Theme.redDeep).frame(width: PZ(10), height: PZ(10))
                                Image(systemName: "xmark")
                                    .font(.system(size: PZ(5.5), weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("删掉这张图")
                        .offset(x: PZ(3), y: PZ(-3))
                    }
                }
            }
            .padding(.horizontal, PZ(12))
            .padding(.vertical, PZ(4))
        }
        .frame(height: PZ(52))
        .id("\(n.id)-\(tick)")
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.sched.opacity(0.08)).frame(height: 0.8)
        }
    }

    private func editorToolbar(_ n: NoteNode) -> some View {
        HStack(spacing: PZ(6)) {
            ghost("贴图", "photo.on.rectangle.angled") { pickImages() }
            Text("⌘V 也能直接贴")
                .font(PF(8))
                .foregroundColor(Theme.inkSoft.opacity(0.75))
            Spacer(minLength: 0)
            ghost("删除", "trash") { pendingDelete = n }
        }
        .padding(.horizontal, PZ(12))
        .padding(.vertical, PZ(6))
        .background(Theme.cream.opacity(0.85))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.sched.opacity(0.08)).frame(height: 0.8)
        }
    }

    // MARK: - 图片放大

    @ViewBuilder
    private var preview: some View {
        if let name = notes.previewImage, let img = notes.image(name) {
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.55)
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(PZ(16))
                Button { notes.previewImage = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(PF(15))
                        .foregroundColor(.white.opacity(0.9))
                }
                .buttonStyle(.plain)
                .padding(PZ(8))
            }
            .contentShape(Rectangle())
            .onTapGesture { notes.previewImage = nil }
            .transition(.opacity)
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(notes.status.hasPrefix("笔记保存失败") ? Theme.sched : Theme.ok)
                .frame(width: PZ(5), height: PZ(5))
            Text(notes.status.isEmpty ? "全部存在本机 data/notes" : notes.status)
                .font(PF(9.5, notes.status.hasPrefix("笔记保存失败") ? .bold : .regular))
                .foregroundColor(notes.status.hasPrefix("笔记保存失败") ? Theme.sched : Theme.inkSoft)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { closePane() } label: {
                Text("关闭").font(PF(8.5, .semibold)).foregroundColor(Theme.sched)
                    .padding(.horizontal, PZ(6)).padding(.vertical, PZ(2))
                    .background(Capsule().fill(Theme.sched.opacity(0.10)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, PZ(16))
        .padding(.vertical, PZ(7))
        .background(Theme.cream.opacity(0.92))
        .overlay(alignment: .top) { Theme.ribbon.frame(height: PZ(1)).opacity(0.45) }
    }

    // MARK: - 草稿回写

    private func loadDraft() {
        loading = true
        draftFor = notes.selected
        let n = notes.selectedNode
        draftTitle = n?.title ?? ""
        draftRich = n.map { notes.attributed($0.id) } ?? RichText.attributed(fromPlain: "")
        draftBody = draftRich.string
        loading = false
    }

    /// immediate = true 立刻落（切条目、退出页、删除前）；
    /// false 走 0.5 秒防抖，边打字边存
    private func commit(_ immediate: Bool) {
        guard !loading, let id = draftFor else { return }
        let ns = notes
        let t = draftTitle
        let richText = draftRich
        saveTask?.cancel()
        if immediate {
            ns.rename(id, to: t)
            ns.setRichBody(id, richText)
            return
        }
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            ns.rename(id, to: t)
            ns.setRichBody(id, richText)
        }
    }

    // MARK: - 贴图

    private func pickImages() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.allowedContentTypes = [.image]
        p.prompt = "贴进来"
        p.message = "选一张或多张图片贴到当前笔记"
        guard p.runModal() == .OK else { return }
        var n = 0
        for u in p.urls where notes.addImage(u) { n += 1 }
        if n == 0 { notes.setStatus("这些文件不算图片") }
    }

    // MARK: - 通用件

    private func ghost(_ t: String, _ icon: String, solid: Bool = false,
                       action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            HStack(spacing: PZ(3.5)) {
                Image(systemName: icon).font(PF(8.5, .semibold))
                Text(t).font(PF(9, .semibold))
            }
            .foregroundColor(solid ? .white : Theme.sched)
            .padding(.horizontal, PZ(7)).padding(.vertical, PZ(3.5))
            .background(
                RoundedRectangle(cornerRadius: PZ(6), style: .continuous)
                    .fill(solid ? AnyShapeStyle(Theme.redGradient) : AnyShapeStyle(Theme.sched.opacity(0.08)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PZ(6), style: .continuous)
                    .stroke(solid ? Theme.todo.opacity(0.5) : Theme.sched.opacity(0.22), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 富文本编辑器（NSTextView 包装）

/// SwiftUI 的 `TextEditor` 只接 `String`，富文本必须自己接一层 NSTextView。
/// 这里只借它的能力（选区、属性、撤销），可能坏事的东西全关掉：
/// 智能引号/自动替换会把代码片段和英文改坏；图片导入会把正文变成附件仓库
/// —— 记事本的图走底下那条图片条，不进正文（否则导出、备份、搜索全要跟着改）。
final class RichTextView: NSTextView {
    /// 粘贴先过一遍洗白。从浏览器/微信粘一段带格式的文字，原样插进来会带上
    /// 22.5pt 的字号、行距 0、深色主题的白字 —— 在宣纸底上直接看不清。
    /// 图片不走这里：⌘V 贴图在按键层就被监视器拦下，存进图片条了。
    override func paste(_ sender: Any?) {
        guard let raw = RichTextView.attributedFromPasteboard(.general) else {
            super.paste(sender)
            return
        }
        RichText.insert(RichText.launder(raw), into: self)
    }

    /// 只认「真的是富文本」的两种类型。纯文本让它走系统那条路，
    /// 免得我们自己拼字符串时把换行、制表符处理错。
    static func attributedFromPasteboard(_ pb: NSPasteboard) -> NSAttributedString? {
        if let d = pb.data(forType: .rtf),
           let s = try? NSAttributedString(
               data: d,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil) {
            return s
        }
        if let d = pb.data(forType: .html),
           let s = try? NSAttributedString(
               data: d,
               options: [.documentType: NSAttributedString.DocumentType.html],
               documentAttributes: nil) {
            return s
        }
        return nil
    }
}


struct RichEditor: NSViewRepresentable {
    /// 哪一篇。换笔记必须整份换内容，不能靠「内容相等」去猜
    let noteID: String
    let text: NSAttributedString
    let bridge: RichEditorBridge
    let onChange: (NSAttributedString) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// 该不该把 `incoming` 再推一次进文本视图。
    ///
    /// 抽成纯函数是为了能离屏断言：这段判断写错不是「看着有点不对」，是**整扇窗卡死**。
    /// 2026-11-25 就是这么翻的：拿 `textStorage.isEqual(to: text)` 当判据，而
    /// `NSTextStorage` 会把带 `NSTextList` 的段落样式（项目符号）规范化一遍 ——
    /// 比出来永远是 false → 每次视图更新都回写 → 回写动选择 → `refresh()` 发布 →
    /// 又一轮更新。**任何带项目符号的笔记都会把主线程顶到 100% CPU**。
    /// 所以判据换成「模型侧快照」：`applied` 是我们上次推下去的那一份，比它即可。
    static func shouldPush(applied: NSAttributedString?, incoming: NSAttributedString, editing: Bool) -> Bool {
        if let applied, applied.isEqual(to: incoming) { return false }
        // 用户正在这里打字：外来的内容一律不抢（抢了光标会跳、输入法会被打断）
        if editing { return false }
        return true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichEditor
        var boundID: String
        /// 程序化灌值期间不把变化报回去 —— 否则一换笔记就等于「用户刚打了一段」
        var loading = false
        /// 上一次推给文本视图的那一份（模型侧，不是文本视图里的实际状态）。
        /// 别改成「从 textStorage 读回来存」：那份已经被文本系统改写过，存了也白存。
        var applied: NSAttributedString?

        init(_ p: RichEditor) {
            parent = p
            boundID = p.noteID
        }

        func textDidChange(_ note: Notification) {
            guard !loading, let tv = note.object as? NSTextView, let st = tv.textStorage else { return }
            parent.onChange(NSAttributedString(attributedString: st))
            parent.bridge.refresh()
        }

        func textViewDidChangeSelection(_ note: Notification) {
            parent.bridge.refresh()
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let tv = RichTextView(frame: .zero)
        tv.delegate = context.coordinator
        tv.isRichText = true
        tv.allowsUndo = true
        tv.importsGraphics = false
        tv.drawsBackground = false
        tv.isEditable = true
        tv.isSelectable = true
        // 自动那几样一律关掉：中文写作里「自动替换」只会把人惹毛
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 4)
        tv.typingAttributes = RichText.baseAttributes()
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv

        context.coordinator.loading = true
        tv.textStorage?.setAttributedString(text)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        context.coordinator.applied = text
        context.coordinator.loading = false
        // 别在视图构建/更新中间改 @Published：下一个主线程回合再挂，
        // 否则控制台会刷「Modifying state during view update」那一类告警。
        DispatchQueue.main.async { bridge.attach(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? RichTextView else { return }
        context.coordinator.parent = self

        if context.coordinator.boundID != noteID {
            context.coordinator.boundID = noteID
            context.coordinator.loading = true
            tv.textStorage?.setAttributedString(text)
            tv.typingAttributes = RichText.baseAttributes()
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.undoManager?.removeAllActions()
            tv.scrollToBeginningOfDocument(nil)
            context.coordinator.applied = text
            context.coordinator.loading = false
            DispatchQueue.main.async { bridge.attach(tv) }
            return
        }

        // 同一篇：只有「外部真的换了内容」才推回视图。判据见 `shouldPush` ——
        // ⚠️ 不要改回 `textStorage.isEqual(to: text)`：项目符号那类段落样式会被文本系统
        // 规范化，比出来永远 false，于是每次视图更新都回写，整扇窗顶到 100% CPU。
        let editing = tv.window?.firstResponder === tv
        guard Self.shouldPush(applied: context.coordinator.applied, incoming: text, editing: editing),
              let st = tv.textStorage else { return }
        context.coordinator.loading = true
        let sel = tv.selectedRange()
        st.setAttributedString(text)
        // 只在选区真要被收拢时才动它：`setSelectedRange` 会发一条选择变化通知，
        // 那又会把工具条刷一遍，白添一轮视图更新。
        let loc = min(sel.location, st.length)
        if sel.length > 0 || sel.location != loc {
            tv.setSelectedRange(NSRange(location: loc, length: 0))
        }
        context.coordinator.applied = text
        context.coordinator.loading = false
    }
}
