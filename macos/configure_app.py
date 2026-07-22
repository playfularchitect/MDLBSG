#!/usr/bin/env python3
"""Give an osacompile-built app a proper identity in its Info.plist.

WHY THIS EXISTS (learned the hard way):
osacompile applets ship WITHOUT a unique CFBundleIdentifier. macOS Launch Services
identifies apps by bundle ID -- so two apps sharing (or missing) one are treated as
THE SAME APP. The loser becomes a ghost: generic icon, refuses to launch, no error
message. That is what killed the Compressor every time a second app existed.

Also optionally registers .mdl as a document type this app owns, so double-clicking
a .mdl archive just decompresses it.

Runs BEFORE the bundle is re-signed -- editing a signed bundle invalidates the
signature, and macOS then silently refuses to launch it (a separate bug, same
family of pain).
"""
import plistlib, sys, os, argparse

# osacompile inserts a generic set of privacy-purpose strings into every applet,
# including Camera, Microphone, Contacts, Calendars, Photos, HomeKit, and Siri.
# MDLBSG does not request those services. Leaving the keys in a public build makes
# the bundle claim permissions it does not use, so remove them before signing.
UNUSED_PRIVACY_KEYS = {
    "NSAppleEventsUsageDescription",
    "NSAppleMusicUsageDescription",
    "NSCalendarsUsageDescription",
    "NSCameraUsageDescription",
    "NSContactsUsageDescription",
    "NSHomeKitUsageDescription",
    "NSMicrophoneUsageDescription",
    "NSPhotoLibraryUsageDescription",
    "NSRemindersUsageDescription",
    "NSSiriUsageDescription",
    "NSSystemAdministrationUsageDescription",
}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("app")
    ap.add_argument("bundle_id")
    ap.add_argument("display_name")
    ap.add_argument("--register-mdl", action="store_true")
    ap.add_argument("--bundle-version", default="81")
    ap.add_argument("--agent", action="store_true")
    args = ap.parse_args()

    plist_path = os.path.join(args.app, "Contents", "Info.plist")
    if not os.path.exists(plist_path):
        print(f"  (no Info.plist at {plist_path} -- skipping)", file=sys.stderr)
        return 0

    with open(plist_path, "rb") as f:
        pl = plistlib.load(f)

    # THE FIX: a unique identity per app, so Launch Services never conflates them.
    pl["CFBundleIdentifier"] = args.bundle_id
    pl["CFBundleName"] = args.display_name
    pl["CFBundleDisplayName"] = args.display_name
    pl["CFBundleVersion"] = str(args.bundle_version)
    pl["CFBundleShortVersionString"] = str(args.bundle_version)

    icon_file = pl.get("CFBundleIconFile", "droplet")
    if icon_file.endswith(".icns"):
        icon_file = icon_file[:-5]

    if args.agent:
        pl["LSUIElement"] = True
    else:
        pl.pop("LSUIElement", None)

    if args.register_mdl:
        pl["CFBundleDocumentTypes"] = [{
            "CFBundleTypeName": "MDLBSG Archive",
            "CFBundleTypeRole": "Viewer",
            "CFBundleTypeExtensions": ["mdl"],
            "CFBundleTypeIconFile": icon_file,
            "LSHandlerRank": "Owner",
            "LSItemContentTypes": ["com.mdlbsg.archive"],
        }]
        pl["UTExportedTypeDeclarations"] = [{
            "UTTypeIdentifier": "com.mdlbsg.archive",
            "UTTypeDescription": "MDLBSG Archive",
            "UTTypeIconFile": icon_file,
            "UTTypeConformsTo": ["public.data", "public.archive"],
            "UTTypeTagSpecification": {"public.filename-extension": ["mdl"]},
        }]

    for key in UNUSED_PRIVACY_KEYS:
        pl.pop(key, None)

    with open(plist_path, "wb") as f:
        plistlib.dump(pl, f)

    extra = " (+ owns .mdl files)" if args.register_mdl else ""
    print(f"      identity set: {args.bundle_id}{extra}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
