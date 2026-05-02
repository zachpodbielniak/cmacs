#!/usr/bin/env bash
# build-aux/android-repack.sh — repackage upstream's known-working
# Emacs Android APK with our Doom bundle injected.  Sidesteps the
# whole cross-compile path: takes Po Lu's prebuilt APK from
# SourceForge, drops `assets/doom-bundle/' + `assets/lisp/site-start.el'
# into it, strips signing metadata, re-zips, zipaligns, resigns
# with the upstream `emacs.keystore' (same key as Po Lu's build, so
# installs cleanly over an existing upstream install).
#
# Why this exists: a stock Emacs APK built from current source on
# our toolchain crashes on Samsung Fold 5 with a FORTIFY abort in
# libhwui.so's BSS mutex; upstream's prebuilt APK doesn't.  We
# couldn't isolate the build-env divergence, so we ship upstream's
# binary verbatim and only inject the Doom bundle that needs to
# travel with the APK.
#
# Runs inside the Containerfile.android image — needs apksigner
# (build-tools), zipalign (build-tools), curl, unzip, zip.
#
# Bind mounts (set up by `just android-repack'):
#
#   /work/cmacs           ← $PWD on the host (RW; for emacs.keystore)
#   /work/doom-core       ← $HOME/.config/emacs (RO)
#   /work/doom-private    ← $HOME/.config/doom  (RO)
#   /work/out             ← $PWD/build/android-out (RW)
#   /work/upstream-cache  ← $PWD/build/upstream-apk-cache (RW)

set -euo pipefail

SRC=/work/cmacs
OUT=/work/out
CACHE=/work/upstream-cache
DOOM_CORE_SRC=/work/doom-core
DOOM_PRIVATE_SRC=/work/doom-private

# Upstream URL and filename — pinned to API 35 aarch64 build.
UPSTREAM_APK_NAME=${UPSTREAM_APK_NAME:-emacs-31.0.50-35-arm64-v8a.apk}
UPSTREAM_APK_URL=${UPSTREAM_APK_URL:-https://sourceforge.net/projects/android-ports-for-gnu-emacs/files/${UPSTREAM_APK_NAME}/download}

# --------------------------------------------------------- preflight
mkdir -p "$CACHE" "$OUT"
KEYSTORE="$SRC/java/emacs.keystore"
test -f "$KEYSTORE" || { echo "missing $KEYSTORE" >&2; exit 2; }

UPSTREAM="$CACHE/$UPSTREAM_APK_NAME"
if [ ! -s "$UPSTREAM" ]; then
  echo "==> downloading upstream APK to $UPSTREAM"
  curl -fsSL --retry 5 --retry-delay 4 --retry-all-errors \
       -o "$UPSTREAM" "$UPSTREAM_APK_URL"
fi
echo "    upstream APK: $(du -h "$UPSTREAM" | cut -f1)  $(sha256sum "$UPSTREAM" | cut -c1-12)"

# ------------------------------------------------------- staging dirs
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
echo "==> unzipping into $WORK/"
unzip -q "$UPSTREAM" -d "$WORK"

# ------------------------------------------------------- doom bundle
echo "==> injecting Doom bundle"
mkdir -p "$WORK/assets/doom-bundle/emacs" "$WORK/assets/doom-bundle/doom"

if [ -d "$DOOM_CORE_SRC" ] && [ "$(ls -A "$DOOM_CORE_SRC" 2>/dev/null)" ]; then
  rsync -a \
    --exclude='/.local' --exclude='/eln-cache' --exclude='/straight' \
    --exclude='/server' --exclude='.git' --exclude='*~' \
    "$DOOM_CORE_SRC/" "$WORK/assets/doom-bundle/emacs/"
  echo "    doom core:    $(du -sh "$WORK/assets/doom-bundle/emacs"    | cut -f1)"
else
  echo "    doom core:    (empty mount — skipping)"
  rmdir "$WORK/assets/doom-bundle/emacs" 2>/dev/null || true
fi

if [ -d "$DOOM_PRIVATE_SRC" ] && [ "$(ls -A "$DOOM_PRIVATE_SRC" 2>/dev/null)" ]; then
  rsync -a --exclude='.git' --exclude='*~' \
    "$DOOM_PRIVATE_SRC/" "$WORK/assets/doom-bundle/doom/"
  echo "    doom private: $(du -sh "$WORK/assets/doom-bundle/doom"     | cut -f1)"
else
  echo "    doom private: (empty mount — skipping)"
  rmdir "$WORK/assets/doom-bundle/doom" 2>/dev/null || true
fi

# ------------------------------------------------------- site-start
# Inject our shim that copies the Doom bundle into HOME on first
# launch.  Source-only — Emacs's byte-compiler will produce the
# .elc on demand.
if [ -f "$SRC/lisp/site-start.el" ]; then
  cp "$SRC/lisp/site-start.el" "$WORK/assets/lisp/site-start.el"
  echo "    site-start.el: copied from cmacs source"
fi

# --------------------------------------------- regenerate directory-tree
#
# Android Emacs's VFS reads `assets/directory-tree' (a packed binary
# manifest produced by `lib-src/asset-directory-tool') to know which
# files exist under /assets.  Adding files to the APK without
# updating this manifest renders them invisible to `file-exists-p'
# even though `locate-library' may still find them via load-path
# directory scans — which is exactly the symptom we hit when our
# site-start.el and doom-bundle/ went unseeded.
#
# Use the prebuilt host binary at lib-src/asset-directory-tool when
# present (built during any prior `just android-build').  If absent,
# compile a standalone copy on the fly — the source has minimal
# external dependencies (just <byteswap.h>, <dirent.h>, etc) and
# doesn't truly need config.h despite the #include.
TOOL=$SRC/lib-src/asset-directory-tool
if [ ! -x "$TOOL" ]; then
  echo "==> compiling asset-directory-tool"
  STUB=$(mktemp -d)
  : > "$STUB/config.h"
  TOOL=$(mktemp)
  gcc -O2 -I"$STUB" -DASSET_DIRECTORY_TOOL_STANDALONE \
      -o "$TOOL" "$SRC/lib-src/asset-directory-tool.c" 2>&1 \
    | grep -vE 'config\.h|undefined symbol' || true
  rm -rf "$STUB"
  test -x "$TOOL" || { echo "asset-directory-tool build failed" >&2; exit 2; }
fi

echo "==> regenerating assets/directory-tree"
rm -f "$WORK/assets/directory-tree"
"$TOOL" "$WORK/assets" "$WORK/assets/directory-tree"
echo "    new tree: $(stat -c %s "$WORK/assets/directory-tree") bytes"

# -------------------------------------------------- strip signing meta
# Removing META-INF/ drops upstream's existing v1 (jarsigner) sigs.
# `apksigner sign' below replaces them.  v2/v3 sigs sit in the apk's
# trailer rather than META-INF; apksigner overwrites those too.
echo "==> stripping signing metadata"
rm -rf "$WORK/META-INF"

# ------------------------------------------------------------ re-zip
#
# Android API 30+ requires resources.arsc to be STORED (uncompressed)
# and 4-byte aligned, otherwise installPackageLI rejects with
# "Targeting R+ requires resources.arsc … uncompressed".  Two-pass
# zip: store resources.arsc raw, deflate everything else.  Same
# constraint applies to native .so libs in modern AGP, so store
# them too — saves runtime extraction.
echo "==> re-zipping"
UNALIGNED="$OUT/repacked.unaligned.apk"
rm -f "$UNALIGNED"
(
  cd "$WORK"
  # Pass 1: deflate everything EXCEPT resources.arsc and lib/**/*.so
  zip -qr "$UNALIGNED" . \
      -x resources.arsc 'lib/*/*.so'
  # Pass 2: store (uncompressed) resources.arsc + native libs
  if [ -f resources.arsc ]; then
    zip -q -0 "$UNALIGNED" resources.arsc
  fi
  # shellcheck disable=SC2046
  if compgen -G 'lib/*/*.so' >/dev/null; then
    zip -q -0 "$UNALIGNED" $(find lib -name '*.so' -type f)
  fi
)

# ----------------------------------------------------------- align
echo "==> zipalign"
ALIGNED="$OUT/repacked.aligned.apk"
rm -f "$ALIGNED"
zipalign -f -p 4 "$UNALIGNED" "$ALIGNED"

# ------------------------------------------------------------ sign
echo "==> apksigner sign"
SIGNED="$OUT/$UPSTREAM_APK_NAME"
apksigner sign \
  --ks "$KEYSTORE" \
  --ks-pass pass:emacs1 \
  --key-pass pass:emacs1 \
  --v2-signing-enabled \
  --debuggable-apk-permitted \
  --out "$SIGNED" \
  "$ALIGNED"

rm -f "$UNALIGNED" "$ALIGNED"

# ------------------------------------------------------------ done
echo
echo "==> done.  APK:"
ls -lh "$SIGNED"
echo "    sha256: $(sha256sum "$SIGNED" | cut -c1-32)..."
echo "    contents check (Doom + site-start):"
unzip -l "$SIGNED" | grep -E "doom-bundle|site-start" | head -8 || \
  echo "    (no Doom additions found — was the bundle staged?)"
