#!/usr/bin/env python3
"""A stand-in for `op` in the tests. Serves items from $FAKE_OP_DB (JSON: a list
of full items), logs every argv to $FAKE_OP_LOG, and rejects any command line
the broker isn't supposed to use, so the tests also pin the exact invocations."""

import json
import os
import sys

args = sys.argv[1:]
with open(os.environ["FAKE_OP_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")

# The broker appends --account when configured.
if "--account" in args:
    i = args.index("--account")
    args = args[:i] + args[i + 2 :]

with open(os.environ["FAKE_OP_DB"]) as f:
    db = json.load(f)


def summary(item):
    keep = ("id", "title", "vault", "category", "urls", "additional_information")
    return {k: item[k] for k in keep if k in item}


if args[:6] == ["item", "list", "--categories", "Login", "--format", "json"]:
    rest = args[6:]
    vault = None
    if rest[:1] == ["--vault"] and len(rest) == 2:
        vault = rest[1]
    elif rest:
        sys.exit("fake op: unexpected list args %r" % rest)
    items = [summary(i) for i in db if vault is None or vault in (i["vault"]["id"], i["vault"]["name"])]
    print(json.dumps(items))
elif len(args) == 8 and args[:2] == ["item", "get"] and args[3] == "--vault" and args[5:] == ["--format", "json", "--reveal"]:
    for item in db:
        if item["id"] == args[2] and item["vault"]["id"] == args[4]:
            print(json.dumps(item))
            break
    else:
        sys.exit('[ERROR] "%s" isn\'t an item' % args[2])
elif len(args) == 6 and args[:2] == ["item", "get"] and args[3] == "--vault" and args[5] == "--otp":
    for item in db:
        if item["id"] == args[2] and item["vault"]["id"] == args[4]:
            print(item.get("_otp", ""))
            break
    else:
        sys.exit("not found")
else:
    sys.exit("fake op: unexpected command %r" % args)
