# ShuttlX

Native SwiftUI iPhone and Apple Watch badminton motion analytics. The six primary
sections are Statistics, Analysis, Records, Watch, Profile and Settings; Analysis
is the normal launch destination.

**Current state:** source implementation and Windows static checks. Apple builds,
Swift test execution, simulator appearance and physical Watch behaviour have not
yet been verified. This is not a compiled or release-ready app.

The repository also contains a full web companion in [`web/`](web/). It mirrors
the native sections and stores completed Watch summaries per signed-in Apple
account. A standalone Watch can connect directly over HTTPS: the Watch displays
a time-limited QR code, the iPhone app scans it, and the browser completes Sign
in with Apple before the credential is sent back to the Watch.

The web companion is a Cloudflare Worker/Vinext application backed by D1. GitHub
stores the source; GitHub Pages is not used for the account API. See
[`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) for the Apple credentials, D1
migration, custom-domain and DNS steps.

The published website is [ShuttlX](https://shuttlx.ericxyuan.chatgpt.site).
The Watch's default Website Sync address uses this same origin. Apple sign-in
still requires the Apple Developer credentials described in the deployment guide.

## Open the project later on Mac

The [interactive interface review](docs/design/index.html) shows the phone,
Watch and widget design direction, with light/dark and empty/populated states.
Its example values are confined to the board. See the
[UI implementation notes](docs/design/UI-DIRECTION.md) for native mappings and
the remaining Apple-device checks.

Open **ShuttlX.xcodeproj** in Xcode 26 or newer. The project contains four targets:
the iPhone app, single-target Watch app, iPhone widgets and Watch widgets.
The Foundation-only ShuttlXCore package is local; there are no remote app package
dependencies. Minimum OS versions are iOS 18 and watchOS 11. Native Liquid Glass
is gated to OS 26; earlier systems use system material.

Choose your signing team, register suitable bundle identifiers and replace
the development App Group group.com.shuttlx.app consistently if needed.
Install iOS/watchOS simulator platforms, then run the verification script from
Terminal in the copied project directory:

    bash scripts/verify_mac.sh

Physical capture needs a paired Apple Watch worn on the racket wrist.
The supplied master-icon.png is copied unchanged into both app asset catalogues.
It is an opaque 1024 × 1024 RGB image; static checks verify matching hashes.

## Implemented source

- Watch capture uses real CMDeviceMotion samples on a serial worker with bounded
  windows, conservative swing rejection, delivered-rate measurement, pause/resume,
  checkpoint recovery, badminton workout lifetime and end/save controls.
- Persistent chunked transfers verify packet/full-payload hashes and identities.
  The iPhone acknowledges only after durable storage; duplicate identities do not
  duplicate analytics. Acknowledged Watch recovery archives are removed.
- Analysis includes period/session selection, explainable radar dimensions,
  classification coverage, speed points at real dates, consistency, inferred
  rallies and navigable shot sensor charts. Missing metrics stay unavailable.
- Statistics retain unknown events. Records include progression, previous best,
  improvement and a link to the source session/stroke.
- Profile editing supports PhotosPicker, camera, crop/reposition, optional player
  measurements, equipment catalogue search, explicit variant/color choices and
  dated equipment history. New sessions can link to equipment active at their
  recorded start date; this is a profile-based association, not sensor detection.
- Settings cover tracking requests, calibration parameters, confidence, retention,
  units and appearance. Developer tools replay imported traces and export separate
  labelled Watch datasets without adding fake personal sessions.
- App Group widget snapshots have explicit empty states. Native shortcuts and
  widget links open the matching section. The navigation retains each stack.
- UI behaviour is adapted from consulted Fluidity guidance to native SwiftUI,
  using native Liquid Glass/materials rather than web components.
- Website Sync uses one-time QR claims (`/pair` and `/api/device/qr/claim`),
  device bearer tokens stored in the Watch Keychain, and account-scoped D1
  rows. The old website pairing-code screen is no longer part of the web UI.

## Accuracy and scope

The app detects candidate swings. No validated learned classifier or full player
calibration workflow is bundled. Default classifications remain Unknown;
experimental classification must be enabled explicitly. Speed is an optional
angular-motion estimate, never shuttle speed. Rallies group only this player's
detected strokes. Tactical intent, placement and outcomes are not inferred.

The catalogue is deliberately small and sourced, not a complete global catalogue.
Product images require verified usage permission and are not fabricated.

## Development checks

Use PowerShell in C:\Users\admin\iCloudDrive\ShuttlX:

    python scripts/validate_source.py

For a fresh machine install the versions in scripts/requirements.txt. If files
or resources change, run scripts/prepare_resources.py and
scripts/generate_project.py before validation. The project.yml file remains the
editable manifest and can alternatively be processed with XcodeGen on Mac.

See [validation and device acceptance](docs/VALIDATION.md),
[latest static report](docs/validation-report.json),
[architecture](docs/ARCHITECTURE.md), [core API](docs/CORE_API.md),
[Watch transport contract](docs/WATCH_API.md) and [catalogue notes](docs/CATALOGUE.md).
