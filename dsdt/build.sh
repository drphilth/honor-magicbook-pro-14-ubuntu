#!/usr/bin/env bash
# build.sh — produce the corrected DSDT for the Honor MagicBook Pro 14 2025 (FMB-P).
# Run where a CURRENT iasl is available (laptop Fedora: `sudo dnf install acpica-tools`;
# this WSL desktop's packaged iasl is too old — build ACPICA from source and set IASL=).
#
#   IASL=/path/to/iasl ./build.sh        # or just ./build.sh if `iasl` is current
#
# Input : dsdt/original/DSDT        (raw table from /sys/firmware/acpi/tables/DSDT)
# Output: dsdt/patched/dsdt.aml     (load via initrd override; Secure Boot OFF)
#         dsdt/patched/clean-fix.patch
set -euo pipefail
cd "$(dirname "$0")"
IASL="${IASL:-iasl}"
mkdir -p patched

echo ">> [1] disassemble stock DSDT"
"$IASL" -d original/DSDT >/dev/null 2>&1
cp original/DSDT.dsl patched/dsdt.dsl

echo ">> [2] THE FIX — remove NFC0 load-time GNUM call (keeps the device intact)"
#    NFC0 ran GNUM(0x0014080A) at table-load -> GINF AE_AML_INTERNAL -> DSDT load aborts.
sed -i '/INT1 = GNUM (0x0014080A)/d; /CreateWordField (SBGF, 0x17, INT1)/d' patched/dsdt.dsl

echo ">> [2b] TOUCHSCREEN FIX — ACPI PowerResource (_PR0/_ON) to power the FTSC1000 panel"
#    The DSDT has NO power/reset method for the FocalTech panel (verified). Power is pure
#    GPIO: line 108 (GPP_A_12, desc 0x0014040C) = power-enable, line 130 (GPP_E_2, 0x00140482)
#    = reset-release (GNUM-verified). Driving them in _INI runs too early -> pinctrl clobbers
#    it. Instead inject a PowerResource (PWRR) whose _ON drives them (SPMV pad-mode + SGOV
#    value, the firmware's own pattern), referenced by the panel _PR0 -> the OS runs _ON when
#    it powers the device to D0 (after pinctrl, before i2c_hid probes). GNUM-verified GPIO lines; see inject-touchscreen-power.py.
python3 "$(dirname "$0")/inject-touchscreen-power.py" patched/dsdt.dsl

echo ">> [3] bump DSDT OEM revision 0x02 -> 0x03 (required for initrd override to apply)"
sed -i 's/\("ARL", \)0x00000002/\10x00000003/' patched/dsdt.dsl

echo ">> [4] remove references unrepresentable in a standalone DSDT (toolchain-forced,"
echo "       NOT behavioural — all are dead/SSDT-injected; see docs/dsdt-root-cause.md)"
#    (a) 13 unused EFUN.CRFI externals (declared, never referenced)
sed -i '/External (.*EFUN\.CRFI/d' patched/dsdt.dsl
#    (b) 4 XHCI _PS0/_PS3 PS0X/PS3X externals (no loaded table defines them -> dead hooks)
sed -i '/External (_SB_\.PC0[02]\.XHCI\._PS[03]\.PS[03]X,/d' patched/dsdt.dsl
#    (c) their 4 dead guarded-call blocks: If (CondRefOf (PSnX)) { PSnX () }
perl -0777 -i -pe 's/[ \t]*If \(CondRefOf \(PS0X\)\)\n[ \t]*\{\n[ \t]*PS0X \(\)\n[ \t]*\}\n//g' patched/dsdt.dsl
perl -0777 -i -pe 's/[ \t]*If \(CondRefOf \(PS3X\)\)\n[ \t]*\{\n[ \t]*PS3X \(\)\n[ \t]*\}\n//g' patched/dsdt.dsl

echo ">> [5] compile (-on: keep the injected ABSOLUTE \\_SB.PC00.I2C2.TPL1.PWRR ref in TD_P —"
echo "       the optimizer would shorten it to a bare PWRR NameSeg, which once mis-bound to"
echo "       the stock \\_SB.PWRR method at load; harmless for the rest of the as-written source)"
"$IASL" -on -tc patched/dsdt.dsl >/dev/null 2>&1 || { "$IASL" -on -tc patched/dsdt.dsl 2>&1 | grep -i error; exit 1; }
[ -f patched/dsdt.aml ] || mv patched/DSDT.aml patched/dsdt.aml 2>/dev/null || true

echo ">> [6] record the minimal source diff"
diff original/DSDT.dsl patched/dsdt.dsl > patched/clean-fix.patch || true
cp patched/dsdt.aml patched/dsdt.global.aml

echo ">> [7] derive the Chinese-SKU variant (NVS regions shifted +0x00100000)"
#    The FMB-P ships in a global and a Chinese BIOS. Their stock DSDTs are byte-identical
#    EXCEPT for six NVS base-address literals, each 0x00100000 higher on the Chinese unit
#    (verified against denis-bb's reference disassembly, dsdt/reference/honor-fmb-p-dsdt/original/
#    — the ONLY non-checksum differences). None of our fixes touch these, so the Chinese patched
#    DSDT == our global patched DSDT with the same six swaps. The initramfs deb GNVS-selects the
#    right one at install (postinst). UNTESTED on real Chinese hardware — shipped for community
#    verification (README.Debian says so). The assertion below fails the build loudly if a future
#    BIOS changes the DSDT so the deltas no longer apply cleanly (re-audit against the reference).
cp patched/dsdt.dsl patched/dsdt.chinese.dsl
chinese_pairs=(
  "0x67E09018 0x67E19018"   # GNVS SystemMemory region base
  "0x67E13D18 0x67E23D18"   # SANB
  "0x67E13F98 0x67E23F98"   # VMNB
  "0x67E13018 0x67E23018"   # PNVB
  "0x67E13E98 0x67E23E98"   # OGNS SystemMemory region base
  "0x67DEC018 0x67DFC018"   # MDBG SystemMemory region base
)
for pair in "${chinese_pairs[@]}"; do
  set -- $pair; g="$1"; c="$2"
  n=$(grep -cF "$g" patched/dsdt.chinese.dsl)
  [ "$n" -eq 1 ] || { echo "FATAL: expected exactly one '$g' in the patched DSDT, found $n."; \
    echo "       The DSDT layout changed — re-audit the global<->Chinese SKU deltas against"; \
    echo "       dsdt/reference/honor-fmb-p-dsdt/original/ before shipping a Chinese AML."; exit 1; }
  sed -i "s/$g/$c/" patched/dsdt.chinese.dsl
done

echo ">> [8] compile the Chinese variant"
"$IASL" -on -tc patched/dsdt.chinese.dsl >/dev/null 2>&1 || { "$IASL" -on -tc patched/dsdt.chinese.dsl 2>&1 | grep -i error; exit 1; }
[ -f patched/dsdt.chinese.aml ] || mv patched/DSDT.aml patched/dsdt.chinese.aml 2>/dev/null || true

echo ">> done:"
echo "   global : $(ls -l patched/dsdt.global.aml | awk '{print $5}') bytes -> patched/dsdt.global.aml  (== patched/dsdt.aml, boot-proven)"
echo "   chinese: $(ls -l patched/dsdt.chinese.aml | awk '{print $5}') bytes -> patched/dsdt.chinese.aml (UNTESTED on hardware)"
echo "   OEM rev: $(grep -m1 DefinitionBlock patched/dsdt.dsl)"
