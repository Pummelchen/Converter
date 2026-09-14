#ifndef BW64_BRIDGE_H
#define BW64_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Writes a true BW64 WAV file from a raw float32 little-endian PCM file.
// Returns 0 on success and non-zero on failure. A best-effort error message
// is written into error_buffer when provided.
//
// The two path parameters are deliberately separated by the numeric options:
// interleaving distinct types makes an accidental input/output swap a compile
// error, which matters because the writer opens the output with truncation.
int bw64_write_from_f32le_file(
    const char *input_path,
    uint16_t channels,
    uint32_t sample_rate,
    uint16_t bit_depth,
    const char *output_path,
    char *error_buffer,
    size_t error_buffer_size
);

#ifdef __cplusplus
}
#endif

#endif
