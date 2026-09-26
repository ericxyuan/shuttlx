# ShuttlX interface direction

Updated 24 September 2026. This pass covers native source changes and a browser
review board. It has not been compiled or rendered with Apple's SDKs.

Open [the interactive review board](index.html) in a browser. It works as a local
file and through a local server. All numbers in that board are illustrative;
the installed native app does not seed personal sessions with this data.

## Shared language

- Preserve the supplied master icon. Use its blue family with system backgrounds,
  clear white/dark cards, rounded metric typography and restrained shadows.
- Use native Liquid Glass for phone navigation on iOS 26. Content cards stay
  solid. Earlier systems use system material; Reduce Transparency uses solid
  surfaces. The browser board does not emulate native Liquid Glass.
- Prioritise recorded facts: detected shots, active duration and inferred rallies.
  Show missing estimates explicitly and retain unknown events in totals.
- Use semantic text styles, labelled controls and adaptive metric rows. Device
  tests still need to cover Dynamic Type, VoiceOver and contrast settings.

## Phone

Six direct destinations remain Statistics, Analysis, Records, Watch, Profile and
Settings. Analysis is the launch destination. Each tab retains its navigation
stack; an external link resets its destination stack so it can reveal the target.

Analysis starts with one session summary: large shot count, active time, inferred
rallies and classification coverage. Detail cards follow it. Session history is a
searchable native sheet with date, shot count, active time and a selected indicator.
Empty history searches, an empty time period and an app with no sessions have
different messages. The first-session action opens Watch setup.

Statistics and record detail retain the existing real-data charts, disclosure
rows and links to the originating session. Profile and Settings use native forms.
The review board shows the proposed hierarchy of all six sections; it is a
representative selection of screens, not an exhaustive reproduction of every
native form or chart.

Primary implementation: ShuttlX/Design/SessionPresentation.swift,
ShuttlX/Design/ShuttlComponents.swift, ShuttlX/Features/AnalyticsViews.swift,
ShuttlX/App/AppNavigation.swift.

## Watch

The ready screen has a single start action. A running session uses a vertical
page layout: primary metric, two optional supporting metrics and pause/resume on
the first page; elapsed time and end/save controls on the second. Saving is a busy
state. End requires confirmation. Finished sessions show a saved summary and
transfer state. Dimming removes the live page's action button and toolbar control.

Existing controller actions handle the real session lifecycle. Display presets
still choose metrics rather than changing detection settings. Widget refreshes
are snapshots scheduled by watchOS, not a guaranteed live stream.

Primary implementation: ShuttlXWatch/WatchRootView.swift.

## Widgets

The phone Analysis widget leads with detected shots. Medium and large families
add active time; available tactical/hand percentages are secondary. Missing
classification cannot erase useful measured session facts. Empty widgets point
to starting on Watch. The personal-best widget keeps its eligibility explanation.

Watch circular accessories emphasise a single value; rectangular accessories
include the brand, count and last recorded detail. Empty accessories avoid
pretending there is an active or saved session.

Snapshots carry optional shot count and duration so older stored snapshots can
still decode. Session identity, date and statistics use the same latest eligible
session. Widget links route to that session, including repeated opens.

Primary implementation: ShuttlXWidgets/ShuttlXWidgets.swift,
ShuttlXWatchWidgets/ShuttlXWatchWidgets.swift,
Shared/Connectivity/PhoneWidgetSnapshot.swift, ShuttlX/App/AppStore.swift.

## Verification and next acceptance

Browser checks exercised all six destinations, light/dark appearance, illustrative
and first-session states, setup navigation and pause/resume. Phone and Watch
compositions were visually inspected in the browser. This verifies the review
board only. Source parsing and project coverage are recorded in
../validation-report.json.

On an Apple host, run scripts/verify_mac.sh, then inspect the smallest supported
phone and Watch sizes, large accessibility text, all widget families, both
appearances and both reduced-motion/transparency settings. Check cold-start and
repeated widget links, deleted-session links, empty history searches, pause/end
confirmation, offline save and delayed phone sync on physical paired devices.

References consulted: [Apple Liquid Glass](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views),
[watchOS design](https://developer.apple.com/design/human-interface-guidelines/designing-for-watchos)
and [Always On](https://developer.apple.com/design/human-interface-guidelines/always-on).
