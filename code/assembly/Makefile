# Makefile for ATtiny45 Binary Watch Firmware
#
# Toolchain: avra (assembler), avrdude (programmer)
# Target: ATtiny45 @ 1 MHz (8 MHz internal RC, CKDIV8)

# Project
SRC      = nerdwatch.asm
HEX      = nerdwatch.hex
EEP      = nerdwatch.eep.hex
LST      = nerdwatch.lst
OBJ      = nerdwatch.obj
COFF     = nerdwatch.cof

# Programmer — adjust for your setup
PROG     = usbtiny
MCU_AVRD = attiny45

# Fuse values
# lfuse=0x62: 8 MHz internal RC, CKDIV8 (factory default)
# hfuse=0xD7: EESAVE enabled, BOD disabled, SPIEN enabled
# efuse=0xFF: default
LFUSE    = 0x62
HFUSE    = 0xD7
EFUSE    = 0xFF

#-----------------------------------------------------------------------------
# Targets
#-----------------------------------------------------------------------------

.PHONY: all assemble flash fuses calibrate clean help

all: assemble

help:
	@echo "Targets:"
	@echo "  assemble   — Assemble source into .hex"
	@echo "  flash      — Upload .hex to ATtiny45"
	@echo "  fuses      — Program fuse bytes (requires confirmation)"
	@echo "  calibrate  — Flash firmware then show calibration instructions"
	@echo "  clean      — Remove build artifacts"

assemble: $(HEX)

$(HEX): $(SRC)
	avra -fI $(SRC)
	@echo ""
	@size=$$(wc -c < $(HEX) | tr -d ' '); \
	echo "Output: $(HEX) ($$size bytes raw hex)"; \
	if [ "$$size" -gt 1024 ]; then \
		echo "WARNING: .hex file exceeds 1 KB target"; \
	else \
		echo "OK: .hex file under 1 KB"; \
	fi

flash: $(HEX)
	avrdude -c $(PROG) -p $(MCU_AVRD) -U flash:w:$(HEX):i

fuses:
	@echo "About to program fuses for $(MCU_AVRD):"
	@echo "  lfuse = $(LFUSE)"
	@echo "  hfuse = $(HFUSE)"
	@echo "  efuse = $(EFUSE)"
	@echo ""
	@echo "WARNING: Incorrect fuses can brick the chip!"
	@read -p "Continue? [y/N] " ans; \
	if [ "$$ans" = "y" ] || [ "$$ans" = "Y" ]; then \
		avrdude -c $(PROG) -p $(MCU_AVRD) \
			-U lfuse:w:$(LFUSE):m \
			-U hfuse:w:$(HFUSE):m \
			-U efuse:w:$(EFUSE):m; \
	else \
		echo "Aborted."; \
	fi

calibrate: flash
	@echo ""
	@echo "=== WDT Calibration Mode ==="
	@echo "1. Hold the button while powering on / resetting the chip"
	@echo "2. Both LEDs will blink 4 times (calibration mode)"
	@echo "3. Release the button"
	@echo "4. Press the button to START counting (green LED turns on)"
	@echo "5. Wait exactly 5 minutes using a reference clock"
	@echo "6. Press the button to STOP counting"
	@echo "7. Calibration value saved to EEPROM"
	@echo ""
	@echo "The chip will use the calibrated WDT tick count for timekeeping."

clean:
	rm -f $(HEX) $(EEP) $(LST) $(OBJ) $(COFF)
