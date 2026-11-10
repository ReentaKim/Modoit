import AppKit
import ModoitCore
import ModoitKit
import Observation

/// 사이드바에서 고른 것
enum SidebarSelection: Hashable {
    case all
    case favorites
    case folder(String)

    var scope: NoteScope {
        switch self {
        case .all: .all
        case .favorites: .favorites
        case .folder(let p): .folder(p)
        }
    }

    /// 다시 켤 때 복원하려고 적어 두는 글자 (FR-53)
    var stored: String {
        switch self {
        case .all: "all"
        case .favorites: "favorites"
        case .folder(let p): "folder:" + p
        }
    }

    init(stored: String?) {
        switch stored {
        case "favorites": self = .favorites
        case let s? where s.hasPrefix("folder:"): self = .folder(String(s.dropFirst(7)))
        default: self = .all
        }
    }
}

/// 실행 옵션 (개발·검사용)
///   --config-dir <폴더>   config.json을 둘 곳. 없으면 앱 설정 폴더
///   --vault <폴더>        저장 폴더(설정에 저장하지 않는다)
///   --selftest 1          화면을 실제로 조작해 검사하고 끝낸다. --log <파일>, --snapshot <png>
struct LaunchOptions {
    var configDir: String?
    var vault: String?
    var selfTest = false
    var snapshot: String?
    var log: String?
    /// 선택이 바뀔 때마다 적는 파일(검사용)
    var stateFile: String?

    static let current = parse(CommandLine.arguments)

    static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--config-dir": o.configDir = it.next()
            case "--vault": o.vault = it.next()
            // 값이 없는 인자를 두면 AppKit이 그 뒤 인자를 "열 파일"로 보고 기본 창을 띄우지 않는다. 그래서 늘 값을 받는다
            case "--selftest": o.selfTest = it.next() == "1"
            case "--snapshot": o.snapshot = it.next()
            case "--log": o.log = it.next()
            case "--state-file": o.stateFile = it.next()
            default: break
            }
        }
        return o
    }
}

@MainActor @Observable
final class AppModel {
    private(set) var config: Config
    private(set) var tree = Tree(folders: [], notes: [], layout: Layout())
    var selection: SidebarSelection = .all {
        didSet { if selection != oldValue { rememberSelection() } }
    }
    private(set) var selectedNote: String?
    var query = ""
    var collapsed: Set<String> = []
    /// 잠깐 보이는 안내
    private(set) var notice: String?
    /// 지금 메모의 지원하지 않는 서식. 비어 있지 않으면 읽기 전용 (FR-43)
    private(set) var unsupported: [String] = []
    /// 지금 메모를 저장하지 못하고 있다 (NFR-13)
    private(set) var saveFailing = false
    /// UTF-8이 아니라 열 수 없는 메모를 골랐다 (BUG-19)
    private(set) var notUTF8 = false
    /// 편집기가 문서를 그린 횟수(검사용)
    private(set) var loadedCount = 0
    /// 메뉴가 화면에 시키는 일. 값이 바뀌면 그 화면이 반응한다
    private(set) var newFolderRequest = 0
    private(set) var findRequest = 0

    @ObservationIgnored let editor = WebEditor()
    @ObservationIgnored private(set) var store: SessionStore?
    @ObservationIgnored private(set) var session: NoteSession?
    @ObservationIgnored private let editorID = EditorID()
    @ObservationIgnored let configPath: String
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var watcher: VaultWatcher?
    /// 메인 창을 보인다(닫혀 있으면 다시 연다). AppDelegate가 채운다
    @ObservationIgnored var showMainWindow: () -> Void = {}
    @ObservationIgnored private var noticeGeneration = 0
    /// 지난 종료를 저장 실패로 멈췄다. 이번에는 그대로 끝낸다 (F-12 R-2)
    @ObservationIgnored var quitForced = false

    var vault: String? { config.vault }
    var prefs: Prefs { config.prefs }

    init(options: LaunchOptions = .current) {
        let dir = options.configDir ?? Self.defaultConfigDir()
        configPath = dir + "/config.json"
        config = Config.load(from: configPath)
        editor.onChange = { [weak self] md, base in self?.editorChanged(md, base: base) }
        editor.onOpened = { [weak self] reasons in self?.unsupported = reasons }
        editor.onLoaded = { [weak self] in self?.loadedCount += 1 }
        editor.onError = { [weak self] m in self?.show(notice: m) }
        applyAppearance()
        if let v = options.vault {
            open(vault: v, remember: false)
        } else if let v = config.vault, isDir(v) {
            open(vault: v, remember: false)
        } else {
            config.vault = nil
        }
    }

    private static func defaultConfigDir() -> String {
        let base = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first ?? NSHomeDirectory()
        // 앱 ID가 폴더 이름이다. 개발판(.dev)은 정식판의 설정을 건드리지 않는다
        return base + "/" + (Bundle.main.bundleIdentifier ?? "io.github.reentakim.modoit.dev")
    }

    private func isDir(_ path: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }

    // MARK: 저장 폴더 (F-01)

    func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "선택"
        panel.message = "메모를 저장할 폴더를 고르세요"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 고른 폴더의 경로를 디스크에 있는 이름 그대로 쓴다
        let path = url.withUnsafeFileSystemRepresentation { $0.flatMap { realpath($0, nil) } }.map { p -> String in
            defer { free(p) }
            return String(cString: p)
        } ?? url.path
        open(vault: path, remember: true)
    }

    func open(vault path: String, remember: Bool) {
        if let old = config.vault, old == path, store != nil { return }
        // 바꾸기 전에 남은 입력을 저장한다 (F-01 R-3)
        if let store, store.flushAll() > 0 {
            show(notice: "저장하지 못한 메모가 있어 저장 폴더를 바꾸지 않았습니다.")
            return
        }
        closeSession()
        config.vault = path
        if remember { saveConfig() }
        editor.vault = path
        let s = SessionStore(vault: path)
        s.onSaved = { [weak self] in self?.scheduleRefresh() }
        s.onState = { [weak self] in self?.updateFailing() }
        s.onRenamed = { [weak self] old, new in self?.noteRenamed(old, new) }
        store = s
        // 다른 앱이 바꾼 것을 목록과 열린 메모에 반영한다 (FR-22)
        watcher?.stop()
        watcher = VaultWatcher(vault: path) { [weak self] paths in
            self?.store?.diskChanged(paths.isEmpty ? nil : paths)
            self?.scheduleRefresh()
        }
        // 기본 폴더 `메모/`가 없으면 만든다 (F-01 4.1)
        _ = try? createFolderIfMissing(path)
        refresh()
        restoreSelection()
    }

    private func createFolderIfMissing(_ vault: String) throws {
        if !isDir(vault + "/" + defaultFolder) { _ = try ModoitCore.createFolder(vault: vault, parent: "", name: defaultFolder) }
    }

    private func saveConfig() {
        do {
            try config.save(to: configPath)
        } catch {
            show(notice: "설정을 저장하지 못했습니다: \(error)")
        }
    }

    // MARK: 목록

    func refresh() {
        guard let vault else { return }
        if let t = try? listTree(vault: vault) { tree = t }
        if let sel = selectedNote, !tree.notes.contains(where: { $0.path == sel }), session?.busy != true {
            // 다른 앱에서 지워졌다
            if session == nil || !noteExists(vault: vault, sel) { selectNote(nil) }
        }
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    var sort: NoteSort { NoteSort(rawValue: prefs.noteSort) ?? .modified }

    var groups: [NoteGroup] {
        groupNotes(filterNotes(tree.notes, scope: selection.scope, query: query), sort: sort)
    }

    var sidebarRows: [SidebarRow] { flattenTree(tree.folders, tree.layout, collapsed: collapsed) }

    func count(in folder: String) -> Int { tree.notes.count { $0.folder == folder } }
    var favoriteCount: Int { tree.notes.count(where: \.pinned) }
    /// 떠 있는 스티키만 (F-08 FR-31)
    var openStickies: [NoteMeta] { tree.notes.filter { $0.sticky?.open == true } }
    var selectedMeta: NoteMeta? { tree.notes.first { $0.path == selectedNote } }

    // MARK: 메모 열기 (F-06 4.3)

    func selectNote(_ path: String?) {
        guard path != selectedNote else { return }
        closeSession()
        selectedNote = path
        rememberSelection()
        guard let path, let store else { return }
        openSession(store, path, focus: false)
    }

    private func openSession(_ store: SessionStore, _ path: String, createdNew: Bool = false, focus: Bool, forceEditable: Bool = false) {
        do {
            let s = try store.open(path, createdNew: createdNew)
            session = s
            s.attach(editorID) { [weak self] body in self?.editor.update(markdown: body) }
            editor.load(markdown: s.body, notePath: s.path, forceEditable: forceEditable, focus: focus, prefs: prefs)
            updateFailing()
        } catch let e as VaultError where e == .notUTF8 {
            notUTF8 = true
        } catch {
            show(notice: "메모를 열 수 없습니다: \(error)")
            selectedNote = nil
        }
    }

    private func closeSession() {
        notUTF8 = false
        unsupported = []
        saveFailing = false
        guard let s = session, let store else { return }
        session = nil
        store.detach(editorID, from: s)
        if s.busy {
            show(notice: "이전 메모를 아직 저장하지 못했습니다. 저장될 때까지 계속 다시 시도합니다.")
        } else if s.createdNew, s.body.allSatisfy(\.isWhitespace), let vault {
            // 이번 실행에서 앱이 만든 빈 메모만 정리한다 (Brief 3.3-2)
            store.discardUnder(s.path)
            try? trashPath(vault + "/" + s.path)
            scheduleRefresh()
        }
    }

    /// "그래도 편집" (FR-43)
    func editAnyway() {
        guard let s = session else { return }
        unsupported = []
        editor.load(markdown: s.body, notePath: s.path, forceEditable: true, focus: true, prefs: prefs)
        show(notice: "편집하면 지원하지 않는 서식은 바뀔 수 있습니다.")
    }

    private func editorChanged(_ markdown: String, base: String) {
        session?.edit(markdown, basedOn: base, from: editorID)
    }

    private func noteRenamed(_ old: String, _ new: String) {
        if selectedNote == old {
            selectedNote = new
            editor.moved(to: new)
            rememberSelection()
        }
        scheduleRefresh()
    }

    private func updateFailing() {
        saveFailing = session?.failure != nil
    }

    // MARK: 메모 만들기·지우기·즐겨찾기 (F-05, F-04)

    func newNote() {
        guard let vault, let store else { return }
        let folder: String = { if case .folder(let p) = selection { return p } else { return "" } }()
        do {
            let path = try createNote(vault: vault, folder: folder)
            // 새 메모가 목록에서 안 보이는 일을 막는다 (F-09 R-3)
            query = ""
            if case .favorites = selection { selection = .all }
            closeSession()
            refresh()
            selectedNote = path
            rememberSelection()
            openSession(store, path, createdNew: true, focus: true)
        } catch {
            show(notice: "메모를 만들 수 없습니다: \(error)")
        }
    }

    func trash(note path: String) {
        guard let vault, let store else { return }
        // 다음 메모를 고른다 (F-05)
        let flat = groups.flatMap(\.notes).map(\.path)
        let next: String? = flat.firstIndex(of: path).flatMap { i in
            i + 1 < flat.count ? flat[i + 1] : (i > 0 ? flat[i - 1] : nil)
        }
        if selectedNote == path {
            if let s = session { session = nil; s.detach(editorID) }
            selectedNote = nil
        }
        // 저장하면 지운 파일이 다시 생긴다 (Brief 3.3-4)
        store.discardUnder(path)
        do {
            try trashPath(vault + "/" + path)
        } catch {
            show(notice: "휴지통으로 보낼 수 없습니다: \(error)")
        }
        refresh()
        if selectedNote == nil { selectNote(next) }
    }

    func setFavorite(_ path: String, _ on: Bool) {
        guard let vault, let store else { return }
        // 입력 중인 본문을 먼저 저장한다. 저장하며 이름이 바뀔 수 있다 (F-04 R-5, BUG-28)
        let s = store.existing(path)
        s?.flush()
        do {
            try patchMeta(vault: vault, s?.path ?? path, MetaPatch(pinned: on))
        } catch {
            show(notice: "즐겨찾기를 바꿀 수 없습니다: \(error)")
        }
        refresh()
    }

    func toggleFavoriteOfSelected() {
        if let n = selectedMeta { setFavorite(n.path, !n.pinned) }
    }

    func setSort(_ s: NoteSort) {
        updatePrefs { $0.noteSort = s.rawValue }
    }

    // MARK: 설정 (F-10)

    /// 설정을 바꾸고 저장하고 모든 화면에 바로 적용한다 (Brief 3.7)
    func updatePrefs(_ change: (inout Prefs) -> Void) {
        var p = config.prefs
        change(&p)
        p = p.normalized()
        guard p != config.prefs else { return }
        config.prefs = p
        saveConfig()
        applyAppearance()
        editor.apply(prefs: p)
    }

    /// 모양: 앱 전체에 건다. 메인 창이 숨어 있어도, 메뉴와 대화상자에도 바로 적용된다 (FR-45)
    private func applyAppearance() {
        NSApplication.shared.appearance = switch prefs.theme {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }

    // MARK: 창 제목, Finder

    /// 창 제목: 지금 고른 사이드바 항목 (F-02 R-4)
    var windowTitle: String {
        guard vault != nil else { return "Modoit" }
        switch selection {
        case .all: return "모든 메모"
        case .favorites: return "즐겨찾기"
        case .folder(let p): return (p as NSString).lastPathComponent
        }
    }

    var windowSubtitle: String {
        vault == nil ? "" : "\(groups.reduce(0) { $0 + $1.notes.count })개의 메모"
    }

    /// Finder에서 그 파일·폴더를 골라 보인다. nil이면 저장 폴더를 연다. 파일을 쓰지 않는다
    func revealInFinder(_ rel: String?) {
        guard let vault else { return }
        if let rel {
            NSWorkspace.shared.selectFile(vault + "/" + rel, inFileViewerRootedAtPath: "")
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: vault))
        }
    }

    // MARK: 메뉴 (F-11)

    /// 결과가 메인 창에 보여야 하는 명령은 메인 창을 먼저 보인다 (F-11 R-1)
    func menuNewNote() { showMainWindow(); newNote() }
    func menuNewFolder() { showMainWindow(); updatePrefs { $0.sidebarCollapsed = false }; newFolderRequest += 1 }
    func menuFind() { showMainWindow(); findRequest += 1 }
    func menuChooseVault() { showMainWindow(); chooseVault() }
    func menuToggleSidebar() { showMainWindow(); updatePrefs { $0.sidebarCollapsed.toggle() } }

    // MARK: 폴더 (F-03)

    private func fail(_ what: String, _ error: Error) {
        show(notice: "\(what): \(error)")
    }

    /// 이름 변경·이동(from → to)을 선택, 펼침 상태, 열린 세션에 반영한다 (F-03 R-4)
    private func pathMoved(from: String, to: String) {
        func remap(_ p: String) -> String? {
            if p == from { return to }
            if p.hasPrefix(from + "/") { return to + p.dropFirst(from.count) }
            return nil
        }
        store?.applyMove(from: from, to: to)
        if case .folder(let p) = selection, let np = remap(p) { selection = .folder(np) }
        if let n = selectedNote, let np = remap(n) {
            selectedNote = np
            editor.moved(to: np)
            rememberSelection()
        }
        collapsed = Set(collapsed.map { remap($0) ?? $0 })
    }

    func createFolder(parent: String, name: String) {
        guard let vault else { return }
        do {
            let p = try ModoitCore.createFolder(vault: vault, parent: parent, name: name)
            collapsed.remove(parent)
            refresh()
            selection = .folder(p)
        } catch {
            fail("폴더를 만들 수 없습니다", error)
        }
    }

    func renameFolder(_ path: String, to name: String) {
        guard let vault, let store else { return }
        store.flushAll()
        do {
            let np = try ModoitCore.renameFolder(vault: vault, path, to: name)
            if np != path { pathMoved(from: path, to: np) }
            refresh()
        } catch {
            fail("이름을 바꿀 수 없습니다", error)
        }
    }

    /// 그 폴더와 하위 폴더에 든 메모 수(삭제 확인에 쓴다)
    func noteCount(under path: String) -> Int {
        tree.notes.count { $0.folder == path || $0.folder.hasPrefix(path + "/") }
    }

    /// 폴더를 휴지통으로. 메모가 있으면 `confirmed`가 true여야 한다 (FR-26)
    func trashFolder(_ path: String) {
        guard let vault, let store else { return }
        store.flushAll()
        // 그 안 메모의 세션은 저장 없이 닫는다 (Brief 3.3-4)
        if let n = selectedNote, n.hasPrefix(path + "/") {
            if let s = session { session = nil; s.detach(editorID) }
            selectedNote = nil
        }
        store.discardUnder(path)
        do {
            try ModoitCore.trashFolder(vault: vault, path)
        } catch {
            fail("휴지통으로 보낼 수 없습니다", error)
        }
        if case .folder(let p) = selection, p == path || p.hasPrefix(path + "/") { selection = .all }
        refresh()
    }

    func setLayout(_ layout: Layout) {
        guard let vault else { return }
        do {
            try saveLayout(vault: vault, layout)
        } catch {
            fail("순서를 저장할 수 없습니다", error)
        }
        refresh()
    }

    /// 폴더를 끌어 놓았다. destParent 안의 before 앞(nil이면 맨 뒤)에. into = 폴더 위에 놓아 안으로 옮긴 것 (FR-27)
    func moveFolder(_ path: String, toParent destParent: String, before: String?, into: Bool) {
        guard let vault, let store else { return }
        // 자기 자신·하위 폴더 안으로는 옮길 수 없다
        if destParent == path || destParent.hasPrefix(path + "/") { return }
        var name = (path as NSString).lastPathComponent
        do {
            if parentRel(path) != destParent {
                store.flushAll()
                let m = try moveEntry(vault: vault, from: path, toFolder: destParent)
                name = (m.to as NSString).lastPathComponent
                pathMoved(from: m.from, to: m.to)
            }
            let t = try listTree(vault: vault)
            try saveLayout(vault: vault, reorder(t.folders, t.layout, parent: destParent, key: name, before: before, into: into))
            if into { collapsed.remove(destParent) }
        } catch {
            fail("폴더를 옮길 수 없습니다", error)
        }
        refresh()
    }

    func moveSeparator(_ id: String, from fromParent: String, toParent destParent: String, before: String?) {
        var l = tree.layout
        if fromParent != destParent {
            // 옛 부모의 현재 순서를 고정한 뒤 빼낸다
            l.order[fromParent] = customSequence(parent: fromParent, childrenOf(tree.folders, parent: fromParent), l).map(\.key)
            l = removeKey(l, parent: fromParent, key: id)
        }
        setLayout(reorder(tree.folders, l, parent: destParent, key: id, before: before))
    }

    /// 메모를 폴더로 끌어 옮긴다. 이미지 링크를 새 위치 기준으로 고친다 (FR-36)
    func moveNote(_ path: String, toFolder dest: String) {
        guard let vault, let store else { return }
        // 입력을 먼저 저장한다. 저장하며 이름이 바뀔 수 있으므로 저장 뒤의 경로를 쓴다 (BUG-28)
        let s = store.existing(path)
        s?.flush()
        let current = s?.path ?? path
        if parentRel(current) == dest { return }
        do {
            let m = try moveEntry(vault: vault, from: current, toFolder: dest)
            pathMoved(from: m.from, to: m.to)
            // 옮기면서 링크를 고쳐 썼다. 열려 있는 편집기에 새 내용을 보여 준다
            store.diskChanged([m.to])
        } catch {
            fail("메모를 옮길 수 없습니다", error)
        }
        refresh()
    }

    // MARK: 다시 켜면 이어서 (FR-53)

    private var defaultsKey: String { "last:" + (vault ?? "") }

    private func rememberSelection() {
        guard vault != nil else { return }
        UserDefaults.standard.set(["selection": selection.stored, "note": selectedNote ?? ""], forKey: defaultsKey)
        if let f = LaunchOptions.current.stateFile {
            try? "\(selection.stored) | \(selectedNote ?? "-")\n".write(toFile: f, atomically: true, encoding: .utf8)
        }
    }

    private func restoreSelection() {
        let saved = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]
        var sel = SidebarSelection(stored: saved?["selection"])
        // 폴더가 없어졌으면 "모든 메모" (FR-53)
        if case .folder(let p) = sel, findNode(tree.folders, p) == nil { sel = .all }
        selection = sel
        selectedNote = nil
        if let note = saved?["note"], !note.isEmpty, tree.notes.contains(where: { $0.path == note }) {
            selectNote(note)
        }
    }

    // MARK: 종료 (F-12)

    /// 모든 메모를 저장한다. 저장하지 못한 메모 수
    func flushForQuit() -> Int { store?.flushAll() ?? 0 }

    func show(notice text: String, seconds: Double = 4) {
        notice = text
        noticeGeneration += 1
        let g = noticeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.noticeGeneration == g { self?.notice = nil }
        }
    }
}
