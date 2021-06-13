.syntax unified
.fpu fpv4-sp-d16
.include "src/libcomp2300/macros.S"
.global EXTI0_IRQHandler, EXTI1_IRQHandler, control_line_on, control_line_off, transmit_byte

/* 
lines:
  - control line: which the sender uses to tell the receiver that it’s sending data (as opposed to just waiting between messages)
    - PE12 (sender / output)
    - PH0 (receiver / input)
  - clock line: which the sender uses to tell the receiver when to read each incoming bit from the data line
    - PE13 (sender / output)
    - PH1 (receiver / input)
  - data line: which is used to send the actual data one-bit-at-a-time as either a low (0) or high (1) voltage
    - PD0 (sender / output)
    - PE14 (receiver / input)

Sender
1. when the sender wants to send a message it will trigger a rising edge (a 0 to 1 transition) on the control line
2. to send a bit (i.e. 0 or 1), the sender must:
  - first write the bit to the data line
  - then pulse (toggle) the clock line to trigger a read on the receiver’s end
3. step 2 must be repeated until all n bits in the message have been sent, and then finally the sender should trigger a falling edge on the control line to indicate that it has finished sending data
  - when ready to send another message start again from step 1
  interrupt:
    - tim7 interrupt: move to next note

Receiver
1. on startup the receiver must wait, listening for a rising edge on the control line
  - control line: PH0 (receiver / input)
2. when a rising edge is detected on the control line, the receiver starts paying attention to the clock line:
  - each time the clock line is pulsed (i.e. either a rising or falling edge), the receiver must read a single bit off the data line by reading the appropriate input data register GPIOx_IDR
  - the receiver must store the bit somewhere for later processing, and also increment the count of how many bits have been received in this message
3. step 2 must be repeated while the control line remains high
4. when a falling edge is detected on the control line:
  - if exactly n bits have been sent in the current message (i.e. since the last rising edge on the control line) the receiver has successfully received the message, and can store/queue it for later processing
  - if more/fewer than n bits have been sent in the current message, the receiver must disregard the message
  - the receiver must return to step 1 and start listening for a new message
  interrupt:
    - when control line H0 is 1
      - enable clock line interrupt
      - prepare to store received data
    - when clock line H1 is 1, read data line (E14)
      - count bits received

1. tim7 trigger interrupt in sender
  1. set control line to 1
    1. control line interrupt in receiver
    2. receiver enables clock line interrupt
    3. create space to store received data
    4. count bits received
  2. send MIDI 3 bytes over clock line and data line
  3. set control line to 0, trigger falling edge interrupt in receiver
    1. receiver checks all data received
    2. executes command
*/

.type control_line_init, %function
control_line_init:
  push {lr}

  GPIO_configure_output_pin E, 12 @ sender
  GPIO_configure_input_pin H, 0 @ receiver
  GPIO_configure_input_pin_it H, 0

  EXTI_set_rising_edge_trigger 0
  EXTI_set_falling_edge_trigger 0

  @ enable the NVIC interrupt
  NVIC_set ISER 6 @ EXTI0

  @ increase interrupt priority
  mov r0, #6 @ r0: position (see table on 11.3 @Disco reference manual)
  mov r1, 0b0100 @ r1: priority (4 bits, 1111 = lowest priority, 0000 = highest priority)
  bl NVIC_IPR_set_priority

  pop {lr}
  bx lr
.size control_line_init, .-control_line_init

.type clock_line_init, %function
clock_line_init:
  push {lr}

  GPIO_configure_output_pin E, 13 @ sender
  GPIO_configure_input_pin H, 1 @ receiver
  GPIO_configure_input_pin_it H, 1

  EXTI_set_rising_edge_trigger 1

  @ increase interrupt priority
  mov r0, #7 @ r0: position (see table on 11.3 @Disco reference manual)
  mov r1, 0b0000 @ r1: priority (4 bits, 1111 = lowest priority, 0000 = highest priority)
  bl NVIC_IPR_set_priority

  pop {lr}
  bx lr
.size clock_line_init, .-clock_line_init

.type data_line_init, %function
data_line_init:
  push {lr}
  GPIO_configure_output_pin D, 0 @ sender
  GPIO_configure_input_pin E, 14 @ receiver
  pop {lr}
  bx lr
.size data_line_init, .-data_line_init

.type control_line_on, %function
control_line_on:
  push {lr}
  GPIOx_ODR_set E 12
  pop {lr}
  bx lr
.size control_line_on, .-control_line_on

.type control_line_off, %function
control_line_off:
  push {lr}
  GPIOx_ODR_clear E 12
  pop {lr}
  bx lr
.size control_line_off, .-control_line_off

@ receiver
.type control_line_rising_edge, %function
control_line_rising_edge:
  push {lr}
  @ enable the NVIC interrupt for clock line
  NVIC_set ISER 7 @ EXTI1
  pop {lr}
  bx lr
.size control_line_rising_edge, .-control_line_rising_edge

@ receiver
.type control_line_falling_edge, %function
control_line_falling_edge:
  push {r4-r5, lr}
  @ disable clock line interrupt
  NVIC_set ICER 7 @ EXTI1

  ldr r2, =current_command @ r2 = address of command
  ldr r3, [r2] @ r3 = length of bits received

  @ divmod
  mov r0, #32
  mod r4 r3 r0 @ r4 = remainder
  udiv r5, r3, r0 @ r5 = division result

  @ if length of bits received is not divisible by 32, discard
  mov r0, #0
  cmp r0, r4
  bne invalid_data_received

  @ if 3 bytes not received, discard
  mov r0, #96
  cmp r0, r3
  bne invalid_data_received

  bl execute_midi_command
  b end_processing_message

invalid_data_received:
  bl red_led_on

end_processing_message:
  ldr r0, =current_command
  mov r1, #0
  str r1, [r0], #4
  str r1, [r0], #4
  str r1, [r0], #4
  str r1, [r0], #4
  pop {r4-r5, lr}
  bx lr
.size control_line_falling_edge, .-control_line_falling_edge

.type clock_line_toggle, %function
clock_line_toggle:
  push {lr}
  GPIOx_ODR_set E 13
  GPIOx_ODR_clear E 13
  pop {lr}
  bx lr
.size clock_line_toggle, .-clock_line_toggle

.type data_line_on, %function
data_line_on:
  push {r2, lr}
  GPIOx_ODR_set D 0
  pop {r2, lr}
  bx lr
.size data_line_on, .-data_line_on

.type data_line_off, %function
data_line_off:
  push {r2, lr}
  GPIOx_ODR_clear D 0
  pop {r2, lr}
  bx lr
.size data_line_off, .-data_line_off

@ receiver
.type control_line_falling_edge, %function
execute_midi_command:
  push {lr}

  ldr r0, =current_command
  ldr r1, [r0, #4]!
  ldr r2, [r0, #4]!
  ldr r3, [r0, #4]!

  mov r0, 0x80
  cmp r0, r1
  IT NE
  blne sound_off

  mov r0, 0x80
  cmp r0, r1
  IT EQ
  bleq sound_on

  pop {lr}
  bx lr
.size control_line_falling_edge, .-control_line_falling_edge

@ receiver
.type sound_off, %function
sound_off:
  push {lr}
  
  ldr r0, =play_status
  mov r1, #0
  str r1, [r0]

  pop {lr}
  bx lr
.size sound_off, .-sound_off

/* 
expects
r2: midi note number
r3: velocity*/
@ receiver
.type sound_on, %function
sound_on:
  push {r4, r8, lr}

  @ convert midi note number to frequency_x100
  mov r8, r3
  mov r0, r2
  bl convert_midi_to_frequency
  mov r4, r0

  mov r0, r8
  bl convert_velocity_to_amplitude
  mov r1, r0

  mov r0, r4
  bl wave_change

  ldr r0, =play_status
  mov r1, #1
  str r1, [r0]

  pop {r4, r8, lr}
  bx lr
.size sound_on, .-sound_on

/* 
expects
r0: velocity */
@ receiver
.type convert_velocity_to_amplitude, %function
convert_velocity_to_amplitude:
  push {lr}

  mov r1, 0x7FFF
  mov r2, 127
  udiv r1, r2
  mul r0, r1

  pop {lr}
  bx lr
.size convert_velocity_to_amplitude, .-convert_velocity_to_amplitude

@ control line
@ receiver
.type EXTI0_IRQHandler, %function
EXTI0_IRQHandler:
  push {lr}

  @ check rising or falling edge
  GPIOx_IDR_read H 0
  mov r1, #1
  cmp r0, r1
  
  IT EQ
  bleq control_line_rising_edge

  GPIOx_IDR_read H 0
  mov r1, #1
  cmp r0, r1

  IT NE
  blne control_line_falling_edge

  @ Clear interrupt
  EXTI_PR_clear_pending 0

  pop {lr}
  bx lr
.size EXTI0_IRQHandler, .-EXTI0_IRQHandler

@ clock line
@ receiver
.type EXTI1_IRQHandler, %function
EXTI1_IRQHandler:
  push {r4-r8, lr}

  ldr r7, =current_command @ r7 = address of command
  ldr r4, [r7] @ r4 = length of bits received
  @ increment and store number of bits received
  add r4, #1
  str r4, [r7], #4
  sub r4, #1

  @ divmod
  mov r0, #32
  mod r5 r4 r0 @ r5 = remainder
  udiv r6, r4, r0 @ r6 = division result

  GPIOx_IDR_read E 14 @ read data line

  lsl r0, r5
  mov r8, r0 @ r8 = bit received, shifted to proper location

  @ move address in r7 to ith byte based on divmod result
  mov r0, #4
  mul r0, r6
  add r7, r0

  @ store received bit
  ldr r0, [r7]
  add r0, r8
  str r0, [r7]

  @ Clear interrupt
  EXTI_PR_clear_pending 1

  pop {r4-r8, lr}
  bx lr
.size EXTI1_IRQHandler, .-EXTI1_IRQHandler

/* transmits from the least significant bit
input
r0: byte to transmit
uses
r2: current bit to send
r3: rotated byte
r4: byte to transmit
r5: counter - number of bits sent*/
.type transmit_byte, %function
transmit_byte:
  push {r4-r5, lr}
  mov r4, r0
  mov r5, #0
transmit_bit_repeat:
  @ use ror to send 1 bit at a time
  mov r0, #32
  cmp r0, r5
  beq end_transmission

  ror r3, r4, r5
  and r2, r3, 0b1

  mov r0, 1
  cmp r2, r0
  IT EQ
  bleq data_line_on

  mov r0, 1
  cmp r2, r0
  IT NE
  blne data_line_off

  bl clock_line_toggle
  bl sync

  add r5, #1
  b transmit_bit_repeat
end_transmission:
  bl data_line_off
  pop {r4-r5, lr}
  bx lr
.size transmit_byte, .-transmit_byte

.global main
.type main, %function
main:
  bl init

  @ enable the System Configuration Controller (SYSCFG) clock so that 
  @ you can modify the system configuration 
  @ (see Chaper 8 and 8.2.3 in the discoboard reference manual).
  RCC_APB2ENR_set 0

  @ enable GPIO pins
  GPIOx_clock_enable D
  GPIOx_clock_enable E
  GPIOx_clock_enable H

  @ initialize communication lines and fpu
  bl control_line_init
  bl clock_line_init
  bl data_line_init

  bl fpu_init
  bl red_led_init
  
  @ start the first counter
  bl TIM7_IRQHandler

.size main, .-main

.type play, %function
play:
  @ play music while play_status is 1
  ldr r0, =play_status
  ldr r0, [r0]
  mov r1, #1
  cmp r0, r1
  IT EQ
    bleq wave_play_next_sample

  b play
.size play, .-play

@ code below this line is taken from:
@ https://gitlab.cecs.anu.edu.au/u7233149/comp2300-2021-assignment-2/-/blob/part-2/src/main.S
.type fpu_init, %function
fpu_init:
  ldr r0,=ADR_CPACR
  ldr r0, [r0]
  ldr r1, [r0]
  ldr r2, =0xF

  @ set 1111 at offset 20
  orr r1, r1, r2, LSL #20
  str r1, [r0]

  @ isb
  bx lr
.size fpu_init, .-fpu_init

.type convert_midi_to_frequency, %function
convert_midi_to_frequency:
  @ convert midi byte number to frequency_x100
  
  @ args
  @ r0: midi byte number

  @ result
  @ r0: frequency
  
  push {lr}

  sub r0, #69

  @ convert midi byte number to float32
  vmov s0, r0
  vcvt.f32.s32 s0, s0

  @ places 2 ^ ((d-69)/12) in s0
  bl compute_2_exp_frac

  @ s0 *= 440Hz
  mov r1, #440
  vmov s1, r1
  vcvt.f32.u32 s1, s1
  vmul.f32 s0, s0, s1

  @ lastly, multiply Hz by 100
  mov r1, #100
  vmov s1, r1
  vcvt.f32.u32 s1, s1
  vmul.f32 s0, s0, s1
  @ now, s0 contains midi byte converted to frequency_x100
  
  @ convert to int and store back to r0
  vcvt.u32.f32 s0, s0
  vmov r0, s0

  pop {lr}
  bx lr
.size convert_midi_to_frequency, .-convert_midi_to_frequency

.type compute_2_exp_frac, %function
compute_2_exp_frac:
  @ calculates 2^(m/n) where m = d-69 and n = 12, equivalent to (nth root of 2)^ m
  @ 12th root of 2 is #1.0594631 which is approximately 1+(2973/50000)

  @ args
  @ s0: midi byte number - 69 = m
  @ r0: midi byte number - 69 = m

  @ result
  @ r1: counter = 1
  @ s1: 12th root of 2
  @ s2: 12th root of 2
  push {lr}

  mov r1, #2973
  mov r2, #50000
  mov r3, #1
  vmov s1, r1
  vmov s2, r2
  vmov s3, r3
  vcvt.f32.u32 s1, s1
  vcvt.f32.u32 s2, s2
  vcvt.f32.u32 s3, s3
  vdiv.f32 s1, s1, s2
  vadd.f32 s1, s3
  vmov s2, s1
  mov r1, #1

absolute_func:
  @ args
  @ r0: integer

  @ result
  @ r2: absolute value of r0
  
  @ if r0 > -1, branch; else, multiply by -1
  mov r3, #-1
  mov r2, r0
  cmp r0, r3
  bgt exponentiate

  @ r2 = r0 * -1
  mul r2, r0, r3

exponentiate:
  @ compute a^b or 2 ^ ((d-69)/12) by calculating (12th root of 2) ^ (d-69)

  @ args
  @ r0: d - 69
  @ r2: b = abs(d-69)

  @ expects
  @ r1: counter = 1
  @ s1: a = 12th root of 2
  @ s2: a_i
  @ s3: 1.0

  @ result
  @ s0: 2 ^ ((d-69)/12)

  @ for i in range (1, abs(d-69)+1); a_i := a_{i-1} * a
  vmul.f32 s2, s1
  add r1, #1
  cmp r1, r2
  blt exponentiate
  vmov s1, s2

  @ if (d-69) is negative, then negative exponent 1/a^b
  mov r3, #0
  cmp r0, r3

  IT LT
    bllt negative_exponent

  vmov s0, s1
  
  pop {lr}
  bx lr
.size compute_2_exp_frac, .-compute_2_exp_frac

.type negative_exponent, %function
negative_exponent:
  @ expects
  @ s1: a^b
  @ s3: 1.0

  @ result
  @ s1: 1 / a^b
  vdiv.f32 s1, s3, s1
  bx lr
.size negative_exponent, .-negative_exponent

.data
play_status:
  .word 0

current_command:
  .word 0 @ length in bits
  .word 0, 0, 0

ADR_CPACR:
  @ memory address of Coprocessor Access Control Register, CPACR for enabling FPU
  .word 0xE000ED88
