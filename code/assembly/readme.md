# Assembly nerd's watch

## Why Assembly

The Arduino code only has a small glitch. It is so inefficient that the battery only lasts for 3 days. The main loop runs continuously with no sleep, burning through a CR2032 in no time. So I rewrote the nerd's watch code from scratch in AVR Assembly targeting the ATtiny45. The result: **~2 years of battery life** instead of ~3 days.

## How it works

The watch spends 99.99% of its time in power-down sleep, drawing only ~4.5 uA. Two things wake it up:

1. **Watchdog Timer (WDT)** fires every ~8 seconds to keep time
2. **Button press** (pin change interrupt on PB0) to display the time

### Timekeeping

Instead of counting individual clock cycles with a prescaler, the firmware counts WDT ticks. The WDT runs off its own 128 kHz oscillator independently of the CPU. Every ~8 seconds the WDT interrupt fires, increments a tick counter, and goes right back to sleep. After `ticks_per_5min` ticks (default 37, calibratable), a 5-minute block rolls over.

Only three values are tracked:

| Register | Range | Purpose |
|----------|-------|---------|
| `tick_count` | 0 to ticks_per_5min-1 | WDT ticks since last 5-min rollover |
| `five_min` | 0-11 | 5-minute block within the hour |
| `hours` | 1-12 | Current hour |

The tick counter uses `sub` instead of `clr` on rollover, carrying any fractional remainder to eliminate cumulative drift.

### Telling the time

Press the button and the watch blinks 2 sequences of 4 bits (MSB first):

- **Green LED** = binary 1
- **Yellow LED** = binary 0

For example, `0110 1001` means:
- Hours: `0+4+2+0 = 6`
- Minutes: `1+0+0+1 = 9`, and `9 x 5 = 45`
- Time is **6:45**

Timing: 500ms per bit, 100ms gap between bits, 500ms gap between hour and minute groups.

### Time setting

On every power-on (without holding the button), the watch enters time-setting mode:

1. Both LEDs blink twice to signal mode entry
2. **Set hours**: current value blinks in binary, press button to increment, wait 4 seconds to confirm
3. Both LEDs blink once to signal transition
4. **Set minutes**: same as hours (sets 5-minute blocks, 0-11)
5. Both LEDs blink twice to confirm

### WDT Calibration

The WDT oscillator varies chip-to-chip. For accurate timekeeping, calibrate it:

1. Hold the button while powering on / resetting
2. Both LEDs blink 4 times (calibration mode entered)
3. Release the button
4. Press to **start** counting (green LED turns on)
5. Wait exactly **5 minutes** using a reference clock
6. Press to **stop** counting
7. The raw tick count is saved to EEPROM and used for all future timekeeping

## Hardware

Target: **ATtiny45** @ 1 MHz (8 MHz internal RC with CKDIV8)

| Pin | Function |
|-----|----------|
| PB0 (pin 5) | Button input, internal pull-up, active-low |
| PB1 (pin 6) | Yellow LED (binary 0), active-low |
| PB2 (pin 7) | Green LED (binary 1), active-low |
| PB3, PB4 | Output LOW (unused, prevent floating) |
| PB5 | RESET, external pull-up |

## Power budget

| State | Current | Duty |
|-------|---------|------|
| Power-down + WDT | ~4.5 uA | 99.99% |
| Display active (1 MHz + LED) | ~5.3 mA | ~106 s/day |
| **Average** | **~11 uA** | **~2 years on CR2032** |

## Fuse settings

| Fuse | Value | Key bits |
|------|-------|----------|
| lfuse | `0x62` | 8 MHz internal RC, CKDIV8 enabled (factory default) |
| hfuse | `0xD7` | EESAVE enabled (preserves calibration across flashes), BOD disabled |
| efuse | `0xFF` | Default |

## Build and flash

Requires [avra](https://github.com/Ro5bert/avra) (assembler) and [avrdude](https://github.com/avrdudes/avrdude) (programmer).

```bash
make assemble    # Build .hex from nerdwatch.asm
make flash       # Upload .hex to ATtiny45
make fuses       # Program fuse bytes (prompts for confirmation)
make calibrate   # Flash + print calibration instructions
make clean       # Remove build artifacts
```

Edit `PROG` in the Makefile to match your programmer (default: `usbtiny`).

## File size

The firmware compiles to under 1 KB of flash (~15% of the ATtiny45's 4 KB). Compare that to the Arduino version which needs an ATmega328P.
