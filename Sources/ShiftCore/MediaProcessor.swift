import AVFoundation

enum MediaProcessor {
    static func export(_ url: URL, preset: String, fileType: AVFileType, to output: URL,
                       timeRange: CMTimeRange? = nil) async throws {
        let asset = AVURLAsset(url: url)
        if preset == AVAssetExportPresetAppleM4A, try await asset.loadTracks(withMediaType: .audio).isEmpty {
            throw ShiftError.failed("\(url.lastPathComponent) heeft geen audio")
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ShiftError.failed("Exporteren kan niet voor \(url.lastPathComponent)")
        }
        session.shouldOptimizeForNetworkUse = true
        if let timeRange { session.timeRange = timeRange }
        try await session.export(to: output, as: fileType)
    }

    /// Re-encodes to H.264 + AAC in MP4 with a capped bitrate, so the result is small and plays in every browser.
    /// Apple's export presets use fixed high bitrates and often make already-efficient files bigger.
    static func transcodeForWeb(_ url: URL, maxShortEdge: Int, bitsPerPixel: Double = 0.1, sourceCap: Double = 1.1,
                                to output: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ShiftError.failed("\(url.lastPathComponent) heeft geen videospoor")
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let (natural, transform, fps, sourceRate) = try await videoTrack.load(.naturalSize, .preferredTransform,
                                                                              .nominalFrameRate, .estimatedDataRate)

        // Scale on the short edge so portrait 1080x1920 counts as 1080p too.
        let scale = min(1, CGFloat(maxShortEdge) / min(natural.width, natural.height))
        let width = Int((natural.width * scale / 2).rounded()) * 2
        let height = Int((natural.height * scale / 2).rounded()) * 2

        // 0.1 bits per pixel per frame is clean for web video; never exceed the source's own bitrate by much.
        let frameRate = Double(fps > 0 ? fps : 30)
        var bitrate = Double(width * height) * frameRate * bitsPerPixel
        if sourceRate > 0 { bitrate = min(bitrate, Double(sourceRate) * sourceCap) }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: Int(frameRate * 2),
            ],
        ])
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        var pairs = [(videoOutput as AVAssetReaderOutput, videoInput)]
        if let audioTrack {
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(audioOutput)
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 128_000,
            ])
            audioInput.expectsMediaDataInRealTime = false
            writer.add(audioInput)
            pairs.append((audioOutput, audioInput))
        }

        guard reader.startReading() else { throw reader.error ?? ShiftError.failed("Video lezen mislukt") }
        guard writer.startWriting() else { throw writer.error ?? ShiftError.failed("Video schrijven mislukt") }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            for (index, (readerOutput, writerInput)) in pairs.enumerated() {
                group.addTask {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let queue = DispatchQueue(label: "shift.transcode.\(index)")
                        writerInput.requestMediaDataWhenReady(on: queue) {
                            while writerInput.isReadyForMoreMediaData {
                                guard reader.status == .reading, let buffer = readerOutput.copyNextSampleBuffer() else {
                                    writerInput.markAsFinished()
                                    continuation.resume()
                                    return
                                }
                                if !writerInput.append(buffer) {
                                    reader.cancelReading()
                                }
                            }
                        }
                    }
                }
            }
        }

        if reader.status == .failed || writer.status == .failed {
            writer.cancelWriting()
            throw writer.error ?? reader.error ?? ShiftError.failed("Video omzetten mislukt")
        }
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}
