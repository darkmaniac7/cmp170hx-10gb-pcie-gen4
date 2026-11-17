# CMP 170HX 10 GB: PCIe Gen3 and Gen4 at x4

Driver patches and scripts that train the PCIe link of an NVIDIA CMP 170HX 10 GB card (`10de:2082`) to Gen3
(8 GT/s) or Gen4 (16 GT/s) at x4. They build on [cmpunlocker](https://github.com/amoghmunikote/cmpunlocker) and
NVIDIA open-gpu-kernel-modules 615.71.09.

Measured on two cards: pinned host-to-device / device-to-host copies went from 1.67 / 1.71 GB/s at Gen2 x4 to
3.24 / 3.38 GB/s at Gen3 x4 and 6.31-6.37 / 6.76 GB/s at Gen4 x4.

Background, history and community reports:

- https://cmp.wiki/wiki/PCIe_Gen4_on_the_10_GB_card
- https://cmp.wiki/wiki/PCIe_Gen3_on_the_10_GB_card

## What it does

- Clears the two Gen3-disable fuses (`OPT_DISABLE_GEN3_SPEED` `0x820250`, `OPT_PCIE_BOOT_GEN3_DIS` `0x820580`) and
  bit 25 (`GEN4_SPEED_DISABLED`) of `PCIE_MAGIC_BITS_D` (`0x820520`) through the fuse software override at driver
  probe. These are register writes that last until the next GPU reset, not fuse burns.
- Sets the card's internal Gen3 link configuration during GSP boot.
- Trains Gen3 through RM (`SET_PCIE_SPEED` 1, 2, 3), then Gen4 through one PCIe config-space retrain after a runtime
  PHY init.

## What it does not do

- It burns nothing. The only permanent change it needs is the 10 GB RIR gate burn (`DISABLE_SW_OVERRIDE`) that
  10 GB unlock users already have. Everything else is volatile: a power cycle returns the card to its boot link, and
  the link has to be trained again after every boot.
- It does not widen the link. x4 stays x4; x16 needs the PCIe capacitor mod.
- It does not change SMs, memory, ECC or NVLink.
- It does not make `nvidia-smi` report Gen4 ([see below](#nvidia-smi-still-says-gen3)).
- It does not work inside a passthrough VM: the retrain writes the host root port's config space.
- It is not tested on 8 GB cards (`10de:20c2`). The GSP blocks and the scripts act only on `2082`, but the probe
  fuse override also matches `20c2`. On a host with both kinds of card, limit the override to one 10 GB card with
  `cmp_fuse_bdf`.

## Requirements

- A 10 GB card with the RIR gate burn done: `DISABLE_SW_OVERRIDE` (`0x820084`) reads 0 (`cmp_gen4_e1.py` prints it).
- cmpunlocker installed and working on nvidia-open 615.71.09.
- For Gen4, a port that does 16 GT/s at the other end. Behind a PCIe switch, both sides of the switch must.
- Bare metal.
- Console or power access. A failed attempt can need a power cycle.
- A pinned-memory copy test for the bandwidth gate.

## Tested setup

| | |
|---|---|
| Cards | two CMP 170HX 10 GB (`10de:2082`), RIR gate burned, 122 and 108 SMs, 40 GiB each |
| Host | desktop board, bare metal, UEFI, Secure Boot off; each card on its own CPU root port (PCIe 5.0 x8 capable), no switch |
| Link width | x4 (no capacitor mod) |
| OS | Ubuntu 24.04, kernel 6.8.0-149-generic |
| Driver | nvidia-open 615.71.09, cmpunlocker 10gb profile (commit `2c7e2ec`), CUDA 12.8 |
| Extra patch | the in-memory VBIOS override patch `615-vbios-override-per-gpu.patch` from [Panchovix/nvidia-linux-vbios-vix-loader](https://github.com/Panchovix/nvidia-linux-vbios-vix-loader), used for an unrelated V/F offset change |

The VBIOS override patch changes none of the files the Gen4 patch changes, but every Gen4 run here had it in the
build. Gen4 without it has not been tested. It applies on top of this stack with offsets only.

## Results

Pinned 256 MiB copies, 10 runs per measurement, GB/s.

| | Gen2 x4 (cmpunlocker) | Gen3 x4 | Gen4 x4 |
|---|---|---|---|
| Host to device | 1.67 | 3.24 | 6.31-6.37 |
| Device to host | 1.71 | 3.38 | 6.76 |
| `LnkSta`, card and root port | 5 GT/s x4 | 8 GT/s x4 | 16 GT/s x4, equalization complete |
| 30-minute soak, both cards at once | | PASS | PASS |

Both soaks ran gpu-burn and continuous pinned copies on both cards at the same time and sampled `LnkSta` at both
ends every 15 s:

- Gen3: 120 of 120 samples at Gen3 x4 on each card, 0 AER, 0 Xid, gpu-burn 0 errors, 3.24 / 3.38 GB/s per card
  under load.
- Gen4: 120 of 120 samples at Gen4 x4 on each card, 0 AER (correctable 0), 0 Xid, gpu-burn 0 errors,
  6.31 / 6.76 GB/s per card under load (minimum 6.30), still 16 GT/s at the end, at most 56 C. A 30-minute soak of
  the first card alone also passed at 6.37 / 6.76 GB/s (minimum 6.27).

Gen4 x4 raw is 7.88 GB/s per direction, so the copies ran at about 81-86 % of raw, as Gen3 did on the same cards.
Each card trained Gen3 and Gen4 on its first attempt.

## Contents

```
patches/
  series                              apply order of the four patches
  README.md                           what each patch does
  pcie-gen2-scaffolding-only.patch    cmpunlocker's Gen2 booter code in kernel_gsp.c, kept for Gen3
  pcie-gen3-gsp.patch                 Gen3 link setup at GSP boot (CmpGen3=1)
  pcie-gen3-fuse-override.patch       probe-time fuse override (cmp_fuse_gen3, cmp_fuse_bdf)
  pcie-gen4-g4.patch                  Gen4 additions (cmp_fuse_gen4, optional CmpGen4)
tools/
  set_pcie_speed.c                    RM link-speed trainer, installed as cmp-pcie-speed
  cmp-gen3.sh                         Gen1 -> Gen2 -> Gen3 training through RM, one pass
  cmp_gen4_e1.py                      Gen4 prerequisite check (read-only) and runtime PHY init (--apply)
  cmp-gen4.sh                         one config-space retrain from Gen3 to Gen4, with checks
```

## Base and patch order

- NVIDIA open-gpu-kernel-modules **615.71.09** (GitHub tag tarball, sha256
  `caf48cda7d5fe7374d1d24ca4a90efb4dc783eefabfad5fa4b64fdc24213b62a`).
- cmpunlocker at commit **`2c7e2ecd7944e791fec040d2680036beb4a9327b`** (master, "Add 615.71.10", 2026-10-27).

The order is cmpunlocker's `driver/build.sh` `PATCH_ORDER` at that commit, with `pcie-gen2.patch` and
`pcie-gen2-probe-retrain.patch` replaced by the four patches here, in the same slot:

```
sec2-postbl-plm-ss-cfg.patch        cmpunlocker
booter-verify.patch                 cmpunlocker
late-pma.patch                      cmpunlocker
bar0-pramin-clamp.patch             cmpunlocker
ce-scrub-workarounds.patch          cmpunlocker
persistent-sw-state.patch           cmpunlocker
pcie-gen2-scaffolding-only.patch    this repo
pcie-gen3-gsp.patch                 this repo
pcie-gen3-fuse-override.patch       this repo
pcie-gen4-g4.patch                  this repo
name-string.patch                   cmpunlocker
cmp-sku-mask.patch                  cmpunlocker
```

The tested build left out cmpunlocker's `bar1-resize-unlock.patch`, `ecc-enable.patch`, `ecc-fbpa-static.patch`
and `ecc-reporting.patch`. The four patches also apply cleanly with those in their usual places, but that
combination has not been built or tested.

Checked with `patch --dry-run` on a fresh copy of the 615.71.09 tarball: the four patches apply in this order with
no fuzz and no offset, and the patched tree is byte-identical to the tree the tested modules were built from (before
the VBIOS override patch was added).

Why `pcie-gen2.patch` is split: its `kernel_gsp.c` half (booter register unlock, `OPT_GEN23=0`) is what lets the card
advertise Gen3 at all. A build without it applied the fuse override but `LnkCap2` stayed at 2.5 GT/s. Its
`kernel_gsp_tu102.c` half and `pcie-gen2-probe-retrain.patch` pin the link to Gen2, so they are dropped.

## Build

Start from a working cmpunlocker install on 615.71.09 with the 10gb profile, so the firmware, the module directory
and cmpunlocker's modprobe file are in place. Then build the patched modules by hand and swap them in. You need the
kernel headers for the running kernel, gcc, `patch` and `pciutils`.

```bash
git clone https://github.com/amoghmunikote/cmpunlocker.git
git -C cmpunlocker checkout 2c7e2ecd7944e791fec040d2680036beb4a9327b
git clone https://github.com/darkmaniac7/cmp170hx-10gb-pcie-gen4.git
curl -L -o ogkm-615.71.09.tar.gz \
  https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/615.71.09.tar.gz
echo "caf48cda7d5fe7374d1d24ca4a90efb4dc783eefabfad5fa4b64fdc24213b62a  ogkm-615.71.09.tar.gz" | sha256sum -c
tar -xzf ogkm-615.71.09.tar.gz
cd open-gpu-kernel-modules-615.71.09

C=../cmpunlocker/driver/patches
G=../cmp170hx-10gb-pcie-gen4/patches
for p in $C/sec2-postbl-plm-ss-cfg.patch $C/booter-verify.patch $C/late-pma.patch \
         $C/bar0-pramin-clamp.patch $C/ce-scrub-workarounds.patch $C/persistent-sw-state.patch \
         $G/pcie-gen2-scaffolding-only.patch $G/pcie-gen3-gsp.patch \
         $G/pcie-gen3-fuse-override.patch $G/pcie-gen4-g4.patch \
         $C/name-string.patch $C/cmp-sku-mask.patch; do
  patch -p1 --forward < "$p" || { echo "FAILED: $p"; break; }
done

make -j"$(nproc)" modules SYSSRC=/lib/modules/$(uname -r)/build CC=gcc

cc -std=gnu11 -O2 -Wall -Wextra -Isrc/common/sdk/nvidia/inc \
  ../cmp170hx-10gb-pcie-gen4/tools/set_pcie_speed.c -o cmp-pcie-speed
```

The 40 GiB geometry needs no extra step at this cmpunlocker commit: the patched source picks it by PCI device ID at
runtime, and cmpunlocker's own `build.sh` skips its rewrite for the same reason.

## Install

As root, with no GPU clients running. Back up the current modules **before** copying the new ones in.

```bash
KVER=$(uname -r)
MODDIR=/lib/modules/$KVER/updates/cmpunlocker
BACKUP=/var/backups/cmp-pcie-gen4
mkdir -p "$BACKUP"
cp -a "$MODDIR"/nvidia*.ko "$BACKUP"/
mv /etc/modprobe.d/cmp-pcie-gen2.conf "$BACKUP"/      # written by cmpunlocker's installer

install -m 0644 kernel-open/nvidia*.ko "$MODDIR"/
install -m 0755 cmp-pcie-speed /usr/local/sbin/cmp-pcie-speed
install -m 0755 ../cmp170hx-10gb-pcie-gen4/tools/cmp-gen3.sh \
                ../cmp170hx-10gb-pcie-gen4/tools/cmp-gen4.sh \
                ../cmp170hx-10gb-pcie-gen4/tools/cmp_gen4_e1.py /usr/local/sbin/

cat > /etc/modprobe.d/cmp-pcie-gen4.conf <<'CONF'
options nvidia NVreg_RegistryDwords="RmForceEnableGen2=1;RMPcieLinkSpeed=0x5;CmpGen3=1" cmp_fuse_gen3=0 cmp_fuse_gen4=0
CONF

depmod -a "$KVER"
update-initramfs -u -k "$KVER"
```

Then cold boot, or reload the nvidia modules with no GPU clients running.

### Module options

```
options nvidia NVreg_RegistryDwords="RmForceEnableGen2=1;RMPcieLinkSpeed=0x5;CmpGen3=1" cmp_fuse_gen3=0 cmp_fuse_gen4=0
```

- `RMPcieLinkSpeed=0x5` is a bit mask that allows Gen3 (it does not mean Gen5). The Gen4 retrain goes through config
  space and does not read it.
- `CmpGen3=1` turns on the Gen3 block at GSP boot.
- `cmp_fuse_gen3=0` clears the two Gen3-disable fuses at probe.
- `cmp_fuse_gen4=0` clears bit 25 of `PCIE_MAGIC_BITS_D` at probe. Leave it out for Gen3 only.
- No `cmp_fuse_bdf`: the overrides apply to every matching card in the host. `cmp_fuse_bdf=0000:01:00.0` limits every
  `cmp_fuse_*` override, Gen4 included, to that one card.
- No `CmpGen4`: the PHY init runs at runtime from a trained Gen3 link, which is the tested route. The boot-time block
  behind `CmpGen4=1` has not been tested on its own anywhere.
- Keep every registry key in one `NVreg_RegistryDwords` string. A second `options nvidia NVreg_RegistryDwords=` line,
  in the same file or another file in `/etc/modprobe.d`, replaces the first and silently drops the Gen3 keys.
- Do not set the other `cmp_fuse_*` parameters (gpc, tpc, fbp, l2, nvlink, ecc, flr) or `cmp_fuse_magicd_clr` for
  this. They are not part of the procedure and were not tested here.

### Check after boot (read-only)

```bash
dmesg | grep "CMP fuse:"
lspci -s 0000:01:00.0 -vv | grep LnkCap2
```

Expected on each card:

```
CMP fuse: gen3 fused=0x1 write=0x0 opt=0x0 (direct)
CMP fuse: gen3_boot ... write=0x0 opt=0x0 (direct)
CMP fuse: magic_d before=0x16680000 clear=0x02000000 set=0x00000000 want=0x14680000 after=0x14680000 (rmw)
CMP fuse: EN_SW_OVERRIDE=1 (pre-RM/GSP)
LnkCap2: Supported Link Speeds: 2.5-16GT/s, ...
```

The `magic_d before` value is what the tested cards read; yours may differ, but bit 25 (`0x02000000`) must be clear
in `after`. Stop if you see `DID NOT STICK` or `disable_sw_override fuse is burned` (the RIR gate is not done), or if
`LnkCap2` does not list 8 GT/s (no Gen3) or 16 GT/s (no Gen4 this boot; Gen3 still works).

Repeating `kgspExecuteBooterLoad_TU102: failed to execute Booter Load: 0xffff` lines are normal on unlocked 10 GB
cards. They appear with the plain cmpunlocker module too, and the adapter still initialises. They are not the
failure signal; `LnkCap2` is.

## Every boot

The link setting is volatile, so these steps run after every boot. One card at a time, one attempt per card per
boot.

```bash
BDF=0000:01:00.0                                            # the card; repeat for the next card afterwards
sudo cmp-gen3.sh "$BDF"                                     # 1. Gen3: must end at 8 GT/s at both ends
sudo python3 -I /usr/local/sbin/cmp_gen4_e1.py "$BDF"          # 2. read-only check of the Gen4 prerequisites
sudo python3 -I /usr/local/sbin/cmp_gen4_e1.py "$BDF" --apply  # 3. runtime PHY init (E1); does not retrain
sudo python3 -I /usr/local/sbin/cmp_gen4_e1.py "$BDF"          #    must print "E1 Gen4 PHY init present: YES"
sudo cmp-gen4.sh "$BDF"                                     # 4. one retrain to 16 GT/s
```

For Gen3 only, stop after step 1.

- `cmp-gen3.sh` reads the device minor, asks RM for speed 1, then 2, sets Target Link Speed 3 on the root port and
  the card (`CAP_EXP+30.w=0003:000f`), then asks RM for speed 3. It exits non-zero unless `LnkSta` is 8 GT/s at both
  ends and the width did not drop. On a link that is already Gen3 it only checks.
- `cmp_gen4_e1.py` maps BAR0 read-only by default and reports the Gen4 prerequisites. With `--apply` it writes the
  Gen4 part of the A100 DevInit PHY setup that the CMP VBIOS leaves out: `0x88CE4` = `0x14`, `0x88CE0` bits 5:0 = 6,
  clears `CYA_0` (`0x8C2C0`) bits 0, 2, 3, 13 and 23, `PL_LINK_RATE` (`0x8C1C0`) bits 19:16 = 4, `LINK_CONFIG_0`
  (`0x8C040`) bits 19:18 = 0 (reversed encoding: 0 is Gen4), VSEC `0x88610` bits 0 and 12, and the Gen3 bits in
  `PRIV_MISC_1`. It refuses unless the card is a `2082` bound to nvidia, bit 25 of `PCIE_MAGIC_BITS_D` is clear, the
  link is at Gen3 and every register reads sane.
- `cmp-gen4.sh` refuses unless the link is at Gen3 and both ends list 16 GT/s in `LnkCap2`. It sets Target Link
  Speed 4 on the root port and the card, sets Retrain Link once on the root port, waits up to about 3 s, then checks
  `LnkSta` at both ends, the width and the uncorrectable AER counters. On failure it sets the target speed back to 3
  on both ends without retraining and exits 1, or 2 if the card's config space is unreadable. **Never run it in a
  loop.**
- Do not use RM's speed control for Gen4. On this driver `SET_PCIE_SPEED` is handled by the closed GSP-RM with a link
  capability cached at boot; on an 8 GB card it returned `0x56` (not supported) for Gen4.

In testing these steps were run by hand. If you automate them, run them once per boot, after the driver has
initialised and before GPU work starts, never in a retry loop.

## Gen4 pass gates

A link that reads 16 GT/s is not yet a pass. All four, on each card:

1. **`LnkSta` 16 GT/s at both ends, width kept.** `lspci -vv` on the card and on its root port both show
   `Speed 16GT/s` with the width from before (x4 here), and `/sys/bus/pci/devices/<bdf>/current_link_speed` reads
   `16.0 GT/s PCIe`.
2. **At least 5 GB/s in both directions** in pinned host-to-device and device-to-host copies. Gen3 x4 gives about
   3.3 GB/s on these cards, and Gen4 x4 is expected at about 6.4 to 6.8 GB/s. The 5 GB/s line (1.5x Gen3) is our
   threshold, not a community number.
3. **No new Xid and no new uncorrectable AER** at either end, and `aer_dev_correctable` does not climb under load.
   A climbing correctable count means marginal 16 GT/s equalization, and the replays eat the bandwidth.
4. **A 30-minute soak** with GPU compute and continuous pinned copies, sampling `LnkSta` at both ends, then a check
   after an idle period. RM still believes the link is Gen3 ([below](#nvidia-smi-still-says-gen3)), so watch for a
   silent fall back to 8 GT/s.

### Why the bandwidth gate

Members of the cmpunlocker community have reported links labelled Gen4 that moved data at Gen3 speed ("Gen4 in name
only"): kingsizexxxl's cap-modded card was "allegedly gen4x16, but it clearly isnt", and deejay9983 noted that "24gb
round trip is gen 3 speeds". `LnkSta` alone cannot tell the two apart; a copy test can. Use a pinned-memory copy
test you trust (the figures here come from 256 MiB `cudaMemcpy` copies from page-locked host memory, 10 runs) and
compare it with Gen3 on the same card with the same tool.

## nvidia-smi still says Gen3

`nvidia-smi` (`pcie.link.gen.current`) keeps reporting Gen3 on a card at 16 GT/s. RM caches the link capability at
boot and the Gen4 retrain goes around RM. This is expected and is not a failure. Judge the link by `LnkSta` at both
ends, sysfs `current_link_speed` and the copy bandwidth.

## Recovery

Neither tested card needed recovery from a Gen4 attempt. These are the planned steps:

- **Gen4 trained but failed a gate:** set the target speed back to 3 on both ends and retrain once:
  ```bash
  setpci -s <root port> CAP_EXP+30.w=0003:000f
  setpci -s <card> CAP_EXP+30.w=0003:000f
  setpci -s <root port> CAP_EXP+10.w=0020:0020
  lspci -s <card> -vv | grep LnkSta:          # expect 8GT/s
  ```
  RM's speed control (`cmp-pcie-speed 3 <minor> <bus>`) is the second choice; it has not been tried from a Gen4 link.
- **The card fell off the bus** (`LnkSta` reads `ffff`, Xid 79, config space unreadable, `cmp-gen4.sh` exit 2):
  stop all writes and retries. Do a secondary bus reset on the root port (set bit 6 of its Bridge Control, wait,
  clear it), then reboot. If the card is still missing, power cycle.
- **Never loop the trainer.** One attempt per card per boot. A card that dropped off the bus in a Gen3 transition
  on another machine was later judged to have a damaged PCIe controller.
- **Back to Gen3:** remove `cmp_fuse_gen4=0` from the modprobe file, `update-initramfs -u`, reboot.
- **Back to stock cmpunlocker:** restore the modules and `cmp-pcie-gen2.conf` from the backup, remove
  `cmp-pcie-gen4.conf`, `depmod -a`, `update-initramfs -u`, cold boot. Setting `CmpGen3=0` alone is not a full undo.

A power cycle clears every volatile change regardless.

## Risks

- **RM does not know about the Gen4 link.** If RM runs its own speed change (a performance-state change or an error
  recovery), it may retrain to the Gen3 it has cached and drop the link to 8 GT/s without a log line. It did not
  happen in the 30-minute soaks; the idle re-check in the gates is there to catch it.
- **A failed 16 GT/s transition can take the card off the bus**, more readily than a failed Gen3 one. Have console
  and power access before you start.
- **Do not burn a Gen3 or Gen4 fuse record.** Which fuse bit disables Gen3 is not settled, the meaning of
  `PCIE_MAGIC_BITS_D` bits 19, 22, 26 and 28 is not decoded, and nothing here needs to be permanent.
- 16 GT/s equalization held on two unmodified x4 links straight to CPU root ports. Risers, chipset slots and PCIe
  switches can be worse: watch the correctable AER count.
- Tested on one host with two cards. Other boards, other cards and other driver versions are untested.
- No warranty: these patches write undocumented hardware registers. See the license files.

## Credits

- **amoghmunikote**: [cmpunlocker](https://github.com/amoghmunikote/cmpunlocker), the base patches and the Gen2
  booter code reused in `pcie-gen2-scaffolding-only.patch`.
- **lxwx** (lixiangwuxian, @lxtend on Discord) and **hezz1891**: the Gen3 method. lxwx's
  [170hx_tips](https://github.com/lixiangwuxian/170hx_tips) guide is the source of the probe-time fuse override, the
  post-GSP Gen3 block, `set_pcie_speed.c` and `cmp-gen3.sh`. hezz1891 posted evanrodgers'
  [wrapper](https://github.com/evanrodgers/cmp-170hx-rir-burn-util) and the 30-minute two-card acceptance run used
  as the soak bar here.
- **CMPGlitch / ._.patrik**: the Gen4 PHY-init (E1) sequence, the LTSSM retrain and the warning about the `0x881C0`
  write, worked out on an 8 GB card.
- **bruno063185**: the first report of volatile Gen4 x4 on a gate-burned 10 GB card.
- **kingsizexxxl** and **deejay9983**: the "Gen4 in name only" reports behind the bandwidth gate.
- **Panchovix**: [nvidia-linux-vbios-vix-loader](https://github.com/Panchovix/nvidia-linux-vbios-vix-loader), whose
  VBIOS override patch was in the tested build.

More detail and the sources for each claim: [PCIe Gen4 on the 10 GB card](https://cmp.wiki/wiki/PCIe_Gen4_on_the_10_GB_card)
and [PCIe Gen3 on the 10 GB card](https://cmp.wiki/wiki/PCIe_Gen3_on_the_10_GB_card) on cmp.wiki.

## License

- `patches/`: GNU General Public License version 2 ([LICENSE](LICENSE)). The patches extend cmpunlocker, which is
  GPL-2.0, and `pcie-gen2-scaffolding-only.patch` is taken from it. The NVIDIA files they modify are MIT-licensed,
  and the nvidia module is dual MIT/GPL.
- `tools/`: MIT ([tools/LICENSE](tools/LICENSE)).
- `pcie-gen3-fuse-override.patch`, `pcie-gen3-gsp.patch`, `tools/set_pcie_speed.c` and `tools/cmp-gen3.sh` are
  adapted from code published in [lixiangwuxian/170hx_tips](https://github.com/lixiangwuxian/170hx_tips), which does
  not state a license. Those parts remain the work of their author and are included here with credit; the terms
  above cover the changes made in this repository.

Not affiliated with or endorsed by NVIDIA. NVIDIA is a trademark of NVIDIA Corporation.
