# DSDT workflow

Goal: produce a corrected `patched/dsdt.aml` built from **this machine's own** ACPI
tables, then load it via initrd override. We do **not** trust the prebuilt v1.13
binary, and we do **not** blindly replicate denis-bb's patch — see
[`../docs/dsdt-root-cause.md`](../docs/dsdt-root-cause.md) for why (his patch mixes
~14 cosmetic/toolchain edits with 1–2 genuine ones and mis-states the mechanism).

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
4. **Bump OEM revision by +1** (must exceed firmware's `0x02`, or the override is
   ignored). This is required regardless of which edit wins.
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

After editing, diff the *kinds* of changes against the reference patch:
```bash
diff <(grep -c 'EFUN.CRFI' reference/patched/dsdt.global.dsl) \
     <(grep -c 'EFUN.CRFI' patched/dsdt.dsl)   # both should be 0
grep -c 'Device (NFC0)' patched/dsdt.dsl        # expect 0
```

## Pipeline

`build.sh` automates dump → decompile → (manual edit) → recompile → validate.
If `iasl -d` fails with `AE_ALREADY_EXISTS`, exclude the SSDT that defines
`HS03._UPC` (denis-bb's was `ssdt23.dat`; ours may differ) and re-run.

The patched DSDT now carries **two** fixes (OEM rev **0x03**):

1. **Touchpad** (step [2], the original fix): delete `NFC0`'s load-time `GNUM` call so
   the table load no longer aborts.
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
- `original/`  — `acpidump` output from this machine (gitignored if large).
- `patched/`   — our edited `dsdt.dsl` and compiled `dsdt.aml` (the deliverable).
