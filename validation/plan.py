#!/usr/bin/env python3
"""Turn validation/RUN into the job matrix. Line: name | amd64,arm64 | timeout-min | command"""
import json, pathlib
RUNNERS = {"amd64": "ubuntu-24.04", "arm64": "ubuntu-24.04-arm"}
rows = []
for line in pathlib.Path(__file__).with_name("RUN").read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    name, arches, timeout, cmd = [p.strip() for p in line.split("|", 3)]
    for arch in arches.split(","):
        rows.append({"name": f"{name}-{arch}", "runner": RUNNERS[arch], "timeout": int(timeout), "cmd": cmd})
print("matrix=" + json.dumps(rows))
