# Watch and connectivity contract

`Shared/Connectivity/SessionTransferService.swift` is included in both app targets. It imports ShuttlXCore, WatchConnectivity, CryptoKit, Observation and Foundation.

`@MainActor @Observable final class SessionTransferService`:
- `init()`, `activate()`, `retryPendingTransfers()`.
- `onReceiveSession: ((Session) async throws -> Void)?`. iPhone sets this before activation. Callback MUST durably save/deduplicate by session UUID before returning. Acknowledgements are emitted only after it succeeds; throwing retains incoming chunks for retry.
- `configure(settings: TrackingSettings, layout: WatchLayout) throws`. Sends durable latest applicationContext; settings/layout received on watch are persisted and applied at next session, avoiding changes mid-swing.
- `onConfigurationReceived: ((TrackingSettings, WatchLayout) -> Void)?`.
- `settings: TrackingSettings`, `layout: WatchLayout` (read-only observable).
- `isPaired`, `isAppInstalled`, `isReachable`: Bool. Reachable means immediate-message reachability, not whether background transfer is possible.
- `deviceStatus: WatchDeviceStatus?` with `modelName: String`, `systemVersion: String`, `batteryLevel: Double?` (0...1), `motionAvailable: Bool`, `requestedSampleRateHz: Double?`, `measuredSampleRateHz: Double?`, `trackingStatus: String`, `reportedAt: Date`.
- `modelName: String?`, `batteryLevel: Double?`, `trackingStatus: String` convenience read-only properties.
- `lastError: String?`, `syncState: String`, `pendingTransferCount: Int`.
- `enqueue(_ session: Session) async throws`; durable outbox before scheduling transfer.
- `publishStatus(_ status: WatchDeviceStatus) throws` on Watch.

Motion update frequency is a request, not a hardware guarantee. Core Motion does not enumerate supported rates. The watch reports delivered timestamp frequency; UI must not invent a supported 200 Hz/max list. Automatic defaults to a conservative 50 Hz request. When configuring numeric rates, label them requested and show measured frequency separately.

Transport protocol v1 splits sessions into bounded JSON file chunks, hashes each chunk and the full session with SHA-256, and persists sender outbox/receiver inbox. Resends use the same transfer ID. Receivers retain partial groups until complete and persist receipt/session-digest identity before ack; conflicting session UUID content is rejected. Durable `transferUserInfo` acknowledgements remove only verified sender outbox entries. Apple may defer transfer delivery; there is no fake progress percentage.

## Targets and entitlements

- Watch app: `NSMotionUsageDescription`; `NSHealthShareUsageDescription`; `NSHealthUpdateUsageDescription`; `WKBackgroundModes = [workout-processing]`; `com.apple.developer.healthkit = true`.
- Watch app + watch WidgetKit extension: App Group `group.com.shuttlx.app` (replace consistently with the signed team's group if needed).
- Widget extension sources include `Shared/Connectivity/WatchWidgetSnapshot.swift` only, not the WCSession service.
- Watch app bundle companion ID should match iPhone bundle; URL scheme `shuttlx` supports widget launch.

HealthKit badminton workout session supports background sensor continuation. App sessions are saved locally regardless of phone connectivity. A failed capture is paused and recoverable; confirmed End saves the session and stages sync. No device sensor data is synthesized. Developer dataset recordings are separate labelled real-motion files and never feed production statistics.

## Verification boundary

Source written on Windows: no Apple SDK compiler or Watch simulator is available. Test the paired physical watch with wrist down, phone disconnected, pause/resume, app termination/recovery, denied HealthKit/motion permissions, duplicate/reordered/missing chunks and retried persistence before release.

Official API references:
- https://developer.apple.com/documentation/healthkit/running-workout-sessions
- https://developer.apple.com/documentation/coremotion/cmmotionmanager/devicemotionupdateinterval
- https://developer.apple.com/documentation/watchconnectivity/wcsessionfile/fileurl
- https://developer.apple.com/documentation/watchconnectivity/wcsession

The Watch UI includes preset selection and dedicated five-second labelled dataset capture. Received dataset JSON is accepted by MotionRecording.decode and is never inserted into personal sessions. Layout changes on Watch use a durable layout message to update the phone. Acknowledged Watch recovery archives are removed; interrupted cleanup is retried when enqueue sees its durable receipt. Raw retention settings apply to the phone, while pending Watch transfers are retained until delivery.
