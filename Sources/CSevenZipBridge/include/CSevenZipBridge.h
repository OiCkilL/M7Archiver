#ifndef M7_C_SEVEN_ZIP_BRIDGE_H
#define M7_C_SEVEN_ZIP_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct M7SevenZipEntry {
    char *path;
    int64_t size;
    int64_t modifiedAt;
    bool isDirectory;
    bool isEncrypted;
} M7SevenZipEntry;

typedef struct M7SevenZipEntryList {
    M7SevenZipEntry *entries;
    int count;
    bool isEncrypted;
    char *error;
} M7SevenZipEntryList;

/// Progress tracking struct for 7-Zip extraction.
/// Passed by pointer to m7_7z_extract; fields are read/written
/// concurrently by the C worker and a Swift monitoring task.
/// All pointer parameters are optional (NULL = no tracking).
typedef struct {
    volatile int64_t current;       ///< entries processed so far (incremented by C)
    volatile int32_t cancel_flag;   ///< set to 1 by Swift to request cancellation
    int64_t total;                  ///< total entries to process (set by Swift)
    volatile int32_t skipped;       ///< entries skipped due to errors (incremented by C)
    char *skipped_paths;            ///< \n-separated paths of skipped files (set by C, freed by Swift)
} M7SevenZipExtractProgress;

M7SevenZipEntryList m7_7z_list(const char *archivePath);
M7SevenZipEntryList m7_7z_test(const char *archivePath);
int m7_7z_extract(const char *archivePath, const char *destinationPath, char **error, M7SevenZipExtractProgress *progress);
void m7_7z_entry_list_free(M7SevenZipEntryList list);
void m7_7z_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif
