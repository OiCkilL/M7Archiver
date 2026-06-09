# Vendored libarchive

`Vendor/libarchive/` ships a project-built universal static `libarchive.a`
plus the two public headers `CLibArchiveBridge.c` consumes. This replaces
the previous Homebrew dependency, which was arm64-only and required users
to `brew install libarchive` on every dev machine.

## Layout

```
Vendor/libarchive/
├── build-libarchive.sh   # committed — cmake-based universal build
├── build/                # git-ignored — source copy + cmake build dir
├── lib/                  # git-ignored — libarchive.a (universal)
├── include/              # git-ignored — archive.h, archive_entry.h
└── README.md             # this file
```

## Building

```sh
Vendor/libarchive/build-libarchive.sh
```

Output:
- `Vendor/libarchive/lib/libarchive.a` — universal (arm64 + x86_64) static
- `Vendor/libarchive/include/archive.h`
- `Vendor/libarchive/include/archive_entry.h`

The script reads `.workflow/reference/libarchive/` (a frozen libarchive
3.7.x tree) as its source of truth and never modifies it.

## Format coverage

This build statically links zlib + bzip2 (universal, ship with macOS at
`/usr/lib`). Optional Homebrew-only deps are disabled:

| Format       | libarchive (this build) | SevenZipEngine (`7zz`) |
| ------------ | ----------------------- | ---------------------- |
| zip          | ✓                       | ✓                      |
| 7z (read)    | ✓ (built-in LZMA SDK)   | ✓                      |
| tar          | ✓                       | ✓                      |
| gzip / .gz   | ✓                       | ✓                      |
| bzip2 / .bz2 | ✓                       | ✓                      |
| ar, cpio, iso, xar, mtree | ✓          | (limited)              |
| xz / .xz     | ✗                       | ✓                      |
| zstd / .zst  | ✗                       | ✓                      |
| lz4 / .lz4   | ✗                       | ✓                      |
| tar.xz / .tar.zst / .tar.lz4 | ✗           | ✓                      |
| rar          | ✓ (read only)           | ✓ (read only)          |

The format catalog in `Sources/ArchiveCore/Formats/ArchiveFormatCatalog.json`
routes xz / zstd / lz4 / tar.{xz,zst,lz4} to `sevenZip` so users still see
working list / extract behaviour even though libarchive itself can't read
them in this build.

## Why not bundle xz / zstd / lz4 deps too

Each optional compressor would need a universal build of its own (with
universal versions of its own deps). That is a multi-day rabbit hole.
ip7z `7zz` already handles all of them, and it's already shipped under
`Vendor/7zip/`. Re-using it for those formats is the smaller, cleaner
move.

## Licensing

libarchive is BSD 2-clause. The static archive can be statically linked
into the M7Archiver app without source-disclosure obligations. The two
header files we vendor are part of the same BSD-licensed distribution.
