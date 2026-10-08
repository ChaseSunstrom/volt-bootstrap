// Dart calls shapelib (voltc bindings --lang dart): a generic's instances, a struct held by a class
// with methods, owned values passed in, a Volt trait as an interface both ways, callbacks taking and
// giving text, handles and errors, closures given back (called like functions, close()), lists, and
// optional text and handles; the library's leak report goes to stderr last
import 'dart:ffi';
import 'dart:io';

import 'shapelib.dart';

String n(num v) => v == v.truncate() ? v.truncate().toString() : v.toString();

// Dart's own shape: Volt calls it through the trait's table, and closes one it was given
class Circle implements shape, VoltCloseable {
  double r;

  Circle(this.r);

  @override
  double area() => 3 * r * r;

  @override
  String name() => 'circle';

  @override
  void grow(double by) => r += by;

  @override
  void close() => print('circle gone');
}

// a shape whose name throws
class Broken implements shape {
  @override
  double area() => 1;

  @override
  String name() => throw StateError('no name');

  @override
  void grow(double by) {}
}

int twice(int x) {
  if (x > 5) {
    throw VoltError.of(bank_error.OVERDRAWN);
  }
  return x * 2;
}

// what C and C++ don't print: an E!void callback, closures given back giving E!void and a str
void extras() {
  var ok = true;
  try {
    checked((x) {
      if (x <= 0) {
        throw VoltError.of(bank_error.OVERDRAWN);
      }
    }, 1);
  } on VoltError {
    ok = false;
  }
  var err = '';
  try {
    checked((x) => throw VoltError.of(bank_error.OVERDRAWN), 1);
  } on bank_error catch (e) {
    err = e.name;
  }
  print('checked $ok $err');
  final lim = limiter();
  var under = true;
  try {
    lim(3);
  } on VoltError {
    under = false;
  }
  var over = '';
  try {
    lim(12);
  } on bank_error catch (e) {
    over = e.name;
  }
  lim.close();
  print('limit $under $over');
  final sign = labeler();
  print('sign ${sign(5)} ${sign(-1)}');
  sign.close();
}

// lists (List both ways), lists of text and handles, null for none
void lists() {
  final a = account.open('ann');
  a.deposit(5);
  final b = account.open('bobby');
  b.deposit(9);
  final both = [a, b];
  final os = owners(both);
  print('owners ${os.length} ${os[0]} ${os[1]}');
  final rich = richest(both);
  print('richest $rich after ${a.get()} ${b.get()}');
  final opened = open_all(['cy', 'dee']);
  print('opened ${opened.length} ${opened[1].owner()}');
  // each handle is the caller's
  for (final x in opened) {
    x.close();
  }
  final sq = squares_upto(4);
  print('squares ${sq.length} ${sq[3]} sum ${sum_all(sq)}');
  final parts = ['a', 'b', 'c'];
  print('joined ${joined(parts, '-')} total ${total_len(parts)}');
  print('${greeting('ann')}; ${greeting(null)}');
  final n1 = nickname(a), n2 = nickname(b);
  print('nick ${n1 != null ? 1 : 0} $n1 ${n2 != null ? 1 : 0}');
  final c = open_if('eve', true);
  final d = open_if('x', false);
  print('open_if ${c != null ? 1 : 0} ${d == null ? 1 : 0}');
  print('close_if ${close_if(c)} ${close_if(null)}');
  // given to Volt: a and b let their handles go
  print('close_all ${close_all(both)}');
  print('some ${count_some([1, null, 3])}');
  print('lists closed ${closed_accounts()}');
}

// the name of what f throws
String raised(void Function() f) {
  try {
    f();
  } catch (e) {
    return e.runtimeType.toString();
  }
  return 'nothing';
}

// Dart's own (after the rest): an exception a callback or a trait fn throws comes out of the call
// that led to it once Volt (given a stand-in) returns; what Volt can't take (closed, lent, or given
// twice) is refused before anything is given; a handle Volt lent a callback is closed once it
// returns; a callback that has to give a handle and throws ends the program
void dartExtras() {
  final a = account.open('ann');
  a.deposit(5);
  print('raised ${raised(() => shout((s) => throw StateError('boom'), 'hey'))} ${raised(() => try_twice((x) => throw StateError('boom'), 1))} ${raised(() => visit(a, (b) => throw StateError('boom')))} ${raised(() => describe(Broken()))}');
  final gone = account.open('gone');
  close_account(gone);
  account? kept;
  visit(a, (b) {
    kept = b;
    return 0;
  });
  print('refused ${raised(() => close_account(gone))} ${raised(() => visit(a, (b) => close_account(b)))} ${raised(() => visit(a, (b) => close_account(a)))} ${raised(() => visit(a, (b) {
            a.close();
            return 0;
          }))} ${raised(() => close_all([a, a]))} ${raised(() => richest([a, a]))} ${raised(() => kept!.get())}');
  print('kept ${raised(() => close_all([a, gone]))} ${a.owner()} ${a.get()}');
  a.close();
  final p = Process.runSync(Platform.resolvedExecutable, [Platform.script.toFilePath(), 'fatal']);
  print('fatal ${p.exitCode} ${p.stderr.toString().contains('no owner')}');
}

void main(List<String> args) {
  if (args.contains('fatal')) {
    opened_by((owner) => throw StateError('no owner'));
    return;
  }
  extras();
  print('biggest ${biggest_i32([3, 9, 4])} ${n(biggest_f64([1.5, 0.5]))}');
  final a = account.open('ann');
  a.deposit(250);
  a.rename('bea');
  var m = a.deposit(50);
  print('account ${a.owner()} $m');
  m = visit(a, (b) => b.deposit(1));
  print('visit $m get ${a.get()}');
  m = close_account(a);
  print('closed $m ${closed_accounts()}');
  final c = Circle(1);
  print(describe(c));
  // given: Volt closes it when it's done
  print('grown ${n(grow_twice(Circle(1)))}');
  final sq = make_square(2);
  sq.grow(1);
  print('${sq.name()} ${n(sq.area())} ${describe(sq)}');
  sq.close();
  print(shout((s) => '$s!', 'hey'));
  var t = '';
  try {
    try_twice(twice, 4);
  } on bank_error catch (e) {
    t = e.name;
  }
  print('try ${try_twice(twice, 1)} $t');
  m = opened_by((owner) {
    final b = account.open(owner);
    b.deposit(7);
    return b;
  });
  print('opened $m');
  print('closed ${closed_accounts()}');
  final d = doubler(), hi = greeter();
  print('${d(21)} ${hi('volt')}');
  d.close();
  hi.close();
  lists();
  c.close();
  dartExtras();
  // what the library still holds (it was built with --leak-check): 0 when it freed everything
  final lib = DynamicLibrary.open(Platform.environment['VOLT_SHAPELIB_LIB']!);
  stderr.writeln('volt live: ${lib.lookup<Size>('volt_live_allocs').value}');
}
