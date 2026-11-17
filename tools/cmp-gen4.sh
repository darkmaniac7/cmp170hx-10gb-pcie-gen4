#!/usr/bin/env bash
# cmp-gen4.sh: CMP 170HX 10 GB (10de:2082) single-pass Gen3 -> Gen4 retrain.
# Needs the patched driver from ../patches loaded with cmp_fuse_gen4=0 (see README).
#
# Uses the PCIe config-space path (Target Link Speed = 16GT/s on both ends + one Retrain Link
# on the upstream port), executed by the LTSSM. It does NOT call RM SET_PCIE_SPEED(4): that
# control is routed to closed GSP-RM, which returned 0x56 NOT_SUPPORTED for Gen4 on GA100 CMP
# (CMPGlitch, 8 GB card, driver 610.43.03; not tried on 2082/615.71.09).
#
# Preconditions (checked): 2082 at 0000:xx:00.0, link already Gen3 (run cmp-gen3.sh first),
# GPU and upstream LnkCap2 both list 16GT/s. The Gen4 PHY init (E1) must already be applied,
# either by the CmpGen4=1 boot block or by `cmp_gen4_e1.py --apply` (checked by cmp_gen4_e1.py).
# One attempt, no retries. On failure it parks Target Link Speed back at Gen3 on both ends.
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Root privileges required'; exit 1; }
BDF=${1:?Usage: sudo bash cmp-gen4.sh 0000:01:00.0}
[[ $BDF =~ ^0000:[0-9a-fA-F]{2}:00\.0$ ]] || { echo 'This tool supports only 0000:xx:00.0'; exit 1; }
BDF=${BDF,,}
D=/sys/bus/pci/devices/$BDF
[[ $(cat "$D/vendor") == 0x10de && $(cat "$D/device") == 0x2082 ]] || {
  echo 'Device is not the validated 10de:2082'; exit 1;
}
PARENT=$(basename "$(dirname "$(readlink -f "$D")")")
[[ $PARENT =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] || exit 1
[[ $(cat "/sys/bus/pci/devices/$PARENT/class") == 0x0604* ]] || {
  echo 'Upstream device is not a PCI bridge'; exit 1;
}

read_w() { local s; s=$(setpci -s "$1" "$2") || return 1
           [[ $s =~ ^[[:xdigit:]]{4}$ && ${s,,} != ffff ]] || return 1; printf '%s' "$s"; }
read_l() { local s; s=$(setpci -s "$1" "$2") || return 1
           [[ $s =~ ^[[:xdigit:]]{8}$ && ${s,,} != ffffffff ]] || return 1; printf '%s' "$s"; }
aer_tot() { # $1=bdf $2=correctable|fatal|nonfatal -> TOTAL count or "na"
  local f=/sys/bus/pci/devices/$1/aer_dev_$2
  if [[ -r $f ]]; then awk '/^TOTAL_ERR/{print $2; f=1} END{if(!f)print "na"}' "$f"; else echo na; fi; }
aer_snap() { local b; for b in "$BDF" "$PARENT"; do
  printf '%s cor=%s nonfatal=%s fatal=%s\n' "$b" "$(aer_tot "$b" correctable)" \
    "$(aer_tot "$b" nonfatal)" "$(aer_tot "$b" fatal)"; done; }
park_gen3() { setpci -s "$PARENT" CAP_EXP+30.w=0003:000f 2>/dev/null || true
              setpci -s "$BDF" CAP_EXP+30.w=0003:000f 2>/dev/null || true; }

STA=$(read_w "$BDF" CAP_EXP+12.w) || { echo 'GPU config space unreadable'; exit 1; }
UPSTA=$(read_w "$PARENT" CAP_EXP+12.w) || { echo 'Upstream config space unreadable'; exit 1; }
CAP2=$(read_l "$BDF" CAP_EXP+2c.l) || { echo 'GPU LnkCap2 unreadable'; exit 1; }
UPCAP2=$(read_l "$PARENT" CAP_EXP+2c.l) || { echo 'Upstream LnkCap2 unreadable'; exit 1; }
GEN=$((16#$STA & 15)); WIDTH=$(( (16#$STA >> 4) & 63 ))
echo "GPU=$BDF upstream=$PARENT LnkSta=$STA (Gen$GEN x$WIDTH) upLnkSta=$UPSTA LnkCap2=$CAP2 upLnkCap2=$UPCAP2"
(( WIDTH > 0 )) || { echo 'Invalid link width'; exit 1; }
echo '--- AER before ---'; AER_BEFORE=$(aer_snap); echo "$AER_BEFORE"

if (( GEN == 4 && (16#$UPSTA & 15) == 4 )); then
  echo 'Already Gen4 at both ends; validating only.'
else
  (( (16#$CAP2 >> 4) & 1 )) || {
    echo 'NO-GO: GPU LnkCap2 does not list 16GT/s (MAGIC_D bit25 not cleared on this card?)'; exit 1; }
  (( (16#$UPCAP2 >> 4) & 1 )) || { echo 'NO-GO: upstream port LnkCap2 does not list 16GT/s'; exit 1; }
  (( GEN == 3 )) || { echo "NO-GO: link is Gen$GEN, not Gen3. Run cmp-gen3.sh first."; exit 1; }
  echo 'Target Link Speed = 16GT/s on both ends, then ONE Retrain Link on the upstream port'
  setpci -s "$PARENT" CAP_EXP+30.w=0004:000f
  setpci -s "$BDF" CAP_EXP+30.w=0004:000f
  setpci -s "$PARENT" CAP_EXP+10.w=0020:0020
  for _ in $(seq 1 30); do            # wait up to ~3 s for Link Training (bit11) to clear
    sleep 0.1
    s=$(read_w "$PARENT" CAP_EXP+12.w) || continue
    (( (16#$s >> 11) & 1 )) || break
  done
  sleep 0.5
fi

AFTER=$(read_w "$BDF" CAP_EXP+12.w) || {
  echo 'FAILED: GPU config space unreadable after retrain (fell off the bus?). STOP, no retry.'
  echo 'Recovery: README, "Recovery" (SBR on the root port, then reboot, then power cycle).'
  exit 2; }
UP=$(read_w "$PARENT" CAP_EXP+12.w) || UP=ffff
STA2=$(read_w "$BDF" CAP_EXP+32.w || echo '????')
NGEN=$((16#$AFTER & 15)); NWIDTH=$(( (16#$AFTER >> 4) & 63 )); UPGEN=$((16#$UP & 15))
echo "after: GPU LnkSta=$AFTER upstream LnkSta=$UP => GPU Gen$NGEN x$NWIDTH, upstream Gen$UPGEN; GPU LnkSta2=$STA2"
echo '--- AER after ---'; AER_AFTER=$(aer_snap); echo "$AER_AFTER"
lspci -s "$BDF" -vv | grep -E 'LnkCap:|LnkCap2:|LnkCtl2:|LnkSta:|LnkSta2:' || true
lspci -s "$PARENT" -vv | grep -E 'LnkSta:' || true

fatal_up=0
while read -r b rest; do
  for k in nonfatal fatal; do
    a=$(sed -n "s/.*$k=\([^ ]*\).*/\1/p" <<<"$rest")
    p=$(grep "^$b " <<<"$AER_BEFORE" | sed -n "s/.*$k=\([^ ]*\).*/\1/p")
    if [[ $a =~ ^[0-9]+$ && $p =~ ^[0-9]+$ ]] && (( a > p )); then fatal_up=1; fi
  done
done <<<"$AER_AFTER"

if (( NGEN == 4 && UPGEN == 4 && NWIDTH >= WIDTH && fatal_up == 0 )); then
  echo 'LINK PASS: 16GT/s at both ends, width kept, no new uncorrectable AER.'
  echo 'NOT DONE YET: the bandwidth gate (pinned H2D and D2H both >= 5 GB/s at x4) and the 30-minute soak decide acceptance.'
  echo 'Note: nvidia-smi will still say Gen3 (RM boot-cached linkCap). Judge by LnkSta, sysfs and bandwidth.'
  exit 0
fi
park_gen3
echo 'FAILED: Gen4 not established at both ends, width dropped, or new uncorrectable AER.'
echo 'Target Link Speed parked back at Gen3 on both ends (no retrain issued). Do NOT loop this script.'
echo "If the link is now below Gen3: cmp-pcie-speed 3 <minor> <bus>, or README \"Recovery\"."
exit 1
