#!/usr/bin/env python3
"""Replay deduplicated Boost CSV/JSONL with the current production Swift model.

Generated reports belong in local-data/analysis/. Recorded v1 scores are comparison
data; v2 row-state score verification is distinct from a cold-start trajectory replay.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path

from decode_boost_trace import decode

ROOT = Path(__file__).resolve().parent.parent


def number(value):
    return None if value in (None, "", "none") else float(value)


def alias(row, *keys):
    return next((row[key] for key in keys if row.get(key) not in (None, "")), None)


def read_inputs(paths, forced_version):
    rows = []
    versions = {}
    for path in paths:
        if path.suffix.lower() == ".csv":
            with path.open(encoding="utf-8-sig", newline="") as source:
                records = [{"fields": row} for row in csv.DictReader(source)]
        else:
            records = list(decode([path]))
        for record in records:
            fields = record.get("fields", {})
            if record.get("event") == "boost_trace_start":
                versions[fields["traceID"]] = int(fields.get("modelVersion", 1))
            if record.get("event") not in (None, "boost_trace_sample"):
                continue
            timestamp = alias(fields, "timestamp_utc", "timestamp") or record.get("timestamp")
            if not timestamp:
                raise ValueError(f"{path}: sample has no timestamp")
            filtered = number(fields.get("filteredBrightness"))
            version = forced_version or versions.get(alias(fields, "trace_id", "traceID"))
            if version is None:
                version = 2 if filtered is not None else 1
            rows.append({
                "instanceID": alias(fields, "instance_id", "instanceID") or record.get("instanceID") or "unknown_csv_instance",
                "sequence": int(fields["sequence"]),
                "timestamp": datetime.fromisoformat(timestamp.replace("Z", "+00:00")).timestamp(),
                "uptime": number(fields.get("uptime")),
                "actualInterval": number(alias(fields, "actual_interval_s", "actualInterval")),
                "brightness": float(fields["brightness"]), "source": fields["source"],
                "recordedModelVersion": version,
                "recordedScore": number(fields.get("S")),
                "recordedBaseline": number(fields.get("baseline")),
                "recordedVelocity": number(fields.get("velocity")),
                "recordedFilteredBrightness": filtered,
                "recordedFrequency": number(alias(fields, "next_frequency_hz", "nextFrequency")),
            })
    unique = {}
    for row in rows:
        key = (row["instanceID"], row["sequence"])
        if key in unique:
            prior = unique[key]
            if (prior["brightness"], prior["timestamp"], prior["source"]) != (row["brightness"], row["timestamp"], row["source"]):
                raise ValueError(f"conflicting duplicate observation: {key}")
        else:
            unique[key] = row
    result = sorted(unique.values(), key=lambda row: (row["instanceID"], row["sequence"]))
    previous = None
    reconstructed = 0
    for row in result:
        if row["uptime"] is None:
            reconstructed += 1
            if previous and row["instanceID"] == previous["instanceID"]:
                interval = row["actualInterval"] if row["sequence"] == previous["sequence"] + 1 else None
                row["uptime"] = previous["uptime"] + (interval if interval is not None else row["timestamp"] - previous["timestamp"])
            else:
                row["uptime"] = 0
        previous = row
    return result, {"inputRows": len(rows), "uniqueSamples": len(result),
                    "duplicateRows": len(rows) - len(result), "reconstructedUptimeRows": reconstructed}


def transitions(rows, key):
    count = 0
    previous = None
    instance = None
    for row in rows:
        if row.get("reset") or row["instanceID"] != instance:
            previous = None
        value = row.get(key) if key != "v2Baseline" else row.get("trend", {}).get("baseline")
        if value is not None and previous is not None and value != previous:
            count += 1
        previous = value
        instance = row["instanceID"]
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--recorded-model-version", type=int, choices=(1, 2), help="Override CSV inference")
    args = parser.parse_args()
    if args.output.resolve() in {path.resolve() for path in args.inputs}:
        parser.error("report cannot overwrite an input")
    try:
        rows, counts = read_inputs(args.inputs, args.recorded_model_version)
        if not rows:
            raise ValueError("no Boost samples in the supplied input")
        environment = os.environ.copy()
        if not environment.get("DEVELOPER_DIR"):
            for directory in (Path("/Applications/Xcode.app/Contents/Developer"), Path.home() / "Downloads/Xcode.app/Contents/Developer"):
                if directory.exists():
                    environment["DEVELOPER_DIR"] = str(directory)
                    break
        compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], env=environment, text=True).strip() if shutil.which("xcrun") else shutil.which("swiftc")
        if not compiler:
            raise ValueError("swiftc is required")
        with tempfile.TemporaryDirectory(prefix="darkshift-trend-replay-") as temporary:
            work = Path(temporary)
            samples = work / "input.json"
            samples.write_text(json.dumps(rows, allow_nan=False), encoding="utf-8")
            executable = work / "trend-replay"
            cache = ROOT / "build/TrendReplayModuleCache"
            subprocess.run([compiler, "-swift-version", "5", "-module-cache-path", str(cache), "-parse-as-library",
                            *map(str, sorted((ROOT / "Shared").glob("*.swift"))),
                            str(ROOT / "tools/trend_replay_main.swift"), "-o", str(executable)],
                           check=True, env=environment, cwd=ROOT)
            output = json.loads(subprocess.check_output([str(executable), str(samples)], env=environment))
        state_errors = [abs(row["recordedStateScoreError"]) for row in output if "recordedStateScoreError" in row]
        summary = {**counts, "recordedFrequencyChanges": transitions(output, "recordedFrequency"),
                   "replayFrequencyChanges": transitions(output, "frequency"),
                   "recordedBaselineChanges": transitions(output, "recordedBaseline"),
                   "replayBaselineChanges": transitions(output, "v2Baseline"),
                   "resets": [{"sequence": row["sequence"], "reason": row["reset"]} for row in output if "reset" in row],
                   "replayCandidates": [{"sequence": row["sequence"], "mode": row["candidate"], "timestamp": row["timestamp"]} for row in output if "candidate" in row],
                   "recordedStateScoreChecks": len(state_errors), "maxRecordedStateScoreError": max(state_errors, default=None)}
        report = {"modelVersion": 2, "inputs": [str(path) for path in args.inputs], "summary": summary,
                  "limitations": ["Visible-window cold start; missing earlier peak/origin history is not fabricated.",
                                  "Missing sequences reset observations even when the visible time gap is short.",
                                  "Immediate-success notification counterfactual; no device appearance labels or accuracy metric.",
                                  "The recorded sampling grid is reused; this is not a simulation of the new timer's future readings.",
                                  "CSV without uptime uses adjacent actual intervals and UTC only across missing sequences."],
                  "samples": output}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.output.with_name(args.output.name + ".partial")
        temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
        temporary.replace(args.output)
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"replay failed: {error}\n")


if __name__ == "__main__":
    main()
