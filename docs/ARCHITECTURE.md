# ShuttlX implementation architecture

ShuttlX is a native iPhone and Apple Watch application. The first launch is empty and opens Analysis. Production never seeds example sessions or invents a connected Watch, player, equipment, sensor measurement, or classification.

## Targets and boundaries

- **ShuttlX**: iOS 18+, SwiftUI, SwiftData, Charts, PhotosUI. Six independently retained navigation stacks in a floating bottom control. Xcode 26+ builds use native Liquid Glass on iOS 26; older OS versions use native system material.
- **ShuttlXWatch**: watchOS 11+, Core Motion, HealthKit workout lifetime, local durable session capture, WatchConnectivity outbox. Capture is independent of the phone.
- **ShuttlXWidgets**: Home Screen analysis and record widgets, an App Group snapshot and deep links.
- **ShuttlXWatchWidgets**: accessory widgets for complications and Smart Stack, reading real local snapshot data.
- **ShuttlXCore**: portable Foundation package. Serializable sensor/session/settings models, bounded detection, classifier protocol, replay, raw statistics, explainable analysis, rally inference, consistency, computed records.

## Data flow

Core Motion user acceleration (g) and rotation (rad/s) → serial bounded detector → swing window → features → classifier → durable Watch session → versioned, integrity-checked transfer → iPhone SwiftData transaction → acknowledgement → analytics and widget snapshot.

The receiver acknowledges persistence, not mere delivery. IDs make retries idempotent. Raw retention affects sensor windows, not summary values. Estimated swing speed requires calibration; it is never shuttle speed. Wrist sensors alone do not establish shot placement, winning shots, opponent contacts, rally outcomes or tactical intent.

## Navigation and interaction

Statistics, Analysis, Records, Watch, Profile, Settings are always directly reachable. There is no More tab. Analysis is the normal launch selection; deep links override it. Native sheets and menus own focus and dismissal. All stacks stay mounted, while inactive stacks are excluded from hit testing and accessibility. At accessibility text sizes the navigation becomes two rows of three labeled buttons.

Fluidity's local component guidance was consulted before implementation: selection-and-integration, design foundations, Watermelon compact selectors/record detail/chart composition, extension glass/stack contracts and the shared motion policy. These supply behavior and hierarchy. The implementation is original SwiftUI, using native Apple controls and materials rather than importing the plugin's React or CSS adapters. Crisp content cards are structural; glass is reserved for navigation and interaction.

## Validation boundary

This source is authored on Windows. Source/manifest checks can run here; Apple platform compilation, simulator rendering, HealthKit behavior, background motion continuity and paired-device transfers require a Mac with Xcode 26+ and real Apple hardware. The repository contains reproducible build/check commands and a physical-device acceptance plan. Do not equate source implementation or synthetic regression fixtures with hardware validation or validated shot-classification accuracy.
