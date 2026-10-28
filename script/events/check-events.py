#!/usr/bin/env python3
"""Generate or check this repo's ABI event manifest baseline and event families.

Usage:
  python3 script/events/check-events.py [--update] [--no-build]

Baseline: script/events/events-baseline.txt
Families: script/events/event-families.txt  (one `EventName family` per line)
Only concrete contracts declared under src/ are included; interfaces, libraries,
and abstract contracts are excluded. Requires forge on PATH unless --no-build is
used with an existing out/ directory.
"""

# Everything outside the FAMILIES table is byte-identical across core/action/group-chat;
# the table itself is a per-repo slice of matt-gov/docs/event-standards.md §6.1.

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

EVENTS_DIR = Path(__file__).resolve().parent
REPO = EVENTS_DIR.parent.parent

# Family slot rules from matt-gov/docs/event-standards.md §6.1, this repo's families only.
#   root: allowed first field names; empty means the emitter itself is the root key.
#   round_after: `round` must follow at least one of these fields when present.
FAMILIES = {
    "action.registry": {"root": ("tokenAddress",), "round_after": ("actionId",)},
    "action.config": {"root": ("tokenAddress",), "round_after": ()},
    "action.group": {"root": ("tokenAddress",), "round_after": ("actionId",)},
    "action.participation": {
        "root": ("tokenAddress", "serviceTokenAddress"),
        "round_after": ("memberId",),
    },
    "action.round": {"root": ("tokenAddress",), "round_after": ("actionId",)},
    "action.quota": {"root": ("tokenAddress",), "round_after": ()},
    "action.verification": {
        "root": ("tokenAddress",),
        "round_after": ("actionId", "groupId", "memberId"),
    },
    "action.recipients": {"root": ("sourceTokenAddress",), "round_after": ("sourceActionId",)},
    "action.service": {"root": ("serviceTokenAddress",), "round_after": ("serviceActionId",)},
}

# Standard token events inherited from OZ are outside the spec (see §9) and carry no family.
STANDARD_EVENTS = {"Transfer", "Approval", "ApprovalForAll", "TransferSingle", "TransferBatch"}


def canonical_type(inp):
    typ = inp.get("type", "")
    if typ.startswith("tuple"):
        comps = ",".join(canonical_type(c) for c in inp.get("components", []))
        return f"({comps}){typ[len('tuple'):]}"
    return typ


def is_concrete_contract(source, contract):
    path = REPO / source
    if not path.exists():
        return False
    text = path.read_text()
    if re.search(rf"\blibrary\s+{re.escape(contract)}\b", text):
        return False
    if re.search(rf"\babstract\s+contract\s+{re.escape(contract)}\b", text):
        return False
    return bool(re.search(rf"\bcontract\s+{re.escape(contract)}\b", text))


def load_events():
    out = REPO / "out"
    if "--no-build" not in sys.argv:
        forge = shutil.which("forge")
        if not forge:
            sys.exit("forge not found; add ~/.foundry/bin to PATH or use --no-build")
        subprocess.run([forge, "build", "--locked"], cwd=REPO, check=True)
    if not out.exists():
        sys.exit("missing out/; run forge build first")

    events = set()
    for path in out.rglob("*.json"):
        if "build-info" in path.parts:
            continue
        try:
            data = json.loads(path.read_text())
        except Exception:
            continue
        targets = ((data.get("metadata") or {}).get("settings") or {}).get(
            "compilationTarget"
        ) or {}
        if len(targets) != 1:
            continue
        source, contract = next(iter(targets.items()))
        if not source.startswith("src/"):
            continue
        if not is_concrete_contract(source, contract):
            continue
        for item in data.get("abi") or []:
            if item.get("type") != "event":
                continue
            inputs = ",".join(
                f"{i.get('name', '')}:{canonical_type(i)}{' indexed' if i.get('indexed') else ''}"
                for i in item.get("inputs", [])
            )
            anonymous = " anonymous" if item.get("anonymous") else ""
            events.add(f"{contract}.{item['name']}({inputs}){anonymous}")
    return sorted(events)


def split_params(body):
    parts, depth, current = [], 0, ""
    for ch in body:
        if ch == "," and depth == 0:
            parts.append(current)
            current = ""
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        current += ch
    if current.strip():
        parts.append(current)
    return [part.strip() for part in parts if part.strip()]


def parse_baseline(lines):
    parsed = []
    for line in lines:
        match = re.match(r"^(\w+)\.(\w+)\((.*)\)( anonymous)?$", line)
        if not match:
            sys.exit(f"unparseable baseline line: {line}")
        params = []
        for part in split_params(match.group(3)):
            name = part.split(":", 1)[0].strip()
            params.append(name)
        parsed.append((match.group(2), params))
    return parsed


def load_families():
    path = EVENTS_DIR / "event-families.txt"
    if not path.exists():
        sys.exit(f"missing family map: {path}")
    mapping = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 2:
            sys.exit(f"bad family line: {line}")
        event, family = fields
        if event in mapping:
            sys.exit(f"duplicate family assignment: {event}")
        if family not in FAMILIES:
            sys.exit(f"unknown family {family} for {event}")
        mapping[event] = family
    return mapping


def check_families(events):
    mapping = load_families()
    protocol = [(name, params) for name, params in events if name not in STANDARD_EVENTS]
    names = {name for name, _ in protocol}
    missing = sorted(names - set(mapping))
    extra = sorted(set(mapping) - names)
    if missing:
        sys.exit("events without a family: " + ", ".join(missing))
    if extra:
        sys.exit("family entries without an event: " + ", ".join(extra))

    problems = []
    for name, params in protocol:
        rule = FAMILIES[mapping[name]]
        roots = rule["root"]
        if roots and (not params or params[0] not in roots):
            problems.append(f"{name}: first field {params[0] if params else '<none>'} not in {roots}")
        if "round" in params:
            index = params.index("round")
            anchors = [params.index(a) for a in rule["round_after"] if a in params]
            if anchors and index < max(anchors):
                problems.append(f"{name}: round before {params[max(anchors)]}")
    if problems:
        sys.exit("family slot violations:\n  " + "\n  ".join(problems))
    return len(names)


def main():
    lines = load_events()
    baseline = EVENTS_DIR / "events-baseline.txt"
    parsed = parse_baseline(lines)

    if "--update" in sys.argv:
        count = check_families(parsed)
        baseline.write_text("\n".join(lines) + "\n")
        print(f"wrote {len(lines)} events to {baseline}")
        print(f"event families OK: {count} protocol events")
        return

    if not baseline.exists():
        sys.exit(f"missing baseline: {baseline}; run with --update")
    expected = [line for line in baseline.read_text().splitlines() if line.strip()]
    if len(expected) != len(set(expected)):
        sys.exit("baseline contains duplicate lines")
    if expected != lines:
        missing = sorted(set(expected) - set(lines))
        extra = sorted(set(lines) - set(expected))
        print(f"event manifest mismatch: {len(missing)} missing, {len(extra)} extra")
        for line in missing:
            print("  -", line)
        for line in extra:
            print("  +", line)
        sys.exit(1)

    check_families(parsed)
    print(f"event manifest OK: {len(lines)} events; families OK")


if __name__ == "__main__":
    main()
