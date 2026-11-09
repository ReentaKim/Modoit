import AppKit
import ModoitCore
import WebKit

/// v0.3 TipTap 편집기(editor-host 번들)를 WKWebView로 띄우고 메시지로 잇는다.
/// 계약: docs/dev/architecture-v2.md 4장
@MainActor
final class WebEditor: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    let vault: Vault
    var onChange: ((String) -> Void)?
    /// 문서를 다 그렸을 때 (load 한 번마다)
    var onLoaded: (() -> Void)?
    private var isReady = false
    private var pending: [String: Any]?

    init(vault: Vault) {
        self.vault = vault
        let config = WKWebViewConfiguration()
        let schemes = SchemeHandler(vault: vault)
        config.setURLSchemeHandler(schemes, forURLScheme: "modoit-app")
        config.setURLSchemeHandler(schemes, forURLScheme: "modoit-file")
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(WeakMessageHandler(self), name: "modoit")
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.load(URLRequest(url: URL(string: "modoit-app://editor/index.html")!))
    }

    func load(markdown: String, notePath: String?, compact: Bool, accent: String = "yellow") {
        let doc: [String: Any] = [
            "markdown": markdown,
            "notePath": notePath as Any? ?? NSNull(),
            "vault": vault.root.path,
            "compact": compact,
            "accent": accent,
        ]
        if isReady { send(doc) } else { pending = doc }
    }

    private func send(_ doc: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: doc),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.modoit.load(\(json))")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            if let p = pending { pending = nil; send(p) }
        case "loaded":
            onLoaded?()
        case "change":
            if let md = body["markdown"] as? String { onChange?(md) }
        case "invoke":
            handleInvoke(body)
        case "readOnly":
            print("[editor] 읽기 전용:", body["reasons"] ?? "")
        case "error":
            print("[editor] 오류:", body["message"] ?? "")
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
                try vault.saveAttachment(notePath: args["notePath"] as? String ?? "",
                                         fileName: args["fileName"] as? String ?? "",
                                         dataBase64: args["dataBase64"] as? String ?? "")
            }
        default:
            result = .failure(VaultError("지원하지 않는 명령: \(cmd)"))
        }
        let (ok, value): (Bool, String) = switch result {
        case .success(let v): (true, v)
        case .failure(let e): (false, String(describing: e))
        }
        let encoded = (try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        webView.evaluateJavaScript("window.modoit.settleInvoke(\(id), \(ok), \(encoded))")
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
/// modoit-file://local/<절대 경로> → 저장 폴더 안 파일만 (v0.3 asset 프로토콜 범위와 같다)
@MainActor
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    let vault: Vault
    init(vault: Vault) { self.vault = vault }

    static let editorDir: URL = {
        if let u = Bundle.main.url(forResource: "editor", withExtension: nil) { return u }
        return Bundle.module.url(forResource: "editor", withExtension: nil)!
    }()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = fileURL(for: url),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let headers = ["Content-Type": mime(file.pathExtension), "Access-Control-Allow-Origin": "*"]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func fileURL(for url: URL) -> URL? {
        let path = url.path(percentEncoded: false)
        switch url.scheme {
        case "modoit-app":
            let base = Self.editorDir.standardizedFileURL
            let f = base.appending(path: String(path.drop { $0 == "/" })).standardizedFileURL
            return f.path.hasPrefix(base.path + "/") ? f : nil
        case "modoit-file":
            let f = URL(filePath: path).resolvingSymlinksInPath()
            let base = vault.root.resolvingSymlinksInPath().path
            return f.path.hasPrefix(base + "/") ? f : nil
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
