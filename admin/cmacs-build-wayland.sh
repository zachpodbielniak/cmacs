#!/usr/bin/env bash
# cmacs-build-wayland.sh -- build the Wayland stack from source when the
# distro's is too old for gowl.
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# gowl needs wlroots >= 0.19; Ubuntu 24.04 (noble) ships 0.17, along
# with wayland 1.22 (wlroots wants >= 1.23.1) and pixman 0.42 (wants
# >= 0.43).  Everything else -- Fedora 44, Arch, Ubuntu 26.04 -- has a
# usable wlroots in its repositories and this script exits immediately.
#
# Shared by the Containerfile and admin/cmacs-distrobox.sh, so the two
# cannot drift: this block used to live inline in the Containerfile, and
# a second copy of a list with this many silent traps is a copy that
# goes stale.
#
# The probe is on pkg-config rather than on the distro version, so a
# release that starts shipping a new enough wlroots stops building it
# from source without anyone editing this file.
#
# Two details that are easy to get wrong, both silent:
#
#   * libdir.  Installing to /usr/lib on Debian/Ubuntu does NOT shadow
#     the distro's libraries: /usr/lib/<triplet>/pkgconfig is searched
#     first, so meson happily reports "found 1.22.0 but need >=1.23.1"
#     with a freshly built 1.23.1 sitting in /usr/lib.  The libdir is
#     therefore taken from the multiarch triplet.
#
#   * staging (--stage only).  The container's final image is only
#     /build/stage, so a library built here and installed to the
#     builder's /usr is NOT in the image -- the result links against
#     wayland 1.23 symbols and lands on a host that has 1.22.  With
#     --stage the install is done twice: once into /usr so cmacs can
#     build, and once into a scratch DESTDIR whose libdir alone is copied
#     into the stage.  Headers are deliberately left behind; the image
#     must not shadow the distro's wayland headers for anything else the
#     user compiles.  A distrobox needs no stage: the box IS the system.
#
# libwayland and pixman have only ever added to their ABI, so the newer
# copies satisfy every existing consumer.  wlroots 0.19 carries its
# version in its soname and coexists with the distro's 0.17.
#
# Versions come from the environment so the Containerfile's ARGs keep
# working unchanged: WAYLAND_VERSION, WAYLAND_PROTOCOLS_VERSION,
# PIXMAN_VERSION, WLROOTS_VERSION.

set -euo pipefail

: "${WAYLAND_VERSION:=1.23.1}"
: "${WAYLAND_PROTOCOLS_VERSION:=1.41}"
: "${PIXMAN_VERSION:=pixman-0.44.2}"
: "${WLROOTS_VERSION:=0.19}"

STAGE=""
WORKDIR=""

# Root is needed to install into /usr.  A container build is already
# root and usually has no sudo at all; a distrobox user has sudo.
if [[ "${EUID:-$(id -u)}" -eq 0 ]]
then
	SUDO=()
else
	SUDO=(sudo)
fi

usage () {
	cat <<'EOF'
Usage: admin/cmacs-build-wayland.sh [--stage DIR] [--workdir DIR]

Build wayland, wayland-protocols, pixman and wlroots from source and
install them into /usr -- but only when pkg-config finds no wlroots
0.19/0.20.  A no-op on every distro that packages a usable one.

  --stage DIR    Also copy the built libraries (libdir only, no headers,
                 no .pc) into DIR/usr/<libdir> and touch
                 DIR/.bundled-wayland.  Used by the Containerfile.
  --workdir DIR  Where to clone and build (default: a mktemp dir,
                 removed afterwards).
  -h, --help     Show this help
  --license      Show the license

Examples:
  admin/cmacs-build-wayland.sh                       # distrobox / host
  admin/cmacs-build-wayland.sh --stage /build/stage  # Containerfile
  WLROOTS_VERSION=0.20 admin/cmacs-build-wayland.sh
EOF
}

# have_usable_wlroots
#
# True when pkg-config already sees a wlroots gowl can build against.
have_usable_wlroots () {
	pkg-config --exists wlroots-0.20 || pkg-config --exists wlroots-0.19
}

# install_build_deps
#
# The from-source build's own dependencies.  Only Debian/Ubuntu has ever
# needed this path; on anything else the distro wlroots is new enough.
# Echoes the libdir to install into.
install_build_deps () {
	local libdir="lib64"

	if command -v apt-get >/dev/null 2>&1
	then
		export DEBIAN_FRONTEND=noninteractive
		"${SUDO[@]}" apt-get install -y --no-install-recommends --no-remove \
			meson ninja-build git ca-certificates \
			libffi-dev libexpat1-dev libxml2-dev docbook-xsl xsltproc \
			libudev-dev libseat-dev libdisplay-info-dev libliftoff-dev \
			hwdata libgbm-dev libvulkan-dev glslang-tools \
			libxcb-composite0-dev libxcb-ewmh-dev \
			libxcb-render-util0-dev libxcb-res0-dev libxcb-xinput-dev \
			libxcb-dri3-dev libxcb-present-dev libxcb-shm0-dev \
			libxcb-xfixes0-dev libxcb-randr0-dev \
			python3-setuptools >&2
		"${SUDO[@]}" apt-get install -y --no-install-recommends --no-remove \
			libxcb-errors-dev >&2 \
			|| echo "NOTE: no libxcb-errors-dev; X11 errors print as codes" >&2
		libdir="lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
	fi

	echo "${libdir}"
}

# build_stack <libdir> <workdir> <scratch-destdir>
#
# Clone, build and install each component in dependency order.  Each
# one is installed (and ldconfig'd) before the next is configured,
# because every later component finds the earlier ones via pkg-config.
build_stack () {
	if [[ $# -ne 3 ]]
	then
		echo 'build_stack() requires 3 positional arguments' >&2
		echo 'build_stack <libdir> <workdir> <scratch-destdir>' >&2
		exit 1
	fi

	local libdir="${1}"
	local workdir="${2}"
	local scratch="${3}"
	local spec name rest url ref opts
	local -a specs opt_words

	specs=(
		"wayland|https://gitlab.freedesktop.org/wayland/wayland.git|${WAYLAND_VERSION}|-Ddocumentation=false -Dtests=false"
		"wayland-protocols|https://gitlab.freedesktop.org/wayland/wayland-protocols.git|${WAYLAND_PROTOCOLS_VERSION}|-Dtests=false"
		"pixman|https://gitlab.freedesktop.org/pixman/pixman.git|${PIXMAN_VERSION}|-Dtests=disabled -Ddemos=disabled"
		"wlroots|https://gitlab.freedesktop.org/wlroots/wlroots.git|${WLROOTS_VERSION}|-Dexamples=false -Dbackends=drm,libinput,x11 -Drenderers=gles2,vulkan"
	)

	for spec in "${specs[@]}"
	do
		name="${spec%%|*}"; rest="${spec#*|}"
		url="${rest%%|*}"; rest="${rest#*|}"
		ref="${rest%%|*}"; opts="${rest#*|}"
		read -r -a opt_words <<< "${opts}"

		echo "==> ${name} ${ref}"
		# A rerun after a failure finds the previous clone; start the
		# component over rather than trusting a half-configured tree.
		rm -rf "${workdir:?}/${name}"
		git clone --depth 1 -b "${ref}" "${url}" "${workdir}/${name}"
		meson setup "${workdir}/${name}/build" "${workdir}/${name}" \
			--prefix=/usr --libdir="${libdir}" "${opt_words[@]}"
		ninja -C "${workdir}/${name}/build"
		"${SUDO[@]}" ninja -C "${workdir}/${name}/build" install
		if [[ -n "${scratch}" ]]
		then
			DESTDIR="${scratch}" ninja -C "${workdir}/${name}/build" install
		fi
		"${SUDO[@]}" ldconfig
	done
}

main () {
	local libdir workdir scratch="" own_workdir=0

	while [[ $# -gt 0 ]]
	do
		case "${1}" in
			-h|--help)  usage; exit 0 ;;
			--license)  echo "AGPL-3.0-or-later"; exit 0 ;;
			--stage)    STAGE="${2:?--stage needs a directory}"; shift ;;
			--workdir)  WORKDIR="${2:?--workdir needs a directory}"; shift ;;
			*)          echo "Unknown option: ${1}" >&2; usage >&2; exit 1 ;;
		esac
		shift
	done

	if have_usable_wlroots
	then
		echo "==> Distro wlroots is usable:"
		pkg-config --modversion wlroots-0.20 2>/dev/null \
			|| pkg-config --modversion wlroots-0.19
		exit 0
	fi

	echo "==> No usable wlroots; building the Wayland stack from source"
	libdir="$(install_build_deps)"
	echo "==> Wayland stack libdir: /usr/${libdir}"

	if [[ -z "${WORKDIR}" ]]
	then
		WORKDIR="$(mktemp -d)"
		own_workdir=1
	fi
	workdir="${WORKDIR}"
	mkdir -p "${workdir}"
	if [[ -n "${STAGE}" ]]
	then
		scratch="${workdir}/wayland-stage"
		mkdir -p "${scratch}"
	fi

	build_stack "${libdir}" "${workdir}" "${scratch}"

	# Only the libdir reaches the stage: no headers, no pkg-config
	# files.  See the header comment.
	if [[ -n "${STAGE}" ]]
	then
		mkdir -p "${STAGE}/usr/${libdir}"
		cp -a "${scratch}/usr/${libdir}/." "${STAGE}/usr/${libdir}/"
		rm -rf "${STAGE}/usr/${libdir}/pkgconfig"
		touch "${STAGE}/.bundled-wayland"
	fi

	if [[ "${own_workdir}" -eq 1 ]]
	then
		rm -rf "${workdir}"
	fi

	pkg-config --modversion wlroots-0.19
}

main "$@"
