// Dart calls the Volt library through voltc bindings --lang dart (dart:ffi): errors are thrown as
// VoltError subclasses, owned text comes back as a String, an export struct is a class (close()
// frees it now; otherwise a NativeFinalizer frees it once it's collected)
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
