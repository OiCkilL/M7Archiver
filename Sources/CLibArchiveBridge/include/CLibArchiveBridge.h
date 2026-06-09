#ifndef M7_LIB_ARCHIVE_BRIDGE_H
#define M7_LIB_ARCHIVE_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct M7ArchiveEntry {
    char *path;
    int64_t size;
    int64_t modifiedAt;
    bool isDirectory;
    bool isEncrypted;
} M7ArchiveEntry;

typedef struct M7ArchiveEntryList {
    M7ArchiveEntry *entries;
    int count;
    bool isEncrypted;
    bool needsEncodingFix;
    char *error;
} M7ArchiveEntryList;

#define M7_ZIP_RAW_NAME_MAX_COUNT 100000
#define M7_ZIP_RAW_NAME_MAX_BYTES (8 * 1024 * 1024)
#define M7_ZIP_RAW_NAME_MAX_SINGLE_NAME_BYTES 65535

/// Raw ZIP central-directory filename bytes for one entry.
/// Bytes are length-delimited and are not NUL-terminated.
typedef struct M7ZipRawName {
    uint8_t *bytes;
    int byteCount;
    uint8_t *unicodePathBytes;
    int unicodePathByteCount;
    bool hasValidUnicodePath;
    uint16_t flags;
} M7ZipRawName;

typedef struct M7ZipRawNameList {
    M7ZipRawName *names;
    int count;
    char *error;
    bool hasError;
} M7ZipRawNameList;

M7ArchiveEntryList m7_archive_list(const char *archivePath, const char *password, const char *encoding);
M7ArchiveEntryList m7_archive_test(const char *archivePath, const char *password, const char *encoding);
M7ZipRawNameList m7_zip_read_raw_names(const char *archivePath);
void m7_zip_raw_name_list_free(M7ZipRawNameList list);
/// Progress tracking struct for extraction.
/// Passed by pointer to m7_archive_extract; fields are read/written
/// concurrently by the C worker and a Swift monitoring task.
/// All pointer parameters are optional (NULL = no tracking).
typedef struct {
    volatile int64_t current;       ///< entries processed so far (incremented by C)
    volatile int32_t cancel_flag;   ///< set to 1 by Swift to request cancellation
    int64_t total;                  ///< total entries to process (set by Swift)
    volatile int32_t skipped;       ///< entries skipped due to errors (incremented by C)
    char *skipped_paths;            ///< \n-separated paths of skipped files (set by C, freed by Swift)
} M7ExtractProgress;

int m7_archive_extract(const char *archivePath, const char *destinationPath, const char *password, const char *encoding, char **error, M7ExtractProgress *progress);
int m7_archive_create_zip(const char *archivePath, char **sourcePaths, char **entryPaths, int sourceCount, int compressionLevel, const char *encoding, const char *encryption, const char *password, char **error);
void m7_archive_entry_list_free(M7ArchiveEntryList list);
void m7_archive_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif
