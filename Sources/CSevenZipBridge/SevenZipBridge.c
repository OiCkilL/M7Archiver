#include "CSevenZipBridge.h"

#include "vendor/7zip/C/7z.h"
#include "vendor/7zip/C/7zAlloc.h"
#include "vendor/7zip/C/7zBuf.h"
#include "vendor/7zip/C/7zCrc.h"
#include "vendor/7zip/C/7zFile.h"
#include "vendor/7zip/C/7zTypes.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <utime.h>

#define M7_7Z_INPUT_BUF_SIZE ((size_t)1 << 18)

static const ISzAlloc g_Alloc = { SzAlloc, SzFree };
static const ISzAlloc g_AllocTemp = { SzAllocTemp, SzFreeTemp };
static int g_CrcInit = 0;

static char *m7_strdup(const char *string) {
    if (string == NULL) { return NULL; }
    size_t length = strlen(string) + 1;
    char *copy = malloc(length);
    if (copy != NULL) { memcpy(copy, string, length); }
    return copy;
}

static char *m7_make_error(const char *message) {
    return m7_strdup(message != NULL ? message : "Unknown 7-Zip error");
}

static char *m7_make_errno_error(const char *prefix, int err) {
    const char *suffix = strerror(err);
    if (suffix == NULL) { return m7_make_error(prefix); }
    size_t prefixLen = strlen(prefix);
    size_t suffixLen = strlen(suffix);
    char *buffer = malloc(prefixLen + 2 + suffixLen + 1);
    if (buffer == NULL) { return m7_make_error(prefix); }
    memcpy(buffer, prefix, prefixLen);
    buffer[prefixLen] = ':';
    buffer[prefixLen + 1] = ' ';
    memcpy(buffer + prefixLen + 2, suffix, suffixLen + 1);
    return buffer;
}

static char *m7_make_sz_error(SRes res, WRes wres) {
    switch (res) {
        case SZ_OK: return NULL;
        case SZ_ERROR_UNSUPPORTED: return m7_make_error("7-Zip decoder does not support this archive");
        case SZ_ERROR_MEM: return m7_make_error("7-Zip decoder could not allocate memory");
        case SZ_ERROR_CRC: return m7_make_error("7-Zip CRC error");
        case SZ_ERROR_ARCHIVE: return m7_make_error("7-Zip archive is corrupt");
        case SZ_ERROR_NO_ARCHIVE: return m7_make_error("File is not a 7-Zip archive");
        case SZ_ERROR_INPUT_EOF: return m7_make_error("Unexpected end of 7-Zip input stream");
        case SZ_ERROR_READ:
            return m7_make_errno_error("7-Zip read error", (int)wres);
        default: {
            char buffer[64];
            snprintf(buffer, sizeof(buffer), "7-Zip error %d", (int)res);
            return m7_make_error(buffer);
        }
    }
}

static void m7_crc_init_once(void) {
    if (!g_CrcInit) {
        CrcGenerateTable();
        g_CrcInit = 1;
    }
}

static int64_t m7_ntfs_time_to_unix(CNtfsFileTime value) {
    UInt64 ticks = ((UInt64)value.High << 32) | value.Low;
    if (ticks == 0) { return -1; }
    return (int64_t)(ticks / 10000000ULL - 11644473600ULL);
}

static int m7_is_entry_encrypted(const CSzArEx *db, UInt32 fileIndex) {
    UInt32 folderIndex = db->FileToFolder[fileIndex];
    if (folderIndex == (UInt32)-1) { return 0; }
    size_t offset = db->db.FoCodersOffsets[folderIndex];
    size_t limit = db->db.FoCodersOffsets[(size_t)folderIndex + 1] - offset;
    CSzData data;
    data.Data = db->db.CodersData + offset;
    data.Size = limit;
    while (data.Size > 0) {
        CSzFolder folder;
        if (SzGetNextFolderItem(&folder, &data) != SZ_OK) { break; }
        for (UInt32 i = 0; i < folder.NumCoders; i++) {
            if (folder.Coders[i].MethodID == 0x6F10701U) {
                return 1; // 7zAES
            }
        }
    }
    return 0;
}

static SRes m7_utf16_to_utf8(Byte *dest, const UInt16 *src, const UInt16 *srcLim) {
    while (src < srcLim) {
        UInt32 value = *src++;
        if (value < 0x80) {
            *dest++ = (Byte)value;
            continue;
        }
        if (value < 0x800) {
            *dest++ = (Byte)(0xC0 | (value >> 6));
            *dest++ = (Byte)(0x80 | (value & 0x3F));
            continue;
        }
        if (value >= 0xD800 && value <= 0xDBFF && src < srcLim) {
            UInt32 low = *src;
            if (low >= 0xDC00 && low <= 0xDFFF) {
                src++;
                value = 0x10000 + (((value - 0xD800) << 10) | (low - 0xDC00));
            }
        }
        if (value < 0x10000) {
            *dest++ = (Byte)(0xE0 | (value >> 12));
            *dest++ = (Byte)(0x80 | ((value >> 6) & 0x3F));
            *dest++ = (Byte)(0x80 | (value & 0x3F));
        } else {
            *dest++ = (Byte)(0xF0 | (value >> 18));
            *dest++ = (Byte)(0x80 | ((value >> 12) & 0x3F));
            *dest++ = (Byte)(0x80 | ((value >> 6) & 0x3F));
            *dest++ = (Byte)(0x80 | (value & 0x3F));
        }
    }
    *dest = 0;
    return SZ_OK;
}

static char *m7_utf16_path_to_utf8(const UInt16 *src, size_t lengthWithNul) {
    if (lengthWithNul == 0) { return m7_strdup(""); }
    size_t srcLen = lengthWithNul - 1;
    size_t capacity = srcLen * 4 + 1;
    char *buffer = malloc(capacity);
    if (buffer == NULL) { return NULL; }
    if (m7_utf16_to_utf8((Byte *)buffer, src, src + srcLen) != SZ_OK) {
        free(buffer);
        return NULL;
    }
    return buffer;
}

static int m7_append_entry(M7SevenZipEntryList *list, M7SevenZipEntry entry) {
    M7SevenZipEntry *entries = realloc(list->entries, sizeof(M7SevenZipEntry) * (size_t)(list->count + 1));
    if (entries == NULL) {
        list->error = m7_make_error("Unable to allocate 7-Zip entry list");
        free(entry.path);
        return 0;
    }
    list->entries = entries;
    list->entries[list->count] = entry;
    list->count += 1;
    return 1;
}

typedef struct {
    CFileInStream archiveStream;
    CLookToRead2 lookStream;
    CSzArEx db;
    SRes res;
} M7SevenZipContext;

static void m7_7z_context_init(M7SevenZipContext *context) {
    memset(context, 0, sizeof(*context));
    File_Construct(&context->archiveStream.file);
    FileInStream_CreateVTable(&context->archiveStream);
    context->archiveStream.wres = 0;
    LookToRead2_CreateVTable(&context->lookStream, False);
    SzArEx_Init(&context->db);
}

static void m7_7z_context_free(M7SevenZipContext *context) {
    SzArEx_Free(&context->db, &g_Alloc);
    ISzAlloc_Free(&g_Alloc, context->lookStream.buf);
    File_Close(&context->archiveStream.file);
}

static SRes m7_7z_open_context(M7SevenZipContext *context, const char *archivePath) {
    m7_crc_init_once();
    m7_7z_context_init(context);

    context->archiveStream.wres = InFile_Open(&context->archiveStream.file, archivePath);
    if (context->archiveStream.wres != 0) {
        return SZ_ERROR_READ;
    }

    context->lookStream.buf = (Byte *)ISzAlloc_Alloc(&g_Alloc, M7_7Z_INPUT_BUF_SIZE);
    if (context->lookStream.buf == NULL) {
        return SZ_ERROR_MEM;
    }
    context->lookStream.bufSize = M7_7Z_INPUT_BUF_SIZE;
    context->lookStream.realStream = &context->archiveStream.vt;
    LookToRead2_INIT(&context->lookStream);

    return SzArEx_Open(&context->db, &context->lookStream.vt, &g_Alloc, &g_AllocTemp);
}

static M7SevenZipEntryList m7_7z_read_entries(const char *archivePath, int readData) {
    M7SevenZipEntryList list;
    memset(&list, 0, sizeof(list));

    M7SevenZipContext context;
    SRes res = m7_7z_open_context(&context, archivePath);
    if (res != SZ_OK) {
        list.error = m7_make_sz_error(res, context.archiveStream.wres);
        m7_7z_context_free(&context);
        return list;
    }

    UInt32 blockIndex = 0xFFFFFFFF;
    Byte *outBuffer = NULL;
    size_t outBufferSize = 0;

    for (UInt32 i = 0; i < context.db.NumFiles; i++) {
        size_t nameLen = SzArEx_GetFileNameUtf16(&context.db, i, NULL);
        UInt16 *temp = (UInt16 *)SzAlloc(NULL, nameLen * sizeof(UInt16));
        if (temp == NULL) {
            list.error = m7_make_error("Unable to allocate 7-Zip filename buffer");
            break;
        }
        SzArEx_GetFileNameUtf16(&context.db, i, temp);
        char *utf8 = m7_utf16_path_to_utf8(temp, nameLen);
        SzFree(NULL, temp);
        if (utf8 == NULL) {
            list.error = m7_make_error("Unable to convert 7-Zip filename to UTF-8");
            break;
        }

        M7SevenZipEntry entry;
        entry.path = utf8;
        entry.size = (int64_t)SzArEx_GetFileSize(&context.db, i);
        entry.modifiedAt = SzBitWithVals_Check(&context.db.MTime, i)
            ? m7_ntfs_time_to_unix(context.db.MTime.Vals[i])
            : -1;
        entry.isDirectory = SzArEx_IsDir(&context.db, i);
        entry.isEncrypted = m7_is_entry_encrypted(&context.db, i) != 0;
        if (entry.isEncrypted) {
            list.isEncrypted = true;
        }
        if (!m7_append_entry(&list, entry)) { break; }

        if (readData && !entry.isDirectory) {
            size_t offset = 0;
            size_t outSizeProcessed = 0;
            res = SzArEx_Extract(
                &context.db,
                &context.lookStream.vt,
                i,
                &blockIndex,
                &outBuffer,
                &outBufferSize,
                &offset,
                &outSizeProcessed,
                &g_Alloc,
                &g_AllocTemp
            );
            if (res != SZ_OK) {
                list.error = m7_make_sz_error(res, context.archiveStream.wres);
                break;
            }
        }
    }

    ISzAlloc_Free(&g_Alloc, outBuffer);
    m7_7z_context_free(&context);
    return list;
}

M7SevenZipEntryList m7_7z_list(const char *archivePath) {
    return m7_7z_read_entries(archivePath, 0);
}

M7SevenZipEntryList m7_7z_test(const char *archivePath) {
    return m7_7z_read_entries(archivePath, 1);
}

int m7_7z_extract(const char *archivePath, const char *destinationPath, char **error, M7SevenZipExtractProgress *progress) {
    if (error != NULL) { *error = NULL; }
#if defined(M7_DEBUG_7Z_EXTRACT)
    FILE *dbg = fopen("/tmp/m7_7z_debug.log", "a");
    if (dbg) { fprintf(dbg, "[m7_7z_extract] ENTER archive=%s dest=%s progress=%p\n", archivePath, destinationPath, (void*)progress); }
#endif

    M7SevenZipContext context;
    SRes res = m7_7z_open_context(&context, archivePath);
#if defined(M7_DEBUG_7Z_EXTRACT)
    if (dbg) { fprintf(dbg, "[m7_7z_extract] SzArEx_Open returned %d (%s)\n", (int)res, res == SZ_OK ? "OK" : res == SZ_ERROR_CRC ? "CRC" : res == SZ_ERROR_DATA ? "DATA" : "OTHER"); }
#endif
    if (res != SZ_OK) {
        if (error != NULL) { *error = m7_make_sz_error(res, context.archiveStream.wres); }
        m7_7z_context_free(&context);
#if defined(M7_DEBUG_7Z_EXTRACT)
        if (dbg) { fprintf(dbg, "[m7_7z_extract] FAIL before loop, returning %d\n", (int)res); fclose(dbg); }
#endif
        return res;
    }

#if defined(M7_DEBUG_7Z_EXTRACT)
    if (dbg) { fprintf(dbg, "[m7_7z_extract] NumFiles=%u progress->skipped_init=%d progress->current_init=%lld\n", context.db.NumFiles, progress ? (int)progress->skipped : -1, progress ? (long long)progress->current : -1); }
#endif

    UInt32 blockIndex = 0xFFFFFFFF;
    Byte *outBuffer = NULL;
    size_t outBufferSize = 0;

    for (UInt32 i = 0; i < context.db.NumFiles; i++) {
#if defined(M7_DEBUG_7Z_EXTRACT)
        if (dbg) { fprintf(dbg, "[m7_7z_extract] LOOP i=%u/%u\n", i, context.db.NumFiles); }
#endif
        // Check cancellation flag before processing next entry.
        if (progress != NULL && progress->cancel_flag) {
#if defined(M7_DEBUG_7Z_EXTRACT)
            if (dbg) { fprintf(dbg, "[m7_7z_extract] CANCELLED at i=%u\n", i); }
#endif
            break;
        }

        size_t nameLen = SzArEx_GetFileNameUtf16(&context.db, i, NULL);
        UInt16 *temp = (UInt16 *)SzAlloc(NULL, nameLen * sizeof(UInt16));
        if (temp == NULL) {
            res = SZ_ERROR_MEM;
            break;
        }
        SzArEx_GetFileNameUtf16(&context.db, i, temp);
        char *utf8 = m7_utf16_path_to_utf8(temp, nameLen);
        SzFree(NULL, temp);
        if (utf8 == NULL) {
            res = SZ_ERROR_MEM;
            break;
        }

        char *fullPath = NULL;
        size_t destLen = strlen(destinationPath);
        size_t relLen = strlen(utf8);
        fullPath = malloc(destLen + 1 + relLen + 1);
        if (fullPath == NULL) {
            free(utf8);
            res = SZ_ERROR_MEM;
            break;
        }
        memcpy(fullPath, destinationPath, destLen);
        fullPath[destLen] = '/';
        memcpy(fullPath + destLen + 1, utf8, relLen + 1);

        if (SzArEx_IsDir(&context.db, i)) {
            if (mkdir(fullPath, 0777) != 0 && errno != EEXIST) {
                if (error != NULL) { *error = m7_make_errno_error("Unable to create extracted directory", errno); }
                free(utf8);
                free(fullPath);
                res = SZ_ERROR_WRITE;
                break;
            }
            free(utf8);
            free(fullPath);
            if (progress != NULL) { progress->current++; }
            continue;
        }

        char *separator = fullPath + destLen + 1;
        int entryError = 0;
        while ((separator = strchr(separator, '/')) != NULL) {
            *separator = 0;
            if (mkdir(fullPath, 0777) != 0 && errno != EEXIST) {
                if (error != NULL) { *error = m7_make_errno_error("Unable to create extracted directory", errno); }
                free(utf8);
                free(fullPath);
                res = SZ_ERROR_WRITE;
                entryError = 1;
                break;
            }
            *separator = '/';
            separator++;
        }
        if (entryError) { break; }

        size_t offset = 0;
        size_t outSizeProcessed = 0;
        res = SzArEx_Extract(
            &context.db,
            &context.lookStream.vt,
            i,
            &blockIndex,
            &outBuffer,
            &outBufferSize,
            &offset,
            &outSizeProcessed,
            &g_Alloc,
            &g_AllocTemp
        );
#if defined(M7_DEBUG_7Z_EXTRACT)
        if (dbg) { fprintf(dbg, "[m7_7z_extract] i=%u SzArEx_Extract returned res=%d blockIndex=0x%x outBuffer=%p outBufferSize=%zu offset=%zu outSizeProcessed=%zu\n", i, (int)res, blockIndex, (void*)outBuffer, outBufferSize, offset, outSizeProcessed); }
#endif
        if (res == SZ_ERROR_CRC || res == SZ_ERROR_DATA) {
#if defined(M7_DEBUG_7Z_EXTRACT)
            if (dbg) { fprintf(dbg, "[m7_7z_extract] i=%u DATA_ERROR res=%d -> SKIP, blockIndex_before=%u\n", i, (int)res, blockIndex); }
#endif
            // Data corruption on this file — skip it and continue.
            // Record the skipped file path for user notification.
            if (progress != NULL) {
                size_t curLen = progress->skipped_paths ? strlen(progress->skipped_paths) : 0;
                size_t addLen = strlen(utf8);
                char *newPaths = (char *)realloc(progress->skipped_paths, curLen + addLen + 2);
                if (newPaths) {
                    if (curLen > 0) {
                        newPaths[curLen] = '\n';
                        memcpy(newPaths + curLen + 1, utf8, addLen + 1);
                    } else {
                        memcpy(newPaths, utf8, addLen + 1);
                    }
                    progress->skipped_paths = newPaths;
                }
                progress->skipped++;
                progress->current++;
            }
            blockIndex = 0xFFFFFFFF;
            ISzAlloc_Free(&g_Alloc, outBuffer);
            outBuffer = NULL;
            outBufferSize = 0;
            free(utf8);
            free(fullPath);
            continue;
        }
        if (res != SZ_OK) {
#if defined(M7_DEBUG_7Z_EXTRACT)
            if (dbg) { fprintf(dbg, "[m7_7z_extract] i=%u FATAL_ERROR res=%d -> BREAK\n", i, (int)res); }
#endif
            // Non-data errors (memory, write, archive structure) are fatal.
            if (error != NULL) { *error = m7_make_sz_error(res, context.archiveStream.wres); }
            free(utf8);
            free(fullPath);
            break;
        }

        CSzFile outFile;
        File_Construct(&outFile);
        WRes wres = OutFile_Open(&outFile, fullPath);
        if (wres != 0) {
            if (error != NULL) { *error = m7_make_errno_error("Unable to open extracted file", (int)wres); }
            free(utf8);
            free(fullPath);
            res = SZ_ERROR_WRITE;
            break;
        }

        size_t processedSize = outSizeProcessed;
        wres = File_Write(&outFile, outBuffer + offset, &processedSize);
        File_Close(&outFile);
        if (wres != 0 || processedSize != outSizeProcessed) {
            if (error != NULL) { *error = m7_make_errno_error("Unable to write extracted file", (int)(wres != 0 ? wres : EIO)); }
            free(utf8);
            free(fullPath);
            res = SZ_ERROR_WRITE;
            break;
        }

        if (SzBitWithVals_Check(&context.db.MTime, i)) {
            struct utimbuf times;
            times.actime = times.modtime = (time_t)m7_ntfs_time_to_unix(context.db.MTime.Vals[i]);
            utime(fullPath, &times);
        }

        free(utf8);
        free(fullPath);
        if (progress != NULL) { progress->current++; }
    }

#if defined(M7_DEBUG_7Z_EXTRACT)
    if (dbg) {
        fprintf(dbg, "[m7_7z_extract] END res=%d progress->skipped=%d progress->current=%lld\n",
                (int)res, progress ? (int)progress->skipped : -1, progress ? (long long)progress->current : -1);
        fclose(dbg);
    }
#endif
    ISzAlloc_Free(&g_Alloc, outBuffer);
    m7_7z_context_free(&context);
    return res;
}

void m7_7z_entry_list_free(M7SevenZipEntryList list) {
    for (int i = 0; i < list.count; i++) {
        free(list.entries[i].path);
    }
    free(list.entries);
    free(list.error);
}

void m7_7z_string_free(char *string) {
    free(string);
}
