# DSDT workflow

Goal: produce a corrected `patched/dsdt.aml` built from **this machine's own** ACPI
tables, then load it via initrd override. We do **not** trust the prebuilt v1.13
binary, and we do **not** blindly replicate denis-bb's patch — see
[`../docs/dsdt-root-cause.md`](../docs/dsdt-root-cause.md) for why (his patch mixes
~14 cosmetic/toolchain edits with 1–2 genuine ones and mis-states the mechanism).

## Usage

```bash
mkdir -p dsdt/original
sudo cat /sys/firmware/acpi/tables/DSDT > dsdt/original/DSDT   # or acpidump -b's dsdt.dat
IASL=/path/to/iasl dsdt/build.sh                                 # IASL= optional
```

The input must be the **stock** firmware table: dump it while no override is active
(`build.sh` refuses an already-patched table). Output lands in `patched/`
(`dsdt.global.aml`, `dsdt.chinese.aml`, `clean-fix.patch`).

**BIOS 1.17** already fixes the NFC0 load abort in firmware (the `GNUM` call moved into
`NFC0._CRS`); `build.sh` detects that, skips step [2] and only injects the touchscreen
power resource. The OEM revision is always set to the firmware's revision + 1.

## Clean approach (not "remove everything until it boots")

1. **Evidence first** — capture the *runtime* ACPI error from `dmesg`/`journalctl`
   on the stock machine, not iasl's disassembly-time error. Dump DSDT **and all
   SSDTs** (`acpidump -b`).
2. **Decompile with full context** (`iasl -e ssdt*.dat -d`) so externals resolve —
   delete **nothing** gratuitously (this is where denis-bb's EFUN.CRFI deletions came
   from; we avoid them).
3. **Bisect the two real candidates** independently and test which restores USB:
   - `Device (NFC0)` on `\_SB.PC00.I2C1` (HID `NTAG0001`, I2C `0x0057`), and/or
   - the `XHCI._PS0.PS0X` / `._PS3.PS3X` externals + their `PS0X()`/`PS3X()` calls.
4. **Bump OEM revision by +1** (must exceed the firmware's — `0x02` on BIOS
   1.13/1.16/1.17 — or the override is ignored). This is required regardless of which edit wins.
5. Prefer overriding a **single small SSDT** if the culprit lives there, rather than
   shipping the whole 528 KB DSDT.

Ship the minimal necessary-and-sufficient change; record the mechanism in the
root-cause doc. Find blocks by name, not line (line numbers differ per BIOS):
```bash
grep -n 'Device (NFC0)'      patched/dsdt.dsl
grep -n 'EFUN.CRFI'          patched/dsdt.dsl
grep -n 'PS0X\|PS3X'         patched/dsdt.dsl
grep -n 'DefinitionBlock'    patched/dsdt.dsl
```

## Cross-check

After a build, check the *kinds* of changes:
```bash
grep -c 'EFUN.CRFI' patched/dsdt.dsl                      # expect 0 (toolchain-forced, step [4])
grep -c 'Device (NFC0)' patched/dsdt.dsl                  # expect 1 — we keep the device
grep -B1 'GNUM (0x0014080A)' patched/dsdt.dsl             # 1.13/1.16: nothing; 1.17: only inside _CRS
grep -c 'Name (TD_P, Package' patched/dsdt.dsl            # expect 1 (touchscreen fix)
grep -m1 DefinitionBlock patched/dsdt.dsl                 # OEM revision = firmware + 1
```
(denis-bb's reference patch instead deletes `NFC0` entirely, so its counts differ.)

## Pipeline

`build.sh` automates decompile → patch (steps [2]–[4]) → recompile → record the diff →
derive the Chinese-SKU table. Dumping the table is up to you (see Usage).
If `iasl -d` fails with `AE_ALREADY_EXISTS`, exclude the SSDT that defines
`HS03._UPC` (denis-bb's was `ssdt23.dat`; ours may differ) and re-run.

The patched DSDT carries **two** fixes (OEM rev = firmware + 1, i.e. **0x03** on
current BIOSes):

1. **DSDT load** (step [2], the original fix): delete `NFC0`'s load-time `GNUM` call so
   the table stops aborting mid-load. This is the boot-critical fix — the abort orphans
   the whole ACPI namespace (`\_SB.PC00`, the PCIe root complex, plus `GFX0`/`TCPU` and
   the USB-C SSDT), so on Ubuntu it hides the **NVMe root** (no boot) and the I2C
   **touchpad**. (It was labelled "Touchpad" after the Fedora-6.19 recon, where PCIe/NVMe
   survived the abort and only the touchpad broke — the visible casualties are
   kernel-dependent; see `../docs/dsdt-root-cause.md`.)
2. **Touchscreen** (step [2b], `inject-touchscreen-power.py`): inject the ACPI
   `PowerResource (PWRR)` + `_PR0`/`_PR3` that the OEM only wrote for the disabled
   I2C4/I2C5 sibling panels, so Linux powers the FTSC1000 panel at i2c-hid probe
   (debugged in the development notebook; the mechanism is summarised in
   `inject-touchscreen-power.py`'s comments). **Compile-flag
   caveat:** step [5] passes `iasl -on` — without it the optimizer shortens the injected
   absolute `\_SB.PC00.I2C2.TPL1.PWRR` reference to a bare `PWRR` NameSeg, which
   mis-binds to an unrelated stock `\_SB.PWRR` method at table load and silently breaks
   the device's power management.

## Directories

- `reference/` — denis-bb's `.patch` + `original/` & `patched/` `.dsl` (pulled by
  `reference/fetch.sh`). For diffing only; never boot these directly.
- `original/`  — raw `acpidump` output. **⚠️ Never committed** — `.gitignore`d because it
  includes the **MSDM** table (the machine's Windows OEM product key). `acpidump -b` emits
  MSDM alongside DSDT/SSDTs, so keep *every* raw dump out of git (see `.gitignore`).
- `patched/`   — our edited `dsdt.dsl` and compiled `dsdt.aml` (the deliverable).
