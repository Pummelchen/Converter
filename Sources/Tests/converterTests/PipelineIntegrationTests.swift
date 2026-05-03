import Foundation
import XCTest
@testable import converter

final class PipelineIntegrationTests: XCTestCase {
    // Large stderr output used to risk pipe-buffer deadlock; this keeps that path under test.
    func testRunHandlesLargeStderrWithoutDeadlock() throws {
        let workspace = try IntegrationWorkspace()
        let runner = workspace.runner()
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = ResultBox<Result<ProcessResult, Error>>()

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> ProcessResult in
                try runner.run("/bin/sh", [
                    "-c",
                    "i=0; while [ $i -lt 40000 ]; do printf 'noisy-line-%05d\\n' \"$i\" 1>&2; i=$((i+1)); done"
                ])
            }
            outcome.store(result)
            semaphore.signal()
        }

        XCTAssertEqual(semaphore.wait(timeout: .now() + 10), .success, "ProcessRunner.run timed out while draining stderr.")
        let processResult = try XCTUnwrap(outcome.load()).get()
        XCTAssertTrue(processResult.stderr.contains("noisy-line-39999"))
    }

    // Pipelines need concurrent producer/consumer draining so noisy tools do not deadlock each other.
    func testRunPipelineHandlesLargeProducerOutputWithoutDeadlock() throws {
        let workspace = try IntegrationWorkspace()
        let runner = workspace.runner()
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = ResultBox<Result<PipelineProcessResult, Error>>()

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> PipelineProcessResult in
                try runner.runPipeline(
                    producerExecutable: "/bin/sh",
                    producerArguments: [
                        "-c",
                        "i=0; while [ $i -lt 12000 ]; do printf 'payload\\n'; printf 'producer-%05d\\n' \"$i\" 1>&2; i=$((i+1)); done"
                    ],
                    consumerExecutable: "/usr/bin/wc",
                    consumerArguments: ["-l"]
                )
            }
            outcome.store(result)
            semaphore.signal()
        }

        XCTAssertEqual(semaphore.wait(timeout: .now() + 10), .success, "ProcessRunner.runPipeline timed out while draining pipes.")
        let pipelineResult = try XCTUnwrap(outcome.load()).get()
        XCTAssertEqual(pipelineResult.consumer.stdout.trimmed, "12000")
        XCTAssertTrue(pipelineResult.producer.stderr.contains("producer-11999"))
    }

    func testAudioConversionMatrixProducesVerifiedOutputs() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let flac = try workspace.createAudio(name: "audio_flac", ext: "flac")
        let wav = try workspace.createAudio(name: "audio_wav", ext: "wav")
        let mp3 = try workspace.createAudio(name: "audio_mp3", ext: "mp3")
        let m4a = try workspace.createAudio(name: "audio_m4a", ext: "m4a")
        let tool = try workspace.makeTool(arguments: ["-wavtom4a"])

        let checks: [(String, URL, () throws -> URL, (URL) throws -> Void)] = [
            ("flac->wav", flac, { try tool.convertFLACToWAV(flac) }, { file in
                try tool.verifyWAVStandard(file)
                try tool.verifyDurationMatch(source: flac, output: file)
            }),
            ("flac->mp3", flac, { try tool.convertFLACToMP3(flac) }, { file in
                try tool.verifyMP3Standard(file)
                try tool.verifyDurationMatch(source: flac, output: file)
            }),
            ("flac->m4a", flac, { try tool.convertAudioToM4A(flac) }, { file in
                try tool.verifyAudioOutput(file, codec: "aac", sampleRate: tool.config.m4aSampleRate, channels: tool.config.m4aChannels)
                try tool.verifyDurationMatch(source: flac, output: file)
            }),
            ("wav->flac", wav, { try tool.convertWAVToFLAC(wav) }, { file in
                try tool.verifyAudioOutput(file, codec: "flac", sampleRate: tool.config.flacSampleRate, channels: tool.config.flacChannels)
                try tool.verifyDurationMatch(source: wav, output: file)
            }),
            ("wav->mp3", wav, { try tool.convertWAVToMP3(wav) }, { file in
                try tool.verifyMP3Standard(file)
                try tool.verifyDurationMatch(source: wav, output: file)
            }),
            ("wav->m4a", wav, { try tool.convertWAVToM4A(wav) }, { file in
                try tool.verifyAudioOutput(file, codec: "aac", sampleRate: tool.config.m4aSampleRate, channels: tool.config.m4aChannels)
                try tool.verifyDurationMatch(source: wav, output: file)
            }),
            ("mp3->wav", mp3, { try tool.convertMP3ToWAV(mp3) }, { file in
                try tool.verifyWAVStandard(file)
                try tool.verifyDurationMatch(source: mp3, output: file)
            }),
            ("mp3->flac", mp3, { try tool.convertMP3ToFLAC(mp3) }, { file in
                try tool.verifyAudioOutput(file, codec: "flac", sampleRate: tool.config.flacSampleRate, channels: tool.config.flacChannels)
                try tool.verifyDurationMatch(source: mp3, output: file)
            }),
            ("mp3->m4a", mp3, { try tool.convertAudioToM4A(mp3) }, { file in
                try tool.verifyAudioOutput(file, codec: "aac", sampleRate: tool.config.m4aSampleRate, channels: tool.config.m4aChannels)
                try tool.verifyDurationMatch(source: mp3, output: file)
            }),
            ("m4a->wav", m4a, { try tool.convertM4AToWAV(m4a) }, { file in
                try tool.verifyWAVStandard(file)
                try tool.verifyDurationMatch(source: m4a, output: file)
            }),
            ("m4a->mp3", m4a, { try tool.convertM4AToMP3(m4a) }, { file in
                try tool.verifyMP3Standard(file)
                try tool.verifyDurationMatch(source: m4a, output: file)
            }),
            ("m4a->flac", m4a, { try tool.convertM4AToFLAC(m4a) }, { file in
                try tool.verifyAudioOutput(file, codec: "flac", sampleRate: tool.config.flacSampleRate, channels: tool.config.flacChannels)
                try tool.verifyDurationMatch(source: m4a, output: file)
            })
        ]

        for (label, source, build, verify) in checks {
            let output = try build()
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "Missing output for \(label)")
            try verify(output)
            try tool.verifySourceLoudnessPreserved(source: source, output: output)
        }
    }

    func testAudioTranscodesIgnoreAttachedVideoStreams() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])

        let flacWithArtwork = try workspace.createFLACWithArtwork(name: "flac_artwork")
        let mp3WithArtwork = try workspace.createMP3WithArtwork(name: "mp3_artwork")
        let tool = try workspace.makeTool(arguments: ["-flactowav"])

        XCTAssertNoThrow(try tool.requireVideoStream(flacWithArtwork), "FLAC fixture should contain attached artwork.")
        XCTAssertNoThrow(try tool.requireVideoStream(mp3WithArtwork), "MP3 fixture should contain attached artwork.")
        XCTAssertNoThrow(try tool.preflightFLACInput(flacWithArtwork))
        XCTAssertNoThrow(try tool.preflightMP3Input(mp3WithArtwork))

        let wavFromFLAC = try tool.convertFLACToWAV(flacWithArtwork)
        try tool.verifyWAVStandard(wavFromFLAC, qcPolicy: nil)
        XCTAssertThrowsError(try tool.requireVideoStream(wavFromFLAC), "WAV output should contain audio only.")

        let wavFromMP3 = try tool.convertMP3ToWAV(mp3WithArtwork)
        try tool.verifyWAVStandard(wavFromMP3, qcPolicy: nil)
        XCTAssertThrowsError(try tool.requireVideoStream(wavFromMP3), "WAV output should contain audio only.")
    }

    func testExternalFLACVariantStreamCopiesAudioOnlyFromFLACWithArtwork() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])

        let source = try workspace.createFLACWithArtwork(name: "external_flac_artwork")
        let output = workspace.output.appendingPathComponent("external_flac_artwork_RF64").appendingPathExtension("flac")
        let tool = try workspace.makeTool(arguments: ["-flactowav"])

        XCTAssertNoThrow(try tool.requireVideoStream(source), "FLAC fixture should contain attached artwork.")
        let created = try tool.createExternalFLACVariant(source: source, output: output)

        try tool.verifyFLACFile(created, qcPolicy: nil)
        XCTAssertThrowsError(try tool.requireVideoStream(created), "External FLAC output should contain audio only.")
        try tool.verifyCanonicalPCMSampleEquivalence(source: source, output: created, label: "External FLAC", format: .s24le)
    }

    func testImageConversionsAndDerivativesProduceVerifiedOutputs() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["magick", "ffmpeg", "ffprobe"])

        let png = try workspace.createImage(name: "poster", ext: "png")
        let jpg = try workspace.createImage(name: "cover", ext: "jpg")
        let jpeg = try workspace.createImage(name: "scan", ext: "jpeg")
        let tool = try workspace.makeTool(arguments: ["-aipix"])

        let pngFromJpg = try tool.convertJPGToPNG(jpg)
        try tool.verifyImageOutput(pngFromJpg, width: tool.config.image8KWidth, height: tool.config.image8KHeight, format: "PNG")

        let pngFromJpeg = try tool.convertJPGToPNG(jpeg)
        try tool.verifyImageOutput(pngFromJpeg, width: tool.config.image8KWidth, height: tool.config.image8KHeight, format: "PNG")

        let jpgFromPng = try tool.convertPNGToJPEG(png, outputExtension: "jpg")
        try tool.verifyImageOutput(jpgFromPng, width: tool.config.image8KWidth, height: tool.config.image8KHeight, format: "JPEG")

        let aipix = try tool.aipixFile(png)
        try tool.verifyImageOutput(aipix.eightK, width: tool.config.image8KWidth, height: tool.config.image8KHeight, format: "PNG")
        try tool.verifyImageOutput(aipix.fourK, width: tool.config.image4KWidth, height: tool.config.image4KHeight, format: "PNG")

        let nft = try tool.nftFrom8K(aipix.eightK)
        try tool.verifyImageOutput(nft.nft8K, width: tool.config.image8KWidth, height: tool.config.image8KWidth, format: "PNG")
        try tool.verifyImageOutput(nft.nft3K, width: tool.config.image3KSize, height: tool.config.image3KSize, format: "PNG")
        try tool.verifyImageOutput(nft.nft2K, width: tool.config.image2KSize, height: tool.config.image2KSize, format: "PNG")

        let threeK = try tool.squarePNGFrom8K(aipix.eightK, size: tool.config.image3KSize, label: "3K")
        let twoK = try tool.squarePNGFrom8K(aipix.eightK, size: tool.config.image2KSize, label: "2K")
        try tool.verifyImageOutput(threeK, width: tool.config.image3KSize, height: tool.config.image3KSize, format: "PNG")
        try tool.verifyImageOutput(twoK, width: tool.config.image2KSize, height: tool.config.image2KSize, format: "PNG")

        let jpgExtent = try tool.jpegExtentFromPNG(aipix.eightK, requiredWidth: tool.config.image8KWidth, requiredHeight: tool.config.image8KHeight, suffix: "1MB", targetBytes: tool.config.image8KJPG1MBTargetBytes)
        try tool.verifyImageOutput(jpgExtent, width: tool.config.image8KWidth, height: tool.config.image8KHeight, format: "JPEG", maxBytes: tool.config.image8KJPG1MBTargetBytes)
    }

    func testImageOutputsAreNormalizedToSRGB() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["magick"])

        let cmykJPG = workspace.output.appendingPathComponent("cmyk_source.jpg")
        _ = try workspace.runner().run("magick", [
            "-size", "320x180",
            "gradient:#224477-#DD8844",
            "-colorspace", "CMYK",
            cmykJPG.path
        ])

        let tool = try workspace.makeTool(arguments: ["-jpgtopng"])
        let converted = try tool.convertJPGToPNG(cmykJPG)
        let colorspace = try XCTUnwrap(tool.imageColorSpace(converted))
        XCTAssertEqual(colorspace.lowercasedASCII, "srgb")
    }

    func testRejectsJPEGExtensionWithPNGPayload() throws {
        let workspace = try IntegrationWorkspace()
        let png = try workspace.createImage(name: "real_png", ext: "png")
        let fakeJPEG = try workspace.copy(png, as: "fake_photo", ext: "jpg")
        let tool = try workspace.makeTool(arguments: ["-jpgtopng"])
        XCTAssertThrowsError(try tool.convertJPGToPNG(fakeJPEG)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Image format mismatch"))
        }
    }

    func testRejectsPNGExtensionWithJPEGPayload() throws {
        let workspace = try IntegrationWorkspace()
        let jpg = try workspace.createImage(name: "real_jpg", ext: "jpg")
        let fakePNG = try workspace.copy(jpg, as: "fake_graphic", ext: "png")
        let tool = try workspace.makeTool(arguments: ["-pngtojpg"])
        XCTAssertThrowsError(try tool.convertPNGToJPEG(fakePNG, outputExtension: "jpg")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Image format mismatch"))
        }
    }

    func testRejectsMP3ExtensionWithWAVPayload() throws {
        let workspace = try IntegrationWorkspace()
        let wav = try workspace.createAudio(name: "real_wav", ext: "wav")
        let fakeMP3 = try workspace.copy(wav, as: "fake_song", ext: "mp3")
        let tool = try workspace.makeTool(arguments: ["-mp3towav"])
        XCTAssertThrowsError(try tool.convertMP3ToWAV(fakeMP3)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Audio container mismatch") || error.localizedDescription.contains("Audio codec mismatch"))
        }
    }

    func testRejectsFLACExtensionWithMP3Payload() throws {
        let workspace = try IntegrationWorkspace()
        let mp3 = try workspace.createAudio(name: "real_mp3", ext: "mp3")
        let fakeFLAC = try workspace.copy(mp3, as: "fake_lossless", ext: "flac")
        let tool = try workspace.makeTool(arguments: ["-flactowav"])
        XCTAssertThrowsError(try tool.convertFLACToWAV(fakeFLAC)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Audio container mismatch") || error.localizedDescription.contains("Audio codec mismatch"))
        }
    }

    func testRejectsM4AExtensionWithMP3Payload() throws {
        let workspace = try IntegrationWorkspace()
        let mp3 = try workspace.createAudio(name: "real_mp3", ext: "mp3")
        let fakeM4A = try workspace.copy(mp3, as: "fake_aac", ext: "m4a")
        let tool = try workspace.makeTool(arguments: ["-m4atowav"])
        XCTAssertThrowsError(try tool.convertM4AToWAV(fakeM4A)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Audio codec mismatch") || error.localizedDescription.contains("Unexpected video stream") || error.localizedDescription.contains("Audio container mismatch"))
        }
    }

    func testRejectsWAVBinaryGarbage() throws {
        let workspace = try IntegrationWorkspace()
        let garbage = try workspace.writeGarbageFile(name: "broken", ext: "wav")
        let tool = try workspace.makeTool(arguments: ["-wavtomp3"])
        XCTAssertThrowsError(try tool.convertWAVToMP3(garbage))
    }

    func testRejectsMP4ExtensionWithImagePayload() throws {
        let workspace = try IntegrationWorkspace()
        let png = try workspace.createImage(name: "still", ext: "png")
        let fakeMP4 = try workspace.copy(png, as: "still_video", ext: "mp4")
        let tool = try workspace.makeTool(arguments: ["-mp4toshort"])
        XCTAssertThrowsError(try tool.shortenMP4(fakeMP4, audioQCPolicy: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Video container mismatch") || error.localizedDescription.contains("Missing video stream"))
        }
    }

    func testRejectsSilentMP3Input() throws {
        let workspace = try IntegrationWorkspace()
        let silent = try workspace.createSilentAudio(name: "silent_track", ext: "mp3")
        let tool = try workspace.makeTool(arguments: ["-mp3towav"])
        XCTAssertThrowsError(try tool.convertMP3ToWAV(silent)) { error in
            XCTAssertTrue(error.localizedDescription.contains("silent") || error.localizedDescription.contains("audible"))
        }
    }

    func testMP3CleanRemovesArtworkAndExtraStreams() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])

        let taggedMP3 = try workspace.createMP3WithArtwork(name: "artwork_track")
        let tool = try workspace.makeTool(arguments: ["-mp3clean"])

        XCTAssertNoThrow(try tool.requireVideoStream(taggedMP3), "Fixture should contain attached artwork before cleaning.")
        try tool.cleanMP3(taggedMP3)
        try tool.verifyMP3Standard(taggedMP3, qcPolicy: tool.config.deliveryAudioQCPolicy)
        XCTAssertThrowsError(try tool.requireVideoStream(taggedMP3))
    }

    func testMP3CleanDoesNotEnforceDeliveryQCOnStreamCopyCleanup() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig + "\nAUDIO_QC_MAX_TRUE_PEAK_DBTP=-1\n"
        )

        let taggedMP3 = try workspace.createHotMP3WithArtwork(name: "hot_artwork_track")
        let tool = try workspace.makeTool(arguments: ["-mp3clean"])

        XCTAssertNoThrow(try tool.requireVideoStream(taggedMP3), "Fixture should contain attached artwork before cleaning.")
        XCTAssertNoThrow(try tool.cleanMP3(taggedMP3))
        try tool.verifyMP3Standard(taggedMP3, qcPolicy: nil)
        XCTAssertThrowsError(try tool.requireVideoStream(taggedMP3))
        XCTAssertThrowsError(try tool.verifyMP3Standard(taggedMP3, qcPolicy: tool.config.deliveryAudioQCPolicy))
    }

    func testFadeOutProducesTruncatedSameFormatAudioOutput() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])

        let source = try workspace.createMP3WithArtwork(name: "fade_song", duration: 3.0)
        let tool = try workspace.makeTool(arguments: ["-fadeout", "1.5", "0.75"])
        let spec = try tool.cli.fadeOutSpec()

        try tool.stepFadeOut()

        let output = workspace.output.appendingPathComponent("fade_song_faded.mp3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        try tool.verifyMP3Standard(output, qcPolicy: tool.config.deliveryAudioQCPolicy)
        XCTAssertThrowsError(try tool.requireVideoStream(output))
        try tool.verifyDuration(output, expectedSeconds: spec.endSeconds, label: "fadeout output")
        try tool.verifyDuration(source, expectedSeconds: 3.0, label: "source duration", tolerance: 0.25)
    }

    func testFadeOutRejectsRangeBeyondSourceDuration() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        _ = try workspace.createAudio(name: "short_song", ext: "wav", duration: 1.2)
        let tool = try workspace.makeTool(arguments: ["-fadeout", "1.0", "1.0"])

        XCTAssertThrowsError(try tool.stepFadeOut()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Fade end"))
        }
    }

    func testFadeOutDoesNotEnforceDeliveryQCPolicy() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig + "\nAUDIO_QC_MAX_TRUE_PEAK_DBTP=-1\n"
        )

        _ = try workspace.createHotMP3WithArtwork(name: "hot_fade_song", duration: 3.0, gainDB: 24)
        let tool = try workspace.makeTool(arguments: ["-fadeout", "1.5", "0.75"])
        let spec = try tool.cli.fadeOutSpec()

        XCTAssertNoThrow(try tool.stepFadeOut())

        let output = workspace.output.appendingPathComponent("hot_fade_song_faded.mp3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        try tool.verifyMP3Standard(output, qcPolicy: nil)
        XCTAssertThrowsError(try tool.requireVideoStream(output))
        try tool.verifyDuration(output, expectedSeconds: spec.endSeconds, label: "fadeout output")
    }

    func testTailFadeProcessesMP3WAVAndFLACWithoutTruncating() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let mp3 = try workspace.createAudio(name: "tail_mp3", ext: "mp3", duration: 2.0)
        let wav = try workspace.createAudio(name: "tail_wav", ext: "wav", duration: 2.0)
        let flac = try workspace.createAudio(name: "tail_flac", ext: "flac", duration: 2.0)
        let tool = try workspace.makeTool(arguments: ["-fade", "0.5"])

        try tool.stepFade()

        let mp3Out = workspace.output.appendingPathComponent("tail_mp3_faded.mp3")
        let wavOut = workspace.output.appendingPathComponent("tail_wav_faded.wav")
        let flacOut = workspace.output.appendingPathComponent("tail_flac_faded.flac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp3Out.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavOut.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: flacOut.path))
        try tool.verifyTailFadeOutput(mp3Out, sourceExtension: "mp3", expectedDuration: try XCTUnwrap(try tool.mediaDuration(mp3)))
        try tool.verifyTailFadeOutput(wavOut, sourceExtension: "wav", expectedDuration: try XCTUnwrap(try tool.mediaDuration(wav)))
        try tool.verifyTailFadeOutput(flacOut, sourceExtension: "flac", expectedDuration: try XCTUnwrap(try tool.mediaDuration(flac)))
        XCTAssertThrowsError(try tool.requireVideoStream(mp3Out))
        XCTAssertThrowsError(try tool.requireVideoStream(wavOut))
        XCTAssertThrowsError(try tool.requireVideoStream(flacOut))
    }

    func testFadeCutProcessesMP3WAVAndFLACWithShortenedDuration() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let mp3 = try workspace.createAudio(name: "cut_mp3", ext: "mp3", duration: 3.0)
        let wav = try workspace.createAudio(name: "cut_wav", ext: "wav", duration: 3.0)
        let flac = try workspace.createAudio(name: "cut_flac", ext: "flac", duration: 3.0)
        let tool = try workspace.makeTool(arguments: ["-fadecut", "0.5", "0.75"])

        try tool.stepFadeCut()

        let mp3Out = workspace.output.appendingPathComponent("cut_mp3_fadecut.mp3")
        let wavOut = workspace.output.appendingPathComponent("cut_wav_fadecut.wav")
        let flacOut = workspace.output.appendingPathComponent("cut_flac_fadecut.flac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp3Out.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavOut.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: flacOut.path))
        try tool.verifyTailFadeOutput(mp3Out, sourceExtension: "mp3", expectedDuration: try XCTUnwrap(try tool.mediaDuration(mp3)) - 0.5)
        try tool.verifyTailFadeOutput(wavOut, sourceExtension: "wav", expectedDuration: try XCTUnwrap(try tool.mediaDuration(wav)) - 0.5)
        try tool.verifyTailFadeOutput(flacOut, sourceExtension: "flac", expectedDuration: try XCTUnwrap(try tool.mediaDuration(flac)) - 0.5)
        XCTAssertThrowsError(try tool.requireVideoStream(mp3Out))
        XCTAssertThrowsError(try tool.requireVideoStream(wavOut))
        XCTAssertThrowsError(try tool.requireVideoStream(flacOut))
    }

    func testFadeCutRejectsCutThatRemovesEntireSource() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        _ = try workspace.createAudio(name: "too_short", ext: "wav", duration: 1.0)
        let tool = try workspace.makeTool(arguments: ["-fadecut", "2", "0.5"])

        XCTAssertThrowsError(try tool.stepFadeCut()) { error in
            XCTAssertTrue(error.localizedDescription.contains("would remove the entire audio file"))
        }
    }

    func testMP3ToShortPreparesHighQualityIntermediatesAndBuildsShort() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig +
                "\nMP3_BITRATE=320k\n" +
                "MP3_MIN_BITRATE_BPS=300000\n" +
                "M4A_BITRATE=384k\n"
        )

        _ = try workspace.createImage(name: "poster", ext: "png", width: 320, height: 180)
        let sourceMP3 = try workspace.createMP3WithArtwork(name: "song", duration: 2.4)
        try? FileManager.default.removeItem(at: workspace.output.appendingPathComponent("song_cover.png"))
        let tool = try workspace.makeTool(arguments: ["-mp3toshort"])

        try tool.stepMP3ToShort()

        let preparedMP3 = workspace.output.appendingPathComponent("song.mp3")
        let preparedM4A = workspace.output.appendingPathComponent("song.m4a")
        let eightK = workspace.output.appendingPathComponent("poster_8K.png")
        let mainVideo = workspace.output.appendingPathComponent("song_8K.mp4")
        let shortVideo = workspace.output.appendingPathComponent("song_8K_Short.mp4")

        XCTAssertTrue(FileManager.default.fileExists(atPath: preparedMP3.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preparedM4A.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: eightK.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mainVideo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortVideo.path))

        XCTAssertGreaterThanOrEqual(try tool.audioBitrateBps(preparedMP3), 300_000)
        try tool.verifyMP3Standard(preparedMP3, qcPolicy: nil)
        try tool.verifyM4AFile(preparedM4A, sampleRate: tool.config.m4aSampleRate, channels: tool.config.m4aChannels, qcPolicy: nil)
        try tool.verifyVideoOutput(
            shortVideo,
            width: tool.config.shortMP4ScaleW,
            height: tool.config.shortMP4ScaleH,
            codec: tool.config.shortMP4VerifyCodec,
            pixelFormat: tool.config.shortMP4PixelFormat,
            colorPrimaries: tool.config.videoColorPrimaries,
            colorTransfer: tool.config.videoColorTransfer,
            colorSpace: tool.config.videoColorSpace,
            colorRange: tool.config.videoColorRange
        )
        XCTAssertThrowsError(try tool.requireVideoStream(preparedMP3))
        XCTAssertThrowsError(try tool.requireVideoStream(preparedM4A))
        XCTAssertNoThrow(try tool.requireVideoStream(mainVideo))
        XCTAssertNoThrow(try tool.requireVideoStream(shortVideo))
        try tool.verifyDuration(shortVideo, expectedSeconds: 1.0, label: "short mp4")
        XCTAssertEqual(sourceMP3.lastPathComponent, "song.mp3")
    }

    func testMP3ToShortAcceptsPortrait8KPNGWithoutLandscapeMainRender() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig +
                "\nMP3_BITRATE=320k\n" +
                "MP3_MIN_BITRATE_BPS=300000\n" +
                "M4A_BITRATE=384k\n"
        )

        _ = try workspace.createImage(
            name: "Vertical_8K",
            ext: "png",
            width: 90,
            height: 160
        )
        let sourceMP3 = try workspace.createMP3WithArtwork(name: "song", duration: 2.4)
        try? FileManager.default.removeItem(at: workspace.output.appendingPathComponent("song_cover.png"))
        let tool = try workspace.makeTool(arguments: ["-mp3toshort"])

        try tool.stepMP3ToShort()

        let preparedMP3 = workspace.output.appendingPathComponent("song.mp3")
        let preparedM4A = workspace.output.appendingPathComponent("song.m4a")
        let portraitImage = workspace.output.appendingPathComponent("Vertical_8K.png")
        let mainVideo = workspace.output.appendingPathComponent("song_8K.mp4")
        let shortVideo = workspace.output.appendingPathComponent("song_8K_Short.mp4")

        XCTAssertTrue(FileManager.default.fileExists(atPath: preparedMP3.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preparedM4A.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: portraitImage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mainVideo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortVideo.path))

        XCTAssertGreaterThanOrEqual(try tool.audioBitrateBps(preparedMP3), 300_000)
        try tool.verifyMP3Standard(preparedMP3, qcPolicy: nil)
        try tool.verifyM4AFile(preparedM4A, sampleRate: tool.config.m4aSampleRate, channels: tool.config.m4aChannels, qcPolicy: nil)
        try tool.verifyVideoOutput(
            shortVideo,
            width: tool.config.shortMP4ScaleW,
            height: tool.config.shortMP4ScaleH,
            codec: tool.config.shortMP4VerifyCodec,
            pixelFormat: tool.config.shortMP4PixelFormat,
            colorPrimaries: tool.config.videoColorPrimaries,
            colorTransfer: tool.config.videoColorTransfer,
            colorSpace: tool.config.videoColorSpace,
            colorRange: tool.config.videoColorRange
        )
        XCTAssertThrowsError(try tool.requireVideoStream(preparedMP3))
        XCTAssertThrowsError(try tool.requireVideoStream(preparedM4A))
        XCTAssertNoThrow(try tool.requireVideoStream(shortVideo))
        try tool.verifyDuration(shortVideo, expectedSeconds: 1.0, label: "portrait short mp4")
        XCTAssertEqual(sourceMP3.lastPathComponent, "song.mp3")
    }

    func testMP3ToShortPreservesSourceLoudnessOnLandscapePath() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig +
                "\nMP3_BITRATE=320k\n" +
                "MP3_MIN_BITRATE_BPS=300000\n" +
                "M4A_BITRATE=384k\n"
        )

        _ = try workspace.createImage(name: "poster", ext: "png", width: 320, height: 180)
        let sourceMP3 = try workspace.createMP3WithArtwork(name: "loud_song", duration: 6.0)
        try? FileManager.default.removeItem(at: workspace.output.appendingPathComponent("loud_song_cover.png"))
        let tool = try workspace.makeTool(arguments: ["-mp3toshort"])

        try tool.stepMP3ToShort()

        let shortVideo = workspace.output.appendingPathComponent("loud_song_8K_Short.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortVideo.path))
        try tool.verifySourceLoudnessPreserved(source: sourceMP3, output: shortVideo)
    }

    func testMP3ToShortPreservesSourceLoudnessOnPortraitPath() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig +
                "\nAUDIO_QC_MAX_TRUE_PEAK_DBTP=-1\n" +
                "MP3_BITRATE=320k\n" +
                "MP3_MIN_BITRATE_BPS=300000\n" +
                "M4A_BITRATE=384k\n"
        )

        _ = try workspace.createImage(name: "Vertical_8K", ext: "png", width: 90, height: 160)
        let sourceMP3 = try workspace.createHotMP3WithArtwork(name: "hot_song", duration: 6.0, gainDB: 24)
        try? FileManager.default.removeItem(at: workspace.output.appendingPathComponent("hot_song_cover.png"))
        let tool = try workspace.makeTool(arguments: ["-mp3toshort"])

        XCTAssertNoThrow(try tool.stepMP3ToShort())

        let preparedM4A = workspace.output.appendingPathComponent("hot_song.m4a")
        let shortVideo = workspace.output.appendingPathComponent("hot_song_8K_Short.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preparedM4A.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortVideo.path))
        try tool.verifyM4AFile(
            preparedM4A,
            sampleRate: tool.config.m4aSampleRate,
            channels: tool.config.m4aChannels,
            qcPolicy: nil
        )
        try tool.verifyVideoOutput(
            shortVideo,
            width: tool.config.shortMP4ScaleW,
            height: tool.config.shortMP4ScaleH,
            codec: tool.config.shortMP4VerifyCodec,
            pixelFormat: tool.config.shortMP4PixelFormat,
            colorPrimaries: tool.config.videoColorPrimaries,
            colorTransfer: tool.config.videoColorTransfer,
            colorSpace: tool.config.videoColorSpace,
            colorRange: tool.config.videoColorRange
        )
        try tool.verifySourceLoudnessPreserved(source: sourceMP3, output: shortVideo)
    }

    func testMP3ToShortComparesAgainstTrimmedSourceSegmentLoudness() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig +
                "\nSHORT_MP4_CLIP_SECONDS=1\n" +
                "MP3_BITRATE=320k\n" +
                "MP3_MIN_BITRATE_BPS=300000\n" +
                "M4A_BITRATE=384k\n"
        )

        _ = try workspace.createImage(name: "poster", ext: "png", width: 320, height: 180)
        let sourceMP3 = workspace.output.appendingPathComponent("dynamic_loudness.mp3")
        _ = try workspace.runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi",
            "-i", "sine=frequency=440:duration=2.0:sample_rate=48000",
            "-ac", "2",
            "-af", "volume='if(lt(t,1),1,0.1)':eval=frame",
            "-c:a", "libmp3lame",
            "-b:a", "320k",
            "-ar", "48000",
            sourceMP3.path
        ])

        let tool = try workspace.makeTool(arguments: ["-mp3toshort"])
        try tool.stepMP3ToShort()

        let shortVideo = workspace.output.appendingPathComponent("dynamic_loudness_8K_Short.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortVideo.path))
        try tool.verifySourceLoudnessPreserved(source: sourceMP3, output: shortVideo)
    }

    func testMP3HashAcceptsArtworkAndNonProjectBitrateMP3() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig + "\nMP3_MIN_BITRATE_BPS=300000\n"
        )

        let taggedMP3 = try workspace.createMP3WithArtwork(name: "hash_artwork_track")
        let tool = try workspace.makeTool(arguments: ["-mp3tohash"])
        let expectedHash = try tool.crc32(for: taggedMP3)

        XCTAssertNoThrow(try tool.requireVideoStream(taggedMP3), "Fixture should contain attached artwork before hashing.")
        XCTAssertNoThrow(try tool.stepMP3Hash())

        let hashed = workspace.output.appendingPathComponent(expectedHash).appendingPathExtension("mp3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hashed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: taggedMP3.path))
        XCTAssertNoThrow(try tool.requireVideoStream(hashed))
    }

    func testFLACHashRenamesToCRC32Filename() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let flac = try workspace.createAudio(name: "hash_source", ext: "flac")
        let tool = try workspace.makeTool(arguments: ["-flactohash"])
        let expectedHash = try tool.crc32(for: flac)

        try tool.stepFLACHash()

        let hashed = workspace.output.appendingPathComponent(expectedHash).appendingPathExtension("flac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hashed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: flac.path))
        try tool.preflightFLACInput(hashed)
    }

    func testAcceptsLeadingSilenceWhenAudioBecomesAudibleLater() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let delayed = workspace.output.appendingPathComponent("leadingsilence.mp3")
        _ = try workspace.runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi",
            "-i", "sine=frequency=440:duration=1.0:sample_rate=48000",
            "-af", "adelay=3000|3000",
            "-ac", "2",
            "-c:a", "libmp3lame",
            "-b:a", "192k",
            delayed.path
        ])

        let tool = try workspace.makeTool(arguments: ["-mp3towav"])
        let wav = try tool.convertMP3ToWAV(delayed)
        try tool.verifyWAVStandard(wav)
    }

    func testRejectsStereoImbalancedOutputWhenPolicyIsStrict() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig + "\nAUDIO_QC_MAX_STEREO_IMBALANCE_DB=0.10\n"
        )
        let input = try workspace.createStereoImbalancedAudio(name: "imbalanced", ext: "wav")
        let tool = try workspace.makeTool(arguments: ["-wavtom4a"])

        let output = try tool.convertWAVToM4A(input)
        XCTAssertThrowsError(try tool.verifyAudioQC(output, policy: tool.config.deliveryAudioQCPolicy)) { error in
            XCTAssertTrue(error.localizedDescription.contains("stereo imbalance"))
        }
    }

    func testWAVToM4AAcceptsNonStandardRIFFInput() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let riff = try workspace.createPlainRIFFWAV(name: "plain_input")
        let tool = try workspace.makeTool(arguments: ["-wavtom4a"])
        let output = try tool.convertWAVToM4A(riff)

        try tool.verifyM4AFile(output, sampleRate: tool.config.m4aSampleRate, channels: tool.config.m4aChannels, qcPolicy: nil)
        try tool.verifyDurationMatch(source: riff, output: output)
        try tool.verifySourceLoudnessPreserved(source: riff, output: output)
    }

    func testAlbumBuildAcceptsNonStandardRIFFWavInputs() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        _ = try workspace.createPlainRIFFWAV(name: "track01", frequency: 440)
        _ = try workspace.createPlainRIFFWAV(name: "track02", frequency: 554)
        try workspace.writeAlbum(["track01", "track02"])

        let tool = try workspace.makeTool(arguments: ["-wavtoalbum"])
        let album = try tool.buildAlbumFromAlbumFile(extension: "wav", defaultOutputName: "album.rf64.wav")
        try tool.verifyWAVStandard(album)
    }

    func testWAVHashAcceptsNonStandardRIFFInput() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let riff = try workspace.createPlainRIFFWAV(name: "plain_hash")
        let tool = try workspace.makeTool(arguments: ["-wavtohash"])
        let expectedHash = try tool.crc32(for: riff)

        try tool.stepWAVHash()

        let hashed = workspace.output.appendingPathComponent(expectedHash).appendingPathExtension("wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hashed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: riff.path))
        XCTAssertEqual(try tool.crc32(for: hashed), expectedHash)
        try tool.preflightWAVInput(hashed)
    }

    func testUnifiedHashRenamesWAVFLACMP3AndMP4Together() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])

        let wav = try workspace.createPlainRIFFWAV(name: "mix_wave")
        let flac = try workspace.createAudio(name: "mix_flac", ext: "flac")
        let mp3 = try workspace.createMP3WithArtwork(name: "mix_mp3")
        let mp4 = try workspace.createVideoMP4(name: "mix_video", duration: 1.2)
        let tool = try workspace.makeTool(arguments: ["--hash"])

        let wavHash = try tool.crc32(for: wav)
        let flacHash = try tool.crc32(for: flac)
        let mp3Hash = try tool.crc32(for: mp3)
        let mp4Hash = try tool.crc32(for: mp4)

        try tool.stepUnifiedHash()

        let hashedWAV = workspace.output.appendingPathComponent(wavHash).appendingPathExtension("wav")
        let hashedFLAC = workspace.output.appendingPathComponent(flacHash).appendingPathExtension("flac")
        let hashedMP3 = workspace.output.appendingPathComponent(mp3Hash).appendingPathExtension("mp3")
        let hashedMP4 = workspace.output.appendingPathComponent(mp4Hash).appendingPathExtension("mp4")

        XCTAssertTrue(FileManager.default.fileExists(atPath: hashedWAV.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hashedFLAC.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hashedMP3.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hashedMP4.path))

        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: flac.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mp3.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mp4.path))

        try tool.preflightWAVInput(hashedWAV)
        try tool.preflightFLACInput(hashedFLAC)
        XCTAssertNoThrow(try tool.requireVideoStream(hashedMP3))
        try tool.preflightMP4Input(hashedMP4)
    }

    func testUnifiedHashIgnoresNestedDirectories() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let nested = workspace.output.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let wav = nested.appendingPathComponent("deep.wav")
        _ = try workspace.runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi",
            "-i", "sine=frequency=440:duration=1.0:sample_rate=44100",
            "-ac", "2",
            "-c:a", "pcm_s16le",
            wav.path
        ])

        let tool = try workspace.makeTool(arguments: ["--hash"])
        let expectedHash = try tool.crc32(for: wav)

        try tool.stepUnifiedHash()

        let hashed = workspace.output.appendingPathComponent(expectedHash).appendingPathExtension("wav")
        XCTAssertFalse(FileManager.default.fileExists(atPath: hashed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
    }

    func testFullAudioPreparationPreservesOriginalWAVForExternalFLACVariants() async throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let riff = try workspace.createPlainRIFFWAV(name: "wav_source", sampleRate: 44_100)
        let reference = try workspace.copy(riff, as: "wav_source_reference", ext: "wav")
        let tool = try workspace.makeTool()

        let artifacts = try await tool.fullAudioPreparation(sourceAudio: riff)

        XCTAssertEqual(try tool.audioField(artifacts.wav, "sample_rate"), String(tool.config.wavSampleRate))

        let rf64FLAC = workspace.output.appendingPathComponent("wav_source_RF64.flac")
        let bw64FLAC = workspace.output.appendingPathComponent("wav_source_BW64.flac")
        XCTAssertEqual(try tool.audioField(rf64FLAC, "sample_rate"), "44100")
        XCTAssertEqual(try tool.audioField(bw64FLAC, "sample_rate"), "44100")
        try tool.verifyCanonicalPCMSampleEquivalence(source: reference, output: rf64FLAC, sampleRate: 44_100, channels: 2, label: "External FLAC", format: .s24le)
        try tool.verifyCanonicalPCMSampleEquivalence(source: reference, output: bw64FLAC, sampleRate: 44_100, channels: 2, label: "External FLAC", format: .s24le)
    }

    func testFullAudioPreparationPreservesMP3SourceLoudnessEvenIfMasteringConfigIsEnabled() async throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig +
                "\nMASTERING_TARGET_LUFS=-28\n"
        )

        let mp3 = try workspace.createAudio(name: "master_me", ext: "mp3", duration: 4.5)
        let tool = try workspace.makeTool(arguments: ["-full"])
        let originalCRC = try tool.crc32(for: mp3)

        let artifacts = try await tool.fullAudioPreparation(sourceAudio: mp3)
        let rebuiltMP3 = try XCTUnwrap(artifacts.mp3)
        let rebuiltCRC = try tool.crc32(for: rebuiltMP3)

        XCTAssertEqual(rebuiltCRC, originalCRC, "Full audio preparation should preserve the source MP3 when it already matches project standard.")
        try tool.verifyMP3Standard(rebuiltMP3, qcPolicy: nil)
        try tool.verifySourceLoudnessPreserved(source: mp3, output: rebuiltMP3)
    }

    func testDerivedImageNamingOnlyReplacesTrailing8KMarker() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["magick"])

        let source = try workspace.createImage(
            name: "mix_8K_take_8K",
            ext: "png",
            width: 320,
            height: 180
        )
        let tool = try workspace.makeTool(arguments: ["-pngto3k"])

        let square = try tool.squarePNGFrom8K(source, size: tool.config.image3KSize, label: "3K")
        let nft = try tool.nftFrom8K(source)

        XCTAssertEqual(square.lastPathComponent, "mix_8K_take_3K.png")
        XCTAssertEqual(nft.nft8K.lastPathComponent, "mix_8K_take_NFT8K.png")
        XCTAssertEqual(nft.nft3K.lastPathComponent, "mix_8K_take_NFT3K.png")
        XCTAssertEqual(nft.nft2K.lastPathComponent, "mix_8K_take_NFT2K.png")
    }

    func testAIPixPreservesFullStemToAvoidUnderscoreCollisions() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["magick"])

        _ = try workspace.createImage(name: "art_1", ext: "png")
        _ = try workspace.createImage(name: "art_2", ext: "png")

        let tool = try workspace.makeTool(arguments: ["-aipix"])
        try tool.stepAIPix()

        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("art_1_8K.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("art_2_8K.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("art_8K.png").path))
    }

    func testVisualSubsCreatesVerifiedPNGViaPublishedOutput() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["magick"])

        let tool = try workspace.makeTool(arguments: ["-visualsubs", "128", "--output-file", "dots.png"])
        let output = try tool.visualSubs()
        try tool.verifyImageOutput(output, width: tool.config.image8KWidth, height: tool.config.image8KHeight, format: "PNG")
        let outputs = try FileManager.default.contentsOfDirectory(at: workspace.output, includingPropertiesForKeys: nil, options: [])
        XCTAssertFalse(outputs.contains { $0.lastPathComponent.contains(tool.runToken) })
    }

    func testVisualSubsReservesCenterMarkerAgainstRandomDots() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["magick"])

        let tool = try workspace.makeTool(arguments: ["-visualsubs", "1", "--seed", "976", "--output-file", "center_guard.png"])
        let output = try tool.visualSubs()
        let centerPixel = try workspace.runner().run("magick", [
            output.path,
            "-format", "%[hex:p{160,90}]",
            "info:"
        ]).stdout.trimmed

        XCTAssertEqual(centerPixel.uppercased(), "FFFF00000000")
    }

    func testCanonicalPCMVerifierRejectsMismatchedLosslessOutput() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let source = try workspace.createAudio(name: "source", ext: "wav", frequency: 440)
        let mismatched = try workspace.createAudio(name: "different_take", ext: "flac", frequency: 554)
        let tool = try workspace.makeTool(arguments: ["-wavtoflac"])

        XCTAssertThrowsError(
            try tool.verifyCanonicalPCMSampleEquivalence(
                source: source,
                output: mismatched,
                sampleRate: tool.config.flacSampleRate,
                channels: tool.config.flacChannels,
                label: "FLAC output",
                format: .s24le
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Canonical PCM mismatch"))
        }
    }

    func testProbeCacheInvalidatesWhenFileFingerprintChanges() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let file = try workspace.createAudio(name: "cache_probe", ext: "wav", duration: 1.2, frequency: 440)
        let tool = try workspace.makeTool(arguments: ["-wavtom4a"])
        let firstDuration = try XCTUnwrap(tool.mediaDuration(file))

        _ = try workspace.createAudio(name: "cache_probe", ext: "wav", duration: 2.4, frequency: 554)
        let secondDuration = try XCTUnwrap(tool.mediaDuration(file))

        XCTAssertNotEqual(firstDuration, secondDuration)
        XCTAssertGreaterThan(secondDuration, firstDuration)
    }

    func testExistingExternalFLACIsRebuiltWhenCanonicalPCMDoesNotMatchSource() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let source = try workspace.createAudio(name: "archive_source", ext: "wav", frequency: 440)
        let wrong = try workspace.createAudio(name: "wrong_take", ext: "wav", frequency: 659)
        let output = workspace.output.appendingPathComponent("archive_source_RF64.flac")
        _ = try workspace.runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-i", wrong.path,
            "-map", "0:a:0",
            "-c:a", "flac",
            output.path
        ])

        let tool = try workspace.makeTool(arguments: ["-wavtoflac"])
        let rebuilt = try tool.createExternalFLACVariant(source: source, output: output)
        XCTAssertEqual(rebuilt.standardizedFileURL, output.standardizedFileURL)
        try tool.verifyFLACFile(rebuilt, qcPolicy: nil)
        try tool.verifyCanonicalPCMSampleEquivalence(source: source, output: rebuilt, label: "External FLAC", format: .s24le)
    }

    func testFullPipelineProducesExpectedOutputsAndLeavesNoScopedTemps() async throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])

        _ = try workspace.createImage(name: "art", ext: "png")
        let sourceMP3 = try workspace.createAudio(name: "track", ext: "mp3")
        let sourceMP3Reference = workspace.root.appendingPathComponent("track_source_reference.mp3")
        try FileManager.default.copyItem(at: sourceMP3, to: sourceMP3Reference)
        try Data("foreign-temp".utf8).write(to: workspace.output.appendingPathComponent(".converter-tmp.foreign.decoy.mp3"))
        try Data("foreign-temp".utf8).write(to: workspace.output.appendingPathComponent(".converter-tmp.foreign.decoy.png"))

        let tool = try workspace.makeTool()
        defer { tool.cleanupTemps() }
        try tool.initializeForExecution()
        try await tool.stepFull()

        let visibleOutputs = try FileManager.default.contentsOfDirectory(at: workspace.output, includingPropertiesForKeys: [.isRegularFileKey], options: [])
        XCTAssertFalse(visibleOutputs.contains { $0.lastPathComponent.contains(tool.runToken) }, "Run-scoped temp files leaked into Output.")

        let prefix = "art"
        let base = "track"
        let expectedFiles = [
            "\(prefix)_8K.png",
            "\(prefix)_4K.png",
            "\(prefix)_3K.png",
            "\(prefix)_2K.png",
            "\(prefix)_NFT8K.png",
            "\(prefix)_NFT3K.png",
            "\(prefix)_NFT2K.png",
            "\(base).wav",
            "\(base).m4a",
            "\(base).mp3",
            "\(base)_RF64.wav",
            "\(base)_BW64.wav",
            "\(base)_RF64.flac",
            "\(base)_BW64.flac",
            "\(base)_8K.mp4",
            "\(base)_8K_Short.mp4"
        ]

        for name in expectedFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent(name).path), "Missing full-run output \(name)")
        }

        let wavOutput = workspace.output.appendingPathComponent("\(base).wav")
        let m4aOutput = workspace.output.appendingPathComponent("\(base).m4a")
        let mp3Output = workspace.output.appendingPathComponent("\(base).mp3")
        let mp4Output = workspace.output.appendingPathComponent("\(base)_8K.mp4")
        let shortOutput = workspace.output.appendingPathComponent("\(base)_8K_Short.mp4")
        try tool.verifyWAVStandard(wavOutput, qcPolicy: nil)
        try tool.verifyAudioOutput(m4aOutput, codec: "aac", sampleRate: tool.config.m4aSampleRate, channels: tool.config.m4aChannels, qcPolicy: nil)
        try tool.verifyMP3Standard(mp3Output, qcPolicy: nil)
        try tool.verifySourceLoudnessPreserved(source: sourceMP3Reference, output: wavOutput)
        try tool.verifySourceLoudnessPreserved(source: sourceMP3Reference, output: m4aOutput)
        try tool.verifySourceLoudnessPreserved(source: sourceMP3Reference, output: mp3Output)
        try tool.verifySourceLoudnessPreserved(source: sourceMP3Reference, output: mp4Output)
        try tool.verifySourceLoudnessPreserved(source: sourceMP3Reference, output: shortOutput)
        try tool.verifyCanonicalPCMSampleEquivalence(
            source: workspace.output.appendingPathComponent("\(base).wav"),
            output: workspace.output.appendingPathComponent("\(base)_RF64.flac"),
            label: "External FLAC",
            format: .s24le
        )
        try tool.verifyCanonicalPCMSampleEquivalence(
            source: workspace.output.appendingPathComponent("\(base).wav"),
            output: workspace.output.appendingPathComponent("\(base)_BW64.flac"),
            label: "External FLAC",
            format: .s24le
        )
        try tool.verifyExternalWAVVariant(workspace.output.appendingPathComponent("\(base)_RF64.wav"), source: workspace.output.appendingPathComponent("\(base).wav"), expectBext: false)
        try tool.verifyBW64WAVVariant(workspace.output.appendingPathComponent("\(base)_BW64.wav"), source: workspace.output.appendingPathComponent("\(base).wav"))
        try tool.verifyVideoOutput(
            mp4Output,
            width: tool.config.videoMP4Width,
            height: tool.config.videoMP4Height,
            codec: tool.config.videoMP4VerifyCodec,
            pixelFormat: tool.config.videoMP4PixelFormat,
            colorPrimaries: tool.config.videoColorPrimaries,
            colorTransfer: tool.config.videoColorTransfer,
            colorSpace: tool.config.videoColorSpace,
            colorRange: tool.config.videoColorRange
        )
        try tool.verifyVideoOutput(
            shortOutput,
            width: tool.config.shortMP4ScaleW,
            height: tool.config.shortMP4ScaleH,
            codec: tool.config.shortMP4VerifyCodec,
            pixelFormat: tool.config.shortMP4PixelFormat,
            colorPrimaries: tool.config.videoColorPrimaries,
            colorTransfer: tool.config.videoColorTransfer,
            colorSpace: tool.config.videoColorSpace,
            colorRange: tool.config.videoColorRange
        )
    }

    func testFullPipelineUsesNamedHorizontalAndVertical8KPNGs() async throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])

        _ = try workspace.createImage(name: "Horizontal_8K", ext: "png", width: 320, height: 180)
        _ = try workspace.createImage(name: "Vertical_8K", ext: "png", width: 90, height: 160)
        let sourceFLAC = try workspace.createAudio(name: "463406_B_PH", ext: "flac")

        let tool = try workspace.makeTool()
        defer { tool.cleanupTemps() }
        try tool.initializeForExecution()
        try await tool.stepFull()

        let base = sourceFLAC.stem
        let mainOutput = workspace.output.appendingPathComponent("\(base)_8K").appendingPathExtension("mp4")
        let shortOutput = workspace.output.appendingPathComponent("\(base)_8K_Short").appendingPathExtension("mp4")

        XCTAssertTrue(FileManager.default.fileExists(atPath: mainOutput.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortOutput.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("Horizontal_8K_8K.png").path),
            "Direct Horizontal_8K.png input should not be reprocessed as a generic source image."
        )
        try tool.verifyVideoOutput(
            mainOutput,
            width: tool.config.videoMP4Width,
            height: tool.config.videoMP4Height,
            codec: tool.config.videoMP4VerifyCodec,
            pixelFormat: tool.config.videoMP4PixelFormat,
            colorPrimaries: tool.config.videoColorPrimaries,
            colorTransfer: tool.config.videoColorTransfer,
            colorSpace: tool.config.videoColorSpace,
            colorRange: tool.config.videoColorRange
        )
        try tool.verifyVideoOutput(
            shortOutput,
            width: tool.config.shortMP4ScaleW,
            height: tool.config.shortMP4ScaleH,
            codec: tool.config.shortMP4VerifyCodec,
            pixelFormat: tool.config.shortMP4PixelFormat,
            colorPrimaries: tool.config.videoColorPrimaries,
            colorTransfer: tool.config.videoColorTransfer,
            colorSpace: tool.config.videoColorSpace,
            colorRange: tool.config.videoColorRange
        )
        try tool.verifySourceLoudnessPreserved(source: sourceFLAC, output: mainOutput)
        try tool.verifySourceLoudnessPreserved(source: sourceFLAC, output: shortOutput)
    }

    func testAlbumBuildFromAlbumFileCreatesVerifiedRF64Wave() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        _ = try workspace.createAudio(name: "track01", ext: "wav")
        _ = try workspace.createAudio(name: "track02", ext: "wav", frequency: 554)
        try workspace.writeAlbum(["track01", "track02"])

        let tool = try workspace.makeTool(arguments: ["-wavtoalbum"])
        let album = try tool.buildAlbumFromAlbumFile(extension: "wav", defaultOutputName: "album.rf64.wav")
        try tool.verifyWAVStandard(album)
        XCTAssertEqual(album.lastPathComponent, "album.rf64.wav")
    }

    func testSchedulerRespectsResourceClassLimits() async throws {
        let workspace = try IntegrationWorkspace()
        let tool = try workspace.makeTool(arguments: ["-wavtom4a"])
        let counter = ConcurrencyCounter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    try await tool.withImagePermit {
                        counter.enter(.image)
                        defer { counter.leave(.image) }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                }
            }
            for _ in 0 ..< 8 {
                group.addTask {
                    try await tool.withAudioPermit {
                        counter.enter(.audio)
                        defer { counter.leave(.audio) }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                }
            }
            for _ in 0 ..< 4 {
                group.addTask {
                    try await tool.withVideoPermit {
                        counter.enter(.video)
                        defer { counter.leave(.video) }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                }
            }
            try await group.waitForAll()
        }

        XCTAssertLessThanOrEqual(counter.peak(.image), tool.schedulerProfile.image)
        XCTAssertLessThanOrEqual(counter.peak(.audio), tool.schedulerProfile.audio)
        XCTAssertLessThanOrEqual(counter.peak(.video), tool.schedulerProfile.video)
        XCTAssertLessThanOrEqual(counter.peakTotalCount(), tool.schedulerProfile.total)
    }

    func testDoctorPassesOnHealthyWorkspace() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])
        _ = try workspace.createImage(name: "poster", ext: "png")
        _ = try workspace.createAudio(name: "song", ext: "mp3")

        let tool = try workspace.makeTool(arguments: ["-doctor"])
        XCTAssertNoThrow(try tool.initializeForExecution())
        XCTAssertNoThrow(try tool.stepDoctor())
    }

    func testMasterCanonicalWAVRemediatesOutOfPolicyLoudness() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig +
                "\nMASTERING_ENABLED=1\n" +
                "\nMASTERING_TARGET_LUFS=-40\n"
        )
        let wav = try workspace.createAudio(name: "needs_master", ext: "wav", duration: 4.5)
        let tool = try workspace.makeTool(arguments: ["-wavtom4a"])

        let before = try tool.audioQCResult(for: wav, policy: tool.config.masteringAudioQCPolicy)
        XCTAssertFalse(before.passed, "Fixture should start out of mastering policy so remediation is exercised.")

        try tool.masterCanonicalWAVInPlaceIfNeeded(wav)

        XCTAssertNoThrow(try tool.verifyWAVStandard(wav, qcPolicy: tool.config.masteringAudioQCPolicy))
        let after = try tool.audioQCResult(for: wav, policy: tool.config.masteringAudioQCPolicy)
        XCTAssertTrue(after.passed)
    }

    func testMasterCanonicalWAVFallsBackWhenTwoPassMeasurementIsOutOfRange() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig +
                "\nMASTERING_ENABLED=1\n"
        )
        let wav = try workspace.createHotAudio(name: "too_hot", ext: "wav", duration: 3.0, gainDB: 24)
        let tool = try workspace.makeTool(arguments: ["-wavtom4a"])

        let before = try tool.audioQCResult(for: wav, policy: tool.config.masteringAudioQCPolicy)
        XCTAssertFalse(before.passed, "Hot fixture should force mastering fallback.")

        XCTAssertNoThrow(try tool.masterCanonicalWAVInPlaceIfNeeded(wav))
        XCTAssertNoThrow(try tool.verifyWAVStandard(wav, qcPolicy: tool.config.masteringAudioQCPolicy))
    }

    func testMainVideoRenderFallsBackToSoftwareEncoder() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig +
                "\nVIDEO_MP4_ENCODER=definitely_missing_encoder\n" +
                "VIDEO_MP4_ENCODER_FALLBACKS=libx264\n" +
                "VIDEO_MP4_VERIFY_CODEC=h264\n" +
                "VIDEO_MP4_TAG=avc1\n"
        )

        let image = try workspace.createImage(name: "poster", ext: "png")
        let audio = try workspace.createAudio(name: "track", ext: "m4a")
        let tool = try workspace.makeTool(arguments: ["-m4atomp4"])

        let output = try tool.renderM4AToMP4(imageFile: image, audioFile: audio, audioQCPolicy: nil)
        try tool.verifyVideoOutput(
            output,
            width: tool.config.videoMP4Width,
            height: tool.config.videoMP4Height,
            codec: "h264",
            pixelFormat: tool.config.videoMP4PixelFormat,
            colorPrimaries: tool.config.videoColorPrimaries,
            colorTransfer: tool.config.videoColorTransfer,
            colorSpace: tool.config.videoColorSpace,
            colorRange: tool.config.videoColorRange
        )
    }

    func testShortVideoRenderFallsBackToSoftwareEncoder() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig +
                "\nSHORT_MP4_VIDEO_CODEC=definitely_missing_short_encoder\n" +
                "SHORT_MP4_VIDEO_FALLBACKS=libx264\n" +
                "SHORT_MP4_VERIFY_CODEC=h264\n"
        )

        let image = try workspace.createImage(name: "poster", ext: "png")
        let audio = try workspace.createAudio(name: "track", ext: "m4a")
        let tool = try workspace.makeTool(arguments: ["-mp4toshort"])
        let main = try tool.renderM4AToMP4(imageFile: image, audioFile: audio, audioQCPolicy: nil)

        let short = try tool.shortenMP4(main, audioQCPolicy: nil)
        try tool.verifyVideoOutput(
            short,
            width: tool.config.shortMP4ScaleW,
            height: tool.config.shortMP4ScaleH,
            codec: "h264",
            pixelFormat: tool.config.shortMP4PixelFormat,
            colorPrimaries: tool.config.videoColorPrimaries,
            colorTransfer: tool.config.videoColorTransfer,
            colorSpace: tool.config.videoColorSpace,
            colorRange: tool.config.videoColorRange
        )
    }

    func testShortVideoHardCapsAt58SecondsEvenIfConfigRequestsMore() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig +
                "\nSHORT_MP4_CLIP_SECONDS=75\n"
        )

        let source = try workspace.createVideoMP4(name: "long_source", duration: 60.5, width: 320, height: 180)
        let tool = try workspace.makeTool(arguments: ["-mp4toshort"])

        let short = try tool.shortenMP4(source, audioQCPolicy: nil)
        try tool.verifyVideoOutput(
            short,
            width: tool.config.shortMP4ScaleW,
            height: tool.config.shortMP4ScaleH,
            codec: tool.config.shortMP4VerifyCodec,
            pixelFormat: tool.config.shortMP4PixelFormat,
            colorPrimaries: tool.config.videoColorPrimaries,
            colorTransfer: tool.config.videoColorTransfer,
            colorSpace: tool.config.videoColorSpace,
            colorRange: tool.config.videoColorRange
        )
        try tool.verifyDuration(short, expectedSeconds: 58.0, label: "short mp4", tolerance: 0.25)
    }
}
