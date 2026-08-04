# Wearwell

Wearwell is a private, native iPhone wardrobe with three outfit workflows:

- **Manual Collage** works entirely offline.
- **AI Style** is text-only: it selects confirmed garment IDs, then opens those
  pieces in the manual collage editor with a deterministic low-overlap layout.
- **Should I Buy This?** tests a wishlist candidate against clothes you own.

The iOS app stores the wardrobe and every editable collage locally and mirrors
durable records and images to the user's private iCloud database. Reinstalling
on a device signed into the same iCloud account restores the library. Settings
also supports versioned `.wearwellbackup` export and non-destructive restore.
AI actions are sent
to the paired Mac companion, which reuses the Mac's existing `codex login` and
pins `gpt-5.6-luna`; it never embeds an OpenAI API key.
Codex requests use the `fast` service tier with medium reasoning.

## Run the app

1. Open `Wearwell.xcodeproj` in Xcode 26 or newer.
2. Select the **Wearwell** scheme and an iOS 18+ simulator or device.
3. Build and run. Manual collages work without the companion.

Command-line verification:

```bash
xcodebuild -project Wearwell.xcodeproj -scheme Wearwell \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

## Configure iCloud storage

The project expects the private CloudKit container `iCloud.com.wearwell.app`.
Before running a signed build, the Apple Developer team administrator must add
that container to the `com.wearwell.app` App ID and refresh its provisioning
profile. The checked-in entitlements already enable CloudKit and push delivery.

Run a Debug build once with an iCloud test account and add a sample item so
SwiftData initializes the development schema. Verify its record types in
CloudKit Console, then deploy the development schema to production before an
App Store or TestFlight release. Production CloudKit schemas are additive, so
future model changes must add a new `VersionedSchema` and migration stage.

On first launch after upgrading, Wearwell scans the existing `WearwellAssets`
directory and creates cloud-backed blobs without deleting the legacy files.
Migration status and iCloud account availability appear in Settings.

## Run the Mac companion

```bash
codex login
cd Companion
npm install
npm start
```

Choose **Sign in with ChatGPT** during `codex login`. On first start the helper
prints a six-digit pairing code and advertises `_wearwell._tcp` on the local
network. In Wearwell, open Settings, enter the Mac's local hostname or IP and
the printed code, then pair. The discovered service name is shown as a hint.

The companion uses HTTPS with a generated local certificate. Wearwell pins the
certificate and stores its device token in the iPhone Keychain, limits uploads,
and deletes job uploads after each request. The Mac must be awake and reachable
for AI actions.

Clothing imports are durable background jobs. Wait until an import displays
**Queued — safe to lock**, then the iPhone can be locked or used for something
else while the Mac continues analysis. Wearwell retrieves the result when it is
active again. Two isolated workers analyze photos concurrently without sharing
generated-image output folders. Queued jobs survive a companion restart and
expire from the Mac after 24 hours if they never start; unavailable imports stay
on the phone with a Retry action instead of silently disappearing.

The wardrobe supports second-level types for Tops (long sleeves, tank tops,
T-shirts, sleeveless, blouses), Bottoms (shorts, skirts, pants), Outerwear
(cover-ups, sweaters, jackets, coats), and Accessories (tights, hats, misc).
Luna proposes a type during import and the review and garment-detail screens let
the user correct it before or after saving.

AI outfit composition allows a dress to be layered with one bottom and supports
intentional two-piece torso layering, such as a fitted long sleeve under a tank
or dress. Luna must return explicit `under` and `main`/`over` roles for layered
tops or a top-and-dress pairing. Recommendations still enforce at most one dress,
one bottom, two tops, and two torso pieces total. The Companion prompt and iPhone
validator both apply the rule.

The Inspiration tab accepts saved looks and Pinterest screenshots. Luna analyzes
each image into a fixed, explainable style vector plus reusable traits, outfit
formulas, proportion relationships, focal points, and styling rules. Existing
version-1 inspiration is upgraded once when the Companion is available. The phone
stores those per-look analyses and maintains a versioned aggregate style profile
locally. Adding, deleting, or favoriting a look updates the cache; ordinary outfit
requests do not reanalyze the images. Styling sends the compact profile and at
most four locally selected relevant examples to Luna. Luna first creates six to
eight valid combinations, then a separate critic pass rejects awkward, bland,
physically implausible, or repetitive options and returns the best three.

Each worker processes its own catalog images sequentially so generated images
cannot cross between photos. Garment-analysis turns time out after four minutes and
individual catalog-image turns after five minutes; a failed catalog image falls
back to its source photo instead of blocking the remaining queue.

## Privacy boundary

Wearwell receives only images explicitly selected, captured, pasted, or shared
by the user. Generated catalog and try-on images are approximations, not proof
of fit, drape, opacity, sizing, or garment accuracy.
