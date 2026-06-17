import 'package:test/test.dart';

import 'package:maplibre_flutter_core/maplibre_flutter_core.dart';

void main() {
  test('invoke native function', () {
    expect(sum(24, 18), 42);
  });

  test('invoke async native callback', () async {
    expect(await sumAsync(24, 18), 42);
  });
}
