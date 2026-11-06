import Combine
import Foundation
import UserNotifications

// ---------------------------------------------------------------------------
// MatchEvent
// ---------------------------------------------------------------------------

struct MatchEvent: Identifiable {
    enum Source: String { case dom = "DOM" }
    let id = UUID()
    let timestamp: Date
    let keyword: String
    let details: String
    let source: Source

    var timestampLabel: String {
        Self.formatter.string(from: timestamp)
    }
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .medium; return f
    }()
}

// ---------------------------------------------------------------------------
// CalendarResolver (URL utility)
// ---------------------------------------------------------------------------

enum CalendarResolver {
    static func isCalendarURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("mlb.com") && url.path.lowercased().contains("/schedule")
    }

    static func urlsMatch(_ lhs: URL, _ rhs: URL?) -> Bool {
        guard let rhs else { return false }
        return normalizedURL(lhs) == normalizedURL(rhs)
    }

    private static func normalizedURL(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        let s = c?.url?.absoluteString ?? url.absoluteString
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }
}

// ---------------------------------------------------------------------------
// CalendarResolution
// ---------------------------------------------------------------------------

struct CalendarResolution {
    let sourceURL: URL
    let targetURL: URL
    let startDate: Date?
    let targetLabel: String
    let timeLabel: String?

    var summary: String {
        if let t = timeLabel, !t.isEmpty { return "\(targetLabel) / \(t)" }
        return targetLabel
    }
}

// ---------------------------------------------------------------------------
// AppModel
// ---------------------------------------------------------------------------

@MainActor
final class AppModel: ObservableObject {
    static let appDisplayName = "s17o"
    static let defaultKeywords = "Ohtani\nShohei Ohtani"

    // -----------------------------------------------------------------------
    // Setup state
    // -----------------------------------------------------------------------
    @Published var isSetupComplete: Bool = UserDefaults.standard.bool(forKey: "s17o.setupComplete") {
        didSet { UserDefaults.standard.set(isSetupComplete, forKey: "s17o.setupComplete") }
    }

    func completeSetup() {
        isSetupComplete = true
    }

    // -----------------------------------------------------------------------
    // Settings (UserDefaults)
    // -----------------------------------------------------------------------
    @Published var keywordsText: String = UserDefaults.standard.string(forKey: "s17o.keywords") ?? defaultKeywords {
        didSet { UserDefaults.standard.set(keywordsText, forKey: "s17o.keywords") }
    }
    @Published var automationURLText: String = UserDefaults.standard.string(forKey: "s17o.automationUrl") ?? "https://www.mlb.com/dodgers/schedule/" {
        didSet { UserDefaults.standard.set(automationURLText, forKey: "s17o.automationUrl"); refreshCalendarState() }
    }
    @Published var automationStartDate: Date = (UserDefaults.standard.object(forKey: "s17o.automationStartDate") as? Date) ?? Date() {
        didSet { UserDefaults.standard.set(automationStartDate, forKey: "s17o.automationStartDate"); refreshAutomationSchedule() }
    }
    @Published var autoOpenTargetPage: Bool = UserDefaults.standard.bool(forKey: "s17o.autoOpenPage") {
        didSet { UserDefaults.standard.set(autoOpenTargetPage, forKey: "s17o.autoOpenPage"); refreshAutomationSchedule() }
    }
    @Published var autoStartMonitoringAtSchedule: Bool = UserDefaults.standard.bool(forKey: "s17o.autoStartMonitoring") {
        didSet { UserDefaults.standard.set(autoStartMonitoringAtSchedule, forKey: "s17o.autoStartMonitoring"); refreshAutomationSchedule() }
    }
    @Published var autoSoundControlEnabled: Bool = UserDefaults.standard.bool(forKey: "s17o.autoSoundControl") {
        didSet { UserDefaults.standard.set(autoSoundControlEnabled, forKey: "s17o.autoSoundControl"); handleAutoSoundToggle() }
    }
    @Published var autoBringToFrontEnabled: Bool = UserDefaults.standard.bool(forKey: "s17o.autoBringToFront") {
        didSet { UserDefaults.standard.set(autoBringToFrontEnabled, forKey: "s17o.autoBringToFront") }
    }

    // -----------------------------------------------------------------------
    // Published UI state
    // -----------------------------------------------------------------------
    @Published var isRunning = false
    @Published var statusMessage = "Idle"
    @Published var lastError = ""
    @Published var lastMatchKeyword = ""
    @Published var lastMatchTranscript = ""
    @Published var recentMatches: [MatchEvent] = []
    @Published var activeProfileLabel = "未選択"
    @Published var profileReason = "まだありません"
    @Published var pageTitle = ""
    @Published var pageURL = ""
    @Published var pageSummary = "まだありません"
    @Published var baseballSummary = "未検出"
    @Published var pageHighlights = ""
    @Published var lastDOMUpdate = "まだありません"
    @Published var automationStatus = "自動化オフ"
    @Published var calendarStatus = "未使用"
    @Published var soundAutomationStatus = "手動"
    @Published var aiEngineStatus = "未確認"

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------
    let cooldownSeconds = 45.0
    private let adLoopThresholdSeconds = 180.0

    private let profileEngine = ProfileEngine()
    private var browserController: BrowserController?
    private var lastNotificationAt: [String: Date] = [:]
    private var lastDOMNotificationSignature = ""
    private var baseballContext: BaseballContext?
    private var calendarResolution: CalendarResolution?
    private var latestSnapshotSignature = ""
    private var lastForegroundSignature = ""
    private var adObservationSignature = ""
    private var adObservationStartedAt: Date?
    private var adLoopNotificationSignature = ""
    private var lastBaseballProgressSignature = ""
    private var automationManagedMutedState: Bool?
    private var snapshotInterpretationTask: Task<Void, Never>?
    private var automationTimer: Timer?
    private var isScheduledAutomationRunning = false

    init() {
        if !isSetupComplete {
            keywordsText = Self.defaultKeywords
            automationURLText = "https://www.mlb.com/dodgers/schedule/"
        }
        soundAutomationStatus = autoSoundControlEnabled ? "待機" : "手動"
        refreshAutomationSchedule()
        refreshCalendarState()
        checkAIAvailability()
    }

    private func checkAIAvailability() {
        if #available(iOS 18.1, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                aiEngineStatus = "利用可能"
            case .unavailable(let reason):
                aiEngineStatus = "利用不可: \(reason)"
            }
        } else {
            aiEngineStatus = "iOS 18.1 以降が必要です"
        }
    }

    // -----------------------------------------------------------------------
    // BrowserController 接続
    // -----------------------------------------------------------------------

    func attach(browserController: BrowserController) {
        self.browserController = browserController
        browserController.onSnapshot = { [weak self] snapshot in
            self?.handleSnapshot(snapshot)
        }
    }

    // -----------------------------------------------------------------------
    // 監視開始・停止
    // -----------------------------------------------------------------------

    func startMonitoring() async {
        guard !isRunning else { return }
        resetSessionState()

        let keywords = parsedKeywords(from: keywordsText)
        guard !keywords.isEmpty else {
            lastError = "少なくとも1つのキーワードを指定してください。"
            return
        }

        do {
            statusMessage = "権限を確認しています"
            try await profileEngine.ensureAvailable()
            try await requestNotificationAuthorization()

            isRunning = true
            statusMessage = "Watching"

            if autoSoundControlEnabled {
                await applyAutomaticSoundState(using: nil, keywords: keywords, force: true)
            }
        } catch {
            lastError = error.localizedDescription
            statusMessage = "失敗"
        }
    }

    func stopMonitoring() async {
        await tearDown()
        statusMessage = "Idle"
    }

    func runAutomationNow() async {
        await executeScheduledAutomation(trigger: "手動実行")
    }

    func openConfiguredTargetPageNow() {
        guard let url = validatedAutomationSourceURL() else {
            lastError = "自動オープン用の URL が無効です。"
            return
        }
        let target = resolvedTargetURL(from: url) ?? url
        browserController?.navigate(to: target)
        automationStatus = "ブラウザを開きました"
    }

    // -----------------------------------------------------------------------
    // Snapshot 処理
    // -----------------------------------------------------------------------

    private func handleSnapshot(_ snapshot: PageSnapshotEnvelope) {
        pageTitle    = snapshot.page.title
        pageURL      = snapshot.page.url
        pageHighlights = snapshot.page.highlights.joined(separator: "\n")

        let sig = snapshotSignature(snapshot)
        guard sig != latestSnapshotSignature else { return }
        latestSnapshotSignature = sig

        guard isRunning else { return }

        let keywords  = parsedKeywords(from: keywordsText)
        let refDate   = snapshot.sentAt.map { Date(timeIntervalSince1970: $0 / 1000.0) } ?? Date()

        snapshotInterpretationTask?.cancel()
        snapshotInterpretationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let interpreted = try await profileEngine.interpret(
                    snapshot: snapshot, keywords: keywords, referenceDate: refDate)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.latestSnapshotSignature == sig else { return }
                    self.applyInterpreted(interpreted, snapshot: snapshot, keywords: keywords)
                }
            } catch is CancellationError { return }
              catch { await self.surfaceError(error) }
        }
    }

    private func applyInterpreted(_ interpreted: InterpretedPage,
                                   snapshot: PageSnapshotEnvelope,
                                   keywords: [String]) {
        activeProfileLabel = interpreted.selection.profile.displayName
        profileReason      = interpreted.selection.reason
        pageSummary        = interpreted.summary
        lastDOMUpdate      = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)

        switch interpreted.payload {
        case .baseball(let ctx):
            baseballContext = ctx
            baseballSummary = ctx.summary
            applyCalendarStateIfNeeded(using: ctx, sourceURLString: snapshot.page.url)
            if autoSoundControlEnabled {
                Task { await self.applyAutomaticSoundState(using: ctx, keywords: keywords) }
            }
            updateAdLoopObservation(using: ctx)

        case .generic:
            baseballContext = nil
            baseballSummary = "未検出"
            calendarResolution = nil
            soundAutomationStatus = autoSoundControlEnabled ? "待機" : "手動"
            adObservationSignature = ""
            adObservationStartedAt = nil
            adLoopNotificationSignature = ""
            lastBaseballProgressSignature = ""
        }

        if let match = interpreted.domMatch {
            Task { await self.notifyDOMMatchIfNeeded(match) }
        }
    }

    // -----------------------------------------------------------------------
    // 通知
    // -----------------------------------------------------------------------

    private func notifyDOMMatchIfNeeded(_ match: DOMMatch) async {
        guard isRunning, match.signature != lastDOMNotificationSignature else { return }
        let key = "dom:\(normalize(match.keyword))"
        let now = Date()
        if let prev = lastNotificationAt[key], now.timeIntervalSince(prev) < cooldownSeconds { return }

        lastDOMNotificationSignature = match.signature
        lastNotificationAt[key] = now
        lastMatchKeyword = match.keyword
        lastMatchTranscript = match.details
        recentMatches.insert(MatchEvent(timestamp: now, keyword: match.keyword,
                                        details: match.details, source: .dom), at: 0)
        statusMessage = "DOM 一致を検出しました"
        await postNotification(title: Self.appDisplayName, body: match.details)
    }

    private func notifyEvent(key: String, keyword: String, details: String) async {
        let now = Date()
        if let prev = lastNotificationAt[key], now.timeIntervalSince(prev) < cooldownSeconds { return }
        lastNotificationAt[key] = now
        lastMatchKeyword = keyword
        lastMatchTranscript = details
        recentMatches.insert(MatchEvent(timestamp: now, keyword: keyword,
                                        details: details, source: .dom), at: 0)
        statusMessage = "\(keyword)を検出しました"
        await postNotification(title: Self.appDisplayName, body: details)
    }

    private func postNotification(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func requestNotificationAuthorization() async throws {
        let granted = try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        if !granted { throw AppError.notificationDenied }
    }

    // -----------------------------------------------------------------------
    // 音声自動制御（WKWebView 内の media.muted）
    // -----------------------------------------------------------------------

    private func applyAutomaticSoundState(using ctx: BaseballContext?,
                                           keywords: [String],
                                           force: Bool = false) async {
        guard autoSoundControlEnabled else { return }
        guard isRunning else { soundAutomationStatus = "待機"; return }

        let shouldUnmute = shouldEnableSound(for: ctx, keywords: keywords)
        let targetMuted  = !shouldUnmute

        if !force, automationManagedMutedState == targetMuted {
            soundAutomationStatus = shouldUnmute ? "自動ON" : "自動ミュート"
            return
        }

        do {
            try await browserController?.setMediaMuted(targetMuted)
            automationManagedMutedState = targetMuted
            soundAutomationStatus = shouldUnmute ? "自動ON" : "自動ミュート"
        } catch {
            lastError = error.localizedDescription
            soundAutomationStatus = "失敗"
        }
    }

    private func shouldEnableSound(for ctx: BaseballContext?, keywords: [String]) -> Bool {
        guard let ctx else { return false }
        let normedKW = keywords.map(normalize)
        return [ctx.currentBatter, ctx.onDeck, ctx.pitcher]
            .compactMap { $0 }
            .contains { field in normedKW.contains(where: { normalize(field).contains($0) }) }
    }

    private func restoreSoundIfNeeded() {
        guard automationManagedMutedState == true else { automationManagedMutedState = nil; return }
        Task { try? await browserController?.setMediaMuted(false) }
        automationManagedMutedState = nil
    }

    private func handleAutoSoundToggle() {
        if autoSoundControlEnabled {
            if isRunning {
                Task { await applyAutomaticSoundState(using: baseballContext,
                                                      keywords: parsedKeywords(from: keywordsText), force: true) }
            } else { soundAutomationStatus = "待機" }
        } else { restoreSoundIfNeeded(); soundAutomationStatus = "手動" }
    }

    // -----------------------------------------------------------------------
    // 広告ループ監視
    // -----------------------------------------------------------------------

    private func updateAdLoopObservation(using ctx: BaseballContext?) {
        guard isRunning, let ctx else {
            adObservationSignature = ""; adObservationStartedAt = nil
            adLoopNotificationSignature = ""; lastBaseballProgressSignature = ""; return
        }

        let progressSig = [ctx.pageKind, ctx.gameState, ctx.inningHalf ?? "",
                           ctx.currentBatter ?? "", ctx.previousBatter ?? "",
                           ctx.onDeck ?? "", ctx.pitcher ?? "", ctx.outs ?? ""].joined(separator: "\n")
        defer { lastBaseballProgressSignature = progressSig }

        guard ctx.adState == "ad" || ctx.adState == "stuck" else {
            adObservationSignature = ""; adObservationStartedAt = nil; adLoopNotificationSignature = ""; return
        }

        if !lastBaseballProgressSignature.isEmpty, lastBaseballProgressSignature != progressSig {
            Task { await notifyEvent(key: "dom:ad-progress-mismatch", keyword: "広告異常",
                details: "試合進行 DOM は更新されていますが、配信状態は \(ctx.adState) のままです。\(ctx.summary)") }
        }

        let sig = "\(pageURL)\n\(ctx.adState)"
        let now = Date()
        if adObservationSignature != sig {
            adObservationSignature = sig; adObservationStartedAt = now; adLoopNotificationSignature = ""; return
        }
        adObservationStartedAt = adObservationStartedAt ?? now
        let elapsed = now.timeIntervalSince(adObservationStartedAt!)
        guard elapsed >= adLoopThresholdSeconds, adLoopNotificationSignature != sig else { return }
        adLoopNotificationSignature = sig
        Task { await notifyEvent(key: "dom:ad-loop", keyword: "広告ループ",
            details: "MLB.TV が \(ctx.adState) のまま \(Int(elapsed)) 秒継続しています。") }
    }

    // -----------------------------------------------------------------------
    // カレンダー
    // -----------------------------------------------------------------------

    private func applyCalendarStateIfNeeded(using ctx: BaseballContext, sourceURLString: String) {
        guard let sourceURL = URL(string: sourceURLString), CalendarResolver.isCalendarURL(sourceURL) else { return }
        guard let watchURL = ctx.watchURL else {
            calendarResolution = nil
            calendarStatus = "AI が watch URL を特定できませんでした"; return
        }
        let res = CalendarResolution(sourceURL: sourceURL, targetURL: watchURL,
                                     startDate: ctx.scheduledStartDate,
                                     targetLabel: ctx.summary.isEmpty ? watchURL.absoluteString : ctx.summary,
                                     timeLabel: ctx.scheduledTimeText)
        calendarResolution = res
        calendarStatus = res.summary
        if let d = ctx.scheduledStartDate { automationStartDate = d }
    }

    private func refreshCalendarState() {
        let trimmed = automationURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { calendarResolution = nil; calendarStatus = "未使用"; return }
        guard let url = validatedAutomationSourceURL() else { calendarResolution = nil; calendarStatus = "URL不正"; return }
        guard CalendarResolver.isCalendarURL(url) else { calendarResolution = nil; calendarStatus = "通常URL"; return }
        if let res = calendarResolution, CalendarResolver.urlsMatch(res.sourceURL, url) {
            calendarStatus = res.summary; return
        }
        calendarResolution = nil; calendarStatus = "読取待ち"
    }

    // -----------------------------------------------------------------------
    // 自動化スケジュール
    // -----------------------------------------------------------------------

    private func refreshAutomationSchedule() {
        automationTimer?.invalidate(); automationTimer = nil
        guard autoOpenTargetPage || autoStartMonitoringAtSchedule else {
            automationStatus = "自動化オフ"; return
        }
        if autoOpenTargetPage, automationURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            automationStatus = "URL未設定"; return
        }
        let interval = automationStartDate.timeIntervalSinceNow
        if interval <= 0 {
            automationStatus = "予定時刻到達"
            Task { await executeScheduledAutomation(trigger: "予定時刻到達") }
            return
        }
        automationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.executeScheduledAutomation(trigger: "予定時刻到達") }
        }
        automationStatus = "待機中: \(DateFormatter.localizedString(from: automationStartDate, dateStyle: .short, timeStyle: .short))"
    }

    private func executeScheduledAutomation(trigger: String) async {
        guard !isScheduledAutomationRunning else { return }
        isScheduledAutomationRunning = true
        defer { isScheduledAutomationRunning = false }

        if autoOpenTargetPage {
            guard let url = validatedAutomationSourceURL() else {
                lastError = "自動オープン用の URL が無効です。"
                automationStatus = "\(trigger): 失敗"; return
            }
            let target = resolvedTargetURL(from: url) ?? url
            browserController?.navigate(to: target)
        }
        if autoStartMonitoringAtSchedule {
            if autoOpenTargetPage { try? await Task.sleep(for: .seconds(1.5)) }
            await startMonitoring()
            guard isRunning else { automationStatus = "\(trigger): Start Watching failed"; return }
        }
        automationStatus = autoOpenTargetPage && autoStartMonitoringAtSchedule
            ? "\(trigger): Opened browser & Start Watching"
            : autoOpenTargetPage ? "\(trigger): ブラウザを開きました"
            : "\(trigger): Start Watching"
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    func validatedAutomationSourceURL() -> URL? {
        let trimmed = automationURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private func resolvedTargetURL(from sourceURL: URL) -> URL? {
        guard CalendarResolver.isCalendarURL(sourceURL),
              let res = calendarResolution, CalendarResolver.urlsMatch(res.sourceURL, sourceURL)
        else { return nil }
        return res.targetURL
    }

    private func resetSessionState() {
        lastError = ""; lastMatchKeyword = ""; lastMatchTranscript = ""
        recentMatches.removeAll(); lastNotificationAt.removeAll()
        lastDOMNotificationSignature = ""
        snapshotInterpretationTask?.cancel(); snapshotInterpretationTask = nil
        latestSnapshotSignature = ""
        activeProfileLabel = "未選択"; profileReason = "まだありません"
        pageSummary = "まだありません"; baseballSummary = "未検出"
        baseballContext = nil
        soundAutomationStatus = autoSoundControlEnabled ? "待機" : "手動"
        lastForegroundSignature = ""; adObservationSignature = ""
        adObservationStartedAt = nil; adLoopNotificationSignature = ""
        lastBaseballProgressSignature = ""
    }

    private func tearDown() async {
        snapshotInterpretationTask?.cancel()
        restoreSoundIfNeeded()
        isRunning = false
    }

    private func surfaceError(_ error: Error) async {
        lastError = error.localizedDescription
        statusMessage = "失敗"
        await tearDown()
    }

    private func parsedKeywords(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func snapshotSignature(_ s: PageSnapshotEnvelope) -> String {
        [s.page.title, s.page.url, s.page.headings.joined(separator: "|"),
         s.page.highlights.joined(separator: "|"), s.page.visibleText].joined(separator: "\n")
    }
}

// ---------------------------------------------------------------------------
// AppError
// ---------------------------------------------------------------------------

enum AppError: LocalizedError {
    case notificationDenied

    var errorDescription: String? {
        switch self {
        case .notificationDenied:
            return "通知権限がありません。設定アプリで通知を許可してください。"
        }
    }
}
