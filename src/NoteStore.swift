//
//  NoteStore.swift
//  书办（ShuBan）· 记事本数据层
//
//  为什么是「扁平表 + parent 指针」而不是嵌套结构：
//  改名、移动、删除都只改一行字段，不用递归拷贝整棵子树；
//  落盘成 JSON 也天然是稳定结构，不会因为层级深了出现递归解码的坑。
//  取树的时候按 parent 现算，节点量级（几十上百）完全撑得住。
//
//  存储位置（全部在 data/notes/ 下，纯本地、随手 cp 走就能备份）：
//    notes.json          树（扁平表 + parent 指针）+ 正文的纯文本投影
//    rich/<id>.rtfd/     正文的富文本，RTFD 目录包 —— 正文里的图就装在包里的 Attachment.png
//    files/<文件名>      正文里「插文件」拷进来的附件（芯片指向这里）
//    images/<uuid>.png   老数据：这一轮之前图是正文下面一条图片条，打开时自动迁进正文
//

import SwiftUI
import AppKit

// MARK: - 模型

struct NoteNode: Codable, Identifiable, Equatable {
    var id: String
    /// nil = 顶层
    var parent: String?
    var title: String
    /// true = 文件夹（能装子项），false = 笔记（有正文和图片）
    var folder: Bool
    var body: String
    /// ⚠️ 老字段，只为把老数据读出来。这一轮之前图存在正文**下方**一条图片条里，
    /// 靠这个列表挂账；现在图直接进正文，所以打开时会迁进 RTFD 包并把这里清空。
    /// 别再往里加东西 —— 新图走 `RichEditorBridge.insertImage`。
    var images: [String]
    /// 同一层内的排序
    var order: Int
    var createdAt: Double
    var updatedAt: Double

    init(id: String = UUID().uuidString,
         parent: String? = nil,
         title: String,
         folder: Bool = false,
         body: String = "",
         images: [String] = [],
         order: Int = 0,
         createdAt: Double = Date().timeIntervalSince1970,
         updatedAt: Double? = nil) {
        self.id = id
        self.parent = parent
        self.title = title
        self.folder = folder
        self.body = body
        self.images = images
        self.order = order
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, parent, title, folder, body, images, order, createdAt, updatedAt
    }

    /// 手写解码：字段缺一个就整份读不出来，对「用户自己的笔记」来说代价太大，
    /// 所以每个字段都给兜底值。以后加字段也不会把老文件读崩。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        parent = try? c.decodeIfPresent(String.self, forKey: .parent)
        title = (try? c.decode(String.self, forKey: .title)) ?? "未命名"
        folder = (try? c.decode(Bool.self, forKey: .folder)) ?? false
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        images = (try? c.decode([String].self, forKey: .images)) ?? []
        order = (try? c.decode(Int.self, forKey: .order)) ?? 0
        let t = (try? c.decode(Double.self, forKey: .createdAt)) ?? Date().timeIntervalSince1970
        createdAt = t
        updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? t
    }
}

// MARK: - 数据层

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var nodes: [NoteNode] = []
    @Published var selected: String?
    /// 展开着的文件夹 id
    @Published var expanded: Set<String> = []
    /// 搜索词；非空时列表切成「全库搜索结果」
    @Published var keyword: String = ""
    @Published private(set) var status: String = ""

    private(set) var dir: URL?
    /// 富文本按篇存成 RTFD 包：`data/notes/rich/<id>.rtfd/`。
    ///
    /// 为什么不塞进 notes.json：一篇带图的正文是个目录包（TXT.rtf + 几 MB 的 png），
    /// 编码成 JSON 就成了没法读、没法手改、也没法单独备份的糊状。分文件之后
    /// 「删笔记」就是删一个目录，而且包坏了只影响那一篇，不会把整棵树带下水。
    private var richDir: URL?
    /// 「插文件」拷进来的附件实体：`data/notes/files/`。正文里只有一个芯片指过来。
    ///
    /// ⚠️ 文件**不**进 RTFD 包：自动保存是 0.7 秒防抖，一个几十兆的 ppt 进了包，
    /// 就是每写一句话重写几十兆（写一次卡一次）。
    private var filesDir: URL?
    /// 老数据里的图（正文下面那条图片条）就放在这儿，迁移完就不再用了
    private var imageDir: URL?
    /// 正文编辑器的桥（工具条、⌘V 贴图都从这里插进光标处）。
    /// 为什么挂在 store 上而不是让按键监视器自己找 firstResponder：正文是 SwiftUI
    /// 里包的 NSTextView，「当前是哪一篇、光标在哪」只有面板自己和它知道；
    /// 而且搜索框底下也是 NSTextView（field editor），按类名去找很容易把图贴进搜索框。
    weak var richBridge: RichEditorBridge?
    /// 每篇正文上次落盘时的指纹。RTFD 是目录包，写一次就是一整包（含图），
    /// 防抖每次都会来，内容没变就别陪着抖。
    private var richSig: [String: String] = [:]
    private var saveTask: Task<Void, Never>?
    private var configured = false

    /// 目录最多几层。够用就行，纯为了保护「拖进自己子目录」之外的手滑
    static let maxDepth = 7

    // MARK: 路径与加载

    func configure(projectDir: URL?) {
        guard !configured else { return }
        configured = true
        if let d = ProcessInfo.processInfo.environment["WECAL_NOTES_DIR"], !d.isEmpty {
            // 验收钩子：把笔记目录指到别处。拍图、试拖动、试贴图都走它，不碰真实笔记
            dir = URL(fileURLWithPath: d, isDirectory: true)
        } else {
            let base = projectDir ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/ShuBan", isDirectory: true)
            dir = base.appendingPathComponent("data/notes", isDirectory: true)
        }
        imageDir = dir?.appendingPathComponent("images", isDirectory: true)
        if let d = imageDir { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        richDir = dir?.appendingPathComponent("rich", isDirectory: true)
        if let d = richDir { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        filesDir = dir?.appendingPathComponent("files", isDirectory: true)
        if let d = filesDir { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        load()
        seedIfEmpty()
        migrateLegacyImages()
        // 进来不该是空白的：默认选中第一篇，省掉「先点一下」这一步
        if selected == nil { selected = firstNoteId() }
        // 验收钩子：按标题预选一条，拍图时不用手点
        if let pick = ProcessInfo.processInfo.environment["WECAL_NOTES_PICK"], !pick.isEmpty,
           let hit = nodes.first(where: { !$0.folder && $0.title.contains(pick) }) {
            selected = hit.id
        }
    }

    /// 深度优先找第一篇笔记（文件夹跳过）
    private func firstNoteId(_ parent: String? = nil, _ guardCount: Int = 0) -> String? {
        guard guardCount < 256 else { return nil }
        for n in children(parent) {
            if !n.folder { return n.id }
            if let deeper = firstNoteId(n.id, guardCount + 1) { return deeper }
        }
        return nil
    }

    private var fileURL: URL? { dir?.appendingPathComponent("notes.json") }

    private func load() {
        guard let f = fileURL, let raw = try? Data(contentsOf: f) else { return }
        struct Doc: Codable { var version: Int?; var nodes: [NoteNode]?; var expanded: [String]? }
        if let doc = try? JSONDecoder().decode(Doc.self, from: raw), let list = doc.nodes {
            nodes = list
            sanitize()
            // 展开状态跟着文件走：谁把哪个文件夹打开了，下次进来还开着，
            // 不然每次都要重新点开一遍去找昨天那条笔记。
            if let e = doc.expanded {
                expanded = Set(e.filter { id in nodes.contains { $0.id == id && $0.folder } })
            } else {
                expanded = Set(nodes.filter { $0.folder && $0.parent == nil }.map(\.id))
            }
        } else {
            // 读不出来就别装作没事：留个现场，让用户还能自己去捞
            let bad = f.deletingLastPathComponent().appendingPathComponent("notes.bad.json")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.copyItem(at: f, to: bad)
            status = "笔记文件读不出来，已另存 notes.bad.json"
        }
    }

    /// 修掉坏结构：孤儿子项挂回顶层、重复 id 重新发号、同层 order 重新编号。
    /// 手改过 JSON 或者并发写坏的时候，这几步能保住内容不丢。
    private func sanitize() {
        var seen = Set<String>()
        for i in nodes.indices {
            if seen.contains(nodes[i].id) { nodes[i].id = UUID().uuidString }
            seen.insert(nodes[i].id)
        }
        let ids = Set(nodes.map(\.id))
        for i in nodes.indices {
            if let p = nodes[i].parent, !ids.contains(p) { nodes[i].parent = nil }
            if nodes[i].parent == nodes[i].id { nodes[i].parent = nil }
        }
        for p in Set(nodes.map(\.parent)) { renumber(p) }
    }

    private func seedIfEmpty() {
        guard nodes.isEmpty else { return }
        var book = NoteNode(title: "我的笔记", folder: true)
        book.order = 0
        let welcome = NoteNode(
            parent: book.id,
            title: "从这里开始",
            body: """
            书办记事本

            · 左上角「＋」新建笔记，「夹」新建文件夹 —— 都建在当前选中的那一层里
            · 条目可以拖动：拖到文件夹上就进去，拖到笔记上就排在它前面
            · 正文里直接 ⌘V 贴图；也可以点下面「插图片」「插文件」选文件
            · 图就在文字中间，和字一起选中、一起删除、一起撤销；
              文件在正文里是一个 📄 芯片，点一下就打开
            · 上面那条格式栏：粗体斜体下划线删除线、字号台阶、四种颜色、项目符号
            · 右键条目：重命名 / 删除 / 上移下移 / 移到顶层
            · 全部存在本机 data/notes/ 下，是纯 JSON 加一个 <id>.rtfd 包，拷走就是备份

            这个页面就是拿来放零碎东西的：客户现场记的几句话、一张截图、
            待会儿要贴到周报里的一段结论。不用管格式，写完切回日历就行。
            """,
            order: 0)
        nodes = [book, welcome]
        expanded.insert(book.id)
        selected = welcome.id
        saveNow()
        status = "已建好默认笔记本"
    }

    // MARK: 树的读取

    func node(_ id: String?) -> NoteNode? {
        guard let id = id else { return nil }
        return nodes.first { $0.id == id }
    }

    /// 展开/收起文件夹。展开状态要落盘（跟着 notes.json 走），所以走这里而不是让视图直接改集合
    func toggleExpand(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        scheduleSave()
    }

    /// 同一层的子项，按 order 升序
    func children(_ parent: String?) -> [NoteNode] {
        nodes.filter { $0.parent == parent }
            .sorted { $0.order == $1.order ? $0.createdAt < $1.createdAt : $0.order < $1.order }
    }

    var selectedNode: NoteNode? { node(selected) }

    func depth(of id: String) -> Int {
        var d = 0
        var cur = node(id)?.parent
        var guardCount = 0
        while let p = cur, guardCount < 64 {
            d += 1
            cur = node(p)?.parent
            guardCount += 1
        }
        return d
    }

    /// b 是不是 a 的后代（用于挡住「把文件夹拖进自己的子目录」）
    func isDescendant(_ a: String, of b: String) -> Bool {
        var cur = node(a)?.parent
        var guardCount = 0
        while let p = cur, guardCount < 64 {
            if p == b { return true }
            cur = node(p)?.parent
            guardCount += 1
        }
        return false
    }

    func subtree(_ id: String) -> Set<String> {
        var out: Set<String> = [id]
        var frontier = [id]
        var guardCount = 0
        while !frontier.isEmpty, guardCount < 512 {
            guardCount += 1
            let p = frontier.removeLast()
            for n in nodes where n.parent == p && !out.contains(n.id) {
                out.insert(n.id)
                frontier.append(n.id)
            }
        }
        return out
    }

    /// 从根到该节点的标题链，搜索结果里当面包屑用
    func path(of id: String) -> [String] {
        var out: [String] = []
        var cur = node(id)?.parent
        var guardCount = 0
        while let p = node(cur), guardCount < 64 {
            out.insert(p.title, at: 0)
            cur = p.parent
            guardCount += 1
        }
        return out
    }

    var noteCount: Int { nodes.filter { !$0.folder }.count }

    // MARK: 增删改

    /// 新建时的落点：选中文件夹 → 进去；选中笔记 → 跟它同级；没选中 → 顶层
    private func landingParent() -> String? {
        guard let n = selectedNode else { return nil }
        return n.folder ? n.id : n.parent
    }

    func add(folder: Bool) {
        let parent = landingParent()
        if let p = parent, depth(of: p) + 1 > Self.maxDepth {
            status = "目录最多 \(Self.maxDepth + 1) 层，够深了"
            return
        }
        var n = NoteNode(parent: parent,
                         title: folder ? "新建文件夹" : "无标题笔记",
                         folder: folder)
        n.order = (children(parent).last?.order ?? -1) + 1
        nodes.append(n)
        if let p = parent { expanded.insert(p) }
        selected = n.id
        scheduleSave()
        status = folder ? "已新建文件夹" : "已新建笔记"
    }

    func rename(_ id: String, to title: String) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        nodes[i].title = t.isEmpty ? "未命名" : t
        nodes[i].updatedAt = Date().timeIntervalSince1970
        scheduleSave()
    }

    /// 正文由视图那边防抖后调过来，每敲一个字都落盘太浪费。
    /// 注意：这是「纯文本」入口 —— 写进来就等于宣告这一篇没有格式，
    /// 配套的富文本包会被删掉，否则界面上会继续显示旧的富文本（body 才是新内容）。
    /// 带格式的回写走 `setRichBody`。
    func setBody(_ id: String, _ text: String) {
        guard let i = nodes.firstIndex(where: { $0.id == id }), nodes[i].body != text else { return }
        nodes[i].body = text
        nodes[i].updatedAt = Date().timeIntervalSince1970
        dropRich(id)
        scheduleSave()
    }

    // MARK: 富文本

    /// 富文本包：`rich/<id>.rtfd/`
    func richURL(_ id: String) -> URL? { richDir?.appendingPathComponent(id + ".rtfd") }
    /// 上一版的纯 RTF（带不了图）。只为让这一轮之前存的笔记还能读出来，不再写它。
    func legacyRichURL(_ id: String) -> URL? { richDir?.appendingPathComponent(id + ".rtf") }

    /// 取一篇笔记的正文（带格式）。老笔记没有富文本包，就按 body 现造一份 ——
    /// 这样升级上来不用做批量迁移，打开哪篇就顺手把哪篇接上，没打开过的原样躺着。
    func attributed(_ id: String) -> NSAttributedString {
        guard let n = node(id), !n.folder else { return RichText.attributed(fromPlain: "") }
        if let u = richURL(id), let w = try? FileWrapper(url: u, options: []),
           let s = RichText.attributed(fromRTFD: w) {
            return s
        }
        // 这一轮之前的存档是单个 .rtf 文件（正文里的图存不住，只有字和格式）
        if let u = legacyRichURL(id), let d = try? Data(contentsOf: u),
           let s = RichText.attributed(fromLegacyRTF: d) {
            return s
        }
        return RichText.attributed(fromPlain: n.body)
    }

    /// 带格式回写：RTFD 包落盘 + body 存纯文本投影（搜索、字数、老的兼容路径都看 body）。
    /// 内容全空的时候把包删掉，不留一堆只有属性没有字的空壳目录。
    func setRichBody(_ id: String, _ attr: NSAttributedString) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        writeRich(id, attr)
        let text = RichText.plain(attr)
        guard nodes[i].body != text else { return }
        nodes[i].body = text
        nodes[i].updatedAt = Date().timeIntervalSince1970
        scheduleSave()
    }

    /// 正文里现在有几张图（删除确认那句话要用）
    func imageCount(_ id: String) -> Int {
        let s = attributed(id)
        var n = 0
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length), options: []) { v, _, _ in
            if v is NSTextAttachment { n += 1 }
        }
        return n
    }

    private func writeRich(_ id: String, _ attr: NSAttributedString) {
        guard let u = richURL(id) else { return }
        // 老 .rtf 不再写：留着它，下次打开会读到过期内容（attributed 先认 .rtfd，
        // 但一旦正文清空就要靠删文件表达「这篇没有格式」）
        if let old = legacyRichURL(id) { try? FileManager.default.removeItem(at: old) }
        guard let w = RichText.rtfd(attr) else {
            try? FileManager.default.removeItem(at: u)
            richSig[id] = ""
            return
        }
        let sig = Self.richSignature(attr)
        if richSig[id] == sig, FileManager.default.fileExists(atPath: u.path) { return }
        // ⚠️ 目录包要整包换：先删再写。`options: .atomic` 对目录包不成立
        //（它只对普通文件做「临时文件 + rename」），实测写出来是个空壳。
        try? FileManager.default.removeItem(at: u)
        do {
            try w.write(to: u, options: [], originalContentsURL: nil)
            richSig[id] = sig
        } catch {
            status = "正文存不下：\(error.localizedDescription)"
        }
    }

    private func dropRich(_ id: String) {
        if let u = richURL(id) { try? FileManager.default.removeItem(at: u) }
        if let u = legacyRichURL(id) { try? FileManager.default.removeItem(at: u) }
        richSig[id] = ""
    }

    /// 正文指纹：字数 + 文字 + 图的数量和字节数。够挡住「防抖白写一整包」这件事，
    /// 又不至于为了比一遍去把包序列化两次。
    private static func richSignature(_ s: NSAttributedString) -> String {
        var imgs = 0
        var bytes = 0
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length), options: []) { v, _, _ in
            guard let a = v as? NSTextAttachment else { return }
            imgs += 1
            bytes &+= NoteAttachment.pngData(from: a)?.count ?? 0
        }
        return "\(s.length)|\(s.string.hashValue)|\(imgs)|\(bytes)"
    }

    /// 老数据的图（正文下面那条图片条）迁进正文：打开记事本时扫一遍，有就接在
    /// 正文末尾、写进 RTFD 包，再把 `images` 清空。
    ///
    /// 为什么必须迁：那一条已经整块删掉了（菲哥：「插图应该和文字在一起，而不是在下面」）。
    /// 不迁的话，老笔记里的图不是「挪了位置」而是**彻底看不见** —— 对用户就是丢数据。
    private func migrateLegacyImages() {
        var changed = false
        for i in nodes.indices where !nodes[i].images.isEmpty && !nodes[i].folder {
            let id = nodes[i].id
            let m = NSMutableAttributedString(attributedString: attributed(id))
            var moved = 0
            for name in nodes[i].images {
                guard let u = imageDir?.appendingPathComponent(name),
                      let img = NSImage(contentsOf: u), let png = img.shubanPNG(),
                      let a = NoteAttachment.image(png) else { continue }
                if m.length > 0 { m.append(RichText.attributed(fromPlain: "\n")) }
                m.append(NSAttributedString(attachment: a))
                moved += 1
            }
            nodes[i].images = []
            changed = true
            if moved > 0 { writeRich(id, m) }
        }
        if changed {
            // ⚠️ 立刻落盘，不走防抖：`images` 清空这件事必须一次生效。
            // 防抖那 0.7 秒里崩一次或者被 kill 一次，下次启动就会照着旧 JSON
            // 再插一遍 —— 图会从 1 张变 2 张（用例真的撞到过）。
            saveNow()
            status = "老笔记里的图已挪进正文"
        }
    }

    // MARK: 附件文件（正文里的「插文件」）

    func fileURL(_ name: String) -> URL? { filesDir?.appendingPathComponent(name) }

    /// 芯片指向的**实体**路径。名字想翻出 `files/` 之外就返回 nil。
    ///
    /// `fileName(from:)` 那边已经挡住了带 `/` 和 `..` 的名字，这里再挡一道是在**用的地方**
    /// 兜底：附件名是从存档里读出来的，手改过 notes.json 旁边那个包、或者哪天解析逻辑
    /// 改了，都可能漏进来一个「..」。点一下芯片就能开附件目录外的东西，不能靠上游保证。
    func filePath(_ name: String) -> URL? {
        guard let d = filesDir else { return nil }
        let base = d.standardizedFileURL.path
        let u = d.appendingPathComponent(name).standardizedFileURL
        guard u.path.hasPrefix(base + "/") else { return nil }
        return u
    }

    func fileExists(_ name: String) -> Bool {
        guard let u = filePath(name) else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }

    /// 把用户选的文件拷进 `files/`，返回落盘用的文件名（正文里的芯片就用它）。
    /// 同名不覆盖：加「 2」「 3」，跟录屏那边的习惯保持一致 —— 覆盖等于悄悄毁了
    /// 另一篇笔记的附件。
    @discardableResult
    func addFile(_ url: URL) -> String? {
        guard let d = filesDir else { return nil }
        let orig = url.lastPathComponent
        guard !orig.isEmpty else { status = "这个文件没名字，放不进来"; return nil }
        var name = orig
        var k = 2
        while FileManager.default.fileExists(atPath: d.appendingPathComponent(name).path) {
            let base = (orig as NSString).deletingPathExtension
            let ext = (orig as NSString).pathExtension
            name = ext.isEmpty ? "\(base) \(k)" : "\(base) \(k).\(ext)"
            k += 1
            if k > 999 { status = "同名文件太多了"; return nil }
        }
        do {
            try FileManager.default.copyItem(at: url, to: d.appendingPathComponent(name))
        } catch {
            status = "文件拷不进来：\(error.localizedDescription)"
            return nil
        }
        status = "已插入 \(name)"
        return name
    }

    /// 在默认应用里打开芯片指向的文件
    func openFile(_ name: String) {
        guard let u = filePath(name), FileManager.default.fileExists(atPath: u.path) else {
            status = "找不到附件 \(name)（可能被移走了）"
            return
        }
        NSWorkspace.shared.open(u)
    }

    /// 删笔记时顺手清掉只有它用过的附件。
    /// 判据故意放宽成「别的笔记正文里提到过这个名字就不删」：宁可留一个孤儿文件，
    /// 也不能把另一篇还在用的附件删掉（正文的纯文本投影里就带着文件名）。
    private func deleteOrphanFiles(_ names: [String]) {
        guard !names.isEmpty else { return }
        let alive = nodes.map(\.body).joined(separator: "\n")
        for n in Set(names) where !alive.contains(n) {
            if let u = fileURL(n) { try? FileManager.default.removeItem(at: u) }
        }
    }

    /// 一篇笔记正文里用到的附件名（从芯片的链接里取）。删除时要靠它决定哪些文件能一起清掉。
    func referencedFiles(in id: String) -> [String] {
        let s = attributed(id)
        var out: [String] = []
        s.enumerateAttribute(.link, in: NSRange(location: 0, length: s.length), options: []) { v, _, _ in
            guard let u = v as? URL, let name = NoteAttachment.fileName(from: u) else { return }
            out.append(name)
        }
        return out
    }

    func remove(_ id: String) {
        let ids = subtree(id)
        var files: [String] = []
        for n in nodes where ids.contains(n.id) {
            files.append(contentsOf: referencedFiles(in: n.id))
            dropRich(n.id)
        }
        nodes.removeAll { ids.contains($0.id) }
        expanded.subtract(ids)
        if let s = selected, ids.contains(s) {
            selected = children(nil).first?.id
        }
        deleteOrphanFiles(files)
        scheduleSave()
        status = ids.count > 1 ? "已删除 \(ids.count) 项" : "已删除"
    }

    /// 移动：`before` 给了就插在它前面，没给就放到该层末尾
    @discardableResult
    func move(_ id: String, to parent: String?, before sibling: String? = nil) -> Bool {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return false }
        if parent == id { return false }
        if let p = parent {
            guard node(p) != nil, node(p)!.folder else { status = "只能放进文件夹里"; return false }
            guard !isDescendant(p, of: id) else {
                status = "不能把「\(nodes[i].title)」放进它自己里面"
                return false
            }
            guard depth(of: p) + 1 <= Self.maxDepth else { status = "目录最多 \(Self.maxDepth + 1) 层"; return false }
        }
        let oldParent = nodes[i].parent
        nodes[i].parent = parent
        nodes[i].updatedAt = Date().timeIntervalSince1970
        reorder(parent, moving: id, before: sibling)
        if oldParent != parent { renumber(oldParent) }
        if let p = parent { expanded.insert(p) }
        scheduleSave()
        status = "已移动「\(nodes[i].title)」"
        return true
    }

    private func reorder(_ parent: String?, moving id: String, before sibling: String?) {
        var list = children(parent).filter { $0.id != id }
        guard let moved = node(id) else { return }
        if let s = sibling, let idx = list.firstIndex(where: { $0.id == s }) {
            list.insert(moved, at: idx)
        } else {
            list.append(moved)
        }
        for (k, n) in list.enumerated() {
            if let j = nodes.firstIndex(where: { $0.id == n.id }) { nodes[j].order = k }
        }
    }

    private func renumber(_ parent: String?) {
        for (k, n) in children(parent).enumerated() {
            if let j = nodes.firstIndex(where: { $0.id == n.id }) { nodes[j].order = k }
        }
    }

    // MARK: 同级上下移（拖拽之外的兜底）

    func nudge(_ id: String, by delta: Int) {
        guard let n = node(id) else { return }
        var list = children(n.parent)
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard j >= 0, j < list.count else { status = delta < 0 ? "已经在最前面了" : "已经在最后面了"; return }
        list.swapAt(i, j)
        for (k, x) in list.enumerated() {
            if let m = nodes.firstIndex(where: { $0.id == x.id }) { nodes[m].order = k }
        }
        scheduleSave()
    }

    // MARK: 图片

    func setStatus(_ s: String) { status = s }

    /// 拖动落点：目标是文件夹就放进去，是笔记就排到它前面（跟它同级）
    func dropItem(_ id: String, on target: String) {
        guard let t = node(target) else { return }
        if t.folder { move(id, to: t.id) } else { move(id, to: t.parent, before: t.id) }
    }

    /// 正文里的图现在都进了 RTFD 包，所以这儿只剩「从剪贴板认出一张图」这一件事。
    /// 落盘那一步在 `RichEditorBridge.insertImage`（它得知道光标在哪）。
    ///
    /// 从剪贴板取图。只认「真的是图」的情况：纯文本照常交给编辑器自己贴。
    /// 拷文件时系统会塞一个 NSImage 表示，直接取会把 PDF 之类也当图存进来，所以
    /// 先看 png/tiff 数据，再看文件 URL 的扩展名白名单。
    static func imageFromPasteboard(_ pb: NSPasteboard = .general) -> NSImage? {
        if let d = pb.data(forType: .png), let i = NSImage(data: d) { return i }
        if let d = pb.data(forType: .tiff), let i = NSImage(data: d) { return i }
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] {
            let ok = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp"]
            for u in urls where ok.contains(u.pathExtension.lowercased()) {
                if let i = NSImage(contentsOf: u) { return i }
            }
        }
        return nil
    }

    // MARK: 搜索

    func searchRows() -> [(node: NoteNode, path: String)] {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else { return [] }
        return nodes
            .filter { !$0.folder && ($0.title.lowercased().contains(k) || $0.body.lowercased().contains(k)) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(60)
            .map { (node: $0, path: path(of: $0.id).joined(separator: " / ")) }
    }

    // MARK: 落盘

    func scheduleSave() {
        saveTask?.cancel()
        // Task 会继承外层的 @MainActor，所以闭包里可以直接碰 self
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let f = fileURL else { return }
        struct Doc: Codable { var version: Int = 1; var nodes: [NoteNode]; var expanded: [String] }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let doc = Doc(nodes: nodes, expanded: Array(expanded).sorted())
        guard let data = try? enc.encode(doc) else { status = "笔记保存失败：编码出错"; return }
        do {
            if let d = dir { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            try data.write(to: f, options: .atomic)
            let t = DateFormatter()
            t.dateFormat = "HH:mm"
            status = "已存 \(t.string(from: Date()))"
        } catch {
            status = "笔记保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 自检

/// `WECAL_NOTES_TEST=1` 时跑的表。全部在临时目录里做，碰不到真实笔记。
/// 记事本这种「写下去就算数」的东西，光看界面点两下证不了什么：
/// 落盘、重载、层级保护、删树连图片一起删，都得有断言行才算验过。
extension NoteStore {
    @MainActor
    static func runSelfTest() {
        var pass = 0
        var fail = 0
        func check(_ name: String, _ ok: Bool, _ extra: String = "") {
            if ok { pass += 1; say("  ✓ \(name)") } else { fail += 1; say("  ✗ \(name) \(extra)") }
        }
        func attachments(_ a: NSAttributedString) -> [NSTextAttachment] {
            var out: [NSTextAttachment] = []
            a.enumerateAttribute(.attachment, in: NSRange(location: 0, length: a.length), options: []) { v, _, _ in
                if let t = v as? NSTextAttachment { out.append(t) }
            }
            return out
        }
        func chipNames(_ a: NSAttributedString) -> [String] {
            var out: [String] = []
            a.enumerateAttribute(.link, in: NSRange(location: 0, length: a.length), options: []) { v, _, _ in
                if let u = v as? URL, let n = NoteAttachment.fileName(from: u) { out.append(n) }
            }
            return out
        }

        // 自检自带临时目录，按 base/data/notes 断言。外面再传 WECAL_NOTES_DIR
        // （那是给拍图/试拖动用的）会把目录劫走，两条落盘断言就假红了 —— 这里先清掉。
        setenv("WECAL_NOTES_DIR", "", 1)

        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shuban-notes-test-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        say("== 记事本数据层自检 ==")

        // 1. 首次打开：自动建默认笔记本
        let s = NoteStore()
        s.configure(projectDir: base)
        check("首次打开建好默认笔记本", s.nodes.count == 2 && s.noteCount == 1,
              "nodes=\(s.nodes.count) notes=\(s.noteCount)")
        check("默认笔记有欢迎正文", (s.selectedNode?.body.count ?? 0) > 50)
        let json = base.appendingPathComponent("data/notes/notes.json")
        check("notes.json 已落盘", FileManager.default.fileExists(atPath: json.path))

        // 2. 新建文件夹 / 新建笔记的落点
        let bookId = s.children(nil).first { $0.folder }?.id
        s.selected = bookId
        s.add(folder: true)
        let f2 = s.selectedNode
        check("在文件夹里新建子文件夹", f2?.parent == bookId && f2?.folder == true)
        // 再点回上一层：新建笔记要跟文件夹同级
        s.selected = bookId
        s.add(folder: false)
        let n2 = s.selectedNode
        check("新建笔记跟文件夹同级", n2?.parent == bookId && n2?.folder == false)
        // 反过来：选中文件夹时新建，就是建在它里面（跟提示文案一致）
        s.selected = f2!.id
        s.add(folder: false)
        let inner = s.selected
        check("选中文件夹时新建笔记建在它里面", s.node(inner)?.parent == f2?.id)

        // 3. 改名 / 正文
        s.rename(n2!.id, to: "  客户现场记的  ")
        check("改名去掉首尾空格", s.node(n2!.id)?.title == "客户现场记的")
        s.setBody(n2!.id, "第一段\n第二段")
        check("正文写进去了", s.node(n2!.id)?.body == "第一段\n第二段")

        // 4. 移动 + 层级保护
        let welcome = s.nodes.first { !$0.folder && $0.title == "从这里开始" }!
        check("把笔记移进子文件夹", s.move(welcome.id, to: f2!.id) && s.node(welcome.id)?.parent == f2!.id)
        check("挡住「拖进自己」", s.move(f2!.id, to: f2!.id) == false)
        check("挡住「拖进自己的子目录」", s.move(f2!.id, to: welcome.id) == false)
        check("笔记不能当文件夹用", s.move(f2!.id, to: welcome.id) == false)

        // 5. 层数上限
        var deep = bookId
        var made = 0
        for _ in 0..<12 {
            s.selected = deep
            let before = s.nodes.count
            s.add(folder: true)
            if s.nodes.count > before, let id = s.selected { deep = id; made += 1 }
        }
        check("层数到上限就停手", made <= NoteStore.maxDepth, "made=\(made) max=\(NoteStore.maxDepth)")

        // 6. 同级上下移
        s.selected = bookId
        s.add(folder: false)
        let a = s.selected!
        s.add(folder: false)
        let b = s.selected!
        let orderBefore = s.children(bookId).map(\.id)
        s.nudge(b, by: -1)
        let orderAfter = s.children(bookId).map(\.id)
        check("上移改变了同级顺序", orderBefore != orderAfter, "\(orderBefore) → \(orderAfter)")
        check("上移后两条都还在", orderAfter.contains(a) && orderAfter.contains(b))

        // 7. 正文里的图：落成 RTFD 包、读回来还在、纯文本投影里不留占位符
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let img = NSImage(size: NSSize(width: 40, height: 30))
        img.addRepresentation(rep)
        let noteID = n2!.id
        let withImg = NSMutableAttributedString(attributedString: RichText.attributed(fromPlain: "图夹在字中间"))
        if let a = img.shubanPNG().flatMap({ NoteAttachment.image($0) }) {
            withImg.append(NSAttributedString(attachment: a))
        }
        withImg.append(RichText.attributed(fromPlain: "后文"))
        s.setRichBody(noteID, withImg)
        check("正文里的图落成 rich/<id>.rtfd 包",
              s.richURL(noteID).map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        let backImg = s.attributed(noteID)
        check("图从包里读回来了", attachments(backImg).count == 1, "\(attachments(backImg).count) 个")
        check("读回来的图有尺寸（不修的话 bounds 是全 0）",
              (attachments(backImg).first?.bounds.width ?? 0) > 10)
        check("纯文本投影里没有附件占位符",
              s.node(noteID)?.body == "图夹在字中间后文",
              s.node(noteID)?.body.debugDescription ?? "nil")

        // 7b. 附件文件：拷进 files/、同名加序号、正文里只有一个芯片
        let src = base.appendingPathComponent("方案.pptx")
        try? Data("x".utf8).write(to: src)
        let f1 = s.addFile(src)
        let f2name = s.addFile(src)
        check("插文件：真拷进 files/", f1.map { s.fileExists($0) } ?? false)
        check("同名不覆盖（加序号）", f1 != nil && f2name != nil && f1 != f2name, "\(f1 ?? "nil") / \(f2name ?? "nil")")
        check("文件内容真拷过来了",
              f1.flatMap { s.fileURL($0) }.flatMap { try? Data(contentsOf: $0) }.map { $0.count == 1 } ?? false)

        let withChip = NSMutableAttributedString(attributedString: RichText.attributed(fromPlain: "附件："))
        if let f1 { withChip.append(NoteAttachment.chip(name: f1)) }
        s.setRichBody(noteID, withChip)
        check("芯片的链接能存进包再读回来", chipNames(s.attributed(noteID)) == [f1].compactMap { $0 })
        check("芯片在纯文本投影里只剩文件名", s.node(noteID)?.body == "附件：" + (f1 ?? ""))
        check("附件路径只在 files/ 里才认",
              f1 != nil && s.filePath(f1!) != nil && s.filePath("../../etc/passwd") == nil)

        // 8. 删节点连带子树（它引用的附件文件也要跟着删）
        s.selected = inner!
        let innerSrc = base.appendingPathComponent("子目录里的.docx")
        try? Data("y".utf8).write(to: innerSrc)
        let innerFile = s.addFile(innerSrc)
        let innerText = NSMutableAttributedString(attributedString: RichText.attributed(fromPlain: "带附件"))
        if let innerFile { innerText.append(NoteAttachment.chip(name: innerFile)) }
        s.setRichBody(inner!, innerText)
        let doomed = s.subtree(f2!.id).count
        s.remove(f2!.id)
        check("删文件夹连带子项", doomed >= 3 && s.node(f2!.id) == nil, "doomed=\(doomed)")
        check("子树里的条目全清了", s.node(welcome.id) == nil && s.node(inner!) == nil)
        check("子项的附件文件一起删掉",
              innerFile != nil && !s.fileExists(innerFile!), innerFile ?? "nil")
        check("不在删除范围内的附件留着", f1 != nil && s.fileExists(f1!), f1 ?? "nil")
        check("删完还能选中别的条目", s.selectedNode != nil)

        // 9. 落盘 → 重载
        s.selected = n2!.id
        s.setBody(n2!.id, "重载后应该还在")
        s.saveNow()
        let s2 = NoteStore()
        s2.configure(projectDir: base)
        check("重载后节点数一致", s2.nodes.count == s.nodes.count, "\(s2.nodes.count) vs \(s.nodes.count)")
        check("重载后正文一致", s2.node(n2!.id)?.body == "重载后应该还在")
        check("重载后层级一致", s2.node(n2!.id)?.parent == s.node(n2!.id)?.parent)
        check("重载后没有孤儿", s2.nodes.allSatisfy { $0.parent == nil || s2.node($0.parent!) != nil })

        // 10. 坏文件不装死
        try? "{ 这不是 JSON".data(using: .utf8)?.write(to: json)
        let s3 = NoteStore()
        s3.configure(projectDir: base)
        check("坏文件被另存为 notes.bad.json",
              FileManager.default.fileExists(atPath: base.appendingPathComponent("data/notes/notes.bad.json").path))

        // 12. 老数据的图（这一轮之前在正文下面那条图片条里）必须迁进正文，
        //     否则「把下面那条删掉」对老笔记就等于把图删掉了
        struct LDoc: Codable { var version = 1; var nodes: [NoteNode]; var expanded: [String] }
        let lBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shuban-notes-legacy-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let lDir = lBase.appendingPathComponent("data/notes", isDirectory: true)
        let lImgDir = lDir.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: lImgDir, withIntermediateDirectories: true)
        try? img.shubanPNG()?.write(to: lImgDir.appendingPathComponent("old-1.png"))
        let old = NoteNode(id: "L1", title: "老笔记", body: "老的正文", images: ["old-1.png"], order: 0)
        try? JSONEncoder().encode(LDoc(nodes: [old], expanded: []))
            .write(to: lDir.appendingPathComponent("notes.json"))
        let sl = NoteStore()
        sl.configure(projectDir: lBase)
        check("老笔记的图迁进了正文", sl.imageCount("L1") == 1, "\(sl.imageCount("L1")) 张")
        check("迁移后 images 清空", sl.node("L1")?.images.isEmpty == true)
        check("老正文没被动掉", sl.node("L1")?.body.contains("老的正文") == true)
        let sl2 = NoteStore()
        sl2.configure(projectDir: lBase)
        check("迁完重开图还在（说明真写进包了）", sl2.imageCount("L1") == 1,
              "图 \(sl2.imageCount("L1")) 张 · 包在=\(FileManager.default.fileExists(atPath: lDir.appendingPathComponent("rich/L1.rtfd").path)) · images=\(sl2.node("L1")?.images ?? [])")
        try? FileManager.default.removeItem(at: lBase)

        // 13. ⌘V 贴图的判定逻辑（用独立剪贴板，不动用户的）
        let pb = NSPasteboard(name: NSPasteboard.Name("shuban.notes.test"))
        pb.clearContents()
        pb.setData(img.shubanPNG() ?? Data(), forType: .png)
        check("剪贴板里是图 → 认", NoteStore.imageFromPasteboard(pb) != nil)
        pb.clearContents()
        pb.setString("只是文字", forType: .string)
        check("剪贴板里是纯文本 → 不抢（让编辑器自己粘）", NoteStore.imageFromPasteboard(pb) == nil)
        pb.releaseGlobally()

        say("== 结果：\(pass) 通过 / \(fail) 失败 ==")
        exit(fail == 0 ? 0 : 1)
    }
}

// MARK: - 小工具

extension NSImage {
    /// 转 PNG，并且超过 maxWidth 先等比缩 —— 整屏截图原样存进去，几张就上百兆。
    /// 顺手做了「TIFF 转 PNG」，所以贴图和选文件都可以走同一条路。
    func shubanPNG(maxWidth: CGFloat = 1600) -> Data? {
        var s = size
        if s.width < 1 || s.height < 1 {
            if let rep = representations.first { s = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
        }
        guard s.width >= 1, s.height >= 1 else { return nil }
        let k = min(1, maxWidth / s.width)
        let target = NSSize(width: max(1, (s.width * k).rounded()), height: max(1, (s.height * k).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(target.width),
                                         pixelsHigh: Int(target.height),
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
