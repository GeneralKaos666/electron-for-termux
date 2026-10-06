# electron-for-termux

Build [Electron](https://github.com/electron/electron) for
[Termux](https://termux.dev) (Android) as installable packages.

Forked from
[termux-user-repository/electron-tur-builder](https://github.com/termux-user-repository/electron-tur-builder)
to carry the patch set forward to current Electron releases.

## Layout

- `tur-electron/electron-NN/` — one directory per Electron major:
  `build.sh` (Termux package recipe), `toolchain.gn.in`, and the
  `*.patch` files applied on top of the Electron/Chromium sources.
  A `*.patch.disable` file is a patch retired as upstream-obsolete.
- `tur-electron-2/electron-test/` — scratch/experimental package.
- `.github/workflows/package_electron.yml` — CI: merges
  `termux-packages` + `tur` + this repo, lints, then builds with
  `build-package.sh`. Long Electron builds resume across the
  `build-1 … build-7` jobs via status artifacts.
- `repo.json` — apt repository configuration.

## Current state

Active work: `tur-electron/electron-44/` (Electron 44.5.1 /
Chromium 152). See the commit history for the porting progress
(patch rebases, toolchain updates, CI fixes).

## Build checklist

- [x] 61 patches rebased, dry-run CLEAN vs pinned DEPS
- [x] `gn gen` green (40016 targets)
- [ ] Fix `host/root_store_tool` loader assert
  (`elf_machine_rela_relative`, exit 127)
- [ ] Triage remaining ninja failures to full electron link
- [ ] Zip/deb artifacts produced, CI green

## Building

Trigger a build from the Actions tab with the package name, e.g.
`packages = electron-44` (workflow dispatch). Pushes touching
`tur-electron/**`, `tur-electron-2/**`, or the workflow file build
automatically. Only `aarch64` is built in CI.

## Notes

- Builds require the NDK/Rust/Clang toolchains fetched at configure
  time; see `tur-electron/electron-44/build.sh`.
- `setup-tur-electron-builder.sh` reproduces the CI source merge
  locally (termux-packages + tur + this repo).
