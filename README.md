# AE2 CC Monitor

ComputerCraft / CC:Tweaked monitor dashboard for an AE2 network exposed through an Advanced Peripherals ME Bridge.

## Install

Run this on the ComputerCraft computer:

```lua
delete startup.lua
wget https://raw.githubusercontent.com/crameep/ae2-cc-monitor/main/startup.lua startup.lua
reboot
```

## Update

Tap `UPD` in the top-right corner of the monitor. The script downloads the latest `startup.lua` from this repository and reboots.

Manual update:

```lua
delete startup.lua
wget https://raw.githubusercontent.com/crameep/ae2-cc-monitor/main/startup.lua startup.lua
reboot
```

## Depletion Warnings

The monitor stores usage state in `.ae2_usage_state`. It now waits for repeated confirmed drops before warning, because AE snapshots can be noisy while the system is crafting, importing, or moving items.

Tap `IGN` beside a warning to ignore that item. To clear all learned history and ignored items:

```lua
delete .ae2_usage_state
reboot
```
