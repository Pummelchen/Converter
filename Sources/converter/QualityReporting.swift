import Foundation

struct AudioQCPolicy: Hashable, Sendable {
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

struct AudioQCMetrics: Sendable {
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

struct AudioQCResult: Sendable {
    // The policy is carried by value rather than mirrored field-by-field; the copies
    // were written on every QC run and never read back.
    let policy: AudioQCPolicy
    let metrics: AudioQCMetrics
    let passed: Bool
    let issues: [String]
}

extension ProjectConfig {
    var masteringAudioQCPolicy: AudioQCPolicy {
        AudioQCPolicy(
            name: "mastering",
            targetLUFS: masteringTargetLUFS,
            lufsTolerance: max(0.5, audioQCLUFSTolerance / 2),
            maxTruePeakDBTP: masteringMaxTruePeakDBTP,
            maxLoudnessRange: masteringMaxLoudnessRange,
            maxDCOffset: audioQCMaxDCOffset,
            maxStereoImbalanceDB: audioQCMaxStereoImbalanceDB,
            maxClippedSamples: audioQCMaxClippedSamples,
            minimumAnalysisSeconds: audioQCMinimumAnalysisSeconds
        )
    }

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
