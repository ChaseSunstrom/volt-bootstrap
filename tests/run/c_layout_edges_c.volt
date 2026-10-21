// tests/run/c_layout_edges.volt through the C backend
// flags: --backend c tests/run/c_layout_edges.volt
// expect: pk true true 286
// expect: pk read 285 70
// expect: su true true 5
// expect: vv true 32 4
// expect: a32 5 true
// expect: attrs true true true true
// expect: attrs 54926
// expect: by value 21 7 900
// expect: volatile 9
