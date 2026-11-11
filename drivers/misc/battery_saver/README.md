# Built-in Adaptive Battery Saver (SDM845 / Beryllium)

This driver is compiled directly into the Xiaomi Poco F1 kernel image. It
limits CPU frequency policies and manages the SDM845 Gold CPU cores to reduce
battery consumption.

## Kernel configuration

Enable the driver in the Beryllium kernel configuration:

```text
CONFIG_CPU_FREQ=y
CONFIG_HOTPLUG_CPU=y
CONFIG_SMP=y
CONFIG_BATTERY_SAVER=y
```

The driver initializes during boot and does not support `modprobe`, `insmod`,
or `rmmod`. Runtime controls are exposed at:

```text
/sys/module/battery_saver/parameters/
```

## Runtime controls

```bash
cat /sys/module/battery_saver/parameters/status
echo 1 > /sys/module/battery_saver/parameters/profile   # Balanced
echo 2 > /sys/module/battery_saver/parameters/profile   # Extreme
echo 3 > /sys/module/battery_saver/parameters/profile   # Ultra
echo 0 > /sys/module/battery_saver/parameters/enabled   # Bypass
echo 1 > /sys/module/battery_saver/parameters/enabled   # Enable
```

Custom values automatically select profile `4`:

```bash
echo 1056000 > /sys/module/battery_saver/parameters/little_max_freq
echo 1363200 > /sys/module/battery_saver/parameters/big_max_freq
echo 2 > /sys/module/battery_saver/parameters/big_cores_online
```

At least one Gold core is always kept online.

## `batsave`

Install the userspace wrapper from the kernel tree's companion project into
`/usr/local/bin/batsave`. It only accepts known parameters and requires root
for mutations:

```bash
batsave status
batsave profile balanced
batsave set little_max_freq 1056000
batsave disable
batsave enable
```
