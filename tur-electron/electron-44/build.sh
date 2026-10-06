TERMUX_PKG_HOMEPAGE=https://github.com/electron/electron
TERMUX_PKG_DESCRIPTION="Build cross-platform desktop apps with JavaScript, HTML, and CSS"
TERMUX_PKG_LICENSE="MIT, BSD 3-Clause"
TERMUX_PKG_MAINTAINER="Chongyun Lee <uchkks@protonmail.com>"
_CHROMIUM_VERSION=152.0.7977.130
TERMUX_PKG_VERSION=44.5.1
TERMUX_PKG_SRCURL=git+https://github.com/electron/electron
TERMUX_PKG_DEPENDS="electron-deps"
TERMUX_PKG_BUILD_DEPENDS="libnotify, libffi-static"
# Chromium doesn't support i686 on Linux.
TERMUX_PKG_BLACKLISTED_ARCHES="i686"

__tur_setup_depot_tools() {
	export DEPOT_TOOLS_UPDATE=0
	if [ ! -f "$TERMUX_PKG_CACHEDIR/.depot_tools-fetched" ]; then
		git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git $TERMUX_PKG_CACHEDIR/depot_tools
		touch "$TERMUX_PKG_CACHEDIR/.depot_tools-fetched"
	fi
	export PATH="$TERMUX_PKG_CACHEDIR/depot_tools:$PATH"
	export CHROMIUM_BUILDTOOLS_PATH="$TERMUX_PKG_SRCDIR/buildtools"
	# DEPOT_TOOLS_UPDATE=0 suppresses depot_tools' self-bootstrap, so `gn`
	# fails with "python3_bin_reldir.txt not found" on fresh runners/caches.
	# Bootstrap the hermetic Python explicitly when the stamp is missing.
	if [ ! -f "$TERMUX_PKG_CACHEDIR/depot_tools/python3_bin_reldir.txt" ]; then
		(env -u DEPOT_TOOLS_UPDATE "$TERMUX_PKG_CACHEDIR/depot_tools/ensure_bootstrap")
	fi
}

termux_step_get_source() {
	# Check whether we need to get source
	if [ -f "$TERMUX_PKG_CACHEDIR/.electron-source-fetched" ]; then
		local _fetched_source_version=$(cat $TERMUX_PKG_CACHEDIR/.electron-source-fetched)
		if [ "$_fetched_source_version" = "$TERMUX_PKG_VERSION" ]; then
			echo "[INFO]: Use pre-fetched source (version $_fetched_source_version)."
			ln -sfr $TERMUX_PKG_CACHEDIR/tmp-checkout/src $TERMUX_PKG_SRCDIR
			# Revert patches
			shopt -s nullglob
			local f
			for f in $TERMUX_PKG_BUILDER_DIR/*.patch; do
				echo "[INFO]: Reverting $(basename "$f")"
				(sed "s|@TERMUX_PREFIX@|$TERMUX_PREFIX|g" "$f" | patch -f --silent -R -p1 -d "$TERMUX_PKG_SRCDIR") || true
			done
			shopt -u nullglob
			python $TERMUX_SCRIPTDIR/common-files/apply-chromium-patches.py --electron -C "$TERMUX_PKG_SRCDIR" -R -v $_CHROMIUM_VERSION || bash
			return
		fi
	fi

	# Fetch depot_tools
	__tur_setup_depot_tools

	# Install nodejs
	termux_setup_nodejs

	# Get source
	rm -rf "$TERMUX_PKG_CACHEDIR/tmp-checkout"
	mkdir -p "$TERMUX_PKG_CACHEDIR/tmp-checkout"
	pushd "$TERMUX_PKG_CACHEDIR/tmp-checkout"
	gclient config --name "src/electron" --unmanaged https://github.com/electron/electron
	gclient sync --with_branch_heads --with_tags --no-history --revision v$TERMUX_PKG_VERSION || bash
	popd

	# Solve error like `.git/packed-refs is dirty`
	cd "$TERMUX_PKG_CACHEDIR/tmp-checkout/src"
	git pack-refs --all
	cd electron
	git pack-refs --all

	echo "$TERMUX_PKG_VERSION" >"$TERMUX_PKG_CACHEDIR/.electron-source-fetched"
	ln -sfr $TERMUX_PKG_CACHEDIR/tmp-checkout/src $TERMUX_PKG_SRCDIR
}

termux_step_post_get_source() {
	echo "$TERMUX_PKG_VERSION" >$TERMUX_PKG_SRCDIR/electron/ELECTRON_VERSION
	# v44's build/timestamp.gni runs compute_build_timestamp.py, which reads
	# build/util/LASTCHANGE.committime. gclient hooks cannot generate it for
	# --no-history checkouts, so fall back to the current time when the file
	# is missing, empty, or not a timestamp.
	local _lastchange_committime=$TERMUX_PKG_SRCDIR/build/util/LASTCHANGE.committime
	if ! grep -qE '^[0-9]+$' "$_lastchange_committime" 2>/dev/null; then
		date +%s >"$_lastchange_committime"
	fi
}

termux_step_configure() {
	cd $TERMUX_PKG_SRCDIR
	termux_setup_ninja
	termux_setup_nodejs
	__tur_setup_depot_tools

	# v44 enables -f/-m compiler flags that predate Termux's NDK clang,
	# which hard-errors on unknown arguments (warnings are already covered
	# by -Wno-unknown-warning-option). Probe every hard flag Chromium may
	# pass against the real NDK compiler and generate wrapper scripts that
	# strip the rejected ones, so future flag additions degrade to a
	# re-probe instead of a failed build. Host toolchains use explicit
	# upstream clang paths and never see these wrappers.
	# Flags are either literals (exact match) or prefixes ending in '='
	# (for GN-interpolated forms like -fsanitize-ignore-for-ubsan-feature
	# whose values only exist at gen time); prefixes are probed with an
	# empty value and stripped only when clang reports them unknown (as
	# opposed to complaining about the value).
	local _ndk_filter_dir="$TERMUX_PKG_CACHEDIR/ndk-flag-filter"
	rm -rf "$_ndk_filter_dir"
	mkdir -p "$_ndk_filter_dir"
	local _real_cc="$CC" _real_cxx="${CXX:-$CC}"
	local _flag_list _flag_pfx _f _probe_err
	_flag_list="$(grep -ho '"-[fm][A-Za-z0-9-]*\(=[^"]*\)\?"' build/config/compiler/BUILD.gn build/config/sanitizers/sanitizers.gni | tr -d '"' | sort -u || true)"
	_flag_pfx="$(grep -ho '"-[fm][A-Za-z0-9-]*=' build/config/compiler/BUILD.gn build/config/sanitizers/sanitizers.gni | tr -d '"' | sort -u || true)"
	local _deny_file="$_ndk_filter_dir/denylist.txt"
	local _pfx_file="$_ndk_filter_dir/prefixlist.txt"
	: >"$_deny_file"
	: >"$_pfx_file"
	for _f in $_flag_list; do
		case "$_f" in
		*\${* | *\ *) continue ;;
		-mllvm | -Xclang) continue ;;
		esac
		if ! echo 'int _termux_probe_flag;' | "$_real_cxx" -x c++ -fsyntax-only "$_f" -o /dev/null - 2>/dev/null; then
			echo "$_f" >>"$_deny_file"
		fi
	done
	for _f in $_flag_pfx; do
		case "$_f" in
		*\${* | *\ *) continue ;;
		esac
		# Probe with a dummy value: an unknown flag reports "unknown
		# argument" regardless of value, while a known flag complains
		# about the value instead (or accepts it) and must be kept.
		# (The || true is load-bearing: a failing probe must not trip
		# set -e/pipefail here.)
		_probe_err="$(echo 'int _termux_probe_flag;' | "$_real_cxx" -x c++ -fsyntax-only "${_f}test" -o /dev/null - 2>&1)" || true
		case "$_probe_err" in
		*"unknown argument"*) echo "$_f" >>"$_pfx_file" ;;
		esac
	done
	# Android triple for this build arch; gnu --target args are
	# retargeted to it (a gnu triple breaks NDK libc++ search).
	local _ndk_triple
	case "$TERMUX_ARCH" in
	aarch64) _ndk_triple="aarch64-linux-android${TERMUX_PKG_API_LEVEL}" ;;
	arm) _ndk_triple="armv7a-linux-androideabi${TERMUX_PKG_API_LEVEL}" ;;
	i686) _ndk_triple="i686-linux-android${TERMUX_PKG_API_LEVEL}" ;;
	x86_64) _ndk_triple="x86_64-linux-android${TERMUX_PKG_API_LEVEL}" ;;
	*) _ndk_triple="" ;;
	esac
	local _wrap_name _wrap_real _wrap_pat
	for _wrap_name in "$(basename "$_real_cc")" "$(basename "$_real_cxx")"; do
		if [ "$_wrap_name" = "$(basename "$_real_cxx")" ]; then
			_wrap_real="$_real_cxx"
		else
			_wrap_real="$_real_cc"
		fi
		{
			echo '#!/bin/bash'
			echo '# Generated by electron-44 build.sh: strips -f/-m flags'
			echo '# rejected by the NDK compiler (see denylist.txt).'
			echo 'declare -A _DENY=()'
			while IFS= read -r _wrap_pat || [ -n "$_wrap_pat" ]; do
				case "$_wrap_pat" in "" | \#*) continue ;; esac
				printf '_DENY[%q]=1\n' "$_wrap_pat"
			done <"$_deny_file"
			echo "_TRIPLE=\"$_ndk_triple\""
			printf '_PFX_LIST="'
			while IFS= read -r _wrap_pat || [ -n "$_wrap_pat" ]; do
				case "$_wrap_pat" in "" | \#*) continue ;; esac
				printf '%s ' "$_wrap_pat"
			done <"$_pfx_file"
			printf '"\n'
			echo '_ARGS=()'
			echo '_SKIP_NEXT=0'
			echo 'for _a in "$@"; do'
			echo '  if [ "$_SKIP_NEXT" = 1 ]; then _SKIP_NEXT=0; continue; fi'
			echo '  case "$_a" in --target=*-gnu*) if [ -n "$_TRIPLE" ]; then _a="--target=$_TRIPLE"; fi;; esac'
			echo '  if [ -n "${_DENY[$_a]:-}" ]; then'
			echo '    case "$_a" in -mllvm|-Xclang) _SKIP_NEXT=1;; esac'
			echo '    continue'
			echo '  fi'
			echo '  _DROP=0'
			echo '  if [ -n "${_DENY[$_a]:-}" ]; then _DROP=1; fi'
			echo '  if [ "$_DROP" = 0 ]; then'
			echo '    for _k in $_PFX_LIST; do'
			echo '      case "$_a" in "$_k"*) _DROP=1; break;; esac'
			echo '    done'
			echo '  fi'
			echo '  if [ "$_DROP" = 1 ]; then'
			echo '    case "$_a" in -mllvm|-Xclang) _SKIP_NEXT=1;; esac'
			echo '    continue'
			echo '  fi'
			echo '  _ARGS+=("$_a")'
			echo 'done'
			echo "exec \"$_wrap_real\" \"\${_ARGS[@]}\""
		} >"$_ndk_filter_dir/$_wrap_name"
		chmod +x "$_ndk_filter_dir/$_wrap_name"
	done
	export CC="$_ndk_filter_dir/$(basename "$_real_cc")"
	export CXX="$_ndk_filter_dir/$(basename "$_real_cxx")"

	# Remove termux's dummy pkg-config
	local _target_pkg_config=$(command -v pkg-config)
	local _host_pkg_config="$(cat $_target_pkg_config | grep exec | awk '{print $2}')"
	rm -rf $TERMUX_PKG_CACHEDIR/host-pkg-config-bin
	mkdir -p $TERMUX_PKG_CACHEDIR/host-pkg-config-bin
	ln -s $_host_pkg_config $TERMUX_PKG_CACHEDIR/host-pkg-config-bin/pkg-config
	export PATH="$TERMUX_PKG_CACHEDIR/host-pkg-config-bin:$PATH"

	# Install deps
	env -i PATH="$PATH" sudo apt update
	env -i PATH="$PATH" sudo apt install lsb-release -yq
	env -i PATH="$PATH" sudo apt install libfontconfig1 libfontconfig1:i386 -yq
	env -i PATH="$PATH" sudo ./build/install-build-deps.sh --lib32 --no-syms --no-android --no-arm --no-chromeos-fonts --no-nacl --no-prompt

	# Setup rust toolchain and clang toolchain
	./tools/rust/update_rust.py
	./tools/clang/scripts/update.py

	# Ensure the Android compiler-rt builtins our clang_lib patch references
	# exist where GN expects them (lib/clang/18/lib/linux). The standalone
	# NDK's layout and runtime set change across releases, so resolve each
	# archive from anywhere in the NDK tree first, then the full NDK, then
	# the upstream clang package, and link/copy it into place.
	shopt -s nullglob
	local _bt _bt_candidates _bt_src _bt_dest_dir _bt_dest
	_bt_dest_dir="$TERMUX_STANDALONE_TOOLCHAIN/lib/clang/18/lib/linux"
	mkdir -p "$_bt_dest_dir"
	for _bt in libclang_rt.builtins-aarch64-android.a libclang_rt.builtins-arm-android.a libclang_rt.builtins-x86_64-android.a libclang_rt.builtins-i686-android.a libclang_rt.builtins.a; do
		_bt_dest="$_bt_dest_dir/$_bt"
		[ -e "$_bt_dest" ] && continue
		_bt_src=""
		for _bt_candidates in "$TERMUX_STANDALONE_TOOLCHAIN"/lib/clang/*/lib/linux/"$_bt" "$TERMUX_STANDALONE_TOOLCHAIN"/lib64/clang/*/lib/linux/"$_bt" "${NDK:-}"/toolchains/llvm/prebuilt/*/lib/clang/*/lib/linux/"$_bt" "$PWD"/third_party/llvm-build/Release+Asserts/lib/clang/*/lib/linux/"$_bt"; do
			[ -f "$_bt_candidates" ] || continue
			_bt_src="$_bt_candidates"
			break
		done
		if [ -n "$_bt_src" ]; then
			echo "[rt] providing $_bt from $_bt_src"
			if [[ "$_bt_src" == "$TERMUX_STANDALONE_TOOLCHAIN"* ]]; then
				ln -sfn "$_bt_src" "$_bt_dest"
			else
				cp -f "$_bt_src" "$_bt_dest"
			fi
		else
			echo "[rt] WARNING: no source found for $_bt"
		fi
	done
	shopt -u nullglob

	# Install amd64 rootfs if necessary, it should have been installed by source hooks.
	build/linux/sysroot_scripts/install-sysroot.py --sysroots-json-path=electron/script/sysroots.json --arch=amd64
	local _amd64_sysroot_path="$(pwd)/build/linux/$(ls build/linux | grep 'amd64-sysroot')"

	# Install i386 rootfs if necessary, it should have been installed by source hooks.
	build/linux/sysroot_scripts/install-sysroot.py --sysroots-json-path=electron/script/sysroots.json --arch=i386
	local _i386_sysroot_path="$(pwd)/build/linux/$(ls build/linux | grep 'i386-sysroot')"

	# Link to system tools required by the build
	mkdir -p third_party/node/linux/node-linux-x64/bin
	ln -sf $(command -v node) third_party/node/linux/node-linux-x64/bin/

	# Dummy librt.so
	# Why not dummy a librt.a? Some of the binaries reference symbols only exists in Android
	# for some reason, such as the `chrome_crashpad_handler`, which needs to link with
	# libprotobuf_lite.a, but it is hard to remove the usage of `android/log.h` in protobuf.
	echo "INPUT(-llog -liconv -landroid-shmem)" >"$TERMUX_PREFIX/lib/librt.so"

	# Dummy libpthread.a and libresolv.a
	echo '!<arch>' >"$TERMUX_PREFIX/lib/libpthread.a"
	echo '!<arch>' >"$TERMUX_PREFIX/lib/libresolv.a"

	# Symlink libffi.a to libffi_pic.a
	ln -sfr $TERMUX_PREFIX/lib/libffi.a $TERMUX_PREFIX/lib/libffi_pic.a

	# Merge sysroots
	if [ ! -d "$TERMUX_PKG_CACHEDIR/sysroot-$TERMUX_ARCH" ]; then
		rm -rf $TERMUX_PKG_TMPDIR/sysroot
		mkdir -p $TERMUX_PKG_TMPDIR/sysroot
		pushd $TERMUX_PKG_TMPDIR/sysroot
		mkdir -p usr/include usr/lib usr/bin
		cp -R $TERMUX_STANDALONE_TOOLCHAIN/sysroot/usr/include/* usr/include
		cp -R $TERMUX_STANDALONE_TOOLCHAIN/sysroot/usr/include/$TERMUX_HOST_PLATFORM/* usr/include
		cp -R $TERMUX_STANDALONE_TOOLCHAIN/sysroot/usr/lib/$TERMUX_HOST_PLATFORM/$TERMUX_PKG_API_LEVEL/* usr/lib/
		cp "$TERMUX_STANDALONE_TOOLCHAIN/sysroot/usr/lib/$TERMUX_HOST_PLATFORM/libc++_shared.so" usr/lib/
		cp "$TERMUX_STANDALONE_TOOLCHAIN/sysroot/usr/lib/$TERMUX_HOST_PLATFORM/libc++_static.a" usr/lib/
		cp "$TERMUX_STANDALONE_TOOLCHAIN/sysroot/usr/lib/$TERMUX_HOST_PLATFORM/libc++abi.a" usr/lib/
		cp -Rf $TERMUX_PREFIX/include/* usr/include
		cp -Rf $TERMUX_PREFIX/lib/* usr/lib
		ln -sf /data ./data
		# This is needed to build crashpad
		rm -rf $TERMUX_PREFIX/include/spawn.h
		# This is needed to build cups
		cp -Rf $TERMUX_PREFIX/bin/cups-config usr/bin/
		chmod +x usr/bin/cups-config
		popd
		mv $TERMUX_PKG_TMPDIR/sysroot $TERMUX_PKG_CACHEDIR/sysroot-$TERMUX_ARCH
	fi

	# Construct args
	local _clang_base_path="$PWD/third_party/llvm-build/Release+Asserts"
	local _host_cc="$_clang_base_path/bin/clang"
	local _host_cxx="$_clang_base_path/bin/clang++"
	local _host_clang_version=$($_host_cc --version | grep -m1 version | sed -E 's|.*\bclang version ([0-9]+).*|\1|')
	local _target_cpu _target_sysroot="$TERMUX_PKG_CACHEDIR/sysroot-$TERMUX_ARCH"
	local _v8_toolchain_name _v8_current_cpu _v8_sysroot_path
	if [ "$TERMUX_ARCH" = "aarch64" ]; then
		_target_cpu="arm64"
		_v8_current_cpu="x64"
		_v8_sysroot_path="$_amd64_sysroot_path"
		_v8_toolchain_name="clang_x64_v8_arm64"
	elif [ "$TERMUX_ARCH" = "arm" ]; then
		_target_cpu="arm"
		_v8_current_cpu="x86"
		_v8_sysroot_path="$_i386_sysroot_path"
		_v8_toolchain_name="clang_x86_v8_arm"
	elif [ "$TERMUX_ARCH" = "x86_64" ]; then
		_target_cpu="x64"
		_v8_current_cpu="x64"
		_v8_sysroot_path="$_amd64_sysroot_path"
		_v8_toolchain_name="clang_x64"
	fi

	local _common_args_file=$TERMUX_PKG_TMPDIR/common-args-file
	rm -f $_common_args_file
	touch $_common_args_file

	echo "
import(\"$TERMUX_PKG_SRCDIR/electron/build/args/release.gn\")
override_electron_version = \"$TERMUX_PKG_VERSION\"
# Do not build with symbols
symbol_level = 0
# Use our custom toolchain
clang_version = \"$_host_clang_version\"
use_sysroot = false
target_cpu = \"$_target_cpu\"
target_rpath = \"$TERMUX_PREFIX/lib\"
target_sysroot = \"$_target_sysroot\"
custom_toolchain = \"//build/toolchain/linux/unbundle:default\"
custom_toolchain_clang_base_path = \"$TERMUX_STANDALONE_TOOLCHAIN\"
# v44 (chromium 152): host clang is 23; NDK custom pin kept at 18 until CI gn gen confirms NDK major on ubuntu-latest.
custom_toolchain_clang_version = "18"
host_toolchain = \"$TERMUX_PKG_CACHEDIR/custom-toolchain:host\"
v8_snapshot_toolchain = \"$TERMUX_PKG_CACHEDIR/custom-toolchain:$_v8_toolchain_name\"
electron_js2c_toolchain = \"$TERMUX_PKG_CACHEDIR/custom-toolchain:$_v8_toolchain_name\"
clang_use_chrome_plugins = false
dcheck_always_on = false
chrome_pgo_phase = 0
treat_warnings_as_errors = false
# Use system libraries as little as possible
use_bundled_fontconfig = false
use_system_freetype = false
use_system_libdrm = false
# Chromium defaults use_system_libffi to false on Linux: libffi must be
# statically linked (ffi_pic) so host tools don't pick up a runtime
# libffi.so.7 from the bullseye sysroot (trips Ubuntu 24.04 glibc
# RELACOUNT assert in ld.so). Target still resolves -lffi_pic via the
# $PREFIX symlink + merged sysroot below; host via the sysroot static.
use_system_libffi = false
use_custom_libcxx = false
use_custom_libcxx_for_host = true
use_allocator_shim = false
use_partition_alloc_as_malloc = false
# Termux uses the system C++ library (Bionic) instead of the in-tree
# hardened libc++, but v44's V8 sandbox asserts on hardened libc++.
# The OS sandbox is already disabled on Termux, so disable the V8
# sandbox too rather than fight Bionic with a bundled libc++.
v8_enable_sandbox = false
enable_backup_ref_ptr_slow_checks = false
enable_dangling_raw_ptr_checks = false
enable_dangling_raw_ptr_feature_flag = false
backup_ref_ptr_extra_oob_checks = false
enable_backup_ref_ptr_support = false
enable_pointer_compression_support = false
use_nss_certs = true
use_udev = false
use_alsa = false
use_libpci = false
use_pulseaudio = true
use_ozone = true
# Electron does not use Chromoting; disabling keeps the pipewire
# runtime-loader probe (remoting/host) out of the Termux sysroot,
# which has no libpipewire.
enable_remoting = false
ozone_auto_platforms = false
ozone_platform = \"x11\"
ozone_platform_x11 = true
ozone_platform_wayland = true
ozone_platform_headless = true
angle_enable_vulkan = true
angle_enable_swiftshader = true
angle_enable_abseil = false
rtc_use_pipewire = false
use_vaapi = false
# See comments on Chromium package
# (enable_nacl removed upstream: NaCl no longer exists in v44, so the
# explicit false would only warn as having no effect.)
is_cfi = false
use_cfi_icall = false
use_thin_lto = false
# Enable rust
# (The NDK Rust triple is selected per-CPU by our rust.gni patch;
# no build arg needed.)
llvm_android_mainline = true
exclude_unwind_tables = false
" >>$_common_args_file

	if [ "$TERMUX_ARCH" = "arm" ]; then
		echo "arm_arch = \"armv7-a\"" >>$_common_args_file
		echo "arm_float_abi = \"softfp\"" >>$_common_args_file
	fi

	# Use custom toolchain
	mkdir -p $TERMUX_PKG_CACHEDIR/custom-toolchain
	cp -f $TERMUX_PKG_BUILDER_DIR/toolchain.gn.in $TERMUX_PKG_CACHEDIR/custom-toolchain/BUILD.gn
	sed -i "s|@HOST_CC@|$_host_cc|g
			s|@HOST_CXX@|$_host_cxx|g
			s|@HOST_LD@|$_host_cxx|g
			s|@HOST_AR@|$(command -v llvm-ar)|g
			s|@HOST_NM@|$(command -v llvm-nm)|g
			s|@HOST_IS_CLANG@|true|g
			s|@HOST_USE_GOLD@|false|g
			s|@HOST_SYSROOT@|$_amd64_sysroot_path|g
			" $TERMUX_PKG_CACHEDIR/custom-toolchain/BUILD.gn
	sed -i "s|@V8_CC@|$_host_cc|g
			s|@V8_CXX@|$_host_cxx|g
			s|@V8_LD@|$_host_cxx|g
			s|@V8_AR@|$(command -v llvm-ar)|g
			s|@V8_NM@|$(command -v llvm-nm)|g
			s|@V8_TOOLCHAIN_NAME@|$_v8_toolchain_name|g
			s|@V8_CURRENT_CPU@|$_v8_current_cpu|g
			s|@V8_V8_CURRENT_CPU@|$_target_cpu|g
			s|@V8_IS_CLANG@|true|g
			s|@V8_USE_GOLD@|false|g
			s|@V8_SYSROOT@|$_v8_sysroot_path|g
			" $TERMUX_PKG_CACHEDIR/custom-toolchain/BUILD.gn

	# Generate ninja files
	mkdir -p $TERMUX_PKG_BUILDDIR/out/Release
	cat $_common_args_file >$TERMUX_PKG_BUILDDIR/out/Release/args.gn
	gn gen $TERMUX_PKG_BUILDDIR/out/Release
}

termux_step_make() {
	cd $TERMUX_PKG_BUILDDIR
	# depot_tools' ninja.py wrapper aborts with "Could not find checkout"
	# because our build dir is a sibling of src, so resolve the real ninja
	# binary that termux_setup_ninja installed with depot_tools off PATH.
	local _real_ninja="$(PATH="$(echo "$PATH" | tr ':' '\n' | grep -v 'depot_tools' | paste -sd:)" command -v ninja)"
	"$_real_ninja" -C $TERMUX_PKG_BUILDDIR/out/Release electron:node_headers electron electron_license chromium_licenses
	rm -rf "$TERMUX_PKG_CACHEDIR/sysroot-$TERMUX_ARCH"
}

termux_step_make_install() {
	cd $TERMUX_PKG_BUILDDIR
	local _install_prefix=$TERMUX_PREFIX/opt/electron-$TERMUX_PKG_VERSION
	mkdir -p $_install_prefix

	echo "$TERMUX_PKG_VERSION" >$TERMUX_PKG_BUILDDIR/out/Release/version

	local normal_files=(
		# Binary files
		electron
		chrome_sandbox
		chrome_crashpad_handler

		# Resource files
		chrome_100_percent.pak
		chrome_200_percent.pak
		resources.pak

		# V8 Snapshot data
		snapshot_blob.bin
		v8_context_snapshot.bin

		# ICU Data
		icudtl.dat

		# Angle
		libEGL.so
		libGLESv2.so

		# Vulkan
		libvulkan.so.1
		libvk_swiftshader.so
		vk_swiftshader_icd.json

		# FFmpeg
		libffmpeg.so

		# VERSION file
		version
	)

	cp "${normal_files[@]/#/out/Release/}" "$_install_prefix/"

	cp -Rf out/Release/angledata $_install_prefix/
	cp -Rf out/Release/locales $_install_prefix/
	cp -Rf out/Release/resources $_install_prefix/

	chmod +x $_install_prefix/electron

	# Install LICENSE file
	cp out/Release/LICENSE{,S.chromium.html} $_install_prefix/
}

termux_step_install_license() {
	mkdir -p $TERMUX_PREFIX/share/doc/$TERMUX_PKG_NAME
	cp out/Release/LICENSE{,S.chromium.html} $TERMUX_PREFIX/share/doc/$TERMUX_PKG_NAME/
}

termux_step_post_make_install() {
	# Remove the dummy files
	rm $TERMUX_PREFIX/lib/lib{{pthread,resolv,ffi_pic}.a,rt.so}
}

termux_step_post_massage() {
	# Except the deb file, we also create a zip file like electron release
	local _TARGET_CPU="$TERMUX_ARCH"
	if [ "$TERMUX_ARCH" = "aarch64" ]; then
		_TARGET_CPU="arm64"
	elif [ "$TERMUX_ARCH" = "x86_64" ]; then
		_TARGET_CPU="x64"
	elif [ "$TERMUX_ARCH" = "arm" ]; then
		_TARGET_CPU="armv7l"
	fi

	mkdir -p $TERMUX_SCRIPTDIR/output-electron

	pushd $TERMUX_PREFIX/opt/electron-$TERMUX_PKG_VERSION
	zip -r $TERMUX_SCRIPTDIR/output-electron/electron-v$TERMUX_PKG_VERSION-linux-$_TARGET_CPU.zip ./*
	popd
}
