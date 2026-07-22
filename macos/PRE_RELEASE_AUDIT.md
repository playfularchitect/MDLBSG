# App 91 focused audit

## Evidence from the App 90 failure package

The exact installed menu bundle was present, validly ad-hoc signed, and launched
as process `.../MDLBSG Menu.app/Contents/MacOS/applet`. Five seconds after direct
launch it was still alive while Terminal remained frontmost. The user then saw
AppleScript error `-1700`.

The decisive evidence is execution order:

- `launcher-v90 started` is the first log operation after entering the menu's
  `run` body.
- The diagnostic produced no new launch-log entry.
- The decompiled app declared `on run argv`.

Therefore the failure happened before the first statement in the handler, while
the applet's parameterless launch event was being bound to the command-line
`argv` direct parameter.

The same evidence package reported the main Compressor bundle as version 86 and
its decompiled body contained only the App 86 marker. App 90 had installed its
menu helper but had not completed the final Compressor replacement.

## App 91 repair boundary

App 91 changes the compiled menu app from `on run argv` to parameterless
`on run`.

It also changes the installer and verifier to:

- reject `on run argv` in source;
- compile and decompile the menu;
- require parameterless `on run` in the compiled body;
- execute the compiled bundle through Launch Services using the non-UI
  request/proof path;
- install and require Compressor bundle version 91;
- require menu bundle version 91;
- verify both local signatures.

## Intentionally unchanged

- App 88 queue submitter and worker
- Queue ordering and locking
- Compression cores and model settings
- Command wrapper and cache behavior
- Progress window and results helper
- Droplet and extraction handlers
- Archive formats and extraction algorithms
- App 90 native menu layout and cache controls

## Validation limit

This environment cannot compile or display macOS AppleScript app bundles. The
package can prove shell/Python syntax, exact protected-file hashes, queue
self-tests, cache behavior, C/C++ compilation, package integrity, and the source
handler contract. The Mac installer performs AppleScript compilation,
decompilation, plist, Launch Services, bundle-version, and signature checks.
The repeated visible-open test remains the final behavioral proof.
