import SwiftUI
import WebKit
import AppKit

// MARK: - JavaScript to intercept API calls and extract org UUID

private let orgInterceptScript = """
(function() {
    const UUID_RE = /\\/organizations\\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i;
    function notify(url) {
        if (!url) return;
        const m = url.match(UUID_RE);
        if (m && window.webkit && window.webkit.messageHandlers.orgId)
            window.webkit.messageHandlers.orgId.postMessage(m[1]);
    }
    const origFetch = window.fetch;
    window.fetch = function(...args) {
        notify(typeof args[0] === 'string' ? args[0] : args[0]?.url ?? '');
        return origFetch.apply(this, args);
    };
    const origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(method, url) {
        notify(url ?? '');
        return origOpen.apply(this, arguments);
    };
})();
"""

// Weak wrapper prevents WKUserContentController retaining Coordinator strongly (avoids leak).
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (NSObject & WKScriptMessageHandler)?
    init(_ target: NSObject & WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive msg: WKScriptMessage) {
        target?.userContentController(c, didReceive: msg)
    }
}

// MARK: - WKWebView wrapper

struct ClaudeLoginWebView: NSViewRepresentable {
    /// Called when both sessionKey and (if captured) orgId are available.
    let onSuccess: (_ sessionKey: String, _ orgId: String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSuccess: onSuccess) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Inject the org-interceptor before page scripts run
        let script = WKUserScript(source: orgInterceptScript,
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "orgId")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
        webView.load(URLRequest(url: URL(string: "https://claude.ai")!))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    // MARK: Coordinator

    final class Coordinator: NSObject, WKHTTPCookieStoreObserver, WKScriptMessageHandler {
        private let onSuccess: (String, String?) -> Void
        private var sessionKey: String?
        private var orgId: String?
        private var delivered = false

        init(onSuccess: @escaping (String, String?) -> Void) {
            self.onSuccess = onSuccess
        }

        // Called by the JS interceptor whenever an org UUID appears in a fetch/XHR URL
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "orgId", let id = message.body as? String else { return }
            orgId = id
            tryDeliver()
        }

        // Called when cookies change — we watch for sessionKey
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            cookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                guard let sk = cookies.first(where: {
                    $0.domain.hasSuffix("claude.ai") && $0.name == "sessionKey"
                }) else { return }
                DispatchQueue.main.async {
                    self.sessionKey = sk.value
                    self.tryDeliver()
                }
            }
        }

        private func tryDeliver() {
            guard !delivered, let sk = sessionKey else { return }
            delivered = true
            DispatchQueue.main.async { self.onSuccess(sk, self.orgId) }
        }
    }
}

// MARK: - Login sheet content

struct LoginSheetView: View {
    @EnvironmentObject var model: UsageModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Log in to Claude.ai")
                        .font(.headline)
                    Text("Session and org ID stored securely in Keychain / UserDefaults.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { LoginWindowController.dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding()

            Divider()

            ClaudeLoginWebView { sessionKey, orgId in
                Task { await model.handleLogin(sessionKey: sessionKey, orgId: orgId) }
                LoginWindowController.dismiss()
            }
        }
        .frame(width: 540, height: 700)
    }
}

// MARK: - Window controller

final class LoginWindowController: NSObject, NSWindowDelegate {
    private static var current: LoginWindowController?
    private let wc: NSWindowController

    private init(model: UsageModel) {
        let hosting = NSHostingController(rootView: LoginSheetView().environmentObject(model))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Log in to Claude.ai"
        win.setContentSize(NSSize(width: 540, height: 700))
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        wc = NSWindowController(window: win)
        super.init()
        win.delegate = self
    }

    static func present(model: UsageModel) {
        if let existing = current {
            existing.wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let c = LoginWindowController(model: model)
        current = c
        c.wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func dismiss() {
        current?.wc.window?.close()
        current = nil
    }

    func windowWillClose(_ notification: Notification) {
        LoginWindowController.current = nil
    }
}
