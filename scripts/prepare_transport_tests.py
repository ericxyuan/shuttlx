"""Copy the production transport actor into a disposable Swift test package.

No alternate transport implementation is used. Run tests with the Apple
CryptoKit/Foundation toolchain; generating this harness does not execute tests.
"""
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
target = ROOT / ".build/TransportChecks"
(target / "Sources/Transport").mkdir(parents=True, exist_ok=True)
(target / "Tests/TransportTests").mkdir(parents=True, exist_ok=True)
shutil.copyfile(ROOT / "Shared/Connectivity/SessionTransferDisk.swift", target / "Sources/Transport/SessionTransferDisk.swift")
shutil.copyfile(ROOT / "Tests/TransportTests/TransferDiskTests.swift", target / "Tests/TransportTests/TransferDiskTests.swift")
package_path = json.dumps((ROOT / "Packages/ShuttlXCore").as_posix())
(target / "Package.swift").write_text("""// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TransportChecks",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: """ + package_path + """)],
    targets: [
        .target(name: "Transport", dependencies: [.product(name: "ShuttlXCore", package: "ShuttlXCore")]),
        .testTarget(name: "TransportTests", dependencies: ["Transport", .product(name: "ShuttlXCore", package: "ShuttlXCore")])
    ])
""", encoding="utf-8")
print("Prepared isolated tests using an exact copy of the production transport actor.")
