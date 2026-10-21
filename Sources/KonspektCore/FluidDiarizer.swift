#if canImport(FluidAudio)
import FluidAudio
import Foundation

/// Offline pyannote segmentation + WeSpeaker embeddings + VBx clustering on Core ML.
/// Models (~21 MB) are downloaded from Hugging Face on first use; audio stays on the machine.
@available(macOS 14.0, *)
final class FluidDiarizer: Diarizer {
    private let manager = OfflineDiarizerManager(config: .default)

    func diarize(_ samples: [Float]) async throws -> (segments: [VoiceSegment], embeddings: [String: [Float]]) {
        try await manager.prepareModels()
        let r: DiarizationResult
        do { r = try await manager.process(audio: samples) } catch OfflineDiarizationError.noSpeechDetected {
            return ([], [:])
        }
        let segments = r.segments.map {
            VoiceSegment(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
        var embeddings = r.speakerDatabase ?? [:]
        for s in r.segments where embeddings[s.speakerId] == nil && !s.embedding.isEmpty {
            embeddings[s.speakerId] = s.embedding
        }
        return (segments, embeddings)
    }
}
#endif

public enum Diarization {
    /// The local diarizer, nil where it is unavailable (Windows, macOS 14).
    public static func local() -> Diarizer? {
        #if canImport(FluidAudio)
        // macOS 14 crashes in BNNS on Core ML predictions (FluidAudio docs, fixed in macOS 15).
        if #available(macOS 15.0, *) { return FluidDiarizer() }
        #endif
        return nil
    }
}
