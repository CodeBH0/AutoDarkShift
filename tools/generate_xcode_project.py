"""Regenerate the dependency-free Xcode project and shared schemes. Python 3 only.

The checked-in .xcodeproj is ready to open; running this script is optional.
Manual edits to project.pbxproj will be replaced. Signing overrides live in Config/.
"""
from pathlib import Path
import hashlib
import json
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "AutoDarkShift.xcodeproj"
objects = {}


def ident(label):
    return hashlib.sha256(label.encode()).hexdigest()[:24].upper()


def quote(value):
    return json.dumps(value, ensure_ascii=False)


def array(values):
    return "(" + ", ".join(values) + ("," if values else "") + ")"


def add(label, kind, **fields):
    key = ident(label)
    assert key not in objects
    objects[key] = {"isa": kind, **fields}
    return key


def file(path, kind):
    return add("file:" + path, "PBXFileReference", lastKnownFileType=kind,
               path=quote(path), sourceTree="SOURCE_ROOT")


shared = ["Shared/Models.swift", "Shared/ThresholdStateMachine.swift", "Shared/SharedStore.swift",
          "Shared/ServiceContracts.swift", "Shared/MonitorMessageChannel.swift", "Shared/RuntimeStorage.swift",
          "Shared/KeepAliveContracts.swift", "Shared/KeepAliveManager.swift", "Shared/KeepAliveSwitchControl.swift", "Shared/MonitoringReadback.swift", "Shared/MonitorExport.swift"]
monitoring = ["Monitoring/SwitchMonitor.swift", "Monitoring/BoostTraceRecorder.swift", "Monitoring/MonitorControlEndpoint.swift", "Monitoring/LocalMonitoringClient.swift", "Monitoring/MonitoringHostCoordinator.swift"]
platform = ["Platform/ScreenBrightnessSampler.swift", "Platform/LocalModeNotificationSink.swift", "Platform/LoopbackMonitorTransport.swift"]
keepalive = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "KeepAlive").glob("*.swift"))
app = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "App").glob("*.swift"))
tunnel = ["PacketTunnel/PacketTunnelProvider.swift"]
tests = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "Tests").glob("*.swift"))
refs = {path: file(path, "sourcecode.swift") for path in shared + app + tunnel + tests + monitoring + platform + keepalive}
extras = {
    "App": ["App/Info.plist", "App/AutoDarkShift.entitlements"],
    "PacketTunnel": ["PacketTunnel/Info.plist", "PacketTunnel/PacketTunnel.entitlements"],
    "Config": ["Config/Project.xcconfig", "Config/Local.xcconfig.example"],
    "Docs": ["README.md", "docs/DEVICE_ACCEPTANCE.md", "docs/STATIC_VALIDATION.md",
             "docs/ARCHITECTURE.md", "docs/LOG_REPAIR.md", "Package.swift"],
}
for paths in extras.values():
    for path in paths:
        kind = ("text.plist.entitlements" if path.endswith(".entitlements") else
                "text.plist.xml" if path.endswith(".plist") else
                "text.xcconfig" if ".xcconfig" in path else
                "sourcecode.swift" if path.endswith(".swift") else "net.daringfireball.markdown")
        refs[path] = file(path, kind)

products = {}
for name, product_path, kind in [
    ("AutoDarkShift", "AutoDarkShift.app", "wrapper.application"),
    ("PacketTunnel", "PacketTunnel.appex", "wrapper.app-extension"),
    ("AutoDarkShiftCoreTests", "AutoDarkShiftCoreTests.xctest", "wrapper.cfbundle"),
]:
    products[name] = add("product:" + name, "PBXFileReference", explicitFileType=kind,
                         includeInIndex="0", path=quote(product_path), sourceTree="BUILT_PRODUCTS_DIR")

groups = []
for name, paths in [("App", app + extras["App"]), ("PacketTunnel", tunnel + extras["PacketTunnel"]),
                    ("Monitoring", monitoring), ("Platform", platform), ("KeepAlive", keepalive),
                    ("Shared", shared), ("Tests", tests), ("Config", extras["Config"]), ("Docs", extras["Docs"])]:
    groups.append(add("group:" + name, "PBXGroup", children=array([refs[p] for p in paths]),
                      name=quote(name), sourceTree=quote("<group>")))

frameworks = {}
for name in ["Foundation", "SwiftUI", "UIKit", "NetworkExtension", "UserNotifications", "AVKit", "AVFoundation", "CoreLocation"]:
    frameworks[name] = add("framework:" + name, "PBXFileReference", lastKnownFileType="wrapper.framework",
                           name=quote(name + ".framework"), path=quote("System/Library/Frameworks/" + name + ".framework"),
                           sourceTree="SDKROOT")
groups.append(add("group:Frameworks", "PBXGroup", children=array(list(frameworks.values())),
                  name="Frameworks", sourceTree=quote("<group>")))
product_group = add("group:Products", "PBXGroup", children=array(list(products.values())),
                    name="Products", sourceTree=quote("<group>"))
groups.append(product_group)
main_group = add("group:Main", "PBXGroup", children=array(groups), sourceTree=quote("<group>"))


def configuration_list(label, settings, base=None):
    configs = []
    for configuration in ["Debug", "Release"]:
        flags = settings(configuration)
        fields = {"buildSettings": "{ " + " ".join(f"{k} = {v};" for k, v in flags.items()) + " }",
                  "name": configuration}
        if base:
            fields["baseConfigurationReference"] = base
        configs.append(add(f"config:{label}:{configuration}", "XCBuildConfiguration", **fields))
    return add("configs:" + label, "XCConfigurationList", buildConfigurations=array(configs),
               defaultConfigurationIsVisible="0", defaultConfigurationName="Release")


project_configs = configuration_list("Project", lambda c: {
    "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
    "SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": quote("iphoneos iphonesimulator"),
    "TARGETED_DEVICE_FAMILY": quote("1"), "SWIFT_STRICT_CONCURRENCY": "minimal",
    "SWIFT_OPTIMIZATION_LEVEL": quote("-Onone" if c == "Debug" else "-O"),
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": quote("DEBUG $(inherited)" if c == "Debug" else "$(inherited)"),
    "ENABLE_TESTABILITY": "YES" if c == "Debug" else "NO",
    "DEBUG_INFORMATION_FORMAT": quote("dwarf" if c == "Debug" else "dwarf-with-dsym"),
    "ONLY_ACTIVE_ARCH": "YES" if c == "Debug" else "NO",
}, refs["Config/Project.xcconfig"])

project_id = ident("project")
target_ids = {name: ident("target:" + name) for name in products}
proxy = add("proxy:PacketTunnel", "PBXContainerItemProxy", containerPortal=project_id,
            proxyType="1", remoteGlobalIDString=target_ids["PacketTunnel"], remoteInfo="PacketTunnel")
dependency = add("dependency:PacketTunnel", "PBXTargetDependency", target=target_ids["PacketTunnel"], targetProxy=proxy)

for name, sources, used_frameworks in [
    ("AutoDarkShift", app + keepalive + shared + monitoring + platform, list(frameworks)),
    ("PacketTunnel", tunnel + shared + monitoring + platform, ["Foundation", "UIKit", "NetworkExtension", "UserNotifications"]),
    ("AutoDarkShiftCoreTests", tests + shared + monitoring + ["Platform/LoopbackMonitorTransport.swift"], []),
]:
    source_builds = [add("build:" + name + ":" + path, "PBXBuildFile", fileRef=refs[path]) for path in sources]
    framework_builds = [add("link:" + name + ":" + f, "PBXBuildFile", fileRef=frameworks[f]) for f in used_frameworks]
    phases = [
        add("sources:" + name, "PBXSourcesBuildPhase", buildActionMask="2147483647", files=array(source_builds), runOnlyForDeploymentPostprocessing="0"),
        add("frameworks:" + name, "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=array(framework_builds), runOnlyForDeploymentPostprocessing="0"),
        add("resources:" + name, "PBXResourcesBuildPhase", buildActionMask="2147483647", files="()", runOnlyForDeploymentPostprocessing="0"),
    ]
    if name == "AutoDarkShift":
        embed = add("build:EmbedPacketTunnel", "PBXBuildFile", fileRef=products["PacketTunnel"],
                    settings="{ ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy,); }")
        phases.append(add("embed:PacketTunnel", "PBXCopyFilesBuildPhase", buildActionMask="2147483647", dstPath=quote(""),
                          dstSubfolderSpec="13", files=array([embed]), name=quote("Embed App Extensions"), runOnlyForDeploymentPostprocessing="0"))

    def target_settings(configuration, name=name):
        values = {"PRODUCT_NAME": quote("$(TARGET_NAME)"), "GENERATE_INFOPLIST_FILE": "NO",
                  "LD_RUNPATH_SEARCH_PATHS": quote("$(inherited) @executable_path/Frameworks")}
        if name == "AutoDarkShift":
            values.update(PRODUCT_BUNDLE_IDENTIFIER=quote("$(APP_BUNDLE_ID)"),
                          INFOPLIST_FILE=quote("App/Info.plist"), CODE_SIGN_ENTITLEMENTS=quote("App/AutoDarkShift.entitlements"))
        elif name == "PacketTunnel":
            values.update(PRODUCT_BUNDLE_IDENTIFIER=quote("$(TUNNEL_BUNDLE_ID)"),
                          INFOPLIST_FILE=quote("PacketTunnel/Info.plist"), CODE_SIGN_ENTITLEMENTS=quote("PacketTunnel/PacketTunnel.entitlements"),
                          APPLICATION_EXTENSION_API_ONLY="YES", SKIP_INSTALL="YES",
                          LD_RUNPATH_SEARCH_PATHS=quote("$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks"))
        else:
            values.update(PRODUCT_BUNDLE_IDENTIFIER=quote("$(APP_BUNDLE_ID).CoreTests"),
                          GENERATE_INFOPLIST_FILE="YES", SKIP_INSTALL="YES")
        return values

    configurations = configuration_list(name, target_settings)
    add("target:" + name, "PBXNativeTarget", buildConfigurationList=configurations, buildPhases=array(phases),
        buildRules="()", dependencies=array([dependency] if name == "AutoDarkShift" else []), name=quote(name),
        productName=quote(name), productReference=products[name],
        productType=quote("com.apple.product-type.application" if name == "AutoDarkShift" else
                          "com.apple.product-type.app-extension" if name == "PacketTunnel" else "com.apple.product-type.bundle.unit-test"))

target_attributes = " ".join(
    f"{target_ids[name]} = {{ CreatedOnToolsVersion = 15.0; " +
    ("SystemCapabilities = { com.apple.ApplicationGroups.iOS = { enabled = 1; }; com.apple.NetworkExtensions.iOS = { enabled = 1; }; }; " if name != "AutoDarkShiftCoreTests" else "") + "};"
    for name in products
)
add("project", "PBXProject", attributes="{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1500; TargetAttributes = { " + target_attributes + " }; }",
    buildConfigurationList=project_configs, compatibilityVersion=quote("Xcode 14.0"), developmentRegion="en",
    hasScannedForEncodings="0", knownRegions=array(["en", quote("zh-Hans"), "Base"]), mainGroup=main_group,
    productRefGroup=product_group, projectDirPath=quote(""), projectRoot=quote(""), targets=array(list(target_ids.values())))

PROJECT.mkdir(exist_ok=True)
lines = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {};", "\tobjectVersion = 56;", "\tobjects = {"]
for key, fields in sorted(objects.items(), key=lambda item: (item[1]["isa"], item[0])):
    lines.append("\t\t" + key + " = { " + " ".join(f"{k} = {v};" for k, v in fields.items()) + " };")
lines.extend(["\t};", f"\trootObject = {project_id};", "}", ""])
(PROJECT / "project.pbxproj").write_text("\n".join(lines), encoding="utf-8")


def build_reference(parent, name):
    return ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=target_ids[name],
                         BuildableName={"AutoDarkShift": "AutoDarkShift.app", "AutoDarkShiftCoreTests": "AutoDarkShiftCoreTests.xctest"}[name],
                         BlueprintName=name, ReferencedContainer="container:AutoDarkShift.xcodeproj")


def scheme(name, app_enabled):
    root = ET.Element("Scheme", LastUpgradeVersion="1500", version="1.3")
    build = ET.SubElement(root, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
    entries = ET.SubElement(build, "BuildActionEntries")
    for target in (["AutoDarkShift"] if app_enabled else []) + ["AutoDarkShiftCoreTests"]:
        entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES" if target == "AutoDarkShift" else "NO",
                              buildForProfiling="YES" if target == "AutoDarkShift" else "NO", buildForArchiving="YES" if target == "AutoDarkShift" else "NO", buildForAnalyzing="YES")
        build_reference(entry, target)
    test_action = ET.SubElement(root, "TestAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                               selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB", shouldUseLaunchSchemeArgsEnv="YES")
    testables = ET.SubElement(test_action, "Testables")
    testable = ET.SubElement(testables, "TestableReference", skipped="NO")
    build_reference(testable, "AutoDarkShiftCoreTests")
    if app_enabled:
        launch = ET.SubElement(root, "LaunchAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                               selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB", launchStyle="0", useCustomWorkingDirectory="NO",
                               ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES", debugServiceExtension="internal", allowLocationSimulation="YES")
        runnable = ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0")
        build_reference(runnable, "AutoDarkShift")
        profile = ET.SubElement(root, "ProfileAction", buildConfiguration="Release", shouldUseLaunchSchemeArgsEnv="YES", savedToolIdentifier="",
                                useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
        build_reference(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"), "AutoDarkShift")
    ET.SubElement(root, "AnalyzeAction", buildConfiguration="Debug")
    ET.SubElement(root, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
    ET.indent(root, space="  ")
    directory = PROJECT / "xcshareddata" / "xcschemes"
    directory.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(directory / (name + ".xcscheme"), encoding="utf-8", xml_declaration=True)


scheme("AutoDarkShift", True)
scheme("AutoDarkShiftCore", False)
workspace = PROJECT / "project.xcworkspace"
workspace.mkdir(exist_ok=True)
(workspace / "contents.xcworkspacedata").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>\n', encoding="utf-8")
print(f"Generated {len(objects)} project objects and 2 shared schemes.")
