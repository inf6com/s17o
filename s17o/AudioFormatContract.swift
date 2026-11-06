import AVFoundation
import Foundation

// MARK: - ClosedCaptionSegment

/// クローズドキャプション（字幕）テキストのセグメント。
/// 音声認識（PCM チャンネル）の補完テキストチャンネルとして機能する。
///
/// PCM 音声 ──→ SpeechRecognition ──→ KeywordRecognizer
/// CC テキスト ──────────────────────→ KeywordRecognizer  ← 同一の検出パスで処理
///
struct ClosedCaptionSegment: Sendable, Equatable {
    let text: String
    let capturedAt: Date

    enum Source: String, Sendable, Equatable {
        case browserDOM    // ブラウザ拡張が DOM から取得した字幕テキスト
        case videoPlayer   // 動画プレーヤーの字幕トラック（将来対応）
    }
    let source: Source
}

// MARK: - AudioStreamFormatContract

struct AudioStreamFormatContract: Equatable {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let commonFormat: AVAudioCommonFormat
    let isInterleaved: Bool

    @MainActor var avAudioFormat: AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: isInterleaved
        ) else {
            preconditionFailure("無効な音声フォーマットです: \(debugDescription)")
        }
        return format
    }

    var debugDescription: String {
        "\(Int(sampleRate.rounded()))Hz / \(channelCount)ch / \(commonFormat)"
    }

    func matches(_ format: AVAudioFormat) -> Bool {
        sampleRate == format.sampleRate &&
            channelCount == format.channelCount &&
            commonFormat == format.commonFormat &&
            isInterleaved == format.isInterleaved
    }
}

enum AudioFormatContract {
    static let capture = AudioStreamFormatContract(
        sampleRate: 48_000,
        channelCount: 2,
        commonFormat: .pcmFormatFloat32,
        isInterleaved: false
    )

    static let analysis = AudioStreamFormatContract(
        sampleRate: 48_000,
        channelCount: 2,
        commonFormat: .pcmFormatFloat32,
        isInterleaved: false
    )

    static let speech = AudioStreamFormatContract(
        sampleRate: 16_000,
        channelCount: 1,
        commonFormat: .pcmFormatFloat32,
        isInterleaved: false
    )
}
