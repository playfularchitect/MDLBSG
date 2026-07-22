# App 91 validation report

## Evidence used

The App 90 failure package showed that the compiled menu app launched as a live
process, but no `launcher-v90 started` line was written before AppleScript error
`-1700` appeared. The decompiled menu declared `on run argv`. The installed
Compressor still reported bundle version 86, so the App 90 installer had not
completed the final Compressor replacement.

This places the failure before the first statement in the menu handler: the
Finder applet run event did not supply the command-line `argv` direct parameter.

## Validated in this build environment

- Every included shell script passes `bash -n`.
- Every included Python source parses successfully.
- App 88 queue submitter self-test passes.
- App 88 queue worker self-test passes.
- Fresh isolated cache state is OFF.
- `cache on`, `cache off`, and `cache clear` behave as documented.
- The App 91 menu source contains exact parameterless `on run`.
- The broken `on run argv` handler is absent.
- All three C++ compressor cores compile successfully.
- The detached-spawn C helper compiles successfully.
- Queue scripts, compression cores, command wrapper, UI worker, progress body,
  result helper, droplet/extract handlers, and Decompressor source are
  byte-for-byte unchanged from App 90.
- The package contains no generated Python bytecode or Finder metadata.

## Mac-only checks built into the installer and verifier

- Menu AppleScript compilation and decompilation.
- Rejection of `on run argv` before and after compilation.
- Requirement for parameterless `on run` in the compiled menu body.
- Launch Services execution of the compiled menu bundle through the request/proof
  path.
- Compressor AppleScript compilation and decompilation.
- Compressor and menu bundle version 91.
- Unique native-menu bundle identifier and UI-agent setting.
- Local code-signature verification for both bundles.
- Removal of unused privacy metadata.

## Final behavioral gate

1. Complete the App 91 installer and verifier without an error.
2. Confirm the installed Compressor reports bundle version 91.
3. Open the Compressor ten separate times.
4. Close the menu after each open.
5. Confirm the menu appears in front every time.
6. Confirm Cache Settings preserves the selected state.
7. Queue a second file during a large compression.
8. Confirm one progress window and sequential completion.
