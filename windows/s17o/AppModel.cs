using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using Windows.UI.Notifications;
using Windows.Data.Xml.Dom;

namespace s17o;

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

public enum MatchSource { Audio, Dom }

public record MatchEvent(
    DateTime Timestamp,
    string Keyword,
    string Details,
    MatchSource Source)
{
    public string TimestampLabel => Timestamp.ToString("HH:mm:ss");
}

public record BaseballContext(
    string PageKind,
    string GameState,
    string? InningHalf,
    string? CurrentBatter,
    string? PreviousBatter,
    string? OnDeck,
    string? Pitcher,
    string? Outs,
    string AdState,
    string PlaybackState,
    string? WatchUrl,
    string? ScheduledDateText,
    string? ScheduledTimeText,
    string? ScheduledTimeZone,
    DateTime? ScheduledStartDate,
    double Confidence)
{
    public string Summary
    {
        get
        {
            var parts = new List<string>
            {
                $"ページ: {PageKind}",
                $"状態: {GameState}",
                $"配信: {AdState}",
                $"再生: {PlaybackState}",
            };
            if (!string.IsNullOrEmpty(InningHalf)) parts.Add($"回: {InningHalf}");
            if (!string.IsNullOrEmpty(CurrentBatter)) parts.Add($"打者: {CurrentBatter}");
            if (!string.IsNullOrEmpty(PreviousBatter)) parts.Add($"前打者: {PreviousBatter}");
            if (!string.IsNullOrEmpty(OnDeck)) parts.Add($"次打者: {OnDeck}");
            if (!string.IsNullOrEmpty(Pitcher)) parts.Add($"投手: {Pitcher}");
            if (!string.IsNullOrEmpty(Outs)) parts.Add($"アウト: {Outs}");
            return string.Join(" / ", parts);
        }
    }
}

public record GenericProfileContext(
    string Summary,
    string? Phase,
    string? CurrentActor,
    string? NextActor,
    string? Counterpart,
    string BreakState,
    double Confidence);

public enum ProfilePayloadKind { Baseball, Generic }

public record ProfilePayload(
    ProfilePayloadKind Kind,
    BaseballContext? Baseball = null,
    GenericProfileContext? Generic = null);

public record DomMatch(string Keyword, string Reason, string Details, string Signature);

public record InterpretedPage(
    ProfileSelectionState Selection,
    string Summary,
    ProfilePayload Payload,
    DomMatch? DomMatch);

public record ProfileSelectionState(ProfileDefinition Profile, double Confidence, string Reason);

public record CalendarResolution(Uri SourceUrl, Uri TargetUrl, DateTime? StartDate, string TargetLabel, string? TimeLabel)
{
    public string Summary => !string.IsNullOrEmpty(TimeLabel) ? $"{TargetLabel} / {TimeLabel}" : TargetLabel;
}

// ---------------------------------------------------------------------------
// PageSnapshot (received from WebView2 JavaScript)
// ---------------------------------------------------------------------------

public record PageSnapshotEnvelope(
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("page")] PageSnapshotPage Page,
    [property: JsonPropertyName("sentAt")] double? SentAt);

public record PageSnapshotPage(
    [property: JsonPropertyName("title")] string Title,
    [property: JsonPropertyName("url")] string Url,
    [property: JsonPropertyName("headings")] List<string> Headings,
    [property: JsonPropertyName("highlights")] List<string> Highlights,
    [property: JsonPropertyName("visibleText")] string VisibleText,
    [property: JsonPropertyName("links")] List<VisibleLink>? Links);

public record VisibleLink(
    [property: JsonPropertyName("text")] string Text,
    [property: JsonPropertyName("href")] string Href);

// ---------------------------------------------------------------------------
// AppModel
// ---------------------------------------------------------------------------

public sealed class AppModel : INotifyPropertyChanged, IDisposable
{
    public static readonly string AppDisplayName = "s17o";
    public static readonly string ProfilesDirectory =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "s17o", "profiles");

    // -----------------------------------------------------------------------
    // Published state
    // -----------------------------------------------------------------------
    private string _keywordsText = Properties.Settings.Default.Keywords.Length > 0
        ? Properties.Settings.Default.Keywords
        : "Ohtani\nShohei Ohtani";
    public string KeywordsText
    {
        get => _keywordsText;
        set { _keywordsText = value; OnPropertyChanged(); Properties.Settings.Default.Keywords = value; SaveSettings(); }
    }

    private string _automationUrlText = Properties.Settings.Default.AutomationUrl;
    public string AutomationUrlText
    {
        get => _automationUrlText;
        set { _automationUrlText = value; OnPropertyChanged(); Properties.Settings.Default.AutomationUrl = value; SaveSettings(); RefreshAutomationSchedule(); }
    }

    private DateTime _automationStartDate = Properties.Settings.Default.AutomationStartDate == default
        ? DateTime.Now
        : Properties.Settings.Default.AutomationStartDate;
    public DateTime AutomationStartDate
    {
        get => _automationStartDate;
        set { _automationStartDate = value; OnPropertyChanged(); Properties.Settings.Default.AutomationStartDate = value; SaveSettings(); RefreshAutomationSchedule(); }
    }

    private bool _autoOpenTargetPage = Properties.Settings.Default.AutoOpenTargetPage;
    public bool AutoOpenTargetPage
    {
        get => _autoOpenTargetPage;
        set { _autoOpenTargetPage = value; OnPropertyChanged(); Properties.Settings.Default.AutoOpenTargetPage = value; SaveSettings(); RefreshAutomationSchedule(); }
    }

    private bool _autoStartMonitoringAtSchedule = Properties.Settings.Default.AutoStartMonitoring;
    public bool AutoStartMonitoringAtSchedule
    {
        get => _autoStartMonitoringAtSchedule;
        set { _autoStartMonitoringAtSchedule = value; OnPropertyChanged(); Properties.Settings.Default.AutoStartMonitoring = value; SaveSettings(); RefreshAutomationSchedule(); }
    }

    private bool _autoSoundControlEnabled = Properties.Settings.Default.AutoSoundControl;
    public bool AutoSoundControlEnabled
    {
        get => _autoSoundControlEnabled;
        set { _autoSoundControlEnabled = value; OnPropertyChanged(); Properties.Settings.Default.AutoSoundControl = value; SaveSettings(); HandleAutoSoundToggle(); }
    }

    private bool _autoBringToFrontEnabled = Properties.Settings.Default.AutoBringToFront;
    public bool AutoBringToFrontEnabled
    {
        get => _autoBringToFrontEnabled;
        set { _autoBringToFrontEnabled = value; OnPropertyChanged(); Properties.Settings.Default.AutoBringToFront = value; SaveSettings(); HandleAutoBringToFrontToggle(); }
    }

    public bool IsRunning { get => _isRunning; private set { _isRunning = value; OnPropertyChanged(); } }
    public string StatusMessage { get => _status; private set { _status = value; OnPropertyChanged(); } }
    public string Transcript { get => _transcript; private set { _transcript = value; OnPropertyChanged(); } }
    public string CaptureSource { get => _captureSource; private set { _captureSource = value; OnPropertyChanged(); } }
    public string LastError { get => _lastError; private set { _lastError = value; OnPropertyChanged(); } }
    public string LastMatchKeyword { get => _lastMatchKeyword; private set { _lastMatchKeyword = value; OnPropertyChanged(); } }
    public string LastMatchTranscript { get => _lastMatchTranscript; private set { _lastMatchTranscript = value; OnPropertyChanged(); } }
    public string ActiveProfileLabel { get => _activeProfileLabel; private set { _activeProfileLabel = value; OnPropertyChanged(); } }
    public string ProfileReason { get => _profileReason; private set { _profileReason = value; OnPropertyChanged(); } }
    public string PageTitle { get => _pageTitle; private set { _pageTitle = value; OnPropertyChanged(); } }
    public string PageUrl { get => _pageUrl; private set { _pageUrl = value; OnPropertyChanged(); } }
    public string PageSummary { get => _pageSummary; private set { _pageSummary = value; OnPropertyChanged(); } }
    public string BaseballSummary { get => _baseballSummary; private set { _baseballSummary = value; OnPropertyChanged(); } }
    public string PageHighlights { get => _pageHighlights; private set { _pageHighlights = value; OnPropertyChanged(); } }
    public string LastDomUpdate { get => _lastDomUpdate; private set { _lastDomUpdate = value; OnPropertyChanged(); } }
    public string AutomationStatus { get => _automationStatus; private set { _automationStatus = value; OnPropertyChanged(); } }
    public string CalendarStatus { get => _calendarStatus; private set { _calendarStatus = value; OnPropertyChanged(); } }
    public string SoundAutomationStatus { get => _soundAutomationStatus; private set { _soundAutomationStatus = value; OnPropertyChanged(); } }
    public string ForegroundAutomationStatus { get => _foregroundAutomationStatus; private set { _foregroundAutomationStatus = value; OnPropertyChanged(); } }
    public string AiEngineStatus { get => _aiEngineStatus; private set { _aiEngineStatus = value; OnPropertyChanged(); } }
    public ObservableCollection<MatchEvent> RecentMatches { get; } = [];

    // backing fields
    private bool _isRunning;
    private string _status = "停止中";
    private string _transcript = "";
    private string _captureSource = "未取得";
    private string _lastError = "";
    private string _lastMatchKeyword = "";
    private string _lastMatchTranscript = "";
    private string _activeProfileLabel = "未選択";
    private string _profileReason = "まだありません";
    private string _pageTitle = "";
    private string _pageUrl = "";
    private string _pageSummary = "まだありません";
    private string _baseballSummary = "未検出";
    private string _pageHighlights = "";
    private string _lastDomUpdate = "まだありません";
    private string _automationStatus = "自動化オフ";
    private string _calendarStatus = "未使用";
    private string _soundAutomationStatus = "手動";
    private string _foregroundAutomationStatus = "手動";
    private string _aiEngineStatus = "未確認";

    // -----------------------------------------------------------------------
    // Internal state
    // -----------------------------------------------------------------------
    public const double CooldownSeconds = 45;
    private const double AdLoopThresholdSeconds = 180;

    private readonly ProfileEngine _profileEngine = new();
    private ProfileEngine? _attachedProfileEngine;
    private AudioCapture? _audioCapture;
    private KeywordRecognizer? _keywordRecognizer;
    private BrowserController? _browserController;

    private readonly Dictionary<string, DateTime> _lastNotificationAt = [];
    private string _lastDomNotificationSignature = "";
    private BaseballContext? _baseballContext;
    private CalendarResolution? _calendarResolution;
    private string _latestSnapshotSignature = "";
    private string _lastForegroundSignature = "";
    private string _adObservationSignature = "";
    private DateTime? _adObservationStartedAt;
    private string _adLoopNotificationSignature = "";
    private string _lastBaseballProgressSignature = "";
    private bool? _automationManagedMutedState;

    private System.Threading.Timer? _automationTimer;
    private bool _isScheduledAutomationRunning;
    private CancellationTokenSource? _interpretationCts;

    public AppModel()
    {
        _profileEngine = new ProfileEngine();
        AutomationStatus = "自動化オフ";
        SoundAutomationStatus = AutoSoundControlEnabled ? "待機" : "手動";
        ForegroundAutomationStatus = AutoBringToFrontEnabled ? "待機" : "手動";
        RefreshAutomationSchedule();
    }

    // -----------------------------------------------------------------------
    // BrowserController wiring
    // -----------------------------------------------------------------------

    public void AttachBrowserController(BrowserController controller, ProfileEngine profileEngine)
    {
        _browserController = controller;
        profileEngine.AttachBrowser(controller);
        _attachedProfileEngine = profileEngine;
        controller.SnapshotReceived += OnSnapshotReceived;
        AiEngineStatus = controller.IsAiAvailable ? "利用可能" : "Edge AI 未対応";
    }

    // -----------------------------------------------------------------------
    // Monitoring
    // -----------------------------------------------------------------------

    public async Task StartMonitoringAsync()
    {
        if (IsRunning) return;
        ResetSessionState();

        var keywords = ParseKeywords(KeywordsText);
        if (keywords.Count == 0)
        {
            SurfaceError("少なくとも1つのキーワードを指定してください。");
            return;
        }

        try
        {
            StatusMessage = "権限を確認しています";

            _keywordRecognizer = new KeywordRecognizer(
                keywords,
                onTranscript: t => Dispatch(() => Transcript = t),
                onMatch: (kw, text) => Dispatch(async () => await HandleAudioMatchAsync(kw, text)),
                onFailure: ex => Dispatch(() => SurfaceError(ex.Message)));

            _audioCapture = new AudioCapture(
                onBuffer: buf => _keywordRecognizer.Append(buf),
                onSourceChange: src => Dispatch(() => CaptureSource = src),
                onFailure: ex => Dispatch(() => SurfaceError(ex.Message)));

            await _audioCapture.StartAsync();

            IsRunning = true;
            StatusMessage = "監視中";

            if (AutoSoundControlEnabled)
                await ApplyAutomaticSoundStateAsync(null, keywords, force: true);
        }
        catch (Exception ex)
        {
            await SurfaceErrorAsync(ex.Message);
        }
    }

    public async Task StopMonitoringAsync()
    {
        await TearDownPipelineAsync();
        StatusMessage = "停止中";
    }

    public async Task RunAutomationNowAsync() =>
        await ExecuteScheduledAutomationAsync("手動実行");

    public async Task OpenConfiguredTargetPageNowAsync()
    {
        try
        {
            await OpenConfiguredTargetPageAsync();
            AutomationStatus = "ブラウザを開きました";
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            AutomationStatus = "URL オープン失敗";
        }
    }

    // -----------------------------------------------------------------------
    // Snapshot handling
    // -----------------------------------------------------------------------

    private void OnSnapshotReceived(object? sender, PageSnapshotEnvelope snapshot)
    {
        PageTitle = snapshot.Page.Title;
        PageUrl = snapshot.Page.Url;
        PageHighlights = string.Join("\n", snapshot.Page.Highlights);

        var sig = SnapshotSignature(snapshot);
        if (sig == _latestSnapshotSignature) return;
        _latestSnapshotSignature = sig;

        _interpretationCts?.Cancel();
        _interpretationCts = new CancellationTokenSource();
        var ct = _interpretationCts.Token;
        var keywords = ParseKeywords(KeywordsText);
        var refDate = snapshot.SentAt.HasValue
            ? DateTimeOffset.FromUnixTimeMilliseconds((long)snapshot.SentAt.Value).UtcDateTime
            : DateTime.UtcNow;

        var engine = _attachedProfileEngine;
        if (engine is null) return;

        _ = Task.Run(async () =>
        {
            try
            {
                var interpreted = await engine.InterpretAsync(snapshot, keywords, refDate, ct);
                ct.ThrowIfCancellationRequested();
                Dispatch(() => ApplyInterpreted(interpreted, snapshot, keywords));
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                Dispatch(() => SurfaceError(ex.Message));
            }
        }, ct);
    }

    private void ApplyInterpreted(InterpretedPage interpreted, PageSnapshotEnvelope snapshot, List<string> keywords)
    {
        ActiveProfileLabel = interpreted.Selection.Profile.DisplayName;
        ProfileReason = interpreted.Selection.Reason;
        PageSummary = interpreted.Summary;
        LastDomUpdate = DateTime.Now.ToString("HH:mm:ss");

        switch (interpreted.Payload.Kind)
        {
            case ProfilePayloadKind.Baseball:
                var ctx = interpreted.Payload.Baseball!;
                _baseballContext = ctx;
                BaseballSummary = ctx.Summary;
                ApplyCalendarStateIfNeeded(ctx, snapshot.Page.Url);
                if (AutoSoundControlEnabled)
                    _ = ApplyAutomaticSoundStateAsync(ctx, keywords);
                if (AutoBringToFrontEnabled)
                    ApplyAutomaticForegroundState(ctx, keywords);
                UpdateAdLoopObservation(ctx);
                break;

            case ProfilePayloadKind.Generic:
                _baseballContext = null;
                BaseballSummary = "未検出";
                _calendarResolution = null;
                _adObservationSignature = "";
                _adObservationStartedAt = null;
                _adLoopNotificationSignature = "";
                _lastBaseballProgressSignature = "";
                SoundAutomationStatus = AutoSoundControlEnabled ? "待機" : "手動";
                ForegroundAutomationStatus = AutoBringToFrontEnabled ? "待機" : "手動";
                break;
        }

        if (interpreted.DomMatch is { } domMatch)
            _ = NotifyDomMatchIfNeededAsync(domMatch);
    }

    // -----------------------------------------------------------------------
    // Audio match
    // -----------------------------------------------------------------------

    private async Task HandleAudioMatchAsync(string keyword, string transcript)
    {
        var key = $"audio:{Normalize(keyword)}";
        var now = DateTime.Now;
        if (_lastNotificationAt.TryGetValue(key, out var prev) &&
            (now - prev).TotalSeconds < CooldownSeconds) return;

        _lastNotificationAt[key] = now;
        LastMatchKeyword = keyword;
        LastMatchTranscript = transcript;
        RecentMatches.Insert(0, new MatchEvent(now, keyword, NotificationDetails(transcript), MatchSource.Audio));
        StatusMessage = "音声一致を検出しました";

        PostToast(AppDisplayName, NotificationDetails(transcript));
        await Task.CompletedTask;
    }

    private async Task NotifyDomMatchIfNeededAsync(DomMatch match)
    {
        if (!IsRunning) return;
        if (match.Signature == _lastDomNotificationSignature) return;

        var key = $"dom:{Normalize(match.Keyword)}";
        var now = DateTime.Now;
        if (_lastNotificationAt.TryGetValue(key, out var prev) &&
            (now - prev).TotalSeconds < CooldownSeconds) return;

        _lastDomNotificationSignature = match.Signature;
        _lastNotificationAt[key] = now;
        LastMatchKeyword = match.Keyword;
        LastMatchTranscript = match.Details;
        RecentMatches.Insert(0, new MatchEvent(now, match.Keyword, match.Details, MatchSource.Dom));
        StatusMessage = "DOM 一致を検出しました";

        PostToast(AppDisplayName, match.Details);
        await Task.CompletedTask;
    }

    // -----------------------------------------------------------------------
    // Sound automation
    // -----------------------------------------------------------------------

    private async Task ApplyAutomaticSoundStateAsync(
        BaseballContext? ctx, List<string> keywords, bool force = false)
    {
        if (!AutoSoundControlEnabled) return;
        if (!IsRunning) { SoundAutomationStatus = "待機"; return; }

        var shouldUnmute = ShouldEnableSound(ctx, keywords);
        var targetMuted = !shouldUnmute;

        if (!force && _automationManagedMutedState == targetMuted)
        {
            SoundAutomationStatus = shouldUnmute ? "自動ON" : "自動ミュート";
            return;
        }

        try
        {
            await SetBrowserMediaMutedAsync(targetMuted);
            _automationManagedMutedState = targetMuted;
            SoundAutomationStatus = shouldUnmute ? "自動ON" : "自動ミュート";
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            SoundAutomationStatus = "失敗";
        }
    }

    private async Task SetBrowserMediaMutedAsync(bool muted)
    {
        if (_browserController is null) return;
        var js = $$"""
            (() => {
              const media = Array.from(document.querySelectorAll('video, audio'));
              if (media.length === 0) throw new Error('ページ内に media 要素がありません。');
              for (const item of media) item.muted = {{(muted ? "true" : "false")}};
              return String(media.length);
            })();
            """;
        await _browserController.ExecuteScriptAsync(js);
    }

    private static bool ShouldEnableSound(BaseballContext? ctx, List<string> keywords)
    {
        if (ctx is null) return false;
        var fields = new[] { ctx.CurrentBatter, ctx.OnDeck, ctx.Pitcher }
            .Where(f => !string.IsNullOrEmpty(f))
            .Select(f => f!);
        return fields.Any(f => keywords.Any(k =>
            Normalize(f).Contains(Normalize(k), StringComparison.OrdinalIgnoreCase)));
    }

    private void RestoreBrowserSoundIfNeeded()
    {
        if (_automationManagedMutedState is not true) { _automationManagedMutedState = null; return; }
        try { _ = SetBrowserMediaMutedAsync(false); }
        catch (Exception ex) { LastError = ex.Message; }
        _automationManagedMutedState = null;
    }

    // -----------------------------------------------------------------------
    // Foreground automation
    // -----------------------------------------------------------------------

    private void ApplyAutomaticForegroundState(BaseballContext? ctx, List<string> keywords)
    {
        if (!AutoBringToFrontEnabled) return;
        if (!IsRunning) { ForegroundAutomationStatus = "待機"; return; }
        if (!ShouldEnableSound(ctx, keywords)) { _lastForegroundSignature = ""; ForegroundAutomationStatus = "待機"; return; }

        var sig = string.Join("\n", PageUrl,
            ctx?.InningHalf ?? "",
            ctx?.CurrentBatter ?? "",
            ctx?.OnDeck ?? "",
            ctx?.Pitcher ?? "");

        if (sig == _lastForegroundSignature) { ForegroundAutomationStatus = "前面表示済み"; return; }

        try
        {
            _browserController?.BringToFront();
            _lastForegroundSignature = sig;
            ForegroundAutomationStatus = "前面表示";
        }
        catch (Exception ex) { LastError = ex.Message; ForegroundAutomationStatus = "失敗"; }
    }

    // -----------------------------------------------------------------------
    // Ad loop watchdog
    // -----------------------------------------------------------------------

    private void UpdateAdLoopObservation(BaseballContext? ctx)
    {
        if (!IsRunning || ctx is null)
        {
            _adObservationSignature = "";
            _adObservationStartedAt = null;
            _adLoopNotificationSignature = "";
            _lastBaseballProgressSignature = "";
            return;
        }

        var progressSig = string.Join("\n",
            ctx.PageKind, ctx.GameState, ctx.InningHalf ?? "",
            ctx.CurrentBatter ?? "", ctx.PreviousBatter ?? "",
            ctx.OnDeck ?? "", ctx.Pitcher ?? "", ctx.Outs ?? "");

        try
        {
            if (ctx.AdState is not ("ad" or "stuck"))
            {
                _adObservationSignature = "";
                _adObservationStartedAt = null;
                _adLoopNotificationSignature = "";
                return;
            }

            if (!string.IsNullOrEmpty(_lastBaseballProgressSignature) &&
                _lastBaseballProgressSignature != progressSig)
            {
                _ = NotifyAdProgressMismatchAsync(ctx.AdState, ctx.Summary);
            }

            var sig = $"{PageUrl}\n{ctx.AdState}";
            var now = DateTime.Now;
            if (_adObservationSignature != sig)
            {
                _adObservationSignature = sig;
                _adObservationStartedAt = now;
                _adLoopNotificationSignature = "";
                return;
            }

            _adObservationStartedAt ??= now;
            var elapsed = (now - _adObservationStartedAt.Value).TotalSeconds;
            if (elapsed < AdLoopThresholdSeconds || _adLoopNotificationSignature == sig) return;

            _adLoopNotificationSignature = sig;
            _ = NotifyAdLoopAsync(ctx.AdState, elapsed);
        }
        finally
        {
            _lastBaseballProgressSignature = progressSig;
        }
    }

    private Task NotifyAdProgressMismatchAsync(string adState, string summary) =>
        NotifyEventAsync("dom:ad-progress-mismatch", "広告異常",
            $"試合進行 DOM は更新されていますが、配信状態は {adState} のままです。{summary}",
            MatchSource.Dom);

    private Task NotifyAdLoopAsync(string adState, double elapsed) =>
        NotifyEventAsync("dom:ad-loop", "広告ループ",
            $"MLB.TV が {adState} のまま {(int)elapsed} 秒継続しています。",
            MatchSource.Dom);

    private async Task NotifyEventAsync(string key, string keyword, string details, MatchSource source)
    {
        var now = DateTime.Now;
        if (_lastNotificationAt.TryGetValue(key, out var prev) &&
            (now - prev).TotalSeconds < CooldownSeconds) return;

        _lastNotificationAt[key] = now;
        LastMatchKeyword = keyword;
        LastMatchTranscript = details;
        RecentMatches.Insert(0, new MatchEvent(now, keyword, details, source));
        StatusMessage = $"{keyword}を検出しました";
        PostToast(AppDisplayName, details);
        await Task.CompletedTask;
    }

    // -----------------------------------------------------------------------
    // Calendar
    // -----------------------------------------------------------------------

    private void ApplyCalendarStateIfNeeded(BaseballContext ctx, string sourceUrlString)
    {
        if (!Uri.TryCreate(sourceUrlString, UriKind.Absolute, out var sourceUrl) ||
            !CalendarResolver.IsCalendarUrl(sourceUrl)) return;

        if (ctx.WatchUrl is null || !Uri.TryCreate(ctx.WatchUrl, UriKind.Absolute, out var targetUrl))
        {
            _calendarResolution = null;
            CalendarStatus = "AI が watch URL を特定できませんでした";
            return;
        }

        _calendarResolution = new CalendarResolution(sourceUrl, targetUrl,
            ctx.ScheduledStartDate,
            ctx.Summary.Length > 0 ? ctx.Summary : targetUrl.AbsoluteUri,
            ctx.ScheduledTimeText);
        CalendarStatus = _calendarResolution.Summary;

        if (ctx.ScheduledStartDate.HasValue)
            AutomationStartDate = ctx.ScheduledStartDate.Value;
    }

    // -----------------------------------------------------------------------
    // Automation scheduling
    // -----------------------------------------------------------------------

    private void RefreshAutomationSchedule()
    {
        _automationTimer?.Dispose();
        _automationTimer = null;

        if (!AutoOpenTargetPage && !AutoStartMonitoringAtSchedule)
        {
            AutomationStatus = "自動化オフ";
            return;
        }

        if (AutoOpenTargetPage && string.IsNullOrWhiteSpace(AutomationUrlText))
        {
            AutomationStatus = "URL未設定";
            return;
        }

        var scheduled = AutomationStartDate;
        var delay = scheduled - DateTime.Now;

        if (delay <= TimeSpan.Zero)
        {
            AutomationStatus = "予定時刻到達";
            _ = ExecuteScheduledAutomationAsync("予定時刻到達");
            return;
        }

        _automationTimer = new System.Threading.Timer(
            _ => Dispatch(async () => await ExecuteScheduledAutomationAsync("予定時刻到達")),
            null, delay, Timeout.InfiniteTimeSpan);
        AutomationStatus = $"待機中: {scheduled:g}";
    }

    private async Task ExecuteScheduledAutomationAsync(string trigger)
    {
        if (_isScheduledAutomationRunning) return;
        _isScheduledAutomationRunning = true;
        try
        {
            if (AutoOpenTargetPage) await OpenConfiguredTargetPageAsync();
            if (AutoStartMonitoringAtSchedule)
            {
                if (AutoOpenTargetPage) await Task.Delay(1500);
                await StartMonitoringAsync();
                if (!IsRunning) { AutomationStatus = $"{trigger}: 監視開始失敗"; return; }
            }

            AutomationStatus = AutoOpenTargetPage && AutoStartMonitoringAtSchedule
                ? $"{trigger}: ブラウザを開いて監視開始"
                : AutoOpenTargetPage ? $"{trigger}: ブラウザを開きました"
                : $"{trigger}: 監視開始";
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            AutomationStatus = $"{trigger}: 失敗";
        }
        finally { _isScheduledAutomationRunning = false; }
    }

    private Task OpenConfiguredTargetPageAsync()
    {
        if (!Uri.TryCreate(AutomationUrlText.Trim(), UriKind.Absolute, out var url) ||
            url.Scheme is not ("http" or "https"))
            throw new InvalidOperationException("自動オープン用の URL が無効です。");

        var target = _calendarResolution is { } res &&
                     CalendarResolver.UrlsMatch(res.SourceUrl, url) ? res.TargetUrl : url;

        _browserController?.Navigate(target);
        return Task.CompletedTask;
    }

    // -----------------------------------------------------------------------
    // Session management
    // -----------------------------------------------------------------------

    private void ResetSessionState()
    {
        LastError = "";
        Transcript = "";
        LastMatchKeyword = "";
        LastMatchTranscript = "";
        RecentMatches.Clear();
        _lastNotificationAt.Clear();
        _lastDomNotificationSignature = "";
        _interpretationCts?.Cancel();
        _interpretationCts = null;
        _latestSnapshotSignature = "";
        ActiveProfileLabel = "未選択";
        ProfileReason = "まだありません";
        PageSummary = "まだありません";
        BaseballSummary = "未検出";
        _baseballContext = null;
        SoundAutomationStatus = AutoSoundControlEnabled ? "待機" : "手動";
        ForegroundAutomationStatus = AutoBringToFrontEnabled ? "待機" : "手動";
        _lastForegroundSignature = "";
        _adObservationSignature = "";
        _adObservationStartedAt = null;
        _adLoopNotificationSignature = "";
        _lastBaseballProgressSignature = "";
    }

    private async Task TearDownPipelineAsync()
    {
        if (_audioCapture is { } cap) { cap.Stop(); _audioCapture = null; }
        _keywordRecognizer?.Stop();
        _keywordRecognizer = null;
        RestoreBrowserSoundIfNeeded();
        IsRunning = false;
        await Task.CompletedTask;
    }

    private void SurfaceError(string message)
    {
        LastError = message;
        StatusMessage = "失敗";
        _ = TearDownPipelineAsync();
    }

    private async Task SurfaceErrorAsync(string message)
    {
        LastError = message;
        StatusMessage = "失敗";
        await TearDownPipelineAsync();
    }

    private void HandleAutoSoundToggle()
    {
        if (AutoSoundControlEnabled)
        {
            if (IsRunning) _ = ApplyAutomaticSoundStateAsync(_baseballContext, ParseKeywords(KeywordsText), force: true);
            else SoundAutomationStatus = "待機";
        }
        else { RestoreBrowserSoundIfNeeded(); SoundAutomationStatus = "手動"; }
    }

    private void HandleAutoBringToFrontToggle()
    {
        if (AutoBringToFrontEnabled)
        {
            if (IsRunning) ApplyAutomaticForegroundState(_baseballContext, ParseKeywords(KeywordsText));
            else ForegroundAutomationStatus = "待機";
        }
        else { _lastForegroundSignature = ""; ForegroundAutomationStatus = "手動"; }
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    private string NotificationDetails(string transcript)
    {
        var ctx = _baseballContext?.Summary;
        return !string.IsNullOrEmpty(ctx) ? $"{transcript} ({ctx})" : transcript;
    }

    private static List<string> ParseKeywords(string text) =>
        text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(s => s.Length > 0).ToList();

    private static string Normalize(string text) =>
        text.ToLowerInvariant().Normalize(System.Text.NormalizationForm.FormKD);

    private static string SnapshotSignature(PageSnapshotEnvelope s) =>
        string.Join("\n", s.Page.Title, s.Page.Url,
            string.Join("|", s.Page.Headings),
            string.Join("|", s.Page.Highlights),
            s.Page.VisibleText);

    private static void PostToast(string title, string body)
    {
        try
        {
            var xml = new XmlDocument();
            xml.LoadXml($"""
                <toast>
                  <visual><binding template="ToastText02">
                    <text id="1">{System.Security.SecurityElement.Escape(title)}</text>
                    <text id="2">{System.Security.SecurityElement.Escape(body)}</text>
                  </binding></visual>
                </toast>
                """);
            var notifier = ToastNotificationManager.CreateToastNotifier(AppDisplayName);
            notifier.Show(new ToastNotification(xml));
        }
        catch { /* 通知権限なし時は無視 */ }
    }

    private static void SaveSettings()
    {
        try { Properties.Settings.Default.Save(); }
        catch { }
    }

    private static void Dispatch(Action action)
    {
        if (System.Windows.Application.Current?.Dispatcher is { } d)
            d.Invoke(action);
        else action();
    }

    // -----------------------------------------------------------------------
    // INotifyPropertyChanged
    // -----------------------------------------------------------------------

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    // -----------------------------------------------------------------------
    // IDisposable
    // -----------------------------------------------------------------------

    public void Dispose()
    {
        _automationTimer?.Dispose();
        _interpretationCts?.Cancel();
        _interpretationCts?.Dispose();
        _audioCapture?.Stop();
        _keywordRecognizer?.Stop();
    }
}

// ---------------------------------------------------------------------------
// CalendarResolver (URL utility only — extraction is AI-driven)
// ---------------------------------------------------------------------------

public static class CalendarResolver
{
    public static bool IsCalendarUrl(Uri url) =>
        url.Host.Contains("mlb.com", StringComparison.OrdinalIgnoreCase) &&
        url.AbsolutePath.Contains("/schedule", StringComparison.OrdinalIgnoreCase);

    public static bool UrlsMatch(Uri lhs, Uri rhs) =>
        Normalize(lhs) == Normalize(rhs);

    private static string Normalize(Uri url)
    {
        var b = new UriBuilder(url) { Fragment = "" };
        var s = b.Uri.AbsoluteUri;
        return s.EndsWith('/') ? s[..^1] : s;
    }
}
