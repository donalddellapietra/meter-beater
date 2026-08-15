#include "FastScanner.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>

#define AI_USAGE_SCAN_WINDOW (32 * 1024 * 1024)

static int valid_utf8(const unsigned char *bytes, size_t length) {
    size_t i = 0;
    while (i < length) {
        unsigned char c = bytes[i++];
        if (c < 0x80) continue;
        if (c >= 0xC2 && c <= 0xDF) {
            if (i >= length || (bytes[i++] & 0xC0) != 0x80) return 0;
        } else if (c >= 0xE0 && c <= 0xEF) {
            if (i + 1 >= length || (bytes[i] & 0xC0) != 0x80 || (bytes[i + 1] & 0xC0) != 0x80) return 0;
            if (c == 0xE0 && bytes[i] < 0xA0) return 0;
            if (c == 0xED && bytes[i] >= 0xA0) return 0;
            i += 2;
        } else if (c >= 0xF0 && c <= 0xF4) {
            if (i + 2 >= length || (bytes[i] & 0xC0) != 0x80 || (bytes[i + 1] & 0xC0) != 0x80 || (bytes[i + 2] & 0xC0) != 0x80) return 0;
            if (c == 0xF0 && bytes[i] < 0x90) return 0;
            if (c == 0xF4 && bytes[i] >= 0x90) return 0;
            i += 3;
        } else {
            return 0;
        }
    }
    return 1;
}

static int scan_jsonl_file(const char *path,
                           int64_t start_offset,
                           const uint8_t *first_needle,
                           size_t first_needle_length,
                           const uint8_t *second_needle,
                           size_t second_needle_length,
                           int scan_all_lines,
                           AIUsageLineCallback callback,
                           void *context,
                           int64_t *file_size,
                           int64_t *complete_offset,
                           int *invalid_utf8_tail) {
    if (file_size) *file_size = 0;
    if (complete_offset) *complete_offset = start_offset;
    if (invalid_utf8_tail) *invalid_utf8_tail = 0;

    int descriptor = open(path, O_RDONLY);
    if (descriptor < 0) return -1;
    struct stat info;
    if (fstat(descriptor, &info) != 0) {
        close(descriptor);
        return -2;
    }
    if (info.st_size <= 0) {
        close(descriptor);
        if (complete_offset) *complete_offset = 0;
        return 0;
    }

    size_t length = (size_t)info.st_size;
    size_t position = start_offset < 0 ? 0 : (size_t)start_offset;
    if (position > length) position = length;
    size_t complete_line_offset = position;
    long raw_page_size = sysconf(_SC_PAGESIZE);
    size_t page_size = raw_page_size > 0 ? (size_t)raw_page_size : 4096;

    // Map only the active logical window. The virtual mapping may extend to the
    // end so a line crossing the nominal boundary remains contiguous, but the
    // search is capped at the first following newline and the mapping is then
    // discarded. This prevents two large transcripts from making gigabytes of
    // already-consumed clean pages resident at once.
    while (position < length) {
        size_t map_offset = (position / page_size) * page_size;
        size_t map_length = length - map_offset;
        void *mapped = mmap(NULL, map_length, PROT_READ, MAP_PRIVATE, descriptor, (off_t)map_offset);
        if (mapped == MAP_FAILED) {
            close(descriptor);
            return -3;
        }
        const unsigned char *bytes = (const unsigned char *)mapped;
        const unsigned char *chunk_start = bytes + (position - map_offset);
        size_t desired_end = position + AI_USAGE_SCAN_WINDOW;
        if (desired_end > length) desired_end = length;
        size_t chunk_end_offset = desired_end;
        if (desired_end < length) {
            const unsigned char *boundary = memchr(
                bytes + (desired_end - map_offset),
                '\n',
                length - desired_end
            );
            chunk_end_offset = boundary
                ? map_offset + (size_t)(boundary - bytes) + 1
                : length;
        }
        const unsigned char *chunk_end = bytes + (chunk_end_offset - map_offset);

        if (scan_all_lines) {
            const unsigned char *line_start = chunk_start;
            while (line_start < chunk_end) {
                const unsigned char *newline = memchr(line_start, '\n', (size_t)(chunk_end - line_start));
                const unsigned char *line_end = newline ? newline : chunk_end;
                if (callback) callback(line_start, (size_t)(line_end - line_start), map_offset + (int64_t)(line_start - bytes), context);
                if (!newline) break;
                line_start = newline + 1;
            }
        } else {
            const unsigned char *search = chunk_start;
            const unsigned char *first = first_needle_length == 0
                ? NULL
                : memmem(search, (size_t)(chunk_end - search), first_needle, first_needle_length);
            const unsigned char *second = second_needle_length == 0
                ? NULL
                : memmem(search, (size_t)(chunk_end - search), second_needle, second_needle_length);
            while (search < chunk_end) {
                const unsigned char *match = first;
                size_t matched_length = first_needle_length;
                if (!match || (second && second < match)) {
                    match = second;
                    matched_length = second_needle_length;
                }
                if (!match) break;

                const unsigned char *line_start = match;
                while (line_start > chunk_start && line_start[-1] != '\n') line_start--;
                const unsigned char *line_end = match + matched_length;
                while (line_end < chunk_end && *line_end != '\n') line_end++;
                if (callback) callback(line_start, (size_t)(line_end - line_start), map_offset + (int64_t)(line_start - bytes), context);
                if (line_end >= chunk_end) break;
                search = line_end + 1;
                if (first && first < search) {
                    first = memmem(search, (size_t)(chunk_end - search), first_needle, first_needle_length);
                }
                if (second && second < search) {
                    second = memmem(search, (size_t)(chunk_end - search), second_needle, second_needle_length);
                }
            }
        }

        if (chunk_end_offset < length || (chunk_end > chunk_start && chunk_end[-1] == '\n')) {
            complete_line_offset = chunk_end_offset;
        } else {
            complete_line_offset = position;
            for (const unsigned char *cursor = chunk_end; cursor > chunk_start; cursor--) {
                if (cursor[-1] == '\n') {
                    complete_line_offset = map_offset + (size_t)(cursor - bytes);
                    break;
                }
            }
            if (complete_line_offset < length) {
                const unsigned char *tail = bytes + (complete_line_offset - map_offset);
                if (!valid_utf8(tail, length - complete_line_offset) && invalid_utf8_tail) {
                    *invalid_utf8_tail = 1;
                }
            }
        }

        (void)madvise(mapped, map_length, MADV_DONTNEED);
        munmap(mapped, map_length);
        if (chunk_end_offset <= position) break;
        position = chunk_end_offset;
    }

    close(descriptor);
    if (file_size) *file_size = (int64_t)length;
    if (complete_offset) *complete_offset = (int64_t)complete_line_offset;
    return 0;
}

int ai_scan_jsonl_file(const char *path,
                       int64_t start_offset,
                       const uint8_t *needle,
                       size_t needle_length,
                       AIUsageLineCallback callback,
                       void *context,
                       int64_t *file_size,
                       int64_t *complete_offset,
                       int *invalid_utf8_tail) {
    return scan_jsonl_file(path, start_offset, needle, needle_length, NULL, 0,
                           needle_length == 0, callback, context, file_size,
                           complete_offset, invalid_utf8_tail);
}

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
                        int *invalid_utf8_tail) {
    return scan_jsonl_file(path, start_offset, first_needle, first_needle_length,
                           second_needle, second_needle_length, 0, callback,
                           context, file_size, complete_offset, invalid_utf8_tail);
}
