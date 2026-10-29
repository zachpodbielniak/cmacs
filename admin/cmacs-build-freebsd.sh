#!/usr/local/bin/bash
# cmacs-build-freebsd.sh - Build and stage cmacs on FreeBSD
#
# The FreeBSD counterpart of the builder stage in Containerfile: installs the
# build dependencies with pkg(8), builds the canonical dependencies (crispy,
# yaml-glib, mcp-glib, bacon, gowl, ai-glib, podomation, libreclaw), runs
# autogen/configure with the same --with-cmacs-* options the Containerfile
# uses (read from it, so a new feature reaches FreeBSD too), builds, and
# installs into a staging directory. Everything goes under /usr/local, where
# FreeBSD keeps software that is not part of the base system.
#
# Runs as root on FreeBSD 15.x: in Containerfile.freebsd (./build-container
# freebsd-15.1) or directly on a FreeBSD machine.
#
# Usage:
#   admin/cmacs-build-freebsd.sh [options] <step>...
#
# Steps (in order; `all' runs every one):
#   packages     pkg install the build dependencies
#   deps         build and install the canonical dependencies
#   configure    autogen.sh and configure
#   build        gmake
#   install      gmake install into the staging directory, plus cmacs-mcp,
#                the gowl session file and container-release
#   all          every step above
#
# Options:
#   --stage DIR  staging directory for `install' (default /build/stage)
#   --jobs N     parallel jobs (default: every core)
#   -h, --help   Show this help message
#   --license    Show license information
#
# Examples:
#   admin/cmacs-build-freebsd.sh all
#   admin/cmacs-build-freebsd.sh --jobs 8 deps configure build
#   ./build-container freebsd-15.1
#
# Exit codes:
#   0 - Success
#   1 - A step failed
#   2 - Usage error

set -euo pipefail

SRC="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="/usr/local"
LIBDIR="${PREFIX}/lib"
STAGE="/build/stage"
JOBS="$(sysctl -n hw.ncpu)"

# Emacs itself is compiled with gcc13 and native-compiles through gcc13's
# libgccjit. FreeBSD's gcc14 libgccjit (14.2) corrupts the heap at random
# during compile_to_file/context_release: about one native compile in five
# crashed (SIGSEGV/SIGBUS inside libgccjit and jemalloc, or hung when
# Emacs's fatal-signal handler then deadlocked in rtld), worst under make -j.
# The same cmacs against gcc13's libgccjit: 48/48 clean under full load.
# FreeBSD's own emacs port uses gcc13 for native compilation as well. The
# in-house C libraries stay on gcc (14); they are plain C.
EMACS_CC="gcc13"
EMACS_GCC_LIBDIR="${PREFIX}/lib/gcc13"

# Build dependencies by FreeBSD package name: the Containerfile's Fedora list
# mapped across, plus what the in-house libraries need here (evdev-proto for
# <linux/input-event-codes.h>, elfutils for cintrospect's libdw, gcc for
# gnu89 C, gcc13 for Emacs and its libgccjit).
PACKAGES=(
	autoconf automake bash binutils cairo cmake-core cmark curl elfutils
	espeak-ng evdev-proto ffmpeg gcc gcc13 giflib git glib gmake gnutls
	gobject-introspection gstreamer1 gstreamer1-libav gstreamer1-plugins
	gstreamer1-plugins-bad gstreamer1-plugins-good gstreamer1-plugins-ugly
	gtk3 gtk4 harfbuzz jansson jpeg-turbo json-glib libX11 libXcursor libXft
	libXi libXinerama libXpm libXrandr libadwaita libdecor libdex libdrm
	libei libetpan libgudev libinput libotf libsoup3 libspnav libssh2
	libvirt libxcb libxkbcommon libxml2 libyaml libzip m17n-lib mesa-libs
	onnxruntime opencascade openxr pango pipewire pixman pkgconf
	poppler-utils postgresql17-client pulseaudio readline sqlite3 texinfo
	tiff tree-sitter wayland wayland-protocols webkit2-gtk_41 webp
	wl-clipboard wlroots020 xcb-util-wm
)

# The canonical dependency builds, in the Containerfile's order.
CMACS_DEPS=(
	deps/mcp-glib deps/crispy deps/bacon deps/gowl deps/ai-glib
	deps/podomation deps/clawtilla/deps/libreclaw
)


show_help () {
	sed -n '2,/^# Exit codes/p' "$0" | sed -e '/^# Exit codes/d' -e 's/^# \{0,1\}//'
}


log () {
	echo "==> $*" >&2
}


# Environment every step builds in: ports' pkg-config directories, gcc for
# C (the house compiler; FreeBSD's cc is clang), and gmake for every
# Makefile, since the in-house projects are GNU make throughout.
build_env () {
	export PKG_CONFIG_PATH="${LIBDIR}/pkgconfig:${PREFIX}/libdata/pkgconfig:${PREFIX}/share/pkgconfig"
	export CC=gcc
	export MAKE=gmake
}


# FreeBSD only adds the library directories ports register (FFmpeg 6,
# gcc's runtime, ...) to the loader hints at boot, and a container build
# never boots; several dependencies' installs also run ldconfig. Rebuild
# the hints from /usr/local/libdata/ldconfig, as rc.d/ldconfig does.
refresh_ldconfig () {
	local dirs=()

	mapfile -t dirs < <(cat "${PREFIX}"/libdata/ldconfig/* 2> /dev/null || true)
	ldconfig -m "${LIBDIR}" "${dirs[@]}"
}


step_packages () {
	log "installing build dependencies"
	env ASSUME_ALWAYS_YES=yes pkg install -y "${PACKAGES[@]}"
	refresh_ldconfig
}


step_deps () {
	local canon
	local dep
	local gir

	build_env
	canon=(
		"CRISPY_DIR=${SRC}/deps/crispy"
		"YAMLGLIB_DIR=${SRC}/deps/yaml-glib"
		"YAML_GLIB_DIR=${SRC}/deps/yaml-glib"
		"MCP_GLIB_DIR=${SRC}/deps/mcp-glib"
		"BACON_DIR=${SRC}/deps/bacon"
		"AI_GLIB_DIR=${SRC}/deps/ai-glib"
		"PODOMATION_DIR=${SRC}/deps/podomation"
		"PREFIX=${PREFIX}"
		"LIBDIR=${LIBDIR}"
	)
	cd "${SRC}"

	log "canonical dependencies"
	for dep in "${CMACS_DEPS[@]}"
	do
		gmake -C "${dep}" clean "${canon[@]}"
	done
	gmake -C deps/crispy lib "${canon[@]}"
	gmake -C deps/yaml-glib clean DEBUG=0 "${canon[@]}"
	gmake -C deps/yaml-glib lib DEBUG=0 "${canon[@]}"
	gmake -C deps/mcp-glib "${canon[@]}"
	for dep in "${CMACS_DEPS[@]}"
	do
		gir=""
		case "${dep}" in
			*/ai-glib) gir="GIR=1" ;;
			*) ;;
		esac
		gmake -C "${dep}" -j"${JOBS}" all ${gir:+"${gir}"} "${canon[@]}"
		gmake -C "${dep}" install ${gir:+"${gir}"} "${canon[@]}"
	done
	refresh_ldconfig

	log "cad-glib vendored dependencies"
	gmake -C deps/cad-glib deps
}


step_configure () {
	local opts=()

	build_env
	cd "${SRC}"
	# The configure options, as the Containerfile passes them (all but
	# --prefix): one list for every distribution. Plus kqueue for file
	# notification, as FreeBSD's own emacs uses: FreeBSD 15 now has
	# inotify(2), so configure would pick Emacs's inotify backend, whose
	# watches FreeBSD rejects with EINVAL.
	mapfile -t opts < <(sed -n '/^RUN \.\/autogen\.sh/,/make -j/p' Containerfile \
		| grep -o -- '--[a-z0-9=-]*' | grep -v -- '^--prefix')
	log "configure (${#opts[@]} options, ${EMACS_CC})"
	./autogen.sh
	CC="${EMACS_CC}" \
	LDFLAGS="-L${EMACS_GCC_LIBDIR} -Wl,-rpath,${EMACS_GCC_LIBDIR}" \
		./configure --prefix="${PREFIX}" "${opts[@]}" \
			--with-file-notification=kqueue
}


step_build () {
	build_env
	cd "${SRC}"
	log "building with ${JOBS} jobs"
	gmake -j"${JOBS}"
}


step_install () {
	build_env
	cd "${SRC}"
	log "installing into ${STAGE}"
	gmake -j"${JOBS}" install DESTDIR="${STAGE}"
	gmake -C tools/cmacs-mcp clean all PREFIX="${PREFIX}"
	gmake -C tools/cmacs-mcp install PREFIX="${PREFIX}" DESTDIR="${STAGE}"

	# libcmacs-api.so and friends live in ${LIBDIR}/cmacs. Emacs finds
	# them through its rpath, but modules other programs load (bacon's
	# cmacs_gi, ...) need the loader to know the directory. Linux gets
	# /etc/ld.so.conf.d/cmacs.conf (Containerfile); FreeBSD's rc.d/ldconfig
	# reads one directory per line from /usr/local/libdata/ldconfig/.
	mkdir -p "${STAGE}${PREFIX}/libdata/ldconfig"
	echo "${LIBDIR}/cmacs" > "${STAGE}${PREFIX}/libdata/ldconfig/cmacs"

	mkdir -p "${STAGE}${PREFIX}/share/cmacs"
	{
		echo "distro=freebsd"
		echo "release=$(freebsd-version -u | cut -d- -f1)"
		echo "libdir=${LIBDIR}"
		echo "arch=$(uname -m)"
		echo "bundled_wayland=no"
		echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "version=$(sed -n 's/^AC_INIT(\[GNU Emacs\], *\[\([^]]*\)\].*/\1/p' configure.ac | head -1)"
	} > "${STAGE}${PREFIX}/share/cmacs/container-release"
	cat "${STAGE}${PREFIX}/share/cmacs/container-release"
}


main () {
	local steps=()
	local step

	while [[ $# -gt 0 ]]
	do
		case "$1" in
			-h|--help) show_help; return 0 ;;
			--license) echo 'cmacs-build-freebsd.sh - part of cmacs. GPL-3.0-or-later.'; return 0 ;;
			--stage) STAGE="$2"; shift ;;
			--jobs) JOBS="$2"; shift ;;
			all) steps+=(packages deps configure build install) ;;
			packages|deps|configure|build|install) steps+=("$1") ;;
			*) show_help >&2; return 2 ;;
		esac
		shift
	done
	if [[ ${#steps[@]} -eq 0 ]]
	then
		show_help >&2
		return 2
	fi
	if [[ "$(uname -s)" != "FreeBSD" ]]
	then
		log "this builds cmacs for FreeBSD and runs on FreeBSD"
		return 2
	fi

	for step in "${steps[@]}"
	do
		"step_${step}"
	done
}


main "$@"
