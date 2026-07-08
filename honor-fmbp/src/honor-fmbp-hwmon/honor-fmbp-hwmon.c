// SPDX-License-Identifier: GPL-2.0
/*
 * honor-fmbp-hwmon - fan tachometer readout for the HONOR MagicBook Pro 14 (FMB-P).
 *
 * The EC exposes two fan speeds as little-endian 16-bit RPM words in EC RAM
 * (reverse-engineered + verified on this unit under load):
 *   fan1 = LE16 @ 0x2C,  fan2 = LE16 @ 0x2E   (0 when the fan is off/idle)
 * Read-only via the kernel EC API; fan *control* stays with the EC. DMI-gated
 * to HONOR/FMB-P. Exposes a standard hwmon device so `sensors` shows the RPM.
 */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/platform_device.h>
#include <linux/hwmon.h>
#include <linux/acpi.h>
#include <linux/dmi.h>

#define FAN1_LSB 0x2C
#define FAN2_LSB 0x2E

static int read_fan_rpm(u8 lsb, long *val)
{
	u8 lo, hi;
	int ret;

	ret = ec_read(lsb, &lo);
	if (ret)
		return ret;
	ret = ec_read(lsb + 1, &hi);
	if (ret)
		return ret;
	*val = lo | (hi << 8);
	return 0;
}

static umode_t honor_hwmon_is_visible(const void *data, enum hwmon_sensor_types type,
				      u32 attr, int channel)
{
	if (type == hwmon_fan && attr == hwmon_fan_input)
		return 0444;
	return 0;
}

static int honor_hwmon_read(struct device *dev, enum hwmon_sensor_types type,
			    u32 attr, int channel, long *val)
{
	if (type != hwmon_fan || attr != hwmon_fan_input)
		return -EOPNOTSUPP;
	switch (channel) {
	case 0:
		return read_fan_rpm(FAN1_LSB, val);
	case 1:
		return read_fan_rpm(FAN2_LSB, val);
	default:
		return -EINVAL;
	}
}

static const struct hwmon_ops honor_hwmon_ops = {
	.is_visible = honor_hwmon_is_visible,
	.read = honor_hwmon_read,
};

static const struct hwmon_channel_info * const honor_hwmon_info[] = {
	HWMON_CHANNEL_INFO(fan, HWMON_F_INPUT, HWMON_F_INPUT),
	NULL
};

static const struct hwmon_chip_info honor_chip_info = {
	.ops = &honor_hwmon_ops,
	.info = honor_hwmon_info,
};

static struct platform_device *pdev;

static const struct dmi_system_id honor_fmbp[] = {
	{ .matches = {
		DMI_MATCH(DMI_SYS_VENDOR, "HONOR"),
		DMI_MATCH(DMI_PRODUCT_NAME, "FMB-P"),
	} },
	{ }
};

static int __init honor_hwmon_init(void)
{
	struct device *hwmon;

	if (!dmi_check_system(honor_fmbp)) {
		pr_info("honor-fmbp-hwmon: not a HONOR FMB-P, skipping\n");
		return -ENODEV;
	}
	pdev = platform_device_register_simple("honor-fmbp-hwmon", -1, NULL, 0);
	if (IS_ERR(pdev))
		return PTR_ERR(pdev);
	hwmon = devm_hwmon_device_register_with_info(&pdev->dev, "honor_fmbp",
						     NULL, &honor_chip_info, NULL);
	if (IS_ERR(hwmon)) {
		platform_device_unregister(pdev);
		return PTR_ERR(hwmon);
	}
	pr_info("honor-fmbp-hwmon: registered fan1/fan2 (EC 0x2C/0x2E)\n");
	return 0;
}

static void __exit honor_hwmon_exit(void)
{
	platform_device_unregister(pdev);
}

module_init(honor_hwmon_init);
module_exit(honor_hwmon_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Fan tachometer readout for HONOR MagicBook Pro 14 (FMB-P)");
MODULE_AUTHOR("MagicBook Linux project");
