# App 91 changes

- Replaced the menu app's invalid Finder-launch handler `on run argv` with
  parameterless `on run`.
- Removed the command-line argument branch from the compiled applet body.
- Kept the request/proof self-test inside the parameterless applet launch.
- Made the installer reject `on run argv` before and after compilation.
- Made the verifier reject `on run argv` in the installed menu app.
- Requires both the Compressor and menu app to report bundle version 91.
- Preserved the native menu UI, opt-in cache policy, queue, compression cores,
  progress/results bodies, and archive behavior.
