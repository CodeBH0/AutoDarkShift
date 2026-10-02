"""Compile/run the production Foundation core and shared regression scenarios, without XCTest.

Use --isolate-clt-headers only for CLT installations containing duplicate SwiftBridging maps.
It creates temporary resource links and never edits the installed toolchain or project sources.
"""
from pathlib import Path
import argparse
import json
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--isolate-clt-headers", action="store_true")
args = parser.parse_args()
compiler = shutil.which("swiftc")
if not compiler:
    raise SystemExit("swiftc is required.")

with tempfile.TemporaryDirectory(prefix="darkshift-core-") as temporary:
    temp = Path(temporary)
    flags = []
    if args.isolate_clt_headers:
        info = json.loads(subprocess.check_output([compiler, "-print-target-info"], text=True))
        original = Path(info["paths"]["runtimeResourcePath"])
        resource = temp / "usr/lib/swift"
        resource.mkdir(parents=True)
        for child in original.iterdir():
            (resource / child.name).symlink_to(child)
        original_include = original.parent.parent / "include/swift"
        include = temp / "usr/include/swift"
        include.mkdir(parents=True)
        for child in original_include.iterdir():
            if child.name != "module.modulemap":
                (include / child.name).symlink_to(child)
        flags = ["-resource-dir", str(resource)]
    sources = sorted((ROOT / "Shared").glob("*.swift")) + sorted((ROOT / "Monitoring").glob("*.swift"))
    sources += [ROOT / "Platform/LoopbackMonitorTransport.swift"]
    sources += [ROOT / "Tests/RuntimeRegressionScenarios.swift", ROOT / "tools/core_check_main.swift"]
    executable = temp / "core-checks"
    subprocess.run([compiler, "-swift-version", "5", *flags, "-module-cache-path", str(temp / "module-cache"), "-parse-as-library",
                    *map(str, sources), "-o", str(executable)], check=True, cwd=ROOT)
    subprocess.run([str(executable)], check=True, cwd=ROOT)
