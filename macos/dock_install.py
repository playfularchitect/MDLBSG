#!/usr/bin/env python3
"""Put the MDLBSG apps into the Dock correctly, and evict any broken entries.

WHY THIS EXISTS:
The Dock has TWO separate sections, and they behave differently:
  - persistent-apps   (left of the divider)  -> clicking LAUNCHES the app
  - persistent-others (right, near Trash)    -> documents/stacks; clicking an app
                                                dropped here does NOT launch it
An app dragged onto the wrong side looks identical but won't start. On top of that,
every reinstall deletes and recreates the .app, so any Dock entry created earlier
points at a bundle that no longer exists -- it still shows an icon, and clicking it
does nothing at all.

Both failure modes look exactly like "double-click in the Dock does nothing", which
is precisely the reported bug. This script removes every MDLBSG entry from BOTH
sections, then re-adds the apps to persistent-apps with a correct file URL.
"""
import plistlib
import subprocess
import sys
import urllib.parse


def read_dock():
    out = subprocess.run(["defaults", "export", "com.apple.dock", "-"],
                         capture_output=True)
    if out.returncode != 0 or not out.stdout:
        return None
    try:
        return plistlib.loads(out.stdout)
    except Exception:
        return None


def write_dock(pl):
    data = plistlib.dumps(pl)
    res = subprocess.run(["defaults", "import", "com.apple.dock", "-"], input=data)
    return res.returncode == 0


def entry_path(entry):
    """Best-effort extraction of the file path an entry points at."""
    try:
        s = entry["tile-data"]["file-data"]["_CFURLString"]
    except Exception:
        return ""
    if s.startswith("file://"):
        s = urllib.parse.unquote(s[7:])
    return s


def make_entry(app_path):
    url = "file://" + urllib.parse.quote(app_path) + "/"
    return {
        "tile-data": {
            "file-data": {"_CFURLString": url, "_CFURLStringType": 15},
            "file-label": app_path.rstrip("/").split("/")[-1].replace(".app", ""),
            "file-type": 41,
        },
        "tile-type": "file-tile",
    }


def main():
    if len(sys.argv) < 2:
        print("usage: dock_install.py <app path> [<app path> ...]", file=sys.stderr)
        return 1
    apps_to_add = sys.argv[1:]

    pl = read_dock()
    if pl is None:
        print("      (couldn't read the Dock settings; add the apps by dragging them "
              "from Applications to the LEFT side of the Dock divider)")
        return 0

    removed = 0
    for section in ("persistent-apps", "persistent-others"):
        entries = pl.get(section, [])
        kept = []
        for e in entries:
            if "MDLBSG" in entry_path(e):
                removed += 1
            else:
                kept.append(e)
        pl[section] = kept

    # Add to the APPS section -- the only section where clicking launches the app.
    for path in apps_to_add:
        pl.setdefault("persistent-apps", []).append(make_entry(path))

    if not write_dock(pl):
        print("      (couldn't update the Dock settings; drag the apps from "
              "Applications to the LEFT side of the Dock divider)")
        return 0

    print(f"      Dock updated: removed {removed} stale/misplaced entr"
          f"{'y' if removed == 1 else 'ies'}, added {len(apps_to_add)} app"
          f"{'' if len(apps_to_add) == 1 else 's'} to the launch section")
    return 0


if __name__ == "__main__":
    sys.exit(main())
