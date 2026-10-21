#pragma once
/* a header with an accessor of its own, named as voltc names a bitfield's: its own keeps the name */
struct five { unsigned int w : 5; unsigned int k : 3; };
static inline void five_set_w(struct five *s, unsigned int v) { s->w = v + 1; }
