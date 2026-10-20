/* qemu's aarch64 virt board: -kernel loads an ELF where it says and starts it at _start, at EL1 with
   the MMU off. RAM starts at 0x40000000 (qemu puts its device tree at the bottom of it, so the image
   starts 2M up); RAM only, so .data needs no copying (it's loaded where it runs). */
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x40200000, LENGTH = 62M }
SECTIONS {
  .text : { KEEP(*(.text.volt_start)) *(.text .text.*) } > RAM
  .rodata : { *(.rodata .rodata.*) } > RAM
  .init_array : { __init_array_start = .; KEEP(*(.init_array .init_array.*)) __init_array_end = .; } > RAM
  .data : ALIGN(8) { __data_start = .; *(.data .data.*) . = ALIGN(8); __data_end = .; } > RAM
  __data_load = LOADADDR(.data);
  .bss (NOLOAD) : ALIGN(8) { __bss_start = .; *(.bss .bss.* COMMON) . = ALIGN(8); __bss_end = .; } > RAM
  . = ALIGN(16);
  __heap_start = .;
  __stack_top = ORIGIN(RAM) + LENGTH(RAM);
  __heap_end = __stack_top - 0x10000;
}
