#!/usr/bin/env python3
"""fpdiff.py a.json b.json [hard|soft]: exit 1 and list keys whose values differ."""
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3]); sec = sys.argv[3] if len(sys.argv) > 3 else "hard"
bad = [k for k in sorted(set(a[sec]) | set(b[sec])) if a[sec].get(k) != b[sec].get(k)]
errs = [k for k, v in a[sec].items() if str(v).startswith("ERR")]
for k in bad:
    print(f"DIFF {k}: {str(a[sec].get(k))[:160]} -> {str(b[sec].get(k))[:160]}")
print(f"{sec}: {len(a[sec])} keys, {len(bad)} differ, {len(errs)} errored on the first side ({','.join(errs)[:200]})")
sys.exit(1 if bad else 0)
