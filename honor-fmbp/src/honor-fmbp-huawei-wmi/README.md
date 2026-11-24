# huawei-wmi with HONOR FMB-P hotkeys (DKMS)

`huawei-wmi.c` is mainline `drivers/platform/x86/huawei-wmi.c` at **v7.0** (the Ubuntu
26.04 kernel) with [`fmbp-keymap.patch`](fmbp-keymap.patch) applied, nothing else. The
keymap additions come from colorcube's Fedora collection
([fixes/huawei-wmi-dkms](https://github.com/colorcube/Linux-on-Honor-Magicbook-14-Pro/tree/main/fixes/huawei-wmi-dkms)),
based on egormanga's assignments (aymanbagabas/Huawei-WMI#93) and tsukasagenesis' port.

| WMI code | Effect |
|---|---|
| `0x283` / `0x2a3` | F3: `KEY_TOUCHPAD_ON` / `KEY_TOUCHPAD_OFF` |
| `0x288` | F8: `KEY_CAMERA_ACCESS_TOGGLE` |
| `0x2a0` / `0x2a1` / `0x2a6` | Fn+P (balanced / performance / rejected): `KEY_PROG1` |
| `0x2a7` | Fn+R: `KEY_REFRESH_RATE_TOGGLE` |
| `0x2e0` / `0x2e1` | camera module enable / disable |
| `0x2b1`–`0x2b4`, `0x2e5`–`0x2e8` | EC notifications (keyboard backlight, auto-backlight), ignored instead of logged as "Unknown key pressed" |

Regenerate for another kernel (then adjust `BUILD_EXCLUSIVE_KERNEL` in `dkms.conf`):

```sh
curl -o huawei-wmi.c https://raw.githubusercontent.com/torvalds/linux/vX.Y/drivers/platform/x86/huawei-wmi.c
patch huawei-wmi.c < fmbp-keymap.patch
```
