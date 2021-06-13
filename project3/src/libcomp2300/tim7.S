.syntax unified

@ ------------------------ TIM7 ------------------------
@ Timer 7 features a 16-bit prescaler and a 16-bit counter.
@ The prescaler divides the main clock (which runs at 80MHz according to definition in HAL),
@ and the counter counts up according to the divided clock.
@ When the counter counts up to the reload value,
@ an update event is triggered and an interrupt is fired.

@ --------------------- Module Interface --------------------
.global tim7_init, TIM7_IRQHandler, set_count_down

@ --------------------- Implementation --------------------
.include "src/libcomp2300/macros.S"

.set CK_PSC, 80000000

.type tim7_init, %function
@ tim7_init takes two parameters, clock divisor and count (in each case, only the lower 16-bits will be used)
@
@ the clock divisor determines how many CPU cycles per TIM7 tick
@ the count determines how many TIM7 ticks between the TIM7 interrupts firing
@
@ Remember that in the assignment template, the main clock is at 80MHz
@ so, for example, clock divisor = 10000 and count = 8000 will give a 1Hz interrupt
@
@ In short, (seconds between interrupts) = (clock divisor * count) / 80000000
@
@ --parameters--
@ r0: clock divisor (prescaler + 1)
@ r1: count
tim7_init:
  push {r4-r5, lr}
  mov r4, r0
  mov r5, r1

  @ enable peripheral clock
  @ RCC_APB1ENR_set 5
  ldr r0, =ADR_RCC
  ldr r1, =OFS_RCC_APB1ENR
  ldr r2, =5
  bl set_bit

  @ Set prescaler
  @ the counter clock frequency f(CK_CNT) = f(CK_PSC) / (prescaler + 1)
  @ since clock divisor = prescaler + 1,
  @ subtract 1 here to get the prescaler
  @ See Section 29.4.7
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_PSC
  sub r4, 1
  strh r4, [r0, r1]

  @ set counter reload value (Section 29.4.8)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_ARR
  strh r5, [r0, r1]

  @ TIM7_EGR (Section 29.4.5)
  ldr r0, =ADR_TIM7
  ldr r1, =0x14
  ldr r2, [r0, r1]
  orr r2, 0b1
  str r2, [r0, r1]

  @ clear interrupt (Section 29.4.4)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_SR
  mov r2, 0
  bl clear_bit

  @ enable timer 7  (Section 29.4.1s)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_CR1
  mov r2, 0
  bl set_bit

  @ enable TIM7 DMA/interrupt (Section 29.4.3)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_DIER
  mov r2, 0
  bl set_bit

  @ enable TIM7 interrupt in NVIC
  NVIC_set ISER 55  @ TIM7 is at position 55

  @ set debug freeze (Section 44.16.4)
  ldr r0, =ADR_DBGMCU_APB1FZR1
  mov r1, 0
  mov r2, 5
  bl set_bit

  @ NOTE: you MAY want to configure the priority of TIM7.
  @ put your code here if that's the case
  mov r0, #55 @ r0: position (see table on 11.3 @Disco reference manual)
  mov r1, 0b1111 @ r1: priority (4 bits, 1111 = lowest priority, 0000 = highest priority)
  bl NVIC_IPR_set_priority

  bl sync
  pop {r4-r5, lr}
  bx lr
.size tim7_init, .-tim7_init

.type TIM7_IRQHandler, %function
TIM7_IRQHandler:
  push {r4-r7, lr}

  @ increment current note/line
  ldr r0, =music_current_note
  ldr r1, [r0]
  add r1, #1
  str r1, [r0] @ r1 = current line
  sub r1, #1

  ldr r0, =music
  ldr r2, [r0], #4 @ r2 = length

  @ if end of music is reached, reset music by setting music_current_note to 0
  cmp r1, r2
  IT EQ
  bleq restart_music

  @ load next line
  mov r3, #16
  mul r1, r3
  add r0, r1 @ r0 = address of start of current line

  ldr r4, [r0], #4 @ r4 = command
  ldr r5, [r0], #4 @ r5 = midi_byte_number
  ldr r6, [r0], #4 @ r6 = velocity
  ldr r7, [r0], #4 @ r7 = duration_in_sec_x100

  @ transmit data
  bl control_line_on
  bl sync
  mov r0, r4
  bl transmit_byte
  mov r0, r5
  bl transmit_byte
  mov r0, r6
  bl transmit_byte
  bl control_line_off
  bl sync

  @ set up next timer
  mov r0, r7
  bl set_count_down

  pop {r4-r7, lr}
  bx lr
.size TIM7_IRQHandler, .-TIM7_IRQHandler

.type set_count_down, %function
@ args:
@   r0: 1/100 seconds to count
set_count_down:
  push {lr}

  mov r3, r0

  ldr r0, CPU_FREQ
  mov r1, #10000
  udiv r0, r1 @ r0 = clock divisor

  mov r1, #100
  mul r1, r1, r3 @ r1 = count

  bl tim7_init

  pop {lr}
  bx lr
.size set_count_down, .-set_count_down

.type restart_music, %function
restart_music:
  @ reset current note
  ldr r0, =music_current_note
  mov r1, #0
  str r1, [r0]
  add r1, #1

  bx lr
.size restart_music, .-restart_music

.text
CPU_FREQ:
  .word 80000000

.data
music_current_note:
  .word 0
  
music:
  @ Length of array
  .word 50
  
  @ command, midi_byte_number, velocity, duration_in_sec_x100
  .word 0x80, 62, 127,   15 @ D4
  .word 0x90, 62,   0,    1
  .word 0x80, 65, 127,   15 @ F4
  .word 0x90, 65,   0,    1
  .word 0x80, 74, 127,    6 @ D5
  .word 0x90, 74,   0,    1
  .word 0x80, 62, 127,   15 @ D4
  .word 0x90, 62,   0,    1
  .word 0x80, 65, 127,   15 @ F4
  .word 0x90, 65,   0,    1
  .word 0x80, 74, 127,    6 @ D5
  .word 0x90, 74,   0,    1
  .word 0x80, 76, 127,   45 @ E5
  .word 0x90, 76,   0,    1
  .word 0x80, 77, 127,   15 @ F5
  .word 0x90, 77,   0,    1
  .word 0x80, 76, 127,   15 @ E5
  .word 0x90, 76,   0,    1
  .word 0x80, 77, 127,   15 @ F5
  .word 0x90, 77,   0,    1
  .word 0x80, 76, 127,   15 @ E5
  .word 0x90, 76,   0,    1
  .word 0x80, 72, 127,   15 @ C5
  .word 0x90, 72,   0,    1
  .word 0x80, 69, 127,   45 @ A4
  .word 0x90, 69,   0,    1
  .word 0x80,  0,   0,   15 @ silence
  .word 0x90,  0,   0,    1
  .word 0x80, 69, 127,    3 @ A4
  .word 0x90, 69,   0,    1
  .word 0x80, 62, 127,    3 @ D4
  .word 0x90, 62,   0,    1
  .word 0x80, 65, 127,   15 @ F4
  .word 0x90, 65,   0,    1
  .word 0x80, 67, 127,   15 @ G4
  .word 0x90, 67,   0,    1
  .word 0x80, 69, 127,   75 @ A4
  .word 0x90, 69,   0,    1
  .word 0x80,  0,   0,   15 @ silence
  .word 0x90,  0,   0,    1
  .word 0x80, 69, 127,    3 @ A4
  .word 0x90, 69,   0,    1
  .word 0x80, 62, 127,    3 @ D4
  .word 0x90, 62,   0,    1
  .word 0x80, 65, 127,   15 @ F4
  .word 0x90, 65,   0,    1
  .word 0x80, 67, 127,   15 @ G4
  .word 0x90, 67,   0,    1
  .word 0x80, 64, 127,    9 @ E4
  .word 0x90, 64,   0,    1