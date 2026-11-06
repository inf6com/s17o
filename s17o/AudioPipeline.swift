import AVFoundation
import Foundation

// MARK: - AudioPipeline

/// 音声監視パイプラインのオーケストレーター。
///
/// AppModel から音声処理の配線責任を切り離す。
/// SystemAudioCapture / KeywordRecognizer / AudioInferenceEngine の生成・接続・破棄を管理し、
/// 結果のみをコールバックで上位レイヤーへ届ける。
///
/// ─ データフロー ────────────────────────────────────────────────────────────
///
///   ScreenCaptureKit
///     │
///     ├─[PCM 48kHz/2ch]─→ AudioFormatContract.analysis ──→ AudioInferenceEngine ──→ onInference
///     │                                                 ──→ AudioSampleStore (optional)
///     │
///     └─[PCM 16kHz/1ch]─→ AudioFormatContract.speech ──→ KeywordRecognizer ──→ onSpeechMatch
///
///   ClosedCaptionSegment ─────────────────────────────→ KeywordRecognizer ──→ onCaptionMatch
///
@MainActor
final class AudioPipeline {

    // MARK: Init

    init(
        keywords: [String],
        captureAudioSamples: Bool,
        onSpeechMatch:    @escaping @MainActor @Sendable (String, String) -> Void,
        onTranscript:     @escaping @MainActor @Sendable (String) -> Void,
        onInference:      @escaping @MainActor @Sendable (AudioInferenceSnapshot) -> Void,
        onPipelineStatus: @escaping @MainActor @Sendable (String) -> Void,
        onSourceChange:   @escaping @MainActor @Sendable (String) -> Void,
        onFailure:        @escaping @MainActor @Sendable (Error) async -> Void,
        onCaptionMatch:   @escaping @MainActor @Sendable (String, ClosedCaptionSegment) -> Void = { _, _ in }
    ) {
        self.keywords            = keywords
        self.captureAudioSamples = captureAudioSamples
        self.onSpeechMatch       = onSpeechMatch
        self.onTranscript        = onTranscript
        self.onInference         = onInference
        self.onPipelineStatus    = onPipelineStatus
        self.onSourceChange      = onSourceChange
        self.onFailure           = onFailure
        self.onCaptionMatch      = onCaptionMatch
    }

    // MARK: Public interface

    private(set) var isActive = false

    /// パイプラインを起動する。失敗した場合は throws。
    func start() async throws {
        precondition(!isActive, "AudioPipeline.start() called while already active")

        let recognizer = try KeywordRecognizer(
            keywords: keywords,
            onTranscript: { [weak self] text in
                Task { @MainActor in self?.onTranscript(text) }
            },
            onMatch: { [weak self] keyword, text in
                Task { @MainActor in self?.onSpeechMatch(keyword, text) }
            },
            onFailure: { [weak self] error in
                Task { @MainActor in await self?.onFailure(error) }
            }
        )

        let inferenceEngine = try AudioInferenceEngine(
            streamFormat: AudioFormatContract.analysis.avAudioFormat,
            onSnapshot: { [weak self] snapshot in
                Task { @MainActor in self?.onInference(snapshot) }
            },
            onFailure: { [weak self] error in
                Task { @MainActor in await self?.onFailure(error) }
            }
        )

        let store: AudioSampleStore? = captureAudioSamples ? (try? AudioSampleStore()) : nil
        self.sampleStore = store

        let capture = SystemAudioCapture(
            onBuffer: { buffer in
                recognizer.append(buffer)
            },
            onAnalysisBuffer: { [inferenceEngine, store] buffer in
                inferenceEngine.append(buffer)
                if let store, let chunk = AudioAnalysisChunk(buffer: buffer) {
                    store.append(chunk)
                }
            },
            onAudioPipelineStatusChange: { [weak self] descriptor in
                self?.onPipelineStatus(descriptor)
            },
            onSourceChange: { [weak self] source in
                self?.onSourceChange(source)
            },
            onFailure: { [weak self] error in
                await self?.onFailure(error)
            }
        )

        try await capture.start()

        self.capture         = capture
        self.recognizer      = recognizer
        self.inferenceEngine = inferenceEngine
        self.isActive        = true
    }

    /// パイプラインを停止して全リソースを解放する。
    func stop() async {
        defer { isActive = false }
        if let capture { await capture.stop() }
        recognizer?.stop()
        inferenceEngine?.finish()
        capture         = nil
        recognizer      = nil
        inferenceEngine = nil
        sampleStore     = nil
    }

    /// CC テキストをキーワード認識パイプラインへ注入する。
    /// ブラウザ拡張から届いた字幕テキストを音声認識の補完チャンネルとして処理する。
    func append(caption segment: ClosedCaptionSegment) {
        guard isActive, let recognizer else { return }
        recognizer.append(caption: segment, onMatch: { [weak self] keyword in
            guard let self else { return }
            self.onCaptionMatch(keyword, segment)
        })
    }

    /// AudioSampleStore への参照（AppModel からのアクセス用）
    var audioSampleStore: AudioSampleStore? { sampleStore }

    // MARK: Private

    private let keywords: [String]
    private let captureAudioSamples: Bool

    private let onSpeechMatch:    @MainActor @Sendable (String, String) -> Void
    private let onTranscript:     @MainActor @Sendable (String) -> Void
    private let onInference:      @MainActor @Sendable (AudioInferenceSnapshot) -> Void
    private let onPipelineStatus: @MainActor @Sendable (String) -> Void
    private let onSourceChange:   @MainActor @Sendable (String) -> Void
    private let onFailure:        @MainActor @Sendable (Error) async -> Void
    private let onCaptionMatch:   @MainActor @Sendable (String, ClosedCaptionSegment) -> Void

    private var capture:         SystemAudioCapture?
    private var recognizer:      KeywordRecognizer?
    private var inferenceEngine: AudioInferenceEngine?
    private var sampleStore:     AudioSampleStore?
}
