import Foundation
import AVFoundation

/// AVFoundation-backed video conversion. Async; reports progress via the
/// `progress` closure. Cancellation is cooperative: call `cancel()` on the
/// returned `Handle` and the export session is invalidated.
enum VideoConverter {
    final class Handle {
        fileprivate let session: AVAssetExportSession
        fileprivate let timer: DispatchSourceTimer
        init(session: AVAssetExportSession, timer: DispatchSourceTimer) {
            self.session = session
            self.timer = timer
        }
        func cancel() {
            timer.cancel()
            session.cancelExport()
        }
    }

    /// Returns the destination URL on success.
    /// `progress` is called on the main queue with values in 0...1.
    static func convertToMP4(
        source: URL,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, ConversionError>) -> Void
    ) -> Handle? {
        guard FileManager.default.fileExists(atPath: source.path) else {
            completion(.failure(.sourceMissing))
            return nil
        }

        let asset = AVURLAsset(url: source)
        guard asset.isReadable else {
            completion(.failure(.sourceUnreadable))
            return nil
        }

        // Pass-through when source is already H.264/AAC (or audio-less); we
        // detect this by inspecting tracks' format descriptions.
        let preset = canPassthrough(asset: asset)
            ? AVAssetExportPresetPassthrough
            : AVAssetExportPresetHighestQuality

        let finalDest: URL
        do {
            finalDest = try resolveDestination(for: source)
        } catch {
            completion(.failure(.destinationUnwritable))
            return nil
        }

        let tempURL = finalDest
            .deletingPathExtension()
            .appendingPathExtension("part\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("mp4")

        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            completion(.failure(.encodingFailed(reason: "export session unavailable")))
            return nil
        }
        export.outputURL = tempURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        // Poll progress at ~10 Hz (AVAssetExportSession has no KVO-friendly
        // progress prior to iOS 18 / macOS 15; polling is the documented path).
        let queue = DispatchQueue(label: "shelfdemo.video.progress")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak export] in
            guard let export else { return }
            let p = Double(export.progress)
            DispatchQueue.main.async { progress(p) }
        }
        timer.resume()

        let handle = Handle(session: export, timer: timer)

        export.exportAsynchronously {
            timer.cancel()
            DispatchQueue.main.async {
                switch export.status {
                case .completed:
                    do {
                        try FileManager.default.moveItem(at: tempURL, to: finalDest)
                        progress(1.0)
                        completion(.success(finalDest))
                    } catch {
                        try? FileManager.default.removeItem(at: tempURL)
                        completion(.failure(.destinationUnwritable))
                    }
                case .cancelled:
                    try? FileManager.default.removeItem(at: tempURL)
                    completion(.failure(.cancelled))
                case .failed:
                    try? FileManager.default.removeItem(at: tempURL)
                    let reason = export.error?.localizedDescription ?? "unknown error"
                    completion(.failure(.encodingFailed(reason: reason)))
                default:
                    try? FileManager.default.removeItem(at: tempURL)
                    completion(.failure(.encodingFailed(reason: "unexpected status")))
                }
            }
        }
        return handle
    }

    // MARK: - Internals

    private static func canPassthrough(asset: AVAsset) -> Bool {
        // Pass-through is safe when every video track is H.264 and every
        // audio track is AAC. (No tracks → also safe; just a remux.)
        let videoTracks = asset.tracks(withMediaType: .video)
        let audioTracks = asset.tracks(withMediaType: .audio)
        let videoOK = videoTracks.allSatisfy { trackHasFormat($0, fourCC: "avc1") }
        let audioOK = audioTracks.allSatisfy { trackHasFormat($0, fourCC: "mp4a") }
        return videoOK && audioOK
    }

    private static func trackHasFormat(_ track: AVAssetTrack, fourCC: String) -> Bool {
        guard let descs = track.formatDescriptions as? [CMFormatDescription] else {
            return false
        }
        return descs.allSatisfy { desc in
            let code = CMFormatDescriptionGetMediaSubType(desc)
            // Convert the FourCC string to a UInt32.
            let bytes = Array(fourCC.utf8)
            guard bytes.count == 4 else { return false }
            let expected = (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                |  UInt32(bytes[3])
            return code == expected
        }
    }

    private static func resolveDestination(for source: URL) throws -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let preferred = source
            .deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension("mp4")
        let candidate = UniqueDestination.url(preferred: preferred)

        // Empirically probe writability (mirrors ImageConverter logic).
        let probe = candidate
            .deletingPathExtension()
            .appendingPathExtension("probe\(UUID().uuidString.prefix(6))")
        do {
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return candidate
        } catch {
            let cache = try FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("Dropshit/Converted", isDirectory: true)
            try FileManager.default.createDirectory(
                at: cache, withIntermediateDirectories: true
            )
            let p = cache.appendingPathComponent(stem).appendingPathExtension("mp4")
            return UniqueDestination.url(preferred: p)
        }
    }
}
