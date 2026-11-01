#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
my_parser.py -- 自己重写的二进制包解析器（11.1 任务）

只依赖 Python 标准库 struct，不依赖 numpy。
对外提供两个函数：
  parse(pkt)        : 把"一整包"2102 字节解成 (字段字典, 1024 个幅度)
  find_packets(buf) : 从一段可能含粘包/断包/文本垃圾的字节流里切出所有完整包

协议要点（详见《通信协议说明》）：
  整包 = 52 字节头 + 1024*2 字节载荷 + 2 字节校验和 = 2102 字节，全部小端
  同步字 0x55 0xAA；载荷里也可能偶然出现同步字，所以必须用校验和兜底
"""

import struct

# ---- 常量 ----------------------------------------------------------------
SYNC = b"\x55\xaa"          # 帧头同步字（0x55 在前）
HEADER_LEN = 52             # 头部长度
DEFAULT_BINS = 1024         # 每包 bin 数（固定）

# 头部从偏移 2 开始的 21 个字段格式（共 50 字节）
# 大写 H/I = 无符号 u16/u32，小写 h = 有符号 s16
HEADER_FORMAT = "<HHHHhhhIIIHHIhhhhhHHH"

# 与 HEADER_FORMAT 一一对应的字段名（用完整名字，方便阅读和讲解）
HEADER_FIELDS = (
    "seq", "n_bins", "flags", "peak_idx",       # 序号、bin数、状态位、峰值bin
    "ped", "skirt", "far",                      # 三个有符号杂散 dBc（负数）
    "peak_mag", "dc_mag", "hw_mag_sq",          # 峰值/直流/硬件幅度
    "hw_idx", "cap_us",                         # 硬件峰值bin、采集耗时
    "t_us",                                     # 帧周期
    "snr_db", "sfdr_dbc", "thd_dbc",            # 信噪比、无杂散动态范围、谐波
    "sinad_db", "enob_x10",                     # 信纳比、有效位数*10
    "floor_mag", "n_peaks", "cls",              # 谱底、峰个数、分类
)


def packet_length(n_bins=DEFAULT_BINS):
    """整包字节数 = 头 + 载荷 + 校验和。"""
    return HEADER_LEN + 2 * n_bins + 2


def checksum_of(data):
    """前 2100 字节逐字节累加，取低 16 位。"""
    return sum(data) & 0xFFFF


def parse(pkt, n_bins=DEFAULT_BINS):
    """
    解析一整包。
    返回 (info, mags)：
      info : 字段字典，额外含 cs_ok（校验和是否正确）
      mags : 1024 个 u16 幅度组成的元组
    调用前一般已确认 pkt 长度 >= packet_length()。
    """
    # 1) 确认同步字
    if pkt[:2] != SYNC:
        raise ValueError("不是以同步字 0x55AA 开头")

    # 2) 解 52 字节头（从偏移 2 开始解 21 个字段）
    values = struct.unpack_from(HEADER_FORMAT, pkt, 2)
    info = dict(zip(HEADER_FIELDS, values))

    # 3) 解载荷：偏移 52 开始的 n_bins 个 u16
    mags = struct.unpack_from("<%dH" % n_bins, pkt, HEADER_LEN)

    # 4) 校验和：自己算前 2100 字节，和包尾 2 字节对比
    payload_end = HEADER_LEN + 2 * n_bins          # 2100
    got_checksum = struct.unpack_from("<H", pkt, payload_end)[0]
    info["cs_ok"] = (checksum_of(pkt[:payload_end]) == got_checksum)

    # 5) 额外给一个换算好的有效位数（bit），原始 enob_x10 仍保留
    info["enob_bit"] = info["enob_x10"] / 10.0

    return info, mags


def find_packets(buf, n_bins=DEFAULT_BINS):
    """
    从字节流 buf 切出所有完整、校验通过的包。
    返回 (packets, remaining)：
      packets   : 每项是 parse() 给出的 (info, mags)
      remaining : 还凑不齐一整包、需要留到下次继续解析的字节
    能自动跳过开头的 ASCII 文本和载荷里的假同步字。
    """
    total = packet_length(n_bins)
    buf = bytearray(buf)          # 复制一份，避免改动调用方的数据
    packets = []

    while True:
        # 找下一个同步字
        i = buf.find(SYNC)
        if i < 0:
            # 没有同步字：最多保留最后 1 个字节（万一是半个帧头 0x55）
            return packets, bytes(buf[-1:]) if buf else b""

        # 同步字之后的数据不够一整包，先整段保留，等新数据进来
        if len(buf) - i < total:
            return packets, bytes(buf[i:])

        # 先读同步字后偏移 4 处的 n_bins，区分"假同步"和"真正的候选帧"
        candidate_n = struct.unpack_from("<H", buf, i + 4)[0]
        if candidate_n != n_bins:
            # 载荷里偶然出现的假同步字：只跳过这 2 字节，继续往后找
            del buf[:i + 2]
            continue

        # n_bins 匹配，切出候选整包并解析
        pkt = bytes(buf[i:i + total])
        info, mags = parse(pkt, n_bins)

        if info["cs_ok"]:
            # 校验通过：真包，收下并跳过整包
            packets.append((info, mags))
            del buf[:i + total]
        else:
            # 一整帧校验失败（如录制开头被截断的帧）：数据已损坏，
            # 丢弃整个候选包，不在坏包内部继续找，避免错位对齐出巧合的"假好包"
            del buf[:i + total]
