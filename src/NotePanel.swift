//
//  NotePanel.swift
//  书办（ShuBan）· 记事本面板
//
//  和录屏页一样，它不是新窗口 —— 就是书办面板的第三个态（store.mode == 2），
//  从底栏「笔记」进来，从左上角回去。
//  视觉沿用书办那套：宣纸暖白、中国红、金线、印章，字号尺寸统一走 Fnt/S。
//
//  版式：左边一条窄的树（约 140pt 基准宽），右边是编辑区。
//  为什么不做成「列表 → 点进去 → 返回」的两级：这是桌面浮窗，宽度只有 384，
//  但高度够；树一直可见，换条目只要点一下，比来回翻页顺手。
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NotePanel: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var notes: NoteStore

    /// 编辑区草稿。不直接绑 store 里的字段：每敲一个字都写 @Published 会让整棵树重排，
    /// 光标还容易跳。这里先攒着，停手 0.5 秒再回写。
    @State private var draftTitle = ""
    @State private var draftBody = ""
    /// 草稿属于哪个节点。切选中前必须靠它把字存回原来那条，否则刚打的就丢了
    @State private var draftFor: String?
    /// 正在用 loadDraft 灌值：这期间的 onChange 不算用户输入
    @State private var loading = false
    @State private var saveTask: Task<Void, Never>?

    @State private var renaming: String?
    @State private var renameText = ""
    @State private var pendingDelete: NoteNode?

    var body: some View {
        VStack(spacing: 0) {
            header
            ribbonDivider
            HStack(spacing: 0) {
                treeColumn
                    .frame(width: S(142))
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
                    if draftFor == n.id { draftFor = nil; draftTitle = ""; draftBody = "" }
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
                    Text("记")
                        .font(Fnt.s(15, .bold, .serif))
                        .foregroundColor(.white)
                        .offset(y: S(-0.5))
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("记 事 本").font(Fnt.s(21, .heavy, .rounded)).foregroundColor(Theme.sched)
                        Text("书办子功能")
                            .font(Fnt.s(8.5, .semibold, .rounded))
                            .foregroundColor(Theme.goldDeep)
                            .padding(.horizontal, S(4))
                            .padding(.vertical, S(1))
                            .background(Capsule().fill(Theme.todo.opacity(0.18)))
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "list.bullet.indent")
                            .font(Fnt.s(8.5, .semibold))
                            .foregroundColor(Theme.sched.opacity(0.75))
                        Text("\(notes.noteCount) 篇 · 树形目录 · 可贴图")
                            .font(Fnt.s(10)).foregroundColor(Theme.inkSoft).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                newNoteButton
                newFolderButton
            }
            .padding(.horizontal, S(13))
            .padding(.top, S(8))
            .padding(.bottom, S(7))
        }
    }

    private var newNoteButton: some View {
        Button { notes.add(folder: false) } label: {
            Image(systemName: "square.and.pencil")
                .font(Fnt.s(11, .semibold))
                .foregroundColor(.white)
                .frame(width: S(24), height: S(24))
                .background(RoundedRectangle(cornerRadius: S(7), style: .continuous).fill(Theme.redGradient))
                .overlay(RoundedRectangle(cornerRadius: S(7), style: .continuous)
                    .stroke(Theme.todo.opacity(0.5), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .help("新建笔记（建在当前选中的那一层里）")
    }

    private var newFolderButton: some View {
        Button { notes.add(folder: true) } label: {
            Image(systemName: "folder.badge.plus")
                .font(Fnt.s(11, .semibold))
                .foregroundColor(Theme.sched)
                .frame(width: S(24), height: S(24))
                .background(RoundedRectangle(cornerRadius: S(7), style: .continuous).fill(Theme.sched.opacity(0.09)))
                .overlay(RoundedRectangle(cornerRadius: S(7), style: .continuous)
                    .stroke(Theme.sched.opacity(0.25), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .help("新建文件夹")
    }

    private var ribbonDivider: some View {
        Theme.ribbon.frame(height: S(1.2)).opacity(0.55).padding(.horizontal, S(12))
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
                                .font(Fnt.s(9.5)).foregroundColor(Theme.inkSoft)
                                .frame(maxWidth: .infinity).padding(.top, S(18))
                        } else {
                            ForEach(hits, id: \.node.id) { h in hitRow(h.node, h.path) }
                        }
                    }
                }
                .padding(.vertical, S(4))
            }
        }
        .background(Theme.cream.opacity(0.55))
    }

    private var searchRow: some View {
        HStack(spacing: S(4)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: S(8.5), weight: .semibold))
                .foregroundColor(Theme.inkSoft.opacity(0.8))
            TextField("搜标题和正文", text: $notes.keyword)
                .textFieldStyle(.plain)
                .font(Fnt.s(9.5))
                .foregroundColor(Theme.ink)
            if !notes.keyword.isEmpty {
                Button { notes.keyword = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: S(9)))
                        .foregroundColor(Theme.inkSoft.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, S(6))
        .padding(.vertical, S(4))
        .background(RoundedRectangle(cornerRadius: S(6), style: .continuous).fill(Color.black.opacity(0.045)))
        .padding(.horizontal, S(6))
        .padding(.top, S(5))
        .padding(.bottom, S(3))
    }

    private var treeEmptyHint: some View {
        VStack(spacing: S(6)) {
            Text("还没有笔记")
                .font(Fnt.s(9.5)).foregroundColor(Theme.inkSoft)
            Text("点右上角 + 新建")
                .font(Fnt.s(8.5)).foregroundColor(Theme.inkSoft.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, S(20))
    }

    private func treeRow(_ r: TreeRow) -> some View {
        let n = r.node
        let on = notes.selected == n.id
        let kids = n.folder ? notes.children(n.id).count : 0
        return HStack(spacing: S(3)) {
            // 缩进用固定宽度占位，不用 padding —— 深一层就该真的往右挪一格
            Color.clear.frame(width: S(6) * CGFloat(r.depth), height: 1)
            if n.folder {
                Button { toggle(n.id) } label: {
                    Image(systemName: notes.expanded.contains(n.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: S(6), weight: .bold))
                        .foregroundColor(Theme.inkSoft.opacity(0.9))
                        .frame(width: S(10), height: S(12))
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: S(10), height: 1)
            }
            Image(systemName: n.folder ? "folder.fill" : "doc.text")
                .font(.system(size: S(8), weight: .medium))
                .foregroundColor(n.folder ? Theme.todo : Theme.sched.opacity(0.65))
            if renaming == n.id {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(Fnt.s(10, .semibold))
                    .foregroundColor(Theme.ink)
                    .onSubmit { commitRename(n.id) }
                    .onExitCommand { renaming = nil }
            } else {
                Text(n.title)
                    .font(Fnt.s(10, on ? .semibold : .regular))
                    .foregroundColor(on ? Theme.sched : Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if n.folder && kids > 0 {
                Text("\(kids)")
                    .font(Fnt.s(8, .semibold, .rounded))
                    .foregroundColor(on ? Theme.sched.opacity(0.8) : Theme.inkSoft.opacity(0.7))
            }
            if !n.folder && !n.images.isEmpty {
                Image(systemName: "photo")
                    .font(.system(size: S(7)))
                    .foregroundColor(Theme.todo.opacity(0.9))
            }
        }
        .padding(.horizontal, S(4))
        .frame(height: S(21))
        .background(on ? Theme.sched.opacity(0.10) : Color.clear)
        .overlay(alignment: .leading) {
            if on { Rectangle().fill(Theme.sched).frame(width: S(2)) }
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
                .font(Fnt.s(9.5, .semibold))
                .foregroundColor(on ? Theme.sched : Theme.ink)
                .lineLimit(1)
            Text(path.isEmpty ? "顶层" : path)
                .font(Fnt.s(8))
                .foregroundColor(Theme.inkSoft.opacity(0.75))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, S(6))
        .padding(.vertical, S(3))
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
        VStack(spacing: S(8)) {
            ZStack {
                Circle().fill(Theme.sched.opacity(0.07)).frame(width: S(46), height: S(46))
                Image(systemName: "square.and.pencil")
                    .font(Fnt.s(18, .light))
                    .foregroundColor(Theme.sched.opacity(0.55))
            }
            Text("左边选一条，或者点右上角 + 新建")
                .font(Fnt.s(9.5)).foregroundColor(Theme.inkSoft)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func folderView(_ n: NoteNode) -> some View {
        let kids = notes.children(n.id)
        return VStack(spacing: S(9)) {
            ZStack {
                RoundedRectangle(cornerRadius: S(14), style: .continuous)
                    .fill(Theme.todo.opacity(0.14))
                    .frame(width: S(52), height: S(52))
                Image(systemName: "folder.fill")
                    .font(Fnt.s(22))
                    .foregroundColor(Theme.todo)
            }
            Text(n.title)
                .font(Fnt.s(13, .bold))
                .foregroundColor(Theme.ink)
                .multilineTextAlignment(.center)
            Text("\(kids.count) 项 · 里面 \(kids.filter { !$0.folder }.count) 篇笔记")
                .font(Fnt.s(9)).foregroundColor(Theme.inkSoft)
            HStack(spacing: S(6)) {
                ghost("新建笔记", "square.and.pencil", solid: true) {
                    notes.selected = n.id
                    notes.add(folder: false)
                }
                ghost("新建子文件夹", "folder.badge.plus") {
                    notes.selected = n.id
                    notes.add(folder: true)
                }
            }
            .padding(.top, S(2))
            HStack(spacing: S(6)) {
                ghost("重命名", "pencil") { beginRename(n) }
                ghost("删除", "trash") { pendingDelete = n }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(S(12))
    }

    private func noteEditor(_ n: NoteNode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("无标题", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(Fnt.s(13.5, .bold))
                .foregroundColor(Theme.ink)
                .padding(.horizontal, S(12))
                .padding(.top, S(8))
                .onSubmit { commit(true) }

            HStack(spacing: S(5)) {
                Text("\(draftBody.count) 字")
                Text("·")
                Text("改于 \(RelativeDate.text(Date(timeIntervalSince1970: n.updatedAt)))")
                Spacer(minLength: 0)
            }
            .font(Fnt.s(8.5))
            .foregroundColor(Theme.inkSoft.opacity(0.9))
            .padding(.horizontal, S(12))
            .padding(.top, S(2))

            // 红金细线：和日历那边「表头 / 内容」的分隔保持同一语言
            Theme.ribbon
                .frame(height: S(1))
                .opacity(0.5)
                .padding(.horizontal, S(12))
                .padding(.top, S(6))

            TextEditor(text: $draftBody)
                .font(Fnt.s(11))
                .foregroundColor(Theme.ink)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, S(8))
                .padding(.vertical, S(4))
                .frame(maxHeight: .infinity)
                .onChange(of: draftBody) { _ in commit(false) }

            if !n.images.isEmpty { imageStrip(n) }
            editorToolbar(n)
        }
        .onChange(of: draftTitle) { _ in commit(false) }
    }

    private func imageStrip(_ n: NoteNode) -> some View {
        // 读一下 galleryTick：NSImage 不是值类型，删图后不靠这个 tick 视图不会重取
        let tick = notes.galleryTick
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: S(5)) {
                ForEach(n.images, id: \.self) { name in
                    ZStack(alignment: .topTrailing) {
                        if let img = notes.image(name) {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: S(54), height: S(40))
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: S(5), style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: S(5), style: .continuous)
                                    .stroke(Theme.sched.opacity(0.18), lineWidth: 0.8))
                                .onTapGesture { notes.previewImage = name }
                        }
                        Button { notes.removeImage(name, from: n.id) } label: {
                            ZStack {
                                Circle().fill(Theme.redDeep).frame(width: S(10), height: S(10))
                                Image(systemName: "xmark")
                                    .font(.system(size: S(5.5), weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("删掉这张图")
                        .offset(x: S(3), y: S(-3))
                    }
                }
            }
            .padding(.horizontal, S(12))
            .padding(.vertical, S(4))
        }
        .frame(height: S(52))
        .id("\(n.id)-\(tick)")
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.sched.opacity(0.08)).frame(height: 0.8)
        }
    }

    private func editorToolbar(_ n: NoteNode) -> some View {
        HStack(spacing: S(6)) {
            ghost("贴图", "photo.on.rectangle.angled") { pickImages() }
            Text("⌘V 也能直接贴")
                .font(Fnt.s(8))
                .foregroundColor(Theme.inkSoft.opacity(0.75))
            Spacer(minLength: 0)
            ghost("删除", "trash") { pendingDelete = n }
        }
        .padding(.horizontal, S(12))
        .padding(.vertical, S(6))
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
                    .padding(S(16))
                Button { notes.previewImage = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Fnt.s(15))
                        .foregroundColor(.white.opacity(0.9))
                }
                .buttonStyle(.plain)
                .padding(S(8))
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
                .frame(width: S(5), height: S(5))
            Text(notes.status.isEmpty ? "全部存在本机 data/notes" : notes.status)
                .font(Fnt.s(9.5, notes.status.hasPrefix("笔记保存失败") ? .bold : .regular))
                .foregroundColor(notes.status.hasPrefix("笔记保存失败") ? Theme.sched : Theme.inkSoft)
                .lineLimit(1)
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

    // MARK: - 草稿回写

    private func loadDraft() {
        loading = true
        draftFor = notes.selected
        let n = notes.selectedNode
        draftTitle = n?.title ?? ""
        draftBody = n?.body ?? ""
        loading = false
    }

    /// immediate = true 立刻落（切条目、退出页、删除前）；
    /// false 走 0.5 秒防抖，边打字边存
    private func commit(_ immediate: Bool) {
        guard !loading, let id = draftFor else { return }
        let ns = notes
        let t = draftTitle
        let b = draftBody
        saveTask?.cancel()
        if immediate {
            ns.rename(id, to: t)
            ns.setBody(id, b)
            return
        }
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            ns.rename(id, to: t)
            ns.setBody(id, b)
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
            HStack(spacing: S(3.5)) {
                Image(systemName: icon).font(Fnt.s(8.5, .semibold))
                Text(t).font(Fnt.s(9, .semibold))
            }
            .foregroundColor(solid ? .white : Theme.sched)
            .padding(.horizontal, S(7)).padding(.vertical, S(3.5))
            .background(
                RoundedRectangle(cornerRadius: S(6), style: .continuous)
                    .fill(solid ? AnyShapeStyle(Theme.redGradient) : AnyShapeStyle(Theme.sched.opacity(0.08)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: S(6), style: .continuous)
                    .stroke(solid ? Theme.todo.opacity(0.5) : Theme.sched.opacity(0.22), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }
}
