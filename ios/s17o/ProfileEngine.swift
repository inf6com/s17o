import Foundation
import FoundationModels

// ---------------------------------------------------------------------------
// Profile definitions (macOS 版と同一 JSON フォーマット)
// ---------------------------------------------------------------------------

enum ProfileSchema: String, Codable, Equatable {
    case baseballV1   = "baseball_v1"
    case genericLiveV1 = "generic_live_v1"
}

struct ProfileDefinition: Identifiable, Equatable {
    let id: String
    let displayName: String
    let summary: String
    let schema: ProfileSchema
    let promptHint: String

    var presetProfile: PresetProfile? { PresetProfile(rawValue: id) }
}

enum PresetProfile: String, CaseIterable {
    case baseball
    case soccer
    case americanFootball = "american_football"
    case musicConcert     = "music_concert"
    case creatorStream    = "creator_stream"

    nonisolated var displayName: String {
        switch self {
        case .baseball:         return "Baseball"
        case .soccer:           return "Soccer"
        case .americanFootball: return "American Football"
        case .musicConcert:     return "Music Concert"
        case .creatorStream:    return "Creator Stream"
        }
    }

    nonisolated var definition: ProfileDefinition {
        switch self {
        case .baseball:
            return ProfileDefinition(id: rawValue, displayName: displayName,
                summary: "Watching MLB.TV & mlb.com calendar", schema: .baseballV1,
                promptHint: "MLB.TV、mlb.com schedule、野球中継、打者、投手、回、広告状態を扱います。")
        case .soccer:
            return ProfileDefinition(id: rawValue, displayName: displayName,
                summary: "Watching soccer stream", schema: .genericLiveV1,
                promptHint: "association football、match clock、half、lineup、set piece を扱います。")
        case .americanFootball:
            return ProfileDefinition(id: rawValue, displayName: displayName,
                summary: "Watching American football stream", schema: .genericLiveV1,
                promptHint: "American football、down、drive、quarter、possession を扱います。")
        case .musicConcert:
            return ProfileDefinition(id: rawValue, displayName: displayName,
                summary: "Watching music concert stream", schema: .genericLiveV1,
                promptHint: "concert、setlist、encore、intermission、performance segment を扱います。")
        case .creatorStream:
            return ProfileDefinition(id: rawValue, displayName: displayName,
                summary: "Watching creator stream", schema: .genericLiveV1,
                promptHint: "creator stream、segment change、break、ad break、guest change を扱います。")
        }
    }
}

// ---------------------------------------------------------------------------
// Context types (macOS 版と同一)
// ---------------------------------------------------------------------------

struct BaseballContext: Equatable {
    var pageKind: String
    var gameState: String
    var inningHalf: String?
    var currentBatter: String?
    var previousBatter: String?
    var onDeck: String?
    var pitcher: String?
    var outs: String?
    var adState: String
    var playbackState: String
    var watchURL: URL?
    var scheduledDateText: String?
    var scheduledTimeText: String?
    var scheduledTimeZone: String?
    var scheduledStartDate: Date?
    var confidence: Double

    nonisolated var summary: String {
        var parts = ["ページ: \(pageKind)", "状態: \(gameState)", "配信: \(adState)", "再生: \(playbackState)"]
        if let v = inningHalf,     !v.isEmpty { parts.append("回: \(v)") }
        if let v = currentBatter,  !v.isEmpty { parts.append("打者: \(v)") }
        if let v = previousBatter, !v.isEmpty { parts.append("前打者: \(v)") }
        if let v = onDeck,         !v.isEmpty { parts.append("次打者: \(v)") }
        if let v = pitcher,        !v.isEmpty { parts.append("投手: \(v)") }
        if let v = outs,           !v.isEmpty { parts.append("アウト: \(v)") }
        return parts.joined(separator: " / ")
    }
}

struct GenericProfileContext: Equatable {
    let summary: String
    let phase: String?
    let currentActor: String?
    let nextActor: String?
    let counterpart: String?
    let breakState: String
    let confidence: Double
}

enum ProfilePayload: Equatable {
    case baseball(BaseballContext)
    case generic(GenericProfileContext)
}

struct DOMMatch: Equatable {
    let keyword: String
    let reason: String
    let details: String
    let signature: String
}

struct ProfileSelectionState: Equatable {
    let profile: ProfileDefinition
    let confidence: Double
    let reason: String
}

struct InterpretedPage {
    let selection: ProfileSelectionState
    let summary: String
    let payload: ProfilePayload
    let domMatch: DOMMatch?
}

// ---------------------------------------------------------------------------
// Foundation Models output shapes (macOS 版と同一)
// ---------------------------------------------------------------------------

@available(iOS 26.0, *)
@Generable
private struct ProfileSelectionOutput {
    @Guide(description: "Return exactly one profile id from the supplied profile catalog.")
    let selectedProfile: String
    let reason: String
    let confidence: Double
}

@available(iOS 26.0, *)
@Generable
private struct BaseballProfileOutput {
    @Guide(description: "Return exactly one page kind: calendar, live_game, watch_stream, ad_break, postgame, unknown.")
    let pageKind: String
    @Guide(description: "Return exactly one game state: scheduled, live, paused, postgame, unknown.")
    let gameState: String
    let summary: String
    let inningHalf: String?
    let currentActor: String?
    let previousActor: String?
    let nextActor: String?
    let counterpart: String?
    let outs: String?
    @Guide(description: "Return exactly one ad state: live, ad, stuck, unknown.")
    let adState: String
    @Guide(description: "Return exactly one playback state: playing, paused, buffering, stopped, unknown.")
    let playbackState: String
    let watchURL: String?
    let scheduleDateText: String?
    let scheduleTimeText: String?
    let scheduleTimeZone: String?
    let confidence: Double
}

@available(iOS 26.0, *)
@Generable
private struct GenericProfileOutput {
    let summary: String
    let phase: String?
    let currentActor: String?
    let nextActor: String?
    let counterpart: String?
    @Guide(description: "Return exactly one break state: live, break, ad, stuck, unknown.")
    let breakState: String
    let confidence: Double
}

// ---------------------------------------------------------------------------
// ProfileEngine (macOS ProfileEngine と同一ロジック)
// ---------------------------------------------------------------------------

enum ProfileEngineError: LocalizedError {
    case unsupportedOS
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Foundation Models を使用するには iOS 26.0 以降が必要です。"
        case .modelUnavailable(let d):
            return "AI モデルを使用できません: \(d)"
        }
    }
}

actor ProfileEngine {
    private let profilesByID: [String: ProfileDefinition]

    init() {
        var dict = Dictionary(uniqueKeysWithValues: PresetProfile.allCases.map { ($0.rawValue, $0.definition) })
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("s17o/profiles", isDirectory: true)
        if let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension.lowercased() == "json" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        {
            for url in urls {
                guard let data = try? Data(contentsOf: url),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id          = obj["id"] as? String,
                      let displayName = obj["displayName"] as? String,
                      let summary     = obj["summary"] as? String,
                      let schemaRaw   = obj["schema"] as? String,
                      let schema      = ProfileSchema(rawValue: schemaRaw),
                      let promptHint  = obj["promptHint"] as? String
                else { continue }
                dict[id] = ProfileDefinition(id: id, displayName: displayName,
                                             summary: summary, schema: schema, promptHint: promptHint)
            }
        }
        self.profilesByID = dict
    }

    func ensureAvailable() throws {
        guard #available(iOS 26.0, *) else { throw ProfileEngineError.unsupportedOS }
        let model = SystemLanguageModel.default
        if case .unavailable(let reason) = model.availability {
            throw ProfileEngineError.modelUnavailable(String(describing: reason))
        }
    }

    func interpret(
        snapshot: PageSnapshotEnvelope,
        keywords: [String],
        referenceDate: Date
    ) async throws -> InterpretedPage {
        guard #available(iOS 26.0, *) else { throw ProfileEngineError.unsupportedOS }
        try ensureAvailable()

        let digest = SnapshotDigest(snapshot: snapshot)
        let selection = try await selectProfile(using: digest)

        switch selection.profile.schema {
        case .baseballV1:
            let ctx = try await extractBaseballContext(using: digest, referenceDate: referenceDate)
            let match = DOMMatchResolver.find(for: selection.profile, payload: .baseball(ctx),
                                              keywords: keywords, signature: digest.signature)
            return InterpretedPage(selection: selection, summary: ctx.summary,
                                   payload: .baseball(ctx), domMatch: match)
        case .genericLiveV1:
            let ctx = try await extractGenericContext(for: selection.profile, using: digest)
            let match = DOMMatchResolver.find(for: selection.profile, payload: .generic(ctx),
                                              keywords: keywords, signature: digest.signature)
            return InterpretedPage(selection: selection, summary: ctx.summary,
                                   payload: .generic(ctx), domMatch: match)
        }
    }

    @available(iOS 26.0, *)
    private func selectProfile(using digest: SnapshotDigest) async throws -> ProfileSelectionState {
        let catalog = profilesByID.values
            .sorted { $0.id < $1.id }
            .map { "\($0.id): \($0.displayName) / \($0.summary) / \($0.promptHint)" }
            .joined(separator: "\n")

        let session = LanguageModelSession(
            instructions: """
            You are the profile selector for s17o.
            You must choose exactly one profile id from the supplied profile catalog.
            Use only the provided local DOM snapshot.
            Do not invent page content that is not visible.
            Valid profile ids:
            \(catalog)
            """
        )
        let response = try await session.respond(to: digest.promptBody(), generating: ProfileSelectionOutput.self)
        guard let profile = profilesByID[response.content.selectedProfile] else {
            throw ProfileEngineError.modelUnavailable("不正な profile: \(response.content.selectedProfile)")
        }
        return ProfileSelectionState(profile: profile, confidence: response.content.confidence,
                                     reason: response.content.reason)
    }

    @available(iOS 26.0, *)
    private func extractBaseballContext(using digest: SnapshotDigest, referenceDate: Date) async throws -> BaseballContext {
        let session = LanguageModelSession(
            instructions: """
            You extract structured baseball state for s17o from a local DOM snapshot.
            Use only visible local DOM content. Do not guess hidden data. If a field is missing, return null.
            watchURL must be one of the provided visible links when the page is a schedule page.
            scheduleDateText and scheduleTimeText must be copied from visible DOM text as-is.
            scheduleTimeZone must be a short timezone label such as PT, PDT, ET, EDT, JST when visible. If not visible, return null.
            currentActor = current batter. nextActor = next batter or on deck. previousActor = previous batter. counterpart = pitcher.
            """
        )
        let response = try await session.respond(to: digest.promptBody(), generating: BaseballProfileOutput.self)
        let o = response.content

        let watchURL: URL?
        if let s = o.watchURL, !s.isEmpty { watchURL = URL(string: s) } else { watchURL = nil }

        let startDate = ScheduleDateResolver.resolve(
            dateText: o.scheduleDateText, timeText: o.scheduleTimeText,
            explicitTimeZone: o.scheduleTimeZone, referenceDate: referenceDate)

        return BaseballContext(
            pageKind: o.pageKind, gameState: o.gameState, inningHalf: o.inningHalf,
            currentBatter: o.currentActor, previousBatter: o.previousActor, onDeck: o.nextActor,
            pitcher: o.counterpart, outs: o.outs, adState: o.adState, playbackState: o.playbackState,
            watchURL: watchURL, scheduledDateText: o.scheduleDateText, scheduledTimeText: o.scheduleTimeText,
            scheduledTimeZone: o.scheduleTimeZone, scheduledStartDate: startDate, confidence: o.confidence)
    }

    @available(iOS 26.0, *)
    private func extractGenericContext(for profile: ProfileDefinition, using digest: SnapshotDigest) async throws -> GenericProfileContext {
        let session = LanguageModelSession(
            instructions: """
            You extract structured state for the \(profile.id) profile from a local DOM snapshot.
            Use only visible local DOM content. Do not guess hidden data.
            summary must be short and factual.
            phase should capture the current segment of the live event.
            currentActor, nextActor, counterpart should be factual visible names or roles if present.
            Profile summary: \(profile.summary)
            Profile hint: \(profile.promptHint)
            """
        )
        let response = try await session.respond(to: digest.promptBody(), generating: GenericProfileOutput.self)
        let o = response.content
        return GenericProfileContext(summary: o.summary, phase: o.phase, currentActor: o.currentActor,
                                     nextActor: o.nextActor, counterpart: o.counterpart,
                                     breakState: o.breakState, confidence: o.confidence)
    }
}

// ---------------------------------------------------------------------------
// SnapshotDigest
// ---------------------------------------------------------------------------

private struct SnapshotDigest {
    let title: String
    let url: String
    let headings: [String]
    let highlights: [String]
    let visibleText: String
    let links: [VisibleLink]

    init(snapshot: PageSnapshotEnvelope) {
        title       = snapshot.page.title
        url         = snapshot.page.url
        headings    = snapshot.page.headings
        highlights  = snapshot.page.highlights
        visibleText = snapshot.page.visibleText
        links       = snapshot.page.links ?? []
    }

    var signature: String {
        let linkSig = links.map { "\($0.text)\t\($0.href)" }.joined(separator: "|")
        return [title, url, headings.joined(separator: "|"),
                highlights.joined(separator: "|"), linkSig, visibleText].joined(separator: "\n")
    }

    func promptBody() -> String {
        let linkBlock = links.isEmpty ? "[]"
            : links.map { "- text: \($0.text)\n  href: \($0.href)" }.joined(separator: "\n")
        return """
        title:
        \(title)

        url:
        \(url)

        headings:
        \(headings.joined(separator: "\n"))

        highlights:
        \(highlights.joined(separator: "\n"))

        links:
        \(linkBlock)

        visible_text:
        \(visibleText)
        """
    }
}

// ---------------------------------------------------------------------------
// DOMMatchResolver (macOS 版と同一)
// ---------------------------------------------------------------------------

enum DOMMatchResolver {
    nonisolated static func find(for profile: ProfileDefinition, payload: ProfilePayload,
                                  keywords: [String], signature: String) -> DOMMatch? {
        let normed = keywords.map(normalize)
        guard !normed.isEmpty else { return nil }

        switch (profile.schema, payload) {
        case let (.baseballV1, .baseball(ctx)):
            let fields: [(String, String?)] = [
                ("現在打者", ctx.currentBatter), ("前打者", ctx.previousBatter),
                ("次打者", ctx.onDeck), ("投手", ctx.pitcher),
            ]
            for (label, value) in fields {
                guard let value else { continue }
                let nv = normalize(value)
                if let kw = normed.first(where: { nv.contains($0) }) {
                    let details = "\(label)で \(kw) を検出しました: \(value)\(ctx.summary.isEmpty ? "" : " (\(ctx.summary))")"
                    return DOMMatch(keyword: kw, reason: label, details: details, signature: signature)
                }
            }
            return nil
        case let (_, .generic(ctx)):
            let fields = [ctx.currentActor, ctx.nextActor, ctx.counterpart, ctx.summary, ctx.phase].compactMap { $0 }
            for field in fields {
                let nv = normalize(field)
                if let kw = normed.first(where: { nv.contains($0) }) {
                    return DOMMatch(keyword: kw, reason: "profile",
                                   details: "profile で \(kw) を検出しました: \(field)", signature: signature)
                }
            }
            return nil
        default:
            return nil
        }
    }

    nonisolated private static func normalize(_ t: String) -> String {
        t.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

// ---------------------------------------------------------------------------
// ScheduleDateResolver (macOS 版と同一)
// ---------------------------------------------------------------------------

enum ScheduleDateResolver {
    nonisolated private static let timePattern   = #"\b(\d{1,2}):(\d{2})\s*([AaPp][Mm])\b"#
    nonisolated private static let monthPattern  = #"\b(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+(\d{1,2})\b"#
    nonisolated private static let numericPattern = #"\b(\d{1,2})/(\d{1,2})\b"#

    nonisolated static func resolve(dateText: String?, timeText: String?,
                                     explicitTimeZone: String?, referenceDate: Date) -> Date? {
        guard let dateText = trim(dateText), let timeText = trim(timeText),
              let timeMatch = timeText.range(of: timePattern, options: .regularExpression)
        else { return nil }

        let extracted = String(timeText[timeMatch])
        let tzLabel   = trim(explicitTimeZone) ?? inferTZ(from: dateText + " " + timeText)
        guard let tz  = timezone(for: tzLabel ?? "PT") else { return nil }
        guard let md  = parseMonthDay(from: dateText, referenceDate: referenceDate) else { return nil }

        let parts = extracted.split(separator: " ")
        guard parts.count == 2 else { return nil }
        let clock = parts[0].split(separator: ":")
        guard clock.count == 2, let rawH = Int(clock[0]), let min = Int(clock[1]) else { return nil }
        let period = parts[1].lowercased()
        let hour: Int
        switch period {
        case "am": hour = rawH == 12 ? 0 : rawH
        case "pm": hour = rawH == 12 ? 12 : rawH + 12
        default: return nil
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var dc = DateComponents()
        dc.year = md.year; dc.month = md.month; dc.day = md.day
        dc.hour = hour; dc.minute = min
        return cal.date(from: dc)
    }

    nonisolated private static func trim(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    nonisolated private static func inferTZ(from text: String) -> String? {
        let up = text.uppercased()
        for l in ["JST","PDT","PST","PT","EDT","EST","ET","CDT","CST","CT","MDT","MST","MT"] where up.contains(l) { return l }
        return nil
    }

    nonisolated private static func parseMonthDay(from text: String, referenceDate: Date) -> (year: Int, month: Int, day: Int)? {
        if let m = text.range(of: monthPattern, options: [.regularExpression, .caseInsensitive]) {
            let fragment = String(text[m]).replacingOccurrences(of: ".", with: "")
            let p = fragment.split(separator: " ")
            guard p.count == 2, let month = monthIndex(from: String(p[0])), let day = Int(p[1]) else { return nil }
            return (adjustedYear(month: month, day: day, ref: referenceDate), month, day)
        }
        if let m = text.range(of: numericPattern, options: .regularExpression) {
            let p = String(text[m]).split(separator: "/")
            guard p.count == 2, let month = Int(p[0]), let day = Int(p[1]) else { return nil }
            return (adjustedYear(month: month, day: day, ref: referenceDate), month, day)
        }
        return nil
    }

    nonisolated private static func adjustedYear(month: Int, day: Int, ref: Date) -> Int {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: ref)
        guard let y = c.year, let rm = c.month, let rd = c.day else {
            return Calendar(identifier: .gregorian).component(.year, from: ref)
        }
        if month < rm - 1 { return y + 1 }
        if month == rm - 1, day < rd { return y + 1 }
        return y
    }

    nonisolated private static func monthIndex(from text: String) -> Int? {
        switch text.lowercased() {
        case "jan","january": return 1; case "feb","february": return 2
        case "mar","march": return 3;   case "apr","april": return 4
        case "may": return 5;           case "jun","june": return 6
        case "jul","july": return 7;    case "aug","august": return 8
        case "sep","sept","september": return 9; case "oct","october": return 10
        case "nov","november": return 11; case "dec","december": return 12
        default: return nil
        }
    }

    nonisolated private static func timezone(for label: String) -> TimeZone? {
        switch label.uppercased() {
        case "JST": return TimeZone(identifier: "Asia/Tokyo")
        case "PT","PDT","PST": return TimeZone(identifier: "America/Los_Angeles")
        case "MT","MDT","MST": return TimeZone(identifier: "America/Denver")
        case "CT","CDT","CST": return TimeZone(identifier: "America/Chicago")
        case "ET","EDT","EST": return TimeZone(identifier: "America/New_York")
        default: return nil
        }
    }
}
