;=============================================================================
; nerdwatch.asm — ATtiny45 Binary Watch Firmware
;
; Displays time by flashing two LEDs in 4-bit binary.
; Green LED = 1, Yellow LED = 0.
; Hours (1-12) shown first, then minutes in 5-min blocks (0-11).
;
; Timekeeping via WDT interrupt (~8s period).
; Sleeps in power-down mode between events (~4.5 uA).
; Button press (PCINT0 on PB0) wakes to display time.
;
; Target: ATtiny45 @ 1 MHz (8 MHz internal RC, CKDIV8)
; Fuses: lfuse=0x62 hfuse=0xD7 efuse=0xFF
;=============================================================================

.include "tn45def.inc"

;-----------------------------------------------------------------------------
; Constants
;-----------------------------------------------------------------------------
.equ YELLOW_PIN     = PB1       ; LED for binary 0 (active-low)
.equ GREEN_PIN      = PB2       ; LED for binary 1 (active-low)
.equ BUTTON_PIN     = PB0       ; Button input (active-low, pull-up)

.equ LED_MASK       = (1<<YELLOW_PIN)|(1<<GREEN_PIN)

.equ DEFAULT_TICKS  = 37        ; WDT ticks per 5 minutes (8.0s * 37 = 296s)
.equ EEPROM_CAL     = 0x00      ; EEPROM address for calibration value

; Delay counts for 1 MHz clock (4 cycles per inner loop iteration)
; 500ms = 500000 cycles. Outer*256*4 ~ 500000 => Outer ~ 488 ~ use 244 with
; nested triple loop. We use a simple 16-bit delay approach.
.equ DELAY_500MS_H  = 3         ; ~500ms: outer loop high byte
.equ DELAY_500MS_L  = 13        ; ~500ms: outer loop low byte
.equ DELAY_100MS_H  = 0         ; ~100ms: outer loop high byte
.equ DELAY_100MS_L  = 155       ; ~100ms: outer loop low byte
.equ DELAY_20MS_H   = 0         ; ~20ms debounce
.equ DELAY_20MS_L   = 31        ; ~20ms debounce

;-----------------------------------------------------------------------------
; Register aliases
;-----------------------------------------------------------------------------
.def zero           = r2        ; Always 0
.def tick_count     = r3        ; WDT ticks since last 5-min rollover
.def five_min       = r4        ; 5-minute block (0-11)
.def hours          = r5        ; Hours (1-12)
.def ticks_per_5min = r6        ; Calibration: WDT ticks per 5 minutes
.def temp           = r16       ; General purpose (upper reg for immediate ops)
.def temp2          = r17       ; General purpose
.def bit_count      = r18       ; Bit counter for display
.def display_val    = r19       ; Value being displayed
.def delay_h        = r20       ; Delay counter high
.def delay_l        = r21       ; Delay counter low
.def inner          = r22       ; Inner delay counter
.def flags          = r23       ; Bit flags
; flags bit 0: wdt_fired
; flags bit 1: button_pressed
; flags bit 2: calibration mode

.equ FLAG_WDT       = 0
.equ FLAG_BTN       = 1
.equ FLAG_CAL       = 2

;=============================================================================
; Interrupt vectors (ATtiny45: 15 vectors, 1 word each)
;=============================================================================
.org 0x0000
    rjmp    reset               ; RESET
.org 0x0001
    reti                        ; INT0
.org 0x0002
    rjmp    pcint0_isr          ; PCINT0 — button press
.org 0x0003
    reti                        ; TIMER1_COMPA
.org 0x0004
    reti                        ; TIMER1_OVF
.org 0x0005
    reti                        ; TIMER0_OVF
.org 0x0006
    reti                        ; EE_RDY
.org 0x0007
    reti                        ; ANA_COMP
.org 0x0008
    reti                        ; ADC
.org 0x0009
    reti                        ; TIMER1_COMPB
.org 0x000A
    reti                        ; TIMER0_COMPA
.org 0x000B
    reti                        ; TIMER0_COMPB
.org 0x000C
    rjmp    wdt_isr             ; WDT
.org 0x000D
    reti                        ; USI_START
.org 0x000E
    reti                        ; USI_OVF

;=============================================================================
; WDT Interrupt Service Routine
;=============================================================================
wdt_isr:
    sbr     flags, (1<<FLAG_WDT)
    reti

;=============================================================================
; PCINT0 Interrupt Service Routine (button press wakeup)
;=============================================================================
pcint0_isr:
    sbr     flags, (1<<FLAG_BTN)
    reti

;=============================================================================
; RESET — Entry point
;=============================================================================
reset:
    ; Init stack pointer
    ldi     temp, low(RAMEND)
    out     SPL, temp

    ; Clear zero register
    clr     zero

    ; Init flags
    clr     flags

    ;--- GPIO setup ---
    ; PB0 = input (button), PB1/PB2 = output (LEDs), PB3/PB4 = output low
    ; PB5 = input (RESET, external pull-up)
    ldi     temp, (1<<PB1)|(1<<PB2)|(1<<PB3)|(1<<PB4)
    out     DDRB, temp

    ; LEDs off (active-low: set high), pull-up on PB0, PB3/PB4 low
    ldi     temp, (1<<YELLOW_PIN)|(1<<GREEN_PIN)|(1<<BUTTON_PIN)
    out     PORTB, temp

    ;--- Disable unused peripherals for power savings ---
    ; Disable ADC
    in      temp2, ADCSRA
    andi    temp2, ~(1<<ADEN)
    out     ADCSRA, temp2

    ; Shut down all peripherals via PRR
    ldi     temp, (1<<PRTIM0)|(1<<PRTIM1)|(1<<PRUSI)|(1<<PRADC)
    out     PRR, temp

    ;--- Read calibration from EEPROM ---
    rcall   eeprom_read_cal
    mov     ticks_per_5min, temp
    cpi     temp, 0             ; If EEPROM is 0xFF (erased) or 0, use default
    brne    cal_check_ff
    ldi     temp, DEFAULT_TICKS
    mov     ticks_per_5min, temp
    rjmp    cal_done
cal_check_ff:
    cpi     temp, 0xFF
    brne    cal_done
    ldi     temp, DEFAULT_TICKS
    mov     ticks_per_5min, temp
cal_done:

    ;--- Init time registers ---
    clr     tick_count
    clr     five_min
    ldi     temp, 12
    mov     hours, temp

    ;--- Setup WDT for ~8s interrupt ---
    rcall   wdt_setup

    ;--- Enable PCINT0 on PB0 ---
    ldi     temp, (1<<PCINT0)
    out     PCMSK, temp
    ldi     temp, (1<<PCIE)
    out     GIMSK, temp

    ; Enable global interrupts
    sei

    ;--- Check if button held at power-on for calibration ---
    sbic    PINB, BUTTON_PIN    ; Skip if button pressed (low)
    rjmp    no_calibration

    ; Debounce
    rcall   delay_20ms
    sbic    PINB, BUTTON_PIN
    rjmp    no_calibration

    ; Button held — enter calibration mode
    rcall   calibrate
    rjmp    main_loop

no_calibration:
    ;--- Time setting mode ---
    rcall   set_time

;=============================================================================
; Main loop — sleep, handle WDT ticks and button presses
;=============================================================================
main_loop:
    ; Prepare for power-down sleep
    ; MCUCR: SE=1, SM1:SM0 = 10 (power-down)
    ldi     temp, (1<<SE)|(1<<SM1)
    out     MCUCR, temp

    sleep                       ; Zzz... wakes on WDT or PCINT0

    ; Disable sleep (safety)
    ldi     temp, 0
    out     MCUCR, temp

    ;--- Handle WDT tick ---
    sbrs    flags, FLAG_WDT
    rjmp    check_button

    cbr     flags, (1<<FLAG_WDT)

    ; Re-enable WDT interrupt (WDIE is cleared after each ISR!)
    rcall   wdt_re_enable

    ; Increment tick counter
    inc     tick_count

    ; Check if 5 minutes elapsed
    cp      tick_count, ticks_per_5min
    brlo    check_button

    ; 5-minute rollover: subtract (preserves fractional remainder)
    sub     tick_count, ticks_per_5min

    ; Increment 5-minute block
    inc     five_min
    ldi     temp, 12
    cp      five_min, temp
    brlo    check_button

    ; Hour rollover
    clr     five_min
    inc     hours
    ldi     temp, 13
    cp      hours, temp
    brlo    check_button
    ldi     temp, 1
    mov     hours, temp

check_button:
    sbrs    flags, FLAG_BTN
    rjmp    main_loop

    cbr     flags, (1<<FLAG_BTN)

    ; Debounce — wait for button release
    rcall   delay_20ms
    sbic    PINB, BUTTON_PIN    ; If button already released, might be glitch
    rjmp    main_loop           ; Ignore glitch

    ; Wait for button release
btn_release_wait:
    rcall   delay_20ms
    sbis    PINB, BUTTON_PIN
    rjmp    btn_release_wait

    ; Display time
    rcall   display_time

    rjmp    main_loop

;=============================================================================
; display_time — Blink hours then minutes in 4-bit binary
;=============================================================================
display_time:
    ; Display hours (4 bits, MSB first)
    mov     display_val, hours
    rcall   display_4bits

    ; 500ms gap between hour and minute groups
    rcall   delay_500ms

    ; Display 5-minute blocks (4 bits, MSB first)
    mov     display_val, five_min
    rcall   display_4bits

    ret

;=============================================================================
; display_4bits — Blink 4 bits of display_val, MSB first
;   Green LED = 1, Yellow LED = 0 (both active-low)
;=============================================================================
display_4bits:
    ldi     bit_count, 4

disp_next_bit:
    ; Turn off both LEDs first (set high = off for active-low)
    in      temp, PORTB
    ori     temp, LED_MASK
    out     PORTB, temp

    ; Check bit 3 (MSB of lower nibble)
    sbrc    display_val, 3
    rjmp    disp_one
    rjmp    disp_zero

disp_one:
    ; Green LED on (active-low: clear bit)
    cbi     PORTB, GREEN_PIN
    rjmp    disp_wait

disp_zero:
    ; Yellow LED on (active-low: clear bit)
    cbi     PORTB, YELLOW_PIN

disp_wait:
    rcall   delay_500ms

    ; Turn off both LEDs
    in      temp, PORTB
    ori     temp, LED_MASK
    out     PORTB, temp

    ; Shift display_val left for next bit
    lsl     display_val

    ; Inter-bit gap
    rcall   delay_100ms

    dec     bit_count
    brne    disp_next_bit

    ret

;=============================================================================
; set_time — Set hours and minutes on power-on
;   Both LEDs blink to signal mode entry.
;   Button press increments value. 4-second timeout confirms.
;=============================================================================
set_time:
    ; Signal: blink both LEDs twice
    rcall   blink_both
    rcall   blink_both

    ;--- Set hours ---
    ldi     temp, 1
    mov     hours, temp

set_hour_loop:
    ; Display current hour value
    mov     display_val, hours
    rcall   display_4bits

    ; Wait for button press or timeout (~4 seconds = 8 * 500ms)
    ldi     temp2, 8
set_hour_wait:
    rcall   delay_500ms
    sbis    PINB, BUTTON_PIN    ; Button pressed? (active-low)
    rjmp    set_hour_pressed
    dec     temp2
    brne    set_hour_wait

    ; Timeout — confirm hours
    rjmp    set_hour_done

set_hour_pressed:
    ; Debounce
    rcall   delay_20ms
    ; Wait for release
set_hour_release:
    sbis    PINB, BUTTON_PIN
    rjmp    set_hour_release
    rcall   delay_20ms

    ; Increment hours
    inc     hours
    ldi     temp, 13
    cp      hours, temp
    brlo    set_hour_loop
    ldi     temp, 1
    mov     hours, temp
    rjmp    set_hour_loop

set_hour_done:
    ; Signal transition: blink both LEDs once
    rcall   blink_both

    ;--- Set minutes ---
    clr     five_min

set_min_loop:
    ; Display current minute block
    mov     display_val, five_min
    rcall   display_4bits

    ; Wait for button press or timeout (~4 seconds)
    ldi     temp2, 8
set_min_wait:
    rcall   delay_500ms
    sbis    PINB, BUTTON_PIN
    rjmp    set_min_pressed
    dec     temp2
    brne    set_min_wait

    ; Timeout — confirm minutes
    rjmp    set_min_done

set_min_pressed:
    rcall   delay_20ms
set_min_release:
    sbis    PINB, BUTTON_PIN
    rjmp    set_min_release
    rcall   delay_20ms

    inc     five_min
    ldi     temp, 12
    cp      five_min, temp
    brlo    set_min_loop
    clr     five_min
    rjmp    set_min_loop

set_min_done:
    ; Confirmation: blink both LEDs twice
    rcall   blink_both
    rcall   blink_both

    ; Reset tick counter for fresh start
    clr     tick_count

    ret

;=============================================================================
; calibrate — WDT calibration mode
;   Hold button at power-on to enter.
;   Press to start counting WDT ticks.
;   Wait exactly 5 minutes by reference clock.
;   Press to stop. Raw count saved to EEPROM.
;=============================================================================
calibrate:
    ; Signal calibration mode: rapid blink 4 times
    rcall   blink_both
    rcall   blink_both
    rcall   blink_both
    rcall   blink_both

    ; Wait for button release from power-on hold
cal_wait_release1:
    rcall   delay_20ms
    sbis    PINB, BUTTON_PIN
    rjmp    cal_wait_release1

    ; Wait for "start" button press
cal_wait_start:
    sbic    PINB, BUTTON_PIN
    rjmp    cal_wait_start
    rcall   delay_20ms
    ; Wait for release
cal_start_release:
    sbis    PINB, BUTTON_PIN
    rjmp    cal_start_release
    rcall   delay_20ms

    ; Green LED on to indicate counting
    cbi     PORTB, GREEN_PIN

    ; Clear tick counter and WDT flag
    clr     tick_count
    cbr     flags, (1<<FLAG_WDT)

    ; Count WDT ticks until "stop" button press
cal_count_loop:
    ; Sleep in power-down, wake on WDT
    ldi     temp, (1<<SE)|(1<<SM1)
    out     MCUCR, temp
    sleep
    ldi     temp, 0
    out     MCUCR, temp

    ; Handle WDT tick
    sbrs    flags, FLAG_WDT
    rjmp    cal_check_btn
    cbr     flags, (1<<FLAG_WDT)
    rcall   wdt_re_enable
    inc     tick_count

cal_check_btn:
    ; Check for stop button press
    sbic    PINB, BUTTON_PIN
    rjmp    cal_count_loop      ; Not pressed, keep counting

    ; Button pressed — stop
    rcall   delay_20ms

    ; Green LED off
    sbi     PORTB, GREEN_PIN

    ; Store tick_count to EEPROM
    mov     temp, tick_count
    rcall   eeprom_write_cal

    ; Update running calibration
    mov     ticks_per_5min, tick_count

    ; Wait for release
cal_stop_release:
    sbis    PINB, BUTTON_PIN
    rjmp    cal_stop_release
    rcall   delay_20ms

    ; Signal done: blink both LEDs twice
    rcall   blink_both
    rcall   blink_both

    ret

;=============================================================================
; blink_both — Blink both LEDs on for 200ms then off for 200ms
;=============================================================================
blink_both:
    ; Both LEDs on (active-low: clear bits)
    cbi     PORTB, GREEN_PIN
    cbi     PORTB, YELLOW_PIN

    rcall   delay_100ms
    rcall   delay_100ms

    ; Both LEDs off (active-low: set bits)
    sbi     PORTB, GREEN_PIN
    sbi     PORTB, YELLOW_PIN

    rcall   delay_100ms
    rcall   delay_100ms

    ret

;=============================================================================
; WDT setup — Configure WDT for ~8s interrupt mode
;=============================================================================
wdt_setup:
    cli
    wdr

    ; Timed sequence: set WDCE and WDE within 4 cycles
    in      temp, WDTCR
    ori     temp, (1<<WDCE)|(1<<WDE)
    out     WDTCR, temp

    ; Set WDT prescaler to ~8s (WDP3:0 = 1001) and interrupt mode (WDIE=1, WDE=0)
    ldi     temp, (1<<WDIE)|(1<<WDP3)|(1<<WDP0)
    out     WDTCR, temp

    sei
    ret

;=============================================================================
; wdt_re_enable — Re-enable WDIE (cleared automatically after each WDT ISR)
;=============================================================================
wdt_re_enable:
    cli

    ; Timed sequence
    in      temp, WDTCR
    ori     temp, (1<<WDCE)|(1<<WDE)
    out     WDTCR, temp

    ; Re-enable interrupt mode, same prescaler
    ldi     temp, (1<<WDIE)|(1<<WDP3)|(1<<WDP0)
    out     WDTCR, temp

    sei
    ret

;=============================================================================
; Delay routines — Busy-wait loops at 1 MHz
;
; Each inner iteration: dec(1) + brne(2/1) = 3 cycles when taken
; Outer: dec(1) + brne(2) + inner(256*3) = 771 cycles per outer
; For 16-bit outer (delay_h:delay_l):
;   Total cycles ~ (delay_h * 256 + delay_l) * 771
;
; delay_500ms: 3*256+13 = 781 outer => 781*771 = ~602,000 cycles (~602ms)
;   Fine-tune: adjust delay_l as needed for accuracy
; delay_100ms: 0*256+155 = 155 outer => 155*771 = ~119,500 (~120ms)
; delay_20ms:  0*256+31 = 31 outer => 31*771 = ~23,900 (~24ms)
;=============================================================================
delay_500ms:
    push    delay_h
    push    delay_l
    ldi     delay_h, DELAY_500MS_H
    ldi     delay_l, DELAY_500MS_L
    rjmp    delay_common

delay_100ms:
    push    delay_h
    push    delay_l
    ldi     delay_h, DELAY_100MS_H
    ldi     delay_l, DELAY_100MS_L
    rjmp    delay_common

delay_20ms:
    push    delay_h
    push    delay_l
    ldi     delay_h, DELAY_20MS_H
    ldi     delay_l, DELAY_20MS_L

delay_common:
    push    inner

delay_outer:
    ldi     inner, 0            ; 256 iterations (0 wraps)
delay_inner:
    dec     inner
    brne    delay_inner

    ; Decrement 16-bit counter (delay_h:delay_l)
    subi    delay_l, 1
    sbci    delay_h, 0
    brcc    delay_outer         ; Loop while >= 0

    pop     inner
    pop     delay_l
    pop     delay_h
    ret

;=============================================================================
; EEPROM routines
;=============================================================================

; eeprom_read_cal — Read calibration byte from EEPROM addr 0 into temp
eeprom_read_cal:
    sbic    EECR, EEPE         ; Wait for previous write
    rjmp    eeprom_read_cal
    ldi     temp, 0
    out     EEARL, temp         ; Address 0
    sbi     EECR, EERE         ; Start read
    in      temp, EEDR         ; Read data
    ret

; eeprom_write_cal — Write temp to EEPROM addr 0
eeprom_write_cal:
    sbic    EECR, EEPE         ; Wait for previous write
    rjmp    eeprom_write_cal
    ldi     temp2, 0
    out     EEARL, temp2        ; Address 0
    out     EEDR, temp          ; Data
    cli
    sbi     EECR, EEMPE        ; Master enable
    sbi     EECR, EEPE         ; Start write
    sei
    ret
