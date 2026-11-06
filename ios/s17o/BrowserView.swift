import Foundation
import SwiftUI
import WebKit

// ---------------------------------------------------------------------------
// DOM snapshot types (shared with macOS)
// ---------------------------------------------------------------------------

struct PageSnapshotEnvelope: Decodable {
    struct Page: Decodable {
        let title: String
        let url: String
        let headings: [String]
        let highlights: [String]
        let visibleText: String
        let visibilityState: String?
        let links: [VisibleLink]?
    }
    let type: String
    let page: Page
    let sentAt: Double?
}

struct VisibleLink: Decodable, Equatable {
    let text: String
    let href: String
}

// ---------------------------------------------------------------------------
// BrowserController
// ---------------------------------------------------------------------------

@MainActor
final class BrowserController: NSObject, ObservableObject {
    @Published var pageTitle = ""
    @Published var pageURL = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false

    let webView: WKWebView

    var onSnapshot: ((PageSnapshotEnvelope) -> Void)?

    // JavaScript を注入して DOM snapshot を定期送信させる
    private static let injectionScript = """
        (function () {
            if (window.__s17oInjected) return;
            window.__s17oInjected = true;

            function collectLinks() {
                return Array.from(document.querySelectorAll('a[href]'))
                    .slice(0, 200)
                    .map(a => ({ text: a.textContent.trim().slice(0, 120), href: a.href }))
                    .filter(l => l.href.startsWith('http'));
            }

            function collectHighlights() {
                const sel = [
                    '[class*="score"]','[class*="inning"]','[class*="batter"]',
                    '[class*="pitcher"]','[class*="linescore"]','[class*="gameday"]',
                    '[class*="schedule"]','[class*="team"]','[class*="broadcast"]',
                    'h1','h2','h3',
                ].join(',');
                return Array.from(document.querySelectorAll(sel))
                    .map(el => el.textContent.trim())
                    .filter(t => t.length > 0 && t.length < 300)
                    .slice(0, 60);
            }

            function snapshot() {
                const payload = {
                    type: 's17oPageSnapshot',
                    sentAt: Date.now(),
                    page: {
                        title: document.title,
                        url: location.href,
                        visibilityState: document.visibilityState,
                        headings: Array.from(document.querySelectorAll('h1,h2,h3'))
                            .map(h => h.textContent.trim()).filter(t => t.length > 0).slice(0, 30),
                        highlights: collectHighlights(),
                        visibleText: (document.body ? document.body.innerText : '').slice(0, 8000),
                        links: collectLinks(),
                    }
                };
                window.webkit.messageHandlers.s17oSnapshot.postMessage(JSON.stringify(payload));
            }

            snapshot();

            const observer = new MutationObserver(() => {
                clearTimeout(window.__s17oTimer);
                window.__s17oTimer = setTimeout(snapshot, 800);
            });
            observer.observe(document.body || document.documentElement, {
                childList: true, subtree: true, characterData: true
            });
        })();
        """

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        super.init()

        let userScript = WKUserScript(
            source: Self.injectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        webView.configuration.userContentController.addUserScript(userScript)
        webView.configuration.userContentController.add(self, name: "s17oSnapshot")
        webView.navigationDelegate = self
    }

    func navigate(to url: URL) {
        webView.load(URLRequest(url: url))
    }

    func goBack()    { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload()    { webView.reload() }

    // DOM 内の video/audio をミュート制御する
    func setMediaMuted(_ muted: Bool) async throws {
        let js = """
            (() => {
              const media = Array.from(document.querySelectorAll('video, audio'));
              if (media.length === 0) throw new Error('ページ内に media 要素がありません。');
              for (const item of media) item.muted = \(muted ? "true" : "false");
              return String(media.length);
            })();
            """
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// WKNavigationDelegate
// ---------------------------------------------------------------------------

extension BrowserController: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        Task { @MainActor in
            self.isLoading = true
            self.pageURL = webView.url?.absoluteString ?? ""
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        Task { @MainActor in
            self.isLoading = false
            self.pageTitle = webView.title ?? ""
            self.pageURL = webView.url?.absoluteString ?? ""
            self.canGoBack = webView.canGoBack
            self.canGoForward = webView.canGoForward
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
        Task { @MainActor in self.isLoading = false }
    }
}

// ---------------------------------------------------------------------------
// WKScriptMessageHandler — DOM snapshot 受信
// ---------------------------------------------------------------------------

extension BrowserController: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "s17oSnapshot",
              let json = message.body as? String,
              let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(PageSnapshotEnvelope.self, from: data)
        else { return }

        Task { @MainActor in
            self.onSnapshot?(envelope)
        }
    }
}

// ---------------------------------------------------------------------------
// SwiftUI ラッパー
// ---------------------------------------------------------------------------

struct BrowserView: UIViewRepresentable {
    let controller: BrowserController

    func makeUIView(context: Context) -> WKWebView {
        controller.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
