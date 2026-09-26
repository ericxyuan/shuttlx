"""Prepare native metadata and copy the supplied master icon without changing its pixels."""
import json
import plistlib
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def json_file(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

def main():
    for target, platform in [("ShuttlX", "ios"), ("ShuttlXWatch", "watchos")]:
        assets = ROOT / target / "Assets.xcassets"
        icon = assets / "AppIcon.appiconset"
        json_file(assets / "Contents.json", {"info": {"author": "xcode", "version": 1}})
        json_file(icon / "Contents.json", {
            "images": [{"filename": "master-icon.png", "idiom": "universal", "platform": platform, "size": "1024x1024"}],
            "info": {"author": "xcode", "version": 1}
        })
        shutil.copyfile(ROOT / "master-icon.png", icon / "master-icon.png")
        json_file(assets / "AccentColor.colorset" / "Contents.json", {
            "colors": [
                {"idiom": "universal", "color": {"color-space": "srgb", "components": {"red": "0.000", "green": "0.400", "blue": "0.690", "alpha": "1.000"}}},
                {"idiom": "universal", "appearances": [{"appearance": "luminosity", "value": "dark"}],
                 "color": {"color-space": "srgb", "components": {"red": "0.380", "green": "0.770", "blue": "1.000", "alpha": "1.000"}}}
            ], "info": {"author": "xcode", "version": 1}
        })
    for target in ["ShuttlX", "ShuttlXWatch", "ShuttlXWidgets", "ShuttlXWatchWidgets"]:
        widget = "Widgets" in target
        info = {
            "CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)",
            "CFBundleDisplayName": "ShuttlX" if not widget else "ShuttlX Widgets",
            "CFBundleExecutable": "$(EXECUTABLE_NAME)",
            "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "$(PRODUCT_NAME)",
            "CFBundlePackageType": "XPC!" if widget else "APPL",
            "CFBundleShortVersionString": "$(MARKETING_VERSION)",
            "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)"
        }
        if widget:
            info["NSExtension"] = {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}
        elif target == "ShuttlX":
            info.update({
                "LSRequiresIPhoneOS": True, "UILaunchScreen": {},
                "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
                "NSCameraUsageDescription": "Choose to take a player profile photo with your camera.",
                "CFBundleURLTypes": [{"CFBundleTypeRole": "Viewer", "CFBundleURLName": "com.shuttlx.app", "CFBundleURLSchemes": ["shuttlx"]}]
            })
        else:
            info.update({
                "WKApplication": True, "WKCompanionAppBundleIdentifier": "com.shuttlx.app",
                "WKRunsIndependentlyOfCompanionApp": True,
                "WKBackgroundModes": ["workout-processing"],
                "NSMotionUsageDescription": "Record Watch motion during badminton sessions and labelled dataset recordings.",
                "NSHealthShareUsageDescription": "Use a badminton workout session to maintain motion capture while you play.",
                "NSHealthUpdateUsageDescription": "Save your badminton tracking workout to Health."
            })
        (ROOT / target / "Info.plist").write_bytes(plistlib.dumps(info, sort_keys=False))
    strings = ROOT / "Resources/Localizable.xcstrings"
    if not strings.exists():
        json_file(strings, {"sourceLanguage": "en", "strings": {
            key: {"localizations": {"en": {"stringUnit": {"state": "translated", "value": key}}}}
            for key in ["Analysis", "Statistics", "Records", "Watch", "Profile", "Settings", "ShuttlX", "Start session", "Pause", "Resume", "End session"]
        }, "version": "1.0"})
    privacy = {
        "NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [],
        "NSPrivacyCollectedDataTypes": [],
        "NSPrivacyAccessedAPITypes": [
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPITypeReasons": ["CA92.1", "1C8F.1"]},
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategorySystemBootTime", "NSPrivacyAccessedAPITypeReasons": ["35F9.1"]}
        ]
    }
    (ROOT / "Resources/PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(privacy, sort_keys=False))
    print("Prepared four Info.plists, privacy manifest, string catalogue and exact master-icon copies.")

if __name__ == "__main__":
    main()
