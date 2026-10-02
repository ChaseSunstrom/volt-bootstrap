/* qemu's riscv virt board: with -bios none the CPU starts at the bottom of RAM (0x80000000), so the
   start code goes first. RAM only, so .data needs no copying (it's loaded where it runs). */
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 16M }
SECTIONS {
  .text : { KEEP(*(.text.volt_start)) *(.text .text.*) } > RAM
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
  .init_array : { __init_array_start = .; KEEP(*(.init_array .init_array.*)) __init_array_end = .; } > RAM
  .data : ALIGN(4) { __data_start = .; *(.data .data.* .sdata .sdata.*) . = ALIGN(4); __data_end = .; } > RAM
  __data_load = LOADADDR(.data);
  .bss (NOLOAD) : ALIGN(4) { __bss_start = .; *(.bss .bss.* .sbss .sbss.* COMMON) . = ALIGN(4); __bss_end = .; } > RAM
  . = ALIGN(16);
  __heap_start = .;
  __stack_top = ORIGIN(RAM) + LENGTH(RAM);
  __heap_end = __stack_top - 0x10000;
}
