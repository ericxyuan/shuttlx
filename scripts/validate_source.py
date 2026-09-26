"""Static source/resource checks. Does NOT compile Swift or validate Apple SDK APIs."""
import hashlib
import json
import plistlib
import re
import sys
import os
from datetime import datetime, timezone
from pathlib import Path
import xml.etree.ElementTree as ET
import tree_sitter_swift
from tree_sitter import Language, Parser
from PIL import Image
import yaml
from openstep_parser import OpenStepDecoder
from generate_project import collect_sources, uid

ROOT = Path(__file__).resolve().parents[1]

def native_files(pattern):
    # The web application has its own type checks, tests and dependency tree.
    for directory, folders, files in os.walk(ROOT):
        folders[:] = [name for name in folders if name not in {"web", ".build", ".git", "node_modules"}]
        for name in files:
            file = Path(directory) / name
            if file.match(pattern):
                yield file

def main():
    errors = []
    parser = Parser(Language(tree_sitter_swift.language()))
    swift_files = sorted(native_files("*.swift"))
    swift_files = [p for p in swift_files if ".build" not in p.parts]
    for file in swift_files:
        tree = parser.parse(file.read_bytes())
        stack = [tree.root_node]
        while stack:
            node = stack.pop()
            if node.type == "ERROR" or node.is_missing:
                errors.append(f"{file.relative_to(ROOT)}:{node.start_point.row + 1}: Swift parser {node.type}")
            stack.extend(node.children)
    for file in native_files("*.json"):
        try:
            json.loads(file.read_text(encoding="utf-8-sig"))
        except Exception as exc:
            errors.append(f"{file.relative_to(ROOT)}: {exc}")
    for extension in ["*.plist", "*.entitlements", "*.xcprivacy"]:
        for file in native_files(extension):
            try:
                plistlib.loads(file.read_bytes())
            except Exception as exc:
                errors.append(f"{file.relative_to(ROOT)}: {exc}")
    for file in native_files("*.xcstrings"):
        try:
            value = json.loads(file.read_text(encoding="utf-8"))
            assert value["sourceLanguage"] == "en" and value["version"] == "1.0"
        except Exception as exc:
            errors.append(f"{file.relative_to(ROOT)}: {exc}")
    digest = hashlib.sha256((ROOT / "master-icon.png").read_bytes()).hexdigest()
    with Image.open(ROOT / "master-icon.png") as icon:
        if icon.size != (1024, 1024) or icon.mode != "RGB":
            errors.append("Master icon must be an opaque 1024 × 1024 RGB image.")
    for target in ["ShuttlX", "ShuttlXWatch"]:
        assets = ROOT / target / "Assets.xcassets"
        for child in assets.iterdir():
            if child.is_dir() and child.suffix not in {".appiconset", ".colorset", ".imageset", ".dataset"}:
                errors.append(f"{target}: unexpected asset directory {child.name}")
        path = ROOT / target / "Assets.xcassets/AppIcon.appiconset/master-icon.png"
        if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            errors.append(f"{target}: app icon differs from supplied master.")
    spec = yaml.safe_load((ROOT / "project.yml").read_text(encoding="utf-8"))
    project = (ROOT / "ShuttlX.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    with (ROOT / "ShuttlX.xcodeproj/project.pbxproj").open(encoding="utf-8") as stream:
        parsed_project = OpenStepDecoder.ParseFromFile(stream)
    if parsed_project["objects"][parsed_project["rootObject"]]["isa"] != "PBXProject":
        errors.append("Generated project has no valid PBXProject root.")
    defined = set(re.findall(r'"([0-9A-F]{24})"\s*=\s*\{', project))
    referenced = set(re.findall(r'"([0-9A-F]{24})"', project))
    if referenced - defined:
        errors.append("Unresolved Xcode object IDs: " + ", ".join(sorted(referenced - defined)))
    coverage = {}
    for target, config in spec["targets"].items():
        files = collect_sources(config)
        coverage[target] = {"swift": sum(v == "sources" for v in files.values()), "resources": sum(v == "resources" for v in files.values())}
        source_text = "\n".join((ROOT / p).read_text(encoding="utf-8") for p, phase in files.items() if phase == "sources")
        if len(re.findall(r"@main\b", source_text)) != 1:
            errors.append(f"{target}: expected exactly one @main entrypoint")
        for path in files:
            if json.dumps(path) not in project:
                errors.append(f"{target}: source omitted from generated project: {path}")
        for key in ["INFOPLIST_FILE", "CODE_SIGN_ENTITLEMENTS"]:
            if not (ROOT / config["settings"]["base"][key]).is_file():
                errors.append(f"{target}: missing {key}")
    for file in native_files("*.xcscheme"):
        tree = ET.parse(file)
        for reference in tree.findall(".//BuildableReference"):
            if reference.attrib["BlueprintIdentifier"] not in defined:
                errors.append(f"{file.name}: invalid scheme reference")
    watch = plistlib.loads((ROOT / "ShuttlXWatch/Info.plist").read_bytes())
    if watch.get("WKApplication") is not True or watch.get("WKCompanionAppBundleIdentifier") != "com.shuttlx.app":
        errors.append("Modern Watch target metadata is invalid.")
    catalogue = json.loads((ROOT / "Resources/catalogue-development.json").read_text(encoding="utf-8-sig"))
    for collection in ["brands", "products", "variants", "colorways", "images"]:
        rows = catalogue[collection]
        if len({row["id"] for row in rows}) != len(rows):
            errors.append(f"Duplicate {collection} IDs")
    result = {
        "checkedAt": datetime.now(timezone.utc).isoformat(), "passed": not errors,
        "swiftSyntaxFiles": len(swift_files), "targetCoverage": coverage, "masterIconSHA256": digest,
        "errors": errors,
        "notPerformed": ["Swift type checking", "Swift package test execution", "Xcode build", "Simulator visual/accessibility verification", "Paired device capture/transfer tests"]
    }
    output = ROOT / "docs/validation-report.json"
    output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    return 1 if errors else 0

if __name__ == "__main__":
    sys.exit(main())
