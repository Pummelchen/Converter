#include "bw64_bridge.h"

#include <bw64/bw64.hpp>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

struct Options {
    std::string inputPath;
    std::string outputPath;
    std::uint16_t channels = 0;
    std::uint32_t sampleRate = 0;
    std::uint16_t bitDepth = 32;
};

std::uint32_t fourCC(const char id[5]) {
    return bw64::utils::fourCC(id);
}

template <typename T>
void writeLE(std::fstream& stream, T value) {
    stream.write(reinterpret_cast<const char*>(&value), sizeof(value));
}

void forceBW64Container(const std::string& path, std::uint64_t dataBytes) {
    std::fstream stream(path, std::ios::in | std::ios::out | std::ios::binary);
    if (!stream.is_open()) {
        throw std::runtime_error("failed to reopen output for BW64 finalization: " + path);
    }

    const auto fileSize = std::filesystem::file_size(path);
    if (fileSize < 48) {
        throw std::runtime_error("output too small to finalize as BW64: " + path);
    }

    stream.seekp(0);
    writeLE(stream, fourCC("BW64"));
    writeLE(stream, static_cast<std::uint32_t>(0xFFFFFFFFu));
    writeLE(stream, fourCC("WAVE"));

    stream.seekp(12);
    writeLE(stream, fourCC("ds64"));
    writeLE(stream, static_cast<std::uint32_t>(28u));
    writeLE(stream, static_cast<std::uint64_t>(fileSize >= 8 ? fileSize - 8 : 0));
    writeLE(stream, dataBytes);
    writeLE(stream, static_cast<std::uint64_t>(0));
    writeLE(stream, static_cast<std::uint32_t>(0));
}

void validateOutput(const Options& options, std::uint64_t framesWritten) {
    auto reader = bw64::readFile(options.outputPath);
    if (reader->fileFormat() != bw64::utils::fourCC("BW64")) {
        throw std::runtime_error("output is not BW64: " + options.outputPath);
    }
    if (reader->channels() != options.channels) {
        throw std::runtime_error("BW64 channel mismatch");
    }
    if (reader->sampleRate() != options.sampleRate) {
        throw std::runtime_error("BW64 sample-rate mismatch");
    }
    if (reader->bitDepth() != options.bitDepth) {
        throw std::runtime_error("BW64 bit-depth mismatch");
    }
    if (reader->numberOfFrames() != framesWritten) {
        throw std::runtime_error("BW64 frame-count mismatch");
    }
}

void requireOptions(const Options& options) {
    if (options.inputPath.empty()) {
        throw std::runtime_error("input path is required");
    }
    if (options.outputPath.empty()) {
        throw std::runtime_error("output path is required");
    }
    if (options.channels == 0) {
        throw std::runtime_error("channels must be > 0");
    }
    if (options.sampleRate == 0) {
        throw std::runtime_error("sample-rate must be > 0");
    }
    if (options.bitDepth != 16 && options.bitDepth != 24 && options.bitDepth != 32) {
        throw std::runtime_error("bit-depth must be 16, 24, or 32");
    }
}

void writeBW64FromFile(const Options& options) {
    requireOptions(options);

    std::ifstream input(options.inputPath, std::ios::binary);
    if (!input.is_open()) {
        throw std::runtime_error("failed to open input PCM file: " + options.inputPath);
    }

    auto chnaChunk = std::make_shared<bw64::ChnaChunk>();
    auto writer = bw64::writeFile(
        options.outputPath,
        options.channels,
        options.sampleRate,
        options.bitDepth,
        chnaChunk,
        nullptr
    );

    const std::size_t samplesPerChunk = static_cast<std::size_t>(options.channels) * 8192u;
    std::vector<float> buffer(samplesPerChunk);
    std::uint64_t framesWritten = 0;

    while (true) {
        const std::size_t requestedBytes = buffer.size() * sizeof(float);
        input.read(reinterpret_cast<char*>(buffer.data()), static_cast<std::streamsize>(requestedBytes));
        const std::streamsize bytesRead = input.gcount();

        if (bytesRead == 0) {
            break;
        }
        if (bytesRead < 0) {
            throw std::runtime_error("PCM input read failed");
        }
        if (bytesRead % static_cast<std::streamsize>(sizeof(float) * options.channels) != 0) {
            throw std::runtime_error("PCM input byte count is not aligned to full audio frames");
        }

        const auto frames = static_cast<std::uint64_t>(bytesRead / static_cast<std::streamsize>(sizeof(float) * options.channels));
        writer->write(buffer.data(), frames);
        framesWritten += frames;

        if (input.eof()) {
            break;
        }
        if (input.fail()) {
            throw std::runtime_error("PCM input read failed before EOF");
        }
    }

    if (framesWritten == 0) {
        throw std::runtime_error("no audio frames found in PCM input");
    }

    writer.reset();

    const std::uint64_t dataBytes = framesWritten * static_cast<std::uint64_t>(options.channels) * static_cast<std::uint64_t>(options.bitDepth / 8u);
    forceBW64Container(options.outputPath, dataBytes);
    validateOutput(options, framesWritten);
}

void writeError(const std::string& message, char* errorBuffer, size_t errorBufferSize) {
    if (errorBuffer == nullptr || errorBufferSize == 0) {
        return;
    }
    const auto copySize = std::min(message.size(), errorBufferSize - 1);
    std::memcpy(errorBuffer, message.data(), copySize);
    errorBuffer[copySize] = '\0';
}

}  // namespace

int bw64_write_from_f32le_file(
    const char* input_path,
    const char* output_path,
    uint16_t channels,
    uint32_t sample_rate,
    uint16_t bit_depth,
    char* error_buffer,
    size_t error_buffer_size
) {
    try {
        Options options;
        options.inputPath = input_path == nullptr ? "" : input_path;
        options.outputPath = output_path == nullptr ? "" : output_path;
        options.channels = channels;
        options.sampleRate = sample_rate;
        options.bitDepth = bit_depth;
        writeBW64FromFile(options);
        return 0;
    } catch (const std::exception& error) {
        writeError(error.what(), error_buffer, error_buffer_size);
        return 1;
    } catch (...) {
        writeError("unknown BW64 writer error", error_buffer, error_buffer_size);
        return 1;
    }
}
