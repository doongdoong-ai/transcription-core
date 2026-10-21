import Foundation

/// Committed audio coverage, including verified chunks from an earlier session.
/// This is not an estimated completion time or decoder-token percentage.
public struct TranscriptionProgress: Sendable, Equatable {
    public let processedSeconds: Double
    public let totalSeconds: Double
    public let completedChunks: Int
    public let phase: SpeechProcessingPhase
    public init(processedSeconds: Double, totalSeconds: Double, completedChunks: Int, phase: SpeechProcessingPhase = .recognition) {
        self.processedSeconds = processedSeconds; self.totalSeconds = totalSeconds
        self.completedChunks = completedChunks; self.phase = phase
    }
    public var fraction: Double { totalSeconds > 0 ? min(1, max(0, processedSeconds / totalSeconds)) : 0 }
}

public enum SpeechProcessingPhase: String, Sendable { case recognition, alignment }
