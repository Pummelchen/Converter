import Foundation
import XCTest
@testable import converter

final class PipelineIntegrationTests: XCTestCase {
    private func filteredMeanVolumeDB(file: URL, filter: String, workspace: IntegrationWorkspace) throws -> Double {
        let result = try workspace.runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "info",
            "-i", file.path,
            "-map", "0:a:0",
            "-af", "\(filter),volumedetect",
            "-f", "null", "-"
        ])
        guard let line = result.stderr.components(separatedBy: .newlines).last(where: { $0.contains("mean_volume:") }),
              let rawValue = line.components(separatedBy: "mean_volume:").last?.trimmed.split(separator: " ").first,
              let value = Double(rawValue)
        else {
            throw AppError("Unable to read filtered mean volume for \(file.path) with filter \(filter)")
        }
        return value
    }

    private func bassToMidRatioDB(file: URL, workspace: IntegrationWorkspace) throws -> Double {
        let lowBand = try filteredMeanVolumeDB(file: file, filter: "lowpass=f=120", workspace: workspace)
        let midBand = try filteredMeanVolumeDB(file: file, filter: "highpass=f=500,lowpass=f=2000", workspace: workspace)
        return lowBand - midBand
    }

    // Large stderr output used to risk pipe-buffer deadlock; this keeps that path under test.
    func testRunHandlesLargeStderrWithoutDeadlock() throws {
        let workspace = try IntegrationWorkspace()
        let runner = workspace.runner()
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = ResultBox<Result<ProcessResult, any Error>>()

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

    // Long media batches launch thousands of probes; pipe handles must close after every child process.
    func testRunHandlesRepeatedLaunchesWithoutPipeHandleExhaustion() throws {
        let workspace = try IntegrationWorkspace()
        let runner = workspace.runner()

        for index in 0 ..< 400 {
            let result = try runner.run("/bin/echo", ["probe-\(index)"])
            XCTAssertEqual(result.stdout.trimmed, "probe-\(index)")
        }
    }

    // A chatty child must not be able to exhaust memory or deadlock the parent: output
    // beyond the capture cap is drained and discarded rather than buffered.
    func testRunDrainsLargeChildOutputWithoutDeadlock() throws {
        let workspace = try IntegrationWorkspace()
        let runner = workspace.runner()

        let result = try runner.run(
            "/bin/sh",
            [
                "-c",
                "i=0; while [ $i -lt 12000 ]; do printf 'payload-%05d\\n' \"$i\"; printf 'noise-%05d\\n' \"$i\" 1>&2; i=$((i+1)); done"
            ],
            timeoutSeconds: 60
        )

        XCTAssertTrue(result.stdout.contains("payload-11999"))
        XCTAssertTrue(result.stderr.contains("noise-11999"))
        XCTAssertEqual(result.exitCode, 0)
    }

    // audit #0034: PipeCapture keeps at most 64 MiB per stream and drains the surplus; the drain
    // test above emits ~168 KB, so the exceededCap branch never ran. This crosses the cap on BOTH
    // streams (70 MB each) and checks the retained prefix is exactly the cap, the surplus is
    // discarded rather than deadlocking the child, and the run finishes in bounded time.
    func testRunCapsCapturedOutputAt64MiBOnBothStreams() throws {
        let workspace = try IntegrationWorkspace()
        let runner = workspace.runner()
        let cap = 64 * 1024 * 1024
        let start = Date()

        let result = try runner.run(
            "/bin/sh",
            ["-c", "head -c 70000000 /dev/zero | tr '\\0' a; head -c 70000000 /dev/zero | tr '\\0' b 1>&2"],
            timeoutSeconds: 240
        )

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 120, "capped capture must not stall on the discarded surplus")
        XCTAssertEqual(result.exitCode, 0)

        XCTAssertEqual(result.stdout.utf8.count, cap, "stdout must be truncated to exactly the cap")
        XCTAssertEqual(result.stdout.utf8.first, UInt8(ascii: "a"))
        XCTAssertEqual(result.stdout.utf8.last, UInt8(ascii: "a"))
        XCTAssertFalse(result.stdout.utf8.contains { $0 != UInt8(ascii: "a") }, "stdout must hold only 'a'")

        XCTAssertEqual(result.stderr.utf8.count, cap, "stderr must be truncated to exactly the cap")
        XCTAssertEqual(result.stderr.utf8.first, UInt8(ascii: "b"))
        XCTAssertEqual(result.stderr.utf8.last, UInt8(ascii: "b"))
        XCTAssertFalse(result.stderr.utf8.contains { $0 != UInt8(ascii: "b") }, "stderr must hold only 'b'")
    }

    // audit #0034: pins the cap boundary. Output landing exactly on 64 MiB is kept in full (an
    // off-by-one would drop the last byte); one byte over is trimmed to the cap via
    // `captured.append(chunk.prefix(remaining))`, so the trailing 'z' must never be retained.
    func testRunCapturedOutputCapBoundaryKeepsExactCapAndDropsOneByteOver() throws {
        let workspace = try IntegrationWorkspace()
        let runner = workspace.runner()
        let cap = 64 * 1024 * 1024

        let exact = try runner.run(
            "/bin/sh",
            ["-c", "head -c \(cap) /dev/zero | tr '\\0' a"],
            timeoutSeconds: 120
        )
        XCTAssertEqual(exact.exitCode, 0)
        XCTAssertEqual(exact.stdout.utf8.count, cap, "output landing exactly on the cap must be kept whole")
        XCTAssertEqual(exact.stdout.utf8.last, UInt8(ascii: "a"))

        let oneOver = try runner.run(
            "/bin/sh",
            ["-c", "head -c \(cap) /dev/zero | tr '\\0' a; printf z"],
            timeoutSeconds: 120
        )
        XCTAssertEqual(oneOver.exitCode, 0)
        XCTAssertEqual(oneOver.stdout.utf8.count, cap, "one byte over the cap must be trimmed to the cap")
        XCTAssertEqual(oneOver.stdout.utf8.last, UInt8(ascii: "a"), "the byte past the cap must be discarded")
        XCTAssertFalse(oneOver.stdout.utf8.contains(UInt8(ascii: "z")), "the byte past the cap must be discarded")
    }

    // audit #0009: a child that ignores SIGTERM must still be reaped once the timeout fires.
    // Before the fix the watchdog only sent SIGTERM and waitUntilExit blocked for the child's
    // natural lifetime (here 60 s; for a wedged ffmpeg, forever).
    func testRunTimeoutEscalatesToSIGKILLWhenChildIgnoresSIGTERM() throws {
        let workspace = try IntegrationWorkspace()
        let runner = workspace.runner()
        let start = Date()
        XCTAssertThrowsError(try runner.run("/bin/sh", ["-c", "trap '' TERM; sleep 60"], timeoutSeconds: 1)) { error in
            XCTAssertTrue("\(error)".contains("timed out"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 15, "timeout must not wait for the child's natural exit")
    }

    // audit #0009: a grandchild that inherited the pipe must not keep the timed-out run blocked
    // on EOF. The shell exits on SIGTERM; its backgrounded sleep keeps stdout open for 60 s.
    func testRunTimeoutDoesNotWaitForGrandchildHoldingThePipe() throws {
        let workspace = try IntegrationWorkspace()
        let runner = workspace.runner()
        let start = Date()
        XCTAssertThrowsError(try runner.run("/bin/sh", ["-c", "sleep 60 & wait"], timeoutSeconds: 1)) { error in
            XCTAssertTrue("\(error)".contains("timed out"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 15, "timeout must not block on a pipe held by a grandchild")
    }

    // audit #0024: the batch image actions must never re-ingest the full run's portrait stills.
    // -aipix on a 4320x7680 `_Short_8K.png` used to rewrite it as a letterboxed landscape 8K.
    func testImageBatchActionsSkipPortraitShortStills() async throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["magick"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig + "\nIMAGE_8K_WIDTH=320\nIMAGE_8K_HEIGHT=180\n")
        let still = try workspace.createImage(name: "art_Short_8K", ext: "png", width: 180, height: 320)
        let centerCut = try workspace.createImage(name: "art_Short_CenterCut_8K", ext: "png", width: 180, height: 320)
        let reference = try workspace.copy(still, as: "art_Short_8K_reference", ext: "png")

        let aipix = try workspace.makeTool(arguments: ["-aipix"])
        try aipix.stepAIPix()
        let runPix = try workspace.makeTool(arguments: ["-run_pix", "--continue-on-error"])
        try? await runPix.stepRunPix()
        let toJPG = try workspace.makeTool(arguments: ["-pngtojpg"])
        try toJPG.stepPNGToJPG()

        XCTAssertEqual(try aipix.crc32(for: still), try aipix.crc32(for: reference), "still must be untouched")
        XCTAssertEqual(try aipix.imageDimensions(centerCut).map { "\($0.0)x\($0.1)" }, "180x320")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.path + "/art_Short_8K.jpg"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.path + "/art_Short_8K_4K.png"))
    }

    // audit #0026: the bridge used to validate a truncated output against the size it had
    // written into the header itself, so a full disk produced a "successful" short file. The
    // real file size must match; this test writes 1.5 MB of PCM onto a 1 MB RAM disk.
    func testBW64WriterReportsATruncatedOutput() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg"])
        let runner = workspace.runner()
        let attach: ProcessResult
        do {
            attach = try runner.run("/usr/bin/hdiutil", ["attach", "-nomount", "ram://2048"])
        } catch {
            throw XCTSkip("RAM disk unavailable on this host: \(error)")
        }
        guard let device = attach.stdout.split(whereSeparator: \.isWhitespace).first.map(String.init) else {
            throw XCTSkip("hdiutil returned no device")
        }
        defer { _ = try? runner.run("/usr/bin/hdiutil", ["detach", device, "-force"]) }
        _ = try runner.run("/sbin/newfs_hfs", ["-v", "converter-audit", device])
        _ = try runner.run("/usr/sbin/diskutil", ["mount", device])
        let info = try runner.run("/usr/sbin/diskutil", ["info", device]).stdout
        guard let mountLine = info.split(whereSeparator: \.isNewline).first(where: { $0.contains("Mount Point:") }),
              let mountPoint = mountLine.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        else {
            throw XCTSkip("RAM disk did not mount")
        }

        let raw = workspace.output.appendingPathComponent("pcm.f32le")
        _ = try runner.run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2.0:sample_rate=96000",
            "-ac", "2", "-f", "f32le", "-acodec", "pcm_f32le", raw.path
        ])
        let tool = try workspace.makeTool(arguments: ["-full"])
        let output = URL(fileURLWithPath: mountPoint).appendingPathComponent("truncated.wav")
        XCTAssertThrowsError(
            try tool.writeBW64FileFromRawFloatPCM(inputPCM: raw, output: output, channels: 2, sampleRate: 96_000)
        ) { error in
            XCTAssertTrue("\(error)".contains("size mismatch"), "\(error)")
        }
    }

    // The stills must show exactly what the shorts show: the fitted one pads with black, the
    // centre cut fills the frame. Verified on pixels, not on the command that produced them.
    func testPortraitShortStillsMatchTheirRenderFraming() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["magick"])

        let landscape = try workspace.createImage(name: "art_8K", ext: "png", width: 320, height: 180)
        let square = try workspace.createImage(name: "art_NFT8K", ext: "png", width: 320, height: 320)
        let tool = try workspace.makeTool(arguments: ["-full"])
        defer { tool.cleanupTemps() }
        try tool.initializeForExecution()

        let fitted = try tool.portraitShortStills(from: square, mode: .fit, prefix: "art")
        let centerCut = try tool.portraitShortStills(from: landscape, mode: .centerCut, prefix: "art")

        XCTAssertEqual(fitted.all.map(\.lastPathComponent), ["art_Short_8K.png", "art_Short_8K_1MB.jpg", "art_Short_8K_2MB.jpg"])
        XCTAssertEqual(
            centerCut.all.map(\.lastPathComponent),
            ["art_Short_CenterCut_8K.png", "art_Short_CenterCut_8K_1MB.jpg", "art_Short_CenterCut_8K_2MB.jpg"]
        )

        for file in fitted.all + centerCut.all {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "missing \(file.lastPathComponent)")
            let dimensions = try XCTUnwrap(try tool.imageDimensions(file))
            XCTAssertEqual(dimensions.0, tool.config.shortMP4ScaleW, "width of \(file.lastPathComponent)")
            XCTAssertEqual(dimensions.1, tool.config.shortMP4ScaleH, "height of \(file.lastPathComponent)")
        }

        // A square fitted into a 9:16 frame must leave black bands; a centre cut must not.
        func topStripMaximum(_ file: URL) throws -> Double {
            let strip = max(1, tool.config.shortMP4ScaleH / 10)
            let result = try tool.runner.run("magick", [
                file.path, "-alpha", "off",
                "-crop", "\(tool.config.shortMP4ScaleW)x\(strip)+0+0", "+repage",
                "-format", "%[fx:maxima]", "info:"
            ])
            return Double(result.stdout.trimmed) ?? -1
        }

        XCTAssertEqual(try topStripMaximum(fitted.png), 0, accuracy: 0.0001, "fitted still should be letterboxed")
        XCTAssertGreaterThan(try topStripMaximum(centerCut.png), 0, "centre cut still must fill the frame")
    }

    func testCleanupTempsRemovesRunScopedHiddenTempFiles() throws {
        let workspace = try IntegrationWorkspace()
        let tool = try workspace.makeTool(arguments: ["-full"])
        let runScopedTemp = workspace.output.appendingPathComponent(".converter-tmp.\(tool.runToken).mainmp4.hevc_videotoolbox.1234.mp4")
        let orphanedTemp = workspace.output.appendingPathComponent(".converter-tmp.999999.mainmp4.hevc_videotoolbox.1234.mp4")
        let foreignTemp = workspace.output.appendingPathComponent(".converter-tmp.foreign.mainmp4.hevc_videotoolbox.1234.mp4")
        try Data("current-run-temp".utf8).write(to: runScopedTemp)
        try Data("orphaned-temp".utf8).write(to: orphanedTemp)
        try Data("foreign-temp".utf8).write(to: foreignTemp)

        tool.cleanupOrphanedConverterTempFiles()

        XCTAssertTrue(FileManager.default.fileExists(atPath: runScopedTemp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanedTemp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignTemp.path))

        tool.cleanupTemps()

        XCTAssertFalse(FileManager.default.fileExists(atPath: runScopedTemp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignTemp.path))
    }

    // audit #0038: the orphan sweep used to be tested only against the dead PID 999999. It must keep
    // every temp whose owner is alive: this process (getpid), the parent (getppid), launchd (PID 1,
    // where kill(1, 0) fails with EPERM for a non-root user and must count as "exists"), and a
    // spawned child while it runs. A file with a malformed PID or without the prefix is never touched.
    func testCleanupOrphansRetainsTempFilesOfLiveProcessesAndUnparsableNames() throws {
        let workspace = try IntegrationWorkspace()
        let tool = try workspace.makeTool(arguments: ["-full"])
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }
        XCTAssertTrue(child.isRunning, "the sleep child must be alive while the sweep runs")

        func temp(_ name: String) throws -> URL {
            let url = workspace.output.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return url
        }
        let selfTemp = try temp(".converter-tmp.\(getpid()).mainmp4.libx264.1.mp4")
        let parentTemp = try temp(".converter-tmp.\(getppid()).mainmp4.libx264.2.mp4")
        let launchdTemp = try temp(".converter-tmp.1.mainmp4.libx264.3.mp4")
        let childTemp = try temp(".converter-tmp.\(child.processIdentifier).mainmp4.libx264.4.mp4")
        let notAPIDTemp = try temp(".converter-tmp.notapid.x")
        let bareTemp = try temp(".converter-tmp.")
        let unprefixedTemp = try temp("converter-tmp.999999.mainmp4.libx264.5.mp4")
        let deadTemp = try temp(".converter-tmp.999999.mainmp4.libx264.6.mp4")

        XCTAssertFalse(tool.isOrphanedConverterTempFile(selfTemp))
        XCTAssertFalse(tool.isOrphanedConverterTempFile(parentTemp))
        XCTAssertFalse(tool.isOrphanedConverterTempFile(launchdTemp))
        XCTAssertFalse(tool.isOrphanedConverterTempFile(childTemp))
        XCTAssertFalse(tool.isOrphanedConverterTempFile(notAPIDTemp))
        XCTAssertFalse(tool.isOrphanedConverterTempFile(bareTemp))
        XCTAssertFalse(tool.isOrphanedConverterTempFile(unprefixedTemp))
        XCTAssertTrue(tool.isOrphanedConverterTempFile(deadTemp))

        tool.cleanupOrphanedConverterTempFiles()

        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: selfTemp.path), "temp of this process must survive")
        XCTAssertTrue(fileManager.fileExists(atPath: parentTemp.path), "temp of the live parent process must survive")
        XCTAssertTrue(fileManager.fileExists(atPath: launchdTemp.path), "temp of PID 1 (EPERM) must survive")
        XCTAssertTrue(fileManager.fileExists(atPath: childTemp.path), "temp of the running child must survive")
        XCTAssertTrue(fileManager.fileExists(atPath: notAPIDTemp.path), "temp with a non-numeric PID must survive")
        XCTAssertTrue(fileManager.fileExists(atPath: bareTemp.path), "temp with an empty PID must survive")
        XCTAssertTrue(fileManager.fileExists(atPath: unprefixedTemp.path), "file without the prefix must survive")
        XCTAssertFalse(fileManager.fileExists(atPath: deadTemp.path), "temp of the dead PID 999999 must be removed")
        XCTAssertEqual(try String(contentsOf: selfTemp, encoding: .utf8), selfTemp.lastPathComponent)
        XCTAssertEqual(try String(contentsOf: childTemp, encoding: .utf8), childTemp.lastPathComponent)
    }

    // audit #0038: once the owning child has exited and been reaped its temp becomes an orphan and
    // the very next sweep must remove it, while the temps of still-live processes stay untouched.
    func testCleanupOrphansRemovesTempFileOnceOwningChildHasExited() throws {
        let workspace = try IntegrationWorkspace()
        let tool = try workspace.makeTool(arguments: ["-full"])
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }
        let childPID = child.processIdentifier
        let childTemp = workspace.output.appendingPathComponent(".converter-tmp.\(childPID).mainmp4.libx264.1.mp4")
        let selfTemp = workspace.output.appendingPathComponent(".converter-tmp.\(getpid()).mainmp4.libx264.2.mp4")
        try Data("child-temp".utf8).write(to: childTemp)
        try Data("self-temp".utf8).write(to: selfTemp)

        tool.cleanupOrphanedConverterTempFiles()
        XCTAssertTrue(FileManager.default.fileExists(atPath: childTemp.path), "temp must survive while the child runs")
        XCTAssertTrue(tool.processExists(childPID))

        child.terminate()
        child.waitUntilExit()
        XCTAssertFalse(child.isRunning)
        XCTAssertFalse(tool.processExists(childPID), "a terminated and reaped child must no longer exist")
        XCTAssertTrue(tool.isOrphanedConverterTempFile(childTemp))

        tool.cleanupOrphanedConverterTempFiles()
        let fileManager = FileManager.default
        XCTAssertFalse(fileManager.fileExists(atPath: childTemp.path), "temp of the exited child must be removed")
        XCTAssertTrue(fileManager.fileExists(atPath: selfTemp.path), "temp of this process must survive the sweep")
        XCTAssertEqual(try String(contentsOf: selfTemp, encoding: .utf8), "self-temp")
    }

    func testPublishTempReplacesExistingDestination() throws {
        let workspace = try IntegrationWorkspace()
        let tool = try workspace.makeTool(arguments: ["-full"])
        let destination = workspace.output.appendingPathComponent("song_8K.mp4")
        let temp = try tool.makeTemp(in: workspace.output, stem: "mainmp4.libx264", ext: ".mp4")
        try Data("old-final".utf8).write(to: destination)
        try Data("new-final".utf8).write(to: temp)

        try tool.publishTemp(temp, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new-final")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        tool.cleanupTemps()
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new-final")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }

    func testShortMP4OutputStemsDoNotRepeatShortSuffixes() throws {
        let workspace = try IntegrationWorkspace()
        let tool = try workspace.makeTool(arguments: ["-mp4toshort"])

        XCTAssertEqual(tool.shortMP4Stem(forInputStem: "song_8K"), "song_8K_Short")
        XCTAssertEqual(tool.shortMP4Stem(forInputStem: "song_8K_Short"), "song_8K_Short")
        XCTAssertEqual(tool.portraitShortMP4Stem(forAudioStem: "song"), "song_8K_Short")
        XCTAssertEqual(tool.portraitShortMP4Stem(forAudioStem: "song_8K"), "song_8K_Short")
        XCTAssertEqual(tool.portraitShortMP4Stem(forAudioStem: "song_8K_Short"), "song_8K_Short")
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
            ("flac->wav", flac, { try tool.convertAudioToWAV(flac) }, { file in
                try tool.verifyWAVStandard(file)
                try tool.verifyDurationMatch(source: flac, output: file)
            }),
            ("flac->mp3", flac, { try tool.convertAudioToMP3(flac) }, { file in
                try tool.verifyMP3Standard(file)
                try tool.verifyDurationMatch(source: flac, output: file)
            }),
            ("flac->m4a", flac, { try tool.convertAudioToM4A(flac) }, { file in
                try tool.verifyM4AFile(file, sampleRate: tool.config.m4aSampleRate, channels: tool.config.m4aChannels)
                try tool.verifyDurationMatch(source: flac, output: file)
            }),
            ("wav->flac", wav, { try tool.convertAudioToFLAC(wav) }, { file in
                try tool.verifyAudioOutput(file, codec: "flac", sampleRate: tool.config.flacSampleRate, channels: tool.config.flacChannels)
                try tool.verifyDurationMatch(source: wav, output: file)
            }),
            ("wav->mp3", wav, { try tool.convertAudioToMP3(wav) }, { file in
                try tool.verifyMP3Standard(file)
                try tool.verifyDurationMatch(source: wav, output: file)
            }),
            ("wav->m4a", wav, { try tool.convertAudioToM4A(wav) }, { file in
                try tool.verifyM4AFile(file, sampleRate: tool.config.m4aSampleRate, channels: tool.config.m4aChannels)
                try tool.verifyDurationMatch(source: wav, output: file)
            }),
            ("mp3->wav", mp3, { try tool.convertAudioToWAV(mp3) }, { file in
                try tool.verifyWAVStandard(file)
                try tool.verifyDurationMatch(source: mp3, output: file)
            }),
            ("mp3->flac", mp3, { try tool.convertAudioToFLAC(mp3) }, { file in
                try tool.verifyAudioOutput(file, codec: "flac", sampleRate: tool.config.flacSampleRate, channels: tool.config.flacChannels)
                try tool.verifyDurationMatch(source: mp3, output: file)
            }),
            ("mp3->m4a", mp3, { try tool.convertAudioToM4A(mp3) }, { file in
                try tool.verifyM4AFile(file, sampleRate: tool.config.m4aSampleRate, channels: tool.config.m4aChannels)
                try tool.verifyDurationMatch(source: mp3, output: file)
            }),
            ("m4a->wav", m4a, { try tool.convertAudioToWAV(m4a) }, { file in
                try tool.verifyWAVStandard(file)
                try tool.verifyDurationMatch(source: m4a, output: file)
            }),
            ("m4a->mp3", m4a, { try tool.convertAudioToMP3(m4a) }, { file in
                try tool.verifyMP3Standard(file)
                try tool.verifyDurationMatch(source: m4a, output: file)
            }),
            ("m4a->flac", m4a, { try tool.convertAudioToFLAC(m4a) }, { file in
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

        let wavFromFLAC = try tool.convertAudioToWAV(flacWithArtwork)
        try tool.verifyWAVStandard(wavFromFLAC, qcPolicy: nil)
        XCTAssertThrowsError(try tool.requireVideoStream(wavFromFLAC), "WAV output should contain audio only.")

        let wavFromMP3 = try tool.convertAudioToWAV(mp3WithArtwork)
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
        XCTAssertThrowsError(try tool.convertAudioToWAV(fakeMP3)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Audio container mismatch") || error.localizedDescription.contains("Audio codec mismatch"))
        }
    }

    func testRejectsFLACExtensionWithMP3Payload() throws {
        let workspace = try IntegrationWorkspace()
        let mp3 = try workspace.createAudio(name: "real_mp3", ext: "mp3")
        let fakeFLAC = try workspace.copy(mp3, as: "fake_lossless", ext: "flac")
        let tool = try workspace.makeTool(arguments: ["-flactowav"])
        XCTAssertThrowsError(try tool.convertAudioToWAV(fakeFLAC)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Audio container mismatch") || error.localizedDescription.contains("Audio codec mismatch"))
        }
    }

    func testRejectsM4AExtensionWithMP3Payload() throws {
        let workspace = try IntegrationWorkspace()
        let mp3 = try workspace.createAudio(name: "real_mp3", ext: "mp3")
        let fakeM4A = try workspace.copy(mp3, as: "fake_aac", ext: "m4a")
        let tool = try workspace.makeTool(arguments: ["-m4atowav"])
        XCTAssertThrowsError(try tool.convertAudioToWAV(fakeM4A)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Audio codec mismatch") || error.localizedDescription.contains("Unexpected video stream") || error.localizedDescription.contains("Audio container mismatch"))
        }
    }

    func testRejectsWAVBinaryGarbage() throws {
        let workspace = try IntegrationWorkspace()
        let garbage = try workspace.writeGarbageFile(name: "broken", ext: "wav")
        let tool = try workspace.makeTool(arguments: ["-wavtomp3"])
        XCTAssertThrowsError(try tool.convertAudioToMP3(garbage))
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
        XCTAssertThrowsError(try tool.convertAudioToWAV(silent)) { error in
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
        // Stream copy: the 192 kbps fixture keeps its own bitrate; only structure and QC are checked.
        try tool.verifyMP3File(taggedMP3, qcPolicy: tool.config.deliveryAudioQCPolicy)
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
        // A clean is a stream copy: structurally valid MP3, artwork gone, delivery QC not applied
        // (the fixture is deliberately over the true-peak ceiling and must stay that way).
        try tool.verifyMP3File(taggedMP3, requireAudible: false, requireNoVideo: true, qcPolicy: nil)
        XCTAssertThrowsError(try tool.requireVideoStream(taggedMP3))
        XCTAssertThrowsError(try tool.verifyMP3File(taggedMP3, qcPolicy: tool.config.deliveryAudioQCPolicy))
    }

    func testFadeOutProducesTruncatedSameFormatAudioOutput() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])

        let source = try workspace.createMP3WithArtwork(name: "fade_song", duration: 3.0)
        let tool = try workspace.makeTool(arguments: ["-fadeout", "1.5", "0.75"])
        let spec = try tool.cli.fadeOutSpec()

        try tool.stepFadeOut()

        let output = workspace.output.appendingPathComponent("fade_song_fadeout_1.5s_0.75s.mp3")
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

        let output = workspace.output.appendingPathComponent("hot_fade_song_fadeout_1.5s_0.75s.mp3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        try tool.verifyMP3Standard(output, qcPolicy: nil)
        XCTAssertThrowsError(try tool.requireVideoStream(output))
        try tool.verifyDuration(output, expectedSeconds: spec.endSeconds, label: "fadeout output")
    }

    // audit #0020: a bass boost that drives the 24-bit staging WAV past full scale must fail
    // with a clear message instead of publishing a clipped file with no indication.
    // audit #0021: every failed rung must be reported. The padded-MP4 ladder used to keep only
    // the last error, hiding the first rung's (usually real) cause.
    func testPaddedMP4EncoderLadderReportsEveryFailedRung() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        // Both software encoders exist but reject an unknown preset, so both rungs fail in the loop.
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig
                + "\nVIDEO_MP4_ENCODER=libx264\nVIDEO_MP4_ENCODER_FALLBACKS=libx265\n"
                + "VIDEO_MP4_SOFTWARE_PRESET=no_such_preset\n")
        let video = try workspace.createVideoMP4(name: "clip", duration: 1.5)
        let tool = try workspace.makeTool(arguments: ["-silence", "1"])
        XCTAssertThrowsError(try tool.addSilenceToMedia(video, spec: SilenceSpec(seconds: 1))) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("libx264:"), message)
            XCTAssertTrue(message.contains("libx265:"), message)
        }
    }

    func testBassBoostRefusesToPublishClippedOutput() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        // The production ceiling: the shared test config tolerates a million clipped samples.
        try workspace.overwriteConfig(IntegrationWorkspace.defaultConfig + "\nAUDIO_QC_MAX_CLIPPED_SAMPLES=0\n")
        // A 50 Hz tone at about -1 dBFS (the sine source sits near -21 dBFS before gain):
        // +5 dB below 80 Hz pushes it ~4 dB over full scale.
        let hotLow = try workspace.createHotAudio(name: "sub_bass", ext: "wav", frequency: 50, gainDB: 20)
        let tool = try workspace.makeTool(arguments: ["-bass", "80", "5"])
        let boost = BassBoostSpec(frequencyHz: 80, gainDB: 5)
        XCTAssertThrowsError(try tool.bassBoostMedia(hotLow, spec: boost)) { error in
            XCTAssertTrue("\(error)".contains("clip"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.path + "/sub_bass_bass.wav"))
        // The same boost on material with headroom still works.
        let quiet = try workspace.createAudio(name: "quiet_low", ext: "wav", frequency: 50)
        XCTAssertNoThrow(try tool.bassBoostMedia(quiet, spec: boost))
    }

    func testBassBoostProcessesAudioAndMP4Inputs() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let mp3 = try workspace.createAudio(name: "bass_mp3", ext: "mp3", duration: 1.4, frequency: 60)
        let wav = try workspace.createAudio(name: "bass_wav", ext: "wav", duration: 1.4, frequency: 60)
        let flac = try workspace.createAudio(name: "bass_flac", ext: "flac", duration: 1.4, frequency: 60)
        let m4a = try workspace.createAudio(name: "bass_m4a", ext: "m4a", duration: 1.4, frequency: 60)
        let mp4 = try workspace.createVideoMP4(name: "bass_video", duration: 1.4, frequency: 60)
        let tool = try workspace.makeTool(arguments: ["-bass", "80", "5"])

        try tool.stepBass()

        let mp3Out = workspace.output.appendingPathComponent("bass_mp3_bass.mp3")
        let wavOut = workspace.output.appendingPathComponent("bass_wav_bass.wav")
        let flacOut = workspace.output.appendingPathComponent("bass_flac_bass.flac")
        let m4aOut = workspace.output.appendingPathComponent("bass_m4a_bass.m4a")
        let mp4Out = workspace.output.appendingPathComponent("bass_video_bass.mp4")

        for output in [mp3Out, wavOut, flacOut, m4aOut, mp4Out] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "Missing \(output.lastPathComponent)")
        }

        try tool.verifyBassOutput(mp3Out, source: mp3)
        try tool.verifyBassOutput(wavOut, source: wav)
        try tool.verifyBassOutput(flacOut, source: flac)
        try tool.verifyBassOutput(m4aOut, source: m4a)
        try tool.verifyBassOutput(mp4Out, source: mp4)
        XCTAssertNoThrow(try tool.requireVideoStream(mp4Out))
    }

    func testBassUsesSettingsSpecificSuffixForManualValues() throws {
        let workspace = try IntegrationWorkspace()
        let tool = try workspace.makeTool(arguments: ["-bass", "60", "7.5"])
        XCTAssertEqual(try tool.cli.bassBoostSpec(), BassBoostSpec(frequencyHz: 60, gainDB: 7.5))
        XCTAssertEqual(tool.bassOutputSuffix(for: try tool.cli.bassBoostSpec()), "_bass_60Hz_7_5dB")
        XCTAssertEqual(tool.bassFilter(for: try tool.cli.bassBoostSpec()), "bass=f=60:g=7.5:t=h:w=60:p=2:precision=f64")

        let cutTool = try workspace.makeTool(arguments: ["-bass", "80", "-5"])
        XCTAssertEqual(try cutTool.cli.bassBoostSpec(), BassBoostSpec(frequencyHz: 80, gainDB: -5))
        XCTAssertEqual(cutTool.bassOutputSuffix(for: try cutTool.cli.bassBoostSpec()), "_bass_80Hz_m5dB")
        XCTAssertEqual(cutTool.bassFilter(for: try cutTool.cli.bassBoostSpec()), "bass=f=80:g=-5:t=h:w=80:p=2:precision=f64")
    }

    func testBassNegativeGainReducesLowBandEnergy() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let source = workspace.output.appendingPathComponent("bass_cut_source").appendingPathExtension("wav")
        _ = try workspace.runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi",
            "-i", "aevalsrc=0.18*sin(2*PI*60*t)+0.18*sin(2*PI*1000*t):s=48000:d=4",
            "-ac", "2",
            "-c:a", "pcm_f32le",
            "-ar", "48000",
            "-f", "wav",
            "-rf64", "always",
            "-write_bext", "1",
            source.path
        ])

        let tool = try workspace.makeTool(arguments: ["-bass", "80", "-5"])
        let cutOutput = try tool.bassBoostMedia(source, spec: try tool.cli.bassBoostSpec())

        let sourceRatio = try bassToMidRatioDB(file: source, workspace: workspace)
        let cutRatio = try bassToMidRatioDB(file: cutOutput, workspace: workspace)

        XCTAssertLessThan(cutRatio - sourceRatio, -2.0, "Negative bass gain must reduce low-band energy.")
    }

    func testLoudnessDoesNotApplyBassBoost() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let source = workspace.output.appendingPathComponent("two_tone").appendingPathExtension("wav")
        _ = try workspace.runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi",
            "-i", "aevalsrc=0.18*sin(2*PI*60*t)+0.18*sin(2*PI*1000*t):s=48000:d=4",
            "-ac", "2",
            "-c:a", "pcm_f32le",
            "-ar", "48000",
            "-f", "wav",
            "-rf64", "always",
            "-write_bext", "1",
            source.path
        ])

        let tool = try workspace.makeTool(arguments: ["-loudness"])
        let loudnessOutput = try tool.loudnessNormalizeMedia(source, spec: LoudnessSpec(targetLUFS: -12))
        let bassOutput = try tool.bassBoostMedia(source, spec: BassBoostSpec(frequencyHz: 80, gainDB: 5))

        let sourceRatio = try bassToMidRatioDB(file: source, workspace: workspace)
        let loudnessRatio = try bassToMidRatioDB(file: loudnessOutput, workspace: workspace)
        let boostedRatio = try bassToMidRatioDB(file: bassOutput, workspace: workspace)

        XCTAssertLessThan(abs(loudnessRatio - sourceRatio), 1.0, "Loudness normalization must preserve low-vs-mid spectral balance.")
        XCTAssertGreaterThan(boostedRatio - sourceRatio, 2.0, "Bass command must be the path that increases low-band energy.")
    }

    func testLoudScanReportsFourSummaryLines() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        _ = try workspace.createHotAudio(name: "quiet_scan", ext: "wav", duration: 1.4, gainDB: -12)
        _ = try workspace.createAudio(name: "middle_scan", ext: "flac", duration: 1.4)
        _ = try workspace.createHotAudio(name: "loud_scan", ext: "mp3", duration: 1.4, gainDB: 6)
        let tool = try workspace.makeTool(arguments: ["-loudscan"])

        var progressEvents: [LoudnessScanProgress] = []
        let lines = try tool.loudScanReportLines { progressEvents.append($0) }

        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].contains("Average loudness:"))
        XCTAssertTrue(lines[1].contains("Lowest loudness:"))
        XCTAssertTrue(lines[2].contains("Highest loudness:"))
        XCTAssertTrue(lines[3].contains("Top 3 loudest average:"))
        XCTAssertTrue(lines[1].contains("quiet_scan.wav"))
        XCTAssertTrue(lines[2].contains("loud_scan.mp3"))
        XCTAssertEqual(progressEvents.count, 6)
        XCTAssertEqual(progressEvents.filter { $0.isMeasuring }.count, 3)
        XCTAssertEqual(progressEvents.filter { !$0.isMeasuring }.count, 3)
        XCTAssertEqual(progressEvents.first?.processedFiles, 0)
        XCTAssertEqual(progressEvents.first?.totalFiles, 3)
        XCTAssertEqual(progressEvents.last?.processedFiles, 3)
        XCTAssertEqual(progressEvents.last?.reportLines.count, 4)
    }

    func testLoudnessNormalizeProcessesAudioAndMP4Inputs() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let mp3 = try workspace.createHotAudio(name: "level_mp3", ext: "mp3", duration: 1.4, gainDB: 6)
        let wav = try workspace.createHotAudio(name: "level_wav", ext: "wav", duration: 1.4, gainDB: -6)
        let flac = try workspace.createAudio(name: "level_flac", ext: "flac", duration: 1.4)
        let m4a = try workspace.createHotAudio(name: "level_m4a", ext: "m4a", duration: 1.4, gainDB: 3)
        let mp4 = try workspace.createVideoMP4(name: "level_video", duration: 1.4)
        let tool = try workspace.makeTool(arguments: ["-loudness"])
        let policy = tool.loudnessPolicy(targetLUFS: -12)
        XCTAssertEqual(try tool.cli.loudnessSpec(), LoudnessSpec(targetLUFS: -12))

        try tool.stepLoudness()

        let mp3Out = workspace.output.appendingPathComponent("level_mp3_loudness_m12LUFS.mp3")
        let wavOut = workspace.output.appendingPathComponent("level_wav_loudness_m12LUFS.wav")
        let flacOut = workspace.output.appendingPathComponent("level_flac_loudness_m12LUFS.flac")
        let m4aOut = workspace.output.appendingPathComponent("level_m4a_loudness_m12LUFS.m4a")
        let mp4Out = workspace.output.appendingPathComponent("level_video_loudness_m12LUFS.mp4")

        for output in [mp3Out, wavOut, flacOut, m4aOut, mp4Out] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "Missing \(output.lastPathComponent)")
        }

        try tool.verifyLoudnessOutput(mp3Out, source: mp3, policy: policy)
        try tool.verifyLoudnessOutput(wavOut, source: wav, policy: policy)
        try tool.verifyLoudnessOutput(flacOut, source: flac, policy: policy)
        try tool.verifyLoudnessOutput(m4aOut, source: m4a, policy: policy)
        try tool.verifyLoudnessOutput(mp4Out, source: mp4, policy: policy)
        XCTAssertNoThrow(try tool.requireVideoStream(mp4Out))
    }

    func testLoudnessNormalizeKeepsPeakConstrainedMP4Transparent() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig.replacingOccurrences(
                of: "AUDIO_QC_MAX_TRUE_PEAK_DBTP=0",
                with: "AUDIO_QC_MAX_TRUE_PEAK_DBTP=-1"
            )
        )

        let source = workspace.output.appendingPathComponent("peak_limited").appendingPathExtension("mp4")
        _ = try workspace.runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi",
            "-i", "color=c=#111111:size=320x180:rate=2:duration=4",
            "-f", "lavfi",
            "-i", "aevalsrc=if(lt(mod(t\\,1)\\,0.02)\\,0.95*sin(2*PI*1000*t)\\,0.04*sin(2*PI*220*t)):s=48000:d=4",
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-b:a", "192k",
            "-ar", "48000",
            "-shortest",
            source.path
        ])

        let tool = try workspace.makeTool(arguments: ["-loudness"])
        let policy = tool.loudnessPolicy(targetLUFS: -12)
        let sourceMetrics = try tool.audioQCResult(for: source, policy: tool.loudnessPolicy(targetLUFS: -12, tolerance: 99)).metrics
        XCTAssertLessThan(sourceMetrics.integratedLUFS ?? 0, -14)
        XCTAssertGreaterThan(sourceMetrics.truePeakDBTP ?? -99, policy.maxTruePeakDBTP)
        let plan = try tool.staticLoudnessGainPlan(for: source, policy: policy)
        XCTAssertTrue(plan.peakConstrained)
        XCTAssertGreaterThanOrEqual(plan.appliedGainDB, 0)
        XCTAssertLessThan(plan.appliedGainDB, plan.requestedGainDB)

        let output = try tool.loudnessNormalizeMedia(source, spec: LoudnessSpec(targetLUFS: -12))
        let result = try tool.loudnessOutputQCResult(output, source: source, policy: policy)
        XCTAssertTrue(tool.loudnessCandidateIsPublishableFallback(result, policy: policy), result.issues.joined(separator: "; "))
        XCTAssertGreaterThanOrEqual(result.metrics.integratedLUFS ?? -99, (sourceMetrics.integratedLUFS ?? -99) - 0.25)
        XCTAssertLessThanOrEqual(result.metrics.integratedLUFS ?? 99, policy.targetLUFS + 0.5)
        XCTAssertNoThrow(try tool.requireVideoStream(output))
    }

    func testTailFadeProcessesMP3WAVAndFLACWithoutTruncating() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let mp3 = try workspace.createAudio(name: "tail_mp3", ext: "mp3", duration: 2.0)
        let wav = try workspace.createAudio(name: "tail_wav", ext: "wav", duration: 2.0)
        let flac = try workspace.createAudio(name: "tail_flac", ext: "flac", duration: 2.0)
        let tool = try workspace.makeTool(arguments: ["-fade", "0.5"])

        try tool.stepFade()

        let mp3Out = workspace.output.appendingPathComponent("tail_mp3_faded_0.5s.mp3")
        let wavOut = workspace.output.appendingPathComponent("tail_wav_faded_0.5s.wav")
        let flacOut = workspace.output.appendingPathComponent("tail_flac_faded_0.5s.flac")
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

    func testSilenceAddsLeadingAndTrailingPaddingToWAVFLACAndMP4() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let wav = try workspace.createAudio(name: "pad_wav", ext: "wav", duration: 1.2)
        let flac = try workspace.createAudio(name: "pad_flac", ext: "flac", duration: 1.2)
        let mp4 = try workspace.createVideoMP4(name: "pad_video", duration: 1.2)
        let tool = try workspace.makeTool(arguments: ["-silence", "0.5"])
        let spec = try tool.cli.silenceSpec()

        try tool.stepSilence()

        let wavOut = workspace.output.appendingPathComponent("pad_wav_silence_0_5s.wav")
        let flacOut = workspace.output.appendingPathComponent("pad_flac_silence_0_5s.flac")
        let mp4Out = workspace.output.appendingPathComponent("pad_video_silence_0_5s.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavOut.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: flacOut.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp4Out.path))

        for (source, output) in [(wav, wavOut), (flac, flacOut), (mp4, mp4Out)] {
            let sourceDuration = try XCTUnwrap(try tool.mediaDuration(source))
            let expectedDuration = tool.silenceExpectedDuration(sourceDuration: sourceDuration, spec: spec)
            try tool.verifySilenceOutput(output, source: source, expectedDuration: expectedDuration, spec: spec)
            let middleMaxVolume = try tool.audioSegmentMaxVolumeDBFS(file: output, startSeconds: spec.effectiveLeadingSeconds + 0.2, durationSeconds: 0.2)
            XCTAssertGreaterThan(middleMaxVolume, -60, "Original audio must still be audible after inserted leading silence.")
        }
        XCTAssertNoThrow(try tool.requireVideoStream(mp4Out))
    }

    func testSilenceIgnoresPreviouslyGeneratedSilenceOutputs() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        _ = try workspace.createAudio(name: "song", ext: "flac", duration: 1.0)
        _ = try workspace.createAudio(name: "song_silence_30s", ext: "flac", duration: 1.0)
        let tool = try workspace.makeTool(arguments: ["-silence", "0.5"])

        XCTAssertEqual(try tool.audioSilenceCandidates().map(\.lastPathComponent), ["song.flac"])
    }

    func testSilenceMP4UsesH264SafeTagForSoftwareEncoder() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig
                + "\nVIDEO_MP4_ENCODER=libx264\n"
                + "VIDEO_MP4_ENCODER_FALLBACKS=\n"
                + "VIDEO_MP4_TAG=hvc1\n"
        )

        let mp4 = try workspace.createVideoMP4(name: "software_pad_video", duration: 1.2)
        let tool = try workspace.makeTool(arguments: ["-silence", "0.5"])
        let spec = try tool.cli.silenceSpec()

        try tool.stepSilence()

        let output = workspace.output.appendingPathComponent("software_pad_video_silence_0_5s.mp4")
        let expectedDuration = tool.silenceExpectedDuration(sourceDuration: try XCTUnwrap(try tool.mediaDuration(mp4)), spec: spec)
        try tool.verifySilenceOutput(output, source: mp4, expectedDuration: expectedDuration, spec: spec)
        XCTAssertEqual(try tool.videoField(output, "codec_name"), "h264")
    }

    func testNoiseAddsLeadingAndTrailingNoiseToAudioMedia() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let wav = try workspace.createAudio(name: "noise_wav", ext: "wav", duration: 0.8)
        let flac = try workspace.createAudio(name: "noise_flac", ext: "flac", duration: 0.8)
        let mp3 = try workspace.createAudio(name: "noise_mp3", ext: "mp3", duration: 0.8)
        let m4a = try workspace.createAudio(name: "noise_m4a", ext: "m4a", duration: 0.8)
        let mp4 = try workspace.createVideoMP4(name: "noise_video", duration: 0.8)
        let tool = try workspace.makeTool(arguments: ["-noise", "0.5"])
        let spec = try tool.cli.noiseSpec()

        try tool.stepNoise()

        let outputs: [(source: URL, output: URL)] = [
            (wav, workspace.output.appendingPathComponent("noise_wav_noise_0_5s.wav")),
            (flac, workspace.output.appendingPathComponent("noise_flac_noise_0_5s.flac")),
            (mp3, workspace.output.appendingPathComponent("noise_mp3_noise_0_5s.mp3")),
            (m4a, workspace.output.appendingPathComponent("noise_m4a_noise_0_5s.m4a")),
            (mp4, workspace.output.appendingPathComponent("noise_video_noise_0_5s.mp4"))
        ]

        for (source, output) in outputs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
            let sourceDuration = try XCTUnwrap(try tool.mediaDuration(source))
            let expectedDuration = tool.noiseExpectedDuration(sourceDuration: sourceDuration, spec: spec)
            try tool.verifyNoiseOutput(output, source: source, expectedDuration: expectedDuration, spec: spec)
            let leadingGapMaxVolume = try tool.audioSegmentMaxVolumeDBFS(file: output, startSeconds: spec.seconds + 0.2, durationSeconds: 0.2)
            XCTAssertLessThan(leadingGapMaxVolume, -55, "Noise output must insert silence between leading noise and the original audio.")
            let middleMaxVolume = try tool.audioSegmentMaxVolumeDBFS(
                file: output,
                startSeconds: spec.seconds + NoiseSpec.transitionSilenceSeconds + 0.2,
                durationSeconds: 0.2
            )
            XCTAssertGreaterThan(middleMaxVolume, -60, "Original audio must still be audible after inserted noise.")
        }
        XCTAssertNoThrow(try tool.requireVideoStream(workspace.output.appendingPathComponent("noise_video_noise_0_5s.mp4")))
    }

    func testNoiseIgnoresPreviouslyGeneratedNoiseOutputs() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        _ = try workspace.createAudio(name: "song", ext: "flac", duration: 1.0)
        _ = try workspace.createAudio(name: "song_noise_30s", ext: "flac", duration: 1.0)
        let tool = try workspace.makeTool(arguments: ["-noise", "0.5"])

        XCTAssertEqual(try tool.audioNoiseCandidates().map(\.lastPathComponent), ["song.flac"])
    }

    func testNoiseSegmentUsesDynamicLoudnormForProductionDurations() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let tool = try workspace.makeTool(arguments: ["-noise", "3"])
        let spec = try tool.cli.noiseSpec()
        let noise = try tool.makeNormalizedNoiseSegmentWAV(spec: spec, stem: "production.noise")
        defer { tool.discardTempFile(noise) }

        let result = try tool.audioQCResult(for: noise, policy: tool.noiseLoudnessPolicy(for: spec))
        XCTAssertTrue(result.passed, result.issues.joined(separator: "; "))
        XCTAssertEqual(result.metrics.integratedLUFS ?? -99, NoiseSpec.targetLUFS, accuracy: tool.noiseLUFSTolerance(for: spec))
    }

    func testNoisePaddingStaysAtTargetAfterFLACDeliveryEncode() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let flac = try workspace.createAudio(name: "delivery_noise", ext: "flac", duration: 0.8)
        let tool = try workspace.makeTool(arguments: ["-noise", "6"])
        let spec = try tool.cli.noiseSpec()

        let output = try tool.addNoiseToMedia(flac, spec: spec)
        let sourceDuration = try XCTUnwrap(try tool.mediaDuration(flac))
        let expectedDuration = tool.noiseExpectedDuration(sourceDuration: sourceDuration, spec: spec)
        try tool.verifyNoiseOutput(output, source: flac, expectedDuration: expectedDuration, spec: spec)

        let leadingLUFS = try tool.audioSegmentIntegratedLUFS(
            file: output,
            startSeconds: 0.05,
            durationSeconds: spec.seconds - 0.1,
            targetLUFS: NoiseSpec.targetLUFS
        )
        XCTAssertEqual(leadingLUFS, NoiseSpec.targetLUFS, accuracy: tool.noiseLUFSTolerance(for: spec))
    }

    func testFadeCutProcessesMP3WAVAndFLACWithShortenedDuration() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let mp3 = try workspace.createAudio(name: "cut_mp3", ext: "mp3", duration: 3.0)
        let wav = try workspace.createAudio(name: "cut_wav", ext: "wav", duration: 3.0)
        let flac = try workspace.createAudio(name: "cut_flac", ext: "flac", duration: 3.0)
        let tool = try workspace.makeTool(arguments: ["-fadecut", "0.5", "0.75"])

        try tool.stepFadeCut()

        let mp3Out = workspace.output.appendingPathComponent("cut_mp3_fadecut_0.5s_0.75s.mp3")
        let wavOut = workspace.output.appendingPathComponent("cut_wav_fadecut_0.5s_0.75s.wav")
        let flacOut = workspace.output.appendingPathComponent("cut_flac_fadecut_0.5s_0.75s.flac")
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

    func testNFTToShortBuildsShortFromGenericAudioAndNFTImage() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])

        _ = try workspace.createImage(name: "poster", ext: "png", width: 320, height: 180)
        let sourceAAC = try workspace.createAudio(name: "song", ext: "aac", duration: 2.4)
        let tool = try workspace.makeTool(arguments: ["-nfttoshort"])

        try tool.stepNFTToShort()

        let eightK = workspace.output.appendingPathComponent("poster_8K.png")
        let nft8K = workspace.output.appendingPathComponent("poster_NFT8K.png")
        let mainVideo = workspace.output.appendingPathComponent("song_8K.mp4")
        let shortVideo = workspace.output.appendingPathComponent("song_8K_Short.mp4")

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceAAC.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: eightK.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nft8K.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mainVideo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortVideo.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("song.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("song.mp3").path))

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
        try tool.verifyALACAudioOutput(shortVideo, sampleRate: tool.config.shortMP4AudioSampleRate, channels: 2, qcPolicy: nil)
        try tool.verifySourceLoudnessPreserved(source: sourceAAC, output: shortVideo, toleranceDB: 1.0)
        XCTAssertThrowsError(try tool.requireVideoStream(sourceAAC))
        XCTAssertNoThrow(try tool.requireVideoStream(shortVideo))
        try tool.verifyDuration(shortVideo, expectedSeconds: 1.0, label: "short mp4")
        let frame = try workspace.extractFirstVideoFrame(from: shortVideo, name: "song_short_frame")
        XCTAssertLessThan(try workspace.meanGrayValue(image: frame, crop: "90x10+0+0"), 0.05)
        XCTAssertLessThan(try workspace.meanGrayValue(image: frame, crop: "90x10+0+150"), 0.05)
        XCTAssertGreaterThan(try workspace.meanGrayValue(image: frame, crop: "30x30+30+65"), 0.05)
    }

    func testShortBuildsOnlyPortraitMP4FromDirectImageAndAudio() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])

        let image = try workspace.createImage(name: "poster", ext: "png", width: 320, height: 180)
        let sourceFLAC = try workspace.createAudio(name: "song", ext: "flac", duration: 2.4)
        let tool = try workspace.makeTool(arguments: ["-short"])

        try tool.stepShort()

        let shortVideo = workspace.output.appendingPathComponent("song_8K_Short.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortVideo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFLAC.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("song_8K.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("song.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("song.mp3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("poster_8K.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("poster_NFT8K.png").path))

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
        try tool.verifyALACAudioOutput(shortVideo, sampleRate: tool.config.shortMP4AudioSampleRate, channels: 2, qcPolicy: nil)
        try tool.verifySourceLoudnessPreserved(source: sourceFLAC, output: shortVideo, toleranceDB: 1.0)
        let frame = try workspace.extractFirstVideoFrame(from: shortVideo, name: "short_only_frame")
        XCTAssertLessThan(try workspace.meanGrayValue(image: frame, crop: "90x10+0+0"), 0.05)
        XCTAssertLessThan(try workspace.meanGrayValue(image: frame, crop: "90x10+0+150"), 0.05)
        XCTAssertGreaterThan(try workspace.meanGrayValue(image: frame, crop: "30x30+30+65"), 0.05)
    }

    func testShortBuildsLongSongFullSongVariant() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])

        let image = try workspace.createImage(name: "poster", ext: "png", width: 320, height: 180)
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig +
                "\nSHORT_MP4_CLIP_SECONDS=58\n"
        )
        let sourceAudio = try workspace.createAudio(name: "song", ext: "mp3", duration: 90.0)
        let tool = try workspace.makeTool(arguments: ["-short"])

        try tool.stepShort()

        let shortVideo = workspace.output.appendingPathComponent("song_8K_Short.mp4")
        let fullSongShort = workspace.output.appendingPathComponent("song_8K_Short_FullSong.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortVideo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fullSongShort.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))

        let shortClipSeconds = try tool.configuredShortClipSeconds()
        try tool.verifyDuration(shortVideo, expectedSeconds: shortClipSeconds, label: "portrait short mp4", tolerance: 0.3)
        let shortDuration = try XCTUnwrap(tool.mediaDuration(shortVideo))
        let fullDuration = try XCTUnwrap(tool.mediaDuration(fullSongShort))
        XCTAssertEqual(shortDuration, shortClipSeconds, accuracy: 0.3)
        XCTAssertGreaterThan(fullDuration, shortDuration)
        XCTAssertGreaterThan(fullDuration, shortDuration + 20)

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
        try tool.verifyVideoOutput(
            fullSongShort,
            width: tool.config.shortMP4ScaleW,
            height: tool.config.shortMP4ScaleH,
            codec: tool.config.shortMP4VerifyCodec,
            pixelFormat: tool.config.shortMP4PixelFormat,
            colorPrimaries: tool.config.videoColorPrimaries,
            colorTransfer: tool.config.videoColorTransfer,
            colorSpace: tool.config.videoColorSpace,
            colorRange: tool.config.videoColorRange
        )
        try tool.verifyALACAudioOutput(shortVideo, sampleRate: tool.config.shortMP4AudioSampleRate, channels: 2, qcPolicy: nil)
        try tool.verifyALACAudioOutput(fullSongShort, sampleRate: tool.config.shortMP4AudioSampleRate, channels: 2, qcPolicy: nil)
        try tool.verifySourceLoudnessPreserved(source: sourceAudio, output: shortVideo)
        try tool.verifySourceLoudnessPreserved(source: sourceAudio, output: fullSongShort)
    }

    func testShortAcceptsGenericAudioOnlyInputFormat() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])

        _ = try workspace.createImage(name: "poster", ext: "png", width: 320, height: 180)
        let sourceAAC = try workspace.createAudio(name: "song", ext: "aac", duration: 2.4)
        let tool = try workspace.makeTool(arguments: ["-short"])

        try tool.stepShort()

        let shortVideo = workspace.output.appendingPathComponent("song_8K_Short.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortVideo.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("song.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("song_8K.mp4").path))
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
        try tool.verifyALACAudioOutput(shortVideo, sampleRate: tool.config.shortMP4AudioSampleRate, channels: 2, qcPolicy: nil)
        try tool.verifySourceLoudnessPreserved(source: sourceAAC, output: shortVideo, toleranceDB: 1.0)
    }

    func testNFTToShortAcceptsPortrait8KPNGWithoutLandscapeMainRender() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])

        _ = try workspace.createImage(
            name: "Vertical_8K",
            ext: "png",
            width: 90,
            height: 160
        )
        let sourceFLAC = try workspace.createAudio(name: "song", ext: "flac", duration: 2.4)
        let tool = try workspace.makeTool(arguments: ["-nfttoshort"])

        try tool.stepNFTToShort()

        let portraitImage = workspace.output.appendingPathComponent("Vertical_8K.png")
        let mainVideo = workspace.output.appendingPathComponent("song_8K.mp4")
        let shortVideo = workspace.output.appendingPathComponent("song_8K_Short.mp4")

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFLAC.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: portraitImage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mainVideo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortVideo.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("song.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("song.mp3").path))

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
        try tool.verifyALACAudioOutput(shortVideo, sampleRate: tool.config.shortMP4AudioSampleRate, channels: 2, qcPolicy: nil)
        try tool.verifySourceLoudnessPreserved(source: sourceFLAC, output: shortVideo, toleranceDB: 1.0)
        XCTAssertNoThrow(try tool.requireVideoStream(shortVideo))
        try tool.verifyDuration(shortVideo, expectedSeconds: 1.0, label: "portrait short mp4")
    }

    // audit #0015: clipped samples are a per-sample count, so the source and the render only
    // compare when both are measured at the same sample rate. The source clip used to be
    // measured on the 96 kHz staging decode while the render is judged at its own 48 kHz: a
    // 96 kHz source reported 13x the render's clipped samples (ceiling far too loose), and a
    // hot MP3 reported fewer than its render (spurious failure). The rebased ceiling must equal
    // what the same segment measures once decoded the way the render's audio is decoded.
    func testClippedSampleCeilingIsRebasedInTheRenderDomain() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        try workspace.overwriteConfig(IntegrationWorkspace.defaultConfig + "\nAUDIO_QC_MAX_CLIPPED_SAMPLES=0\n")
        let source = try workspace.createClippedAudio(name: "clipped96k", sampleRate: 96_000, duration: 6.0)
        let tool = try workspace.makeTool(arguments: ["-short"])

        // The render's audio: the leading 2 s through the internal WAV standard, then 48 kHz.
        let renderDomain = workspace.output.appendingPathComponent("render_domain.wav")
        let staged = try tool.makeInternalWAV(
            from: source, in: workspace.output, stem: "clipped96k.staged", duration: 2.0
        )
        _ = try workspace.runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-i", staged.path, "-map", "0:a:0", "-ac", "2", "-ar", "48000", "-c:a", "pcm_s24le",
            "-f", "wav", "-rf64", "always", renderDomain.path
        ])
        let expected = try tool.audioQCResult(for: renderDomain, policy: tool.config.deliveryAudioQCPolicy)
            .metrics.clippedSamples
        XCTAssertGreaterThan(expected, 0, "fixture must actually clip")

        let policy = try tool.loudnessPreservingQCPolicy(
            tool.config.deliveryAudioQCPolicy, source: source, limitDuration: 2.0, sampleRate: 48_000
        )

        XCTAssertEqual(policy.maxClippedSamples, expected)
        XCTAssertTrue(policy.name.hasSuffix("-source-relative"))
    }

    // The user-visible half of #0015. An MP3 decodes to float, so a hot master peaks above
    // 0 dBFS on a handful of samples (here 21 across the file, 0.4 dB over); the 24-bit render
    // clips every one of those crests to full scale and measures tens of thousands. Measured
    // raw, the source set a ceiling of 21 and the faithful render failed QC — on a path where
    // only -master / -loudness may alter the audio. The clip cap covers the whole file so the
    // comparison takes the whole-source path; the overshoot is small enough that clipping it
    // moves the loudness by 0.1 dB, which is what a real hot master looks like.
    func testShortFromHotMP3IsNotRejectedForClippedSamplesItInherits() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig + "\nAUDIO_QC_MAX_CLIPPED_SAMPLES=0\nSHORT_MP4_CLIP_SECONDS=6\n"
        )
        _ = try workspace.createImage(name: "poster", ext: "png", width: 320, height: 180)
        let source = try workspace.createHotAudio(name: "hot_master", ext: "mp3", duration: 6.0, gainDB: 21.5)
        let tool = try workspace.makeTool(arguments: ["-short"])

        try tool.stepShort()

        let shortVideo = workspace.output.appendingPathComponent("hot_master_8K_Short.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortVideo.path))
        try tool.verifySourceLoudnessPreserved(source: source, output: shortVideo, toleranceDB: 1.0)
    }

    func testNFTToShortPreservesSourceLoudnessOnLandscapePath() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])

        _ = try workspace.createImage(name: "poster", ext: "png", width: 320, height: 180)
        let sourceFLAC = try workspace.createAudio(name: "loud_song", ext: "flac", duration: 6.0)
        let tool = try workspace.makeTool(arguments: ["-nfttoshort"])

        try tool.stepNFTToShort()

        let shortVideo = workspace.output.appendingPathComponent("loud_song_8K_Short.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortVideo.path))
        try tool.verifySourceLoudnessPreserved(source: sourceFLAC, output: shortVideo, toleranceDB: 1.0)
    }

    func testNFTToShortPreservesSourceLoudnessOnPortraitPath() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig +
                "\nAUDIO_QC_MAX_TRUE_PEAK_DBTP=-1\n"
        )

        _ = try workspace.createImage(name: "Vertical_8K", ext: "png", width: 90, height: 160)
        let sourceMP3 = try workspace.createHotAudio(name: "hot_song", ext: "mp3", duration: 6.0, gainDB: 21)
        let tool = try workspace.makeTool(arguments: ["-nfttoshort"])
        // audit #0037: this fixture used to be a plain -21 dBFS sine that never breached -1 dBTP, so
        // the source-relative rebase this test exists to cover never fired. Prove the source is hot
        // before rendering.
        let sourceResult = try tool.audioQCResult(for: sourceMP3, policy: tool.config.deliveryAudioQCPolicy)
        let sourceTruePeak = try XCTUnwrap(sourceResult.metrics.truePeakDBTP)
        XCTAssertGreaterThan(sourceTruePeak, -1, "hot_song must breach AUDIO_QC_MAX_TRUE_PEAK_DBTP=-1")

        XCTAssertNoThrow(try tool.stepNFTToShort())

        let shortVideo = workspace.output.appendingPathComponent("hot_song_8K_Short.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortVideo.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("hot_song.m4a").path))
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
        try tool.verifySourceLoudnessPreserved(source: sourceMP3, output: shortVideo, toleranceDB: 2.0)
    }

    // audit #0037: loudnessPreservingQCPolicy had no direct test of the rebase itself. A hot
    // source that breaches only the true-peak ceiling must get exactly that ceiling rebased to
    // what it measures plus the 0.1 dB rounding allowance and the "-source-relative" name, with
    // every other ceiling carried over from the configured policy untouched.
    func testLoudnessPreservingQCPolicyRebasesOnlyTheBreachedTruePeakCeiling() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        try workspace.overwriteConfig(IntegrationWorkspace.defaultConfig + "\nAUDIO_QC_MAX_TRUE_PEAK_DBTP=-1\n")
        let source = try workspace.createHotAudio(name: "hot48k", ext: "wav", duration: 6.0, gainDB: 20.5)
        let tool = try workspace.makeTool(arguments: ["-short"])
        let policy = tool.config.deliveryAudioQCPolicy
        XCTAssertEqual(policy.maxTruePeakDBTP, -1)

        let sourceResult = try tool.audioQCResult(for: source, policy: policy)
        let measured = try XCTUnwrap(sourceResult.metrics.truePeakDBTP)
        XCTAssertGreaterThan(measured, -1, "fixture must breach the true-peak ceiling")
        XCTAssertEqual(sourceResult.metrics.clippedSamples, 0, "fixture must breach nothing but the true peak")

        let rebased = try tool.loudnessPreservingQCPolicy(policy, source: source, sampleRate: 48_000)

        XCTAssertEqual(rebased.name, "delivery-source-relative")
        XCTAssertEqual(rebased.maxTruePeakDBTP, measured + 0.1, accuracy: 0.01)
        XCTAssertEqual(rebased.targetLUFS, policy.targetLUFS)
        XCTAssertEqual(rebased.lufsTolerance, policy.lufsTolerance)
        XCTAssertEqual(rebased.maxLoudnessRange, policy.maxLoudnessRange)
        XCTAssertEqual(rebased.maxDCOffset, policy.maxDCOffset)
        XCTAssertEqual(rebased.maxStereoImbalanceDB, policy.maxStereoImbalanceDB)
        XCTAssertEqual(rebased.maxClippedSamples, policy.maxClippedSamples)
        XCTAssertEqual(rebased.minimumAnalysisSeconds, policy.minimumAnalysisSeconds)
    }

    // audit #0037: a source that respects every ceiling must come back as the very policy it was
    // given — same name, no widened tolerance — so a clean render is still held to the configured
    // absolute limits rather than to whatever its source happened to measure.
    func testLoudnessPreservingQCPolicyReturnsTheInputPolicyForACleanSource() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        try workspace.overwriteConfig(IntegrationWorkspace.defaultConfig + "\nAUDIO_QC_MAX_TRUE_PEAK_DBTP=-1\n")
        let source = try workspace.createAudio(name: "clean48k", ext: "wav", duration: 6.0)
        let tool = try workspace.makeTool(arguments: ["-short"])
        let policy = tool.config.deliveryAudioQCPolicy

        let sourceResult = try tool.audioQCResult(for: source, policy: policy)
        let measured = try XCTUnwrap(sourceResult.metrics.truePeakDBTP)
        XCTAssertLessThan(measured, -1, "fixture must respect the true-peak ceiling")
        XCTAssertTrue(sourceResult.passed, "fixture must respect every ceiling: \(sourceResult.issues)")

        let result = try tool.loudnessPreservingQCPolicy(policy, source: source, sampleRate: 48_000)

        XCTAssertEqual(result, policy)
        XCTAssertEqual(result.name, "delivery")
    }

    // audit #0037: `limitDuration` must select exactly the leading seconds of the source — the
    // segment a short inherits — never the whole track. The fixture is quiet for its first 1.5 s
    // and hot (about -0.6 dBTP) afterwards: measured to 1 s it respects -1 dBTP and the policy
    // comes back untouched; measured to 2 s or in full, the hot material sits inside the window
    // and the true-peak ceiling is rebased on it.
    func testLoudnessPreservingQCPolicyMeasuresOnlyTheLeadingLimitDurationSeconds() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        try workspace.overwriteConfig(IntegrationWorkspace.defaultConfig + "\nAUDIO_QC_MAX_TRUE_PEAK_DBTP=-1\n")
        let source = workspace.output.appendingPathComponent("quiet_then_hot.wav")
        _ = try workspace.runner().run("ffmpeg", [
            "-hide_banner", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi",
            "-i", "sine=frequency=440:duration=6.0:sample_rate=48000",
            "-ac", "2",
            "-af", "volume=20.5dB:enable='gte(t,1.5)'",
            "-c:a", "pcm_f32le", "-ar", "48000", "-f", "wav", "-rf64", "always", source.path
        ])
        let tool = try workspace.makeTool(arguments: ["-short"])
        let policy = tool.config.deliveryAudioQCPolicy

        func renderDomainTruePeak(limitDuration: Double?) throws -> Double {
            let result = try tool.renderDomainQCResult(
                for: source, policy: policy, limitDuration: limitDuration, sampleRate: 48_000
            )
            return try XCTUnwrap(result.metrics.truePeakDBTP)
        }
        let leadingSecond = try renderDomainTruePeak(limitDuration: 1.0)
        let leadingTwoSeconds = try renderDomainTruePeak(limitDuration: 2.0)
        let wholeFile = try renderDomainTruePeak(limitDuration: nil)
        XCTAssertLessThan(leadingSecond, -1, "the leading second must respect the ceiling")
        XCTAssertGreaterThan(leadingTwoSeconds, -1, "the second second must breach the ceiling")
        XCTAssertEqual(leadingTwoSeconds, wholeFile, accuracy: 0.01)

        let limited = try tool.loudnessPreservingQCPolicy(
            policy, source: source, limitDuration: 1.0, sampleRate: 48_000
        )
        XCTAssertEqual(limited, policy, "a 1 s short inherits only quiet material")
        XCTAssertEqual(limited.name, "delivery")

        let overlapping = try tool.loudnessPreservingQCPolicy(
            policy, source: source, limitDuration: 2.0, sampleRate: 48_000
        )
        XCTAssertEqual(overlapping.name, "delivery-source-relative")
        XCTAssertEqual(overlapping.maxTruePeakDBTP, leadingTwoSeconds + 0.1, accuracy: 0.01)

        let full = try tool.loudnessPreservingQCPolicy(
            policy, source: source, limitDuration: nil, sampleRate: 48_000
        )
        XCTAssertEqual(full.name, "delivery-source-relative")
        XCTAssertEqual(full.maxTruePeakDBTP, wholeFile + 0.1, accuracy: 0.01)
    }

    func testNFTToShortComparesAgainstTrimmedSourceSegmentLoudness() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig +
                "\nSHORT_MP4_CLIP_SECONDS=1\n"
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

        let tool = try workspace.makeTool(arguments: ["-nfttoshort"])
        try tool.stepNFTToShort()

        let shortVideo = workspace.output.appendingPathComponent("dynamic_loudness_8K_Short.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortVideo.path))
        try tool.verifySourceLoudnessPreserved(source: sourceMP3, output: shortVideo, toleranceDB: 1.0)
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
        let wav = try tool.convertAudioToWAV(delayed)
        try tool.verifyWAVStandard(wav)
    }

    // audit #0013: astats reports "-inf" RMS for a silent channel; that channel used to be
    // dropped from the comparison, so a dead channel scored as perfect balance.
    func testSilentChannelIsReportedAsStereoImbalance() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        let input = try workspace.createOneChannelSilentAudio(name: "one_channel_silent")
        let tool = try workspace.makeTool(arguments: ["-loudscan"])
        let policy = AudioQCPolicy(
            name: "balance-only", targetLUFS: -12, lufsTolerance: 99, maxTruePeakDBTP: 0, maxLoudnessRange: 50,
            maxDCOffset: 1, maxStereoImbalanceDB: 0.1, maxClippedSamples: 1_000_000, minimumAnalysisSeconds: 0.1)
        let result = try tool.audioQCResult(for: input, policy: policy)
        XCTAssertFalse(result.passed, "a dead channel must fail the balance ceiling: \(result.issues)")
        XCTAssertTrue(result.issues.contains { $0.contains("stereo imbalance") }, "\(result.issues)")
    }

    func testRejectsStereoImbalancedOutputWhenPolicyIsStrict() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig + "\nAUDIO_QC_MAX_STEREO_IMBALANCE_DB=0.10\n"
        )
        let input = try workspace.createStereoImbalancedAudio(name: "imbalanced", ext: "wav")
        let tool = try workspace.makeTool(arguments: ["-wavtom4a"])

        let output = try tool.convertAudioToM4A(input)
        XCTAssertThrowsError(try tool.verifyAudioQC(output, policy: tool.config.deliveryAudioQCPolicy)) { error in
            XCTAssertTrue(error.localizedDescription.contains("stereo imbalance"))
        }
    }

    func testWAVToM4AAcceptsNonStandardRIFFInput() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        let riff = try workspace.createPlainRIFFWAV(name: "plain_input")
        let tool = try workspace.makeTool(arguments: ["-wavtom4a"])
        let output = try tool.convertAudioToM4A(riff)

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
        let tool = try workspace.makeTool(arguments: ["-full"])

        // The full run always hands over a release stem distinct from the source's own stem.
        let artifacts = try await tool.fullAudioPreparation(sourceAudio: riff, releaseStem: "wav_release")

        XCTAssertEqual(try tool.audioField(artifacts.wav, "sample_rate"), String(tool.config.wavSampleRate))
        XCTAssertEqual(artifacts.wav.lastPathComponent, "wav_release.wav")
        XCTAssertEqual(try tool.crc32(for: riff), try tool.crc32(for: reference), "the source must stay untouched")

        let rf64FLAC = workspace.output.appendingPathComponent("wav_release_RF64.flac")
        XCTAssertEqual(try tool.audioField(rf64FLAC, "sample_rate"), "44100")
        try tool.verifyCanonicalPCMSampleEquivalence(source: reference, output: rf64FLAC, sampleRate: 44_100, channels: 2, label: "External FLAC", format: .s24le)

        // BW64 is a WAV-only container, so no FLAC counterpart may be emitted.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspace.output.appendingPathComponent("wav_release_BW64.flac").path),
            "BW64 has no FLAC container variant; emitting one would duplicate the RF64 FLAC byte-for-byte."
        )
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

        let artifacts = try await tool.fullAudioPreparation(sourceAudio: mp3, releaseStem: "master_release")
        let rebuiltMP3 = try XCTUnwrap(artifacts.mp3)
        XCTAssertEqual(rebuiltMP3.lastPathComponent, "master_release.mp3")

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

        XCTAssertTrue(

            FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("art_1_8K.png").path))
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

        let tool = try workspace.makeTool(arguments: ["-full"])
        defer { tool.cleanupTemps() }
        try tool.initializeForExecution()
        try await tool.stepFull()

        let allOutputs = try FileManager.default.contentsOfDirectory(at: workspace.output, includingPropertiesForKeys: [.isRegularFileKey], options: [])
        XCTAssertFalse(allOutputs.contains { $0.lastPathComponent.contains(tool.runToken) }, "Run-scoped temp files leaked into Output.")

        // Every generated file — images included — carries the release stem. The run renames its
        // single source audio to `1_source` first, so `1` is the stem, not the incoming filename,
        // and the untouched original sits beside the deliverables.
        // (Byte-for-byte preservation of the source is asserted by testFullRunNeverOverwritesItsMP3Source.)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.output.path + "/1_source.mp3"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("track.mp3").path))
        let prefix = "1"
        let base = "1"
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
            "\(base)_8K.mp4",
            "\(base)_8K_Short.mp4",
            // Portrait stills: the two short framings as artwork, PNG plus sized JPGs.
            "\(prefix)_Short_8K.png",
            "\(prefix)_Short_8K_1MB.jpg",
            "\(prefix)_Short_8K_2MB.jpg",
            "\(prefix)_Short_CenterCut_8K.png",
            "\(prefix)_Short_CenterCut_8K_1MB.jpg",
            "\(prefix)_Short_CenterCut_8K_2MB.jpg"
        ]

        for name in expectedFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent(name).path), "Missing full-run output \(name)")
        }
        // The source artwork keeps its own name; only generated files are renamed.
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("art.png").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("art_8K.png").path),
            "image deliverables must be named after the release, not the artwork file"
        )

        // Regression guard: every shipped archival deliverable must be distinct.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("\(base)_BW64.flac").path),
            "BW64 has no FLAC container variant; emitting one would duplicate the RF64 FLAC byte-for-byte."
        )

        let wavOutput = workspace.output.appendingPathComponent("\(base).wav")
        let m4aOutput = workspace.output.appendingPathComponent("\(base).m4a")
        let mp3Output = workspace.output.appendingPathComponent("\(base).mp3")
        let mp4Output = workspace.output.appendingPathComponent("\(base)_8K.mp4")
        let shortOutput = workspace.output.appendingPathComponent("\(base)_8K_Short.mp4")
        let shortFrame = try workspace.extractFirstVideoFrame(from: shortOutput, name: "full_short_frame")
        try tool.verifyWAVStandard(wavOutput, qcPolicy: nil)
        try tool.verifyM4AFile(m4aOutput, sampleRate: tool.config.m4aSampleRate, channels: tool.config.m4aChannels, qcPolicy: nil)
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
        XCTAssertLessThan(try workspace.meanGrayValue(image: shortFrame, crop: "90x10+0+0"), 0.05)
        XCTAssertLessThan(try workspace.meanGrayValue(image: shortFrame, crop: "90x10+0+150"), 0.05)
    }

    func testFullPipelineProducesFullSongShortForLongSourceAudio() async throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])

        _ = try workspace.createImage(name: "art", ext: "png")
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig +
                "\nSHORT_MP4_CLIP_SECONDS=58\n"
        )
        _ = try workspace.createAudio(name: "track", ext: "mp3", duration: 90.0)
        let tool = try workspace.makeTool(arguments: ["-full"])
        defer { tool.cleanupTemps() }
        try tool.initializeForExecution()
        try await tool.stepFull()

        let shortOutput = workspace.output.appendingPathComponent("1_8K_Short.mp4")
        let fullSongShortOutput = workspace.output.appendingPathComponent("1_8K_Short_FullSong.mp4")

        XCTAssertTrue(FileManager.default.fileExists(atPath: shortOutput.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fullSongShortOutput.path))
        let shortClipSeconds = try tool.configuredShortClipSeconds()
        try tool.verifyDuration(shortOutput, expectedSeconds: shortClipSeconds, label: "short short", tolerance: 0.3)

        let shortDuration = try XCTUnwrap(tool.mediaDuration(shortOutput))
        let fullSongDuration = try XCTUnwrap(tool.mediaDuration(fullSongShortOutput))
        XCTAssertEqual(shortDuration, shortClipSeconds, accuracy: 0.3)
        XCTAssertGreaterThan(fullSongDuration, shortDuration + 20)

        // The run renamed its source, so compare against the file it actually consumed.
        let renamedSource = workspace.output.appendingPathComponent("1_source.mp3")
        try tool.verifySourceLoudnessPreserved(source: renamedSource, output: fullSongShortOutput)
        try tool.verifySourceLoudnessPreserved(source: renamedSource, output: shortOutput)
    }

    func testFullPipelineUsesNamedHorizontalAndVertical8KPNGs() async throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])

        _ = try workspace.createImage(name: "Horizontal_8K", ext: "png", width: 320, height: 180)
        _ = try workspace.createImage(name: "Vertical_8K", ext: "png", width: 90, height: 160)
        _ = try workspace.createAudio(name: "463406_B_PH", ext: "flac")

        let tool = try workspace.makeTool(arguments: ["-full"])
        defer { tool.cleanupTemps() }
        try tool.initializeForExecution()
        try await tool.stepFull()

        // The run renames its source audio to `1`, so that names the release here too.
        let base = "1"
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("1_source.flac").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.output.appendingPathComponent("463406_B_PH.flac").path))
        let mainOutput = workspace.output.appendingPathComponent("\(base)_8K").appendingPathExtension("mp4")
        let shortOutput = workspace.output.appendingPathComponent("\(base)_8K_Short").appendingPathExtension("mp4")

        XCTAssertTrue(FileManager.default.fileExists(atPath: mainOutput.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortOutput.path))
        // Deliverables are named after the release even when the inputs are the named 8K PNGs.
        let expectedImageFiles = [
            "\(base)_4K.png",
            "\(base)_3K.png",
            "\(base)_2K.png",
            "\(base)_NFT8K.png",
            "\(base)_NFT3K.png",
            "\(base)_NFT2K.png",
            "\(base)_8K_1MB.jpg",
            "\(base)_8K_2MB.jpg",
            "\(base)_8K_20MB.jpg",
            "\(base)_3K_1MB.jpg",
            "\(base)_3K_5MB.jpg"
        ]
        for name in expectedImageFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent(name).path),
                "Missing direct-8K image deliverable \(name)"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("Horizontal_4K.png").path),
            "Direct Horizontal_8K.png input should not be reprocessed as a generic source image."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("Horizontal_8K_NFT8K.png").path),
            "Direct Horizontal_8K.png input should use stripped derivative naming for NFT images."
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
        let renamedSource = workspace.output.appendingPathComponent("1_source.flac")
        try tool.verifySourceLoudnessPreserved(source: renamedSource, output: mainOutput)
        try tool.verifySourceLoudnessPreserved(source: renamedSource, output: shortOutput)
        let shortFrame = try workspace.extractFirstVideoFrame(from: shortOutput, name: "full_vertical_short_frame")
        XCTAssertGreaterThan(
            try workspace.meanGrayValue(image: shortFrame, crop: "90x10+0+0"),
            0.05,
            "Existing Vertical_8K.png should fill the top of the short frame without black NFT padding."
        )
        XCTAssertGreaterThan(
            try workspace.meanGrayValue(image: shortFrame, crop: "90x10+0+150"),
            0.05,
            "Existing Vertical_8K.png should fill the bottom of the short frame without black NFT padding."
        )

        tool.cleanupTemps()
        XCTAssertTrue(FileManager.default.fileExists(atPath: mainOutput.path), "Main MP4 should remain after temp cleanup.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shortOutput.path), "Short MP4 should remain after temp cleanup.")
    }

    func testAlbumPipelineSortsMixedAudioNormalizesAndContinuesFullRun() async throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])

        _ = try workspace.createImage(name: "Horizontal_8K", ext: "png", width: 320, height: 180)
        _ = try workspace.createImage(name: "Vertical_8K", ext: "png", width: 90, height: 160)
        _ = try workspace.createHotAudio(name: "10 - Storm", ext: "flac", duration: 1.2, frequency: 660, gainDB: -6)
        _ = try workspace.createHotAudio(name: "1 - Sun", ext: "mp3", duration: 1.2, frequency: 330, gainDB: 6)
        _ = try workspace.createHotAudio(name: "2 - Rain", ext: "wav", duration: 1.2, frequency: 440, gainDB: 0)

        let tool = try workspace.makeTool(arguments: ["-album"])
        defer { tool.cleanupTemps() }
        try tool.initializeForExecution()
        XCTAssertEqual(try tool.albumAudioCandidates().map(\.lastPathComponent), ["1 - Sun.mp3", "2 - Rain.wav", "10 - Storm.flac"])

        try await tool.stepAlbum()

        let expectedFiles = [
            "album.wav",
            "album.m4a",
            "album.mp3",
            "album_RF64.wav",
            "album_BW64.wav",
            "album_RF64.flac",
            "album_8K.mp4",
            "album_8K_Short.mp4"
        ]
        for name in expectedFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent(name).path), "Missing album pipeline output \(name)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("album_BW64.flac").path),
            "BW64 has no FLAC container variant; emitting one would duplicate the RF64 FLAC byte-for-byte."
        )

        let albumWAV = workspace.output.appendingPathComponent("album.wav")
        let mainOutput = workspace.output.appendingPathComponent("album_8K.mp4")
        let shortOutput = workspace.output.appendingPathComponent("album_8K_Short.mp4")
        try tool.verifyWAVStandard(albumWAV, qcPolicy: tool.loudnessPolicy(targetLUFS: -12, tolerance: 3))
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

        let allFiles = try FileManager.default.contentsOfDirectory(at: workspace.output, includingPropertiesForKeys: [.isRegularFileKey], options: [])
        XCTAssertFalse(allFiles.contains { $0.lastPathComponent.contains("album.track") }, "Album track normalization temps leaked into Output.")
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
                "\nMASTERING_TARGET_LUFS=-12\n"
        )
        let wav = try workspace.createHotAudio(name: "too_hot", ext: "wav", duration: 3.0, gainDB: 24)
        let tool = try workspace.makeTool(arguments: ["-wavtom4a"])

        let before = try tool.audioQCResult(for: wav, policy: tool.config.masteringAudioQCPolicy)
        XCTAssertFalse(before.passed, "Hot fixture should force mastering fallback.")

        XCTAssertNoThrow(try tool.masterCanonicalWAVInPlaceIfNeeded(wav))
        XCTAssertNoThrow(try tool.verifyWAVStandard(wav, qcPolicy: tool.config.masteringAudioQCPolicy))
    }

    func testMasterCommandProducesMasteredOutputsWithinPolicy() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig +
                "\nMASTERING_TARGET_LUFS=-40\n"
        )
        _ = try workspace.createAudio(name: "needs_master", ext: "wav", duration: 4.5)
        let tool = try workspace.makeTool(arguments: ["-master"])

        try tool.stepMaster()

        let output = workspace.output.appendingPathComponent("needs_master_mastered.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        try tool.verifyWAVStandard(output, qcPolicy: tool.config.masteringAudioQCPolicy)
        let after = try tool.audioQCResult(for: output, policy: tool.config.masteringAudioQCPolicy)
        XCTAssertTrue(after.passed, "Mastered output must pass the mastering policy: \(after.issues)")
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

    func testShortRendersNarrowPortraitMP4Inputs() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        try workspace.overwriteConfig(
            IntegrationWorkspace.defaultConfig +
                "\nSHORT_MP4_CLIP_SECONDS=58\n"
        )

        // 9:24 portrait is narrower than 9:16; the crop width must clamp to the input width.
        let source = try workspace.createVideoMP4(name: "tall_source", duration: 3.0, width: 240, height: 640)
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
        try tool.verifyDuration(short, expectedSeconds: 3.0, label: "narrow portrait short mp4", tolerance: 0.25)
    }

    func testRejectsEmptyAudioInputWithoutPublishingOutputs() throws {
        let workspace = try IntegrationWorkspace()
        let empty = try workspace.writeEmptyFile(name: "empty_song", ext: "wav")
        let tool = try workspace.makeTool(arguments: ["-wavtomp3"])
        XCTAssertThrowsError(try tool.convertAudioToMP3(empty)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Audio input empty") || message.contains("WAV header too short"), "Unexpected error: \(message)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("empty_song.mp3").path))
    }

    func testRejectsEmptyImageInputWithoutPublishingOutputs() throws {
        let workspace = try IntegrationWorkspace()
        let empty = try workspace.writeEmptyFile(name: "empty_graphic", ext: "png")
        let tool = try workspace.makeTool(arguments: ["-pngtojpg"])
        XCTAssertThrowsError(try tool.convertPNGToJPEG(empty, outputExtension: "jpg")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Image input empty"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("empty_graphic.jpg").path))
    }

    // audit #0017: a listed track that cannot be found is an error, not a warning — a typo in
    // album.txt used to publish a shorter album with exit 0. Under --continue-on-error the
    // album is still built from what resolves, and the run ends with the failure summary.
    func testAlbumFileFailsClosedOnMissingTracksUnlessContinueOnError() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])

        _ = try workspace.createAudio(name: "track01", ext: "wav")
        _ = try workspace.createAudio(name: "track02", ext: "wav", frequency: 554)
        try workspace.writeAlbum(["track01", "missing_track", "track02"])
        let albumOutput = workspace.output.appendingPathComponent("album.rf64.wav")

        let strict = try workspace.makeTool(arguments: ["-wavtoalbum"])
        let albumName = "album.rf64.wav"
        XCTAssertThrowsError(
            try strict.buildAlbumFromAlbumFile(extension: "wav", defaultOutputName: albumName)
        ) { error in
            XCTAssertTrue("\(error)".contains("missing_track"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: albumOutput.path), "no album on a failed entry")

        let lenient = try workspace.makeTool(arguments: ["-wavtoalbum", "--continue-on-error"])
        XCTAssertThrowsError(
            try lenient.buildAlbumFromAlbumFile(extension: "wav", defaultOutputName: albumName)
        ) { error in
            XCTAssertTrue("\(error)".contains("missing_track"), "\(error)")
            XCTAssertTrue("\(error)".contains("1 album entr"), "\(error)")
        }
        try lenient.verifyWAVStandard(albumOutput)
        let track01 = workspace.output.appendingPathComponent("track01.wav")
        let track02 = workspace.output.appendingPathComponent("track02.wav")
        let expectedSeconds = (try lenient.mediaDuration(track01) ?? 0) + (try lenient.mediaDuration(track02) ?? 0)
            + Double(lenient.config.albumSilenceSecs)
        try lenient.verifyDuration(albumOutput, expectedSeconds: expectedSeconds, label: "album wav", tolerance: 0.5)
    }

    // audit #0018: cleaning metadata must not touch the audio. The MPEG frames are stream-copied,
    // so the result decodes sample-for-sample identically and keeps its own sample rate.
    func testMP3CleanIsAStreamCopyThatPreservesTheAudio() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])
        let tagged = try workspace.createMP3WithArtwork(name: "tagged_441", sampleRate: 44_100)
        let reference = workspace.root.appendingPathComponent("tagged_441_reference.mp3")
        try FileManager.default.copyItem(at: tagged, to: reference)
        let tool = try workspace.makeTool(arguments: ["-mp3clean"])

        XCTAssertNoThrow(try tool.requireVideoStream(tagged), "fixture must carry artwork before cleaning")
        try tool.cleanMP3(tagged)
        XCTAssertThrowsError(try tool.requireVideoStream(tagged), "artwork stream must be gone")
        XCTAssertEqual(try tool.audioField(tagged, "sample_rate"), "44100", "a clean must not resample")
        try tool.verifyCanonicalPCMSampleEquivalence(
            source: reference, output: tagged, sampleRate: 44_100, channels: 2, label: "Cleaned MP3", format: .s24le)
    }

    // audit #0007: a 44.1 kHz MP3 is not a standard deliverable, so the run must build 1.mp3 from
    // it — without ever writing onto the source. The source is preserved byte-for-byte under the
    // release's `_source` name.
    func testFullRunNeverOverwritesItsMP3Source() async throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])
        _ = try workspace.createImage(name: "art", ext: "png")
        let sourceMP3 = try workspace.createAudio(name: "track", ext: "mp3", sampleRate: 44_100)
        let reference = workspace.root.appendingPathComponent("track_reference.mp3")
        try FileManager.default.copyItem(at: sourceMP3, to: reference)

        let tool = try workspace.makeTool(arguments: ["-full"])
        defer { tool.cleanupTemps() }
        try tool.initializeForExecution()
        try await tool.stepFull()

        let preserved = workspace.output.appendingPathComponent("1_source.mp3")
        let deliverable = workspace.output.appendingPathComponent("1.mp3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path), "source must survive as 1_source.mp3")
        XCTAssertEqual(try tool.crc32(for: preserved), try tool.crc32(for: reference), "source bytes must be untouched")
        try tool.verifyMP3Standard(deliverable, qcPolicy: nil)
        try tool.verifySourceLoudnessPreserved(source: reference, output: deliverable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("track.mp3").path))
    }

    // audit #0023: a plain 16-bit/44.1 kHz RIFF WAV used to be normalised in place, destroying the
    // only original. The original must survive untouched and the archival FLAC must be bit-exact
    // against it.
    func testFullRunNeverOverwritesItsWAVSource() async throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])
        _ = try workspace.createImage(name: "art", ext: "png")
        let sourceWAV = try workspace.createPlainRIFFWAV(name: "track")
        let reference = workspace.root.appendingPathComponent("track_reference.wav")
        try FileManager.default.copyItem(at: sourceWAV, to: reference)

        let tool = try workspace.makeTool(arguments: ["-full"])
        defer { tool.cleanupTemps() }
        try tool.initializeForExecution()
        try await tool.stepFull()

        let preserved = workspace.output.appendingPathComponent("1_source.wav")
        let deliverable = workspace.output.appendingPathComponent("1.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path), "source must survive as 1_source.wav")
        XCTAssertEqual(try tool.crc32(for: preserved), try tool.crc32(for: reference), "source bytes must be untouched")
        try tool.verifyWAVStandard(deliverable, qcPolicy: nil)
        try tool.verifyCanonicalPCMSampleEquivalence(
            source: preserved,
            output: workspace.output.appendingPathComponent("1_RF64.flac"),
            label: "External FLAC",
            format: .s24le
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("track.wav").path))
    }

    // audit #0008: in an album run --output-file names the album WAV and nothing else; the main
    // MP4 must keep its own <stem>_8K.mp4 name instead of being published over the WAV.
    func testAlbumRunKeepsOutputFileForTheAlbumWAVOnly() async throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe", "magick"])
        _ = try workspace.createImage(name: "art", ext: "png")
        _ = try workspace.createAudio(name: "01", ext: "wav", duration: 1.0)
        _ = try workspace.createAudio(name: "02", ext: "wav", duration: 1.0, frequency: 660)

        let tool = try workspace.makeTool(arguments: ["-album", "--output-file", "MyAlbum.wav"])
        defer { tool.cleanupTemps() }
        try tool.initializeForExecution()
        try await tool.stepAlbum()

        let album = workspace.output.appendingPathComponent("MyAlbum.wav")
        try tool.verifyWAVStandard(album, qcPolicy: nil)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("MyAlbum_8K.mp4").path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent("MyAlbum.m4a").path))
    }

    // audit #0031: IntegrationWorkspace handed ProcessInfo's environment straight to CLIOptions.parse,
    // ProjectConfig.load and ProcessRunner, and makeTool never pinned --output-dir/--config, so
    // OUTPUT_DIR/SRC_DIR/OUT_DIR/CONFIG_FILE/DEBUG exported in a developer's shell redirected every
    // integration test at real user directories. The workspace must drop those keys, keep everything
    // else (PATH above all) and resolve every path inside the temporary workspace.
    func testWorkspaceIgnoresHostDirectoryAndDebugOverrides() throws {
        var poisoned = ProcessInfo.processInfo.environment
        poisoned["OUTPUT_DIR"] = "/nonexistent"
        poisoned["SRC_DIR"] = "/nonexistent"
        poisoned["OUT_DIR"] = "/nonexistent"
        poisoned["CONFIG_FILE"] = "/nonexistent/config.txt"
        poisoned["DEBUG"] = "1"
        // ProjectConfig.load lets any supported config key in the environment override config.txt.
        poisoned["PROFILE"] = "fast_preview"
        poisoned["AUDIO_QC_TARGET_LUFS"] = "-5"
        poisoned["CONVERTER_TEST_MARKER"] = "kept"

        let workspace = try IntegrationWorkspace(inheritedEnvironment: poisoned)
        for key in ["OUTPUT_DIR", "SRC_DIR", "OUT_DIR", "CONFIG_FILE", "DEBUG", "PROFILE", "AUDIO_QC_TARGET_LUFS"] {
            XCTAssertNil(workspace.environment[key], "\(key) leaked into the workspace environment")
        }
        XCTAssertEqual(workspace.environment["PATH"], poisoned["PATH"])
        XCTAssertEqual(workspace.environment["CONVERTER_TEST_MARKER"], "kept")

        let tool = try workspace.makeTool(arguments: ["-help"])
        XCTAssertEqual(tool.cli.outDir.path, workspace.output.path)
        XCTAssertEqual(tool.cli.srcDir.path, workspace.output.path)
        XCTAssertEqual(tool.cli.configFile.path, workspace.root.appendingPathComponent("config.txt").path)
        XCTAssertFalse(tool.cli.debug)
        XCTAssertNil(tool.environment["DEBUG"])
        XCTAssertEqual(tool.environment["PATH"], poisoned["PATH"])
        XCTAssertEqual(tool.config.profileName, "youtube_master")
        XCTAssertEqual(tool.config.audioQCTargetLUFS, -12)
    }

    // audit #0035: --continue-on-error batch semantics. a.wav / b.wav (garbage) / c.wav are
    // discovered in that order (localizedStandardCompare), so the middle file is the one that fails.
    private struct GarbageMiddleBatch {
        let first: URL
        let broken: URL
        let last: URL
    }

    private func makeBatchWithGarbageMiddleFile(_ workspace: IntegrationWorkspace) throws -> GarbageMiddleBatch {
        GarbageMiddleBatch(
            first: try workspace.createAudio(name: "a", ext: "wav", duration: 1.0),
            broken: try workspace.writeGarbageFile(name: "b", ext: "wav"),
            last: try workspace.createAudio(name: "c", ext: "wav", duration: 1.0, frequency: 660)
        )
    }

    private func outputExists(_ name: String, in workspace: IntegrationWorkspace) -> Bool {
        FileManager.default.fileExists(atPath: workspace.output.appendingPathComponent(name).path)
    }

    // audit #0035: with --continue-on-error, processBatch must keep going past the broken file,
    // convert every remaining file, and still fail at the end with the "<n> operation(s) failed." summary.
    func testWAVToMP3ContinueOnErrorConvertsRemainingFilesThenSummarizes() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        _ = try makeBatchWithGarbageMiddleFile(workspace)
        let tool = try workspace.makeTool(arguments: ["-wavtomp3", "--continue-on-error"])

        XCTAssertThrowsError(try tool.stepWAVToMP3()) { error in
            XCTAssertEqual(error.localizedDescription, "1 operation(s) failed.")
        }

        XCTAssertTrue(outputExists("a.mp3", in: workspace), "a.mp3 must be produced before the failure")
        XCTAssertTrue(outputExists("c.mp3", in: workspace), "c.mp3 must be produced after the failure")
        XCTAssertFalse(outputExists("b.mp3", in: workspace), "garbage b.wav must not yield b.mp3")
        XCTAssertNoThrow(try tool.verifyMP3Standard(workspace.output.appendingPathComponent("a.mp3"), qcPolicy: nil))
        XCTAssertNoThrow(try tool.verifyMP3Standard(workspace.output.appendingPathComponent("c.mp3"), qcPolicy: nil))
    }

    // audit #0035: without --continue-on-error the first failure must abort the batch: the original
    // error propagates (no summary) and files after the broken one are never processed.
    func testWAVToMP3StopsAtFirstFailureWithoutContinueOnError() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        _ = try makeBatchWithGarbageMiddleFile(workspace)
        let tool = try workspace.makeTool(arguments: ["-wavtomp3"])

        XCTAssertThrowsError(try tool.stepWAVToMP3()) { error in
            let message = error.localizedDescription
            XCTAssertFalse(message.contains("operation(s) failed"), "fail-fast must rethrow the original: \(message)")
            XCTAssertTrue(message.contains("b.wav"), "the original error must name the broken file: \(message)")
        }

        XCTAssertTrue(outputExists("a.mp3", in: workspace), "a.mp3 must be produced before the failure")
        XCTAssertNoThrow(try tool.verifyMP3Standard(workspace.output.appendingPathComponent("a.mp3"), qcPolicy: nil))
        XCTAssertFalse(outputExists("b.mp3", in: workspace), "garbage b.wav must not yield b.mp3")
        XCTAssertFalse(outputExists("c.mp3", in: workspace), "c.wav must not run after b.wav failed (fail-fast)")
    }

    // audit #0035: stepLoudness has its own loop and summary. With --continue-on-error it must finish
    // the remaining files and report "Loudness normalize failed for 1/3 file(s): b.wav: ...".
    func testLoudnessContinueOnErrorNormalizesRemainingFilesThenSummarizes() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        let batch = try makeBatchWithGarbageMiddleFile(workspace)
        let tool = try workspace.makeTool(arguments: ["-loudness", "--continue-on-error"])
        let policy = tool.loudnessPolicy(targetLUFS: -12)

        XCTAssertThrowsError(try tool.stepLoudness()) { error in
            let message = error.localizedDescription
            let expectedPrefix = "Loudness normalize failed for 1/3 file(s): b.wav: "
            XCTAssertTrue(message.hasPrefix(expectedPrefix), "unexpected summary: \(message)")
            XCTAssertFalse(message.contains("a.wav"), "a.wav succeeded and must not be listed: \(message)")
            XCTAssertFalse(message.contains("c.wav"), "c.wav succeeded and must not be listed: \(message)")
        }

        let firstOut = workspace.output.appendingPathComponent("a_loudness_m12LUFS.wav")
        let lastOut = workspace.output.appendingPathComponent("c_loudness_m12LUFS.wav")
        XCTAssertTrue(outputExists("a_loudness_m12LUFS.wav", in: workspace), "a.wav must be normalized first")
        XCTAssertTrue(outputExists("c_loudness_m12LUFS.wav", in: workspace), "c.wav must be normalized after b")
        XCTAssertFalse(outputExists("b_loudness_m12LUFS.wav", in: workspace), "garbage b.wav must not yield output")
        XCTAssertNoThrow(try tool.verifyLoudnessOutput(firstOut, source: batch.first, policy: policy))
        XCTAssertNoThrow(try tool.verifyLoudnessOutput(lastOut, source: batch.last, policy: policy))
    }

    // audit #0035: without --continue-on-error stepLoudness must stop at b.wav with the per-file
    // message (no "n/total" summary) and leave c.wav untouched.
    func testLoudnessStopsAtFirstFailureWithoutContinueOnError() throws {
        let workspace = try IntegrationWorkspace()
        try workspace.requireCommands(["ffmpeg", "ffprobe"])
        let batch = try makeBatchWithGarbageMiddleFile(workspace)
        let tool = try workspace.makeTool(arguments: ["-loudness"])
        let policy = tool.loudnessPolicy(targetLUFS: -12)

        XCTAssertThrowsError(try tool.stepLoudness()) { error in
            let message = error.localizedDescription
            let expectedPrefix = "Loudness normalize failed for b.wav: "
            XCTAssertTrue(message.hasPrefix(expectedPrefix), "unexpected per-file error: \(message)")
            XCTAssertFalse(message.contains("file(s)"), "fail-fast must not emit the batch summary: \(message)")
        }

        let firstOut = workspace.output.appendingPathComponent("a_loudness_m12LUFS.wav")
        XCTAssertTrue(outputExists("a_loudness_m12LUFS.wav", in: workspace), "a.wav must be normalized first")
        XCTAssertNoThrow(try tool.verifyLoudnessOutput(firstOut, source: batch.first, policy: policy))
        XCTAssertFalse(outputExists("b_loudness_m12LUFS.wav", in: workspace), "garbage b.wav must not yield output")
        XCTAssertFalse(outputExists("c_loudness_m12LUFS.wav", in: workspace), "c.wav must not run after b failed")
    }
}
