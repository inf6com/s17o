import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    private let outputQueue = DispatchQueue(label: "s17o.SystemAudioCapture")
    private let onSpeechBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let onAnalysisBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let onAudioPipelineStatusChange: @MainActor @Sendable (String) -> Void
    private let onSourceChange: @MainActor @Sendable (String) -> Void
    private let onFailure: @MainActor @Sendable (Error) async -> Void
    private let speechConverter = AudioBufferConverter(targetFormat: AudioFormatContract.speech.avAudioFormat)
    private let analysisConverter = AudioBufferConverter(targetFormat: AudioFormatContract.analysis.avAudioFormat)
    private var stream: SCStream?

    init(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onAnalysisBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void = { _ in },
        onAudioPipelineStatusChange: @escaping @MainActor @Sendable (String) -> Void,
        onSourceChange: @escaping @MainActor @Sendable (String) -> Void,
        onFailure: @escaping @MainActor @Sendable (Error) async -> Void
    ) {
        self.onSpeechBuffer = onBuffer
        self.onAnalysisBuffer = onAnalysisBuffer
        self.onAudioPipelineStatusChange = onAudioPipelineStatusChange
        self.onSourceChange = onSourceChange
        self.onFailure = onFailure
    }

    @MainActor
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = selectDisplay(from: content.displays) else {
            throw AppError.noDisplay
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.queueDepth = 3
        configuration.sampleRate = Int(AudioFormatContract.capture.sampleRate)
        configuration.channelCount = Int(AudioFormatContract.capture.channelCount)
        // 映像フレームは不要なので 1fps に抑える
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        // .screen も登録しないと "stream output NOT found" エラーが出るため登録する（映像は無視）
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
        onSourceChange(Self.displayLabel(for: display))
    }

    @MainActor
    func stop() async {
        guard let stream else {
            return
        }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            await onFailure(error)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            await self.onFailure(error)
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else {
            return
        }
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        do {
            guard let pcmBuffer = sampleBuffer.makePCMBuffer() else {
                throw AppError.audioConversionFailed
            }
            let analysisBuffer = try analysisConverter.normalize(pcmBuffer)
            let sampleRate = Int(analysisBuffer.format.sampleRate.rounded())
            let channels = Int(analysisBuffer.format.channelCount)
            let peak = Self.peakLevel(in: analysisBuffer)
            let descriptor = "\(sampleRate)Hz / \(channels)ch / peak \(String(format: "%.2f", peak))"
            onAnalysisBuffer(analysisBuffer)
            Task { @MainActor in
                self.onAudioPipelineStatusChange(descriptor)
            }

            let speechBuffer = try speechConverter.normalize(pcmBuffer)
            onSpeechBuffer(speechBuffer)
        } catch {
            Task { @MainActor in
                await self.onFailure(error)
            }
        }
    }

    private func selectDisplay(from displays: [SCDisplay]) -> SCDisplay? {
        guard let mainScreen = NSScreen.main,
              let screenNumber = mainScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return displays.first
        }

        return displays.first(where: { $0.displayID == screenNumber }) ?? displays.first
    }

    private static func displayLabel(for display: SCDisplay) -> String {
        "\(display.width)x\(display.height) display \(display.displayID) / \(AudioFormatContract.capture.debugDescription)"
    }

    nonisolated private static func peakLevel(in buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else {
            return 0
        }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else {
            return 0
        }

        var peak: Float = 0
        for channelIndex in 0..<channelCount {
            let samples = UnsafeBufferPointer(start: channelData[channelIndex], count: frameCount)
            for sample in samples {
                peak = max(peak, abs(sample))
            }
        }
        return peak
    }
}

private final class AudioBufferConverter {
    private let targetFormat: AVAudioFormat
    nonisolated(unsafe) private var converter: AVAudioConverter?
    nonisolated(unsafe) private var sourceSignature: AudioFormatSignature?

    nonisolated init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    nonisolated func normalize(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let signature = AudioFormatSignature(format: buffer.format)

        if signature.matches(format: targetFormat) {
            return buffer
        }

        if sourceSignature != signature {
            guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                throw AppError.audioConversionFailed
            }
            self.converter = converter
            self.sourceSignature = signature
        }

        guard let converter else {
            throw AppError.audioConversionFailed
        }

        let scaledFrameCount = Double(buffer.frameLength) * (targetFormat.sampleRate / buffer.format.sampleRate)
        let outputCapacity = AVAudioFrameCount(max(1, Int(ceil(scaledFrameCount)) + 64))

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            throw AppError.audioConversionFailed
        }

        let inputState = ConverterInputState(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if inputState.supplied {
                outStatus.pointee = .noDataNow
                return nil
            }

            inputState.supplied = true
            outStatus.pointee = .haveData
            return inputState.buffer
        }

        if let conversionError {
            throw conversionError
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            guard outputBuffer.frameLength > 0 else {
                throw AppError.audioConversionFailed
            }
            return outputBuffer
        case .error:
            throw AppError.audioConversionFailed
        @unknown default:
            throw AppError.audioConversionFailed
        }
    }
}

private final class ConverterInputState: @unchecked Sendable {
    nonisolated(unsafe) var supplied = false
    nonisolated(unsafe) let buffer: AVAudioPCMBuffer

    nonisolated init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private struct AudioFormatSignature: Equatable {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let commonFormat: AVAudioCommonFormat
    let isInterleaved: Bool

    nonisolated init(format: AVAudioFormat) {
        self.sampleRate = format.sampleRate
        self.channelCount = format.channelCount
        self.commonFormat = format.commonFormat
        self.isInterleaved = format.isInterleaved
    }

    nonisolated func matches(format: AVAudioFormat) -> Bool {
        sampleRate == format.sampleRate &&
            channelCount == format.channelCount &&
            commonFormat == format.commonFormat &&
            isInterleaved == format.isInterleaved
    }
}

private extension CMSampleBuffer {
    nonisolated func makePCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        var asbd = asbdPointer.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        pcmBuffer.frameLength = frameCount

        let expectedSourceBufferCount = max(1, format.isInterleaved ? 1 : Int(format.channelCount))
        let audioBufferListSize = MemoryLayout<AudioBufferList>.size + (max(0, expectedSourceBufferCount - 1) * MemoryLayout<AudioBuffer>.size)
        let audioBufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: audioBufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        ).assumingMemoryBound(to: AudioBufferList.self)
        defer {
            audioBufferListPointer.deallocate()
        }
        audioBufferListPointer.pointee.mNumberBuffers = UInt32(expectedSourceBufferCount)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPointer,
            bufferListSize: audioBufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            return nil
        }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(audioBufferListPointer)
        let targetBuffers = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)

        if sourceBuffers.count == targetBuffers.count {
            for index in sourceBuffers.indices {
                guard let source = sourceBuffers[index].mData,
                      let destination = targetBuffers[index].mData else {
                    return nil
                }
                memcpy(destination, source, Int(sourceBuffers[index].mDataByteSize))
                targetBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
            }
            return pcmBuffer
        }

        guard let bytesPerSample = Self.bytesPerSample(for: format.commonFormat) else {
            return nil
        }

        if sourceBuffers.count == 1 {
            guard let source = sourceBuffers[0].mData else {
                return nil
            }
            let sourceBytes = source.assumingMemoryBound(to: UInt8.self)
            for channelIndex in targetBuffers.indices {
                guard let destination = targetBuffers[channelIndex].mData else {
                    return nil
                }
                let destinationBytes = destination.assumingMemoryBound(to: UInt8.self)
                for frameIndex in 0..<Int(frameCount) {
                    let sourceOffset = ((frameIndex * Int(sourceBuffers[0].mNumberChannels)) + channelIndex) * bytesPerSample
                    let destinationOffset = frameIndex * bytesPerSample
                    memcpy(destinationBytes + destinationOffset, sourceBytes + sourceOffset, bytesPerSample)
                }
                targetBuffers[channelIndex].mDataByteSize = UInt32(Int(frameCount) * bytesPerSample)
            }
            return pcmBuffer
        }

        if targetBuffers.count == 1 {
            guard let destination = targetBuffers[0].mData else {
                return nil
            }
            let destinationBytes = destination.assumingMemoryBound(to: UInt8.self)
            for frameIndex in 0..<Int(frameCount) {
                for channelIndex in sourceBuffers.indices {
                    guard let source = sourceBuffers[channelIndex].mData else {
                        return nil
                    }
                    let sourceBytes = source.assumingMemoryBound(to: UInt8.self)
                    let sourceOffset = frameIndex * bytesPerSample
                    let destinationOffset = ((frameIndex * sourceBuffers.count) + channelIndex) * bytesPerSample
                    memcpy(destinationBytes + destinationOffset, sourceBytes + sourceOffset, bytesPerSample)
                }
            }
            targetBuffers[0].mDataByteSize = UInt32(Int(frameCount) * sourceBuffers.count * bytesPerSample)
            return pcmBuffer
        }

        return nil
    }

    nonisolated private static func bytesPerSample(for format: AVAudioCommonFormat) -> Int? {
        switch format {
        case .pcmFormatFloat32:
            MemoryLayout<Float>.size
        case .pcmFormatFloat64:
            MemoryLayout<Double>.size
        case .pcmFormatInt16:
            MemoryLayout<Int16>.size
        case .pcmFormatInt32:
            MemoryLayout<Int32>.size
        case .otherFormat:
            nil
        @unknown default:
            nil
        }
    }
}
