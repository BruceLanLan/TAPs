#!/usr/bin/env python3
"""Tiny receipt reader for `cast send --json` output (cast 1.8 wraps it as {"data": receipt}).

  rx.py field <receipt.json> <name>          print a receipt field (hex numbers converted to decimal)
  rx.py events <receipt.json> <topic0> [addr] one line per matching log: topic1 topic2 topic3 | data words
  rx.py ok <receipt.json>                     exit 0 if status == 1, else print the error and exit 1
"""
import json
import sys


def load(p):
    d = json.load(open(p))
    if isinstance(d, dict) and "schema_version" in d:
        if not d.get("success"):
            return None, d.get("errors")
        d = d["data"]
    return d, None


def main(a):
    cmd, path = a[0], a[1]
    r, err = load(path)
    if cmd == "ok":
        if r is None or int(r["status"], 16) != 1:
            print("FAILED:", err if r is None else "status " + r["status"])
            return 1
        return 0
    if r is None:
        print("NO-RECEIPT", err)
        return 1
    if cmd == "field":
        v = r[a[2]]
        print(int(v, 16) if isinstance(v, str) and v.startswith("0x") and a[2] not in ("transactionHash", "contractAddress", "from", "to") else v)
    elif cmd == "events":
        t0 = a[2].lower()
        addr = a[3].lower() if len(a) > 3 else None
        for log in r["logs"]:
            if log["topics"] and log["topics"][0].lower() == t0 and (addr is None or log["address"].lower() == addr):
                data = log["data"][2:]
                words = [data[i:i + 64] for i in range(0, len(data), 64)]
                print(" ".join(t for t in log["topics"][1:]), "|", " ".join(words))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
