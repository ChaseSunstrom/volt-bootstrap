#include <stddef.h>
/* qsort as MinGW's stdlib.h declares it: its comparison function's declarator starts with an
   attribute (__cdecl), inside the parentheses */
void __attribute__((__unused__)) qsort(void *_Base, size_t _NumOfElements, size_t _SizeOfElements, int (__attribute__((__unused__)) *_PtFuncCompare)(const void *, const void *));
