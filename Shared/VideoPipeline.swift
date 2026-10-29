@preconcurrency import AVFoundation
import Foundation

@MainActor
final class VideoPipeline {
    private let transferRoot: URL?
    private let videoRoot: URL?
    init(transferRoot: URL? = nil, videoRoot: URL? = nil) {
        self.transferRoot = transferRoot
        self.videoRoot = videoRoot
    }
    func run(_ variant: MediaVariant, id: String,
             update: @escaping @MainActor @Sendable (TransferUpdate) -> Void) async throws -> URL {
        let root = try (transferRoot ?? VideoStorage.transfers()).appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = MediaTransfer.shared
        let video = try await downloader.download(variant.video, headers: variant.headers, to: root.appendingPathComponent("video.mp4")) { received, expected in
            Task { @MainActor in
                update(TransferUpdate(state: .downloading, progress: expected.map { Double(received) / Double($0) * (variant.audio == nil ? 0.9 : 0.75) }, received: received, expected: expected))
            }
        }
        try Task.checkCancellation()
        var inputs = [video]
        if let audioURL = variant.audio {
            let videoSize = Int64((try? video.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let audio = try await downloader.download(audioURL, headers: variant.headers, to: root.appendingPathComponent("audio.m4a")) { received, expected in
                Task { @MainActor in
                    update(TransferUpdate(state: .downloading, progress: expected.map { 0.75 + Double(received) / Double($0) * 0.15 }, received: videoSize + received, expected: expected.map { videoSize + $0 }))
                }
            }
            inputs.append(audio)
        }
        try Task.checkCancellation()
        update(TransferUpdate(state: .merging, progress: nil, note: "Ghép hình và tiếng bằng AVFoundation trên iPhone."))
        let destination = try videoRoot ?? VideoStorage.videos()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let output = destination.appendingPathComponent("LocalReel-\(id).mp4")
        do {
            try await export(inputs: inputs, output: output, update: update)
            try Task.checkCancellation()
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    func export(inputs: [URL], output: URL, update: @escaping @MainActor @Sendable (TransferUpdate) -> Void) async throws {
        let composition = AVMutableComposition()
        var hasVideo = false, hasAudio = false
        for input in inputs {
            let asset = AVURLAsset(url: input)
            guard try await asset.load(.isReadable) else { throw LocalReelError(message: "Định dạng nguồn chưa đọc được trên iPhone.") }
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, CMTimeCompare(duration, .zero) > 0 else { throw LocalReelError(message: "Video không có thời lượng hợp lệ.") }
            if !hasVideo, let track = try await asset.loadTracks(withMediaType: .video).first {
                let mutable = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try mutable.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
                mutable.preferredTransform = try await track.load(.preferredTransform)
                hasVideo = true
            }
            if !hasAudio, let track = try await asset.loadTracks(withMediaType: .audio).first {
                let mutable = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try mutable.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
                hasAudio = true
            }
        }
        guard hasVideo, hasAudio else { throw LocalReelError(message: "Nguồn thiếu hình hoặc âm thanh; chưa tạo được MP4 đầy đủ.") }
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        do {
            try await performExport(composition, preset: AVAssetExportPresetPassthrough, output: output, update: update)
        } catch is CancellationError { try? FileManager.default.removeItem(at: output); throw CancellationError() }
        catch {
            try? FileManager.default.removeItem(at: output)
            try Task.checkCancellation()
            update(TransferUpdate(state: .merging, progress: nil, note: "Đang tạo MP4 tương thích bằng phần cứng iPhone; có thể thay đổi chất lượng."))
            do { try await performExport(composition, preset: AVAssetExportPresetHighestQuality, output: output, update: update) }
            catch { try? FileManager.default.removeItem(at: output); throw error }
        }
        let result = AVURLAsset(url: output)
        let videos = try await result.loadTracks(withMediaType: .video)
        let audios = try await result.loadTracks(withMediaType: .audio)
        guard !videos.isEmpty, !audios.isEmpty else {
            try? FileManager.default.removeItem(at: output)
            throw LocalReelError(message: "MP4 đầu ra chưa có đủ hình và tiếng.")
        }
    }
    private func performExport(_ asset: AVAsset, preset: String, output: URL,
                               update: @escaping @MainActor @Sendable (TransferUpdate) -> Void) async throws {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else { throw LocalReelError(message: "iPhone chưa hỗ trợ xuất định dạng video này.") }
        exporter.outputURL = output
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                update(TransferUpdate(state: .merging, progress: Double(exporter.progress)))
                do { try await Task.sleep(for: .milliseconds(300)) } catch { break }
            }
        }
        defer { observer.cancel() }
        try await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in exporter.exportAsynchronously { continuation.resume() } }
            try Task.checkCancellation()
            guard exporter.status == .completed else { throw exporter.error ?? LocalReelError(message: "Chưa xuất được MP4 trên iPhone.") }
        } onCancel: { exporter.cancelExport() }
    }
}
