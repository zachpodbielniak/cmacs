# Print to cmacs

A virtual CUPS printer that delivers print jobs into a running cmacs
instance as annotatable multi-page org documents.  Companion to
`lisp/cmacs/cmacs-print.el` — the backend in this directory only handles
PDF intake and D-Bus handoff; rasterisation, org generation, and the
in-Emacs UX live on the Elisp side.

## Files

| File                              | Purpose                                       |
|-----------------------------------|-----------------------------------------------|
| `cmacs-print`                     | System CUPS backend (POSIX shell, root).      |
| `cmacs-print.ppd`                 | PPD declaring `application/pdf` passthrough.  |
| `install-cmacs-printer.sh`        | System installer.  Auto-redirects to user-mode on immutable systems. |
| `uninstall-cmacs-printer.sh`      | System uninstaller.                           |
| `cmacs-print-handler`             | Per-user IPP handler (POSIX shell).           |
| `cmacs-print.service.in`          | systemd user-unit template.                   |
| `install-cmacs-printer-user.sh`   | Per-user installer.  No sudo, no `/usr` writes. |
| `uninstall-cmacs-printer-user.sh` | Per-user uninstaller.                         |

## Three install modes

### Image-baked (immutablue and downstream OSTree images)

If you're running an image that already includes the cmacs container
layer (immutablue, any ublue/bluefin/bazzite spin that pulls
`quay.io/zachpodbielniak/cmacs`), **you have nothing to install.**
The cmacs Containerfile stages:

- `/usr/lib/cups/backend/cmacs-print` — the CUPS backend
- `/usr/share/cmacs-print/cmacs-print.ppd` — the PPD
- `/usr/libexec/cmacs/cmacs-print-register` — first-boot helper
- `/usr/lib/systemd/system/cmacs-print-register.service` — registers
  the CUPS printer on boot (idempotent)
- `/usr/lib/systemd/user/cmacs-print-drain.{path,service}` — the
  inotify drainer, with `%U` for per-user spool resolution
- `/usr/lib/systemd/{system,user}-preset/50-cmacs-print.preset` —
  enables the registration service system-wide and the drainer for
  every user on first login

`systemctl preset-all` (run during OS build / on first boot) honours
the presets, so a fresh login on immutablue gets `cmacs` in every app's
print dialog without touching `make`.

The two manual modes below are for users running cmacs from source on
non-imaged Linux.



### System mode (mutable Linux — Workstation, traditional Fedora, Debian, Arch, …)

Two commands.  First, the CUPS backend (sudo, system-wide):

```sh
make install-cmacs-printer
# or:
just install-cmacs-printer
# or:
./cmacs/print/install-cmacs-printer.sh
```

The script prompts for `sudo` (CUPS requires root-owned 0700 backends).
On immutable / OSTree systems (Silverblue, Atomic, Bluefin, Bazzite,
Universal Blue, NixOS, generic read-only-rootfs), it detects
`/run/ostree-booted` or a non-writable `/usr` and **redirects you to
the per-user mode below** with a one-line message instead of silently
failing.  Override with `CMACS_PRINT_FORCE_SYSTEM=1` if you've taken
`/usr` writable via `sudo bootc usroverlay` or a layered RPM.

Second, the editor-independent drainer (no sudo, per-user systemd):

```sh
make install-cmacs-print-watcher
```

This installs a systemd user `path` + `service` pair:

- `cmacs-print-drain.path` — kernel-inotify watcher on
  `/tmp/cmacs-print-$UID/`
- `cmacs-print-drain.service` — fires on inotify; runs cmacs in batch
  mode just long enough to call `(cmacs-print-drain-spool)`

This is what makes prints land in your notes directory **without needing
an interactive cmacs running**.  Without it, prints sit in
`/tmp/cmacs-print-$UID/` until you start a cmacs that has
`cmacs-print.el` loaded.  Latency is ~1 second from print to drained
directory.

### Per-user mode (immutable systems, or anyone who'd rather not sudo)

Runs `ippeveprinter` as a per-user systemd service.  The printer
advertises itself via mDNS; `cups-browsed` (running by default on
Fedora Workstation/KDE/Silverblue) discovers it and creates a CUPS
queue named `cmacs` automatically.  Apps see the printer in their
print dialog with no further setup.

```sh
make install-cmacs-printer-user
# or:
just install-cmacs-printer-user
# or:
./cmacs/print/install-cmacs-printer-user.sh
```

No sudo, no `/usr` writes.  The installer:

1. Drops the handler at `~/.local/libexec/cmacs/cmacs-print-handler`.
2. Generates a systemd user unit at
   `~/.config/systemd/user/cmacs-print.service` with absolute paths
   substituted (`@IPPEVE@`, `@HANDLER@`).
3. `systemctl --user enable --now cmacs-print.service`.

If `cups-browsed` is inactive on your system, the script prints the
one-time `sudo systemctl enable --now cups-browsed` command needed to
make discovered printers visible to applications.  That is the *only*
sudo step on any immutable system, and it lives entirely in `/etc/`
(writable on every OSTree variant).

Lifecycle:

```sh
systemctl --user status  cmacs-print.service
systemctl --user stop    cmacs-print.service
systemctl --user start   cmacs-print.service
journalctl  --user -u    cmacs-print.service -f
```

### Which one do I have?

Run `make check-cmacs-printer`.  It reports both modes' state plus
detects whether your `/usr` is immutable.

Verify:

```sh
lpstat -p cmacs                                # should print "idle"
lp -d cmacs /tmp/test.pdf                      # should land in cmacs
```

## How it works (system mode)

1. User prints to `cmacs` from any application.
2. CUPS hands the PDF to `/usr/lib/cups/backend/cmacs-print` on stdin.
3. The backend (running as `cupsd_t` under root):
   - sanitises the username and title;
   - atomically writes the PDF to
     `/tmp/cmacs-print-<uid>/<TS>-job<ID>-<title>.pdf`
     (staging via `.tmp.<...>.pdf` then `mv` so the watcher never sees
     a partial file);
   - exits 0.
4. **That's it.**  The backend doesn't talk to cmacs.

Cmacs (when `cmacs-print.el` is loaded) `file-notify`-watches
`/tmp/cmacs-print-$UID/` and runs `cmacs-print-import-pdf` for each
new file.  This avoids three SELinux dead ends in stock Fedora policy
(all silently denied by `dontaudit` rules):

- `cupsd_t` writing to `user_tmp_t` (= `/run/user/$UID/`)
- `cupsd_t` writing to `user_home_t` (= the user's home dir)
- `cupsd_t` running `su` / `runuser` to transition to the user

`/tmp/` is `tmp_t`, which `cupsd_t` can manage freely; the user can
read it back from their own session.

A periodic `cmacs-print-poll-interval` drain (default 30 s) is the
belt-and-suspenders fallback for daemon mode without any attached
frame, where `file-notify` events can lag.

**If cmacs isn't running when you print**, the PDF sits in
`/tmp/cmacs-print-$UID/` until cmacs starts; the load-time drain
picks it up then.  `/tmp` survives until reboot, so anything queued
before reboot is lost — re-print if needed.

## Troubleshooting

**Nothing happens when I print.**  Check:

```sh
make check-cmacs-printer
```

- `lpstat -p cmacs` reports state — anything other than "idle" is a
  CUPS-side problem (jobs paused, daemon not running).
- `pdftocairo`, `pdfinfo`, `gdbus` must all be on `$PATH`.  Install
  `poppler-utils` (Fedora/Debian/Arch) and `glib2` / `libglib2.0-bin`.
- `gdbus introspect --session --dest=org.cmacs.Editor1
  --object-path=/org/cmacs/Editor` should list `Eval`, `FindFile`, etc.
  If it doesn't, cmacs isn't running with `--with-cmacs-glib`.

**Prints are silently lost when my desktop is locked.**  CUPS can
deliver to the inbox even when no GUI session is active, but D-Bus
session-bus delivery requires a logged-in user.  Run:

```sh
loginctl enable-linger $USER
```

so systemd keeps your user bus alive after logout.

**SELinux denies the backend on Fedora.**  CUPS backends run in the
`cupsd_t` domain.  The backend writes to `/run/user/$UID/` (allowed) and
reads `/run/user/$UID/bus` (allowed).  If you've customised your CUPS
SELinux module, check `journalctl -t setroubleshoot` for AVC denials.

## Uninstall

```sh
make uninstall-cmacs-printer
```

Leaves saved prints in `~/Documents/notes/03_resources/cmacs-print/`
intact.
