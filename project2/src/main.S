@ order of execution
@ main -> play_music -> play_note -> convert_midi_to_frequency -> initialize_play_sound -> loop: play_sound -> loop: (sound_on, sound_off)

.syntax unified
.fpu fpv4-sp-d16

.global main
.type main, %function
main:
  bl init
  bl fpu_init
.size main, .-main

play_music:
  @ load and store array
  ldr r11, =music @ array_pointer
  ldr r10, [r11], #4 @ array_size
  mov r3, #0 @ array_counter

play_note:
  @ args
  @ r3: array_counter = 0
  @ r10: array_size
  @ r11: array_pointer

  @ uses
  @ r4: number_of_cycles_per_10ms_x100
  @ r5: output_sample_rate_x100, duration_counter
  @ r6: counter
  @ r7: on_lengthx100
  @ r8: wavelength
  @ r9: cutoff
  @ r12: duty_cycle

  mov r2, #100
  ldr r5, output_sample_rate
  mul r5, r2 @ multiply output_sample_rate by 100
  udiv r4, r5, r2 @ number_of_cycles_per_10ms_x100 = output_sample_rate / 100

  @ increment array_counter
  add r3, #1

  @ load next note
  ldr r0, [r11], #4 @ r0 = midi_byte_number
  ldr r1, [r11], #4 @ r1 = duration_x100

  @ convert to frequency_x100
  push {r1-r3}
  bl convert_midi_to_frequency
  pop {r1-r3}

  @ wavelength = (output_sample_rate_x100 / frequency_x100) * 100 = (output_sample_rate_x100 / r0) * 100
  udiv r8, r5, r0
  mul r8, r2

  @ on_length = (wavelength / 100) * duty_cycle
  ldr r12, duty_cycle
  udiv r7, r8, r2
  mul r7, r12

  @ convert duration_x100 to cutoff in terms of cpu cycles
  @ cutoff = (duration_x100 * (number_of_cycles_per_10ms_x100 / 100)) * 100
  @ cutoff = duration_x100 * number_of_cycles_per_10ms_x100
  mul r9, r1, r4
  
  @ duration counter
  ldr r2, [r11, #-8]
  mov r5, #0
  cmp r5, r2 @ check if its a silent note
  beq initialize_play_nothing
  bl initialize_play_sound

  cmp r3, r10
  beq play_music @ if array end reached, play from start
  b play_note @ else, play next note


fpu_init:
  ldr r0,=0xE000ED88 @ memory address of Coprocessor Access Control Register, CPACR
  ldr r1, [r0]
  ldr r2, =0xF

  @ set 1111 at offset 20
  orr r1, r1, r2, LSL #20
  str r1, [r0]

  @ isb
  bx lr


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

negative_exponent:
  @ expects
  @ s1: a^b
  @ s3: 1.0

  @ result
  @ s1: 1 / a^b
  vdiv.f32 s1, s3, s1
  bx lr

initialize_play_nothing:
  @ args
  @ r1: duration_x100
  @ r3: array_counter
  @ r4: number_of_cycles_per_10ms_x100
  @ r5: duration_counter
  @ r10: array_size

  @ uses
  @ r9: duration

  push {r3, r6, r9, r10, lr}
  mul r2, r1, r4
  mov r1, #100
  udiv r9, r2, r1 @ r9 = (duration_x100 * number_of_cycles_per_10ms_x100) / 100 = silence_duration

play_nothing:
  mov r0, 0x8000
  bl BSP_AUDIO_OUT_Play_Sample

  add r5, #100
  cmp r5, r9
  ble play_nothing

  @ call play_note again if array end not reached, else call play_music
  pop {r3, r6, r9, r10, lr}
  cmp r3, r10
  beq play_music @ if array end reached, play from start
  b play_note @ else, play next note


initialize_play_sound:
  @ play sound to achieve desired wavelength (r8) or frequency for a specified duration (r9)

  @ args
  @ r5: duration counter
  @ r7: on_length
  @ r8: wavelength
  @ r9: cutoff

  @ uses
  @ r6: counter

  push {r3, lr} @ preserve array counter r3 which will be changed by BSP_AUDIO_OUT_Play_Sample
  mov r6, #0 @ reset counter
  
play_sound:

  @ increment counter
  add r5, #100
  add r6, #100

  cmp r6, r7
  blt sound_on

  cmp r6, r8
  blt sound_off

  @ reset counter
  mov r6, #0

  @ if desired duration not reached, repeat
  cmp r5, r9
  ble play_sound

  @ otherwise, go back and load next note
  pop {r3, lr}
  bx lr

sound_on:
  ldr r0, amplitude
  bl BSP_AUDIO_OUT_Play_Sample
  b play_sound

sound_off:
  mov r0, 0x8000
  bl BSP_AUDIO_OUT_Play_Sample
  b play_sound

.text
output_sample_rate:
  .word 48000

duty_cycle:
  .word 50 @ 80%

amplitude:
  .word 0x5FFF

.data
music:
  @ Length of array
  .word 25
  
  @ midi_byte_number, duration_in_sec_x100
  .word 62, 15 @ D4
  .word 65, 15 @ F4
  .word 74, 6 @ D5
  .word 62, 15 @ D4
  .word 65, 15 @ F4
  .word 74, 6 @ D5
  .word 76, 45 @ E5
  .word 77, 15 @ F5
  .word 76, 15 @ E5
  .word 77, 15 @ F5
  .word 76, 15 @ E5
  .word 72, 15 @ C5
  .word 69, 45 @ A4
  .word 0, 15 @ silence
  .word 69, 3 @ A4
  .word 62, 3 @ D4
  .word 65, 15 @ F4
  .word 67, 15 @ G4
  .word 69, 75 @ A4
  .word 0, 15 @ silence
  .word 69, 3 @ A4
  .word 62, 3 @ D4
  .word 65, 15 @ F4
  .word 67, 15 @ G4
  .word 64, 9 @ E4