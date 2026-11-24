#!/usr/bin/env bash
# build.sh — produce the corrected DSDT for the Honor MagicBook Pro 14 2025 (FMB-P).
# Run where a CURRENT iasl is available (laptop Fedora: `sudo dnf install acpica-tools`;
# this WSL desktop's packaged iasl is too old — build ACPICA from source and set IASL=).
#
#   IASL=/path/to/iasl ./build.sh        # or just ./build.sh if `iasl` is current
#
# Input : dsdt/original/DSDT        (raw STOCK table: a copy of /sys/firmware/acpi/tables/DSDT,
#                                    or dsdt.dat from `acpidump -b`, taken with no override
#                                    active; BIOS 1.13/1.16/1.17)
# Output: dsdt/patched/dsdt.aml     (load via initrd override; Secure Boot OFF)
#         dsdt/patched/clean-fix.patch
set -euo pipefail
cd "$(dirname "$0")"
IASL="${IASL:-iasl}"
mkdir -p patched

die() { echo "FATAL: $*" >&2; exit 1; }

command -v "$IASL" >/dev/null 2>&1 || die "iasl not found (install acpica-tools, or set IASL=)"
# Accept acpidump's name as well: `acpidump -b` writes dsdt.dat, not DSDT.
IN=original/DSDT
[ -f "$IN" ] || [ ! -f original/dsdt.dat ] || IN=original/dsdt.dat
[ -f "$IN" ] || die "no input table: put the stock DSDT at dsdt/original/DSDT
       (sudo cat /sys/firmware/acpi/tables/DSDT > dsdt/original/DSDT, or acpidump -b's dsdt.dat)"

echo ">> [1] disassemble stock DSDT ($IN)"
"$IASL" -p original/stock -d "$IN" >/dev/null 2>&1 \
  || { "$IASL" -p original/stock -d "$IN" 2>&1 | grep -v -E "^(Intel ACPI|ASL\+ Optimizing|Copyright|$)" | tail -15 >&2 || true; die "iasl -d failed on $IN"; }
cp original/stock.dsl patched/dsdt.dsl

# Firmware OEM revision (0x02 on BIOS 1.13/1.16/1.17). The override must carry a HIGHER
# one or the kernel ignores it, so derive it from the input instead of hard-coding 0x02.
REV=$(sed -n 's/^DefinitionBlock ("", "DSDT", 2, "HONOR", "ARL", \(0x[0-9A-Fa-f]*\))$/\1/p' patched/dsdt.dsl | head -1)
[ -n "$REV" ] || die "original/DSDT is not an FMB-P DSDT (expected OEM HONOR / table ARL)"
# Refuse an already-corrected table (ours: injected TD_P; denis-bb's: NFC0 removed), e.g. a
# /sys/firmware/acpi/tables/DSDT copied while an override was active.
if grep -q 'Name (TD_P, Package' patched/dsdt.dsl || ! grep -q 'Device (NFC0)' patched/dsdt.dsl; then
  die "original/DSDT is an already-patched table (was an override active when you dumped it?).
       Boot once without the override, or use a stock dump."
fi
NEW_REV=$(printf '0x%08X' $((REV + 1)))

#    NFC0 ran GNUM(0x0014080A) at table-load -> GINF AE_AML_INTERNAL -> DSDT load aborts.
#    BIOS 1.17 fixed this upstream by moving the call into NFC0._CRS (still runs, but only
#    on demand, not at load) — detect that and skip. The statement text is identical in both
#    places, so tell them apart by nesting depth: iasl indents 4 spaces per level, and only a
#    statement directly in the Device (NFC0) body (device indent + 4) runs at table load; the
#    1.17 copy sits one level deeper inside the method and must be left alone.
body=$(awk '/^ *Device \(NFC0\)$/ { match($0, /^ */); print RLENGTH + 4; exit }' patched/dsdt.dsl)
pad=$(printf '%*s' "$body" '')
n=$(grep -c "^${pad}INT1 = GNUM (0x0014080A)\$" patched/dsdt.dsl || true)
case $n in
  1) echo ">> [2] THE FIX — remove NFC0 load-time GNUM call (keeps the device intact)"
     sed -i "/^${pad}INT1 = GNUM (0x0014080A)\$/d; /^${pad}CreateWordField (SBGF, 0x17, INT1)\$/d" patched/dsdt.dsl ;;
  0) grep -q 'GNUM (0x0014080A)' patched/dsdt.dsl \
       || die "NFC0 GNUM (0x0014080A) not found at all — unknown BIOS, re-audit before shipping"
     echo ">> [2] NFC0 already fixed by this BIOS (GNUM no longer runs at table load) — skipping" ;;
  *) die "expected at most one load-time NFC0 GNUM call, found $n — BIOS changed, re-audit" ;;
esac

echo ">> [2b] TOUCHSCREEN FIX — ACPI PowerResource (_PR0/_ON) to power the FTSC1000 panel"
#    The DSDT has NO power/reset method for the FocalTech panel (verified). Power is pure
#    GPIO: line 108 (GPP_A_12, desc 0x0014040C) = power-enable, line 130 (GPP_E_2, 0x00140482)
#    = reset-release (GNUM-verified). Driving them in _INI runs too early -> pinctrl clobbers
#    it. Instead inject a PowerResource (PWRR) whose _ON drives them (SPMV pad-mode + SGOV
#    value, the firmware's own pattern), referenced by the panel _PR0 -> the OS runs _ON when
#    it powers the device to D0 (after pinctrl, before i2c_hid probes). GNUM-verified GPIO lines; see inject-touchscreen-power.py.
python3 "$(dirname "$0")/inject-touchscreen-power.py" patched/dsdt.dsl

echo ">> [3] bump DSDT OEM revision $REV -> $NEW_REV (required for initrd override to apply)"
sed -i "s/^\(DefinitionBlock (\"\", \"DSDT\", 2, \"HONOR\", \"ARL\", \)$REV)/\1$NEW_REV)/" patched/dsdt.dsl
grep -q "\"ARL\", $NEW_REV)" patched/dsdt.dsl || die "OEM revision bump failed"

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
diff original/stock.dsl patched/dsdt.dsl > patched/clean-fix.patch || true
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
  n=$(grep -cF "$g" patched/dsdt.chinese.dsl || true)   # grep -c exits 1 on 0 matches
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
