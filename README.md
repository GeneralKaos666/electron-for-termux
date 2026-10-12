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

The ninja graph is roughly 49k steps and the build presses well past
`gpu/command_buffer` into `third_party/blink`. Run `38201485374`
(`f02d2ce`, validating the `XRRigidTransform` fix) advanced past its
predecessor's failure point — `build-1`…`build-3` succeeded — then
died in `build-4`, not on a compile error but because upstream
`termux-packages` `master` moved mid-run: commit `2db8bbc2a8`
("parallelize xz compression") rewrote the two Debian-packaging scripts
tur's building-system patch `0006` targets, so the patch no longer
applied. A repo-local override of `0006` fixes it (see the checklist
and Notes); the run validating it is in flight. Each push to
`tur-electron/**` starts a CI build automatically.

## Build checklist

- [x] 71 patch/diff files for electron-44, each verified with
  `git apply --check` / `check-patch-hunks.py` before landing
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
  - `9999-debug-gn-run-binary.patch` probe still active; revert after
    full-build green.
- [x] `net/cookies/cookie_util.cc` iterators (Termux libc++ = `__wrap_iter`)
  fixed by `1021`
- [x] dawn's `-Xclang=-fno-lifetime-safety-*` flags rejected by the NDK
  clang; fixed by the flag-filter probe, which now scans every
  `BUILD.gn`/`*.gni` and unwraps `-Xclang=`/`-mllvm=` tokens into
  whole-token deny entries (`build.sh`, `64c0b1f`)
- [x] bindgen (harfbuzz `hb_rs_generator`) calls clang directly, bypassing
  the `ndk-flag-filter` wrapper, with the unversioned
  `--target=aarch64-linux-gnu`, so `__ANDROID_MIN_SDK_VERSION__` was
  undefined and the merged sysroot's `sys/cdefs.h` `#error`d; fixed by
  `9999-sysroot-disable-target-check.diff` at sysroot construction
- [x] `//third_party/node:check_version` — the running node (v24.18.0,
  Termux's `node` symlinked in by the old electron-32 trick) must equal
  `update_node_binaries`'s pin (v24.12.0) or the assert aborts the ninja
  graph; fixed by downloading the chromium-pinned node binary via
  `./third_party/node/update_node_binaries` + `update_npm_deps`
  (upstream electron42's approach, `build.sh`)
- [x] libsync `sync_file_info_free` — `__INTRODUCED_IN(26)` in a build
  targeting Android 24; lowered to `__INTRODUCED_IN(24)` in libsync's
  `ndk/sync.h` (`9998-libsync-android24-compat.patch`)
- [x] `optional::value_or({})` deduction class — this build uses released
  libc++ (`use_custom_libcxx = false`), whose `value_or` is
  `template <class _Up>` with no default, so a braced-init-list cannot
  deduce `_Up`. Fixed systemically by defaulting `_Up = value_type` in the
  merged sysroot + live prefix libc++ (`9999-sysroot-libcxx-value-or.diff`),
  plus explicit value-type arguments at the remaining call sites
  (`9997-gfx-value_or-fix.patch`,
  `1022-chromium-gpu-raster-value_or-fix.patch`)
- [x] `XRRigidTransform`'s inline `= default` destructor deleted an
  incomplete `gfx::Transform` — the header only forward-declared
  `gfx::Transform` but the class holds a
  `std::unique_ptr<gfx::Transform>` member, so any translation unit
  that destroyed one instantiated `unique_ptr`'s deleter against the
  incomplete type (released libc++ rejects it with a `unique_ptr.h`
  static_assert; this build died on `xr_cpu_depth_information.cc`).
  Upstream ships the same code and only compiles because its toolchain
  never instantiates the destructor inline, so the fix is local:
  `1023-chromium-blink-xr-rigid-transform-incomplete-type.patch`
  moves the destructor out-of-line — declared in the header, defined
  `= default` in the `.cc` where `gfx::Transform` is complete
- [x] Upstream `termux-packages` drift broke tur's building-system patch
  `0006` mid-run: commit `2db8bbc2a8` ("parallelize xz compression")
  rewrote the Debian-packaging scripts `0006` edits, and because every
  CI job re-clones `master`, `build-4` merged the new scripts while
  `prepare`/`build-1`…`build-3` had merged the old ones. Fixed by a
  repo-local override at
  `common-files/building-system-patches/0006-do-not-xz-when-debug.patch`
  (this repo wins the `cp -rn` no-clobber merge; tur's other patches
  still apply). It keeps upstream's new parallel default
  (`XZ_OPT="-T$TERMUX_PKG_MAKE_PROCESSES"`) and tur's debug `-0`.
  Verified locally against live `master` + `tur`: without the override
  the exact CI rejects reproduce, with it all nine patches apply
- [ ] Triage remaining ninja failures to full electron link
  - after the `value_or` fixes the build passed gpu/command_buffer;
    run `38201485374` advanced past `38115416504`'s failure point
    (`XRRigidTransform`, fixed by `1023`/`f02d2ce`) into `build-4`,
    where it stopped on the upstream-drift issue above rather than a
    compile error
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
- CI merges `termux-packages` and `tur` at `master`, freshly in every
  job, so an upstream change can break tur's building-system patches
  mid-run. When that happens, vendor an adapted override under
  `common-files/building-system-patches/` (same filename as the tur
  patch): this repo is merged first and `cp -rn` never overwrites, so
  the override wins while tur's other patches still apply.

## Known limitation: no resume across fix commits

A fix commit costs a fresh ~19h build. CI artifacts are keyed per
commit (`build-status-*` / `build-deps-*`), and each job hard-fails
if the exact artifact for its commit is missing, so a new commit has
nothing to resume from — only re-runs *of the same commit* pick up
the saved build state (via `build-package.sh -c`, which skips patch
application).

Planned improvement (not yet implemented): on a fresh commit, fall
back to the newest prior-commit build-status/build-deps artifact, and
re-apply the `tur-electron/electron-44/*.patch` set idempotently
before the ninja step so ninja rebuilds only the touched files and
their dependents instead of the whole graph. Caveats: config /
sysroot / toolchain changes still need a fresh run, and a patch
touching a widely-included header would cascade.
