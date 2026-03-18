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
int bw64_write_from_f32le_file(
    const char *input_path,
    const char *output_path,
    uint16_t channels,
    uint32_t sample_rate,
    uint16_t bit_depth,
    char *error_buffer,
    size_t error_buffer_size
);

#ifdef __cplusplus
}
#endif

#endif
