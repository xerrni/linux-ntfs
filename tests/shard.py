#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Pick the guest scripts one CI shard runs.

    tests/shard.py I/N SCRIPT...

Prints, one per line and in the order given, the SCRIPTs that shard I
(1 to N) of N runs, so that the N shards take about the same time. The run
times come from tests/durations.txt (seconds per script name; a script not
listed counts 60 s). The slowest script goes first to the shard with the
least work so far (longest processing time first).

A script with the line "# shardable" in its header splits its own work:
it reads SHARD=I/N in the guest and runs only its part. Every shard gets
such a script, and each shard starts with 1/N of its time.

The durations come from the run time column of tests/run_reproducers.sh;
for a shardable script use the sum over its shards. Refresh the file when
the shards of a full run end far apart.

Example:
    tests/shard.py 2/4 hole_fill_stale.sh short_copy_stale.sh fsx_parallel.sh
"""
import os
import sys

DEFAULT = 60


def durations(here):
    times = {}
    with open(os.path.join(here, "durations.txt")) as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2 and not line.startswith("#"):
                times[parts[0]] = int(parts[1])
    return times


def shardable(here, script):
    path = os.path.join(here, os.path.basename(script))
    try:
        with open(path) as f:
            head = [next(f, "") for _ in range(30)]
    except OSError:
        return False
    return any(line.strip() == "# shardable" for line in head)


def name(script):
    base = os.path.basename(script)
    return base[:-3] if base.endswith(".sh") else base


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    try:
        index, count = (int(x) for x in argv[1].split("/"))
    except ValueError:
        print(f"bad shard {argv[1]!r}, want I/N", file=sys.stderr)
        return 2
    if not 1 <= index <= count:
        print(f"bad shard {argv[1]!r}: I must be 1 to N", file=sys.stderr)
        return 2
    here = os.path.dirname(os.path.abspath(__file__))
    times = durations(here)
    scripts = argv[2:]
    split = [s for s in scripts if shardable(here, s)]
    whole = [s for s in scripts if s not in split]
    start = sum(times.get(name(s), DEFAULT) for s in split) / count
    load = [start] * count
    mine = set(split)
    # sorted() is stable: equal times keep the order given
    for s in sorted(whole, key=lambda s: -times.get(name(s), DEFAULT)):
        k = load.index(min(load))
        load[k] += times.get(name(s), DEFAULT)
        if k == index - 1:
            mine.add(s)
    for s in scripts:
        if s in mine:
            print(s)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
