import AppKit
import ModoitCore
import WebKit

/// v0.x의 TipTap 편집기(editor-host 번들)를 WKWebView로 띄우고 메시지로 잇는다 (아키텍처 3.4).
@MainActor
final class WebEditor: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    /// 사용자가 본문을 고쳤다: (새 본문, 편집기가 알던 이전 본문)
    var onChange: ((String, String) -> Void)?
    /// 문서를 열었다. 지원하지 않는 서식 이름들(비어 있으면 편집 가능, FR-43)
    var onOpened: (([String]) -> Void)?
    /// 문서를 다 그렸다
    var onLoaded: (() -> Void)?
    var onError: ((String) -> Void)?
    /// 보기 전용(스티키)에서 n번째 체크박스를 눌렀다: (순서, 바꿀 상태)
    var onCheck: ((Int, Bool) -> Void)?
    /// 보기 전용(스티키)에서 두 번 눌렀다
    var onOpen: (() -> Void)?
    /// 저장 폴더의 절대 경로. 이미지와 첨부 저장의 범위다
    var vault: String? {
        didSet { schemes.vault = vault }
    }

    private let schemes = SchemeHandler()
    private var isReady = false
    private var pending: [String]?

    override init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemes, forURLScheme: "modoit-app")
        config.setURLSchemeHandler(schemes, forURLScheme: "modoit-file")
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(WeakMessageHandler(self), name: "modoit")
        // 창 배경은 Swift가 그린다
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.load(URLRequest(url: URL(string: "modoit-app://editor/index.html")!))
    }

    private func json(_ obj: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: obj, options: .fragmentsAllowed)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    private func run(_ js: String) {
        if isReady { webView.evaluateJavaScript(js) } else { pending = (pending ?? []) + [js] }
    }

    func load(markdown: String, notePath: String?, compact: Bool = false, forceEditable: Bool = false, focus: Bool = false,
              viewer: Bool = false, prefs: Prefs) {
        var doc: [String: Any] = [
            "markdown": markdown,
            "notePath": notePath as Any? ?? NSNull(),
            "vault": vault ?? "",
            "compact": compact,
            "forceEditable": forceEditable,
            "focus": focus,
            "viewer": viewer,
        ]
        doc["prefs"] = prefsObject(prefs)
        run("window.modoit.load(\(json(doc)))")
    }

    /// 다른 편집기나 다른 앱이 본문을 바꿨다
    func update(markdown: String) {
        run("window.modoit.update(\(json(["markdown": markdown])))")
    }

    func apply(prefs: Prefs) {
        run("window.modoit.prefs(\(json(prefsObject(prefs))))")
    }

    func moved(to notePath: String) {
        run("window.modoit.moved(\(json(notePath)))")
    }

    private func prefsObject(_ p: Prefs) -> Any {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(p))) ?? [:]
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            for js in pending ?? [] { webView.evaluateJavaScript(js) }
            pending = nil
        case "opened":
            onOpened?(body["unsupported"] as? [String] ?? [])
        case "loaded":
            onLoaded?()
        case "change":
            if let md = body["markdown"] as? String { onChange?(md, body["base"] as? String ?? md) }
        case "check":
            if let i = body["index"] as? Int, let on = body["checked"] as? Bool { onCheck?(i, on) }
        case "open":
            onOpen?()
        case "invoke":
            handleInvoke(body)
        case "error":
            onError?(body["message"] as? String ?? "")
        default:
            break
        }
    }

    private func handleInvoke(_ body: [String: Any]) {
        guard let id = body["id"] as? Int, let cmd = body["cmd"] as? String else { return }
        let args = body["args"] as? [String: Any] ?? [:]
        let result: Result<String, Error>
        switch cmd {
        case "save_attachment":
            result = Result {
                guard let vault else { throw VaultError("저장 폴더가 없습니다") }
                return try saveAttachment(vault: vault, notePath: args["notePath"] as? String ?? "",
                                          fileName: args["fileName"] as? String ?? "",
                                          dataBase64: args["dataBase64"] as? String ?? "")
            }
        default:
            result = .failure(VaultError("지원하지 않는 명령: \(cmd)"))
        }
        switch result {
        case .success(let v): webView.evaluateJavaScript("window.modoit.settleInvoke(\(id), true, \(json(v)))")
        case .failure(let e): webView.evaluateJavaScript("window.modoit.settleInvoke(\(id), false, \(json(String(describing: e))))")
        }
    }
}

/// WKUserContentController가 핸들러를 강하게 잡아 생기는 순환 참조를 끊는다
@MainActor
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

/// modoit-app://editor/… → 앱에 넣은 편집기 번들
/// modoit-file://local/<절대 경로> → 저장 폴더 안 파일만 (Brief 3.1-4)
/// 외부 주소는 내주지 않는다 (Brief 3.5-3)
@MainActor
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    var vault: String?

    static let editorDir: String = {
        let u = Bundle.main.url(forResource: "editor", withExtension: nil) ?? Bundle.module.url(forResource: "editor", withExtension: nil)!
        return u.resolvingSymlinksInPath().path
    }()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = filePath(for: url), let data = FileManager.default.contents(atPath: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let headers = ["Content-Type": mime((file as NSString).pathExtension), "Access-Control-Allow-Origin": "*"]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func inside(_ path: String, _ base: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        let p = String(cString: real)
        guard let rb = realpath(base, nil) else { return nil }
        defer { free(rb) }
        let b = String(cString: rb)
        return p.hasPrefix(b + "/") ? p : nil
    }

    private func filePath(for url: URL) -> String? {
        let path = url.path(percentEncoded: false)
        switch url.scheme {
        case "modoit-app":
            return inside(Self.editorDir + "/" + path.drop { $0 == "/" }, Self.editorDir)
        case "modoit-file":
            guard let vault else { return nil }
            return inside(path, vault)
        default:
            return nil
        }
    }

    private func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "bmp": "image/bmp"
        case "tiff": "image/tiff"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }
}
