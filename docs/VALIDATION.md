# Validation and device acceptance

The source was continued on Windows. The validation-report.json file records
the actual local checks and lists checks that were not performed.
No IPA, simulator screenshot, physical capture, or Apple compilation is claimed.

## Local checks

Use PowerShell, working directory C:\Users\admin\iCloudDrive\ShuttlX:

    python -m pip install --user -r scripts/requirements.txt
    python scripts/prepare_resources.py
    python scripts/generate_project.py
    python scripts/validate_source.py

The checker parses Swift syntax with tree-sitter (not the Swift compiler),
parses the generated OpenStep project with an independent parser, resolves project
object and scheme references, checks target source membership and one entrypoint
per target, parses property lists/JSON/string catalogues, checks catalogue IDs,
and verifies both app icons are byte-identical to the supplied master. It returns
a nonzero exit code on failure. It cannot establish Apple API correctness,
Swift type correctness, macro expansion, code signing, or UI layout quality.

The project.yml manifest is the editable project definition. The portable
generator supports the subset used here; rerun it whenever files/targets change.
The generated project is included so opening it does not require XcodeGen.
XcodeGen is an alternative on Mac, not an additional required generation step.

## Mac checks, not yet run

In Terminal on a Mac, change to the copied ShuttlX project directory.
Select Xcode 26 or newer and install its iOS and watchOS simulator platforms:

    bash scripts/verify_mac.sh

This runs the core XCTest suite, production transport actor tests, and both generic simulator builds. It stops at
the first failure. A GitHub Actions workflow is also included, but no repository
was published and no remote workflow was run during Windows development.
The selected runner must have Xcode 26+; the script checks this.

Core tests exercise complete pulses, acceleration-only movement, isolated spikes,
sustained movement, refractory suppression, incomplete windows, invalid timestamps,
bounded buffers, measured sample rate, timestamp integration, opt-in classification,
calibration, raw-data omission, rally boundaries, unknown coverage, record
progression, rolling seven-day counts, period filtering and validation. Their
sensor traces are synthetic and are not classifier-accuracy evidence.

The transport test harness copies the actual production actor byte-for-byte into
a temporary local Swift package under .build. It covers more-than-ten-part reverse
delivery, incomplete/duplicate chunks, malformed-packet isolation, conflicting
identities, durable acknowledgement, and stable dataset digests despite JSON
formatting changes. These tests need Apple's CryptoKit/Foundation toolchain and
have been authored but not executed on this Windows host.

The September 23 reliability pass also adds a sensor-callback watchdog, validates
replay label bounds and ordering, keeps healthy saved sessions visible if another
stored row is unreadable, and aligns widget tactical percentages with Analysis.
Malformed incoming files are isolated; ordinary storage errors keep their files
in place for retry. Neither failure path sends a persistence acknowledgement.

Both icon directories were found renamed to AppIconiconset.app. Copies of those
folders are preserved in docs/recovered-assets; the correct AppIcon.appiconset
directories were regenerated from the unchanged master.

## Paired-device acceptance, not yet run

1. Configure a unique signing team/bundle IDs and the shared App Group consistently.
   Install both apps on a paired iPhone and physical Apple Watch.
2. Fresh launch: Analysis is empty, all six sections are directly available, no
   fake session, record, sensor rate or connection is shown.
3. Grant/deny Health and Motion independently. A failure must explain why tracking
   is unavailable and preserve existing data.
4. Start real badminton capture with Watch on the racket wrist. Test wrist-down
   continuation, phone disconnected, pause/resume, end/save and reconnect.
5. Terminate capture. Reopen; a checkpoint must offer paused recovery without
   inventing strokes across the interruption. Check duration and restored settings.
6. Verify partial/reordered/duplicate transfers, storage-write failure, interruption
   between phone save and receipt, and repeated acknowledgement. One session must
   appear exactly once. Only durable phone acknowledgement removes Watch recovery
   archives. Pending transfers remain on Watch while disconnected.
7. Confirm raw retention, export and deletion. Retention applies to iPhone sensor
   windows; unsynced Watch sessions remain for safe delivery. Independently collected
   developer datasets are separate documents, not personal sessions.
8. Test Watch presets/custom layout, sampling requests, haptics, auto-pause and
   explicit resume. Measure the actual delivered sensor rate.
9. Replay an exported Watch dataset with positive labels and negative activities.
   Confirm these results never enter personal statistics.
10. Inspect smallest-phone/landscape layouts, light/dark mode, accessibility text
    sizes, VoiceOver, Reduce Motion, Reduce Transparency, keyboard, sheets and links.
11. Validate PhotosPicker, camera denial, crop/reposition, cancel/save, equipment
    replacement and dated history. Product images need sourced usage permission.
12. Test phone widgets and all three Watch accessory families before/after capture.
    Widgets are OS-refreshed snapshots, not guaranteed live displays.

## Remaining product validation

- No trained, independently validated badminton classifier or calibrated player
  speed model is bundled. Default classifications remain unknown. Optional rules
  support only some shot envelopes and are explicitly experimental.
- Wrist motion cannot establish tactical intent, landing accuracy or match outcome.
  Corresponding dimensions remain unavailable.
- The catalogue is a small manufacturer-sourced development dataset, not the
  complete worldwide catalogue requested in the brief. No licensed product
  photography is bundled.
- Simulator inspection, runtime performance/battery profiling and labelled
  real-world detector evaluation remain required before release.
- English is the source language. A string catalogue and extraction setting are
  present; complete localization extraction needs the Apple build.

Privacy metadata declares local preferences/App Group access and elapsed timing,
following [Apple's required-reason categories](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
Watch metadata uses [Apple's modern single app target](https://developer.apple.com/documentation/watchos-apps/migrating-to-a-single-target-watchos-app).
