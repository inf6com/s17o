@preconcurrency import AppKit
@preconcurrency import AVFoundation
import Combine
import CoreGraphics
import Foundation
import FoundationModels
import os.log
@preconcurrency import SafariServices
@preconcurrency import SoundAnalysis
import Speech
import SwiftUI
import UserNotifications

struct MatchEvent: Identifiable {
    enum Source: String {
        case audio = "音声"
        case dom = "DOM"
    }

    let id = UUID()
    let timestamp: Date
    let keyword: String
    let details: String
    let source: Source

    var timestampLabel: String {
        Self.formatter.string(from: timestamp)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

enum PresetProfile: String, CaseIterable {
    case baseball
    case soccer
    case americanFootball = "american_football"
    case musicConcert = "music_concert"
    case creatorStream = "creator_stream"

    nonisolated var displayName: String {
        switch self {
        case .baseball:
            return "Baseball"
        case .soccer:
            return "Soccer"
        case .americanFootball:
            return "American Football"
        case .musicConcert:
            return "Music Concert"
        case .creatorStream:
            return "Creator Stream"
        }
    }

    nonisolated var definition: ProfileDefinition {
        switch self {
        case .baseball:
            return ProfileDefinition(
                id: rawValue,
                displayName: displayName,
                summary: "Watching MLB.TV & mlb.com calendar",
                schema: .baseballV1,
                promptHint: "MLB.TV、mlb.com schedule、野球中継、打者、投手、回、広告状態を扱います。"
            )
        case .soccer:
            return ProfileDefinition(
                id: rawValue,
                displayName: displayName,
                summary: "Watching soccer stream",
                schema: .genericLiveV1,
                promptHint: "association football、match clock、half、lineup、set piece を扱います。"
            )
        case .americanFootball:
            return ProfileDefinition(
                id: rawValue,
                displayName: displayName,
                summary: "Watching American football stream",
                schema: .genericLiveV1,
                promptHint: "American football、down、drive、quarter、possession を扱います。"
            )
        case .musicConcert:
            return ProfileDefinition(
                id: rawValue,
                displayName: displayName,
                summary: "Watching music concert stream",
                schema: .genericLiveV1,
                promptHint: "concert、setlist、encore、intermission、performance segment を扱います。"
            )
        case .creatorStream:
            return ProfileDefinition(
                id: rawValue,
                displayName: displayName,
                summary: "Watching creator stream",
                schema: .genericLiveV1,
                promptHint: "creator stream、segment change、break、ad break、guest change を扱います。"
            )
        }
    }
}

enum ProfileSchema: String, Codable, Equatable {
    case baseballV1 = "baseball_v1"
    case genericLiveV1 = "generic_live_v1"
}

struct ProfileDefinition: Identifiable, Equatable {
    let id: String
    let displayName: String
    let summary: String
    let schema: ProfileSchema
    let promptHint: String

    var presetProfile: PresetProfile? {
        PresetProfile(rawValue: id)
    }
}

private enum ProfileRegistryError: LocalizedError {
    case invalidManifest(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let details):
            return "profile manifest が不正です: \(details)"
        }
    }
}

private enum ProfileRegistry {
    nonisolated private static let allowedIDPattern = #"^[a-z0-9_]+$"#

    nonisolated static func load() throws -> [String: ProfileDefinition] {
        let directoryURL = try ensureProfileDirectory()
        var definitions = Dictionary(uniqueKeysWithValues: PresetProfile.allCases.map { ($0.rawValue, $0.definition) })

        let manifestURLs = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for manifestURL in manifestURLs {
            let data = try Data(contentsOf: manifestURL)
            guard
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let id = object["id"] as? String,
                let displayName = object["displayName"] as? String,
                let summary = object["summary"] as? String,
                let schemaRawValue = object["schema"] as? String,
                let schema = ProfileSchema(rawValue: schemaRawValue),
                let promptHint = object["promptHint"] as? String
            else {
                throw ProfileRegistryError.invalidManifest("\(manifestURL.lastPathComponent): id/displayName/summary/schema/promptHint が必要です。")
            }
            let definition = try validate(
                id: id,
                displayName: displayName,
                summary: summary,
                schema: schema,
                promptHint: promptHint,
                sourceURL: manifestURL
            )
            definitions[definition.id] = definition
        }

        return definitions
    }

    nonisolated private static func ensureProfileDirectory() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = baseURL
            .appendingPathComponent("s17o", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    nonisolated private static func validate(
        id: String,
        displayName: String,
        summary: String,
        schema: ProfileSchema,
        promptHint: String,
        sourceURL: URL
    ) throws -> ProfileDefinition {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptHint = promptHint.trimmingCharacters(in: .whitespacesAndNewlines)

        guard id.range(of: allowedIDPattern, options: .regularExpression) != nil else {
            throw ProfileRegistryError.invalidManifest("\(sourceURL.lastPathComponent): id は小文字英数字と underscore のみで指定してください。")
        }
        guard !displayName.isEmpty else {
            throw ProfileRegistryError.invalidManifest("\(sourceURL.lastPathComponent): displayName が空です。")
        }
        guard !summary.isEmpty else {
            throw ProfileRegistryError.invalidManifest("\(sourceURL.lastPathComponent): summary が空です。")
        }
        guard !promptHint.isEmpty else {
            throw ProfileRegistryError.invalidManifest("\(sourceURL.lastPathComponent): promptHint が空です。")
        }

        return ProfileDefinition(
            id: id,
            displayName: displayName,
            summary: summary,
            schema: schema,
            promptHint: promptHint
        )
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

struct BaseballContext: Equatable {
    var pageKind: String
    var gameState: String
    var inningHalf: String?
    var currentBatter: String?
    var previousBatter: String?
    var onDeck: String?
    var inTheHole: String?
    var pitcher: String?
    var outs: String?
    var baseRunners: [String]
    var adState: String
    var playbackState: String
    var watchURL: URL?
    var scheduledDateText: String?
    var scheduledTimeText: String?
    var scheduledTimeZone: String?
    var scheduledStartDate: Date?
    var confidence: Double

    nonisolated var summary: String {
        var components = [
            "ページ: \(pageKind)",
            "状態: \(gameState)",
            "配信: \(adState)",
            "再生: \(playbackState)",
        ]

        if let inningHalf, !inningHalf.isEmpty {
            components.append("回: \(inningHalf)")
        }
        if let currentBatter, !currentBatter.isEmpty {
            components.append("打者: \(currentBatter)")
        }
        if let previousBatter, !previousBatter.isEmpty {
            components.append("前打者: \(previousBatter)")
        }
        if let onDeck, !onDeck.isEmpty {
            components.append("次打者: \(onDeck)")
        }
        if !baseRunners.isEmpty {
            components.append("塁上: \(baseRunners.joined(separator: ", "))")
        }
        if let pitcher, !pitcher.isEmpty {
            components.append("投手: \(pitcher)")
        }
        if let outs, !outs.isEmpty {
            components.append("アウト: \(outs)")
        }

        return components.joined(separator: " / ")
    }
}

struct VisibleLink: Decodable, Equatable {
    let text: String
    let href: String
}

struct CalendarResolution {
    let sourceURL: URL
    let targetURL: URL
    let startDate: Date?
    let targetLabel: String
    let timeLabel: String?

    var summary: String {
        if let timeLabel, !timeLabel.isEmpty {
            return "\(targetLabel) / \(timeLabel)"
        }
        return targetLabel
    }
}

struct PageSnapshotEnvelope: Decodable {
    struct Sender: Decodable {
        let tabId: Int?
        let url: String?
        let active: Bool?
        let isFocusedWindow: Bool?
    }

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
    let sender: Sender?
    let sentAt: Double?
}

struct BrowserMessageTypeEnvelope: Decodable {
    let type: String
}

struct BrowserTabCatalogEnvelope: Decodable {
    struct Tab: Decodable {
        let id: Int
        let title: String
        let url: String
        let active: Bool?
        let isFocusedWindow: Bool?
    }

    let type: String
    let reason: String?
    let sentAt: Double?
    let tabs: [Tab]
}

struct BrowserExtensionHandshakeEnvelope: Decodable {
    let type: String
    let name: String?
    let sentAt: Double?
}

struct BrowserTabCandidate: Identifiable, Equatable {
    let id: Int
    let windowIndex: Int
    let tabIndex: Int
    let title: String
    let url: String
    let lastSeen: Date

    var summary: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmedTitle.isEmpty ? url : trimmedTitle
        if windowIndex > 0, tabIndex > 0 {
            return "W\(windowIndex) T\(tabIndex) \(label)"
        }
        return label
    }
}

struct ProfileSelectionState: Equatable {
    let profile: ProfileDefinition
    let confidence: Double
    let reason: String
}

enum ProfilePayload: Equatable {
    case baseball(BaseballContext)
    case generic(GenericProfileContext)
}

struct InterpretedPage {
    let selection: ProfileSelectionState
    let summary: String
    let payload: ProfilePayload
    let domMatch: DOMMatch?
}

struct DOMMatch: Equatable {
    let keyword: String
    let reason: String
    let details: String
    let signature: String
}

private struct SnapshotDigest {
    let title: String
    let url: String
    let headings: [String]
    let highlights: [String]
    let visibleText: String
    let links: [VisibleLink]

    nonisolated init(snapshot: PageSnapshotEnvelope) {
        self.title = snapshot.page.title
        self.url = snapshot.page.url
        self.headings = snapshot.page.headings
        self.highlights = snapshot.page.highlights
        self.visibleText = snapshot.page.visibleText
        self.links = snapshot.page.links ?? []
    }

    nonisolated var signature: String {
        let linkSignature = links.map { "\($0.text)\t\($0.href)" }.joined(separator: "|")
        return [title, url, headings.joined(separator: "|"), highlights.joined(separator: "|"), linkSignature, visibleText]
            .joined(separator: "\n")
    }

    nonisolated func promptBody() -> String {
        let linkBlock: String
        if links.isEmpty {
            linkBlock = "[]"
        } else {
            linkBlock = links
                .map { "- text: \($0.text)\n  href: \($0.href)" }
                .joined(separator: "\n")
        }

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

@available(macOS 26.0, *)
@Generable
private struct ProfileSelectionOutput {
    @Guide(description: "Return exactly one profile id from the supplied profile catalog.")
    let selectedProfile: String
    let reason: String
    let confidence: Double
}

@available(macOS 26.0, *)
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
    @Guide(description: "The batter who is 'in the hole' (2 positions from batting). Return null if not visible.")
    let waitingActor: String?
    let counterpart: String?
    let outs: String?
    @Guide(description: "Names of players currently on base (any of 1st, 2nd, 3rd). Return empty array [] when bases are empty or runners are not visible.")
    let baseRunners: [String]
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

@available(macOS 26.0, *)
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

enum ProfileEngineError: LocalizedError {
    case unsupportedOS
    case modelUnavailable(String)
    case profileRegistryInvalid(String)
    case invalidSelectedProfile(String)
    case invalidWatchURL(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Foundation Models を使用するには macOS 26 以降が必要です。"
        case .modelUnavailable(let details):
            return "AI モデルを使用できません: \(details)"
        case .profileRegistryInvalid(let details):
            return "profile registry を読み込めません: \(details)"
        case .invalidSelectedProfile(let value):
            return "model が不正な profile を返しました: \(value)"
        case .invalidWatchURL(let value):
            return "model が不正な watch URL を返しました: \(value)"
        }
    }
}

private actor ProfileEngine {
    private let model: SystemLanguageModel?
    private let profilesByID: [String: ProfileDefinition]
    private let registryError: Error?

    init() {
        if #available(macOS 26.0, *) {
            self.model = SystemLanguageModel.default
        } else {
            self.model = nil
        }
        do {
            self.profilesByID = try ProfileRegistry.load()
            self.registryError = nil
        } catch {
            self.profilesByID = [:]
            self.registryError = error
        }
    }

    func ensureAvailable() throws {
        guard #available(macOS 26.0, *) else {
            throw ProfileEngineError.unsupportedOS
        }
        if let registryError {
            throw ProfileEngineError.profileRegistryInvalid(registryError.localizedDescription)
        }
        guard let model else {
            throw ProfileEngineError.unsupportedOS
        }
        switch model.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw ProfileEngineError.modelUnavailable(String(describing: reason))
        }
    }

    func availableProfiles() throws -> [ProfileDefinition] {
        try ensureAvailable()
        return profilesByID.values.sorted { $0.id < $1.id }
    }

    func interpret(snapshot: PageSnapshotEnvelope, keywords: [String], referenceDate: Date) async throws -> InterpretedPage {
        guard #available(macOS 26.0, *) else {
            throw ProfileEngineError.unsupportedOS
        }
        try ensureAvailable()

        let digest = SnapshotDigest(snapshot: snapshot)
        let selection = try await selectProfile(using: digest)

        switch selection.profile.schema {
        case .baseballV1:
            let baseball = try await extractBaseballContext(using: digest, referenceDate: referenceDate)
            let domMatch = DOMMatchResolver.find(for: selection.profile, payload: .baseball(baseball), keywords: keywords, signature: digest.signature)
            return InterpretedPage(selection: selection, summary: baseball.summary, payload: .baseball(baseball), domMatch: domMatch)
        case .genericLiveV1:
            let generic = try await extractGenericContext(for: selection.profile, using: digest)
            let domMatch = DOMMatchResolver.find(for: selection.profile, payload: .generic(generic), keywords: keywords, signature: digest.signature)
            return InterpretedPage(selection: selection, summary: generic.summary, payload: .generic(generic), domMatch: domMatch)
        }
    }

    @available(macOS 26.0, *)
    private func selectProfile(using digest: SnapshotDigest) async throws -> ProfileSelectionState {
        let profileCatalog = profilesByID.values
            .sorted { $0.id < $1.id }
            .map { "\($0.id): \($0.displayName) / \($0.summary) / \($0.promptHint)" }
            .joined(separator: "\n")

        let session = LanguageModelSession(
            model: model ?? .default,
            instructions: """
            You are the profile selector for s17o.
            You must choose exactly one profile id from the supplied profile catalog.
            Use only the provided local DOM snapshot.
            Do not invent page content that is not visible.
            Valid profile ids:
            \(profileCatalog)
            """
        )
        let response = try await session.respond(to: digest.promptBody(), generating: ProfileSelectionOutput.self)
        guard let profile = profilesByID[response.content.selectedProfile] else {
            throw ProfileEngineError.invalidSelectedProfile(response.content.selectedProfile)
        }
        return ProfileSelectionState(profile: profile, confidence: response.content.confidence, reason: response.content.reason)
    }

    @available(macOS 26.0, *)
    private func extractBaseballContext(using digest: SnapshotDigest, referenceDate: Date) async throws -> BaseballContext {
        let session = LanguageModelSession(
            model: model ?? .default,
            instructions: """
            You extract structured baseball state for s17o from a local DOM snapshot.
            Use only visible local DOM content.
            Do not guess hidden data.
            If a field is missing, return null.
            watchURL must be one of the provided visible links when the page is a schedule page.
            scheduleDateText and scheduleTimeText must be copied from visible DOM text as-is.
            scheduleTimeZone must be a short timezone label such as PT, PDT, ET, EDT, JST when visible. If not visible, return null.
            currentActor = current batter (AT BAT).
            nextActor = on deck batter (ON DECK, 1 position away).
            waitingActor = in the hole batter (IN THE HOLE, 2 positions away).
            previousActor = previous batter.
            counterpart = pitcher.
            baseRunners = array of player names currently on base (1st, 2nd, or 3rd base). Extract from baserunner indicators or base diagram visible in the DOM. Return [] when bases are empty or not shown.
            """
        )
        let response = try await session.respond(to: digest.promptBody(), generating: BaseballProfileOutput.self)

        let watchURL: URL?
        if let watchURLString = response.content.watchURL, !watchURLString.isEmpty {
            guard let candidate = URL(string: watchURLString) else {
                throw ProfileEngineError.invalidWatchURL(watchURLString)
            }
            watchURL = candidate
        } else {
            watchURL = nil
        }

        let scheduledStartDate = ScheduleDateResolver.resolve(
            dateText: response.content.scheduleDateText,
            timeText: response.content.scheduleTimeText,
            explicitTimeZone: response.content.scheduleTimeZone,
            referenceDate: referenceDate
        )

        return BaseballContext(
            pageKind: response.content.pageKind,
            gameState: response.content.gameState,
            inningHalf: response.content.inningHalf,
            currentBatter: response.content.currentActor,
            previousBatter: response.content.previousActor,
            onDeck: response.content.nextActor,
            inTheHole: response.content.waitingActor,
            pitcher: response.content.counterpart,
            outs: response.content.outs,
            baseRunners: response.content.baseRunners,
            adState: response.content.adState,
            playbackState: response.content.playbackState,
            watchURL: watchURL,
            scheduledDateText: response.content.scheduleDateText,
            scheduledTimeText: response.content.scheduleTimeText,
            scheduledTimeZone: response.content.scheduleTimeZone,
            scheduledStartDate: scheduledStartDate,
            confidence: response.content.confidence
        )
    }

    @available(macOS 26.0, *)
    private func extractGenericContext(for profile: ProfileDefinition, using digest: SnapshotDigest) async throws -> GenericProfileContext {
        let session = LanguageModelSession(
            model: model ?? .default,
            instructions: """
            You extract structured state for the \(profile.id) profile from a local DOM snapshot.
            Use only visible local DOM content.
            Do not guess hidden data.
            summary must be short and factual.
            phase should capture the current segment of the live event.
            currentActor, nextActor, counterpart should be factual visible names or roles if present.
            Profile summary: \(profile.summary)
            Profile hint: \(profile.promptHint)
            """
        )
        let response = try await session.respond(to: digest.promptBody(), generating: GenericProfileOutput.self)
        return GenericProfileContext(
            summary: response.content.summary,
            phase: response.content.phase,
            currentActor: response.content.currentActor,
            nextActor: response.content.nextActor,
            counterpart: response.content.counterpart,
            breakState: response.content.breakState,
            confidence: response.content.confidence
        )
    }
}

private enum DOMMatchResolver {
    nonisolated static func find(for profile: ProfileDefinition, payload: ProfilePayload, keywords: [String], signature: String) -> DOMMatch? {
        let normalizedKeywords = keywords.map(normalize)
        guard !normalizedKeywords.isEmpty else {
            return nil
        }

        switch (profile.schema, payload) {
        case let (.baseballV1, .baseball(context)):
            let fields: [(String, String?)] = [
                ("現在打者", context.currentBatter),
                ("前打者", context.previousBatter),
                ("次打者", context.onDeck),
                ("控え打者", context.inTheHole),
                ("投手", context.pitcher),
            ]

            for (label, value) in fields {
                guard let value else {
                    continue
                }
                let normalizedValue = normalize(value)
                if let keyword = normalizedKeywords.first(where: { normalizedValue.contains($0) }) {
                    let details = "\(label)で \(keyword) を検出しました: \(value)\(context.summary.isEmpty ? "" : " (\(context.summary))")"
                    return DOMMatch(keyword: keyword, reason: label, details: details, signature: signature)
                }
            }

            for runner in context.baseRunners {
                let normalizedValue = normalize(runner)
                if let keyword = normalizedKeywords.first(where: { normalizedValue.contains($0) }) {
                    let details = "塁上で \(keyword) を検出しました: \(runner)\(context.summary.isEmpty ? "" : " (\(context.summary))")"
                    return DOMMatch(keyword: keyword, reason: "塁上", details: details, signature: signature)
                }
            }
            return nil

        case let (_, .generic(context)):
            let fields = [
                context.currentActor,
                context.nextActor,
                context.counterpart,
                context.summary,
                context.phase,
            ]
            .compactMap { $0 }

            for field in fields {
                let normalizedValue = normalize(field)
                if let keyword = normalizedKeywords.first(where: { normalizedValue.contains($0) }) {
                    return DOMMatch(keyword: keyword, reason: "profile", details: "profile で \(keyword) を検出しました: \(field)", signature: signature)
                }
            }
            return nil

        default:
            return nil
        }
    }

    nonisolated private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

private enum ScheduleDateResolver {
    nonisolated private static let timePattern = #"\b(\d{1,2}):(\d{2})\s*([AaPp][Mm])\b"#
    nonisolated private static let monthPattern = #"\b(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+(\d{1,2})\b"#
    nonisolated private static let numericDatePattern = #"\b(\d{1,2})/(\d{1,2})\b"#

    nonisolated static func resolve(dateText: String?, timeText: String?, explicitTimeZone: String?, referenceDate: Date) -> Date? {
        guard
            let dateText = normalize(dateText),
            let timeText = normalize(timeText),
            let timeMatch = timeText.range(of: timePattern, options: .regularExpression)
        else {
            return nil
        }

        let extractedTime = String(timeText[timeMatch])
        let timezoneLabel = normalize(explicitTimeZone) ?? inferTimeZone(from: dateText + " " + timeText)
        guard let sourceTimeZone = timezone(for: timezoneLabel ?? "PT") else {
            return nil
        }

        guard let monthDay = parseMonthDay(from: dateText, referenceDate: referenceDate) else {
            return nil
        }

        let components = extractedTime.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        guard components.count == 2 else {
            return nil
        }
        let clock = components[0].split(separator: ":")
        guard clock.count == 2,
              let rawHour = Int(clock[0]),
              let minute = Int(clock[1]) else {
            return nil
        }

        let period = components[1].lowercased()
        let hour: Int
        switch period {
        case "am":
            hour = rawHour == 12 ? 0 : rawHour
        case "pm":
            hour = rawHour == 12 ? 12 : rawHour + 12
        default:
            return nil
        }

        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.timeZone = sourceTimeZone

        var dateComponents = DateComponents()
        dateComponents.year = monthDay.year
        dateComponents.month = monthDay.month
        dateComponents.day = monthDay.day
        dateComponents.hour = hour
        dateComponents.minute = minute

        return sourceCalendar.date(from: dateComponents)
    }

    nonisolated private static func normalize(_ text: String?) -> String? {
        guard let text else {
            return nil
        }
        let normalized = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    nonisolated private static func inferTimeZone(from text: String) -> String? {
        let normalized = text.uppercased()
        for label in ["JST", "PDT", "PST", "PT", "EDT", "EST", "ET", "CDT", "CST", "CT", "MDT", "MST", "MT"] where normalized.contains(label) {
            return label
        }
        return nil
    }

    nonisolated private static func parseMonthDay(from text: String, referenceDate: Date) -> (year: Int, month: Int, day: Int)? {
        if let match = text.range(of: monthPattern, options: .regularExpression) {
            let fragment = String(text[match]).replacingOccurrences(of: ".", with: "")
            let parts = fragment.split(separator: " ")
            guard parts.count == 2,
                  let month = monthIndex(from: String(parts[0])),
                  let day = Int(parts[1]) else {
                return nil
            }
            let year = adjustedYear(month: month, day: day, referenceDate: referenceDate)
            return (year, month, day)
        }

        if let match = text.range(of: numericDatePattern, options: .regularExpression) {
            let fragment = String(text[match])
            let parts = fragment.split(separator: "/")
            guard parts.count == 2,
                  let month = Int(parts[0]),
                  let day = Int(parts[1]) else {
                return nil
            }
            let year = adjustedYear(month: month, day: day, referenceDate: referenceDate)
            return (year, month, day)
        }

        return nil
    }

    nonisolated private static func adjustedYear(month: Int, day: Int, referenceDate: Date) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        let reference = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        guard let year = reference.year, let referenceMonth = reference.month, let referenceDay = reference.day else {
            return calendar.component(.year, from: referenceDate)
        }

        if month < referenceMonth - 1 {
            return year + 1
        }
        if month == referenceMonth - 1, day < referenceDay {
            return year + 1
        }
        return year
    }

    nonisolated private static func monthIndex(from text: String) -> Int? {
        switch text.lowercased() {
        case "jan", "january": return 1
        case "feb", "february": return 2
        case "mar", "march": return 3
        case "apr", "april": return 4
        case "may": return 5
        case "jun", "june": return 6
        case "jul", "july": return 7
        case "aug", "august": return 8
        case "sep", "sept", "september": return 9
        case "oct", "october": return 10
        case "nov", "november": return 11
        case "dec", "december": return 12
        default: return nil
        }
    }

    nonisolated private static func timezone(for label: String) -> TimeZone? {
        switch label.uppercased() {
        case "JST":
            return TimeZone(identifier: "Asia/Tokyo")
        case "PT", "PDT", "PST":
            return TimeZone(identifier: "America/Los_Angeles")
        case "MT", "MDT", "MST":
            return TimeZone(identifier: "America/Denver")
        case "CT", "CDT", "CST":
            return TimeZone(identifier: "America/Chicago")
        case "ET", "EDT", "EST":
            return TimeZone(identifier: "America/New_York")
        default:
            return nil
        }
    }
}

enum AppError: LocalizedError {
    case noKeywords
    case screenCaptureDenied
    case speechAuthorizationDenied(String)
    case speechServiceDisabled
    case notificationAuthorizationDenied
    case speechRecognizerUnavailable
    case onDeviceRecognitionUnavailable
    case noDisplay
    case audioConversionFailed
    case calendarReadFailed(String)
    case invalidAutomationURL
    case browserUnavailable
    case pageOpenFailed(String)
    case audioControlFailed(String)
    case audioInferenceUnavailable(String)
    case audioSampleStorageFailed(String)

    var errorDescription: String? {
        switch self {
        case .noKeywords:
            return "少なくとも1つのキーワードを指定してください。"
        case .screenCaptureDenied:
            return "画面収録権限がありません。システム設定で許可後、このアプリを完全に終了して再起動してから再試行してください。"
        case .speechAuthorizationDenied(let status):
            return "Speech 権限が拒否されています: \(status)"
        case .speechServiceDisabled:
            return "Siri と音声入力が無効です。システム設定のキーボードで音声入力を有効にしてください。"
        case .notificationAuthorizationDenied:
            return "通知権限がありません。システム設定で通知を許可してください。"
        case .speechRecognizerUnavailable:
            return "Speech recognizer を初期化できませんでした。"
        case .onDeviceRecognitionUnavailable:
            return "この環境ではオンデバイス音声認識が利用できません。"
        case .noDisplay:
            return "音声取得に使用できる表示先が見つかりません。"
        case .audioConversionFailed:
            return "音声バッファの変換に失敗しました。"
        case .calendarReadFailed(let details):
            return "MLBカレンダー読取に失敗しました: \(details)"
        case .invalidAutomationURL:
            return "自動オープン用の URL が無効です。http または https の URL を指定してください。"
        case .browserUnavailable:
            return "ブラウザを起動できませんでした。"
        case .pageOpenFailed(let details):
            return "対象ページを開けませんでした: \(details)"
        case .audioControlFailed(let details):
            return "ブラウザ音声の制御に失敗しました: \(details)"
        case .audioInferenceUnavailable(let details):
            return "音声AIの初期化に失敗しました: \(details)"
        case .audioSampleStorageFailed(let details):
            return "音声サンプル保存に失敗しました: \(details)"
        }
    }
}

struct AudioInferenceSnapshot: Sendable {
    enum Scene: String, Sendable {
        case commentary = "Commentary"
        case ballpark = "Ballpark"
        case commercial = "Commercial"
        case quiet = "Silence"
        case mixed = "Mixed"
    }

    let scene: Scene
    let sceneConfidence: Double
    let primaryLabel: String
    let primaryConfidence: Double
    let speechConfidence: Double
    let crowdConfidence: Double
    let musicConfidence: Double
    let silenceConfidence: Double

    nonisolated var sceneStatusLine: String {
        "\(scene.rawValue) \(Self.percent(sceneConfidence))"
    }

    nonisolated var detailsStatusLine: String {
        "\(primaryLabel) \(Self.percent(primaryConfidence)) / speech \(Self.percent(speechConfidence)) / crowd \(Self.percent(crowdConfidence)) / music \(Self.percent(musicConfidence)) / silence \(Self.percent(silenceConfidence))"
    }

    nonisolated init(result: SNClassificationResult) {
        let top = result.classifications.first
        let scoreMap = Dictionary(uniqueKeysWithValues: result.classifications.map { ($0.identifier, $0.confidence) })
        let speech = Self.maximum(of: [
            scoreMap["speech"],
            scoreMap["shout"],
            scoreMap["yell"],
            scoreMap["whispering"],
            scoreMap["singing"],
            scoreMap["humming"],
            scoreMap["rapping"],
        ])
        let crowd = Self.maximum(of: [
            scoreMap["crowd"],
            scoreMap["cheering"],
            scoreMap["applause"],
            scoreMap["chatter"],
            scoreMap["babble"],
            scoreMap["booing"],
        ])
        let music = scoreMap["music"] ?? 0
        let silence = scoreMap["silence"] ?? 0

        let derived: (Scene, Double)
        if silence >= 0.82 {
            derived = (.quiet, silence)
        } else if music >= 0.48, crowd < 0.22 {
            derived = (.commercial, music)
        } else if speech >= 0.52, music < 0.30 {
            derived = (.commentary, speech)
        } else if crowd >= 0.40, crowd >= speech {
            derived = (.ballpark, crowd)
        } else if speech >= 0.34, music >= 0.20, crowd < 0.20 {
            derived = (.commercial, min(1.0, max(speech, music)))
        } else {
            derived = (.mixed, max(speech, max(crowd, max(music, silence))))
        }

        self.scene = derived.0
        self.sceneConfidence = derived.1
        self.primaryLabel = top?.identifier ?? "unknown"
        self.primaryConfidence = top?.confidence ?? 0
        self.speechConfidence = speech
        self.crowdConfidence = crowd
        self.musicConfidence = music
        self.silenceConfidence = silence
    }

    nonisolated private static func maximum(of values: [Double?]) -> Double {
        values.compactMap { $0 }.max() ?? 0
    }

    nonisolated private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

// MARK: - SoundPolicy

/// 音声制御のオーケストレーター。
///
/// DOM チャンネル（打席・塁上情報）と音声チャンネル（シーン分析・キーワード検出）
/// の両シグナルを受け取り、単一の「今ミュートすべきか」の判断を下す。
///
/// ─ アーキテクチャ ──────────────────────────────────────────────────────────
///
///   検出モジュール               シグナル更新                 評価
///   ──────────────────         ──────────────────         ─────────
///   DOM (BaseballContext)  →   keywordPlayerActive        ┐
///   Speech Recognition     →   lastKeywordAudioAt         ├─ evaluate() → Decision
///   AudioInference (Scene) →   isCommercialConfirmed      │
///                          →   isEnglishCommentaryActive  ┘
///
/// 優先順位（高 → 低）:
///   1. キーワード選手アクティブ（DOM or 音声）→ 強制アンミュート
///   2. CM 確定                              → ミュート
///   3. 英語実況中                           → ミュート
///   4. 自動制御ON・キーワード未検出          → ミュート待機
///   5. 全機能オフ                           → 手動（ミュートしない）
///
struct SoundPolicy {

    // MARK: Signal state (updated by detection modules)

    /// DOM: キーワード選手が打席・塁上にいる
    var keywordPlayerActive: Bool = false

    /// Audio: 音声認識がキーワードを最後に検出した時刻（nil = 未検出）
    var lastKeywordAudioAt: Date? = nil

    /// Audio: CM シーンが確定している（updateCommercialAudioObservation がデバウンス後にセット）
    var isCommercialConfirmed: Bool = false

    /// Audio: 英語実況シーンが検出されている（updateCommentaryTrackObservation がセット）
    var isEnglishCommentaryActive: Bool = false

    /// 音声キーワード検出の有効期間（秒）
    /// この時間内は音声検出をアクティブとみなし DOM 更新を待つ
    static let keywordAudioWindow: TimeInterval = 90

    // MARK: Decision

    enum Reason: Equatable {
        case manual          // 全機能オフ → ユーザー手動
        case keywordDOM      // DOM でキーワード選手を検出 → アンミュート
        case keywordAudio    // 音声でキーワードを検出（時限的） → アンミュート
        case commercial      // CM 確定 → ミュート
        case commentary      // 英語実況 → ミュート
        case waiting         // 自動制御ON・キーワード未検出 → ミュート待機
        case standby         // 機能ON・現在は静か/球場音 → アンミュート
    }

    struct Decision: Equatable {
        let muted: Bool
        let reason: Reason

        var soundAutomationStatusLabel: String {
            switch reason {
            case .manual:       return "手動"
            case .keywordDOM:   return "ミュート解除中"
            case .keywordAudio: return "ミュート解除中（音声）"
            case .waiting:      return "ミュート待機"
            case .commercial:   return "ミュート待機"
            case .commentary:   return "ミュート待機"
            case .standby:      return "待機"
            }
        }

        var commercialAudioStatusLabel: String {
            switch reason {
            case .commercial:   return "CMミュート"
            case .keywordDOM, .keywordAudio: return "ミュート解除中"
            default:            return "待機"
            }
        }

        var commentaryTrackStatusLabel: String {
            switch reason {
            case .commentary:   return "英語実況オフ"
            case .commercial:   return "CM中"
            case .keywordDOM, .keywordAudio: return "ミュート解除中"
            default:            return "待機"
            }
        }
    }

    // MARK: Evaluation

    struct Config {
        let autoSoundControlEnabled: Bool
        let suppressCommercialAudioEnabled: Bool
        let suppressEnglishCommentaryEnabled: Bool
    }

    func evaluate(config: Config, at now: Date = Date()) -> Decision {
        // 全機能オフ → 手動モード（ミュートしない）
        guard config.autoSoundControlEnabled
                || config.suppressCommercialAudioEnabled
                || config.suppressEnglishCommentaryEnabled
        else {
            return Decision(muted: false, reason: .manual)
        }

        let keywordAudioRecent = lastKeywordAudioAt
            .map { now.timeIntervalSince($0) < Self.keywordAudioWindow } ?? false

        // 1. キーワード選手アクティブ → 最優先アンミュート
        if config.autoSoundControlEnabled {
            if keywordPlayerActive {
                return Decision(muted: false, reason: .keywordDOM)
            }
            if keywordAudioRecent {
                return Decision(muted: false, reason: .keywordAudio)
            }
        }

        // 2. CM 確定 → ミュート
        if config.suppressCommercialAudioEnabled && isCommercialConfirmed {
            return Decision(muted: true, reason: .commercial)
        }

        // 3. 英語実況 → ミュート
        if config.suppressEnglishCommentaryEnabled && isEnglishCommentaryActive {
            return Decision(muted: true, reason: .commentary)
        }

        // 4. 自動制御ON・キーワード未検出 → ミュート待機
        if config.autoSoundControlEnabled {
            return Decision(muted: true, reason: .waiting)
        }

        // 5. CM/実況機能のみ有効・現在は非対象シーン → アンミュート
        return Decision(muted: false, reason: .standby)
    }

    mutating func reset() {
        keywordPlayerActive = false
        lastKeywordAudioAt = nil
        isCommercialConfirmed = false
        isEnglishCommentaryActive = false
    }
}

final class AudioInferenceEngine: NSObject, SNResultsObserving, @unchecked Sendable {
    nonisolated(unsafe) private let analyzer: SNAudioStreamAnalyzer
    nonisolated(unsafe) private let request: SNClassifySoundRequest
    nonisolated private let onSnapshot: @Sendable (AudioInferenceSnapshot) -> Void
    nonisolated private let onFailure: @Sendable (Error) -> Void
    nonisolated(unsafe) private var framePosition: AVAudioFramePosition = 0

    init(
        streamFormat: AVAudioFormat,
        onSnapshot: @escaping @Sendable (AudioInferenceSnapshot) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws {
        self.analyzer = SNAudioStreamAnalyzer(format: streamFormat)
        self.onSnapshot = onSnapshot
        self.onFailure = onFailure
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.overlapFactor = 0.875
        self.request = request

        super.init()
        try analyzer.add(request, withObserver: self)
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        analyzer.analyze(buffer, atAudioFramePosition: framePosition)
        framePosition += AVAudioFramePosition(buffer.frameLength)
    }

    nonisolated func finish() {
        analyzer.completeAnalysis()
    }

    nonisolated func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let classification = result as? SNClassificationResult else {
            return
        }
        onSnapshot(AudioInferenceSnapshot(result: classification))
    }

    nonisolated func request(_ request: any SNRequest, didFailWithError error: Error) {
        onFailure(error)
    }
}

struct AudioAnalysisChunk: Sendable {
    let capturedAt: Date
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let interleavedSamples: [Float]

    nonisolated var duration: TimeInterval {
        guard sampleRate > 0 else {
            return 0
        }
        return Double(frameCount) / sampleRate
    }

    nonisolated init?(buffer: AVAudioPCMBuffer, capturedAt: Date = Date()) {
        guard let channelData = buffer.floatChannelData else {
            return nil
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else {
            return nil
        }

        var interleavedSamples = [Float]()
        interleavedSamples.reserveCapacity(frameCount * channelCount)

        for frameIndex in 0..<frameCount {
            for channelIndex in 0..<channelCount {
                interleavedSamples.append(channelData[channelIndex][frameIndex])
            }
        }

        self.capturedAt = capturedAt
        self.sampleRate = buffer.format.sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.interleavedSamples = interleavedSamples
    }
}

struct AudioSampleMetadata: Sendable {
    let capturedAt: Date
    let scene: String
    let sceneConfidence: Double
    let primaryLabel: String
    let primaryConfidence: Double
    let speechConfidence: Double
    let crowdConfidence: Double
    let musicConfidence: Double
    let silenceConfidence: Double
    let pageURL: String
    let pageTitle: String
    let activeProfile: String
    let baseballSummary: String
    let monitoredTab: String
    let transcript: String

    nonisolated var jsonObject: [String: Any] {
        let formatter = ISO8601DateFormatter()
        return [
            "capturedAt": formatter.string(from: capturedAt),
            "scene": scene,
            "sceneConfidence": sceneConfidence,
            "primaryLabel": primaryLabel,
            "primaryConfidence": primaryConfidence,
            "speechConfidence": speechConfidence,
            "crowdConfidence": crowdConfidence,
            "musicConfidence": musicConfidence,
            "silenceConfidence": silenceConfidence,
            "pageURL": pageURL,
            "pageTitle": pageTitle,
            "activeProfile": activeProfile,
            "baseballSummary": baseballSummary,
            "monitoredTab": monitoredTab,
            "transcript": transcript,
        ]
    }
}

final class AudioSampleStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "s17o.AudioSampleStore")
    private let baseDirectoryURL: URL
    private let retentionWindow: TimeInterval = 24
    private let captureWindow: TimeInterval = 5
    nonisolated(unsafe) private var chunks: [AudioAnalysisChunk] = []

    nonisolated init() throws {
        let appSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = appSupportURL
            .appendingPathComponent("s17o", isDirectory: true)
            .appendingPathComponent("audio-samples", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        self.baseDirectoryURL = directoryURL
    }

    nonisolated func append(_ chunk: AudioAnalysisChunk) {
        queue.async {
            self.chunks.append(chunk)
            self.pruneLocked(referenceDate: chunk.capturedAt)
        }
    }

    nonisolated func exportRecentWindow(scene: AudioInferenceSnapshot.Scene, metadata: AudioSampleMetadata) throws -> URL? {
        try queue.sync {
            pruneLocked(referenceDate: metadata.capturedAt)

            guard let latestChunk = chunks.last else {
                return nil
            }

            let requiredFrames = Int((latestChunk.sampleRate * captureWindow).rounded())
            var selectedChunks: [AudioAnalysisChunk] = []
            var accumulatedFrames = 0

            for chunk in chunks.reversed() where chunk.sampleRate == latestChunk.sampleRate && chunk.channelCount == latestChunk.channelCount {
                selectedChunks.append(chunk)
                accumulatedFrames += chunk.frameCount
                if accumulatedFrames >= requiredFrames {
                    break
                }
            }

            guard accumulatedFrames >= requiredFrames else {
                return nil
            }

            selectedChunks.reverse()
            let channelCount = latestChunk.channelCount
            var mergedSamples = [Float]()
            mergedSamples.reserveCapacity(accumulatedFrames * channelCount)
            for chunk in selectedChunks {
                mergedSamples.append(contentsOf: chunk.interleavedSamples)
            }

            let excessFrames = accumulatedFrames - requiredFrames
            if excessFrames > 0 {
                mergedSamples.removeFirst(excessFrames * channelCount)
                accumulatedFrames = requiredFrames
            }

            let sceneDirectoryURL = baseDirectoryURL.appendingPathComponent(scene.rawValue.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: sceneDirectoryURL, withIntermediateDirectories: true)

            let stem = Self.fileStem(for: metadata.capturedAt)
            let wavURL = sceneDirectoryURL.appendingPathComponent("\(stem).wav")
            let metadataURL = sceneDirectoryURL.appendingPathComponent("\(stem).json")

            try writeWAV(
                to: wavURL,
                sampleRate: latestChunk.sampleRate,
                channelCount: channelCount,
                frameCount: accumulatedFrames,
                interleavedSamples: mergedSamples
            )

            guard JSONSerialization.isValidJSONObject(metadata.jsonObject) else {
                throw AppError.audioSampleStorageFailed("metadata を JSON に変換できませんでした。")
            }
            let json = try JSONSerialization.data(withJSONObject: metadata.jsonObject, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: metadataURL, options: [.atomic])

            return wavURL
        }
    }

    nonisolated private func pruneLocked(referenceDate: Date) {
        let threshold = referenceDate.addingTimeInterval(-retentionWindow)
        chunks.removeAll { $0.capturedAt < threshold }
    }

    nonisolated private func writeWAV(
        to url: URL,
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int,
        interleavedSamples: [Float]
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            throw AppError.audioSampleStorageFailed("AVAudioFormat を生成できませんでした。")
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw AppError.audioSampleStorageFailed("AVAudioPCMBuffer を生成できませんでした。")
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channelData = buffer.floatChannelData else {
            throw AppError.audioSampleStorageFailed("PCM channel data を取得できませんでした。")
        }

        for frameIndex in 0..<frameCount {
            let baseIndex = frameIndex * channelCount
            for channelIndex in 0..<channelCount {
                channelData[channelIndex][frameIndex] = interleavedSamples[baseIndex + channelIndex]
            }
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let audioFile = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try audioFile.write(from: buffer)
    }

    nonisolated private static func fileStem(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }
}

actor NotificationManager {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorization() async throws {
        let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            SafariBridge.requestNotificationAuthorization(withOptions: UNAuthorizationOptions.alert.rawValue) { allowed, error in
                // Delivered on main queue by SafariBridge
                MainActor.assumeIsolated {
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: allowed)
                }
            }
        }
        guard granted else {
            throw AppError.notificationAuthorizationDenied
        }
    }

    func post(title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == UNErrorDomain,
                       nsError.code == UNError.Code.notificationsNotAllowed.rawValue {
                        continuation.resume(throwing: AppError.notificationAuthorizationDenied)
                        return
                    }
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let appDisplayName = "s17o"
    nonisolated static let browserDisplayName = "Safari"
    nonisolated static let extensionBundleIdentifier = "com.decopin.s17o.Extension"
    static let pageSnapshotNotification = Notification.Name("s17oPageSnapshot")
    static let setupCompleteKey = "s17o.setupComplete"
    static let keywordsKey = "s17o.keywordsText"
    static let defaultKeywords = "Ohtani\nShohei Ohtani"
    static let automationURLKey = "s17o.automationURLText"
    static let automationStartDateKey = "s17o.automationStartDate"
    static let autoOpenTargetPageKey = "s17o.autoOpenTargetPage"
    static let autoStartMonitoringKey = "s17o.autoStartMonitoring"
    static let autoSoundControlKey = "s17o.autoSoundControl"
    static let autoBringToFrontKey = "s17o.autoBringToFront"
    static let suppressCommercialAudioKey = "s17o.suppressCommercialAudio"
    static let suppressEnglishCommentaryKey = "s17o.suppressEnglishCommentary"
    static let captureAudioSamplesKey = "s17o.captureAudioSamples"
    static let lastAutomationFireAtKey = "s17o.lastAutomationFireAt"

    @Published var isSetupComplete: Bool {
        didSet {
            defaults.set(isSetupComplete, forKey: Self.setupCompleteKey)
        }
    }

    func completeSetup() {
        isSetupComplete = true
    }

    @Published var keywordsText: String {
        didSet {
            defaults.set(keywordsText, forKey: Self.keywordsKey)
        }
    }
    @Published var automationURLText: String {
        didSet {
            defaults.set(automationURLText, forKey: Self.automationURLKey)
            refreshConfiguredCalendarState()
            refreshAutomationSchedule()
        }
    }
    @Published var automationStartDate: Date {
        didSet {
            defaults.set(automationStartDate, forKey: Self.automationStartDateKey)
            refreshAutomationSchedule()
        }
    }
    @Published var autoOpenTargetPage: Bool {
        didSet {
            defaults.set(autoOpenTargetPage, forKey: Self.autoOpenTargetPageKey)
            refreshAutomationSchedule()
        }
    }
    @Published var autoStartMonitoringAtSchedule: Bool {
        didSet {
            defaults.set(autoStartMonitoringAtSchedule, forKey: Self.autoStartMonitoringKey)
            refreshAutomationSchedule()
        }
    }
    @Published var autoSoundControlEnabled: Bool {
        didSet {
            defaults.set(autoSoundControlEnabled, forKey: Self.autoSoundControlKey)
            handleAutoSoundToggleChange()
        }
    }
    @Published var autoBringToFrontEnabled: Bool {
        didSet {
            defaults.set(autoBringToFrontEnabled, forKey: Self.autoBringToFrontKey)
            handleAutoBringToFrontToggleChange()
        }
    }
    @Published var suppressCommercialAudioEnabled: Bool {
        didSet {
            defaults.set(suppressCommercialAudioEnabled, forKey: Self.suppressCommercialAudioKey)
            handleCommercialAudioToggleChange()
        }
    }
    @Published var suppressEnglishCommentaryEnabled: Bool {
        didSet {
            defaults.set(suppressEnglishCommentaryEnabled, forKey: Self.suppressEnglishCommentaryKey)
            handleEnglishCommentaryToggleChange()
        }
    }
    @Published var captureAudioSamplesEnabled: Bool {
        didSet {
            defaults.set(captureAudioSamplesEnabled, forKey: Self.captureAudioSamplesKey)
            handleAudioSampleCaptureToggleChange()
        }
    }
    @Published private(set) var pipelineState: MonitoringPipelineState = .idle
    var isRunning: Bool { pipelineState.isActive }
    @Published var statusMessage = "待機"
    @Published var transcript = ""
    @Published var captureSource = "未取得"
    @Published var audioPipelineStatus = "未初期化"
    @Published var audioInferenceStatus = "未初期化"
    @Published var audioSceneStatus = "未判定"
    @Published private(set) var speechPermission = SetupPermissionState.unknown
    @Published private(set) var screenCapturePermission = SetupPermissionState.unknown
    @Published private(set) var notificationPermission = SetupPermissionState.unknown
    @Published private(set) var browserExtensionState = BrowserExtensionState.unknown
    @Published var setupGuidance = "初期設定を確認してください。"
    @Published var lastError = ""
    @Published var lastMatchKeyword = ""
    @Published var lastMatchTranscript = ""
    @Published var recentMatches: [MatchEvent] = []
    /// キーワード検出のたびに新しい値がセットされる（AppDelegate や View が観察して通知・前面表示に使う）
    @Published var latestDetection: MatchEvent? = nil
    @Published var activeProfileLabel = "未選択"
    @Published var profileReason = "まだありません"
    @Published var pageTitle = ""
    @Published var pageURL = ""
    @Published var monitoredTabSummary = "未固定"
    @Published var browserTabCandidates: [BrowserTabCandidate] = []
    @Published var selectedBrowserTabID: Int?
    @Published var pageSummary = "まだありません"
    @Published var baseballSummary = "未検出"
    @Published var pageHighlights = ""
    @Published var lastDOMUpdate = "まだありません"
    @Published var automationStatus = "自動化オフ"
    @Published var calendarStatus = "未使用"
    @Published var soundAutomationStatus = "手動"
    @Published var foregroundAutomationStatus = "手動"
    @Published var commercialAudioStatus = "手動"
    @Published var commentaryTrackStatus = "手動"
    @Published var audioSampleCaptureStatus = "オフ"

    let cooldownSeconds = 45.0
    private let adLoopThresholdSeconds = 180.0

    private let defaults = UserDefaults.standard
    /// 音声キャプチャ・認識・推論を束ねるパイプライン（起動中のみ non-nil）
    private var audioPipeline: AudioPipeline?
    private let profileEngine = ProfileEngine()
    private let notificationManager = NotificationManager()
    private var lastNotificationAt: [String: Date] = [:]
    nonisolated(unsafe) private var distributedObserver: NSObjectProtocol?
    private var lastDOMNotificationSignature = ""
    private var baseballContext: BaseballContext?
    private var genericProfileContext: GenericProfileContext?
    private var monitoredTabID: Int?
    private var connectedBrowserCandidateID: Int?
    private var connectedBrowserTargetURL: String?
    private var userClearedBrowserTarget = false
    private var extensionBrowserTabCandidates: [BrowserTabCandidate] = []
    private var appleScriptBrowserTabCandidates: [BrowserTabCandidate] = []
    private var lastBrowserExtensionHandshakeAt: Date?
    private var automationTimer: Timer?
    private var lastAutomationFireAt: Date?
    private var isScheduledAutomationRunning = false
    /// 音声制御オーケストレーター（単一の判断源）
    private var soundPolicy = SoundPolicy()
    private var appliedSystemMutedState: Bool?
    private var savedSystemVolume: Int?
    private var calendarResolution: CalendarResolution?
    private var lastAcceptedSnapshot: PageSnapshotEnvelope?
    private var lastForegroundSignature = ""
    private var adObservationSignature = ""
    private var adObservationStartedAt: Date?
    private var adLoopNotificationSignature = ""
    private var lastBaseballProgressSignature = ""
    private var latestSnapshotSignature = ""
    private var snapshotInterpretationTask: Task<Void, Never>?
    private var commentarySuppressionState: Bool?
    private var audioCommercialObservationStartedAt: Date?
    private var audioNonCommercialObservationStartedAt: Date?
    private var audioSampleObservationScene: AudioInferenceSnapshot.Scene?
    private var audioSampleObservationStartedAt: Date?
    private var audioSampleLastExportAtByScene: [AudioInferenceSnapshot.Scene: Date] = [:]
    private var audioSampleExportInFlight = false
    private var requiresScreenCaptureRestart = false

    init() {
        let defaults = UserDefaults.standard
        let setupComplete = defaults.bool(forKey: Self.setupCompleteKey)
        self.isSetupComplete = setupComplete
        if setupComplete {
            self.keywordsText = defaults.string(forKey: Self.keywordsKey) ?? Self.defaultKeywords
            self.automationURLText = defaults.string(forKey: Self.automationURLKey) ?? "https://www.mlb.com/dodgers/schedule/"
        } else {
            self.keywordsText = Self.defaultKeywords
            self.automationURLText = "https://www.mlb.com/dodgers/schedule/"
        }
        self.automationStartDate = defaults.object(forKey: Self.automationStartDateKey) as? Date ?? Date()
        self.autoOpenTargetPage = defaults.bool(forKey: Self.autoOpenTargetPageKey)
        self.autoStartMonitoringAtSchedule = defaults.bool(forKey: Self.autoStartMonitoringKey)
        self.autoSoundControlEnabled = defaults.bool(forKey: Self.autoSoundControlKey)
        self.autoBringToFrontEnabled = defaults.bool(forKey: Self.autoBringToFrontKey)
        self.suppressCommercialAudioEnabled = defaults.bool(forKey: Self.suppressCommercialAudioKey)
        self.suppressEnglishCommentaryEnabled = defaults.bool(forKey: Self.suppressEnglishCommentaryKey)
        self.captureAudioSamplesEnabled = defaults.bool(forKey: Self.captureAudioSamplesKey)
        self.lastAutomationFireAt = defaults.object(forKey: Self.lastAutomationFireAtKey) as? Date
        Task { @MainActor [weak self] in
            self?.observePageSnapshots()
            await self?.refreshBrowserControlStateAndWait()
            self?.refreshConfiguredCalendarState()
            self?.refreshAutomationSchedule()
            if self?.autoSoundControlEnabled == true {
                self?.soundAutomationStatus = "待機"
            }
            if self?.autoBringToFrontEnabled == true {
                self?.foregroundAutomationStatus = "待機"
            }
            if self?.suppressCommercialAudioEnabled == true {
                self?.commercialAudioStatus = "待機"
            }
            if self?.suppressEnglishCommentaryEnabled == true {
                self?.commentaryTrackStatus = "待機"
            }
            if self?.captureAudioSamplesEnabled == true {
                self?.audioSampleCaptureStatus = "待機"
            }
            await self?.refreshSetupStatus()
        }
    }

    deinit {
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
    }

    var isMonitoringSetupReady: Bool {
        screenCapturePermission.isGranted &&
        speechPermission.isGranted &&
        notificationPermission.isGranted
    }

    var isBrowserExtensionReady: Bool {
        browserExtensionState.isEnabled
    }

    var isBrowserTargetConnected: Bool {
        connectedBrowserTargetURL != nil
    }

    var speechStatus: String {
        speechPermission.label
    }

    var screenCaptureStatus: String {
        screenCapturePermission.label
    }

    var notificationStatus: String {
        notificationPermission.label
    }

    var browserControlStatus: String {
        browserExtensionState.label
    }

    private var monitoringReadiness: MonitoringReadiness {
        if isRunning {
            return .running
        }
        if screenCapturePermission == .restartRequired {
            return .restartRequired
        }
        if !isMonitoringSetupReady {
            return .setupRequired
        }
        if !isBrowserExtensionReady {
            return .browserExtensionRequired(browserExtensionState)
        }
        if !isBrowserTargetConnected {
            return .browserTargetRequired
        }
        return .ready
    }

    var browserTargetGuidance: String {
        if isBrowserTargetConnected {
            return "対象タブは選択済みです。"
        }
        if !isBrowserCurrentlyRunning() {
            return "\(Self.browserDisplayName) が起動していません。"
        }
        if browserTabCandidates.isEmpty {
            return "\(Self.browserDisplayName) に開いているタブがありません。"
        }
        return "一覧から対象タブを選択してください。"
    }

    var browserGuidance: String {
        if browserExtensionState != .enabled {
            return "\(Self.browserDisplayName) の「機能拡張」で s17o にチェックを入れて有効化してください。"
        }
        if !isRunning {
            if !isBrowserTargetConnected {
                return browserTargetGuidance
            }
            return "\(Self.browserDisplayName) の対象タブは選択済みです。開始を押してください。"
        }
        if monitoredTabSummary == "未固定" {
            if configuredWatchTargetURLPrefix() != nil {
                return "\(Self.browserDisplayName) で対象ページを開いてください。対象ページを検出すると開始します。"
            }
            return "\(Self.browserDisplayName) から対象タブの内容を受信できていません。"
        }
        return "対象タブを使用中です。"
    }

    var screenCaptureSetupActionTitle: String {
        switch screenCapturePermission {
        case .granted:
            return "状態を更新"
        case .restartRequired:
            return "再起動が必要"
        default:
            return "画面収録を許可"
        }
    }

    var speechSetupActionTitle: String {
        switch speechPermission {
        case .granted:
            return "状態を更新"
        case .denied, .restricted:
            return "Speech 設定を開く"
        case .unavailable, .disabled:
            return "音声入力設定を開く"
        default:
            return "Speech を許可"
        }
    }

    var notificationSetupActionTitle: String {
        switch notificationPermission {
        case .granted:
            return "状態を更新"
        case .denied:
            return "通知設定を開く"
        default:
            return "通知を許可"
        }
    }

    var canStartWatching: Bool {
        isMonitoringSetupReady && isBrowserExtensionReady && isBrowserTargetConnected && !isRunning
    }

    func refreshSetupStatus() async {
        if requiresScreenCaptureRestart {
            screenCapturePermission = .restartRequired
        } else {
            screenCapturePermission = CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
        speechPermission = currentSpeechPermission()
        notificationPermission = notificationPermission(for: await notificationManager.authorizationStatus())
        updateSetupGuidance()
        updateIdleStatus()
        if isSetupRelatedError(lastError) {
            lastError = ""
        }
    }

    func handleScreenCaptureSetupAction() async {
        lastError = ""
        statusMessage = "画面収録を確認しています"

        if CGPreflightScreenCaptureAccess() {
            await refreshSetupStatus()
            return
        }

        let granted = CGRequestScreenCaptureAccess()
        requiresScreenCaptureRestart = granted
        screenCapturePermission = granted ? .restartRequired : .denied
        speechPermission = currentSpeechPermission()
        notificationPermission = notificationPermission(for: await notificationManager.authorizationStatus())

        if granted {
            setupGuidance = "画面収録を許可しました。このアプリを完全に終了して再起動してください。"
            if !isRunning {
                statusMessage = "再起動待ち"
            }
            return
        }

        openScreenCapturePreferences()
        updateSetupGuidance()
    }

    func handleSpeechSetupAction() async {
        lastError = ""
        statusMessage = "Speech を確認しています"

        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted:
            speechPermission = currentSpeechPermission()
            openSpeechRecognitionPreferences()
        case .authorized, .notDetermined:
            let status = await KeywordRecognizer.requestAuthorization()
            speechPermission = speechPermission(for: status)
            if speechPermission == .granted {
                speechPermission = speechAvailabilityPermission()
            }
            if speechPermission == .unavailable {
                openSpeechPreferences()
            }
        @unknown default:
            speechPermission = .unknown
        }

        screenCapturePermission = CGPreflightScreenCaptureAccess() ? .granted : .denied
        notificationPermission = notificationPermission(for: await notificationManager.authorizationStatus())
        updateSetupGuidance()
    }

    func handleNotificationSetupAction() async {
        lastError = ""
        statusMessage = "通知を確認しています"

        let currentStatus = await notificationManager.authorizationStatus()
        switch currentStatus {
        case .authorized, .provisional, .ephemeral:
            notificationPermission = .granted
        case .denied:
            notificationPermission = .denied
            openNotificationPreferences()
        case .notDetermined:
            do {
                try await notificationManager.requestAuthorization()
            } catch AppError.notificationAuthorizationDenied {
                notificationPermission = .denied
            } catch {
                await surface(error: error)
                return
            }
            notificationPermission = notificationPermission(for: await notificationManager.authorizationStatus())
            if notificationPermission == .denied {
                openNotificationPreferences()
            }
        @unknown default:
            notificationPermission = .unknown
        }

        screenCapturePermission = CGPreflightScreenCaptureAccess() ? .granted : .denied
        speechPermission = currentSpeechPermission()
        updateSetupGuidance()
    }

    func startMonitoring() async {
        guard pipelineState.canStart else { return }

        resetSessionState(preserveConnectedTarget: true)
        pipelineState = .starting

        let keywords = parsedKeywords(from: keywordsText)
        guard !keywords.isEmpty else {
            pipelineState = .failed("キーワードが設定されていません")
            await surface(error: AppError.noKeywords)
            return
        }

        await refreshSetupStatus()
        guard isMonitoringSetupReady else {
            pipelineState = .idle
            lastError = ""
            statusMessage = "初期設定を完了してください"
            return
        }
        guard isBrowserExtensionReady else {
            pipelineState = .idle
            lastError = ""
            statusMessage = "\(Self.browserDisplayName)拡張待ち"
            return
        }
        guard isBrowserTargetConnected else {
            pipelineState = .idle
            lastError = ""
            statusMessage = "対象タブ未選択"
            return
        }

        do {
            statusMessage = "開始中"
            try ensureScreenCaptureAuthorization()
            try ensureSpeechAuthorization()
            try await ensureNotificationAuthorization()

            audioSampleCaptureStatus = captureAudioSamplesEnabled ? "待機" : "オフ"

            let pipeline = AudioPipeline(
                keywords: keywords,
                captureAudioSamples: captureAudioSamplesEnabled,
                onSpeechMatch: { [weak self] keyword, text in
                    Task { await self?.handleAudioMatch(keyword: keyword, transcript: text) }
                },
                onTranscript: { [weak self] text in
                    self?.transcript = text
                },
                onInference: { [weak self] snapshot in
                    self?.handleAudioInferenceSnapshot(snapshot)
                },
                onPipelineStatus: { [weak self] descriptor in
                    self?.audioPipelineStatus = descriptor
                },
                onSourceChange: { [weak self] source in
                    self?.captureSource = source
                },
                onFailure: { [weak self] error in
                    await self?.surface(error: error)
                },
                onCaptionMatch: { [weak self] keyword, segment in
                    Task { await self?.handleAudioMatch(keyword: keyword, transcript: segment.text) }
                }
            )

            try await pipeline.start()
            self.audioPipeline = pipeline
            pipelineState = .running
            statusMessage = "開始中"
        } catch {
            pipelineState = .failed(error.localizedDescription)
            await surface(error: error)
        }
    }

    func stopMonitoring() async {
        await tearDownPipeline()
        updateIdleStatus()
    }

    func runAutomationNow() async {
        await executeScheduledAutomation(trigger: "手動実行")
    }

    func openConfiguredTargetPageNow() async {
        do {
            try await openConfiguredTargetPage()
            try? await Task.sleep(for: .milliseconds(400))
            refreshBrowserTabCandidates()
            automationStatus = "\(Self.browserDisplayName) を開きました"
        } catch {
            lastError = error.localizedDescription
            automationStatus = "URL オープン失敗"
        }
    }

    func connectBrowserTarget() async {
        lastError = ""

        do {
            guard !browserTabCandidates.isEmpty else {
                throw AppError.pageOpenFailed("\(Self.browserDisplayName) のタブ一覧をまだ取得できていません。")
            }
            guard let selectedBrowserTabID,
                  browserTabCandidates.contains(where: { $0.id == selectedBrowserTabID }) else {
                throw AppError.pageOpenFailed("開いているタブ一覧から対象タブを選択してください。")
            }
            selectBrowserTab(selectedBrowserTabID)
            updateIdleStatus()
        } catch {
            await surface(error: error)
        }
    }

    func selectBrowserTab(_ tabID: Int?) {
        selectedBrowserTabID = tabID
        userClearedBrowserTarget = (tabID == nil)

        guard let tabID,
              let selectedTab = browserTabCandidates.first(where: { $0.id == tabID }) else {
            connectedBrowserCandidateID = nil
            connectedBrowserTargetURL = nil
            if !isRunning {
                monitoredTabID = nil
                monitoredTabSummary = "未固定"
            }
            updateIdleStatus()
            return
        }

        connectedBrowserCandidateID = tabID
        connectedBrowserTargetURL = normalizedTabMatchURL(selectedTab.url)
        if !isRunning {
            monitoredTabID = nil
            monitoredTabSummary = selectedTab.summary
        }
        pageURL = selectedTab.url
        pageTitle = selectedTab.title
        updateIdleStatus()
    }

    func disconnectBrowserTarget() {
        userClearedBrowserTarget = true
        selectedBrowserTabID = nil
        connectedBrowserCandidateID = nil
        connectedBrowserTargetURL = nil
        monitoredTabID = nil
        monitoredTabSummary = "未固定"
        updateIdleStatus()
    }

    func openBrowserControlPreferences() {
        SafariBridge.showPreferences(forIdentifier: Self.extensionBundleIdentifier) { error in
            if let error {
                // フォールバック: Safari を前面に出す
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Safari.app"))
                os_log("showPreferences failed: %{public}@", type: .error, error.localizedDescription)
            }
        }
        lastError = ""
        browserExtensionState = .checking
        updateIdleStatus()
    }

    func openScreenCapturePreferences() {
        guard let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            lastError = "システム設定の URL を生成できませんでした。"
            return
        }
        guard NSWorkspace.shared.open(settingsURL) else {
            lastError = "システム設定を開けませんでした。"
            return
        }
    }

    func openNotificationPreferences() {
        guard let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?com.decopin.s17o") else {
            lastError = "通知設定の URL を生成できませんでした。"
            return
        }
        guard NSWorkspace.shared.open(settingsURL) else {
            lastError = "通知設定を開けませんでした。"
            return
        }
    }

    func openSpeechRecognitionPreferences() {
        guard let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") else {
            lastError = "Speech 設定の URL を生成できませんでした。"
            return
        }
        guard NSWorkspace.shared.open(settingsURL) else {
            lastError = "Speech 設定を開けませんでした。"
            return
        }
    }

    func openSpeechPreferences() {
        guard let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else {
            lastError = "音声入力設定の URL を生成できませんでした。"
            return
        }
        guard NSWorkspace.shared.open(settingsURL) else {
            lastError = "音声入力設定を開けませんでした。"
            return
        }
    }

    func refreshBrowserControlState() {
        Task { @MainActor [weak self] in
            await self?.refreshBrowserControlStateAndWait()
        }
    }

    /// アプリがフォアグラウンドに戻ったとき（Safari 設定変更後など）に呼ぶ。
    /// 音声制御機能の失敗キャッシュをリセットして即時再試行する。
    func retryFailedAudioAutomationsIfNeeded() {
        guard isRunning else { return }
        // appliedSystemMutedState をリセットして次回 applySoundPolicy が必ず再実行されるようにする
        appliedSystemMutedState = nil
        try? applySoundPolicy()
    }

    func refreshBrowserControlStateAndWait() async {
        let state = await withCheckedContinuation { continuation in
            SafariBridge.getExtensionState(forIdentifier: Self.extensionBundleIdentifier) { isEnabled, error in
                continuation.resume(returning: (
                    isEnabled,
                    (error as NSError?)?.domain,
                    (error as NSError?)?.code,
                    error?.localizedDescription
                ))
            }
        }

        if state.1 == nil, state.0 {
            browserExtensionState = .enabled
            lastError = ""
        } else if await requestBrowserExtensionHandshakeAndWait() {
            browserExtensionState = .enabled
            lastError = ""
        } else if let errorDomain = state.1, let errorCode = state.2 {
            browserExtensionState = resolveBrowserExtensionState(errorDomain: errorDomain, errorCode: errorCode)
            if !isBrowserExtensionDiscoveryError(errorDomain: errorDomain, errorCode: errorCode),
               let description = state.3,
               !description.isEmpty {
                lastError = description
            }
        } else {
            browserExtensionState = state.0 ? .enabled : .disabled
        }

        refreshBrowserTabCandidates()
        updateIdleStatus()
    }

    private func refreshAutomationSchedule() {
        automationTimer?.invalidate()
        automationTimer = nil

        guard autoOpenTargetPage || autoStartMonitoringAtSchedule else {
            automationStatus = "自動化オフ"
            return
        }

        if autoOpenTargetPage, automationURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            automationStatus = "URL未設定"
            return
        }

        let scheduledDate = automationStartDate
        if let lastAutomationFireAt, lastAutomationFireAt >= scheduledDate {
            automationStatus = "実行済み: \(automationDateLabel(lastAutomationFireAt))"
            return
        }

        let interval = scheduledDate.timeIntervalSinceNow
        if interval <= 0 {
            automationStatus = "予定時刻到達"
            Task { @MainActor in
                await executeScheduledAutomation(trigger: "予定時刻到達")
            }
            return
        }

        automationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else {
                return
            }
            Task { @MainActor in
                await self.executeScheduledAutomation(trigger: "予定時刻到達")
            }
        }
        automationStatus = "待機中: \(automationDateLabel(scheduledDate))"
    }

    private func executeScheduledAutomation(trigger: String) async {
        guard !isScheduledAutomationRunning else {
            return
        }

        isScheduledAutomationRunning = true
        defer {
            isScheduledAutomationRunning = false
        }

        do {
            if autoOpenTargetPage {
                try await openResolvedAutomationTargetPage()
            }

            if autoStartMonitoringAtSchedule {
                if autoOpenTargetPage {
                    try? await Task.sleep(for: .seconds(1.5))
                }
                await startMonitoring()
                guard isRunning else {
                    automationStatus = "\(trigger): 開始失敗"
                    return
                }
            }

            let firedAt = Date()
            lastAutomationFireAt = firedAt
            defaults.set(firedAt, forKey: Self.lastAutomationFireAtKey)

            if autoOpenTargetPage && autoStartMonitoringAtSchedule {
                automationStatus = "\(trigger): \(Self.browserDisplayName) を開いて開始"
            } else if autoOpenTargetPage {
                automationStatus = "\(trigger): \(Self.browserDisplayName) を開きました"
            } else {
                automationStatus = "\(trigger): 開始"
            }
        } catch {
            lastError = error.localizedDescription
            automationStatus = "\(trigger): 失敗"
        }
    }

    private func observePageSnapshots() {
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.pageSnapshotNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else {
                return
            }
            guard let payload = notification.userInfo?["payload"] as? String else {
                return
            }
            MainActor.assumeIsolated {
                self.consumeSnapshotPayload(payload)
            }
        }
    }

    private func consumeSnapshotPayload(_ payload: String) {
        guard let data = payload.data(using: .utf8) else {
            return
        }

        do {
            let header = try JSONDecoder().decode(BrowserMessageTypeEnvelope.self, from: data)
            switch header.type {
            case "pageSnapshot":
                let snapshot = try JSONDecoder().decode(PageSnapshotEnvelope.self, from: data)
                handlePageSnapshot(snapshot)
            case "tabCatalog":
                let catalog = try JSONDecoder().decode(BrowserTabCatalogEnvelope.self, from: data)
                handleTabCatalog(catalog)
            case "extensionHandshake":
                let handshake = try JSONDecoder().decode(BrowserExtensionHandshakeEnvelope.self, from: data)
                handleBrowserExtensionHandshake(handshake)
            default:
                lastError = "未対応のブラウザ通知を受信しました。"
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handlePageSnapshot(_ snapshot: PageSnapshotEnvelope) {
        markBrowserExtensionReachable()
        recordBrowserTabCandidate(snapshot)

        if isRunning {
            guard acceptRunningSnapshot(snapshot) else {
                return
            }
        } else {
            guard acceptIdleSnapshot(snapshot) else {
                return
            }
        }

        lastAcceptedSnapshot = snapshot
        pageTitle = snapshot.page.title
        pageURL = snapshot.page.url
        pageHighlights = snapshot.page.highlights.joined(separator: "\n")

        let snapshotSignature = SnapshotDigest(snapshot: snapshot).signature
        guard snapshotSignature != latestSnapshotSignature else {
            return
        }
        latestSnapshotSignature = snapshotSignature

        let keywords = parsedKeywords(from: keywordsText)
        snapshotInterpretationTask?.cancel()
        snapshotInterpretationTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let interpreted = try await profileEngine.interpret(
                    snapshot: snapshot,
                    keywords: keywords,
                    referenceDate: snapshot.sentAt.map { Date(timeIntervalSince1970: $0 / 1000.0) } ?? Date()
                )
                await MainActor.run {
                    guard self.latestSnapshotSignature == snapshotSignature else {
                        return
                    }
                    self.apply(interpreted: interpreted, snapshot: snapshot, keywords: keywords)
                }
            } catch is CancellationError {
                return
            } catch let e as ProfileEngineError {
                // AI モデルエラーはモニタリングを止めずにステータス表示だけ更新する
                await MainActor.run {
                    self.lastError = e.localizedDescription
                    self.activeProfileLabel = "AI 解析待機中"
                }
            } catch {
                await self.surface(error: error)
            }
        }
    }

    private func acceptRunningSnapshot(_ snapshot: PageSnapshotEnvelope) -> Bool {
        guard let senderTabID = snapshot.sender?.tabId else {
            return false
        }

        if let monitoredTabID {
            guard senderTabID == monitoredTabID else {
                return false
            }

            monitoredTabSummary = monitoredTabLabel(for: snapshot)
            statusMessage = "動作中"
            return true
        }

        guard snapshotMatchesConnectedTarget(snapshot) else {
            return false
        }

        monitoredTabID = senderTabID
        monitoredTabSummary = monitoredTabLabel(for: snapshot)
        statusMessage = "動作中"
        return true
    }

    private func acceptIdleSnapshot(_ snapshot: PageSnapshotEnvelope) -> Bool {
        guard snapshot.page.visibilityState != "hidden" else {
            return false
        }

        guard let senderTabID = snapshot.sender?.tabId else {
            return false
        }

        if let monitoredTabID {
            return senderTabID == monitoredTabID
        }
        return false
    }

    private func recordBrowserTabCandidate(_ snapshot: PageSnapshotEnvelope) {
        if monitoredTabID == snapshot.sender?.tabId {
            monitoredTabSummary = monitoredTabLabel(for: snapshot)
        }
    }

    private func handleTabCatalog(_ catalog: BrowserTabCatalogEnvelope) {
        markBrowserExtensionReachable()
        let candidates = catalog.tabs
            .filter { tab in
                guard !tab.url.isEmpty else {
                    return false
                }
                if tab.url.hasPrefix("safari-web-extension://") || tab.url.hasPrefix("safari-extension://") {
                    return false
                }
                return true
            }
            .sorted { lhs, rhs in
                let lhsFocused = (lhs.isFocusedWindow == true && lhs.active == true) ? 0 : 1
                let rhsFocused = (rhs.isFocusedWindow == true && rhs.active == true) ? 0 : 1
                if lhsFocused != rhsFocused {
                    return lhsFocused < rhsFocused
                }
                let lhsWindow = (lhs.isFocusedWindow == true) ? 0 : 1
                let rhsWindow = (rhs.isFocusedWindow == true) ? 0 : 1
                if lhsWindow != rhsWindow {
                    return lhsWindow < rhsWindow
                }
                let lhsActive = (lhs.active == true) ? 0 : 1
                let rhsActive = (rhs.active == true) ? 0 : 1
                if lhsActive != rhsActive {
                    return lhsActive < rhsActive
                }
                let lhsTitle = lhs.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let rhsTitle = rhs.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return (lhsTitle.isEmpty ? lhs.url : lhsTitle) < (rhsTitle.isEmpty ? rhs.url : rhsTitle)
            }
            .enumerated()
            .map { offset, tab in
                BrowserTabCandidate(
                    id: tab.id,
                    windowIndex: 0,
                    tabIndex: offset + 1,
                    title: tab.title,
                    url: tab.url,
                    lastSeen: Date()
                )
            }

        extensionBrowserTabCandidates = candidates
        updateVisibleBrowserTabCandidates()
    }

    private func handleBrowserExtensionHandshake(_ handshake: BrowserExtensionHandshakeEnvelope) {
        _ = handshake
        markBrowserExtensionReachable()
    }

    private func markBrowserExtensionReachable() {
        lastBrowserExtensionHandshakeAt = Date()
        browserExtensionState = .enabled
        clearResolvedBrowserStateErrorIfNeeded()
        updateIdleStatus()
    }

    private func monitoredTabLabel(for snapshot: PageSnapshotEnvelope) -> String {
        let title = snapshot.page.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = title.isEmpty ? snapshot.page.url : title
        if let tabID = snapshot.sender?.tabId {
            return "#\(tabID) \(summary)"
        }
        return summary
    }

    private func handleAudioMatch(keyword: String, transcript: String) async {
        let normalizedKeyword = normalize(keyword)
        let now = Date()

        if let previous = lastNotificationAt["audio:\(normalizedKeyword)"],
           now.timeIntervalSince(previous) < cooldownSeconds {
            return
        }

        lastNotificationAt["audio:\(normalizedKeyword)"] = now
        lastMatchKeyword = keyword
        lastMatchTranscript = transcript
        let audioEvent = MatchEvent(timestamp: now, keyword: keyword, details: notificationDetails(for: transcript), source: .audio)
        recentMatches.insert(audioEvent, at: 0)
        latestDetection = audioEvent
        statusMessage = "音声一致を検出しました"

        // 音声でキーワードを検出 = 該当選手が今まさに注目されているシグナル。
        // 打席時ミュート解除が有効なら DOM 更新を待たずに即座にアンミュートする。
        // SoundPolicy.keywordAudioWindow 秒以内は有効。DOM 更新が来れば keywordPlayerActive が引き継ぐ。
        if autoSoundControlEnabled {
            soundPolicy.lastKeywordAudioAt = now
            do {
                try applySoundPolicy()
            } catch {
                lastError = error.localizedDescription
            }
        }

        let body = notificationDetails(for: transcript)
        do {
            try await notificationManager.post(title: Self.appDisplayName, body: body)
        } catch {
            await surface(error: error)
        }
    }

    private func notifyDOMMatchIfNeeded(_ domMatch: DOMMatch) async {
        guard isRunning else {
            return
        }
        guard domMatch.signature != lastDOMNotificationSignature else {
            return
        }

        let notificationKey = "dom:\(normalize(domMatch.keyword))"
        let now = Date()
        if let previous = lastNotificationAt[notificationKey],
           now.timeIntervalSince(previous) < cooldownSeconds {
            return
        }

        lastDOMNotificationSignature = domMatch.signature
        lastNotificationAt[notificationKey] = now
        lastMatchKeyword = domMatch.keyword
        lastMatchTranscript = domMatch.details
        let domEvent = MatchEvent(timestamp: now, keyword: domMatch.keyword, details: domMatch.details, source: .dom)
        recentMatches.insert(domEvent, at: 0)
        latestDetection = domEvent
        statusMessage = "DOM 一致を検出しました"

        do {
            try await notificationManager.post(title: Self.appDisplayName, body: domMatch.details)
        } catch {
            await surface(error: error)
        }
    }

    private func ensureScreenCaptureAuthorization() throws {
        if CGPreflightScreenCaptureAccess() {
            screenCapturePermission = .granted
            return
        }
        screenCapturePermission = .denied
        throw AppError.screenCaptureDenied
    }

    private func ensureSpeechAuthorization() throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            let availabilityState = speechAvailabilityPermission()
            speechPermission = availabilityState
            if availabilityState != .granted {
                if availabilityState == .unavailable {
                    throw AppError.speechServiceDisabled
                }
                if availabilityState == .unsupported {
                    throw AppError.onDeviceRecognitionUnavailable
                }
                throw AppError.speechRecognizerUnavailable
            }
        case .denied:
            speechPermission = .denied
            throw AppError.speechAuthorizationDenied("denied")
        case .restricted:
            speechPermission = .restricted
            throw AppError.speechAuthorizationDenied("restricted")
        case .notDetermined:
            speechPermission = .notRequested
            throw AppError.speechAuthorizationDenied("notDetermined")
        @unknown default:
            speechPermission = .unknown
            throw AppError.speechAuthorizationDenied("unknown")
        }
    }

    private func ensureNotificationAuthorization() async throws {
        let status = await notificationManager.authorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            notificationPermission = .granted
        case .denied:
            notificationPermission = .denied
            throw AppError.notificationAuthorizationDenied
        case .notDetermined:
            notificationPermission = .notRequested
            throw AppError.notificationAuthorizationDenied
        @unknown default:
            notificationPermission = .unknown
            throw AppError.notificationAuthorizationDenied
        }
    }

    private func currentSpeechPermission() -> SetupPermissionState {
        let authorizationStatus = SFSpeechRecognizer.authorizationStatus()
        let state = speechPermission(for: authorizationStatus)
        guard state == .granted else {
            return state
        }
        return speechAvailabilityPermission()
    }

    private func speechAvailabilityPermission() -> SetupPermissionState {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            return .unavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return .unsupported
        }
        guard recognizer.isAvailable else {
            return .unavailable
        }
        return .granted
    }

    private func speechPermission(for status: SFSpeechRecognizerAuthorizationStatus) -> SetupPermissionState {
        switch status {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notRequested
        @unknown default:
            return .unknown
        }
    }

    private func notificationPermission(for status: UNAuthorizationStatus) -> SetupPermissionState {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            return .notRequested
        @unknown default:
            return .unknown
        }
    }

    private func updateIdleStatus() {
        guard !isRunning else {
            return
        }

        statusMessage = monitoringReadiness.statusMessage
    }

    private func waitForBrowserTargetConnection(timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while monitoredTabID == nil {
            if clock.now >= deadline {
                throw AppError.pageOpenFailed("対象ページを開きましたが、\(Self.browserDisplayName) から対象タブを確認できませんでした。")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func updateSetupGuidance() {
        if screenCapturePermission == .restartRequired {
            setupGuidance = "画面収録を許可しました。このアプリを完全に終了して再起動してください。"
            updateIdleStatus()
            return
        }

        if screenCapturePermission != .granted {
            setupGuidance = "画面収録を許可してください。許可後はアプリを完全に終了して再起動してください。"
            updateIdleStatus()
            return
        }

        switch speechPermission {
        case .notRequested:
            setupGuidance = "Speech を許可してください。"
            updateIdleStatus()
            return
        case .denied, .restricted:
            setupGuidance = "Speech をシステム設定で許可してください。"
            updateIdleStatus()
            return
        case .unavailable, .disabled:
            setupGuidance = "音声認識を利用できません。Siri と音声入力を確認してください。"
            updateIdleStatus()
            return
        case .unsupported:
            setupGuidance = "この環境ではオンデバイス音声認識を利用できません。"
            updateIdleStatus()
            return
        default:
            break
        }

        if notificationPermission != .granted {
            setupGuidance = "通知を許可してください。"
            updateIdleStatus()
            return
        }

        setupGuidance = "初期設定は完了しています。"
        updateIdleStatus()
    }

    private func isSetupRelatedError(_ message: String) -> Bool {
        guard !message.isEmpty else {
            return false
        }

        if message == AppError.screenCaptureDenied.errorDescription {
            return true
        }
        if message == AppError.notificationAuthorizationDenied.errorDescription ||
            message.contains("Notifications are not allowed for this application") {
            return true
        }
        if message == AppError.speechServiceDisabled.errorDescription ||
            message.contains("Siri and Dictation are disabled") {
            return true
        }
        if message.hasPrefix("Speech 権限が拒否されています:") {
            return true
        }
        if message == AppError.speechRecognizerUnavailable.errorDescription ||
            message == AppError.onDeviceRecognitionUnavailable.errorDescription {
            return true
        }
        return false
    }

    private func parsedKeywords(from text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func notificationDetails(for transcript: String) -> String {
        let context = baseballContext?.summary
        if let context, !context.isEmpty {
            return "\(transcript) (\(context))"
        }
        return transcript
    }

    private func refreshBrowserTabCandidates() {
        guard isBrowserCurrentlyRunning() else {
            extensionBrowserTabCandidates = []
            appleScriptBrowserTabCandidates = []
            browserTabCandidates = []
            if !isRunning {
                disconnectBrowserTarget()
            } else {
                selectedBrowserTabID = nil
            }
            return
        }

        SafariBridge.getTabCatalog { [weak self] tabs, error in
            let tabCatalogData: Data?
            if let tabs,
               JSONSerialization.isValidJSONObject(tabs) {
                tabCatalogData = try? JSONSerialization.data(withJSONObject: tabs, options: [])
            } else {
                tabCatalogData = nil
            }
            let errorMessage = error?.localizedDescription

            MainActor.assumeIsolated {
                guard let self else {
                    return
                }

                if let errorMessage {
                    self.appleScriptBrowserTabCandidates = []
                    if self.extensionBrowserTabCandidates.isEmpty {
                        self.lastError = errorMessage
                    }
                    self.updateVisibleBrowserTabCandidates()
                    return
                }

                let resolvedTabs = (tabCatalogData.flatMap { data in
                    try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                }) ?? []
                self.appleScriptBrowserTabCandidates = self.browserTabCandidates(from: resolvedTabs)
                self.updateVisibleBrowserTabCandidates()
            }
        }
    }

    private func updateVisibleBrowserTabCandidates() {
        let visibleCandidates = appleScriptBrowserTabCandidates.isEmpty ? extensionBrowserTabCandidates : appleScriptBrowserTabCandidates
        browserTabCandidates = visibleCandidates
        clearResolvedBrowserStateErrorIfNeeded()

        if let connectedBrowserCandidateID,
           visibleCandidates.contains(where: { $0.id == connectedBrowserCandidateID }) {
            selectBrowserTab(connectedBrowserCandidateID)
            return
        }

        if let selectedBrowserTabID,
           visibleCandidates.contains(where: { $0.id == selectedBrowserTabID }) {
            selectBrowserTab(selectedBrowserTabID)
            return
        }

        if userClearedBrowserTarget {
            if visibleCandidates.isEmpty {
                userClearedBrowserTarget = false
            }
            return
        }

        if let firstTabID = visibleCandidates.first?.id {
            selectBrowserTab(firstTabID)
            return
        }

        if !isRunning {
            disconnectBrowserTarget()
        } else {
            selectedBrowserTabID = nil
        }
    }

    private func clearResolvedBrowserStateErrorIfNeeded() {
        guard !lastError.isEmpty else {
            return
        }

        let staleBrowserMessages = [
            "Safariでエラーが起きました: アプリケーションは実行されていません。",
            "\(Self.browserDisplayName) が起動していません。",
            "\(Self.browserDisplayName) のタブ一覧をまだ取得できていません。",
            "The operation couldn’t be completed. (SFErrorDomain error 1.)"
        ]

        if staleBrowserMessages.contains(where: { lastError.contains($0) }) {
            lastError = ""
        }
    }

    private func browserTabCandidates(from tabs: [[String: Any]]) -> [BrowserTabCandidate] {
        tabs.compactMap { tab in
            guard let id = tab["id"] as? Int,
                  let windowIndex = tab["windowIndex"] as? Int,
                  let tabIndex = tab["tabIndex"] as? Int,
                  let title = tab["title"] as? String,
                  let url = tab["url"] as? String,
                  !url.isEmpty else {
                return nil
            }

            return BrowserTabCandidate(
                id: id,
                windowIndex: windowIndex,
                tabIndex: tabIndex,
                title: title,
                url: url,
                lastSeen: Date()
            )
        }
        .sorted { lhs, rhs in
            if lhs.windowIndex != rhs.windowIndex {
                return lhs.windowIndex < rhs.windowIndex
            }
            return lhs.tabIndex < rhs.tabIndex
        }
    }

    private func requestBrowserExtensionHandshakeAndWait(timeout: Duration = .seconds(1)) async -> Bool {
        let baseline = lastBrowserExtensionHandshakeAt
        let dispatchResult = await withCheckedContinuation { continuation in
            SafariBridge.dispatchMessage(
                withName: "healthCheck",
                toExtensionWithIdentifier: Self.extensionBundleIdentifier,
                userInfo: ["sentAt": Date().timeIntervalSince1970]
            ) { error in
                continuation.resume(returning: (
                    (error as NSError?)?.domain,
                    (error as NSError?)?.code
                ))
            }
        }

        guard dispatchResult.0 == nil else {
            return false
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if didReceiveBrowserExtensionHandshake(since: baseline) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        return didReceiveBrowserExtensionHandshake(since: baseline)
    }

    private func didReceiveBrowserExtensionHandshake(since baseline: Date?) -> Bool {
        guard let lastBrowserExtensionHandshakeAt else {
            return false
        }
        guard let baseline else {
            return true
        }
        return lastBrowserExtensionHandshakeAt > baseline
    }

    private func resolveBrowserExtensionState(errorDomain: String, errorCode: Int) -> BrowserExtensionState {
        if isBrowserExtensionDiscoveryError(errorDomain: errorDomain, errorCode: errorCode) {
            return .notDetected
        }
        return .failed
    }

    private func isBrowserExtensionDiscoveryError(errorDomain: String, errorCode: Int) -> Bool {
        errorDomain == SFErrorDomain && errorCode == 1
    }

    private func fetchBrowserTabCandidates() throws -> [BrowserTabCandidate] {
        let itemSeparator = Character(UnicodeScalar(31))
        let rowSeparator = Character(UnicodeScalar(30))
        let source = """
        on run
            set itemSeparator to character id 31
            set rowSeparator to character id 30
            set rows to {}
            tell application "Safari"
                repeat with windowIndex from 1 to count of windows
                    set w to window windowIndex
                    set currentTabIndex to index of current tab of w
                    set orderedTabIndexes to {currentTabIndex}
                    repeat with tabIndex from 1 to count of tabs of w
                        if tabIndex is not currentTabIndex then
                            set end of orderedTabIndexes to tabIndex
                        end if
                    end repeat
                    repeat with orderedTabIndex in orderedTabIndexes
                        set tabIndex to orderedTabIndex as integer
                        set t to tab tabIndex of w
                        set tabTitle to name of t
                        set tabURL to URL of t
                        if tabURL is not missing value and tabURL is not "" then
                            set end of rows to ((windowIndex as text) & itemSeparator & (tabIndex as text) & itemSeparator & (tabTitle as text) & itemSeparator & (tabURL as text))
                        end if
                    end repeat
                end repeat
            end tell
            set AppleScript's text item delimiters to rowSeparator
            set outputText to rows as text
            set AppleScript's text item delimiters to ""
            return outputText
        end run
        """
        let output = try runAppleScript(source).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            return []
        }

        return output
            .split(separator: rowSeparator)
            .compactMap { row in
                let columns = row.split(separator: itemSeparator, omittingEmptySubsequences: false)
                guard columns.count == 4,
                      let windowIndex = Int(columns[0]),
                      let tabIndex = Int(columns[1]) else {
                    return nil
                }

                return BrowserTabCandidate(
                    id: browserTabCandidateID(windowIndex: windowIndex, tabIndex: tabIndex),
                    windowIndex: windowIndex,
                    tabIndex: tabIndex,
                    title: String(columns[2]),
                    url: String(columns[3]),
                    lastSeen: Date()
                )
            }
    }

    private func browserTabCandidateID(windowIndex: Int, tabIndex: Int) -> Int {
        (windowIndex << 16) | tabIndex
    }

    private func snapshotMatchesConnectedTarget(_ snapshot: PageSnapshotEnvelope) -> Bool {
        guard let connectedBrowserTargetURL else {
            return false
        }
        return normalizedTabMatchURL(snapshot.page.url) == connectedBrowserTargetURL
    }

    private func normalizedTabMatchURL(_ rawURL: String) -> String {
        guard var components = URLComponents(string: rawURL) else {
            return rawURL
        }
        components.fragment = nil
        return components.string ?? rawURL
    }

    private static func peakLevel(in buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else {
            return 0
        }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            return 0
        }

        var peak: Float = 0
        let channelCount = Int(buffer.format.channelCount)
        for channelIndex in 0..<channelCount {
            let samples = channelData[channelIndex]
            for frameIndex in 0..<frameCount {
                let amplitude = abs(samples[frameIndex])
                if amplitude > peak {
                    peak = amplitude
                }
            }
        }
        return peak
    }

    private func resetSessionState(preserveConnectedTarget: Bool = false) {
        lastError = ""
        transcript = ""
        lastMatchKeyword = ""
        lastMatchTranscript = ""
        recentMatches.removeAll()
        lastNotificationAt.removeAll()
        lastDOMNotificationSignature = ""
        snapshotInterpretationTask?.cancel()
        snapshotInterpretationTask = nil
        latestSnapshotSignature = ""
        if !preserveConnectedTarget {
            connectedBrowserCandidateID = nil
            connectedBrowserTargetURL = nil
            monitoredTabID = nil
            monitoredTabSummary = "未固定"
        }
        activeProfileLabel = "未選択"
        profileReason = "まだありません"
        audioPipelineStatus = "未初期化"
        audioInferenceStatus = "未初期化"
        audioSceneStatus = "未判定"
        audioSampleCaptureStatus = captureAudioSamplesEnabled ? "待機" : "オフ"
        pageSummary = "まだありません"
        baseballSummary = "未検出"
        genericProfileContext = nil
        baseballContext = nil
        soundAutomationStatus = autoSoundControlEnabled ? "待機" : "手動"
        foregroundAutomationStatus = autoBringToFrontEnabled ? "待機" : "手動"
        commercialAudioStatus = suppressCommercialAudioEnabled ? "待機" : "手動"
        commentaryTrackStatus = suppressEnglishCommentaryEnabled ? "待機" : "手動"
        lastForegroundSignature = ""
        adObservationSignature = ""
        adObservationStartedAt = nil
        adLoopNotificationSignature = ""
        lastBaseballProgressSignature = ""
        commentarySuppressionState = nil
        soundPolicy.reset()
        appliedSystemMutedState = nil
        audioCommercialObservationStartedAt = nil
        audioNonCommercialObservationStartedAt = nil
        audioSampleObservationScene = nil
        audioSampleObservationStartedAt = nil
        audioSampleLastExportAtByScene.removeAll()
        audioSampleExportInFlight = false
    }

    private func surface(error: Error) async {
        let surfacedError: Error
        if let appError = error as? AppError {
            switch appError {
            case .screenCaptureDenied:
                screenCapturePermission = .denied
                surfacedError = appError
            case .speechAuthorizationDenied(let status):
                switch status {
                case "denied":
                    speechPermission = .denied
                case "restricted":
                    speechPermission = .restricted
                case "notDetermined":
                    speechPermission = .notRequested
                default:
                    speechPermission = .unknown
                }
                surfacedError = appError
            case .speechRecognizerUnavailable:
                speechPermission = .unavailable
                surfacedError = appError
            case .onDeviceRecognitionUnavailable:
                speechPermission = .unsupported
                surfacedError = appError
            case .notificationAuthorizationDenied:
                notificationPermission = .denied
                surfacedError = appError
            case .speechServiceDisabled:
                speechPermission = .disabled
                surfacedError = appError
            default:
                surfacedError = appError
            }
        } else if error.localizedDescription.contains("Siri and Dictation are disabled") {
            speechPermission = .disabled
            surfacedError = AppError.speechServiceDisabled
        } else {
            surfacedError = error
        }

        if isSetupRelatedError(surfacedError.localizedDescription) {
            lastError = ""
            updateSetupGuidance()
            statusMessage = "初期設定待ち"
            await tearDownPipeline()
            return
        }

        lastError = surfacedError.localizedDescription
        statusMessage = "失敗"
        await tearDownPipeline()
    }

    private func tearDownPipeline() async {
        pipelineState = .stopping
        if let p = audioPipeline { await p.stop() }
        audioPipeline = nil
        restoreBrowserSoundIfNeeded()
        restoreEnglishCommentaryIfNeeded()
        pipelineState = .idle
    }

    private func handleAutoSoundToggleChange() {
        if autoSoundControlEnabled {
            if isRunning {
                applyAutomaticSoundState(using: baseballContext, keywords: parsedKeywords(from: keywordsText), force: true)
            } else {
                soundAutomationStatus = "待機"
            }
        } else {
            soundPolicy.keywordPlayerActive = false
            soundPolicy.lastKeywordAudioAt = nil
            do {
                try applySoundPolicy()
            } catch {
                lastError = error.localizedDescription
                soundAutomationStatus = "失敗"
            }
        }
    }

    private func handleAutoBringToFrontToggleChange() {
        if autoBringToFrontEnabled {
            if isRunning {
                applyAutomaticForegroundState(using: baseballContext, keywords: parsedKeywords(from: keywordsText))
            } else {
                foregroundAutomationStatus = "待機"
            }
        } else {
            lastForegroundSignature = ""
            foregroundAutomationStatus = "手動"
        }
    }

    private func handleCommercialAudioToggleChange() {
        if suppressCommercialAudioEnabled {
            commercialAudioStatus = "待機"
        } else {
            audioCommercialObservationStartedAt = nil
            audioNonCommercialObservationStartedAt = nil
            soundPolicy.isCommercialConfirmed = false
            do {
                try applySoundPolicy()
                commercialAudioStatus = "手動"
            } catch {
                let msg = safariJavaScriptPermissionMessage(from: error.localizedDescription)
                lastError = msg
                commercialAudioStatus = "失敗: \(msg)"
            }
        }
    }

    private func handleEnglishCommentaryToggleChange() {
        if suppressEnglishCommentaryEnabled {
            commentaryTrackStatus = "待機"
        } else {
            soundPolicy.isEnglishCommentaryActive = false
            do {
                try applySoundPolicy()
            } catch {
                lastError = error.localizedDescription
            }
            commentaryTrackStatus = "手動"
        }
    }

    private func handleAudioSampleCaptureToggleChange() {
        if captureAudioSamplesEnabled {
            audioSampleCaptureStatus = isRunning ? "待機" : "待機"
        } else {
            audioSampleObservationScene = nil
            audioSampleObservationStartedAt = nil
            audioSampleLastExportAtByScene.removeAll()
            audioSampleExportInFlight = false
            audioSampleCaptureStatus = "オフ"
        }
    }

    private func handleAudioInferenceSnapshot(_ snapshot: AudioInferenceSnapshot) {
        audioSceneStatus = snapshot.sceneStatusLine
        audioInferenceStatus = snapshot.detailsStatusLine
        updateCommentaryTrackObservation(using: snapshot)
        updateCommercialAudioObservation(using: snapshot)
        updateAudioSampleCapture(using: snapshot)
    }

    private func updateCommentaryTrackObservation(using snapshot: AudioInferenceSnapshot) {
        guard suppressEnglishCommentaryEnabled, isRunning else {
            if soundPolicy.isEnglishCommentaryActive {
                soundPolicy.isEnglishCommentaryActive = false
                try? applySoundPolicy()
            }
            commentaryTrackStatus = suppressEnglishCommentaryEnabled ? "待機" : "手動"
            return
        }

        switch snapshot.scene {
        case .commentary, .mixed:
            soundPolicy.isEnglishCommentaryActive = true
        case .ballpark, .quiet, .commercial:
            soundPolicy.isEnglishCommentaryActive = false
        }

        do {
            try applySoundPolicy()
            switch snapshot.scene {
            case .commentary, .mixed: commentaryTrackStatus = "英語実況オフ"
            case .ballpark, .quiet:   commentaryTrackStatus = "球場音"
            case .commercial:         commentaryTrackStatus = "CM中"
            }
        } catch {
            let msg = safariJavaScriptPermissionMessage(from: error.localizedDescription)
            lastError = msg
            commentaryTrackStatus = "失敗: \(msg)"
        }
    }

    private func updateCommercialAudioObservation(using snapshot: AudioInferenceSnapshot) {
        guard suppressCommercialAudioEnabled else {
            commercialAudioStatus = "手動"
            return
        }
        guard isRunning else {
            commercialAudioStatus = "待機"
            return
        }

        let now = Date()
        switch snapshot.scene {
        case .commercial:
            audioNonCommercialObservationStartedAt = nil
            if audioCommercialObservationStartedAt == nil {
                audioCommercialObservationStartedAt = now
            }
            let elapsed = now.timeIntervalSince(audioCommercialObservationStartedAt ?? now)
            guard elapsed >= 2 else {
                commercialAudioStatus = "CM判定中"
                return
            }
            do {
                let wasConfirmed = soundPolicy.isCommercialConfirmed
                soundPolicy.isCommercialConfirmed = true
                try applySoundPolicy()
                commercialAudioStatus = "CMミュート"
                if !wasConfirmed {
                    recordAudioPolicyEvent(keyword: "CMミュート", details: snapshot.detailsStatusLine)
                    statusMessage = "CM 音をミュートしました"
                }
            } catch {
                let msg = safariJavaScriptPermissionMessage(from: error.localizedDescription)
                lastError = msg
                commercialAudioStatus = "失敗: \(msg)"
            }

        case .ballpark, .commentary, .mixed:
            audioCommercialObservationStartedAt = nil
            if audioNonCommercialObservationStartedAt == nil {
                audioNonCommercialObservationStartedAt = now
            }
            let elapsed = now.timeIntervalSince(audioNonCommercialObservationStartedAt ?? now)
            guard elapsed >= 1 else {
                commercialAudioStatus = soundPolicy.isCommercialConfirmed ? "CM解除判定中" : "待機"
                return
            }
            do {
                let wasConfirmed = soundPolicy.isCommercialConfirmed
                soundPolicy.isCommercialConfirmed = false
                try applySoundPolicy()
                commercialAudioStatus = "待機"
                if wasConfirmed {
                    recordAudioPolicyEvent(keyword: "CM解除", details: snapshot.detailsStatusLine)
                    statusMessage = "CM 音を解除しました"
                }
            } catch {
                let msg = safariJavaScriptPermissionMessage(from: error.localizedDescription)
                lastError = msg
                commercialAudioStatus = "失敗: \(msg)"
            }

        case .quiet:
            commercialAudioStatus = soundPolicy.isCommercialConfirmed ? "CMミュート維持" : "待機"
        }
    }

    private func updateAudioSampleCapture(using snapshot: AudioInferenceSnapshot) {
        guard captureAudioSamplesEnabled else {
            audioSampleCaptureStatus = "オフ"
            return
        }
        guard isRunning else {
            audioSampleCaptureStatus = "待機"
            return
        }
        guard let audioSampleStore = audioPipeline?.audioSampleStore else {
            audioSampleCaptureStatus = "未初期化"
            return
        }

        switch snapshot.scene {
        case .commentary, .ballpark, .commercial:
            break
        case .quiet, .mixed:
            audioSampleObservationScene = nil
            audioSampleObservationStartedAt = nil
            audioSampleCaptureStatus = "待機"
            return
        }

        let now = Date()
        if audioSampleObservationScene != snapshot.scene {
            audioSampleObservationScene = snapshot.scene
            audioSampleObservationStartedAt = now
            audioSampleCaptureStatus = "\(snapshot.scene.rawValue) 蓄積中"
            return
        }

        let observedAt = audioSampleObservationStartedAt ?? now
        let elapsed = now.timeIntervalSince(observedAt)
        guard elapsed >= 3 else {
            audioSampleCaptureStatus = "\(snapshot.scene.rawValue) 蓄積中"
            return
        }

        if let previous = audioSampleLastExportAtByScene[snapshot.scene],
           now.timeIntervalSince(previous) < 45 {
            audioSampleCaptureStatus = "\(snapshot.scene.rawValue) 保存済み"
            return
        }

        guard !audioSampleExportInFlight else {
            audioSampleCaptureStatus = "保存中"
            return
        }

        audioSampleExportInFlight = true
        audioSampleCaptureStatus = "保存中"

        let metadata = AudioSampleMetadata(
            capturedAt: now,
            scene: snapshot.scene.rawValue,
            sceneConfidence: snapshot.sceneConfidence,
            primaryLabel: snapshot.primaryLabel,
            primaryConfidence: snapshot.primaryConfidence,
            speechConfidence: snapshot.speechConfidence,
            crowdConfidence: snapshot.crowdConfidence,
            musicConfidence: snapshot.musicConfidence,
            silenceConfidence: snapshot.silenceConfidence,
            pageURL: pageURL,
            pageTitle: pageTitle,
            activeProfile: activeProfileLabel,
            baseballSummary: baseballSummary,
            monitoredTab: monitoredTabSummary,
            transcript: transcript
        )

        let scene = snapshot.scene
        DispatchQueue.global(qos: .utility).async { [weak self, audioSampleStore = audioPipeline?.audioSampleStore] in
            guard let audioSampleStore else { return }
            guard let self else {
                return
            }

            do {
                let wavURL = try audioSampleStore.exportRecentWindow(scene: scene, metadata: metadata)
                Task { @MainActor in
                    self.audioSampleExportInFlight = false
                    if let wavURL {
                        self.audioSampleLastExportAtByScene[scene] = now
                        self.audioSampleCaptureStatus = "保存: \(wavURL.lastPathComponent)"
                    } else {
                        self.audioSampleCaptureStatus = "\(scene.rawValue) 蓄積中"
                    }
                }
            } catch {
                Task { @MainActor in
                    self.audioSampleExportInFlight = false
                    self.lastError = error.localizedDescription
                    self.audioSampleCaptureStatus = "失敗"
                }
            }
        }
    }

    private func recordAudioPolicyEvent(keyword: String, details: String) {
        let now = Date()
        lastMatchKeyword = keyword
        lastMatchTranscript = details
        recentMatches.insert(
            MatchEvent(timestamp: now, keyword: keyword, details: details, source: .audio),
            at: 0
        )
    }

    private func applyAutomaticSoundState(using baseballContext: BaseballContext?, keywords: [String], force: Bool = false) {
        guard autoSoundControlEnabled, isRunning else {
            soundAutomationStatus = autoSoundControlEnabled ? "待機" : "手動"
            return
        }

        let shouldUnmute = shouldEnableSound(for: baseballContext, keywords: keywords)

        // DOM チャンネルのシグナルをポリシーに反映
        if !force, soundPolicy.keywordPlayerActive == shouldUnmute { return }
        soundPolicy.keywordPlayerActive = shouldUnmute
        // DOM でキーワードを確認できたので音声検出の時限フラグは不要
        if shouldUnmute { soundPolicy.lastKeywordAudioAt = nil }

        do {
            try applySoundPolicy()
        } catch {
            lastError = error.localizedDescription
            soundAutomationStatus = "失敗"
        }
    }

    private func shouldEnableSound(for baseballContext: BaseballContext?, keywords: [String]) -> Bool {
        guard let baseballContext else {
            return false
        }

        let normalizedKeywords = keywords.map(normalize)
        let activeFields = [
            baseballContext.currentBatter,
            baseballContext.onDeck,
            baseballContext.inTheHole,
            baseballContext.pitcher,
        ]
        .compactMap { $0 } + baseballContext.baseRunners

        for field in activeFields {
            let normalizedField = normalize(field)
            if normalizedKeywords.contains(where: { normalizedField.contains($0) }) {
                return true
            }
        }

        return false
    }

    private func applyAutomaticForegroundState(using baseballContext: BaseballContext?, keywords: [String]) {
        guard autoBringToFrontEnabled else {
            return
        }
        guard isRunning else {
            foregroundAutomationStatus = "待機"
            return
        }

        guard shouldEnableSound(for: baseballContext, keywords: keywords) else {
            lastForegroundSignature = ""
            foregroundAutomationStatus = "待機"
            return
        }

        let signature = [
            pageURL,
            baseballContext?.inningHalf ?? "",
            baseballContext?.currentBatter ?? "",
            baseballContext?.onDeck ?? "",
            baseballContext?.pitcher ?? "",
        ].joined(separator: "\n")

        if signature == lastForegroundSignature {
            foregroundAutomationStatus = "前面表示済み"
            return
        }

        do {
            try activateBrowser()
            lastForegroundSignature = signature
            foregroundAutomationStatus = "前面表示"
        } catch {
            lastError = error.localizedDescription
            foregroundAutomationStatus = "失敗"
        }
    }

    private func applyEnglishCommentarySuppressionIfNeeded(using baseballContext: BaseballContext? = nil, force: Bool = false) {
        guard suppressEnglishCommentaryEnabled else {
            return
        }
        guard isRunning else {
            commentaryTrackStatus = "待機"
            return
        }
        // baseballContext があれば pageKind をチェックするが、nil でも試みる
        // (selectBrowserAudioTrack は対象タブの URL で絞り込む)
        if let baseballContext, !shouldControlCommentaryTrack(for: baseballContext) {
            commentaryTrackStatus = "待機"
            return
        }
        if !force {
            switch commentarySuppressionState {
            case true?:
                commentaryTrackStatus = "英語実況オフ"
                return
            case false?:
                // 一度失敗していても force=false なら再試行しない
                commentaryTrackStatus = "失敗"
                return
            case nil:
                break
            }
        }

        do {
            let selectedTrack = try selectBrowserAudioTrack(preferEnglish: false)
            commentarySuppressionState = true
            commentaryTrackStatus = "英語実況オフ: \(selectedTrack)"
        } catch {
            let msg = safariJavaScriptPermissionMessage(from: error.localizedDescription)
            lastError = msg
            commentarySuppressionState = false
            commentaryTrackStatus = "失敗: \(msg)"
        }
    }

    private func restoreEnglishCommentaryIfNeeded() {
        guard let commentarySuppressionState else {
            return
        }
        guard commentarySuppressionState else {
            self.commentarySuppressionState = nil
            return
        }

        do {
            _ = try selectBrowserAudioTrack(preferEnglish: true)
        } catch {
            if lastError.isEmpty {
                lastError = error.localizedDescription
            }
        }
        self.commentarySuppressionState = nil
    }

    private func shouldControlCommentaryTrack(for baseballContext: BaseballContext) -> Bool {
        switch baseballContext.pageKind {
        case "watch_stream", "live_game", "ad_break":
            return true
        default:
            return false
        }
    }

    private func activateBrowser() throws {
        let targetPrefix = try browserControlTargetURLPrefix()
        let source = """
        on run argv
            set targetPrefix to item 1 of argv
            tell application "Safari"
                repeat with w in every window
                    repeat with tabIndex from 1 to (count of tabs of w)
                        set t to tab tabIndex of w
                        set tabURL to URL of t
                        if tabURL is not missing value and tabURL starts with targetPrefix then
                            set current tab of w to t
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            error "対象タブが見つかりませんでした。"
        end run
        """
        _ = try runAppleScript(source, arguments: [targetPrefix])
    }

    private func restoreBrowserSoundIfNeeded() {
        soundPolicy.reset()
        audioCommercialObservationStartedAt = nil
        audioNonCommercialObservationStartedAt = nil
        guard appliedSystemMutedState != nil else { return }
        do {
            try applySoundPolicy()
        } catch {
            if lastError.isEmpty { lastError = error.localizedDescription }
        }
    }

    /// SoundPolicy を評価してシステムボリュームへ反映する単一エントリポイント。
    /// 全ての音声制御パスはこの関数を呼ぶ。
    private func applySoundPolicy() throws {
        let config = SoundPolicy.Config(
            autoSoundControlEnabled: autoSoundControlEnabled,
            suppressCommercialAudioEnabled: suppressCommercialAudioEnabled,
            suppressEnglishCommentaryEnabled: suppressEnglishCommentaryEnabled
        )
        let decision = soundPolicy.evaluate(config: config)
        soundAutomationStatus = decision.soundAutomationStatusLabel
        guard appliedSystemMutedState != decision.muted else { return }
        try setSystemAudioMuted(decision.muted)
        appliedSystemMutedState = decision.muted
    }

    /// システムボリュームでミュート制御する。
    /// el.muted と異なり、ScreenCaptureKit はボリューム変更前の音声をキャプチャするため
    /// 音声認識・シーン分析は引き続き動作する。
    private func setSystemAudioMuted(_ muted: Bool) throws {
        if muted {
            // 現在のボリュームを保存してから 0 にする
            if savedSystemVolume == nil {
                guard let getScript = NSAppleScript(source: "output volume of (get volume settings)") else {
                    throw AppError.audioControlFailed("AppleScript を作成できませんでした。")
                }
                var getError: NSDictionary?
                let result = getScript.executeAndReturnError(&getError)
                savedSystemVolume = Int(result.stringValue ?? "50") ?? 50
            }
            guard let muteScript = NSAppleScript(source: "set volume output volume 0") else {
                throw AppError.audioControlFailed("AppleScript を作成できませんでした。")
            }
            var muteError: NSDictionary?
            muteScript.executeAndReturnError(&muteError)
            if let muteError {
                let msg = (muteError[NSAppleScript.errorMessage] as? String) ?? "ボリューム設定に失敗しました。"
                throw AppError.audioControlFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } else {
            guard let vol = savedSystemVolume else { return }
            savedSystemVolume = nil
            guard let restoreScript = NSAppleScript(source: "set volume output volume \(vol)") else { return }
            var restoreError: NSDictionary?
            restoreScript.executeAndReturnError(&restoreError)
        }
    }

    private func apply(interpreted: InterpretedPage, snapshot: PageSnapshotEnvelope, keywords: [String]) {
        if monitoredTabID == snapshot.sender?.tabId {
            monitoredTabSummary = monitoredTabLabel(for: snapshot)
        }

        activeProfileLabel = interpreted.selection.profile.displayName
        profileReason = interpreted.selection.reason
        pageSummary = interpreted.summary
        lastDOMUpdate = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)

        switch interpreted.payload {
        case .baseball(let context):
            genericProfileContext = nil
            baseballContext = context
            baseballSummary = context.summary
            applyCalendarStateIfNeeded(using: context, sourceURLString: snapshot.page.url)
            if autoSoundControlEnabled {
                applyAutomaticSoundState(using: context, keywords: keywords)
            }
            if autoBringToFrontEnabled {
                applyAutomaticForegroundState(using: context, keywords: keywords)
            }
            updateAdLoopObservation(using: context)
        case .generic(let context):
            genericProfileContext = context
            baseballContext = nil
            baseballSummary = "未検出"
            calendarResolution = nil
            if CalendarResolver.isCalendarURL(URL(string: automationURLText) ?? URL(fileURLWithPath: "/")) {
                calendarStatus = "未解決"
            }
            soundAutomationStatus = autoSoundControlEnabled ? "待機" : "手動"
            foregroundAutomationStatus = autoBringToFrontEnabled ? "待機" : "手動"
            commentaryTrackStatus = suppressEnglishCommentaryEnabled ? "待機" : "手動"
            adObservationSignature = ""
            adObservationStartedAt = nil
            adLoopNotificationSignature = ""
            lastBaseballProgressSignature = ""
            commentarySuppressionState = nil
        }

        if let domMatch = interpreted.domMatch {
            Task { @MainActor in
                await notifyDOMMatchIfNeeded(domMatch)
            }
        }
    }

    private func applyCalendarStateIfNeeded(using context: BaseballContext, sourceURLString: String) {
        guard let sourceURL = URL(string: sourceURLString), CalendarResolver.isCalendarURL(sourceURL) else {
            return
        }

        guard let targetURL = context.watchURL else {
            calendarResolution = nil
            calendarStatus = "AI が watch URL を特定できませんでした"
            lastError = "AI が MLB カレンダーから対象 watch URL を特定できませんでした。"
            return
        }

        let resolution = CalendarResolution(
            sourceURL: sourceURL,
            targetURL: targetURL,
            startDate: context.scheduledStartDate,
            targetLabel: context.summary.isEmpty ? targetURL.absoluteString : context.summary,
            timeLabel: context.scheduledTimeText
        )
        calendarResolution = resolution
        calendarStatus = resolution.summary
        if let startDate = context.scheduledStartDate {
            automationStartDate = startDate
        }
    }

    private func updateAdLoopObservation(using baseballContext: BaseballContext?) {
        guard isRunning else {
            return
        }
        guard let baseballContext else {
            adObservationSignature = ""
            adObservationStartedAt = nil
            adLoopNotificationSignature = ""
            lastBaseballProgressSignature = ""
            return
        }
        let adState = baseballContext.adState
        let progressSignature = [
            baseballContext.pageKind,
            baseballContext.gameState,
            baseballContext.inningHalf ?? "",
            baseballContext.currentBatter ?? "",
            baseballContext.previousBatter ?? "",
            baseballContext.onDeck ?? "",
            baseballContext.pitcher ?? "",
            baseballContext.outs ?? "",
        ].joined(separator: "\n")

        defer {
            lastBaseballProgressSignature = progressSignature
        }

        guard adState == "ad" || adState == "stuck" else {
            adObservationSignature = ""
            adObservationStartedAt = nil
            adLoopNotificationSignature = ""
            return
        }

        if lastBaseballProgressSignature.isEmpty == false,
           lastBaseballProgressSignature != progressSignature {
            Task { @MainActor in
                await notifyAdProgressMismatchIfNeeded(adState: adState, progressSummary: baseballContext.summary)
            }
        }

        let signature = [pageURL, adState].joined(separator: "\n")
        let now = Date()
        if adObservationSignature != signature {
            adObservationSignature = signature
            adObservationStartedAt = now
            adLoopNotificationSignature = ""
            return
        }

        guard let adObservationStartedAt else {
            self.adObservationStartedAt = now
            return
        }

        let elapsed = now.timeIntervalSince(adObservationStartedAt)
        guard elapsed >= adLoopThresholdSeconds else {
            return
        }
        guard adLoopNotificationSignature != signature else {
            return
        }

        adLoopNotificationSignature = signature
        Task { @MainActor in
            await notifyAdLoopIfNeeded(adState: adState, elapsed: elapsed)
        }
    }

    private func notifyAdProgressMismatchIfNeeded(adState: String, progressSummary: String) async {
        let notificationKey = "dom:ad-progress-mismatch"
        let now = Date()
        if let previous = lastNotificationAt[notificationKey],
           now.timeIntervalSince(previous) < cooldownSeconds {
            return
        }

        let details = "試合進行 DOM は更新されていますが、配信状態は \(adState) のままです。\(progressSummary)"
        lastNotificationAt[notificationKey] = now
        lastMatchKeyword = "広告異常"
        lastMatchTranscript = details
        recentMatches.insert(
            MatchEvent(timestamp: now, keyword: "広告異常", details: details, source: .dom),
            at: 0
        )
        statusMessage = "広告異常を検出しました"

        do {
            try await notificationManager.post(title: Self.appDisplayName, body: details)
        } catch {
            await surface(error: error)
        }
    }

    private func notifyAdLoopIfNeeded(adState: String, elapsed: TimeInterval) async {
        let notificationKey = "dom:ad-loop"
        let now = Date()
        if let previous = lastNotificationAt[notificationKey],
           now.timeIntervalSince(previous) < cooldownSeconds {
            return
        }

        let details = "MLB.TV が \(adState) のまま \(Int(elapsed)) 秒継続しています。"
        lastNotificationAt[notificationKey] = now
        lastMatchKeyword = "広告ループ"
        lastMatchTranscript = details
        recentMatches.insert(
            MatchEvent(timestamp: now, keyword: "広告ループ", details: details, source: .dom),
            at: 0
        )
        statusMessage = "広告ループを検出しました"

        do {
            try await notificationManager.post(title: Self.appDisplayName, body: details)
        } catch {
            await surface(error: error)
        }
    }

    private func validatedAutomationSourceURL() throws -> URL {
        let trimmed = automationURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw AppError.invalidAutomationURL
        }
        return url
    }

    private func refreshConfiguredCalendarState() {
        let trimmed = automationURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            calendarResolution = nil
            calendarStatus = "未使用"
            return
        }
        guard let sourceURL = try? validatedAutomationSourceURL() else {
            calendarResolution = nil
            calendarStatus = "URL不正"
            return
        }
        guard CalendarResolver.isCalendarURL(sourceURL) else {
            calendarResolution = nil
            calendarStatus = "通常URL"
            return
        }
        if let calendarResolution, CalendarResolver.urlsMatch(calendarResolution.sourceURL, sourceURL) {
            calendarStatus = calendarResolution.summary
            return
        }
        calendarResolution = nil
        calendarStatus = "読取待ち"
    }

    private func resolvedAutomationTargetURL() throws -> URL {
        let sourceURL = try validatedAutomationSourceURL()
        guard CalendarResolver.isCalendarURL(sourceURL) else {
            return sourceURL
        }
        guard let calendarResolution, CalendarResolver.urlsMatch(calendarResolution.sourceURL, sourceURL) else {
            throw AppError.calendarReadFailed("\(Self.browserDisplayName) で対象の MLB カレンダーページを開き、対象試合だけが見える状態にしてください。")
        }
        return calendarResolution.targetURL
    }

    private func openConfiguredTargetPage() async throws {
        let targetURL = try validatedAutomationSourceURL()
        try await openPageInBrowser(targetURL)
    }

    private func openResolvedAutomationTargetPage() async throws {
        let targetURL = try resolvedAutomationTargetURL()
        try await openPageInBrowser(targetURL)
    }

    private func openPageInBrowser(_ targetURL: URL) async throws {
        guard let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            throw AppError.browserUnavailable
        }
        let browserDisplayName = Self.browserDisplayName

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([targetURL], withApplicationAt: safariURL, configuration: configuration) { application, error in
                if let error {
                    continuation.resume(throwing: AppError.pageOpenFailed(error.localizedDescription))
                    return
                }
                guard application != nil else {
                    continuation.resume(throwing: AppError.pageOpenFailed("\(browserDisplayName) が URL を開けませんでした。"))
                    return
                }
                continuation.resume()
            }
        }
    }

    private func automationDateLabel(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }

    private func browserControlTargetURL() throws -> URL {
        if let currentURL = URL(string: pageURL),
           let scheme = currentURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return currentURL
        }
        return try resolvedAutomationTargetURL()
    }

    private func browserControlTargetURLPrefix() throws -> String {
        let targetURL = try browserControlTargetURL()
        return try normalizedURLPrefix(for: targetURL)
    }

    private func configuredWatchTargetURLPrefix() -> String? {
        let targetURL: URL
        if let resolvedURL = try? resolvedAutomationTargetURL() {
            targetURL = resolvedURL
        } else if let configuredURL = try? validatedAutomationSourceURL(),
                  CalendarResolver.isCalendarURL(configuredURL) == false {
            targetURL = configuredURL
        } else {
            return nil
        }

        return try? normalizedURLPrefix(for: targetURL)
    }

    private func normalizedURLPrefix(for targetURL: URL) throws -> String {
        guard var components = URLComponents(url: targetURL, resolvingAgainstBaseURL: false) else {
            throw AppError.pageOpenFailed("対象 URL を解釈できませんでした。")
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? targetURL.absoluteString
    }

    private func selectBrowserAudioTrack(preferEnglish: Bool) throws -> String {
        let targetPrefix = try browserControlTargetURLPrefix()
        // MLB.TV は Video.js + videojs-http-streaming (VHS) を使用しており、
        // Safari の HLS ネイティブ再生ではなく VHS が HLS を処理するため
        // video.audioTracks (HTML5 native) には何も入らない。
        // Video.js の player.audioTracks() API を最初に試み、次に native を試みる。
        let preferEnglishJS = preferEnglish ? "true" : "false"
        let scriptSource = """
        (() => {
          const preferEnglish = \(preferEnglishJS);
          const describeTrack = (t) => {
            const parts = [t.label, t.language, t.kind, t.id]
              .filter(Boolean).map(v => String(v).trim()).filter(Boolean);
            return parts.join(" / ") || "unnamed";
          };
          const normalizeText = (t) => [t.label, t.language, t.kind, t.id]
            .filter(Boolean).map(v => String(v).toLowerCase()).join(" ");
          const isEnglish = (t) => {
            const text = normalizeText(t);
            return /(^|\\b)(en|eng|english)(\\b|$)/.test(text) ||
                   text.includes("commentary") || text.includes("home audio") ||
                   text.includes("english");
          };
          const rank = (t) => {
            const text = normalizeText(t);
            if (text.includes("ballpark")) return 0;
            if (/(^|\\b)(ja|jpn|japanese)(\\b|$)/.test(text)) return 1;
            if (/(^|\\b)(es|spa|spanish)(\\b|$)/.test(text)) return 2;
            if (text.includes("away audio")) return 3;
            return 10;
          };
          const trySelect = (trackList) => {
            const available = [];
            for (let i = 0; i < trackList.length; i++) {
              const t = trackList[i];
              if (t) available.push(t);
            }
            if (available.length === 0) return null;
            const candidates = available.filter(t => preferEnglish ? isEnglish(t) : !isEnglish(t));
            if (candidates.length === 0) {
              const labels = available.map(t => describeTrack(t)).join(", ");
              throw new Error(preferEnglish
                ? "英語実況 track が見つかりません。利用可能: " + labels
                : "英語実況以外の track が見つかりません。利用可能: " + labels);
            }
            candidates.sort((a, b) => rank(a) - rank(b));
            const selected = candidates[0];
            for (const t of available) {
              if (typeof t.enabled !== "undefined") t.enabled = false;
            }
            selected.enabled = true;
            return describeTrack(selected);
          };

          // --- Approach 1: Video.js player.audioTracks() ---
          const vjs = window.videojs;
          const vjsPlayers = vjs && vjs.players
            ? Object.values(vjs.players).filter(Boolean)
            : [];
          for (const player of vjsPlayers) {
            try {
              const tracks = player.audioTracks ? player.audioTracks() : null;
              if (tracks && tracks.length > 0) {
                const result = trySelect(tracks);
                if (result !== null) return "vjs: " + result;
              }
            } catch (e) {
              throw e;
            }
          }

          // --- Approach 2: HTML5 native audioTracks ---
          for (const video of Array.from(document.querySelectorAll("video"))) {
            const tracks = video.audioTracks;
            if (tracks && tracks.length > 0) {
              const result = trySelect(tracks);
              if (result !== null) return "native: " + result;
            }
          }

          // --- 診断情報を含めたエラー ---
          const diag = [];
          diag.push("Video.js players: " + vjsPlayers.length);
          if (vjsPlayers.length > 0) {
            for (const p of vjsPlayers) {
              const tl = p.audioTracks ? p.audioTracks() : null;
              diag.push("  vjs tracks: " + (tl ? tl.length : "n/a"));
            }
          }
          const videos = Array.from(document.querySelectorAll("video"));
          diag.push("video elements: " + videos.length);
          for (const v of videos) {
            diag.push("  native tracks: " + (v.audioTracks ? v.audioTracks.length : "n/a"));
          }
          throw new Error("audio track を切り替えられませんでした。" + diag.join(", "));
        })();
        """
        let source = """
        on run argv
            set targetPrefix to item 1 of argv
            set scriptSource to item 2 of argv
            tell application "Safari"
                repeat with w in every window
                    repeat with t in tabs of w
                        set tabURL to URL of t
                        if tabURL is not missing value and tabURL starts with targetPrefix then
                            return do JavaScript scriptSource in t
                        end if
                    end repeat
                end repeat
            end tell
            error "対象タブが見つかりませんでした。"
        end run
        """
        return try runAppleScript(source, arguments: [targetPrefix, scriptSource]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// AppleScript を s17o プロセス自身のコンテキストで実行する。
    /// Process() + osascript を使うと別プロセス扱いになり
    /// temporary-exception.apple-events エンタイトルメントが効かないため
    /// NSAppleScript を使って同一プロセス内で Apple Event を送信する。
    @discardableResult
    private func runAppleScript(_ source: String, arguments: [String] = [], requiresBrowserRunning: Bool = true) throws -> String {
        if requiresBrowserRunning {
            try ensureBrowserRunningForControl()
        }

        guard let script = NSAppleScript(source: source) else {
            throw AppError.audioControlFailed("AppleScript を作成できませんでした。")
        }

        var errorDict: NSDictionary?
        let result: NSAppleEventDescriptor?

        if arguments.isEmpty {
            result = script.executeAndReturnError(&errorDict)
        } else {
            // on run argv 形式: 'aevt'/'oapp' イベントに引数リストを添付して実行
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(0x61657674), // 'aevt' kCoreEventClass
                eventID: AEEventID(0x6F617070),       // 'oapp' kAEOpenApplication
                targetDescriptor: nil,
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            let argList = NSAppleEventDescriptor.list()
            for (i, arg) in arguments.enumerated() {
                argList.insert(NSAppleEventDescriptor(string: arg), at: i + 1)
            }
            event.setDescriptor(argList, forKeyword: AEKeyword(0x2D2D2D2D)) // keyDirectObject '----'
            result = script.executeAppleEvent(event, error: &errorDict)
        }

        if let errorDict {
            let msg = (errorDict[NSAppleScript.errorMessage] as? String)
                ?? (errorDict[NSAppleScript.errorBriefMessage] as? String)
                ?? "AppleScript が失敗しました。"
            throw AppError.audioControlFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return result?.stringValue ?? ""
    }

    private func ensureBrowserRunningForControl() throws {
        guard isBrowserCurrentlyRunning() else {
            browserExtensionState = .browserNotRunning
            throw AppError.audioControlFailed("\(Self.browserDisplayName) が起動していません。対象ページを \(Self.browserDisplayName) で開いた状態で再試行してください。")
        }
    }

    /// AppleScript エラーメッセージを解析し、
    /// 「Apple Event からの JavaScript を許可」が無効な場合に
    /// ユーザー向けの案内メッセージに変換する。
    private func safariJavaScriptPermissionMessage(from raw: String) -> String {
        // -1743: errAEEventNotPermitted（do JavaScript が無効）
        // -10004: errAEPrivilegeError（アクセス権違反）
        if raw.contains("-1743") || raw.contains("not permitted")
            || raw.contains("Access not allowed")
            || raw.contains("-10004") || raw.contains("アクセス権の違反")
            || raw.contains("access rights") {
            return "Safari 設定 → デベロッパ → オートメーション →「Apple Event からの JavaScript を許可」をチェックしてください"
        }
        return raw
    }

    private func isBrowserCurrentlyRunning() -> Bool {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.Safari")
            .contains(where: { $0.isTerminated == false })
    }
}

enum CalendarResolver {
    static func isCalendarURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return false
        }
        return host.contains("mlb.com") && url.path.lowercased().contains("/schedule")
    }

    static func urlsMatch(_ lhs: URL, _ rhs: URL?) -> Bool {
        guard let rhs else {
            return false
        }
        return normalizedURL(lhs) == normalizedURL(rhs)
    }

    private static func normalizedURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        let absolute = components?.url?.absoluteString ?? url.absoluteString
        if absolute.hasSuffix("/") {
            return String(absolute.dropLast())
        }
        return absolute
    }

}
