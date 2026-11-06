import AVFoundation
import Foundation
import Speech

final class KeywordRecognizer: @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    nonisolated(unsafe) private let request: SFSpeechAudioBufferRecognitionRequest
    private let requestQueue = DispatchQueue(label: "s17o.KeywordRecognizer")
    nonisolated(unsafe) private var task: SFSpeechRecognitionTask?
    private let keywords: [String]
    private let onTranscript: (String) -> Void
    private let onMatch: (String, String) -> Void
    private let onFailure: (Error) -> Void

    init(
        keywords: [String],
        onTranscript: @escaping (String) -> Void,
        onMatch: @escaping (String, String) -> Void,
        onFailure: @escaping (Error) -> Void
    ) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            throw AppError.speechRecognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw AppError.onDeviceRecognitionUnavailable
        }
        guard recognizer.isAvailable else {
            throw AppError.speechRecognizerUnavailable
        }

        self.recognizer = recognizer
        self.request = SFSpeechAudioBufferRecognitionRequest()
        self.keywords = keywords
        self.onTranscript = onTranscript
        self.onMatch = onMatch
        self.onFailure = onFailure

        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = keywords

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else {
                return
            }

            if let error {
                self.onFailure(error)
                return
            }

            guard let result else {
                return
            }

            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return
            }

            self.onTranscript(text)

            if let keyword = self.detectKeyword(in: text) {
                self.onMatch(keyword, text)
            }
        }
    }

    /// PCM バッファを音声認識に供給する。
    /// フォーマットは AudioFormatContract.speech（16kHz/1ch/Float32）であること。
    /// フォーマット契約は AudioPipeline レイヤーで保証されるため、ここでは再チェックしない。
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        requestQueue.sync {
            request.append(buffer)
        }
    }

    /// CC テキストをキーワード検出に直接供給する（テキストチャンネル）。
    /// 音声認識（PCM チャンネル）の補完として機能し、同一の detectKeyword ロジックを使用する。
    nonisolated func append(caption segment: ClosedCaptionSegment, onMatch: @escaping (String) -> Void) {
        requestQueue.sync {
            if let keyword = detectKeyword(in: segment.text) {
                onMatch(keyword)
            }
        }
    }

    nonisolated func stop() {
        requestQueue.sync {
            request.endAudio()
            task?.cancel()
            task = nil
        }
    }

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SafariBridge.requestSpeechAuthorization { rawStatus in
                // Delivered on main queue by SafariBridge
                MainActor.assumeIsolated {
                    let status = SFSpeechRecognizerAuthorizationStatus(rawValue: Int(rawStatus)) ?? .notDetermined
                    continuation.resume(returning: status)
                }
            }
        }
    }

    private func detectKeyword(in transcript: String) -> String? {
        let normalizedTranscript = normalize(transcript)
        let transcriptTokens = tokenize(normalizedTranscript)

        for keyword in keywords {
            let normalizedKeyword = normalize(keyword)
            if normalizedTranscript.contains(normalizedKeyword) {
                return keyword
            }

            let keywordTokens = tokenize(normalizedKeyword)
            if keywordTokens.isEmpty {
                continue
            }

            let exactLength = keywordTokens.count
            let candidateLengths = Set([max(1, exactLength - 1), exactLength, exactLength + 1]).sorted()
            var bestScore = 0.0

            for candidateLength in candidateLengths {
                guard candidateLength <= transcriptTokens.count else {
                    continue
                }

                for start in 0...(transcriptTokens.count - candidateLength) {
                    let window = transcriptTokens[start..<(start + candidateLength)].joined(separator: " ")
                    let score = similarity(normalizedKeyword, window)
                    if score > bestScore {
                        bestScore = score
                    }
                }
            }

            if bestScore >= threshold(for: keywordTokens.count) {
                return keyword
            }
        }

        return nil
    }

    private func threshold(for keywordTokenCount: Int) -> Double {
        keywordTokenCount <= 1 ? 0.82 : 0.76
    }

    private func tokenize(_ text: String) -> [String] {
        text.split { $0.isWhitespace }.map(String.init)
    }

    private func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9 ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func similarity(_ lhs: String, _ rhs: String) -> Double {
        let distance = levenshtein(lhs, rhs)
        let longest = max(lhs.count, rhs.count)
        guard longest > 0 else {
            return 1
        }
        return 1 - (Double(distance) / Double(longest))
    }

    private func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let lhsArray = Array(lhs)
        let rhsArray = Array(rhs)

        if lhsArray.isEmpty {
            return rhsArray.count
        }
        if rhsArray.isEmpty {
            return lhsArray.count
        }

        var previous = Array(0...rhsArray.count)
        for (lhsIndex, lhsCharacter) in lhsArray.enumerated() {
            var current = [lhsIndex + 1]
            current.reserveCapacity(rhsArray.count + 1)

            for (rhsIndex, rhsCharacter) in rhsArray.enumerated() {
                let insertion = current[rhsIndex] + 1
                let deletion = previous[rhsIndex + 1] + 1
                let substitution = previous[rhsIndex] + (lhsCharacter == rhsCharacter ? 0 : 1)
                current.append(min(insertion, deletion, substitution))
            }

            previous = current
        }

        return previous[rhsArray.count]
    }
}
