import Foundation

struct AudioQCPolicy: Sendable {
    let name: String
    let targetLUFS: Double
    let lufsTolerance: Double
    let maxTruePeakDBTP: Double
    let maxLoudnessRange: Double
    let maxDCOffset: Double
    let maxStereoImbalanceDB: Double
    let maxClippedSamples: Int
    let minimumAnalysisSeconds: Double

    var minimumLUFS: Double { targetLUFS - lufsTolerance }
    var maximumLUFS: Double { targetLUFS + lufsTolerance }
}

struct AudioQCMetrics: Codable, Sendable {
    let integratedLUFS: Double?
    let truePeakDBTP: Double?
    let loudnessRange: Double?
    let dcOffset: Double?
    let stereoImbalanceDB: Double?
    let peakLevelDBFS: Double?
    let clippedSamples: Int
    let maxVolumeDBFS: Double?
    let analysisLimited: Bool
}

struct AudioQCResult: Codable, Sendable {
    let policy: String
    let targetLUFS: Double
    let lufsTolerance: Double
    let maxTruePeakDBTP: Double
    let maxLoudnessRange: Double
    let maxDCOffset: Double
    let maxStereoImbalanceDB: Double
    let maxClippedSamples: Int
    let minimumAnalysisSeconds: Double
    let metrics: AudioQCMetrics
    let passed: Bool
    let issues: [String]
}

extension ProjectConfig {
    var deliveryAudioQCPolicy: AudioQCPolicy {
        AudioQCPolicy(
            name: "delivery",
            targetLUFS: audioQCTargetLUFS,
            lufsTolerance: audioQCLUFSTolerance,
            maxTruePeakDBTP: audioQCMaxTruePeakDBTP,
            maxLoudnessRange: audioQCMaxLoudnessRange,
            maxDCOffset: audioQCMaxDCOffset,
            maxStereoImbalanceDB: audioQCMaxStereoImbalanceDB,
            maxClippedSamples: audioQCMaxClippedSamples,
            minimumAnalysisSeconds: audioQCMinimumAnalysisSeconds
        )
    }

    var shortFormAudioQCPolicy: AudioQCPolicy {
        AudioQCPolicy(
            name: "short-form",
            targetLUFS: shortAudioQCTargetLUFS,
            lufsTolerance: shortAudioQCLUFSTolerance,
            maxTruePeakDBTP: audioQCMaxTruePeakDBTP,
            maxLoudnessRange: shortAudioQCMaxLoudnessRange,
            maxDCOffset: audioQCMaxDCOffset,
            maxStereoImbalanceDB: audioQCMaxStereoImbalanceDB,
            maxClippedSamples: audioQCMaxClippedSamples,
            minimumAnalysisSeconds: audioQCMinimumAnalysisSeconds
        )
    }
}
