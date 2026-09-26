"""Portable deterministic Xcode project emitter for the checked-in project.yml subset.

XcodeGen can regenerate from the same manifest on macOS. This emitter makes a
reviewable .xcodeproj available without pretending an Apple build ran on Windows.
"""
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET
import yaml

ROOT = Path(__file__).resolve().parents[1]

def uid(key):
    return hashlib.sha1(key.encode()).hexdigest()[:24].upper()

def serialize(value, depth=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (depth + 1) + json.dumps(str(k)) + " = " + serialize(v, depth + 1) + ";\n" for k, v in value.items()) + "\t" * depth + "}"
    if isinstance(value, list):
        return "(" + ", ".join(serialize(v, depth) for v in value) + ")"
    if isinstance(value, bool):
        return "YES" if value else "NO"
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value))

def collect_sources(target):
    found = {}
    for source in target["sources"]:
        path = ROOT / source["path"]
        exclusions = set(source.get("excludes", []))
        if not path.exists():
            raise ValueError(f"Missing source {path}")
        candidates = [path] if path.is_file() else sorted(path.rglob("*"))
        for file in candidates:
            relative = file.relative_to(ROOT).as_posix()
            if any(part in exclusions for part in file.relative_to(path if path.is_dir() else path.parent).parts):
                continue
            if any(part.endswith(".xcassets") for part in file.parts[:-1]):
                continue
            if file.suffix not in [".swift", ".xcassets", ".json", ".xcstrings", ".xcprivacy"]:
                continue
            found[relative] = "sources" if file.suffix == ".swift" else "resources"
    return found

def main():
    spec = yaml.safe_load((ROOT / "project.yml").read_text(encoding="utf-8"))
    targets = spec["targets"]
    objects = {}
    def add(key, isa, **fields):
        identifier = uid(key)
        objects[identifier] = {"isa": isa, **fields}
        return identifier
    def configuration_list(key, base):
        configs = []
        for name in ["Debug", "Release"]:
            settings = dict(base)
            settings.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone" if name == "Debug" else "-O",
                             "DEBUG_INFORMATION_FORMAT": "dwarf" if name == "Debug" else "dwarf-with-dsym"})
            if name == "Debug":
                settings.update({"SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) DEBUG", "ENABLE_TESTABILITY": "YES"})
            configs.append(add(key + name, "XCBuildConfiguration", buildSettings=settings, name=name))
        return add(key + "list", "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    package = add("package", "XCLocalSwiftPackageReference", relativePath="Packages/ShuttlXCore")
    groups = []
    product_refs = {}
    for name, target in targets.items():
        ext = target["type"] == "app-extension"
        product_refs[name] = add(name + "product", "PBXFileReference", explicitFileType="wrapper.app-extension" if ext else "wrapper.application",
                                 includeInIndex=0, path=name + (".appex" if ext else ".app"), sourceTree="BUILT_PRODUCTS_DIR")
    for name, target in targets.items():
        builds = {"sources": [], "resources": [], "frameworks": []}
        refs = []
        for path, phase in collect_sources(target).items():
            suffix = Path(path).suffix
            file_type = {".swift": "sourcecode.swift", ".xcassets": "folder.assetcatalog", ".xcstrings": "text.json.xcstrings",
                         ".xcprivacy": "text.xml", ".json": "text.json"}[suffix]
            ref = add("file:" + path, "PBXFileReference", lastKnownFileType=file_type, path=path, sourceTree="SOURCE_ROOT")
            refs.append(ref)
            builds[phase].append(add(name + ":" + path, "PBXBuildFile", fileRef=ref))
        for path in [target["settings"]["base"]["INFOPLIST_FILE"], target["settings"]["base"]["CODE_SIGN_ENTITLEMENTS"]]:
            refs.append(add("file:" + path, "PBXFileReference", lastKnownFileType="text.plist.xml", path=path, sourceTree="SOURCE_ROOT"))
        groups.append(add(name + "group", "PBXGroup", children=refs, name=name, sourceTree="<group>"))
        package_products = []
        dependencies = []
        embed_extensions = []
        embed_watch = []
        for dependency in target.get("dependencies", []):
            if "package" in dependency:
                product = add(name + "packageProduct", "XCSwiftPackageProductDependency", package=package, productName="ShuttlXCore")
                package_products.append(product)
                builds["frameworks"].append(add(name + "linkCore", "PBXBuildFile", productRef=product))
            else:
                child = dependency["target"]
                proxy = add(name + child + "proxy", "PBXContainerItemProxy", containerPortal=uid("project"), proxyType=1,
                            remoteGlobalIDString=uid(child + "target"), remoteInfo=child)
                dependencies.append(add(name + child + "dependency", "PBXTargetDependency", target=uid(child + "target"), targetProxy=proxy))
                build = add(name + child + "embed", "PBXBuildFile", fileRef=product_refs[child], settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
                (embed_watch if targets[child]["platform"] == "watchOS" and target["platform"] == "iOS" else embed_extensions).append(build)
        phases = [add(name + phase, isa, buildActionMask=2147483647, files=builds[phase], runOnlyForDeploymentPostprocessing=0)
                  for phase, isa in [("sources", "PBXSourcesBuildPhase"), ("frameworks", "PBXFrameworksBuildPhase"), ("resources", "PBXResourcesBuildPhase")]]
        if embed_extensions:
            phases.append(add(name + "embedExtensions", "PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="", dstSubfolderSpec=13,
                              files=embed_extensions, name="Embed App Extensions", runOnlyForDeploymentPostprocessing=0))
        if embed_watch:
            phases.append(add(name + "embedWatch", "PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="$(CONTENTS_FOLDER_PATH)/Watch", dstSubfolderSpec=16,
                              files=embed_watch, name="Embed Watch Content", runOnlyForDeploymentPostprocessing=0))
        settings = dict(spec["settings"]["base"])
        settings.update(target["settings"]["base"])
        watch = target["platform"] == "watchOS"
        settings.update({"PRODUCT_NAME": "$(TARGET_NAME)", "SDKROOT": "watchos" if watch else "iphoneos",
                         "SUPPORTED_PLATFORMS": "watchos watchsimulator" if watch else "iphoneos iphonesimulator",
                         "WATCHOS_DEPLOYMENT_TARGET" if watch else "IPHONEOS_DEPLOYMENT_TARGET": target["deploymentTarget"],
                         "GENERATE_INFOPLIST_FILE": "NO",
                         "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks" + (" @executable_path/../../Frameworks" if target["type"] == "app-extension" else "")})
        add(name + "target", "PBXNativeTarget", buildConfigurationList=configuration_list(name, settings), buildPhases=phases,
            buildRules=[], dependencies=dependencies, name=name, packageProductDependencies=package_products,
            productName=name, productReference=product_refs[name],
            productType="com.apple.product-type.app-extension" if target["type"] == "app-extension" else "com.apple.product-type.application")
    products = add("products", "PBXGroup", children=list(product_refs.values()), name="Products", sourceTree="<group>")
    main_group = add("mainGroup", "PBXGroup", children=groups + [products], sourceTree="<group>")
    add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "2600"},
        buildConfigurationList=configuration_list("project", {"CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
                                                             "SWIFT_VERSION": "5.0", "ENABLE_USER_SCRIPT_SANDBOXING": "YES"}),
        compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "Base"],
        mainGroup=main_group, productRefGroup=products, packageReferences=[package], projectDirPath="", projectRoot="",
        targets=[uid(name + "target") for name in targets])
    project = ROOT / "ShuttlX.xcodeproj"
    project.mkdir(exist_ok=True)
    document = {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": uid("project")}
    (project / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(document) + "\n", encoding="utf-8")
    workspace = project / "project.xcworkspace"
    workspace.mkdir(exist_ok=True)
    (workspace / "contents.xcworkspacedata").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="self:"/></Workspace>\n', encoding="utf-8")
    schemes = project / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    for name in spec["schemes"]:
        scheme = ET.Element("Scheme", LastUpgradeVersion="2600", version="1.3")
        action = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
        entries = ET.SubElement(action, "BuildActionEntries")
        entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES", buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES")
        attrs = dict(BuildableIdentifier="primary", BlueprintIdentifier=uid(name + "target"), BuildableName=name + ".app",
                     BlueprintName=name, ReferencedContainer="container:ShuttlX.xcodeproj")
        ET.SubElement(entry, "BuildableReference", **attrs)
        launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                               selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0", useCustomWorkingDirectory="NO",
                               ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES", allowLocationSimulation="YES")
        runnable = ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0")
        ET.SubElement(runnable, "BuildableReference", **attrs)
        ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
        ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
        ET.indent(scheme)
        ET.ElementTree(scheme).write(schemes / (name + ".xcscheme"), encoding="utf-8", xml_declaration=True)
    print(f"Generated ShuttlX.xcodeproj: {len(targets)} native targets, {len(objects)} objects.")

if __name__ == "__main__":
    main()
