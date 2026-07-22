# MDLBSG App 91 — Applet Run-Handler Fix RC1

MDLBSG is a lossless compressor that writes `.mdl` archives and restores the
original bytes exactly. App 91 keeps the App 88 single-live-queue behavior and
the App 89 opt-in plaintext cache policy.

## Exact App 90 failure

The App 90 evidence package showed:

- `~/.mdlbsg/MDLBSG Menu.app` launched and remained alive.
- Terminal stayed frontmost.
- Activating the menu app ended the process.
- The user received AppleScript error `-1700`: “Can’t make some data into the
  expected type.”
- No new `launcher-v90 started` line was written, so the menu body failed before
  its first executable statement.
- The installed menu source declared `on run argv`.
- The installed Compressor was still bundle version 86, proving the App 90
  installer had not completed the final Compressor replacement.

The applet was compiled with the command-line `osascript` run-handler shape.
Finder launches a script application with the normal parameterless `run` event.
The app therefore failed while binding the incoming run event to `argv`, before
it could log or display its menu.

## App 91 repair

App 91 makes one runtime correction:

```applescript
on run
```

replaces:

```applescript
on run argv
```

The menu body, cache controls, AppKit alert, mode selection, file/folder
selection, queue, compression cores, and archive behavior are otherwise
preserved.

The installer now rejects any menu source or compiled menu body containing
`on run argv`. It also proves the parameterless handler survives compilation,
launches the compiled menu app through Launch Services, checks the self-test
request, installs the full Compressor as bundle version 91, and verifies both
installed signatures.

## Install on macOS

1. Unzip this package.
2. Open `MDLBSG_App_91_APPLET_RUN_HANDLER_FIX_RC1_2026-07-22`.
3. Double-click `RUN_ME_FIRST.command`.
4. Run `VERIFY_APP91_RELEASE.command` after installation.

Requires macOS and the Xcode command line tools. If `clang` is unavailable, run:

```bash
xcode-select --install
```

This candidate uses local ad-hoc signatures, not Apple Developer ID
notarization. macOS may require right-clicking `RUN_ME_FIRST.command` and
choosing **Open**.

## Opening the app

Opening **MDLBSG Compressor** should display:

- Choose Files
- Choose Folder
- Change Mode
- Cache Settings...
- Quit

The menu shows the current compression mode and cache state. Drag-and-drop
compression uses the same shared live queue.

## Plaintext cache

The cache is explicit opt-in. When OFF, MDLBSG does not create or read hidden
plaintext cache copies. When enabled, regular files up to 1 GB may be stored
under `~/.mdlbsg/cache`; at most three entries are retained with a 6 GB total
cap.

Use **Cache Settings...** in the app menu, or:

```bash
mdlbsg cache status
mdlbsg cache on
mdlbsg cache off
mdlbsg cache clear
```

Disabling the cache stops using it but does not erase older cached copies.
Choose **Clear Copies** or run `mdlbsg cache clear` to delete them.

## Queue behavior retained

- Exactly one queue worker owns compression work.
- Exactly one progress window is shown.
- Later drops append to the active queue.
- Items run sequentially in submission order.
- One combined statistics dialog appears after the queue becomes empty.
- Cancelling stops the current item and clears the remaining queue.

## Applications

**MDLBSG Compressor** compresses files and folders. Drag items onto the app, or
open it and choose them.

**MDLBSG Decompressor** restores `.mdl` archives.

Do not distribute the `.app` bundle by itself. The apps depend on the runtime
installed under `~/.mdlbsg`; distribute this complete installer package.

## Command line

```text
mdlbsg c <file|folder> [output.mdl] [-p fast|turbo|max]
mdlbsg d <archive.mdl> [output]
mdlbsg mode [fast|turbo|max]
mdlbsg cache [status|clear|off|on]
mdlbsg version
mdlbsg help
```

## Logs and proof

- Runtime log: `~/.mdlbsg/launch.log`
- Native menu app: `~/.mdlbsg/MDLBSG Menu.app`
- Installed build information: `~/.mdlbsg/bin/BUILD_INFO_APP91`
- Queue state: `~/.mdlbsg/queue88`
