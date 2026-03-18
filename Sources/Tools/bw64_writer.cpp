#include <bw64/bw64.hpp>

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

struct Options {
    std::string outputPath;
    std::uint16_t channels = 0;
    std::uint32_t sampleRate = 0;
    std::uint16_t bitDepth = 32;
};

void requireValue(int index, int argc, const std::string& flag) {
    if (index + 1 >= argc) {
        throw std::runtime_error("missing value for " + flag);
    }
}

// Parse the small CLI surface used by the Swift pipeline.
Options parseOptions(int argc, char** argv) {
    Options options;

    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--output") {
            requireValue(index, argc, argument);
            options.outputPath = argv[++index];
        } else if (argument == "--channels") {
            requireValue(index, argc, argument);
            options.channels = static_cast<std::uint16_t>(std::stoul(argv[++index]));
        } else if (argument == "--sample-rate") {
            requireValue(index, argc, argument);
            options.sampleRate = static_cast<std::uint32_t>(std::stoul(argv[++index]));
        } else if (argument == "--bit-depth") {
            requireValue(index, argc, argument);
            options.bitDepth = static_cast<std::uint16_t>(std::stoul(argv[++index]));
        } else {
            throw std::runtime_error("unknown argument: " + argument);
        }
    }

    if (options.outputPath.empty()) {
        throw std::runtime_error("--output is required");
    }
    if (options.channels == 0) {
        throw std::runtime_error("--channels must be > 0");
    }
    if (options.sampleRate == 0) {
        throw std::runtime_error("--sample-rate must be > 0");
    }
    if (options.bitDepth != 16 && options.bitDepth != 24 && options.bitDepth != 32) {
        throw std::runtime_error("--bit-depth must be 16, 24, or 32");
    }

    return options;
}

std::uint32_t fourCC(const char id[5]) {
    return bw64::utils::fourCC(id);
}

template <typename T>
void writeLE(std::fstream& stream, T value) {
    stream.write(reinterpret_cast<const char*>(&value), sizeof(value));
}

// libbw64 only flips to BW64 automatically above 4 GB. Force the final RIFF+JUNK
// header into a standards-style BW64+ds64 header so smaller delivery files are
// still true BW64 containers.
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

// Re-open with libbw64 to confirm that the helper emitted a readable BW64 file.
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

}  // namespace

int main(int argc, char** argv) {
    try {
        const Options options = parseOptions(argc, argv);
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
            std::cin.read(reinterpret_cast<char*>(buffer.data()), static_cast<std::streamsize>(requestedBytes));
            const std::streamsize bytesRead = std::cin.gcount();

            if (bytesRead == 0) {
                break;
            }
            if (bytesRead < 0) {
                throw std::runtime_error("stdin read failed");
            }
            if (bytesRead % static_cast<std::streamsize>(sizeof(float) * options.channels) != 0) {
                throw std::runtime_error("stdin byte count is not aligned to full audio frames");
            }

            const auto frames = static_cast<std::uint64_t>(bytesRead / static_cast<std::streamsize>(sizeof(float) * options.channels));
            writer->write(buffer.data(), frames);
            framesWritten += frames;

            if (std::cin.eof()) {
                break;
            }
            if (std::cin.fail()) {
                throw std::runtime_error("stdin read failed before EOF");
            }
        }

        if (framesWritten == 0) {
            throw std::runtime_error("no audio frames received on stdin");
        }

        writer.reset();

        const std::uint64_t dataBytes = framesWritten * static_cast<std::uint64_t>(options.channels) * static_cast<std::uint64_t>(options.bitDepth / 8u);
        forceBW64Container(options.outputPath, dataBytes);
        validateOutput(options, framesWritten);
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "bw64_writer: " << error.what() << '\n';
        return 1;
    }
}
