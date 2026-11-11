# Adaptive Battery Saver Kernel Module (SDM845 / Beryllium)

An in-kernel power optimization module for Qualcomm Snapdragon 845 (Xiaomi Poco F1 `beryllium`), providing active CPU frequency capping and dynamic big cluster core hotplugging to maximize battery longevity.

---

## Key Features

- **Zero Permanent Footprint**: When unloaded (`rmmod battery_saver`), it unhooks all notifiers, restores all offlined CPU cores, and commands `cpufreq` to recalculate policies back to original stock limits.
- **Dynamic Policy Interception**: Uses `CPUFREQ_POLICY_NOTIFIER` (`CPUFREQ_ADJUST`) to clamp frequencies directly within the kernel governor cycle, overriding aggressive boost attempts without breaking governors.
- **Intelligent Big Core Offlining**: Safely hotplugs high-power Gold cores (Cores 4-7) while guaranteeing Little cluster cores (Cores 0-3) remain available for zero system lockups.
- **Instant Sysfs Customizability**: Fine-tune individual parameters or switch presets on the fly via `/sys/module/battery_saver/parameters/`.

---

## Power Profiles

| Profile ID | Profile Name | Little Cluster (0-3) Max | Big Cluster (4-7) Max | Active Big Cores | Target Use Case |
|---|---|---|---|---|---|
| `0` | **Passthrough** | Unclamped (Stock) | Unclamped (Stock) | 4 Cores | Bypass / Monitoring only |
| `1` | **Balanced Powersave** *(Default)* | 1,209,600 kHz (1.21 GHz) | 1,574,400 kHz (1.57 GHz) | 4 Cores | Daily driver, smooth 60fps UI, ~30-40% peak power reduction |
| `2` | **Extreme Powersave** | 1,056,000 kHz (1.05 GHz) | 1,056,000 kHz (1.05 GHz) | 2 Cores (4, 5) | Social media, reading, endurance (~55-65% power reduction) |
| `3` | **Ultra Battery Saver** | 825,600 kHz (825 MHz) | 825,600 kHz (825 MHz) | 1 Core (4) | Emergency low-battery endurance |
| `4` | **Custom** | User-defined | User-defined | User-defined | Custom tuning |

---

## Runtime Usage & Sysfs Interface

All parameters are exposed in `/sys/module/battery_saver/parameters/`:

### 1. View Dashboard & Real-Time Telemetry
```bash
cat /sys/module/battery_saver/parameters/status
```
Example output:
```text
========================================
 SDM845 Adaptive Battery Saver Dashboard
========================================
 Status               : ENABLED (Active)
 Active Profile       : [1] Balanced Powersave (Smooth Daily)
 Policy Adjustments   : 1420 times enforced

 [Little Cluster: Silver (CPU 0-3)]
   Active Cores       : 4 / 4 online
   Target Limits      : 300000 kHz - 1209600 kHz

 [Big Cluster: Gold (CPU 4-7)]
   Active Cores       : 4 / 4 online
   Target Limits      : 825600 kHz - 1574400 kHz
   Offlined by module : CPU4=ON CPU5=ON CPU6=ON CPU7=ON
========================================
```

### 2. Switch Profile
```bash
# Switch to Extreme Powersave (2 big cores, lower frequency limits)
echo 2 > /sys/module/battery_saver/parameters/profile

# Switch back to Balanced
echo 1 > /sys/module/battery_saver/parameters/profile
```

### 3. Temporarily Bypass Without Unloading
```bash
# Disable restrictions (bypass mode)
echo 0 > /sys/module/battery_saver/parameters/enabled

# Re-enable restrictions
echo 1 > /sys/module/battery_saver/parameters/enabled
```

### 4. Custom Tuning
Setting any custom parameter automatically sets `profile` to `4` (Custom):
```bash
# Cap Little cluster to 1.05 GHz
echo 1056000 > /sys/module/battery_saver/parameters/little_max_freq

# Cap Big cluster to 1.36 GHz
echo 1363200 > /sys/module/battery_saver/parameters/big_max_freq

# Set only 2 big cores online
echo 2 > /sys/module/battery_saver/parameters/big_cores_online
```

---

## Load & Unload Lifecycle

### Load Module
```bash
insmod battery_saver.ko
# Or if installed in /lib/modules:
modprobe battery_saver
```

### Unload Module (Complete Stock Reversion)
```bash
rmmod battery_saver
```
Upon `rmmod`:
1. The cpufreq policy notifier unregisters immediately.
2. Any CPU cores offlined by the module are brought back online via `cpu_up`.
3. All online CPU policies are re-evaluated, immediately restoring full factory frequency ranges and governor boosts.
