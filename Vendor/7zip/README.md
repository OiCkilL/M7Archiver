# Vendored 7-Zip CLI

This directory hosts the ip7z `7zz` binary that `SevenZipEngine` shells out to.

## Why bundle, not call system 7zz

Relying on a Homebrew-installed `7zz` is fine for development, but a shipping
M7Archiver app must be self-contained. A bundled binary:

- Works on user machines that have no Homebrew install.
- Pins a known-good version of ip7z so behaviour is reproducible.
- Can be embedded inside `M7Archiver.app/Contents/MacOS/Helpers/7zz` for the
  release `.app` bundle once the Xcode project lands.
- Sets the stage for the eventual in-process C/C++ bridge that QuickLook
  `.appex` extensions will need (subprocesses are blocked by the QuickLook
  sandbox).

## Layout

```
Vendor/7zip/
├── build-7zz.sh   # committed — fetches read-only ip7z source and compiles
├── build/         # git-ignored — per-arch source copy + .o files
├── bin/           # git-ignored — final binary lives here
└── README.md      # this file
```

## Building

```sh
# host arch (fastest, default)
Vendor/7zip/build-7zz.sh

# explicit arch
Vendor/7zip/build-7zz.sh --arch arm64
Vendor/7zip/build-7zz.sh --arch x86_64

# universal binary for release artifacts
Vendor/7zip/build-7zz.sh --universal
```

The script reads `.workflow/reference/7zip` (a frozen ip7z 26.01 tree) as
its source of truth and never modifies it. All build artifacts go into
`Vendor/7zip/build/` and the final binary lands in `Vendor/7zip/bin/7zz`.

## Resolver lookup order

`SevenZipBinaryResolver` searches in this order:

1. `${REPO_ROOT}/Vendor/7zip/bin/7zz` — project-vendored binary (preferred).
2. The auxiliary executable inside the running app bundle, if any.
3. Homebrew / system paths (`/opt/homebrew/bin/7zz`, `/usr/local/bin/7zz`,
   `7z` legacy aliases, `/usr/bin/...`) — last-resort dev fallback.

## Licensing

ip7z is GNU LGPL with the unRAR exception. Bundling the compiled binary in
the app is permitted under LGPL §6 ("compiled work using the library").
We do not bundle ip7z source at runtime, only the `7zz` executable.

The unRAR exception specifically forbids using the unRAR sources to build a
RAR *creator*. M7Archiver only reads RAR archives via libarchive/7zz, never
creates them; RAR creation is gated behind the user-configured external
`rar` CLI in `ExternalRarEngine`. See the project root `CLAUDE.md`.
