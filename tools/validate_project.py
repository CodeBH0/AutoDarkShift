"""Static project-integrity checks only; does not compile Swift or execute XCTest."""
from pathlib import Path
import json
import re
import plistlib
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent


def parse_openstep(text):
    pattern = r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,"]+'
    tokens = [token for token in re.findall(pattern, text, re.S)
              if not token.startswith("//") and not token.startswith("/*")]
    index = 0

    def take(expected=None):
        nonlocal index
        assert index < len(tokens), "Unexpected end of project"
        token = tokens[index]
        index += 1
        if expected:
            assert token == expected, f"Expected {expected}, got {token}"
        return json.loads(token) if token.startswith('"') else token

    def value():
        if tokens[index] == "{":
            take("{")
            result = {}
            while tokens[index] != "}":
                key = take()
                assert key not in result, f"Duplicate key: {key}"
                take("=")
                result[key] = value()
                take(";")
            take("}")
            return result
        if tokens[index] == "(":
            take("(")
            result = []
            while tokens[index] != ")":
                result.append(value())
                if tokens[index] != ")":
                    take(",")
            take(")")
            return result
        return take()

    result = value()
    assert index == len(tokens), "Unparsed project content"
    return result


project = parse_openstep((ROOT / "AutoDarkShift.xcodeproj/project.pbxproj").read_text(encoding="utf-8"))
objects = project["objects"]
root = objects[project["rootObject"]]
assert root["isa"] == "PBXProject"


def verify_references(value):
    if isinstance(value, dict):
        for item in value.values():
            verify_references(item)
    elif isinstance(value, list):
        for item in value:
            verify_references(item)
    elif re.fullmatch(r"[A-F0-9]{24}", value):
        assert value in objects, f"Unresolved object reference: {value}"


verify_references(project)
local_files = []
for item in objects.values():
    if item["isa"] == "PBXFileReference" and item.get("sourceTree") == "SOURCE_ROOT":
        assert (ROOT / item["path"]).is_file(), f"Missing project file: {item['path']}"
        local_files.append(item["path"])

targets = {objects[key]["name"]: objects[key] for key in root["targets"]}
assert set(targets) == {"AutoDarkShift", "PacketTunnel", "AutoDarkShiftCoreTests"}
expected_sources = {
    "AutoDarkShift": {str(p.relative_to(ROOT)) for folder in ["App", "KeepAlive", "Shared", "Monitoring", "Platform"]
                      for p in (ROOT / folder).glob("*.swift")},
    "PacketTunnel": {str(p.relative_to(ROOT)) for folder in ["PacketTunnel", "Shared", "Monitoring", "Platform"]
                     for p in (ROOT / folder).glob("*.swift")},
    "AutoDarkShiftCoreTests": {str(p.relative_to(ROOT)) for folder in ["Tests", "Shared", "Monitoring"]
                              for p in (ROOT / folder).glob("*.swift")} | {"Platform/LoopbackMonitorTransport.swift"},
}
for name, target in targets.items():
    phases = [objects[key] for key in target["buildPhases"]]
    sources = [phase for phase in phases if phase["isa"] == "PBXSourcesBuildPhase"]
    assert len(sources) == 1
    paths = [objects[objects[key]["fileRef"]]["path"] for key in sources[0]["files"]]
    assert len(paths) == len(set(paths)), f"Duplicate source membership: {name}"
    assert set(paths) == expected_sources[name], f"Unexpected source membership: {name}"
    configs = objects[target["buildConfigurationList"]]["buildConfigurations"]
    assert {objects[key]["name"] for key in configs} == {"Debug", "Release"}
    for key in configs:
        settings = objects[key]["buildSettings"]
        if name != "AutoDarkShiftCoreTests":
            assert (ROOT / settings["INFOPLIST_FILE"]).is_file()
            assert (ROOT / settings["CODE_SIGN_ENTITLEMENTS"]).is_file()
            assert settings["PRODUCT_BUNDLE_IDENTIFIER"] == ("$(APP_BUNDLE_ID)" if name == "AutoDarkShift" else "$(TUNNEL_BUNDLE_ID)")
        if name == "PacketTunnel":
            assert settings["APPLICATION_EXTENSION_API_ONLY"] == "YES"

app_phases = [objects[key] for key in targets["AutoDarkShift"]["buildPhases"]]
embed = next(phase for phase in app_phases if phase["isa"] == "PBXCopyFilesBuildPhase")
assert embed["dstSubfolderSpec"] == "13"
assert len(embed["files"]) == 1
embedded_build = objects[embed["files"][0]]
assert embedded_build["fileRef"] == targets["PacketTunnel"]["productReference"]
assert "CodeSignOnCopy" in embedded_build["settings"]["ATTRIBUTES"]
dependency = objects[targets["AutoDarkShift"]["dependencies"][0]]
assert objects[dependency["target"]]["name"] == "PacketTunnel"

plists = {}
for path in ["App/Info.plist", "PacketTunnel/Info.plist", "App/AutoDarkShift.entitlements", "PacketTunnel/PacketTunnel.entitlements"]:
    with (ROOT / path).open("rb") as handle:
        plists[path] = plistlib.load(handle)
app_info = plists["App/Info.plist"]
tunnel_info = plists["PacketTunnel/Info.plist"]
assert app_info["AppGroupIdentifier"] == tunnel_info["AppGroupIdentifier"] == "$(APP_GROUP_ID)"
assert app_info["RuntimeProtocolVersion"] == tunnel_info["RuntimeProtocolVersion"] == 3
assert app_info["RuntimeStorageMode"] == tunnel_info["RuntimeStorageMode"] == "app-group-v1"
assert app_info["RuntimeSupportedStorageModes"] == tunnel_info["RuntimeSupportedStorageModes"] == ["app-group-v1", "local-ipc-v1"]
assert app_info["PacketTunnelBundleIdentifier"] == "$(TUNNEL_BUNDLE_ID)"
assert tunnel_info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.networkextension.packet-tunnel"
assert tunnel_info["NSExtension"]["NSExtensionPrincipalClass"] == "$(PRODUCT_MODULE_NAME).PacketTunnelProvider"
for path in ["App/AutoDarkShift.entitlements", "PacketTunnel/PacketTunnel.entitlements"]:
    assert plists[path]["com.apple.security.application-groups"] == ["$(APP_GROUP_ID)"]
    assert plists[path]["com.apple.developer.networking.networkextension"] == ["packet-tunnel-provider"]

for name in ["AutoDarkShift", "AutoDarkShiftCore"]:
    tree = ET.parse(ROOT / f"AutoDarkShift.xcodeproj/xcshareddata/xcschemes/{name}.xcscheme")
    for reference in tree.findall(".//BuildableReference"):
        assert objects[reference.attrib["BlueprintIdentifier"]]["name"] == reference.attrib["BlueprintName"]
    testables = tree.findall(".//TestableReference/BuildableReference")
    assert len(testables) == 1 and testables[0].attrib["BlueprintName"] == "AutoDarkShiftCoreTests"
ET.parse(ROOT / "AutoDarkShift.xcodeproj/project.xcworkspace/contents.xcworkspacedata")
configuration_text = (ROOT / "Config/Project.xcconfig").read_text(encoding="utf-8")
assert re.search(r"^IPHONEOS_DEPLOYMENT_TARGET\s*=\s*17\.0\s*$", configuration_text, re.M)
assert re.search(r"^SWIFT_VERSION\s*=\s*5\.0\s*$", configuration_text, re.M)
assert re.search(r"^CODE_SIGN_STYLE\s*=\s*Automatic\s*$", configuration_text, re.M)
assert re.search(r"^DEVELOPMENT_TEAM\s*=[ \t]*$", configuration_text, re.M)
assert '#include? "Local.xcconfig"' in configuration_text

test_names = [name for path in (ROOT / "Tests").glob("*.swift")
              for name in re.findall(r"func (test\w+)\(", path.read_text(encoding="utf-8"))]
assert len(test_names) == len(set(test_names))

# Enforce platform and business dependency boundaries.
for path in (ROOT / "Monitoring").glob("*.swift"):
    text = path.read_text(encoding="utf-8")
    assert not re.search(r"import (UIKit|NetworkExtension|AVKit|UserNotifications)", text), path
    assert "vpn_" not in text and "NEVPN" not in text, path
for path in [ROOT / "App/AppController.swift", ROOT / "App/ControlView.swift"]:
    assert "import NetworkExtension" not in path.read_text(encoding="utf-8"), path
for folder in ["PacketTunnel", "Shared", "Monitoring", "Platform"]:
    for path in (ROOT / folder).glob("*.swift"):
        assert "import AVKit" not in path.read_text(encoding="utf-8"), "PiP must remain in app keep-alive adapters"
for name in ["KeepAliveContracts.swift", "KeepAliveManager.swift", "KeepAliveSwitchControl.swift"]:
    text = (ROOT / "Shared" / name).read_text(encoding="utf-8")
    assert not re.search(r"import (UIKit|SwiftUI|NetworkExtension|AVKit|AVFoundation|CoreLocation|UserNotifications)", text), name
    assert not any(symbol in text for symbol in ["MonitoringClient", "MonitorConfiguration", "SwitchMonitor", "MonitorStore"]), name
with (ROOT / "App/Info.plist").open("rb") as source:
    app_info = plistlib.load(source)
assert set(app_info.get("UIBackgroundModes", [])) == {"audio", "location"}
assert app_info.get("NSLocationWhenInUseUsageDescription") and app_info.get("NSLocationAlwaysAndWhenInUseUsageDescription")
# Retired benchmark sources must never enter the active targets or Swift Package.
retired_symbols = ("PollingBoost", "PollingStatistics", "startPollingTest", "stopPollingTest",
                   "pollingTestID", "appendPollingResult", "readDuration", "effectivePollInterval")
for folder in ["App", "PacketTunnel", "Shared", "Monitoring", "Platform", "KeepAlive"]:
    for path in (ROOT / folder).glob("*.swift"):
        text = path.read_text(encoding="utf-8")
        assert not any(symbol in text for symbol in retired_symbols), f"Retired test component remains: {path}"
assert all(not path.startswith(("archive/", "local-data/", "build/")) for path in local_files), "Local artifacts entered Xcode project"
assert not {"AGENTS.md", "DEVELOPMENT.md"}.intersection(local_files), "Local developer documents entered Xcode project"
package_text = (ROOT / "Package.swift").read_text(encoding="utf-8")
for folder in ["archive", "local-data", "build", "AGENTS.md", "DEVELOPMENT.md"]:
    assert f'"{folder}"' in package_text, f"{folder} must be excluded from Swift Package when present"
ignore_rules = (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()
for path in ["AGENTS.md", "DEVELOPMENT.md"]:
    assert f"/{path}" in ignore_rules, f"{path} must stay local"
assert (ROOT / "docs/models/MathModel-v1.md").is_file(), "Historical mathematical model must be retained"
assert (ROOT / "docs/models/MathModel-v2.md").is_file(), "Current mathematical model must be documented separately"
print("PASS: retired test components and local inputs excluded from active targets; v1 retained and v2 documented.")
print(f"PASS: OpenStep structure; {len(objects)} resolved objects; {len(local_files)} local project files.")
print("PASS: 3 target source memberships, Debug/Release settings, extension embedding and dependency.")
print("PASS: 4 XML plists/entitlements; shared App Group and provider identifiers.")
print("PASS: runtime protocol/storage metadata; monitoring/UI dependency boundaries; native keep-alive adapters remain App-only.")
print("PASS: 2 shared Scheme XML files, test target references and workspace XML.")
print("PASS: iOS 17 / Swift 5 configuration, automatic signing, empty default team and optional local overrides.")
print(f"INFO: {len(test_names)} unique XCTest methods provided; no Swift tests executed by this script.")
print("NOT CHECKED: Swift compilation, Apple SDK availability, signing, provisioning, XCTest results, device behavior.")
