import Foundation

// One chunk of a RIFF/RF64/BW64 WAV file, located by walking the chunk list from the header.
// A chunk id is only a chunk id at a chunk boundary: the same four bytes inside a LIST/INFO
// string, a bext description or the samples themselves are text, not structure.
struct RIFFChunk: Hashable, Sendable {
    let chunkID: String
    // Absolute offset of the eight-byte chunk header.
    let headerOffset: UInt64
    // Payload bytes, after the RF64 size placeholder has been resolved through ds64.
    let payloadSize: UInt64
}

// The real 64-bit sizes an RF64/BW64 file keeps in its ds64 chunk, because the 32-bit fields
// in the RIFF header and the data chunk only hold a placeholder once a file exceeds 4 GiB.
private struct Ds64Sizes: Sendable {
    let dataSize: UInt64
    let tableSizes: [String: UInt64]

    func size(for chunkID: String) -> UInt64? {
        chunkID == "data" ? dataSize : tableSizes[chunkID]
    }
}

// A bounds-checked walk over every chunk of a WAV file. Each step reads one header and seeks
// past the payload, so the cost is proportional to the number of chunks, not the file size;
// a chunk that runs past the end of the file, a placeholder size nothing resolves, or an
// RF64/BW64 that does not open with ds64 is a structural error rather than a silent miss.
struct RIFFChunkWalker: Sendable {
    // The 32-bit size field's value that means "look in ds64".
    static let sizePlaceholder: UInt32 = 0xFFFF_FFFF
    // ds64 is 28 bytes plus 12 per table entry; one this large is corrupt, not merely big.
    static let maxDs64Bytes: UInt64 = 65_536

    let container: String
    let chunks: [RIFFChunk]

    init(file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: 12) ?? Data()
        guard header.count == 12 else {
            throw Self.invalid(file, "header is \(header.count) bytes, need 12")
        }
        let container = Self.fourCC(header, at: 0)
        let formType = Self.fourCC(header, at: 8)
        guard formType == "WAVE" else {
            throw Self.invalid(file, "form type '\(formType)' is not 'WAVE'")
        }
        let requiresDs64: Bool
        switch container {
        case "RIFF":
            requiresDs64 = false
        case "RF64", "BW64":
            requiresDs64 = true
        default:
            throw Self.invalid(file, "unknown container '\(container)'")
        }
        self.container = container
        chunks = try Self.walk(handle, file: file, fileSize: fileSize, container: container, requiresDs64: requiresDs64)
    }

    func contains(_ chunkID: String) -> Bool {
        chunks.contains { $0.chunkID == chunkID }
    }

    private static func invalid(_ file: URL, _ reason: String) -> AppError {
        AppError("WAV chunk structure invalid for \(file.path): \(reason)")
    }

    private static func walk(
        _ handle: FileHandle, file: URL, fileSize: UInt64, container: String, requiresDs64: Bool
    ) throws -> [RIFFChunk] {
        var chunks: [RIFFChunk] = []
        var ds64: Ds64Sizes?
        var offset: UInt64 = 12
        // A missing final pad byte after an odd-sized last chunk leaves `offset` one past the
        // end; that is tolerated, anything else short of a full header is not.
        while offset < fileSize {
            guard fileSize - offset >= 8 else {
                throw invalid(file, "\(fileSize - offset) trailing byte(s) after the last chunk at offset \(offset)")
            }
            try handle.seek(toOffset: offset)
            let chunkHeader = try handle.read(upToCount: 8) ?? Data()
            guard chunkHeader.count == 8 else {
                throw invalid(file, "chunk header at offset \(offset) is truncated")
            }
            let chunkID = fourCC(chunkHeader, at: 0)
            let declaredSize = uint32LE(chunkHeader, at: 4)
            let payloadOffset = offset + 8
            if requiresDs64 && chunks.isEmpty {
                guard chunkID == "ds64" else {
                    throw invalid(file, "\(container) must start with a ds64 chunk, found '\(chunkID)'")
                }
                ds64 = try readDs64(
                    handle, file: file, payloadOffset: payloadOffset, declaredSize: declaredSize, fileSize: fileSize
                )
            }
            let payloadSize = try resolvePayloadSize(
                declaredSize, chunkID: chunkID, offset: offset, ds64: ds64, file: file
            )
            let (payloadEnd, overflow) = payloadOffset.addingReportingOverflow(payloadSize)
            guard !overflow, payloadEnd <= fileSize else {
                let reason = "chunk '\(chunkID)' at offset \(offset) declares \(payloadSize) bytes"
                throw invalid(file, "\(reason) but the file ends at \(fileSize)")
            }
            chunks.append(RIFFChunk(chunkID: chunkID, headerOffset: offset, payloadSize: payloadSize))
            offset = payloadEnd + (payloadSize & 1)
        }
        if requiresDs64 && ds64 == nil {
            throw invalid(file, "\(container) must start with a ds64 chunk, found no chunks")
        }
        return chunks
    }

    // The placeholder is legal only in an RF64/BW64 (where ds64 has already been read, being
    // the first chunk) and only for the data chunk or a chunk ds64's table names.
    private static func resolvePayloadSize(
        _ declaredSize: UInt32, chunkID: String, offset: UInt64, ds64: Ds64Sizes?, file: URL
    ) throws -> UInt64 {
        guard declaredSize == sizePlaceholder else {
            return UInt64(declaredSize)
        }
        guard let ds64 else {
            throw invalid(file, "chunk '\(chunkID)' at offset \(offset) uses the RF64 size placeholder in a RIFF file")
        }
        guard let size = ds64.size(for: chunkID) else {
            let reason = "chunk '\(chunkID)' at offset \(offset) uses the RF64 size placeholder"
            throw invalid(file, "\(reason) but ds64 has no size for it")
        }
        return size
    }

    private static func readDs64(
        _ handle: FileHandle, file: URL, payloadOffset: UInt64, declaredSize: UInt32, fileSize: UInt64
    ) throws -> Ds64Sizes {
        let size = UInt64(declaredSize)
        guard size >= 28, size <= maxDs64Bytes, size <= fileSize - payloadOffset else {
            throw invalid(file, "ds64 chunk of \(size) bytes cannot hold its sizes (need 28 to \(maxDs64Bytes))")
        }
        let payload = try handle.read(upToCount: Int(size)) ?? Data()
        guard payload.count == Int(size) else {
            throw invalid(file, "ds64 chunk is truncated")
        }
        let tableLength = UInt64(uint32LE(payload, at: 24))
        guard 28 + tableLength * 12 <= size else {
            throw invalid(file, "ds64 chunk of \(size) bytes cannot hold a \(tableLength)-entry size table")
        }
        var tableSizes: [String: UInt64] = [:]
        for entry in 0..<Int(tableLength) {
            let entryOffset = 28 + entry * 12
            tableSizes[fourCC(payload, at: entryOffset)] = uint64LE(payload, at: entryOffset + 4)
        }
        return Ds64Sizes(dataSize: uint64LE(payload, at: 8), tableSizes: tableSizes)
    }

    // Latin-1 maps every byte to one character, so a corrupt id is still quotable in an error.
    private static func fourCC(_ data: Data, at offset: Int) -> String {
        let start = data.startIndex + offset
        return String(bytes: data[start..<start + 4], encoding: .isoLatin1) ?? "????"
    }

    private static func uint32LE(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return data[start..<start + 4].enumerated().reduce(UInt32(0)) {
            $0 | UInt32($1.element) << (8 * UInt32($1.offset))
        }
    }

    private static func uint64LE(_ data: Data, at offset: Int) -> UInt64 {
        let start = data.startIndex + offset
        return data[start..<start + 8].enumerated().reduce(UInt64(0)) {
            $0 | UInt64($1.element) << (8 * UInt64($1.offset))
        }
    }
}
