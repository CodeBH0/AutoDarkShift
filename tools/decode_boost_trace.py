#!/usr/bin/env python3
"""Decode old Boost JSONL or compact boost-trace-v2 files into CSV / readable JSONL."""
from __future__ import annotations

import argparse
import csv
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

SOURCE_CODES = {0: "initial", 1: "poll", 2: "event", 3: "wake"}
TARGET_CODES = {0: "none", 1: "dark", 2: "light"}
COLUMNS = (
    "traceID", "instanceID", "phase", "sequence", "timestamp", "uptime", "brightness", "filteredBrightness",
    "source", "requestedFrequency", "nextFrequency", "S", "baseline", "desiredTarget", "pendingTarget",
    "candidateID", "inFlightID", "A", "delta", "V", "velocity", "quietDuration", "actualInterval", "pollInterval",
)


def decode(paths: list[Path]) -> Iterator[dict[str, Any]]:
    """Keep old trace IDs independently; compact samples belong to the surrounding capture block."""
    starts: dict[str, dict[str, Any]] = {}
    states: dict[str, dict[str, Any]] = {}
    active: str | None = None
    for path in paths:
        with path.open(encoding="utf-8") as source:
            for line_number, line in enumerate(source, 1):
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                    if not isinstance(record, dict):
                        raise ValueError("expected a JSON object")
                    fields = record.get("fields", {})
                    event = record.get("event")
                    if event == "boost_trace_start":
                        active = str(fields["traceID"])
                        starts[active] = record
                        states[active] = {}
                    if "s" in record:
                        if active is None:
                            raise ValueError("compact sample has no preceding trace start")
                        start = starts[active]
                        metadata = start["fields"]
                        if metadata.get("schema") != "boost-trace-v2":
                            raise ValueError(f"unsupported compact schema: {metadata.get('schema')!r}")
                        columns = metadata["sampleColumns"].split(",")
                        values = record["s"]
                        if not isinstance(values, list) or len(values) != len(columns):
                            raise ValueError("sample column count does not match the trace schema")
                        sample = dict(zip(columns, values))
                        sample["traceID"] = active
                        sample["instanceID"] = start.get("instanceID", "")
                        sample["source"] = SOURCE_CODES[sample["source"]]
                        sample["timestamp"] = datetime.fromtimestamp(sample.pop("unixSeconds"), timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
                        sample["requestedFrequency"] = sample.pop("requestedHz")
                        sample["nextFrequency"] = sample.pop("nextHz")
                        trigger = int(metadata["triggerSequence"])
                        sequence = int(sample["sequence"])
                        sample["phase"] = "preboost" if sequence < trigger else "trigger" if sequence == trigger else "tracking"
                        if "n" in record:
                            change = record["n"]
                            states[active] = {
                                "desiredTarget": TARGET_CODES[change["d"]], "pendingTarget": TARGET_CODES[change["p"]],
                                "candidateID": change["c"], "inFlightID": change["f"],
                            }
                        sample.update(states[active])
                        yield {"event": "boost_trace_sample", "instanceID": sample.pop("instanceID"),
                               "timestamp": sample.pop("timestamp"), "fields": sample}
                    elif event == "boost_trace_sample":
                        # Old captures may overlap and interleave. Never inherit another trace's start/state.
                        trace = str(fields["traceID"])
                        if not fields.get("phase") and trace in starts:
                            trigger = int(starts[trace]["fields"]["triggerSequence"])
                            sequence = int(fields["sequence"])
                            fields["phase"] = "preboost" if sequence < trigger else "trigger" if sequence == trigger else "tracking"
                        yield record
                    else:
                        yield record
                        if event in {"boost_trace_end", "boost_trace_export_boundary"} and fields.get("traceID") == active:
                            active = None
                except (ValueError, TypeError, KeyError, OverflowError) as error:
                    raise ValueError(f"{path}:{line_number}: {error}") from error
        # Compact records cannot continue in an unrelated input file.
        active = None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path, help="Exported Boost JSONL, including pre-v2 mixed exports")
    parser.add_argument("--output", required=True, type=Path, help="Explicit output path; keep generated files in local-data/analysis/")
    parser.add_argument("--format", choices=("csv", "jsonl"), help="Defaults to the output suffix")
    args = parser.parse_args()
    output: Path = args.output
    if output.resolve() in {path.resolve() for path in args.inputs}:
        parser.error("output cannot overwrite an input log")
    mode = args.format or output.suffix.lstrip(".")
    if mode not in {"csv", "jsonl"}:
        parser.error("choose --format csv/jsonl or an output with that suffix")
    try:
        # Validate the entire source before replacing a previous successful analysis file.
        records = list(decode(args.inputs))
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = output.with_name(output.name + ".partial")
        with temporary.open("w", encoding="utf-8", newline="") as target:
            if mode == "csv":
                writer = csv.DictWriter(target, fieldnames=COLUMNS, extrasaction="ignore", lineterminator="\n")
                writer.writeheader()
                for record in records:
                    if record.get("event") == "boost_trace_sample":
                        writer.writerow({**record.get("fields", {}), "timestamp": record.get("timestamp"), "instanceID": record.get("instanceID")})
            else:
                for record in records:
                    target.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
        temporary.replace(output)
    except (OSError, ValueError) as error:
        parser.exit(1, f"decode failed: {error}\n")


if __name__ == "__main__":
    main()
