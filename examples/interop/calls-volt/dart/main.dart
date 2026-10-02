// Dart calls the Volt library greet through its library (bindings/greet.dart, over dart:ffi): owned
// text comes back as a String, an export struct is a class (close() frees it now)
import '../greet/target/debug/bindings/greet.dart';

void main() {
  print('add ${add(2, 3)}');
  print(hello('volt'));
  final c = tally('clicks');
  c.add(1);
  final n = c.add(2);
  print('${c.name()} $n');
  c.close();
}
