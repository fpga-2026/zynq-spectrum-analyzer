#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# log_stats.py -- long-run logger for the AD snapshot firmware (CAP_MODE=1)
#
# The firmware prints 3 short lines per captured frame, so at 115200 the board
# runs at ~170 frames/s.  A serial terminal (XCOM) cannot display that fast, so
# use this logger instead: it timestamps every line, keeps the statistics, and
# prints a summary (pass rate, pedestal distribution, capture/loop timing).
#
#   python log_stats.py --port COM6 --duration 60 --out ad_log.txt
#
# Stop early with Ctrl+C; the summary is printed either way.
# -----------------------------------------------------------------------------
import argparse
import re
import sys
import time
import collections

try:
    import serial
except ImportError:
    print("pyserial required:  pip install pyserial")
    sys.exit(1)

RE_STATS = re.compile(r"FFT_STATS idx=(\d+) dc=(-?\d+) peak_bin=(\d+) "
                      r"peak_mag=(\d+) nonzero=(\d+) cap=(\d+)us loop=(\d+)us")
RE_SKIRT = re.compile(r"FFT_SKIRT idx=(\d+) ped=(\d+)\((-?\d+)dBc\) "
                      r"skirt=(\d+)\((-?\d+)dBc\) far=(\d+)\((-?\d+)dBc\)")
RE_DROP  = re.compile(r"DROP n=(\d+) ped=(-?\d+)dBc")
RE_STAT  = re.compile(r"STAT n=(\d+) kept=(\d+) ped_min=(-?\d+)dBc ped_max=(-?\d+)dBc")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM6")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--duration", type=float, default=60.0, help="seconds")
    ap.add_argument("--out", default="", help="also write the raw lines here")
    args = ap.parse_args()

    ser = serial.Serial(args.port, args.baud, timeout=0.2)
    fout = open(args.out, "w", encoding="ascii", errors="ignore") if args.out else None

    t0 = time.time()
    t_end = t0 + args.duration
    last = t0
    n_lines = n_frames = 0
    caps, loops = [], []
    ped_hist = collections.Counter()
    drops = []
    stats_lines = []

    print(f"logging {args.port} for {args.duration:.0f} s ... (Ctrl+C to stop early)")
    try:
        while time.time() < t_end:
            raw = ser.readline()
            if not raw:
                continue
            line = raw.decode("ascii", errors="ignore").strip().replace("\r", "")
            if not line:
                continue
            now = time.time()
            n_lines += 1
            if fout:
                fout.write(f"{now - t0:10.6f}  {line}\n")

            m = RE_STATS.search(line)
            if m:
                n_frames += 1
                caps.append(int(m.group(6)))
                loops.append(int(m.group(7)))
                continue
            m = RE_SKIRT.search(line)
            if m:
                ped_hist[int(m.group(3))] += 1
                continue
            m = RE_DROP.search(line)
            if m:
                drops.append(now - t0)
                continue
            m = RE_STAT.search(line)
            if m:
                stats_lines.append(line)
                print(f"  [{now - t0:7.1f}s] {line}")
                continue
            # keep the banner / any unexpected line
            print(f"  [{now - t0:7.1f}s] {line}")
            last = now
        _ = last
    except KeyboardInterrupt:
        print("\n(stopped by user)")
    finally:
        ser.close()
        if fout:
            fout.close()

    el = time.time() - t0
    print()
    print(f"--- summary ({el:.1f} s) ---")
    print(f"  accepted frames reported : {n_frames}")
    print(f"  drop notices printed     : {len(drops)}  (firmware prints every 20th drop)")
    if caps:
        print(f"  capture time  cap  : min={min(caps)}us  avg={sum(caps)/len(caps):.0f}us  max={max(caps)}us")
        print(f"  loop period   loop : min={min(loops)}us  avg={sum(loops)/len(loops):.0f}us  max={max(loops)}us")
        print(f"  -> reported-frame rate = {n_frames/el:.1f} /s")
    if ped_hist:
        print("  pedestal histogram (dBc -> count) of accepted frames:")
        for k in sorted(ped_hist):
            print(f"    {k:5d} dBc : {ped_hist[k]:5d}  {'#' * min(60, ped_hist[k])}")
    if stats_lines:
        print("  firmware STAT windows:")
        for s in stats_lines:
            print(f"    {s}")
    return 0


if __name__ == "__main__":
    sys.exit(main())