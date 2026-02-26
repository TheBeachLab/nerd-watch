# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Arduino-based binary wristwatch (Kokopelli 0.05 port of Sam DeRose's Nerd Watch). Displays time by flashing two LEDs in 4-bit binary: green LED = 1, yellow LED = 0. Hours (1-12) shown first, then minutes in 5-minute increments (0-12). A planned Assembly port aims to improve battery life beyond the Arduino version's ~3 days.

## Build & Upload

This is an Arduino project — open `code/arduino/NerdWatch.ino` in Arduino IDE to compile and upload. No Makefile or CLI build system exists. Target MCU: ATmega328P.

## Architecture

All Arduino source lives in `code/arduino/`:

- **NerdWatch.ino** — Main sketch. Contains `BitDisplayer` (state machine for non-blocking 4-bit LED sequences) and the top-level state machine (`OFF → DISPLAYING_HOUR → DISPLAYING_MINUTE → OFF`). The main `loop()` calls `Update()` on all objects each iteration — no blocking delays.
- **Clock.h/cpp** — Timekeeping using `millis()` with overflow handling. Tracks hours (1-12), minutes, seconds, AM/PM.
- **LED.h/cpp** — PWM-based LED control with multiple modes (OFF, ON, SMOOTH_ON/OFF, THROB, BLINK, MOMENTARY). 20-tick PWM cycle, 0-255 intensity. Supports active-high and active-low logic.
- **Button.h/cpp** — Debounced button input (5ms settling). Detects press/release/state changes via three-state debounce (open → indeterminate → closed).

## Hardware Pins

| Pin | Function |
|-----|----------|
| 0   | Button (internal pull-up, active low) |
| 1   | Yellow LED (binary 0) |
| 2   | Green LED (binary 1) |

## Key Design Constraints

- **Low power**: ADC disabled, LED intensity capped at 64/255 (~25%) to conserve battery.
- **Non-blocking**: All timing uses `millis()` deltas — never use `delay()`.
- **Active-low LEDs**: Both LEDs configured with `SetIsOnWhenHigh(false)`.

## Assembly Build & Flash (ATtiny45)

Requires `avra` (assembler) and `avrdude` (programmer). From `code/assembly/`:

```bash
make assemble    # Build .hex from nerdwatch.asm
make fuses       # Program fuses (lfuse=0x62 hfuse=0xD7 efuse=0xFF) — prompts for confirmation
make flash       # Upload .hex to ATtiny45 via USBtiny programmer
make calibrate   # Flash + print WDT calibration instructions
make clean       # Remove build artifacts
```

Edit `PROG` in the Makefile to match your programmer (default: `usbtiny`).

## Other Directories

- `kokopelli_circuit/` — `.cad` files for the PCB (Kokopelli 0.05 format)
- `milling_images/` — PNG traces/holes/cutout for Fab Modules PCB milling; `.xcf` GIMP sources for artwork customization
- `code/assembly/` — ATtiny45 assembly firmware (`nerdwatch.asm`) with WDT-based timekeeping, power-down sleep (~4.5 uA), EEPROM calibration, and Makefile build system
