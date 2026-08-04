# Local-device development branch

This branch is intended for installing Wearwell with the current personal Apple
development team. Wardrobe records and image blobs use local SwiftData storage,
and backup/restore remains available in Settings.

The restricted App Groups, CloudKit, iCloud, push-notification, and background
remote-notification entitlements are disabled here so Xcode can provision and
sign the app for a physical iPhone.

The in-app photo picker, camera import, wardrobe, collages, saved outfits,
wishlist, backups, and Mac companion continue to work. Share Extension handoff
and cloud sync require the `codex/cloud-capabilities` branch plus a paid Apple
Developer Program team with its identifiers and containers configured.
