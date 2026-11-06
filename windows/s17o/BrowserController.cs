using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using System.Text.Json;
using System.Windows;

namespace s17o;

/// <summary>
/// WebView2 を使って local DOM を full control するモジュール。
/// Edge built-in AI (window.ai / Prompt API) 経由で on-device 推論を行う。
/// </summary>
public sealed class BrowserController
{
    private readonly WebView2 _webView;

    public bool IsAiAvailable { get; private set; }

    /// <summary>DOM スナップショットを受信したときに発火。</summary>
    public event EventHandler<PageSnapshotEnvelope>? SnapshotReceived;

    // DOM スナップショットを定期送信する JavaScript
    // ユーザーが実際に開いているページから取得し、native へ postMessage する。
    private const string InjectionScript = """
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
                    '[class*="score"]', '[class*="inning"]', '[class*="batter"]',
                    '[class*="pitcher"]', '[class*="linescore"]', '[class*="gameday"]',
                    '[class*="schedule"]', '[class*="team"]', '[class*="broadcast"]',
                    'h1', 'h2', 'h3',
                ].join(',');
                return Array.from(document.querySelectorAll(sel))
                    .map(el => el.textContent.trim())
                    .filter(t => t.length > 0 && t.length < 300)
                    .slice(0, 60);
            }

            function snapshot() {
                const body = document.body ? document.body.innerText : '';
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
                        visibleText: body.slice(0, 8000),
                        links: collectLinks(),
                    }
                };
                window.chrome.webview.postMessage(JSON.stringify(payload));
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
        """;

    public BrowserController(WebView2 webView)
    {
        _webView = webView;
    }

    public async Task InitializeAsync()
    {
        await _webView.EnsureCoreWebView2Async();

        _webView.CoreWebView2.WebMessageReceived += OnWebMessageReceived;
        _webView.CoreWebView2.DOMContentLoaded += OnDomContentLoaded;
        _webView.CoreWebView2.NavigationCompleted += OnNavigationCompleted;

        IsAiAvailable = await CheckAiAvailableAsync();
    }

    private async void OnDomContentLoaded(object? sender, CoreWebView2DOMContentLoadedEventArgs e)
    {
        await _webView.CoreWebView2.ExecuteScriptAsync(InjectionScript);
    }

    private async void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (!e.IsSuccess) return;
        await _webView.CoreWebView2.ExecuteScriptAsync(InjectionScript);
    }

    private void OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            var json = e.TryGetWebMessageAsString();
            var envelope = JsonSerializer.Deserialize<PageSnapshotEnvelope>(json);
            if (envelope?.Type == "s17oPageSnapshot")
                SnapshotReceived?.Invoke(this, envelope);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"WebMessage parse error: {ex.Message}");
        }
    }

    // -----------------------------------------------------------------------
    // Navigation
    // -----------------------------------------------------------------------

    public void Navigate(Uri url) =>
        _webView.CoreWebView2?.Navigate(url.AbsoluteUri);

    // -----------------------------------------------------------------------
    // Script execution
    // -----------------------------------------------------------------------

    public async Task<string> ExecuteScriptAsync(string javascript) =>
        await _webView.CoreWebView2.ExecuteScriptAsync(javascript);

    // -----------------------------------------------------------------------
    // AI (Edge Prompt API — window.ai)
    // -----------------------------------------------------------------------

    /// <summary>
    /// Edge built-in AI (window.ai) を使ってプロンプトを送り、テキスト応答を返す。
    /// window.ai が利用できない環境では例外を投げる。
    /// </summary>
    public async Task<string> PromptAiAsync(string systemPrompt, string userMessage, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();

        // JSON エスケープして JavaScript の文字列リテラルとして埋め込む
        var sysEscaped = JsonSerializer.Serialize(systemPrompt);
        var userEscaped = JsonSerializer.Serialize(userMessage);

        var js = $$"""
            (async () => {
                if (!window.ai) return JSON.stringify({error: 'window.ai unavailable'});
                try {
                    const session = await window.ai.createSession({
                        systemPrompt: {{sysEscaped}}
                    });
                    const result = await session.prompt({{userEscaped}});
                    session.destroy();
                    return result;
                } catch (err) {
                    return JSON.stringify({error: String(err)});
                }
            })()
            """;

        var raw = await _webView.CoreWebView2.ExecuteScriptAsync(js);

        // CoreWebView2.ExecuteScriptAsync は JSON エンコードされた文字列を返す
        var unquoted = JsonSerializer.Deserialize<string>(raw) ?? raw;

        if (unquoted.TrimStart().StartsWith("{\"error\""))
        {
            var errObj = JsonSerializer.Deserialize<JsonElement>(unquoted);
            throw new InvalidOperationException($"Edge AI エラー: {errObj.GetProperty("error").GetString()}");
        }

        return unquoted;
    }

    private async Task<bool> CheckAiAvailableAsync()
    {
        try
        {
            var result = await _webView.CoreWebView2.ExecuteScriptAsync(
                "typeof window.ai !== 'undefined' ? 'true' : 'false'");
            return result.Trim('"') == "true";
        }
        catch { return false; }
    }

    // -----------------------------------------------------------------------
    // Foreground (bring the app window to front)
    // -----------------------------------------------------------------------

    public void BringToFront()
    {
        var window = Window.GetWindow(_webView);
        if (window is null) return;

        window.Dispatcher.Invoke(() =>
        {
            if (window.WindowState == WindowState.Minimized)
                window.WindowState = WindowState.Normal;
            window.Activate();
            window.Topmost = true;
            window.Topmost = false;
            window.Focus();
        });
    }
}
