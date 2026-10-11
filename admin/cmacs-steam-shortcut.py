#!/usr/bin/env python3
# cmacs-steam-shortcut.py -- add "Emacs VR" to the Steam library.
#
# Copyright (C) 2026 Zach Podbielniak
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Adds (or updates) a non-Steam shortcut that starts cmacs in a VR headset
# (`emacs --lrg=3dvr'), in the home directory, marked as a VR app so it
# shows in the SteamVR library and gets the scene focus when launched.
#
#   ~/bin/export/emacs-vr    the launcher Steam runs.  It calls the emacs
#                            `just distrobox' exported to ~/bin/export; it
#                            drops Steam's LD_PRELOAD / LD_LIBRARY_PATH (they
#                            would be forwarded into the box, where they
#                            name the host's Steam runtime) and logs to
#                            ~/.local/state/cmacs/emacs-vr.log (the
#                            previous run's is kept as emacs-vr.log.1).
#   userdata/*/config/shortcuts.vdf
#                            the shortcut, for every Steam user on the
#                            machine; the previous file is kept as
#                            shortcuts.vdf.cmacs-bak.
#
# Steam reads shortcuts.vdf at startup, so a running Steam shows the entry
# after a restart (--restart-steam does it; in a gamescope session Steam
# comes straight back).  Rerunning is safe: the entry is matched by name
# and updated in place.
#
# shortcuts.vdf is Steam's *binary* KeyValues format: a tree of
#   0x00 name\0 <children> 0x08    (map)
#   0x01 name\0 value\0            (string)
#   0x02 name\0 <int32 le>         (int)
# closed by a final 0x08.

import argparse
import binascii
import os
import shutil
import struct
import subprocess
import sys

APP_NAME = "Emacs VR"

T_MAP, T_STR, T_INT, T_FLOAT, T_PTR, T_WSTR, T_COLOR, T_U64, T_END = (
    0, 1, 2, 3, 4, 5, 6, 7, 8)


# ------------------------------------------------------------ binary VDF --

class VdfError(Exception):
    pass


def _cstr(data, i):
    end = data.index(b"\0", i)
    return data[i:end].decode("utf-8", "surrogateescape"), end + 1


def _read_map(data, i):
    """Parse map entries starting at I until T_END; return (list, next_i).
    A list of (type, key, value) keeps order and unknown types intact."""
    out = []
    while True:
        if i >= len(data):
            raise VdfError("truncated file")
        t = data[i]
        i += 1
        if t == T_END:
            return out, i
        key, i = _cstr(data, i)
        if t == T_MAP:
            val, i = _read_map(data, i)
        elif t == T_STR:
            val, i = _cstr(data, i)
        elif t in (T_INT, T_FLOAT, T_PTR, T_COLOR):
            val, i = data[i:i + 4], i + 4
        elif t == T_U64:
            val, i = data[i:i + 8], i + 8
        else:
            raise VdfError(f"unknown field type {t} at {i - 1}")
        out.append((t, key, val))


def read_vdf(data):
    if not data:
        return [(T_MAP, "shortcuts", [])]
    tree, i = _read_map(data, 0)
    return tree


def _write_map(entries, out):
    for t, key, val in entries:
        out.append(bytes([t]))
        out.append(key.encode("utf-8", "surrogateescape") + b"\0")
        if t == T_MAP:
            _write_map(val, out)
            out.append(bytes([T_END]))
        elif t == T_STR:
            out.append(val.encode("utf-8", "surrogateescape") + b"\0")
        elif t == T_INT and isinstance(val, int):
            out.append(struct.pack("<i", val))
        else:
            out.append(val)


def write_vdf(tree):
    out = []
    _write_map(tree, out)
    out.append(bytes([T_END]))
    return b"".join(out)


def get(entries, key):
    for t, k, v in entries:
        if k.lower() == key.lower():
            return t, v
    return None, None


# ------------------------------------------------------------- shortcut --

def shortcut_appid(exe, name):
    """Steam's id for a non-Steam shortcut (also names its grid artwork)."""
    return (binascii.crc32((exe + name).encode("utf-8")) & 0xFFFFFFFF) | 0x80000000


def make_entry(exe, start_dir, icon, appid):
    signed = appid - (1 << 32) if appid >= (1 << 31) else appid
    return [
        (T_INT, "appid", signed),
        (T_STR, "appname", APP_NAME),
        (T_STR, "Exe", f'"{exe}"'),
        (T_STR, "StartDir", f'"{start_dir}"'),
        (T_STR, "icon", icon),
        (T_STR, "ShortcutPath", ""),
        (T_STR, "LaunchOptions", ""),
        (T_INT, "IsHidden", 0),
        (T_INT, "AllowDesktopConfig", 1),
        (T_INT, "AllowOverlay", 0),
        (T_INT, "OpenVR", 1),
        (T_INT, "Devkit", 0),
        (T_STR, "DevkitGameID", ""),
        (T_INT, "DevkitOverrideAppID", 0),
        (T_INT, "LastPlayTime", 0),
        (T_STR, "FlatpakAppID", ""),
        (T_MAP, "tags", [(T_STR, "0", "cmacs")]),
    ]


def upsert(tree, entry):
    """Insert ENTRY into the shortcuts map, replacing one named APP_NAME.
    Returns 'added' or 'updated'."""
    t, shortcuts = get(tree, "shortcuts")
    if t != T_MAP:
        shortcuts = []
        tree[:] = [(T_MAP, "shortcuts", shortcuts)]
    for n, (_, key, val) in enumerate(shortcuts):
        _, name = get(val, "appname")
        if name == APP_NAME:
            # Keep play time and user-set fields we do not manage.
            _, last = get(val, "LastPlayTime")
            if last is not None:
                entry = [(ty, k, last if k == "LastPlayTime" else v)
                         for ty, k, v in entry]
            shortcuts[n] = (T_MAP, key, entry)
            return "updated"
    index = 0
    used = {k for _, k, _ in shortcuts}
    while str(index) in used:
        index += 1
    shortcuts.append((T_MAP, str(index), entry))
    return "added"


# ------------------------------------------------------------- launcher --

LAUNCHER = """#!/usr/bin/env bash
# Emacs VR -- cmacs in a VR headset (emacs --lrg=3dvr).
# Written by `just steam-vr-shortcut' (admin/cmacs-steam-shortcut.py); Steam
# runs it from its "Emacs VR" library entry.  Edits here are overwritten.

# Start in the home directory, whatever Steam's working directory is.
cd "${{HOME}}" || exit 1

# Steam injects its overlay and runtime libraries; distrobox would forward
# both into the box, where they name the host's Steam runtime.
unset LD_PRELOAD LD_LIBRARY_PATH

# One log per run; the previous run's is kept as .1.
log="${{XDG_STATE_HOME:-${{HOME}}/.local/state}}/cmacs/emacs-vr.log"
mkdir -p "$(dirname "${{log}}")"
[ -f "${{log}}" ] && mv -f "${{log}}" "${{log}}.1"
{{
    echo "=== $(date -Is) emacs-vr $*"
    echo "DISPLAY=${{DISPLAY:-}} WAYLAND_DISPLAY=${{WAYLAND_DISPLAY:-}}"
}} >"${{log}}"

exec "{emacs}" --lrg=3dvr "$@" >>"${{log}}" 2>&1
"""


def steam_root():
    for p in ("~/.local/share/Steam", "~/.steam/steam", "~/.steam/root",
              "~/.var/app/com.valvesoftware.Steam/.local/share/Steam"):
        p = os.path.realpath(os.path.expanduser(p))
        if os.path.isdir(os.path.join(p, "userdata")):
            return p
    return None


def steam_users(root):
    users = []
    for name in sorted(os.listdir(os.path.join(root, "userdata"))):
        if name.isdigit() and name != "0":
            users.append(os.path.join(root, "userdata", name))
    return users


def install_icon(repo, dest_dir):
    for size in ("128x128", "48x48", "32x32"):
        src = os.path.join(repo, "etc/images/icons/hicolor", size,
                           "apps/emacs.png")
        if os.path.isfile(src):
            os.makedirs(dest_dir, exist_ok=True)
            dest = os.path.join(dest_dir, "emacs-vr.png")
            shutil.copyfile(src, dest)
            return dest
    return ""


def steam_running():
    return subprocess.run(["pgrep", "-x", "steam"], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def main():
    home = os.path.expanduser("~")
    repo = os.path.realpath(os.path.join(os.path.dirname(__file__), ".."))
    ap = argparse.ArgumentParser(
        description='Add an "Emacs VR" entry (emacs --lrg=3dvr) to the Steam library.')
    ap.add_argument("--export-path", default=os.path.join(home, "bin/export"),
                    help="where `just distrobox' exported emacs (default ~/bin/export)")
    ap.add_argument("--start-dir", default=home,
                    help="working directory Emacs starts in (default: home)")
    ap.add_argument("--restart-steam", action="store_true",
                    help="restart Steam so the entry shows up now")
    ap.add_argument("--remove", action="store_true",
                    help="remove the entry (and the launcher) instead")
    ap.add_argument("--dry-run", action="store_true",
                    help="show what would change; write nothing")
    args = ap.parse_args()

    export = os.path.realpath(os.path.expanduser(args.export_path))
    emacs = os.path.join(export, "emacs")
    launcher = os.path.join(export, "emacs-vr")

    if not args.remove and not os.access(emacs, os.X_OK):
        sys.exit(f"{emacs} not found -- run `just distrobox 44' first "
                 "(it exports emacs there)")

    root = steam_root()
    if root is None:
        sys.exit("no Steam installation found (looked for */userdata)")
    users = steam_users(root)
    if not users:
        sys.exit(f"no Steam users under {root}/userdata -- log in to Steam once")

    icon = ""
    if not args.remove:
        if args.dry_run:
            print(f"would write {launcher}")
        else:
            os.makedirs(export, exist_ok=True)
            with open(launcher, "w") as fh:
                fh.write(LAUNCHER.format(emacs=emacs))
            os.chmod(launcher, 0o755)
            icon = install_icon(repo, os.path.join(home, ".local/share/icons/cmacs"))
            print(f"launcher: {launcher}")

    appid = shortcut_appid(f'"{launcher}"', APP_NAME)
    for user in users:
        cfg = os.path.join(user, "config")
        path = os.path.join(cfg, "shortcuts.vdf")
        data = b""
        if os.path.exists(path):
            with open(path, "rb") as fh:
                data = fh.read()
        try:
            tree = read_vdf(data)
        except (VdfError, ValueError) as e:
            print(f"{path}: cannot parse ({e}); leaving it alone", file=sys.stderr)
            continue

        if args.remove:
            t, shortcuts = get(tree, "shortcuts")
            before = len(shortcuts or [])
            if t == T_MAP:
                shortcuts[:] = [s for s in shortcuts
                                if get(s[2], "appname")[1] != APP_NAME]
            what = "removed" if len(shortcuts or []) != before else "absent"
        else:
            what = upsert(tree, make_entry(launcher, args.start_dir, icon, appid))

        if args.dry_run:
            print(f"{path}: would be {what} (appid {appid})")
            continue
        if what == "absent":
            print(f"{path}: no {APP_NAME} entry")
            continue
        os.makedirs(cfg, exist_ok=True)
        if data:
            shutil.copyfile(path, path + ".cmacs-bak")
        tmp = path + ".cmacs-tmp"
        with open(tmp, "wb") as fh:
            fh.write(write_vdf(tree))
        os.replace(tmp, path)
        print(f"{path}: {APP_NAME} {what} (appid {appid}, starts in {args.start_dir})")

    if args.remove and not args.dry_run and os.path.exists(launcher):
        os.unlink(launcher)

    if args.dry_run:
        return
    if steam_running():
        if args.restart_steam:
            print("restarting Steam ...")
            subprocess.run(["steam", "-shutdown"], check=False)
        else:
            print("Steam is running: it reads shortcuts at startup, so restart it "
                  "(or rerun with --restart-steam) to see the entry.")


if __name__ == "__main__":
    main()
