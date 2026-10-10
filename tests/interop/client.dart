// Dart calls the Volt library through voltc bindings --lang dart (dart:ffi): errors are thrown as
// VoltError subclasses, owned text comes back as a String, an export struct is a class (close()
// frees it now; otherwise a NativeFinalizer frees it once it's collected)
import 'dart:ffi';

import 'mathlib.dart';

String n(num v) => v == v.truncate() ? v.truncate().toString() : v.toString();

void main() {
  print('add ${ml_add(2, 3)}');
  final a = vec2.of(x: 1, y: 2), b = vec2.of(x: 3, y: 4);
  print('dot ${n(ml_dot(a, b))}');
  ml_scale(a, 2);
  print('scale ${n(a.x)} ${n(a.y)}');
  print('len ${ml_len('hello')}');
  print('clash ${ml_clash(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 'ab', 13, 14)}');
  final tg = ml_tags_make();
  final head = 'tags ${tg.from} ${tg.type} ${tg.self} ${tg.int_}';
  tg.int_ = 5;
  print('$head ${ml_tags_sum(tg)}');
  final malloc = DynamicLibrary.process().lookupFunction<Pointer<Void> Function(Size), Pointer<Void> Function(int)>('malloc');
  final bp = malloc(4).cast<Int32>()..value = 7;
  final bq = malloc(8).cast<Double>()..value = 2.5;
  ml_bump(bp, bq);
  print('bump ${bp.value} ${n(bq.value)}');
  print('next ${ml_next(color.GREEN).value}');
  print('sqrt ${n(ml_sqrt(9))} 1');
  try {
    ml_sqrt(-1);
  } on math_error catch (e) {
    print('error ${e.code == math_error.NEGATIVE ? 'negative' : '?'}');
  }
  print('greet ${ml_greet('volt')}');
  print('repeat ${ml_repeat('ab', 2)}');
  try {
    ml_repeat('ab', -1);
  } on VoltError catch (e) {
    print('repeat ${e.name.toLowerCase()}');
  }
  print('sum ${n(ml_sum([1, 2, 3.5]))}');
  final ys = [4, 5, 6];
  print('find ${ml_find(ys, 6)} ${ml_find(ys, 9) == null ? 'none' : '?'}');
  final seen = <int>[];
  ml_each(ys, seen.add);
  print('each ${seen.join(' ')} = ${seen.reduce((s, x) => s + x)}');
  final c = counter('clicks');
  c.add(2);
  print('counter ${c.name()} ${c.add(3)}');
  try {
    c.take(9);
  } on math_error catch (e) {
    print('take ${e.name.toLowerCase()}');
  }
  c.close();
  // structs with text, an array and a struct in them (in, out, in a list, from a function), one
  // with a pointer, E!T as a parameter (ok or err)
  final la = ml_label(name: 'ab', sizes: [1, 2, 3], at: vec2.of(x: 7, y: 0));
  print('label ${ml_label_len(la)}');
  final lb = ml_label_of('ab', 3);
  print('label_of ${lb.name} ${lb.sizes.join(' ')} ${lb.at.x}');
  print('labels ${ml_labels_len([la, lb])}');
  print('holder ${ml_holder_k(ml_holder.of(p: nullptr, k: 3))}');
  print('or ${ml_or(VoltResult.ok(4.5), 9.5)} ${ml_or(VoltResult.err(VoltError.of(math_error.NEGATIVE)), 9.5)}');
  print('ask ${ml_ask((k) => ml_label(name: 'abc', sizes: [k, k, k], at: vec2.of(x: 3, y: 0)))}');
  ml_relabel(lb, 4);
  print('relabel ${lb.name} ${lb.sizes.join(' ')}');
  print('count ${ml_labels_count([la, lb])}');
  print('note ${ml_note_len(ml_note(str: 'abc', c: 1, k: 3))}');
  print('or_label ${ml_or_label(VoltResult.ok(la))} ${ml_or_label(VoltResult.err(VoltError.of(math_error.NEGATIVE)))}');
  print('given ${ml_sum_given(3, (k) => [k, 10 * k])} ${ml_area_given((k) => [vec2.of(x: 1.5, y: k.toDouble()), vec2.of(x: 2, y: 3.25)])}');
  final deep = [
    [
      [1, 2],
      [3]
    ],
    [
      [4]
    ]
  ];
  final d = ml_deep(deep);
  print('deep $d ${deep[0][0][1]} ${deep[1][0][0]} words ${ml_words([
        ['ab', 'c'],
        [],
        ['def']
      ])}');
  print('text_given ${ml_text_given((k) => ['ab', 'cde'])} ${ml_labels_given((k) => [ml_label(name: 'abc', sizes: [k, k, k], at: vec2.of(x: 3, y: 0)), ml_label(name: 'de', sizes: [1, 1, 1], at: vec2.of(x: 0, y: 0))])}');
  print('turn ${ml_turn((a) => [a[2], a[1], a[0]])}');
  print('turner ${ml_turned(Turner())} flipped ${ml_flipped(ml_flipper())}');
  final po = ml_pair_of('ab', 'cd');
  final shelf = ml_shelf(labels: [ml_label(name: 'abc', sizes: [2, 2, 2], at: vec2.of(x: 3, y: 0)), ml_label(name: 'de', sizes: [1, 1, 1], at: vec2.of(x: 0, y: 0))], k: 1);
  final bk = ml_labels_back(shelf.labels);
  print('pair ${ml_pair_len(ml_pair(names: ['ab', 'cde'], n: 1))} ${po.names[0]} ${po.names[1]} shelf ${ml_shelf_len(shelf)} back ${bk.length} ${bk[0].name}');

  // a callback's exception comes out of the call (the later calls are skipped), and a closed
  // counter throws
  var calls = 0;
  try {
    ml_each(ys, (x) {
      calls++;
      throw StateError('stop at $x');
    });
    throw 'no error';
  } on StateError catch (e) {
    if (e.message != 'stop at 4' || calls != 1)
      throw 'callback error: $e $calls';
  }
  try {
    c.add(1);
    throw 'closed counter accepted';
  } on StateError {
    // expected
  }
}

class Turner implements ml_turner {
  @override
  List<int> turn(List<int> a) => [a[2], a[1], a[0]];
}
