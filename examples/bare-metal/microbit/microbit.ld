/* the nRF51822: 256K of flash at 0, where the vector table must start, and 16K of RAM at 0x20000000.
   .data lives in RAM but is loaded into flash, and the start code copies it over. It's small: std's
   tables are vals, read-only data in flash, so 16K of RAM is enough. */
MEMORY {
  FLASH (rx) : ORIGIN = 0x00000000, LENGTH = 256K
  RAM (rwx) : ORIGIN = 0x20000000, LENGTH = 16K
}
SECTIONS {
  .vector_table : { KEEP(*(.vector_table)) } > FLASH
  .text : { *(.text .text.*) } > FLASH
  .rodata : { *(.rodata .rodata.*) } > FLASH
  .ARM.exidx : { *(.ARM.exidx .ARM.exidx.*) } > FLASH
  .init_array : { __init_array_start = .; KEEP(*(.init_array .init_array.*)) __init_array_end = .; } > FLASH
  .data : ALIGN(4) { __data_start = .; *(.data .data.*) . = ALIGN(4); __data_end = .; } > RAM AT > FLASH
  __data_load = LOADADDR(.data);
  .bss (NOLOAD) : ALIGN(4) { __bss_start = .; *(.bss .bss.* COMMON) . = ALIGN(4); __bss_end = .; } > RAM
  . = ALIGN(16);
  __heap_start = .;
  __stack_top = ORIGIN(RAM) + LENGTH(RAM);
  __heap_end = __stack_top - 0x2000; /* 8K of stack: a debug build formats a float in about 5K */
}
