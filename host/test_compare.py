#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_compare.py -- 验证自己重写的解析器与原版结果完全一致

同一份 capture_20s.bin 分别走：
  我的：my_parser.find_packets / parse
  原版：live_view.PacketParser.feed / decode
逐包对比：头部全部字段 + 1024 个幅度，并单独突出任务书点名的 seq / peak_idx / peak_mag。
"""

import os

import numpy as np

import live_view
import my_parser

# 原版 decode 依赖在 check_deps() 里才导入的全局 np，这里给模块补上
live_view.np = np

N_BINS = 1024
HERE = os.path.dirname(os.path.abspath(__file__))
BIN_PATH = os.path.join(HERE, "capture_20s.bin")

# 我的字段名 -> 原版 decode 字段名
FIELD_MAP = {
    "seq": "seq",
    "n_bins": "n",
    "flags": "flags",
    "peak_idx": "pk_idx",
    "ped": "ped",
    "skirt": "skirt",
    "far": "far",
    "peak_mag": "pk_mag",
    "dc_mag": "dc",
    "hw_mag_sq": "hw_sq",
    "hw_idx": "hw_idx",
    "cap_us": "cap_us",
    "t_us": "t_us",
    "snr_db": "snr",
    "sfdr_dbc": "sfdr",
    "thd_dbc": "thd",
    "sinad_db": "sinad",
    "enob_x10": "enob",
    "floor_mag": "floor_mag",
    "n_peaks": "n_peaks",
    "cls": "cls",
}


def main():
    data = open(BIN_PATH, "rb").read()
    print("录像文件: %s (%d 字节)" % (os.path.basename(BIN_PATH), len(data)))

    # ---- 我的解析 ----
    my_packets, remaining = my_parser.find_packets(data, N_BINS)

    # ---- 原版解析（一次性喂入整个文件）----
    parser = live_view.PacketParser(N_BINS)
    raw_packets = parser.feed(data)
    orig_packets = [live_view.decode(p, N_BINS) for p in raw_packets]

    print("我的解析包数: %d（残留 %d 字节）" % (len(my_packets), len(remaining)))
    print("原版解析包数: %d（缓冲区残留 %d 字节）" % (len(orig_packets), len(parser.buf)))

    if len(my_packets) != len(orig_packets):
        print("结果: 失败 —— 包数不一致")
        return 1

    field_errors = 0
    mag_errors = 0

    for i, ((my_info, my_mags), orig) in enumerate(zip(my_packets, orig_packets)):
        # 头部全部字段
        for my_key, orig_key in FIELD_MAP.items():
            if my_info[my_key] != orig[orig_key]:
                field_errors += 1
                print("  第%d包字段不一致 %s: 我的=%r 原版=%r"
                      % (i, my_key, my_info[my_key], orig[orig_key]))
        # 1024 个幅度
        if list(my_mags) != list(orig["mags"]):
            mag_errors += 1
            print("  第%d包幅度数组不一致" % i)

    print("---- 字段不一致数: %d，幅度不一致包数: %d ----" % (field_errors, mag_errors))

    # 任务书点名的三项，抽样打印首包和末包
    print("---- 任务书点名指标 seq / peak_idx / peak_mag 对照 ----")
    for i in (0, len(my_packets) - 1):
        my_info = my_packets[i][0]
        orig = orig_packets[i]
        print("  第%3d包  seq: %d/%d  peak_idx: %d/%d  peak_mag: %d/%d"
              % (i,
                 my_info["seq"], orig["seq"],
                 my_info["peak_idx"], orig["pk_idx"],
                 my_info["peak_mag"], orig["pk_mag"]))

    if field_errors == 0 and mag_errors == 0:
        print("结果: 完全一致 —— 重写的 parse / find_packets 与原版对齐")
        return 0
    print("结果: 存在差异")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
