// a variable a macro names under another name, as macOS's stdio.h does (#define stderr __stderrp)
extern int c_alias_real;
int c_alias_real = 7;
#define c_alias_count c_alias_real
extern int __c_alias_hidden;
int __c_alias_hidden = 5;
// (a reserved name, which isn't imported itself: macOS's stderr is __stderrp)
#define c_alias_hidden __c_alias_hidden
