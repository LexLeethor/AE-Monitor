# AE2 CC Monitor

ComputerCraft / CC:Tweaked monitor dashboard for an AE2 network exposed through an Advanced Peripherals ME Bridge.

## Install

Run this on the ComputerCraft computer:

```lua
delete startup.lua
wget https://raw.githubusercontent.com/lexleethor/ae-monitor/main/startup.lua startup.lua
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

## Multiple Monitors

If you build one connected monitor wall, CC:Tweaked exposes it as one big monitor automatically.

If you attach separate monitors, the script renders the same dashboard to every monitor peripheral it can find. `UPD` and `IGN` touch buttons work on the monitor you tap.

## Distance Readability

The script uses larger monitor text when the attached display has enough room, and falls back to compact text on small monitors. Bar labels include current/total values beside the percentage so the main status is readable from farther away.

Only true capacity sections use bars. The top stored items list uses plain names and counts so it does not look like another capacity meter. Items without a real stored amount are ignored; stack/pattern `size` is not counted as inventory.

## Bulk Cell Markers

The biggest stored items list shows a `BULK` marker when the script can associate that item with a bulk storage cell. Auto-detection uses the data exposed by Advanced Peripherals `listCells()`, which may not include the stored/partitioned item on every pack version.

Tap `B+` beside a top item to manually mark it as bulk-backed. Tap `BULK` again to remove a manual marker. Manual markers persist in `.ae2_bulk_items`.

Tap the top `[-] AE2 SYSTEM` header to collapse the large dashboard into a compact health summary; tap `[+] AE2 SUMMARY` to expand it again. Tap `PREV` / `NEXT` in the biggest stored items header to page through stored items when the list is longer than the monitor. Tap section headers marked `[-]` to collapse them and `[+]` to expand them again.

You can also edit `.ae2_bulk_items` beside `startup.lua` directly and put one item id or display name per line:

```lua
edit .ae2_bulk_items
```

Example contents:

```text
minecraft:cobblestone
minecraft:netherrack
iron ingot
```

## Depletion Warnings

The monitor stores usage state in `.ae2_usage_state`. It now waits for repeated confirmed drops before warning, because AE snapshots can be noisy while the system is crafting, importing, or moving items.

`RECENT USE` is a softer, faster panel. It still needs repeated sampled drops, but it is not treated as a depletion warning. AE storage-cell/spatial items are filtered out of watch panels because they tend to create misleading noise.

Tap `IGN` beside a warning to ignore that item. To clear all learned history and ignored items:

```lua
delete .ae2_usage_state
reboot
```
