#include "CLibArchiveBridge.h"

#include <archive.h>
#include <archive_entry.h>
#include <limits.h>
#include <locale.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>


static pthread_once_t m7_locale_once = PTHREAD_ONCE_INIT;

static void m7_init_locale(void) {
    // libarchive's invalid_mbs() calls mbrtowc() which depends on the
    // current locale.  Without a UTF-8 locale, all non-ASCII characters
    // are rejected and pathnames silently become NULL.
    setlocale(LC_CTYPE, "UTF-8");
}

static char *m7_strdup(const char *string) {
    if (string == NULL) { return NULL; }
    size_t length = strlen(string) + 1;
    char *copy = malloc(length);
    if (copy != NULL) { memcpy(copy, string, length); }
    return copy;
}

static char *m7_archive_error(struct archive *archive) {
    const char *error = archive_error_string(archive);
    return m7_strdup(error != NULL ? error : "Unknown libarchive error");
}

static int m7_archive_fail_and_cleanup(struct archive *archive, const char *archivePath, char **error, char *message) {
    if (error != NULL) { *error = message; }
    archive_write_close(archive);
    archive_write_free(archive);
    if (archivePath != NULL) {
        unlink(archivePath);
    }
    return ARCHIVE_FATAL;
}

static int m7_archive_fail_with_message(struct archive *archive, const char *archivePath, char **error, const char *message) {
    return m7_archive_fail_and_cleanup(archive, archivePath, error, m7_strdup(message));
}

static int m7_configure_reader(struct archive *archive, const char *password, const char *encoding) {
    archive_read_support_filter_all(archive);
    archive_read_support_format_all(archive);
    archive_read_support_format_7zip(archive);
    archive_read_support_format_zip(archive);
    archive_read_support_format_rar(archive);
    archive_read_support_format_rar5(archive);
    archive_read_support_format_tar(archive);
    archive_read_support_format_cab(archive);
    archive_read_support_format_iso9660(archive);
    archive_read_support_format_xar(archive);
    if (password != NULL && password[0] != '\0') {
        archive_read_add_passphrase(archive, password);
    }
    if (encoding != NULL && encoding[0] != '\0') {
        // libarchive ZIP handler accepts "zip:hdrcharset=<encoding>" to
        // convert non-UTF-8 filenames (e.g. GBK, CP936, CP437).
        char option[256];
        snprintf(option, sizeof(option), "zip:hdrcharset=%s", encoding);
        archive_read_set_options(archive, option);
    }
    return ARCHIVE_OK;
}

static M7ArchiveEntry m7_make_entry(struct archive_entry *entry) {
    M7ArchiveEntry bridgeEntry;
    const char *utf8 = archive_entry_pathname_utf8(entry);
    const char *raw  = archive_entry_pathname(entry);
    const char *path = utf8 != NULL ? utf8 : raw;
    bridgeEntry.path = m7_strdup(path != NULL ? path : "");
    bridgeEntry.size = archive_entry_size_is_set(entry) ? archive_entry_size(entry) : -1;
    bridgeEntry.modifiedAt = archive_entry_mtime_is_set(entry) ? archive_entry_mtime(entry) : -1;
    bridgeEntry.isDirectory = archive_entry_filetype(entry) == AE_IFDIR;
    bridgeEntry.isEncrypted = archive_entry_is_encrypted(entry) == 1 || archive_entry_is_data_encrypted(entry) == 1 || archive_entry_is_metadata_encrypted(entry) == 1;
    return bridgeEntry;
}

static int m7_append_entry(M7ArchiveEntryList *list, struct archive_entry *entry) {
    M7ArchiveEntry *entries = realloc(list->entries, sizeof(M7ArchiveEntry) * (size_t)(list->count + 1));
    if (entries == NULL) {
        list->error = m7_strdup("Unable to allocate archive entry list");
        return ARCHIVE_FATAL;
    }
    list->entries = entries;
    list->entries[list->count] = m7_make_entry(entry);

    // Track whether any entry has a raw pathname that libarchive could
    // not decode as UTF-8 (signals that a hdrcharset override is needed).
    if (archive_entry_pathname_utf8(entry) == NULL
        && archive_entry_pathname(entry) != NULL
        && archive_entry_pathname(entry)[0] != '\0') {
        list->needsEncodingFix = true;
    }

    list->count += 1;
    return ARCHIVE_OK;
}

static M7ArchiveEntryList m7_archive_read_entries(const char *archivePath, const char *password, const char *encoding, bool readData) {
    M7ArchiveEntryList list;
    list.entries = NULL;
    list.count = 0;
    list.isEncrypted = false;
    list.needsEncodingFix = false;
    list.error = NULL;

    pthread_once(&m7_locale_once, m7_init_locale);

    struct archive *archive = archive_read_new();
    if (archive == NULL) {
        list.error = m7_strdup("Unable to create libarchive reader");
        return list;
    }

    m7_configure_reader(archive, password, encoding);

    if (archive_read_open_filename(archive, archivePath, 10240) != ARCHIVE_OK) {
        list.error = m7_archive_error(archive);
        archive_read_free(archive);
        return list;
    }

    struct archive_entry *entry = NULL;
    for (;;) {
        int result = archive_read_next_header(archive, &entry);
        if (result == ARCHIVE_EOF) { break; }
        if (result < ARCHIVE_WARN) {
            list.error = m7_archive_error(archive);
            break;
        }

        if (entry != NULL) {
            if (m7_append_entry(&list, entry) < ARCHIVE_WARN) { break; }
        }

        if (readData) {
            const void *buffer = NULL;
            size_t size = 0;
            la_int64_t offset = 0;
            for (;;) {
                result = archive_read_data_block(archive, &buffer, &size, &offset);
                if (result == ARCHIVE_EOF) { break; }
                if (result < ARCHIVE_WARN) {
                    list.error = m7_archive_error(archive);
                    break;
                }
            }
            if (list.error != NULL) { break; }
        } else {
            result = archive_read_data_skip(archive);
            if (result < ARCHIVE_WARN && result != ARCHIVE_EOF) {
                list.error = m7_archive_error(archive);
                break;
            }
        }
    }

    int encrypted = archive_read_has_encrypted_entries(archive);
    list.isEncrypted = encrypted == 1;

    archive_read_close(archive);
    archive_read_free(archive);
    return list;
}

#define M7_ZIP_EOCD_SIGNATURE 0x06054b50u
#define M7_ZIP_CENTRAL_DIRECTORY_SIGNATURE 0x02014b50u
#define M7_ZIP_EOCD_MIN_SIZE 22u
#define M7_ZIP_EOCD_MAX_COMMENT_SIZE 65535u
#define M7_ZIP_CENTRAL_DIRECTORY_HEADER_SIZE 46u
#define M7_ZIP_UTF8_FLAG 0x0800u
#define M7_ZIP_CENTRAL_DIRECTORY_ENCRYPTED_FLAG 0x2000u
#define M7_ZIP_UNICODE_PATH_EXTRA_ID 0x7075u
#define M7_ZIP64_ENTRY_COUNT_SENTINEL 0xFFFFu
#define M7_ZIP64_OFFSET_SENTINEL 0xFFFFFFFFu

static uint16_t m7_read_le16(const uint8_t *bytes) {
    return (uint16_t)bytes[0] | (uint16_t)((uint16_t)bytes[1] << 8);
}

static uint32_t m7_read_le32(const uint8_t *bytes) {
    return (uint32_t)bytes[0]
        | ((uint32_t)bytes[1] << 8)
        | ((uint32_t)bytes[2] << 16)
        | ((uint32_t)bytes[3] << 24);
}

static bool m7_u64_add_overflows(uint64_t lhs, uint64_t rhs, uint64_t *result) {
    if (UINT64_MAX - lhs < rhs) { return true; }
    *result = lhs + rhs;
    return false;
}

static bool m7_read_exact(FILE *file, void *buffer, size_t byteCount) {
    return byteCount == 0 || fread(buffer, 1, byteCount, file) == byteCount;
}

static bool m7_seek_to(FILE *file, uint64_t offset) {
    if (offset > (uint64_t)LLONG_MAX) { return false; }
    return fseeko(file, (off_t)offset, SEEK_SET) == 0;
}

static bool m7_valid_utf8(const uint8_t *bytes, size_t byteCount) {
    size_t index = 0;
    while (index < byteCount) {
        uint8_t byte = bytes[index];
        if (byte <= 0x7F) { index += 1; continue; }

        size_t needed = 0;
        uint32_t scalar = 0;
        if ((byte & 0xE0) == 0xC0) {
            needed = 2;
            scalar = (uint32_t)(byte & 0x1F);
            if (scalar == 0) { return false; }
        } else if ((byte & 0xF0) == 0xE0) {
            needed = 3;
            scalar = (uint32_t)(byte & 0x0F);
        } else if ((byte & 0xF8) == 0xF0) {
            needed = 4;
            scalar = (uint32_t)(byte & 0x07);
        } else {
            return false;
        }

        if (index + needed > byteCount) { return false; }
        for (size_t offset = 1; offset < needed; offset++) {
            uint8_t continuation = bytes[index + offset];
            if ((continuation & 0xC0) != 0x80) { return false; }
            scalar = (scalar << 6) | (uint32_t)(continuation & 0x3F);
        }

        if ((needed == 2 && scalar < 0x80)
            || (needed == 3 && scalar < 0x800)
            || (needed == 4 && scalar < 0x10000)
            || scalar > 0x10FFFF
            || (scalar >= 0xD800 && scalar <= 0xDFFF)) {
            return false;
        }
        index += needed;
    }
    return true;
}

static M7ZipRawNameList m7_zip_raw_name_error(M7ZipRawNameList list, const char *message) {
    m7_zip_raw_name_list_free(list);
    M7ZipRawNameList errorList;
    errorList.names = NULL;
    errorList.count = 0;
    errorList.hasError = true;
    errorList.error = m7_strdup(message);
    return errorList;
}

static bool m7_find_eocd(FILE *file, uint64_t fileSize, uint8_t **tailBytes, size_t *tailSize, size_t *eocdOffsetInTail) {
    size_t readSize = (size_t)(fileSize < (uint64_t)(M7_ZIP_EOCD_MIN_SIZE + M7_ZIP_EOCD_MAX_COMMENT_SIZE)
        ? fileSize
        : (uint64_t)(M7_ZIP_EOCD_MIN_SIZE + M7_ZIP_EOCD_MAX_COMMENT_SIZE));
    if (readSize < M7_ZIP_EOCD_MIN_SIZE) { return false; }

    uint64_t tailStart = fileSize - (uint64_t)readSize;
    if (!m7_seek_to(file, tailStart)) { return false; }

    uint8_t *buffer = (uint8_t *)malloc(readSize);
    if (buffer == NULL) { return false; }
    if (!m7_read_exact(file, buffer, readSize)) {
        free(buffer);
        return false;
    }

    for (size_t offset = readSize - M7_ZIP_EOCD_MIN_SIZE + 1; offset > 0; offset--) {
        size_t index = offset - 1;
        if (m7_read_le32(buffer + index) != M7_ZIP_EOCD_SIGNATURE) { continue; }
        uint16_t commentLength = m7_read_le16(buffer + index + 20);
        if (index + M7_ZIP_EOCD_MIN_SIZE + (size_t)commentLength == readSize) {
            *tailBytes = buffer;
            *tailSize = readSize;
            *eocdOffsetInTail = index;
            return true;
        }
    }

    free(buffer);
    return false;
}

static int m7_parse_unicode_path_extra(
    const uint8_t *extra,
    size_t extraLength,
    const uint8_t *rawName,
    size_t rawNameLength,
    M7ZipRawName *name
) {
    size_t offset = 0;
    while (offset < extraLength) {
        if (extraLength - offset < 4) { return -1; }
        uint16_t headerId = m7_read_le16(extra + offset);
        uint16_t dataSize = m7_read_le16(extra + offset + 2);
        size_t dataStart = offset + 4;
        size_t dataEnd = dataStart + (size_t)dataSize;
        if (dataEnd > extraLength || dataEnd < dataStart) { return -1; }

        if (headerId == M7_ZIP_UNICODE_PATH_EXTRA_ID && dataSize >= 5 && !name->hasValidUnicodePath) {
            const uint8_t *data = extra + dataStart;
            uint8_t version = data[0];
            uint32_t expectedCRC = m7_read_le32(data + 1);
            const uint8_t *payload = data + 5;
            size_t payloadLength = (size_t)dataSize - 5;
            uint32_t actualCRC = (uint32_t)crc32(0L, rawName, (uInt)rawNameLength);
            if (version == 1
                && expectedCRC == actualCRC
                && payloadLength > 0
                && m7_valid_utf8(payload, payloadLength)) {
                uint8_t *unicodeBytes = (uint8_t *)malloc(payloadLength);
                if (unicodeBytes == NULL) { return -2; }
                memcpy(unicodeBytes, payload, payloadLength);
                name->unicodePathBytes = unicodeBytes;
                name->unicodePathByteCount = (int)payloadLength;
                name->hasValidUnicodePath = true;
            }
        }
        offset = dataEnd;
    }
    return 0;
}

M7ZipRawNameList m7_zip_read_raw_names(const char *archivePath) {
    M7ZipRawNameList list;
    list.names = NULL;
    list.count = 0;
    list.hasError = false;
    list.error = NULL;

    if (archivePath == NULL || archivePath[0] == '\0') {
        return m7_zip_raw_name_error(list, "Missing ZIP archive path");
    }

    FILE *file = fopen(archivePath, "rb");
    if (file == NULL) {
        return m7_zip_raw_name_error(list, "Unable to open ZIP archive");
    }

    if (fseeko(file, 0, SEEK_END) != 0) {
        fclose(file);
        return m7_zip_raw_name_error(list, "Unable to seek ZIP archive");
    }
    off_t endOffset = ftello(file);
    if (endOffset < 0) {
        fclose(file);
        return m7_zip_raw_name_error(list, "Unable to read ZIP archive size");
    }
    uint64_t fileSize = (uint64_t)endOffset;

    uint8_t *tailBytes = NULL;
    size_t tailSize = 0;
    size_t eocdOffsetInTail = 0;
    if (!m7_find_eocd(file, fileSize, &tailBytes, &tailSize, &eocdOffsetInTail)) {
        fclose(file);
        return m7_zip_raw_name_error(list, "Unable to locate ZIP end of central directory");
    }

    const uint8_t *eocd = tailBytes + eocdOffsetInTail;
    uint16_t diskNumber = m7_read_le16(eocd + 4);
    uint16_t centralDirectoryDisk = m7_read_le16(eocd + 6);
    uint16_t entriesOnDisk = m7_read_le16(eocd + 8);
    uint16_t totalEntries = m7_read_le16(eocd + 10);
    uint32_t centralDirectorySize32 = m7_read_le32(eocd + 12);
    uint32_t centralDirectoryOffset32 = m7_read_le32(eocd + 16);
    uint64_t eocdStart = fileSize - (uint64_t)tailSize + (uint64_t)eocdOffsetInTail;
    free(tailBytes);

    if (diskNumber != 0 || centralDirectoryDisk != 0 || entriesOnDisk != totalEntries) {
        fclose(file);
        return m7_zip_raw_name_error(list, "Multi-disk ZIP archives are not supported by raw filename scanner");
    }
    if (totalEntries == M7_ZIP64_ENTRY_COUNT_SENTINEL
        || centralDirectorySize32 == M7_ZIP64_OFFSET_SENTINEL
        || centralDirectoryOffset32 == M7_ZIP64_OFFSET_SENTINEL) {
        fclose(file);
        return m7_zip_raw_name_error(list, "ZIP64 central directories are not supported by raw filename scanner");
    }
    if (totalEntries > M7_ZIP_RAW_NAME_MAX_COUNT) {
        fclose(file);
        return m7_zip_raw_name_error(list, "ZIP raw filename entry count exceeds scanner limit");
    }

    uint64_t centralDirectorySize = (uint64_t)centralDirectorySize32;
    uint64_t centralDirectoryOffset = (uint64_t)centralDirectoryOffset32;
    uint64_t centralDirectoryEnd = 0;
    if (m7_u64_add_overflows(centralDirectoryOffset, centralDirectorySize, &centralDirectoryEnd)
        || centralDirectoryEnd > fileSize) {
        fclose(file);
        return m7_zip_raw_name_error(list, "ZIP central directory is out of bounds");
    }
    if (centralDirectoryEnd > eocdStart) {
        fclose(file);
        return m7_zip_raw_name_error(list, "ZIP central directory overlaps with end of central directory record");
    }
    if (!m7_seek_to(file, centralDirectoryOffset)) {
        fclose(file);
        return m7_zip_raw_name_error(list, "Unable to seek ZIP central directory");
    }

    uint64_t currentOffset = centralDirectoryOffset;
    uint64_t totalNameBytes = 0;
    for (uint16_t index = 0; index < totalEntries; index++) {
        uint64_t fixedHeaderEnd = 0;
        if (m7_u64_add_overflows(currentOffset, M7_ZIP_CENTRAL_DIRECTORY_HEADER_SIZE, &fixedHeaderEnd)
            || fixedHeaderEnd > centralDirectoryEnd) {
            fclose(file);
            return m7_zip_raw_name_error(list, "ZIP central directory entry header is out of bounds");
        }

        uint8_t header[M7_ZIP_CENTRAL_DIRECTORY_HEADER_SIZE];
        if (!m7_read_exact(file, header, sizeof(header))) {
            fclose(file);
            return m7_zip_raw_name_error(list, "Unable to read ZIP central directory entry header");
        }
        if (m7_read_le32(header) != M7_ZIP_CENTRAL_DIRECTORY_SIGNATURE) {
            fclose(file);
            return m7_zip_raw_name_error(list, "Invalid ZIP central directory entry signature");
        }

        uint16_t flags = m7_read_le16(header + 8);
        uint16_t nameLength = m7_read_le16(header + 28);
        uint16_t extraLength = m7_read_le16(header + 30);
        uint16_t commentLength = m7_read_le16(header + 32);
        if ((flags & M7_ZIP_CENTRAL_DIRECTORY_ENCRYPTED_FLAG) != 0) {
            fclose(file);
            return m7_zip_raw_name_error(list, "Encrypted ZIP central directory metadata is not supported by raw filename scanner");
        }
        if (nameLength > M7_ZIP_RAW_NAME_MAX_SINGLE_NAME_BYTES) {
            fclose(file);
            return m7_zip_raw_name_error(list, "ZIP raw filename length exceeds scanner limit");
        }

        uint64_t variableLength = (uint64_t)nameLength + (uint64_t)extraLength + (uint64_t)commentLength;
        uint64_t entryEnd = 0;
        if (m7_u64_add_overflows(fixedHeaderEnd, variableLength, &entryEnd) || entryEnd > centralDirectoryEnd) {
            fclose(file);
            return m7_zip_raw_name_error(list, "ZIP central directory entry variable data is out of bounds");
        }

        if (totalNameBytes + (uint64_t)nameLength > M7_ZIP_RAW_NAME_MAX_BYTES) {
            fclose(file);
            return m7_zip_raw_name_error(list, "ZIP raw filename byte sample exceeds scanner limit");
        }
        totalNameBytes += (uint64_t)nameLength;

        M7ZipRawName rawName;
        rawName.bytes = NULL;
        rawName.byteCount = (int)nameLength;
        rawName.unicodePathBytes = NULL;
        rawName.unicodePathByteCount = 0;
        rawName.hasValidUnicodePath = false;
        rawName.flags = flags;

        if (nameLength > 0) {
            rawName.bytes = (uint8_t *)malloc((size_t)nameLength);
            if (rawName.bytes == NULL) {
                fclose(file);
                return m7_zip_raw_name_error(list, "Unable to allocate ZIP raw filename bytes");
            }
            if (!m7_read_exact(file, rawName.bytes, (size_t)nameLength)) {
                free(rawName.bytes);
                fclose(file);
                return m7_zip_raw_name_error(list, "Unable to read ZIP raw filename bytes");
            }
        }

        uint8_t *extraBytes = NULL;
        if (extraLength > 0) {
            extraBytes = (uint8_t *)malloc((size_t)extraLength);
            if (extraBytes == NULL) {
                free(rawName.bytes);
                fclose(file);
                return m7_zip_raw_name_error(list, "Unable to allocate ZIP central directory extra field bytes");
            }
            if (!m7_read_exact(file, extraBytes, (size_t)extraLength)) {
                free(extraBytes);
                free(rawName.bytes);
                fclose(file);
                return m7_zip_raw_name_error(list, "Unable to read ZIP central directory extra field bytes");
            }
            int extraResult = m7_parse_unicode_path_extra(extraBytes, (size_t)extraLength, rawName.bytes, (size_t)nameLength, &rawName);
            free(extraBytes);
            if (extraResult < 0) {
                free(rawName.unicodePathBytes);
                free(rawName.bytes);
                fclose(file);
                return m7_zip_raw_name_error(list, "Unable to parse ZIP central directory extra fields");
            }
        }

        if (commentLength > 0 && fseeko(file, (off_t)commentLength, SEEK_CUR) != 0) {
            free(rawName.unicodePathBytes);
            free(rawName.bytes);
            fclose(file);
            return m7_zip_raw_name_error(list, "Unable to skip ZIP central directory entry comment");
        }

        M7ZipRawName *names = (M7ZipRawName *)realloc(list.names, sizeof(M7ZipRawName) * (size_t)(list.count + 1));
        if (names == NULL) {
            free(rawName.unicodePathBytes);
            free(rawName.bytes);
            fclose(file);
            return m7_zip_raw_name_error(list, "Unable to allocate ZIP raw filename list");
        }
        list.names = names;
        list.names[list.count] = rawName;
        list.count += 1;
        currentOffset = entryEnd;
    }

    fclose(file);
    if (currentOffset != centralDirectoryEnd) {
        return m7_zip_raw_name_error(list, "ZIP central directory size does not match parsed entries");
    }
    return list;
}

void m7_zip_raw_name_list_free(M7ZipRawNameList list) {
    if (list.names != NULL) {
        for (int index = 0; index < list.count; index++) {
            free(list.names[index].bytes);
            free(list.names[index].unicodePathBytes);
        }
        free(list.names);
    }
    free(list.error);
}

M7ArchiveEntryList m7_archive_list(const char *archivePath, const char *password, const char *encoding) {
    return m7_archive_read_entries(archivePath, password, encoding, false);
}

M7ArchiveEntryList m7_archive_test(const char *archivePath, const char *password, const char *encoding) {
    return m7_archive_read_entries(archivePath, password, encoding, true);
}

int m7_archive_extract(const char *archivePath, const char *destinationPath, const char *password, const char *encoding, char **error, M7ExtractProgress *progress) {
    if (error != NULL) { *error = NULL; }

    pthread_once(&m7_locale_once, m7_init_locale);

    struct archive *reader = archive_read_new();
    if (reader == NULL) {
        if (error != NULL) { *error = m7_strdup("Unable to create libarchive reader"); }
        return ARCHIVE_FATAL;
    }

    m7_configure_reader(reader, password, encoding);
    if (archive_read_open_filename(reader, archivePath, 10240) != ARCHIVE_OK) {
        if (error != NULL) { *error = m7_archive_error(reader); }
        archive_read_free(reader);
        return ARCHIVE_FATAL;
    }

    // Resolve the destination through realpath so SECURE_SYMLINKS does not
    // trip on platform-level symlinks like macOS's /var → /private/var. The
    // caller is responsible for creating the destination directory before
    // we get here.
    char *resolvedDestination = NULL;
    if (destinationPath != NULL) {
        resolvedDestination = realpath(destinationPath, NULL);
        if (resolvedDestination == NULL) {
            if (error != NULL) {
                size_t needed = strlen(destinationPath) + 64;
                char *message = (char *)malloc(needed);
                if (message != NULL) {
                    snprintf(message, needed, "Unable to resolve destination path %s", destinationPath);
                    *error = message;
                }
            }
            archive_read_free(reader);
            return ARCHIVE_FATAL;
        }
    }
    const char *effectiveDestination = (resolvedDestination != NULL) ? resolvedDestination : destinationPath;

    int flags = ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT;

    struct archive *writer = archive_write_disk_new();
    if (writer == NULL) {
        if (error != NULL) { *error = m7_strdup("Unable to create libarchive disk writer"); }
        archive_read_free(reader);
        return ARCHIVE_FATAL;
    }
    archive_write_disk_set_options(writer, flags);
    archive_write_disk_set_standard_lookup(writer);

    struct archive_entry *entry = NULL;
    int finalResult = ARCHIVE_OK;

    for (;;) {
        // Check cancellation flag before processing next entry.
        if (progress != NULL && progress->cancel_flag) {
            finalResult = ARCHIVE_OK;
            break;
        }

        int result = archive_read_next_header(reader, &entry);
        if (result == ARCHIVE_EOF) { break; }
        if (result < ARCHIVE_WARN) {
            if (error != NULL) { *error = m7_archive_error(reader); }
            finalResult = result;
            break;
        }

        // The archive's own pathname must stay relative; reject absolute
        // entries before we prepend destinationPath. SECURE_NODOTDOT
        // handles ".." traversal at the writer level.
        const char *originalPath = archive_entry_pathname(entry);
        if (originalPath != NULL && originalPath[0] == '/') {
            if (error != NULL) { *error = m7_strdup("Archive contains an absolute path entry; refusing to extract"); }
            finalResult = ARCHIVE_FATAL;
            break;
        }

        // Rewrite each entry to live under destinationPath so we don't
        // need a process-global chdir to control where extraction goes.
        if (originalPath != NULL && effectiveDestination != NULL) {
            size_t destLen = strlen(effectiveDestination);
            size_t pathLen = strlen(originalPath);
            size_t needed = destLen + 1 + pathLen + 1;
            char *fullPath = (char *)malloc(needed);
            if (fullPath == NULL) {
                if (error != NULL) { *error = m7_strdup("Unable to allocate path buffer for extraction"); }
                finalResult = ARCHIVE_FATAL;
                break;
            }
            if (destLen > 0 && effectiveDestination[destLen - 1] == '/') {
                snprintf(fullPath, needed, "%s%s", effectiveDestination, originalPath);
            } else {
                snprintf(fullPath, needed, "%s/%s", effectiveDestination, originalPath);
            }
            archive_entry_set_pathname(entry, fullPath);
            free(fullPath);
        }

        result = archive_write_header(writer, entry);
        if (result < ARCHIVE_OK) {
            // ARCHIVE_WARN or worse on write_header.  Only abort on
            // real failures (ARCHIVE_FAILED / ARCHIVE_FATAL); warnings
            // are tolerated — skip the entry and continue.
            if (result < ARCHIVE_WARN) {
                if (error != NULL) { *error = m7_archive_error(writer); }
                finalResult = result;
                break;
            }
            archive_read_data_skip(reader);
            archive_write_finish_entry(writer);
            if (progress != NULL) {
                size_t curLen = progress->skipped_paths ? strlen(progress->skipped_paths) : 0;
                size_t addLen = strlen(originalPath);
                char *newPaths = (char *)realloc(progress->skipped_paths, curLen + addLen + 2);
                if (newPaths) {
                    if (curLen > 0) {
                        newPaths[curLen] = '\n';
                        memcpy(newPaths + curLen + 1, originalPath, addLen + 1);
                    } else {
                        memcpy(newPaths, originalPath, addLen + 1);
                    }
                    progress->skipped_paths = newPaths;
                }
                progress->skipped++;
                progress->current++;
            }
            continue;
        }

        // Stream data from reader to writer in blocks, with per-entry
        // error recovery: CRC / data errors skip the entry instead of
        // aborting the entire extraction.
        const void *buffer = NULL;
        size_t size = 0;
        la_int64_t offset = 0;
        int entryError = 0;

        for (;;) {
            int dataResult = archive_read_data_block(reader, &buffer, &size, &offset);
            if (dataResult == ARCHIVE_EOF) { break; }
            if (dataResult < ARCHIVE_WARN) {
                // Fatal read error — abort entire extraction.
                if (error != NULL) { *error = m7_archive_error(reader); }
                finalResult = dataResult;
                break;
            }
            if (dataResult < ARCHIVE_OK) {
                // ARCHIVE_WARN on data read (e.g. CRC mismatch) —
                // skip this entry, continue with next.
                entryError = 1;
                break;
            }
            int writeResult = archive_write_data_block(writer, buffer, size, offset);
            if (writeResult < ARCHIVE_OK) {
                // Write error (disk full, permissions, etc.) —
                // abort entire extraction.
                if (error != NULL) { *error = m7_archive_error(writer); }
                finalResult = writeResult;
                break;
            }
        }
        if (finalResult < ARCHIVE_WARN) { break; }

        if (entryError) {
            archive_read_data_skip(reader);
            archive_write_finish_entry(writer);
            if (progress != NULL) {
                size_t curLen = progress->skipped_paths ? strlen(progress->skipped_paths) : 0;
                size_t addLen = strlen(originalPath);
                char *newPaths = (char *)realloc(progress->skipped_paths, curLen + addLen + 2);
                if (newPaths) {
                    if (curLen > 0) {
                        newPaths[curLen] = '\n';
                        memcpy(newPaths + curLen + 1, originalPath, addLen + 1);
                    } else {
                        memcpy(newPaths, originalPath, addLen + 1);
                    }
                    progress->skipped_paths = newPaths;
                }
                progress->skipped++;
                progress->current++;
            }
            continue;
        }

        result = archive_write_finish_entry(writer);
        if (result < ARCHIVE_WARN) {
            if (error != NULL) { *error = m7_archive_error(writer); }
            finalResult = result;
            break;
        }

        // Update progress after a successful entry.
        if (progress != NULL) { progress->current++; }
    }

    archive_write_close(writer);
    archive_write_free(writer);
    archive_read_close(reader);
    archive_read_free(reader);
    free(resolvedDestination);
    return finalResult < ARCHIVE_WARN ? finalResult : ARCHIVE_OK;
}

int m7_archive_create_zip(const char *archivePath, char **sourcePaths, char **entryPaths, int sourceCount, int compressionLevel, const char *encoding, const char *encryption, const char *password, char **error) {
    if (error != NULL) { *error = NULL; }

    pthread_once(&m7_locale_once, m7_init_locale);

    struct archive *archive = archive_write_new();
    if (archive == NULL) {
        if (error != NULL) { *error = m7_strdup("Unable to create libarchive writer"); }
        return ARCHIVE_FATAL;
    }

    archive_write_add_filter_none(archive);
    archive_write_set_format_zip(archive);

    if (encoding != NULL && encoding[0] != '\0') {
        char encodingOption[256];
        snprintf(encodingOption, sizeof(encodingOption), "zip:hdrcharset=%s", encoding);
        if (archive_write_set_options(archive, encodingOption) != ARCHIVE_OK) {
            if (error != NULL) { *error = m7_archive_error(archive); }
            archive_write_free(archive);
            return ARCHIVE_FATAL;
        }
    }

    char compressionOption[32];
    snprintf(compressionOption, sizeof(compressionOption), "zip:compression-level=%d", compressionLevel);
    if (archive_write_set_options(archive, compressionOption) != ARCHIVE_OK) {
        if (error != NULL) { *error = m7_archive_error(archive); }
        archive_write_free(archive);
        return ARCHIVE_FATAL;
    }

    if (password != NULL && password[0] != '\0') {
        const char *encryptionMethod = (encryption != NULL && encryption[0] != '\0') ? encryption : "aes256";
        char encryptionOption[64];
        snprintf(encryptionOption, sizeof(encryptionOption), "zip:encryption=%s", encryptionMethod);
        if (archive_write_set_options(archive, encryptionOption) != ARCHIVE_OK) {
            if (error != NULL) { *error = m7_archive_error(archive); }
            archive_write_free(archive);
            return ARCHIVE_FATAL;
        }
        if (archive_write_set_passphrase(archive, password) != ARCHIVE_OK) {
            if (error != NULL) { *error = m7_archive_error(archive); }
            archive_write_free(archive);
            return ARCHIVE_FATAL;
        }
    }

    if (archive_write_open_filename(archive, archivePath) != ARCHIVE_OK) {
        if (error != NULL) { *error = m7_archive_error(archive); }
        archive_write_free(archive);
        return ARCHIVE_FATAL;
    }

    char buffer[8192];
    int writtenCount = 0;
    for (int index = 0; index < sourceCount; index++) {
        const char *sourcePath = sourcePaths[index];
        const char *entryPath = entryPaths[index];
        struct stat st;
        if (stat(sourcePath, &st) != 0) {
            return m7_archive_fail_with_message(archive, archivePath, error, "Unable to read source file metadata");
        }

        struct archive_entry *entry = archive_entry_new();
        archive_entry_set_pathname(entry, entryPath != NULL ? entryPath : (strrchr(sourcePath, '/') != NULL ? strrchr(sourcePath, '/') + 1 : sourcePath));
        archive_entry_set_perm(entry, S_ISDIR(st.st_mode) ? 0755 : 0644);
        archive_entry_set_mtime(entry, st.st_mtime, 0);

        if (S_ISDIR(st.st_mode)) {
            archive_entry_set_filetype(entry, AE_IFDIR);
            archive_entry_set_size(entry, 0);
        } else {
            archive_entry_set_filetype(entry, AE_IFREG);
            archive_entry_set_size(entry, st.st_size);
        }

        if (archive_write_header(archive, entry) < ARCHIVE_WARN) {
            char *message = m7_archive_error(archive);
            archive_entry_free(entry);
            return m7_archive_fail_and_cleanup(archive, archivePath, error, message);
        }

        if (encoding != NULL && encoding[0] != '\0') {
            const char *warning = archive_error_string(archive);
            if (warning != NULL && strstr(warning, "Can't translate pathname") != NULL) {
                char *message = m7_strdup(warning);
                archive_entry_free(entry);
                return m7_archive_fail_and_cleanup(archive, archivePath, error, message);
            }
        }

        if (S_ISDIR(st.st_mode)) {
            writtenCount += 1;
            archive_entry_free(entry);
            continue;
        }

        FILE *file = fopen(sourcePath, "rb");
        if (file == NULL) {
            archive_entry_free(entry);
            return m7_archive_fail_with_message(archive, archivePath, error, "Unable to open source file for reading");
        }

        size_t bytesRead = 0;
        while ((bytesRead = fread(buffer, 1, sizeof(buffer), file)) > 0) {
            if (archive_write_data(archive, buffer, bytesRead) < 0) {
                char *message = m7_archive_error(archive);
                fclose(file);
                archive_entry_free(entry);
                return m7_archive_fail_and_cleanup(archive, archivePath, error, message);
            }
        }

        if (ferror(file) != 0) {
            fclose(file);
            archive_entry_free(entry);
            return m7_archive_fail_with_message(archive, archivePath, error, "Unable to read source file contents");
        }

        if (fclose(file) != 0) {
            archive_entry_free(entry);
            return m7_archive_fail_with_message(archive, archivePath, error, "Unable to close source file after reading");
        }

        int finishResult = archive_write_finish_entry(archive);
        if (finishResult < ARCHIVE_WARN) {
            char *message = m7_archive_error(archive);
            archive_entry_free(entry);
            return m7_archive_fail_and_cleanup(archive, archivePath, error, message);
        }

        writtenCount += 1;
        archive_entry_free(entry);
    }

    if (writtenCount == 0) {
        char *message = m7_strdup("No files to add to archive");
        return m7_archive_fail_and_cleanup(archive, archivePath, error, message);
    }

    int closeResult = archive_write_close(archive);
    archive_write_free(archive);
    if (closeResult < ARCHIVE_WARN) {
        if (archivePath != NULL) {
            unlink(archivePath);
        }
        if (error != NULL) { *error = m7_strdup("Unable to close archive writer"); }
        return closeResult;
    }
    return ARCHIVE_OK;
}

void m7_archive_entry_list_free(M7ArchiveEntryList list) {
    for (int index = 0; index < list.count; index++) {
        free(list.entries[index].path);
    }
    free(list.entries);
    free(list.error);
}

void m7_archive_string_free(char *string) {
    free(string);
}
