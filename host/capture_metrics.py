#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# capture_metrics.py -- headless frame capture + objective metrics
#
# Used twice:
#   stage 0 (DDS regression)  : --fs 50e6    (DDS path, ddr_test.sdk/fft_demo)
#         NOTE: axis_mux_2to1 accepts only 1 beat / 2 clocks, so the DDS stream
#         is decimated 2:1 and its effective Fs is 50 MHz, not 100 MHz.
#         10 MHz then lands at bin 1638.4 (observed 1638). Using 100e6 would
#         wrongly display it at 20 MHz.
#   stage 2 (AD snapshot)     : --fs 32e6    (AD path, ad_snapshot CAP_MODE=2)
#         The AD source is a <=32 MSPS trickle, below the mux 50 MSPS limit,
#         so no AD sample is dropped and Fs stays 32 MHz (125 kHz -> bin 32).
#
# Only pyserial + numpy are required (no Qt, works on any PC).
# It parses the existing text protocol:
#     FRAME_START idx=N tlast=1
#     <idx>,<mag>
#     FRAME_END
# and also prints PEAK_HW / PEAK_CALC lines if the firmware emits them.
#
# Example:
#   python capture_metrics.py --port COM6 --fs 50e6  --frames 3 --save dds_baseline.npy
#   python capture_metrics.py --port COM6 --fs 32e6  --frames 5 --save ad_snapshot.npy --real
# -----------------------------------------------------------------------------
import argparse
import sys
import time
import numpy as np

try:
    import serial
except ImportError:
    print("pyserial is required:  pip install pyserial")
    sys.exit(1)


def collect_frames(port, baud, want_frames, timeout_s):
    """Read the text protocol until `want_frames` complete frames are seen.

    Anything that is not a frame/peak/data line is echoed with a '|' prefix, so
    it is immediately obvious when the board is printing something else
    (CAP_MODE=1 -> FFT_FRAME/FFT_STATS, DMA TIMEOUT, ...) instead of silence.
    """
    ser = serial.Serial(port, baud, timeout=0.2)
    frames = []
    buf = {}
    in_frame = False
    frame_hdr = ""
    t_end = time.time() + timeout_s
    seen = {"FFT_STATS": 0, "FFT_FRAME": 0, "DMA_ERR": 0, "other": 0}

    while len(frames) < want_frames and time.time() < t_end:
        raw = ser.readline()
        if not raw:
            continue
        line = raw.decode("ascii", errors="ignore").strip().replace("\r", "")
        if not line:
            continue

        if line.startswith("FRAME_START"):
            buf = {}
            frame_hdr = line
            in_frame = True
            continue

        if line.startswith("PEAK_HW") or line.startswith("PEAK_CALC"):
            print("   ", line)
            continue

        if line.startswith("FFT_STATS") or line.startswith("FFT_FRAME"):
            seen["FFT_STATS" if line.startswith("FFT_STATS") else "FFT_FRAME"] += 1
            print("  |", line)
            continue

        if "FRAME_END" in line:
            if in_frame and len(buf) > 0:
                n = max(buf.keys()) + 1
                arr = np.zeros(n, dtype=np.float64)
                for k, v in buf.items():
                    arr[k] = v
                frames.append((frame_hdr, arr))
            in_frame = False
            continue

        if "TIMEOUT" in line.upper() or "DMA" in line.upper():
            seen["DMA_ERR"] += 1
            if seen["DMA_ERR"] <= 5:
                print("  |", line)
            continue

        if in_frame and "," in line:
            try:
                i_s, v_s = line.split(",")[0], line.split(",")[1]
                i, v = int(i_s), int(v_s)
                buf[i] = v
            except ValueError:
                pass
            continue

        # anything else: echo it so the board's real output is visible
        seen["other"] += 1
        if seen["other"] <= 10:
            print("  |", line)

    ser.close()
    return frames, seen


def metrics(arr, fs, real_input=False, skip_dc=5, guard=2):
    n = len(arr)
    half = arr[: n // 2]
    freq = np.arange(n // 2) * fs / n

    dc = arr[0]
    # peak search skipping DC neighbourhood
    lo = min(skip_dc, len(half) - 1)
    pk_local = int(np.argmax(half[lo:])) + lo
    pk_mag = float(half[pk_local])
    pk_freq = float(freq[pk_local])

    # noise floor: median of bins away from DC and peak
    mask = np.ones(len(half), dtype=bool)
    mask[:skip_dc] = False
    mask[max(0, pk_local - guard): pk_local + guard + 1] = False
    floor = float(np.median(half[mask])) if np.any(mask) else 0.0
    floor = max(floor, 1e-9)
    snr = 20.0 * np.log10(max(pk_mag, 1e-9) / floor)

    # spectral pedestal (the "shoulder" around the carrier): mean magnitude of
    # the bins 4..24 away from the peak, on both sides, DC excluded.
    a = np.abs(arr)
    plo, phi = max(1, pk_local - 24), min(len(half), pk_local + 25)
    seg = np.concatenate([a[plo:pk_local], a[pk_local + 1:phi]])
    ped = float(np.mean(seg)) if seg.size else 0.0

    # far skirt: bins 40..120 away from the peak.  This is the discriminator
    # between the two branches: a rectangular-window tone leaks -46..-52 dBc
    # there, so any level well above that is a real pedestal of the signal chain.
    s1 = a[max(1, pk_local - 120): max(1, pk_local - 39)]
    s2 = a[min(len(half), pk_local + 40): min(len(half), pk_local + 121)]
    seg2 = np.concatenate([s1, s2])
    skirt = float(np.mean(seg2)) if seg2.size else 0.0

    # far skirt: bins 150..600 away.  This is the decisive discriminator:
    # a bin-centred tone (AD path) leaks nothing here, and a 0.2-bin-offset tone
    # (DDS path) leaks about -58..-70 dBc here, so any level far above that is a
    # real pedestal of the signal chain.
    f1 = a[max(1, pk_local - 600): max(1, pk_local - 149)]
    f2 = a[min(len(half), pk_local + 150): min(len(half), pk_local + 601)]
    seg3 = np.concatenate([f1, f2])
    skirt_far = float(np.mean(seg3)) if seg3.size else 0.0

    out = {
        "N": n,
        "nonzero": int(np.count_nonzero(arr)),
        "above_floor": int(np.count_nonzero(a[: len(half)] > 3.0 * floor)),
        "dc_bin": float(dc),
        "dc_dbc": 20.0 * np.log10(max(dc, 1e-9) / max(pk_mag, 1e-9)),
        "peak_bin": pk_local,
        "peak_freq_MHz": pk_freq / 1e6,
        "peak_mag": pk_mag,
        "floor_med": floor,
        "snr_dB": snr,
        "pedestal": ped,
        "pedestal_dbc": 20.0 * np.log10(max(ped, 1e-9) / max(pk_mag, 1e-9)),
        "skirt": skirt,
        "skirt_dbc": 20.0 * np.log10(max(skirt, 1e-9) / max(pk_mag, 1e-9)),
        "skirt_far": skirt_far,
        "skirt_far_dbc": 20.0 * np.log10(max(skirt_far, 1e-9) / max(pk_mag, 1e-9)),
    }

    if real_input:
        # For a real-valued input, bin k mirrors bin N-k; bin 0 has no mirror.
        # (The previous version compared arr[k] with arr[N-1-k], which mixed in
        #  the huge DC bin and reported a meaningless ~DC-sized number.)
        kmax = n // 2
        diffs = np.abs(arr[1:kmax] - arr[n - 1: n - kmax: -1])
        out["symmetry_err"] = float(diffs.max()) if diffs.size else 0.0
        out["mirror_bin"] = n - pk_local if 0 < pk_local < n else -1
        out["mirror_mag"] = float(arr[n - pk_local]) if 0 < pk_local < n else 0.0

    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM6")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--fs", type=float, default=32e6)
    ap.add_argument("--frames", type=int, default=3)
    ap.add_argument("--timeout", type=float, default=180.0)
    ap.add_argument("--save", default="")
    ap.add_argument("--real", action="store_true",
                    help="input is real-valued: also report FFT symmetry error")
    ap.add_argument("--compact", action="store_true",
                    help="one line per frame + a min/median/max summary; use "
                         "this with --frames 20 to characterise an intermittent "
                         "pedestal")
    args = ap.parse_args()

    print(f"port={args.port} baud={args.baud} fs={args.fs/1e6:.3f} MHz "
          f"frames={args.frames}")
    frames, seen = collect_frames(args.port, args.baud, args.frames, args.timeout)
    if not frames:
        print("ERROR: no complete FRAME_START..FRAME_END frame received.")
        if seen["FFT_STATS"] or seen["FFT_FRAME"]:
            print("DIAGNOSIS: the firmware is running CAP_MODE=1 (it prints")
            print("           FFT_FRAME/FFT_STATS, never FRAME_START).")
            print("           -> set '#define CAP_MODE 2' in the SDK project's")
            print("              src/sdk_ad_snapshot_main.c, rebuild and re-download.")
            print("           The FFT_STATS lines above already show dc/peak_bin/")
            print("           peak_mag, so they are usable as-is.")
        elif seen["DMA_ERR"]:
            print("DIAGNOSIS: the firmware is reporting DMA errors, so no frame")
            print("           ever completes. Check the AD capture / FIFO state.")
        elif seen["other"]:
            print("DIAGNOSIS: the board is printing unexpected lines (shown above).")
        else:
            print("DIAGNOSIS: the board printed nothing at all - check that the")
            print("           bitstream is loaded, the COM port is not held by")
            print("           another program (XCOM!), and the firmware is running.")
        return 1

    ms = []
    for idx, (hdr, arr) in enumerate(frames):
        m = metrics(arr, args.fs, real_input=args.real)
        ms.append(m)
        if args.compact:
            print(f"f{idx:3d} {hdr.split()[1] if len(hdr.split())>1 else '':10s} "
                  f"dc={m['dc_dbc']:6.1f}  ped={m['pedestal_dbc']:6.1f}  "
                  f"skirt={m['skirt_dbc']:6.1f}  far={m['skirt_far_dbc']:6.1f} dBc  "
                  f"tone={m['peak_mag']:6.0f}  bin={m['peak_bin']}")
            continue
        print(f"--- frame {idx}: {hdr}")
        print(f"    N={m['N']} nonzero={m['nonzero']} above_floor(>1)={m['above_floor']}")
        print(f"    DC bin={m['dc_bin']:.0f}  ({m['dc_dbc']:.1f} dBc)")
        print(f"    peak bin={m['peak_bin']} = {m['peak_freq_MHz']:.6f} MHz "
              f"mag={m['peak_mag']:.0f}")
        print(f"    floor(median)={m['floor_med']:.1f}  peak/floor={m['snr_dB']:.1f} dB")
        print(f"    pedestal(+-4..24 bins)={m['pedestal']:.1f}  "
              f"({m['pedestal_dbc']:.1f} dBc)")
        print(f"    skirt(+-40..120 bins)={m['skirt']:.1f}  "
              f"({m['skirt_dbc']:.1f} dBc)")
        print(f"    skirt_far(+-150..600)={m['skirt_far']:.1f}  "
              f"({m['skirt_far_dbc']:.1f} dBc)   <-- key discriminator")
        if args.real:
            print(f"    symmetry_err={m['symmetry_err']:.0f} "
                  f"(max |x[k]-x[N-k]|, k=1..N/2-1; should be ~0)")
            if m.get("mirror_bin", -1) > 0:
                print(f"    mirror bin {m['mirror_bin']} mag={m['mirror_mag']:.0f} "
                      f"(must equal peak mag for a real input)")

    if args.save:
        np.save(args.save, frames[-1][1])
        print(f"saved last frame -> {args.save}")

    if len(ms) > 1:
        print()
        print(f"--- summary over {len(ms)} frames (dBc) ---")
        for key, name in (("pedestal_dbc", "pedestal(+-4..24) "),
                          ("skirt_dbc",    "skirt(+-40..120)  "),
                          ("skirt_far_dbc","skirt_far(+-150..600)"),
                          ("dc_dbc",       "DC               ")):
            v = np.array([x[key] for x in ms])
            print(f"  {name}: min={v.min():7.1f}  median={np.median(v):7.1f}  "
                  f"max={v.max():7.1f}  spread={v.max()-v.min():5.1f} dB")
        good = [x for x in ms if x["pedestal_dbc"] < -40.0]
        print(f"  frames with pedestal < -40 dBc: {len(good)}/{len(ms)}")
        print("  interpretation: a LARGE spread means an intermittent disturbance;")
        print("                  a tight spread means a deterministic mechanism.")
    return 0


if __name__ == "__main__":
    sys.exit(main())