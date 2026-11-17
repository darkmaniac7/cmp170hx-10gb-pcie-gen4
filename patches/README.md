# Patches

Four patches against NVIDIA open-gpu-kernel-modules 615.71.09, applied on top of cmpunlocker's core patches. The
order is in `series`. They take the slot of cmpunlocker's `pcie-gen2.patch` and `pcie-gen2-probe-retrain.patch`;
the full order is in the top-level README.

| Patch | Changes | What it does |
|---|---|---|
| `pcie-gen2-scaffolding-only.patch` | `src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c` | The `kernel_gsp.c` half of cmpunlocker's `pcie-gen2.patch`, with the same added lines. During GSP bootstrap it uses booter writes to open the XP3G, XVE and fuse-option privilege masks, sets `OPT_GEN23` (`0x82057c`) to 0, programs the XP3G overrides and `PRIV_MISC_1`, and sets the link up for Gen2. Without it the card never advertises Gen3 (`LnkCap2` stays at 2.5 GT/s). The `kernel_gsp_tu102.c` Gen2 block of the same cmpunlocker patch is left out, and so is `pcie-gen2-probe-retrain.patch`: both pin the link to Gen2. |
| `pcie-gen3-gsp.patch` | `src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c` | After the initial-boot BooterLoad, on device `0x2082` and only with the registry key `CmpGen3=1`: Gen3 enable bits in `PRIV_MISC_1` (`0x8841c`), clears `CYA_0` (`0x8c2c0`) bits 2 and 3, target speed 3 in the internal Link Control 2 (`0x880a8`), `PL_LINK_RATE` (`0x8c1c0`) rate 3, VSEC hierarchy bit 12 (`0x88610`), `LINK_CONFIG_0` (`0x8c040`) rate field for 8 GT/s, a directed speed change through `0x8b8c0`, then `0x8872c` = 8. The link itself is trained later from userspace. |
| `pcie-gen3-fuse-override.patch` | `kernel-open/nvidia/nv-pci.c` | Fuse software override at driver probe, before RM and GSP start. `cmp_fuse_gen3=0` clears `OPT_DISABLE_GEN3_SPEED` (`0x820250`) and `OPT_PCIE_BOOT_GEN3_DIS` (`0x820580`) and logs the readback (`CMP fuse: ...`). It does nothing if `DISABLE_SW_OVERRIDE` (`0x820084`) reads 1, which means the RIR gate is not done. `cmp_fuse_bdf=<bdf>` limits it to one card. The other `cmp_fuse_*` parameters (gpc, tpc, fbp, l2, nvlink, ecc, flr) come with the original code and are not part of this procedure. |
| `pcie-gen4-g4.patch` | `nv-pci.c`, `kernel_gsp_tu102.c` | Additive: it removes no line of the patches above. In `nv-pci.c`, `cmp_fuse_gen4=0` clears bit 25 (`GEN4_SPEED_DISABLED`) of `PCIE_MAGIC_BITS_D` (`0x820520`) at probe by read-modify-write, and `cmp_fuse_magicd_clr` can also clear bits 19, 22, 26 and 28 (only bits inside `0x16480000` are accepted). In `kernel_gsp_tu102.c`, a boot-time copy of the Gen4 PHY init (E1) behind `CmpGen4=1`, which runs only on a card whose bit 25 is already clear. Left out on purpose: the `0x881C0` (`SYSTEM_MAX_SPEED`) booter write from CMPGlitch's 8 GB Gen4 patch, which wedged GSP boot. With `cmp_fuse_gen4`, `cmp_fuse_magicd_clr` and `CmpGen4` unset, the build behaves exactly as the Gen3 build. |

Tested: `cmp_fuse_gen3=0`, `CmpGen3=1` and `cmp_fuse_gen4=0`, with the PHY init run at runtime by
`tools/cmp_gen4_e1.py`. Not tested: `CmpGen4=1` (the boot-time PHY init) and `cmp_fuse_magicd_clr`.

`pcie-gen2-scaffolding-only.patch` was regenerated against the 615.71.09 tree so it applies without fuzz; the result
is identical to applying cmpunlocker's own `pcie-gen2.patch` hunk, which lands at the same place with fuzz 1.
