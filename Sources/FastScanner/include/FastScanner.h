#ifndef AI_USAGE_TRACKER_FAST_SCANNER_H
#define AI_USAGE_TRACKER_FAST_SCANNER_H

#include <stddef.h>
#include <stdint.h>

typedef void (*AIUsageLineCallback)(const uint8_t *line, size_t length, int64_t offset, void *context);

/// Read a JSONL file with mmap/memchr and invoke the callback only for lines
/// containing `needle`. Provider files are never modified.
/// Returns 0 on success and a negative value for an open/stat/map failure.
int ai_scan_jsonl_file(const char *path,
                       int64_t start_offset,
                       const uint8_t *needle,
                       size_t needle_length,
                       AIUsageLineCallback callback,
                       void *context,
                       int64_t *file_size,
                       int64_t *complete_offset,
                       int *invalid_utf8_tail);

/// Variant used by Codex accounting, where model context and token counters
/// must be consumed in source order. The callback is invoked once for a line
/// containing either needle.
int ai_scan_jsonl_file2(const char *path,
                        int64_t start_offset,
                        const uint8_t *first_needle,
                        size_t first_needle_length,
                        const uint8_t *second_needle,
                        size_t second_needle_length,
                        AIUsageLineCallback callback,
                        void *context,
                        int64_t *file_size,
                        int64_t *complete_offset,
                        int *invalid_utf8_tail);

#endif
