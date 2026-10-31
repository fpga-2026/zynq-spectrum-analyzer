#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# live_view.py -- real-time viewer for the stage-3 binary stream
#
# Protocol (little endian, 36 + 2*NBINS + 2 bytes):
#   0  2  sync 0x55 0xAA     2  seq      4  n_bins    6  flags
#   8  2  peak_idx          10  ped      12 skirt    14 far      (i16 dBc)
#  16  4  peak_mag          20  dc_mag   24 hw_peak_mag_sq
#  28  2  hw_peak_idx       30  cap_us   32 t_us
#  36  2*NBINS  magnitudes (u16)
#   +=2  checksum = sum of the preceding bytes, low 16 bits
#
# flags: bit0 quality pass, bit1 peak valid, bit2 xcheck ok, bit3 channel (1=DDS)
#
#   python live_view.py --port COM6                 # GUI, 230400, AD path
#   python live_view.py --port COM6 --headless      # text only (link test)
#   python live_view.py --port COM6 --dds           # DDS path (Fs = 100 MHz)
# -----------------------------------------------------------------------------
import argparse
import struct
import sys
import threading
import time

SYNC = b"\x55\xaa"

CLS_NAMES = {0: "UNK", 1: "CW", 2: "MULTI", 3: "WIDE", 4: "CW+NOISE"}
HDR = 52
HDR_FMT = "<HHHHhhhIIIHHIhhhhhHHH"  # from offset 2, 50 bytes (header 52)


def check_deps(gui, need_serial=True):
    global np, serial, pg, QtWidgets
    try:
        import numpy as np
    except ImportError:
        print("numpy required:  pip install numpy")
        sys.exit(1)
    if need_serial:
        try:
            import serial
        except ImportError:
            print("pyserial required:  pip install pyserial")
            sys.exit(1)
    if gui:
        try:
            import pyqtgraph as pg
            from pyqtgraph.Qt import QtWidgets
        except ImportError:
            print("pyqtgraph required for the GUI:  pip install pyqtgraph")
            print("(or run with --headless)")
            sys.exit(1)


class PacketParser:
    """Byte-stream -> packets, with sync search, length check and checksum."""

    def __init__(self, n_bins):
        self.n_bins = n_bins
        self.total = HDR + 2 * n_bins + 2
        self.buf = bytearray()
        self.cs_err = 0
        self.resync = 0

    def feed(self, data):
        self.buf += data
        out = []
        while True:
            i = self.buf.find(SYNC)
            if i < 0:
                keep = 1 if self.buf else 0
                if len(self.buf) > keep:
                    del self.buf[: len(self.buf) - keep]
                    self.resync += 1
                break
            if i > 0:
                del self.buf[:i]
                self.resync += 1
            if len(self.buf) < HDR:
                break
            n_bins = struct.unpack_from("<H", self.buf, 4)[0]
            if n_bins != self.n_bins:
                del self.buf[:2]            # false sync -> step over it
                self.resync += 1
                continue
            if len(self.buf) < self.total:
                break
            pkt = bytes(self.buf[: self.total])
            del self.buf[: self.total]
            cs = struct.unpack_from("<H", pkt, self.total - 2)[0]
            if cs != (sum(pkt[: self.total - 2]) & 0xFFFF):
                self.cs_err += 1
                continue
            out.append(pkt)
        return out


def decode(pkt, n_bins):
    (seq, n, flags, pk_idx, ped, skirt, far, pk_mag, dc, hw_sq, hw_idx,
     cap_us, t_us, snr, sfdr, thd, sinad, enob, floor_mag,
     n_peaks, cls) = struct.unpack_from(HDR_FMT, pkt, 2)
    mags = np.frombuffer(pkt, dtype="<u2", count=n_bins, offset=HDR)
    return dict(seq=seq, n=n, flags=flags, pk_idx=pk_idx, ped=ped,
                skirt=skirt, far=far, pk_mag=pk_mag, dc=dc, hw_sq=hw_sq,
                hw_idx=hw_idx, cap_us=cap_us, t_us=t_us, snr=snr, sfdr=sfdr,
                thd=thd, sinad=sinad, enob=enob, floor_mag=floor_mag,
                n_peaks=n_peaks, cls=cls, mags=mags)


_REC = None          # --record 打开的文件句柄（收到什么就写什么）


class FileSource:
    """--replay 用：接口和 serial.Serial 一样（read / in_waiting / write / close），
    但数据来自一个录好的原始字节文件，读到末尾自动从头再来。"""

    def __init__(self, path, chunk=4096):
        self.f = io.open(path, "rb") if False else open(path, "rb")
        self.chunk = chunk
        self.eof = False

    @property
    def in_waiting(self):
        return self.chunk

    def read(self, n=1):
        data = self.f.read(max(1, n))
        if not data:
            self.eof = True
            time.sleep(0.05)
            self.f.seek(0)          # 循环回放，方便反复看同一段数据
            return b""
        return data

    def write(self, b):
        return len(b)               # 回放模式下发不了通道切换命令，直接忽略

    def flush(self):
        pass

    def close(self):
        self.f.close()


def headless(ser, parser, n_bins, fs, duration, raw_dump=0):
    t0 = time.time()
    n_pkt = 0
    acc = []
    n_bytes = 0
    last = t0
    textbuf = bytearray()
    raw = bytearray()
    print(f"headless: {duration:.0f} s, expect n_bins={n_bins}, fs={fs/1e6:.1f} MHz")
    print("  (lines starting with '|' are raw text from the board)")
    while time.time() - t0 < duration:
        data = ser.read(max(1, ser.in_waiting))
        if not data:
            continue
        n_bytes += len(data)
        if _REC is not None:
            _REC.write(data)
        if len(raw) < 8192:
            raw += data[: 8192 - len(raw)]

        for pkt in parser.feed(data):
            p = decode(pkt, n_bins)
            n_pkt += 1
            acc.append(p)
            now = time.time()
            if n_pkt % 16 == 1 or now - last > 1.0:
                last = now
                bin_hz = fs / 8192.0
                print(f"  seq={p['seq']:5d} flags=0x{p['flags']:04x} "
                      f"peak={p['pk_idx']:4d}({p['pk_idx']*bin_hz/1e3:8.3f}kHz) "
                      f"mag={p['pk_mag']:5d} dc={p['dc']:5d} "
                      f"ped={p['ped']:4d} skirt={p['skirt']:4d} far={p['far']:4d} "
                      f"hw_idx={p['hw_idx']:4d} cap={p['cap_us']}us")
                print(f"        P/F={p['snr']}dB SFDR={p['sfdr']}dBc THD={p['thd']}dBc "
                      f"SINAD={p['sinad']}dB ENOB@in={p['enob']/10:.1f}bit "
                      f"floor={p['floor_mag']} peaks={p['n_peaks']}")

        # echo printable text (banner, DMA TIMEOUT, ...) so nothing stays hidden
        textbuf += data
        while True:
            i = textbuf.find(b"\n")
            if i < 0:
                break
            line = bytes(textbuf[:i]).rstrip(b"\r")
            del textbuf[: i + 1]
            if line and all(32 <= c < 127 for c in line):
                print(f"  | {line.decode('ascii')}")
        if len(textbuf) > 512:
            del textbuf[:-128]

    el = time.time() - t0
    print(f"--- {n_pkt} packets in {el:.1f} s = {n_pkt/el:.1f} fps | "
          f"checksum errors={parser.cs_err} | resyncs={parser.resync} | "
          f"bytes={n_bytes} ({n_bytes/el:.0f} B/s)")
    if acc:
        def rng(key):
            v = [a[key] for a in acc]
            return min(v), max(v)
        pm, pM = rng("ped"); sm, sM = rng("skirt"); fm, fM = rng("far")
        mm, mM = rng("pk_mag"); nm, nM = rng("sinad"); em, eM = rng("enob")
        print(f"--- summary over {len(acc)} packets")
        print(f"    peak bin={acc[-1]['pk_idx']}  mag {mm}..{mM}")
        print(f"    ped {pm}..{pM} dBc   skirt {sm}..{sM} dBc   far {fm}..{fM} dBc")
        print(f"    SINAD {nm}..{nM} dB   ENOB@in {em/10:.1f}..{eM/10:.1f} bit   "
              f"SFDR {min(a['sfdr'] for a in acc)}..{max(a['sfdr'] for a in acc)} dBc   "
              f"THD {min(a['thd'] for a in acc)}..{max(a['thd'] for a in acc)} dBc")
    if n_pkt == 0:
        print("  no packet parsed.  230400 Bd should give ~23000 B/s; a much")
        print("  lower byte rate means the board is not streaming at all.")
        show = min(len(raw), 96 if raw_dump <= 0 else raw_dump)
        if show:
            print(f"  first {show} bytes received:")
            for k in range(0, show, 16):
                chunk = raw[k:k + 16]
                print("   " + " ".join(f"{b:02x}" for b in chunk) +
                      "   " + "".join(chr(b) if 32 <= b < 127 else "." for b in chunk))


def gui(ser, parser, n_bins, fs, hold):
    from pyqtgraph.Qt import QtCore
    app = QtWidgets.QApplication(sys.argv)
    win = pg.GraphicsLayoutWidget(title="AD snapshot -- live spectrum")
    win.resize(1100, 620)
    win.show()

    plot = win.addPlot(row=0, col=0)
    plot.setLabel("bottom", "frequency", units="Hz")
    plot.setLabel("left", "|X| (FFT magnitude)")
    plot.showGrid(x=True, y=True, alpha=0.25)
    plot.setLogMode(x=False, y=False)

    bin_hz = fs / 8192.0
    x = np.arange(n_bins) * bin_hz
    curve = plot.plot(x, np.zeros(n_bins), pen=pg.mkPen("#4fc3f7", width=1))
    if hold:
        curve_h = plot.plot(x, np.zeros(n_bins),
                            pen=pg.mkPen("#ff8a65", width=1,
                                         style=QtCore.Qt.DashLine))
    else:
        curve_h = None

    label = pg.TextItem("waiting for the first packet ...", color=(230, 230, 230))
    label.setPos(0.01, 0.98)
    label.setParentItem(plot.getViewBox())
    label.setAnchor((0, 1))

    state = {"t0": time.time(), "n": 0, "fps": 0.0, "last": time.time(),
             "peak": np.zeros(n_bins, dtype=np.float64), "shown": 0,
             "fs": fs, "x": np.arange(n_bins) * (fs / 8192.0)}

    def update():
        data = ser.read(max(1, ser.in_waiting))
        if data:
            if _REC is not None:
                _REC.write(data)
            for pkt in parser.feed(data):
                p = decode(pkt, n_bins)
                m = p["mags"].astype(np.float64)
                # the axis scale follows the channel reported in the packet
                ch_fs = 100e6 if (p["flags"] & 8) else 32e6
                if ch_fs != state["fs"]:
                    state["fs"] = ch_fs
                    state["x"] = np.arange(n_bins) * (ch_fs / 8192.0)
                    state["peak"] = np.zeros(n_bins, dtype=np.float64)
                    if curve_h is not None:
                        curve_h.setData(state["x"], state["peak"])
                curve.setData(state["x"], m)
                if curve_h is not None:
                    state["peak"] = np.maximum(state["peak"], m)
                    curve_h.setData(state["x"], state["peak"])
                state["n"] += 1
                state["shown"] = p
        now = time.time()
        if now - state["last"] > 0.5:
            state["fps"] = state["n"] / (now - state["t0"])
        p = state["shown"]
        if p:
            bin_hz = state["fs"] / 8192.0
            ch = "DDS" if (p["flags"] & 8) else "AD"
            xc = "ok" if (p["flags"] & 4) else "ERR"
            q = "pass" if (p["flags"] & 1) else "fail"
            label.setText(
                f"{ch}  seq={p['seq']}  fps={state['fps']:.1f}  "
                f"peak bin={p['pk_idx']} ({p['pk_idx']*bin_hz/1e3:.3f} kHz) "
                f"mag={p['pk_mag']}  dc={p['dc']}\n"
                f"ped={p['ped']} dBc  skirt={p['skirt']} dBc  far={p['far']} dBc  "
                f"quality={q}  xcheck={xc}  cap={p['cap_us']}us\n"
                f"P/F={p['snr']} dB  SFDR={p['sfdr']} dBc  THD={p['thd']} dBc  "
                f"SINAD={p['sinad']} dB  ENOB@in={p['enob']/10:.1f} bit  "
                f"floor={p['floor_mag']}  peaks={p['n_peaks']}  "
                f"class={CLS_NAMES.get(p['cls'], '?')}\n"
                f"checksum errors={parser.cs_err}  resyncs={parser.resync}   "
                f"[press 'a' AD / 'd' DDS to switch channel]")

    # live channel switching: the firmware polls the same UART for 'A'/'D'
    from pyqtgraph.Qt import QtGui
    def ask_dds():
        ser.write(b"D")
        print("-> requested DDS reference path")
    def ask_ad():
        ser.write(b"A")
        print("-> requested AD analog path")
    QtWidgets.QShortcut(QtGui.QKeySequence("d"), win).activated.connect(ask_dds)
    QtWidgets.QShortcut(QtGui.QKeySequence("a"), win).activated.connect(ask_ad)

    # typing in the console that launched this script always works (no window
    # focus needed): type d <Enter> for DDS, a <Enter> for AD, q <Enter> to quit
    def stdin_loop():
        for line in sys.stdin:
            c = line.strip().lower()
            if c == "d":
                ask_dds()
            elif c == "a":
                ask_ad()
            elif c in ("q", "quit", "exit"):
                import os
                os._exit(0)
    threading.Thread(target=stdin_loop, daemon=True).start()
    print("switch channel: click the plot then press d/a, OR type d/a here + Enter")

    timer = pg.QtCore.QTimer()
    timer.timeout.connect(update)
    timer.start(10)

    if (sys.flags.interactive != 1) or not hasattr(pg.QtCore, "PYQT_VERSION"):
        QtWidgets.QApplication.instance().exec_()


def selftest(n_bins=1024):
    """Build a packet exactly like the firmware does and parse it back."""
    print(f"selftest: n_bins={n_bins}")
    mags = (np.arange(n_bins) * 3 + 7).astype("<u2")     # known ramp
    hdr = struct.pack("<2s" + HDR_FMT[1:],
                      SYNC, 4321, n_bins, 0x0007, 32, -46, -58, -70,
                      6001, 229, 36012001, 32, 361, 123456789,
                      70, -68, -75, 71, 115, 3, 1, 1)
    body = hdr + mags.tobytes()
    pkt = body + struct.pack("<H", sum(body) & 0xFFFF)
    print(f"  packet length = {len(pkt)} (expected {HDR + 2*n_bins + 2})")

    parser = PacketParser(n_bins)
    # feed in three wasteful chunks, with junk in front, to exercise resync
    junk = b"\x00\x55\xaa\x13\x37garbage-"
    out = []
    data = junk + pkt + b"\x55" + pkt
    for i in range(0, len(data), 97):
        out += parser.feed(data[i:i + 97])
    print(f"  parsed packets = {len(out)} (expected 2), "
          f"cs_err={parser.cs_err}, resync={parser.resync}")
    if len(out) != 2:
        print("  RESULT: FAIL (packet framing)")
        return 1

    p = decode(out[0], n_bins)
    ok = (p["seq"] == 4321 and p["n"] == n_bins and p["flags"] == 0x0007
          and p["pk_idx"] == 32 and p["ped"] == -46 and p["skirt"] == -58
          and p["far"] == -70 and p["pk_mag"] == 6001 and p["dc"] == 229
          and p["hw_sq"] == 36012001 and p["hw_idx"] == 32
          and p["cap_us"] == 361 and p["t_us"] == 123456789
          and p["snr"] == 70 and p["sfdr"] == -68 and p["thd"] == -75
          and p["sinad"] == 71 and p["enob"] == 115 and p["floor_mag"] == 3
          and p["n_peaks"] == 1 and p["cls"] == 1
          and np.array_equal(p["mags"], mags))
    print(f"  header round-trip: {'OK' if ok else 'MISMATCH'}")
    print(f"  sample mag[0..5] = {p['mags'][:6].tolist()}")
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM6")
    ap.add_argument("--baud", type=int, default=230400)
    ap.add_argument("--bins", type=int, default=1024)
    ap.add_argument("--fs", type=float, default=32e6,
                    help="sample rate of the active path (32e6 = AD, 100e6 = DDS)")
    ap.add_argument("--dds", action="store_true", help="same as --fs 100e6")
    ap.add_argument("--headless", action="store_true", help="no GUI, print headers")
    ap.add_argument("--duration", type=float, default=10.0)
    ap.add_argument("--hold", action="store_true", help="draw a peak-hold trace")
    ap.add_argument("--selftest", action="store_true", help="offline protocol self-test")
    ap.add_argument("--raw", type=int, default=0, help="hex-dump this many bytes if no packet")
    ap.add_argument("--switch", default="", help="send a channel command and exit: d or a")
    ap.add_argument("--record", default="", help="save every received byte to this file")
    ap.add_argument("--replay", default="", help="replay a recorded file instead of the serial port")
    args = ap.parse_args()

    if args.selftest:
        check_deps(False, need_serial=False)
        return selftest(args.bins)

    if args.dds:
        args.fs = 100e6
    check_deps(not args.headless, need_serial=not args.replay)

    global _REC
    if args.record:
        _REC = open(args.record, "wb")
        print(f"recording raw bytes to {args.record}")

    if args.replay:
        ser = FileSource(args.replay)
        print(f"replaying {args.replay} (no serial port opened)")
    else:
        ser = serial.Serial(args.port, args.baud, timeout=0.05)

    if args.switch:
        cmd = b"D" if args.switch.strip().lower().startswith("d") else b"A"
        ser.write(cmd)
        ser.flush()
        time.sleep(0.3)
        name = "DDS (Fs=100MHz)" if cmd == b"D" else "AD (Fs=32MHz)"
        print("sent %r -> board switches to %s" % (cmd, name))
        ser.close()
        return 0

    parser = PacketParser(args.bins)
    if args.replay:
        print(f"replay mode, n_bins={args.bins}, fs={args.fs/1e6:.1f} MHz")
    else:
        print(f"opened {args.port} @ {args.baud}, n_bins={args.bins}, "
          f"fs={args.fs/1e6:.1f} MHz, bin={args.fs/8192/1e3:.4f} kHz")

    try:
        if args.headless:
            headless(ser, parser, args.bins, args.fs, args.duration, args.raw)
        else:
            gui(ser, parser, args.bins, args.fs, args.hold)
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        ser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())


