#!/usr/bin/env python3
"""Summarise a diag-min dump: link states, and what happened since the last deliberate drop."""
import re
import sys

t = open(sys.argv[1], errors="replace").read()
m = re.search(r"up_ms=(\d+)", t)
up = int(m[1]) if m else 0
c = re.search(r"host_conn=(\d+) host_disc=(\d+) split_conn=(\d+) split_disc=(\d+)", t)
if not c:
    print("state=unknown")
    sys.exit()
hc, hd, sc, sd = map(int, c.groups())
ev = [(int(a), b, int(x)) for a, b, x in re.findall(r"ZDIAG ev boot=\d+ ms=(\d+) type=(\S+) a=(\d+)", t)]
host_up = hc > hd
left = "on" if sc > sd else "off"
drops = [i for i, e in enumerate(ev) if e[1] == "host-disc" and e[2] == 22]
out = {"host": "up" if host_up else "down", "left": left, "up_ms": up}
if drops:
    tail = ev[drops[-1]:]
    t0 = tail[0][0]
    out["failed"] = sum(1 for e in tail if e[1] == "host-disc" and e[2] == 62)
    others = sorted({e[2] for e in tail[1:] if e[1] == "host-disc" and e[2] != 62})
    out["other"] = "/".join(map(str, others)) or "-"
    conns = [e for e in tail if e[1] == "host-conn"]
    if host_up and conns:
        out["back_ms"] = conns[-1][0] - t0
        out["stable_ms"] = up - conns[-1][0]
        out["interval"] = conns[-1][2]
    out["split_events"] = sum(1 for e in tail if e[1].startswith("split"))
print(" ".join(f"{k}={v}" for k, v in out.items()))
