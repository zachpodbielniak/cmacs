#!/usr/bin/env bash
# cmacs-distrobox.sh -- build cmacs for another distro inside a
# distrobox and install it there as that box's system emacs.
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The distrobox counterpart of ./build-container: the same targets, the
# same base images, the same build steps -- but instead of a scratch
# image to unpack somewhere else, the result is installed into /usr of a
# long-lived box named after its target:
#
#   44      ->  cmacs-fedora-44     registry.fedoraproject.org/fedora:44
#   24.04   ->  cmacs-ubuntu-24.04  docker.io/library/ubuntu:24.04
#   arch    ->  cmacs-arch          docker.io/library/archlinux:latest
#
# so `emacs' inside the box is that distro's cmacs.  Use it to reproduce
# a distro-specific build failure, or to run cmacs against a distro's
# library versions without building an image.
#
# ── Where it builds ──────────────────────────────────────────────────
#
# Not in the checkout itself.  The build is in-tree, so building there
# would overwrite the host's objects with ones linked against another
# distro's libraries (and two boxes would fight over the same tree).
# Each box gets its own copy at build/distrobox/<box>/ instead, which
# distrobox can see because it shares $HOME.
#
# The copy holds the TRACKED files of the superproject and every
# checked-out submodule, plus untracked-but-not-ignored files at the top
# (so a new file you have not committed yet still builds).  Never build
# artifacts: a host .o, .d or .pc in the copy is the same leak
# .containerignore exists to stop -- a .d naming a header this distro
# lacks, a .pc carrying the host's link line.  rsync -a keeps source
# mtimes, so a rerun rewrites only what changed and the box's make is
# incremental.  Files that disappear from the source list are removed
# from the copy, so a deleted or renamed source cannot linger.
#
# ── Resuming ─────────────────────────────────────────────────────────
#
# Every step is safe to rerun, so a box interrupted anywhere -- mid
# package install, mid dep build, mid configure, mid install -- is
# resumed by running the same command again:
#
#   * packages are skipped while a stamp records the package lists this
#     box already installed (a change to install-deps redoes them);
#   * the Wayland stack is probed with pkg-config before it is built;
#   * deps and cmacs are `make', which is incremental by construction;
#   * configure reruns only when its flags or configure itself changed;
#   * the install stages into a fresh DESTDIR and copies, and prunes
#     files the previous install had and this one does not -- a renamed
#     .so must not linger, for the reason install-from-container keeps a
#     manifest.
#
# ── Environment ──────────────────────────────────────────────────────
#
# The box build runs under `env -i' with a plain system PATH.  distrobox
# otherwise forwards the host environment, and a host PATH or
# PKG_CONFIG_PATH reaching into linuxbrew, nix or ~/.local makes
# configure find the HOST's libraries -- which link, and then fail on a
# machine that is not this one.
#
# Not installed, deliberately: the wayland session file, the CUPS
# printer and its systemd units, and the D-Bus activation file.  All
# three are read by host daemons that never look inside a box.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
SRC_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null && pwd)"

TARGET=""
JOBS=""
DRY_RUN=0
INSIDE=0
FORCE_PACKAGES=0
ENTER_AFTER=0

# Filled by resolve_target.
BASE_IMAGE=""
DISTRO=""
RELEASE=""
BOX=""

# Bump when the "basics" in install_packages change, so existing boxes
# pick them up on their next run.  install-deps and the Wayland script
# are hashed directly.
PACKAGES_REV=1

# The deps the Containerfile builds and installs into /usr before
# configuring cmacs.  Order matters: ai-glib before podomation and
# libreclaw, which consume it.  Keep in step with the Containerfile.
CMACS_DEPS=(
	deps/mcp-glib
	deps/crispy
	deps/bacon
	deps/gowl
	deps/ai-glib
	deps/podomation
	deps/clawtilla/deps/libreclaw
)

usage () {
	cat <<'EOF'
Usage: admin/cmacs-distrobox.sh [OPTIONS] TARGET

Create (or reuse) a distrobox for TARGET, build cmacs inside it, and
install it into the box's /usr so `emacs' in the box runs that build.

  TARGET            fedora version (42, 43, 44, ...), ubuntu version
                    (24.04, 26.04, ...), or `arch'
  --jobs N          Build parallelism (default: every core).  Native
                    compilation is memory-hungry per job
  --force-packages  Reinstall system packages even if the stamp says
                    this box already has them
  --enter           Open a shell in the box when the install finishes
  --dry-run         Print the box, image and build tree; change nothing
  -h, --help        Show this help
  --license         Show the license

Boxes are named cmacs-<distro>-<version>, or cmacs-arch.  The build
tree is build/distrobox/<box>/ in this checkout.  Rerunning the same
command resumes or updates a box, whatever step it stopped at.

Examples:
  admin/cmacs-distrobox.sh 44           # cmacs-fedora-44
  admin/cmacs-distrobox.sh 24.04        # cmacs-ubuntu-24.04
  admin/cmacs-distrobox.sh arch --jobs 8
  just dbox 44 && distrobox enter cmacs-fedora-44 -- emacs
EOF
}

# log <message...>
#
# One progress line, prefixed with the box so interleaved output from
# two concurrent boxes stays readable.
log () {
	echo "==> [${BOX:-cmacs-distrobox}] $*"
}

# die <message...>
die () {
	echo "ERROR: $*" >&2
	exit 1
}

# resolve_target <target>
#
# Maps the positional argument onto base image, distro family, release
# and box name.  The SAME shape rules as build-container's
# resolve_target -- a word for Arch, MAJOR.MINOR for Ubuntu, a bare
# integer for Fedora -- so a target valid for one is valid for both.
resolve_target () {
	if [[ $# -ne 1 ]]
	then
		echo 'resolve_target() requires 1 positional argument' >&2
		echo 'resolve_target <target>' >&2
		exit 1
	fi

	local target="${1}"

	if [[ "${target}" == "arch" || "${target}" == "archlinux" ]]
	then
		BASE_IMAGE="docker.io/library/archlinux:latest"
		DISTRO="arch"
		RELEASE="rolling"
		BOX="cmacs-arch"
	elif [[ "${target}" =~ ^[0-9]+\.[0-9]+$ ]]
	then
		BASE_IMAGE="docker.io/library/ubuntu:${target}"
		DISTRO="ubuntu"
		RELEASE="${target}"
		BOX="cmacs-ubuntu-${target}"
	elif [[ "${target}" =~ ^[0-9]+$ ]]
	then
		BASE_IMAGE="registry.fedoraproject.org/fedora:${target}"
		DISTRO="fedora"
		RELEASE="${target}"
		BOX="cmacs-fedora-${target}"
	else
		die "unrecognised target '${target}'; expected a Fedora" \
		    "version (44), an Ubuntu version (24.04), or 'arch'"
	fi
}

# ════════════════════════════════════════════════════════════════════
# Host side
# ════════════════════════════════════════════════════════════════════

# box_exists <name>
#
# True when distrobox already knows a container by that exact name.
box_exists () {
	local name="${1}"

	distrobox list --no-color 2>/dev/null \
		| awk -F'|' 'NR > 1 { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2 }' \
		| grep -Fxq -- "${name}"
}

# ensure_box
#
# Create the box on first use; an existing one is reused as-is.  Its
# distro is checked from inside (check_box_matches_target), because a
# box can share the name and not the image.
ensure_box () {
	if box_exists "${BOX}"
	then
		log "distrobox exists; reusing it"
		return
	fi

	log "creating distrobox from ${BASE_IMAGE}"
	distrobox create --yes --name "${BOX}" --image "${BASE_IMAGE}"
}

# ensure_submodules
#
# The copy is made from the checkout's working tree, so deps/ must be
# populated there first.  Serialised with the same lock build-container
# takes: both mutate the shared working tree's submodule config.
ensure_submodules () {
	local lock

	lock="${TMPDIR:-/tmp}/cmacs-submodule-$(id -u).lock"

	if [[ ! -e "${SRC_ROOT}/.git" ]]
	then
		return
	fi

	log "ensuring submodules are initialised"
	if command -v flock >/dev/null 2>&1
	then
		flock "${lock}" "${SRC_ROOT}/admin/cmacs-submodules.sh"
	else
		"${SRC_ROOT}/admin/cmacs-submodules.sh"
	fi
}

# source_list <outfile>
#
# Write the NUL-separated, sorted list of paths to copy: tracked files
# in the superproject and every checked-out submodule, plus top-level
# untracked files that .gitignore does not exclude.  A tracked file
# deleted in the working tree is dropped rather than handed to rsync,
# which would fail the whole transfer on it.
source_list () {
	local out="${1}"
	local path

	{
		git -C "${SRC_ROOT}" ls-files -z --recurse-submodules
		git -C "${SRC_ROOT}" ls-files -z --others --exclude-standard
	} | while IFS= read -r -d '' path
	do
		if [[ -e "${SRC_ROOT}/${path}" || -L "${SRC_ROOT}/${path}" ]]
		then
			printf '%s\0' "${path}"
		fi
	done | sort -z -u > "${out}"
}

# sync_tree <tree>
#
# Bring the box's copy up to date with the checkout.  See "Where it
# builds" in the header for why it is a copy and why sources only.
sync_tree () {
	local tree="${1}"
	local state="${tree}/.dbox"
	local new_list="${state}/sources.list.new"
	local old_list="${state}/sources.list"
	local path

	mkdir -p "${state}"
	log "syncing sources into ${tree#"${SRC_ROOT}"/}"
	source_list "${new_list}"

	rsync -a --from0 --files-from="${new_list}" \
		"${SRC_ROOT}/" "${tree}/"

	# Anything copied last time that is no longer a source goes.  Only
	# paths from our own list are candidates, and only files and
	# symlinks: a directory may hold the box's build artifacts.
	if [[ -f "${old_list}" ]]
	then
		comm -z -23 "${old_list}" "${new_list}" \
			| while IFS= read -r -d '' path
			do
				if [[ -f "${tree}/${path}" || -L "${tree}/${path}" ]]
				then
					echo "    removing stale ${path}"
					rm -f -- "${tree:?}/${path}"
				fi
			done
	fi
	mv -f "${new_list}" "${old_list}"
}

# configure_flags
#
# The canonical flag set is the Justfile's configure_flags -- the one
# list AGENTS.md says every default build enumerates.  `just distrobox'
# exports it; run directly, ask just for it.
configure_flags () {
	if [[ -n "${CMACS_CONFIGURE_FLAGS:-}" ]]
	then
		echo "${CMACS_CONFIGURE_FLAGS}"
		return
	fi
	if command -v just >/dev/null 2>&1
	then
		just --justfile "${SRC_ROOT}/Justfile" --evaluate configure_flags
		return
	fi
	die "CMACS_CONFIGURE_FLAGS is unset and \`just' is not installed" \
	    "to read the Justfile's configure_flags"
}

# run_host
#
# Everything outside the box: create it, copy the tree, then re-run
# this script from the copy inside the box with a scrubbed environment.
run_host () {
	local tree="${SRC_ROOT}/build/distrobox/${BOX}"
	local lock="${tree}.lock"
	local flags

	command -v distrobox >/dev/null 2>&1 || die "distrobox is not installed"
	command -v rsync >/dev/null 2>&1 || die "rsync is not installed"

	if [[ "${DRY_RUN}" -eq 1 ]]
	then
		echo "box:    ${BOX}"
		echo "image:  ${BASE_IMAGE}"
		echo "distro: ${DISTRO} ${RELEASE}"
		echo "tree:   ${tree}"
		if box_exists "${BOX}"
		then
			echo "state:  box exists; would build in it"
		else
			echo "state:  box missing; would create it"
		fi
		return
	fi

	flags="$(configure_flags | tr -s ' \n' ' ' | sed 's/^ //; s/ $//')"
	mkdir -p "${tree}"

	# One build per box at a time.  Two would race on the same tree and
	# the same /usr; different boxes run concurrently just fine.
	exec 9>"${lock}"
	if ! flock -n 9
	then
		die "another build of ${BOX} is running (lock: ${lock})"
	fi

	ensure_box
	ensure_submodules
	sync_tree "${tree}"

	log "building inside the box"
	distrobox enter "${BOX}" -- env -i \
		HOME="${HOME}" \
		USER="${USER:-$(id -un)}" \
		LOGNAME="${LOGNAME:-$(id -un)}" \
		TERM="${TERM:-xterm}" \
		LANG=C.UTF-8 \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
		CMACS_CONFIGURE_FLAGS="${flags}" \
		CMACS_DBOX_JOBS="${JOBS}" \
		CMACS_DBOX_FORCE_PACKAGES="${FORCE_PACKAGES}" \
		bash "${tree}/admin/cmacs-distrobox.sh" --inside "${TARGET}"

	log "done: \`distrobox enter ${BOX} -- emacs' runs this build"
	if [[ "${ENTER_AFTER}" -eq 1 ]]
	then
		exec distrobox enter "${BOX}"
	fi
}

# ════════════════════════════════════════════════════════════════════
# Box side.  Runs as the user, from the copy, with sudo for /usr.
# ════════════════════════════════════════════════════════════════════

# check_box_matches_target
#
# A box created by hand can carry the right name and the wrong image.
# Building Fedora's package list on Ubuntu fails in confusing ways, so
# refuse up front and say what was found.
check_box_matches_target () {
	local id="" id_like="" version_id=""

	[[ -f /run/.containerenv || -f /.dockerenv ]] \
		|| die "--inside must run inside the distrobox, not on the host"

	# shellcheck source=/dev/null
	id="$(. /etc/os-release && echo "${ID:-}")"
	# shellcheck source=/dev/null
	id_like="$(. /etc/os-release && echo "${ID_LIKE:-}")"
	# shellcheck source=/dev/null
	version_id="$(. /etc/os-release && echo "${VERSION_ID:-}")"

	case "${DISTRO}" in
		fedora)
			[[ "${id}" == "fedora" && "${version_id}" == "${RELEASE}" ]] \
				|| die "${BOX} is ${id} ${version_id}, expected fedora ${RELEASE}"
			;;
		ubuntu)
			[[ "${id}" == "ubuntu" && "${version_id}" == "${RELEASE}" ]] \
				|| die "${BOX} is ${id} ${version_id}, expected ubuntu ${RELEASE}"
			;;
		arch)
			[[ "${id}" == "arch" || " ${id_like} " == *" arch "* ]] \
				|| die "${BOX} is ${id} ${version_id}, expected arch"
			;;
	esac
}

# install_packages <state-dir>
#
# System packages: install-deps --system (the host source of truth),
# the few basics a bare image lacks that a workstation already has, and
# the Wayland stack where the distro's is too old.  Stamped with a hash
# of the scripts that decide the lists, so a rerun skips the slow
# per-package probing until one of them changes.
install_packages () {
	local state="${1}"
	local stamp="${state}/packages.stamp"
	local want

	want="$( { echo "${PACKAGES_REV}"; cat install-deps admin/cmacs-build-wayland.sh; } \
		| sha256sum | cut -d' ' -f1)"
	if [[ "${CMACS_DBOX_FORCE_PACKAGES:-0}" != "1" && -f "${stamp}" \
	      && "$(cat "${stamp}")" == "${want}" ]]
	then
		log "system packages: up to date (stamp)"
		return
	fi

	# Basics a bare base image lacks.  curl/git: cad-glib's CMake
	# FetchContent clones Clipper2.  pip: piper-tts.  An Arch box gets a
	# full -Syu first: a bare -S against stale databases is the classic
	# partial upgrade, and install-deps deliberately does not -Syu a
	# workstation.
	log "system packages: basics"
	case "${DISTRO}" in
		fedora)
			sudo dnf install -y git curl which python3-pip
			;;
		ubuntu)
			sudo env DEBIAN_FRONTEND=noninteractive apt-get update
			sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
				--no-install-recommends --no-remove \
				git curl ca-certificates python3-pip python3-venv
			;;
		arch)
			sudo pacman -Syu --noconfirm --needed git curl which python-pip
			;;
	esac

	log "system packages: ./install-deps --system"
	DEBIAN_FRONTEND=noninteractive ./install-deps --system

	log "system packages: Wayland stack"
	./admin/cmacs-build-wayland.sh

	# Report, don't fail: a narrowed feature is install-deps --check's
	# call to explain, and configure will stop on a hard requirement.
	log "system packages: verifying"
	./install-deps --check || true

	echo "${want}" > "${stamp}"
}

# build_deps <jobs>
#
# The Containerfile's three phases, minus the clean: the copy never
# holds host artifacts, so every rerun can be incremental.
#   1. the shared archives (crispy, yaml-glib, mcp-glib) once, serially,
#      so no consumer's sub-make builds them concurrently;
#   2. each dep under -j, then `sudo make install' -- install only copies,
#      because `all' already ran as the user, so nothing root-owned is
#      left in the tree.
# PREFIX=/usr on every phase: a dep's .pc is written by the build, and
# a build without it bakes /usr/local into the installed .pc.
build_deps () {
	local jobs="${1}"
	local tree="${PWD}"
	local dep gir
	local -a canon

	canon=(
		"CRISPY_DIR=${tree}/deps/crispy"
		"YAMLGLIB_DIR=${tree}/deps/yaml-glib"
		"YAML_GLIB_DIR=${tree}/deps/yaml-glib"
		"MCP_GLIB_DIR=${tree}/deps/mcp-glib"
		"BACON_DIR=${tree}/deps/bacon"
		"AI_GLIB_DIR=${tree}/deps/ai-glib"
		"PODOMATION_DIR=${tree}/deps/podomation"
	)

	for dep in deps/yaml-glib "${CMACS_DEPS[@]}"
	do
		[[ -d "${dep}" ]] || die "${dep} is not checked out"
	done

	log "deps: shared archives"
	make -C deps/crispy lib PREFIX=/usr "${canon[@]}"
	make -C deps/yaml-glib lib DEBUG=0 PREFIX=/usr "${canon[@]}"
	make -C deps/mcp-glib PREFIX=/usr "${canon[@]}"

	for dep in "${CMACS_DEPS[@]}"
	do
		gir=""
		case "${dep}" in
			*/ai-glib) gir="GIR=1" ;;
		esac
		log "deps: ${dep}"
		make -C "${dep}" -j"${jobs}" all PREFIX=/usr ${gir:+"${gir}"} "${canon[@]}" \
			|| die "build ${dep}"
		sudo make -C "${dep}" install PREFIX=/usr ${gir:+"${gir}"} "${canon[@]}" \
			|| die "install ${dep}"
	done

	if ! command -v piper >/dev/null 2>&1
	then
		log "deps: piper-tts"
		sudo pip3 install --no-cache-dir piper-tts \
			|| sudo pip3 install --no-cache-dir --break-system-packages piper-tts \
			|| echo "NOTE: piper-tts not installed; cmacs-piper needs it at runtime"
	fi
	sudo ldconfig

	# cad-glib's vendored kernels, serially, before the parallel make:
	# their nested CMake configures fail when racing an oversubscribed
	# -j (see the Containerfile).
	log "deps: cad-glib kernels"
	make -C deps/cad-glib deps
}

# configure_cmacs <state-dir>
#
# autogen when configure is missing or older than configure.ac;
# configure when there is no config.status, the flags changed, or
# configure was regenerated.  Anything else is make's job.
configure_cmacs () {
	local state="${1}"
	local stamp="${state}/configure.stamp"
	local flags="${CMACS_CONFIGURE_FLAGS} --prefix=/usr"
	local -a flag_words

	if [[ ! -x configure || configure.ac -nt configure ]]
	then
		log "autogen"
		./autogen.sh
	fi

	if [[ -f config.status && -f "${stamp}" \
	      && "$(cat "${stamp}")" == "${flags}" \
	      && ! configure -nt config.status ]]
	then
		log "configure: up to date"
		return
	fi

	log "configure ${flags}"
	read -r -a flag_words <<< "${flags}"
	./configure "${flag_words[@]}"
	echo "${flags}" > "${stamp}"
}

# stage_install <stage> <jobs>
#
# `make install' into a fresh DESTDIR as the user -- install is what
# native-compiles the Lisp, and doing that under sudo would leave
# root-owned files in a tree in $HOME -- plus the extras the
# Containerfile stages alongside it.
stage_install () {
	local stage="${1}"
	local jobs="${2}"
	local libdir="" d emacs_version=""

	rm -rf "${stage}"
	mkdir -p "${stage}"

	log "install: staging"
	make -j"${jobs}" install DESTDIR="${stage}"
	make -C tools/cmacs-mcp all PREFIX=/usr
	make -C tools/cmacs-mcp install PREFIX=/usr DESTDIR="${stage}"

	# The libdir is read off the staged tree, as in the Containerfile:
	# lib64 on Fedora/Arch, lib/<triplet> on Ubuntu, and a wrong one is
	# silent -- ldconfig caches a directory that does not exist.
	for d in "${stage}"/usr/lib64/cmacs "${stage}"/usr/lib/*/cmacs "${stage}"/usr/lib/cmacs
	do
		if [[ -d "${d}" ]]
		then
			libdir="${d#"${stage}"}"
			break
		fi
	done
	[[ -n "${libdir}" ]] || die "no staged cmacs libdir found"
	mkdir -p "${stage}/etc/ld.so.conf.d"
	echo "${libdir}" > "${stage}/etc/ld.so.conf.d/cmacs.conf"

	# The interactive Org manual, deps docs included.
	./tools/sync-deps-docs.sh --quiet
	for d in "${stage}"/usr/share/emacs/*/
	do
		if [[ "$(basename "${d}")" != "site-lisp" ]]
		then
			emacs_version="$(basename "${d}")"
			break
		fi
	done
	if [[ -n "${emacs_version}" && -d doc_org ]]
	then
		cp -a doc_org "${stage}/usr/share/emacs/${emacs_version}/doc_org"
	fi

	# Where this /usr came from.  Named distrobox-release, not
	# container-release: install-from-container reads that one, and this
	# install has no manifest of its own for it to prune against.
	mkdir -p "${stage}/usr/share/cmacs"
	{
		echo "distro=${DISTRO}"
		echo "release=${RELEASE}"
		echo "box=${BOX}"
		echo "libdir=${libdir}"
		echo "arch=$(uname -m)"
		echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "version=$(sed -n 's/^AC_INIT(\[GNU Emacs\], *\[\([^]]*\)\].*/\1/p' configure.ac | head -1)"
	} > "${stage}/usr/share/cmacs/distrobox-release"
}

# install_stage <stage> <state-dir>
#
# Copy the stage over / and prune what the previous install had and this
# one does not.  Copy first, prune second: a failure between them leaves
# both versions' files, which still runs, rather than neither.  Only
# files and symlinks from our own manifest are ever deleted.
install_stage () {
	local stage="${1}"
	local state="${2}"
	local manifest="/usr/share/cmacs/distrobox-manifest"
	local new_manifest="${state}/manifest.new"
	local path

	( cd -- "${stage}" >/dev/null && find . \( -type f -o -type l \) -print0 \
		| sed -z 's|^\.||' | sort -z ) > "${new_manifest}"

	# tar rather than cp -a: Arch's /usr/lib64 is a symlink to lib, and
	# cp refuses to merge a staged usr/lib64 DIRECTORY into it ("cannot
	# overwrite non-directory").  --keep-directory-symlink follows it.
	log "install: copying into /"
	tar -C "${stage}" -cf - . \
		| sudo tar -C / -xf - --keep-directory-symlink --no-same-owner

	if [[ -f "${manifest}" ]]
	then
		comm -z -23 "${manifest}" "${new_manifest}" \
			| while IFS= read -r -d '' path
			do
				if [[ "${path}" == /* && ( -f "${path}" || -L "${path}" ) ]]
				then
					echo "    pruning ${path}"
					sudo rm -f -- "${path}"
				fi
			done
	fi
	sudo install -D -m 0644 "${new_manifest}" "${manifest}"
	sudo ldconfig
}

# run_inside
#
# The build proper, run from the box's copy of the tree.
run_inside () {
	local tree="${SRC_ROOT}"
	local state="${tree}/.dbox"
	local jobs="${CMACS_DBOX_JOBS:-}"

	[[ -n "${CMACS_CONFIGURE_FLAGS:-}" ]] \
		|| die "CMACS_CONFIGURE_FLAGS is unset; run via \`just distrobox'"
	if [[ -z "${jobs}" ]]
	then
		jobs="$(nproc)"
	fi

	cd -- "${tree}" >/dev/null
	mkdir -p "${state}"
	check_box_matches_target

	install_packages "${state}"
	build_deps "${jobs}"
	configure_cmacs "${state}"

	log "make -j${jobs}"
	make -j"${jobs}"

	stage_install "${state}/stage" "${jobs}"
	install_stage "${state}/stage" "${state}"

	log "installed: $(command -v emacs) -- $(emacs --version | head -1)"
}

main () {
	while [[ $# -gt 0 ]]
	do
		case "${1}" in
			-h|--help)        usage; exit 0 ;;
			--license)        echo "AGPL-3.0-or-later"; exit 0 ;;
			--jobs)           JOBS="${2:?--jobs needs a number}"; shift ;;
			--force-packages) FORCE_PACKAGES=1 ;;
			--enter)          ENTER_AFTER=1 ;;
			--dry-run)        DRY_RUN=1 ;;
			--inside)         INSIDE=1 ;;
			-*)               usage >&2; die "unknown option ${1}" ;;
			*)
				[[ -z "${TARGET}" ]] || die "one TARGET only (got '${TARGET}' and '${1}')"
				TARGET="${1}"
				;;
		esac
		shift
	done

	if [[ -z "${TARGET}" ]]
	then
		usage >&2
		exit 1
	fi
	if [[ -n "${JOBS}" && ! "${JOBS}" =~ ^[1-9][0-9]*$ ]]
	then
		die "--jobs takes a positive number, not '${JOBS}'"
	fi

	resolve_target "${TARGET}"

	if [[ "${INSIDE}" -eq 1 ]]
	then
		run_inside
	else
		run_host
	fi
}

main "$@"
