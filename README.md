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
- [x] Fix `host/root_store_tool` loader assert
  (`elf_machine_rela_relative`, exit 127)
  - Root cause: orphaned `0007` patch preloaded the sysroot libffi.so.7
    link stub (dangling DT_RELA + RELACOUNT=20) into every `./host/` tool;
    its own relocation asserted before the tool's map started.
  - Fix: static host libffi (`42e5f50`) + delete the LD_PRELOAD half
    (`da560e0`). Verified in run `37607641031`: 0 ld.so asserts, gated trio
    passed (`preexec RELACOUNT-on-disk=0`), build advanced 1h04m past the
    historical failure point.
  - `9999` probe still active; revert after full-build green.
- [ ] Triage remaining ninja failures to full electron link
  - `net/cookies/cookie_util.cc` iterators (Termux libc++ = `__wrap_iter`)
    fixed by `1021` — verified: build advanced to step 11776/80202.
  - dawn's `-Xclang=-fno-lifetime-safety-*` flags rejected by the NDK
    clang; fixed by the flag-filter probe, which now scans every
    `BUILD.gn`/`*.gni` and unwraps `-Xclang=`/`-mllvm=` tokens into
    whole-token deny entries (`build.sh`, `64c0b1f`) — verified in run
    `37711204662`: build sailed past dawn to the harfbuzz step.
  - bindgen (harfbuzz `hb_rs_generator`) called clang directly —
    bypassing the `ndk-flag-filter` wrapper — with the unversioned
    `--target=aarch64-linux-gnu`, so `__ANDROID_MIN_SDK_VERSION__`
    was undefined and the merged sysroot's `sys/cdefs.h` `#error`d.
    Fixed by `9999-sysroot-disable-target-check.diff`, applied over the
    merged sysroot at construction time (`build.sh`) — verified in run
    `37729925790`: the build passed bindgen and advanced 1h21m to step
    14519/80202 (webrtc/viz/crashpad territory).
  - Current blocker: `//third_party/node:check_version` — the running
    node (v24.18.0, Termux's `node` symlinked in by the old electron-32
    trick) must equal `update_node_binaries`'s pin (v24.12.0) or the
    assert aborts the ninja graph. Fixed by adopting upstream electron42's
    approach: download the chromium-pinned node binary via
    `./third_party/node/update_node_binaries` + `update_npm_deps`
    (`build.sh`). Self-consistent: the checker and downloader read the
    same `update_node_binaries`.
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
