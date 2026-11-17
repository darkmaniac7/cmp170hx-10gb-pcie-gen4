#!/usr/bin/env python3
"""cmp_gen4_e1.py: CMP 170HX 10 GB (10de:2082) Gen4 prerequisite check / runtime E1 apply.

Default (no flag): READ-ONLY. Maps BAR0 read-only and reports the Gen4 prerequisites:
  MAGIC_D 0x820520 bit25 (and the other Gen4 bits), the E1 PHY-init registers
  (0x88CE4, 0x88CE0, CYA_0 0x8C2C0, PL_LINK_RATE 0x8C1C0, LINK_CONFIG_0 0x8C040,
  VSEC 0x88610), internal LnkCap 0x88084 / LnkCap2 0x880A4, and config LnkSta.

--apply: writes the SAME E1 sequence as the CmpGen4=1 driver block (read-modify-write,
  except the one-shot 0x88CE4=0x14), from an already-trained Gen3 link: the timing at
  which CMPGlitch validated E1, and the route tested on 10 GB cards. Use it when booting
  without CmpGen4=1 (the boot-time block is untested).
  Refuses unless: device 2082, nvidia bound, MAGIC_D bit25 clear, LnkSta = Gen3, all
  reads sane. Volatile; a power cycle restores everything. It never retrains the link.
Usage:  python3 -I cmp_gen4_e1.py 0000:01:00.0 [--apply]
"""
import mmap
import os
import pathlib
import struct
import subprocess
import sys

MAP = 0x824000
MAGIC_D, DSOV, EN_SW = 0x820520, 0x820084, 0x820040
R_CE4, R_CE0, R_CYA, R_PL, R_LC0, R_VSEC, R_MISC1 = (
    0x88CE4, 0x88CE0, 0x8C2C0, 0x8C1C0, 0x8C040, 0x88610, 0x8841C)
R_LNKCAP, R_LNKCAP2, R_LNKCTL2 = 0x88084, 0x880A4, 0x880A8
GEN4_BITS = 0x16480000           # MAGIC_D bits 19,22,25,26,28 (A100 has all clear)
CYA_CLR = (1 << 0) | (1 << 2) | (1 << 3) | (1 << 13) | (1 << 23)


def bad(v):
    return v == 0xFFFFFFFF or (v & 0xFFFF0000) == 0xBADF0000


def lnksta(bdf):
    out = subprocess.run(["setpci", "-s", bdf, "CAP_EXP+12.w"],
                         capture_output=True, text=True, check=True).stdout.strip()
    return int(out, 16)


def main():
    args = [a for a in sys.argv[1:]]
    apply = "--apply" in args
    args = [a for a in args if a != "--apply"]
    if len(args) != 1:
        raise SystemExit(__doc__)
    bdf = args[0].lower()
    p = pathlib.Path("/sys/bus/pci/devices") / bdf
    if (p / "vendor").read_text().strip() != "0x10de" or \
       (p / "device").read_text().strip() != "0x2082":
        raise SystemExit("Not the validated 10de:2082 device")
    if not (p / "driver").exists() or (p / "driver").resolve().name != "nvidia":
        raise SystemExit("Run with the nvidia driver bound and initialised")

    fd = os.open(p / "resource0", (os.O_RDWR if apply else os.O_RDONLY) | os.O_SYNC)
    try:
        prot = mmap.PROT_READ | (mmap.PROT_WRITE if apply else 0)
        with mmap.mmap(fd, MAP, flags=mmap.MAP_SHARED, prot=prot) as m:
            rd = lambda o: struct.unpack_from("<I", m, o)[0]

            def wr(o, v):
                struct.pack_into("<I", m, o, v & 0xFFFFFFFF)

            regs = [(DSOV, "DISABLE_SW_OVERRIDE"), (EN_SW, "EN_SW_OVERRIDE"),
                    (MAGIC_D, "MAGIC_D"), (R_CE4, "88CE4"), (R_CE0, "88CE0"),
                    (R_CYA, "CYA_0"), (R_PL, "PL_LINK_RATE"), (R_LC0, "LINK_CONFIG_0"),
                    (R_VSEC, "VSEC_HIER"), (R_MISC1, "PRIV_MISC_1"),
                    (R_LNKCAP, "LnkCap(int)"), (R_LNKCAP2, "LnkCap2(int)"),
                    (R_LNKCTL2, "LnkCtl2(int)")]
            vals = {o: rd(o) for o, _ in regs}
            for o, n in regs:
                print(f"{n:22s} 0x{o:06x} = 0x{vals[o]:08x}")
            if any(bad(v) for v in vals.values()):
                raise SystemExit("Unreadable/poisoned register; do not interpret or write")
            sta = lnksta(bdf)
            md = vals[MAGIC_D]
            print(f"config LnkSta = 0x{sta:04x} (Gen{sta & 15} x{(sta >> 4) & 63})")
            print(f"MAGIC_D bit25 GEN4_DIS = {(md >> 25) & 1}; other Gen4 bits set = "
                  f"0x{md & GEN4_BITS & ~(1 << 25):08x} (A100 parity needs 0)")
            print(f"LnkCap(int) max-speed nibble = {vals[R_LNKCAP] & 0xF}; "
                  f"LnkCap2(int) 16GT/s bit = {(vals[R_LNKCAP2] >> 4) & 1}")
            e1 = (vals[R_CE4] == 0x14 and (vals[R_CE0] & 0x3F) == 0x06 and
                  (vals[R_CYA] & CYA_CLR) == 0 and ((vals[R_PL] >> 16) & 0xF) == 4 and
                  (vals[R_LC0] & 0xC0000) == 0 and (vals[R_VSEC] & 0x1001) == 0x1001)
            print(f"E1 Gen4 PHY init present: {'YES' if e1 else 'NO'}")
            if not apply:
                return 0
            if (md >> 25) & 1:
                raise SystemExit("REFUSE: MAGIC_D bit25 set (boot with cmp_fuse_gen4=0 first)")
            if (sta & 15) != 3:
                raise SystemExit("REFUSE: link is not Gen3 (run cmp-gen3.sh first)")
            if e1:
                print("E1 already present; nothing written")
                return 0
            wr(R_CE4, 0x14)
            wr(R_CE0, (rd(R_CE0) & ~0x3F) | 0x06)
            wr(R_CYA, rd(R_CYA) & ~CYA_CLR)
            wr(R_PL, (rd(R_PL) & ~0x000F0000) | (4 << 16))
            wr(R_LC0, rd(R_LC0) & ~0x000C0000)
            wr(R_VSEC, rd(R_VSEC) | 0x1001)
            v = rd(R_MISC1)
            wr(R_MISC1, (v | (1 << 11) | (1 << 13)) & ~((1 << 12) | (1 << 14) | 0xC0000000))
            after = {o: rd(o) for o, _ in regs}
            for o, n in regs:
                if after[o] != vals[o]:
                    print(f"  wrote {n:16s} 0x{vals[o]:08x} -> 0x{after[o]:08x}")
            ok = (after[R_CE4] == 0x14 and (after[R_CE0] & 0x3F) == 0x06 and
                  (after[R_CYA] & CYA_CLR) == 0 and ((after[R_PL] >> 16) & 0xF) == 4 and
                  (after[R_LC0] & 0xC0000) == 0)
            print("E1 runtime apply:", "OK" if ok else "INCOMPLETE (a write did not stick): do not train Gen4")
            print(f"LnkSta now 0x{lnksta(bdf):04x} (E1 does not retrain; still expect Gen3)")
            return 0 if ok else 1
    finally:
        os.close(fd)


if __name__ == "__main__":
    raise SystemExit(main())
