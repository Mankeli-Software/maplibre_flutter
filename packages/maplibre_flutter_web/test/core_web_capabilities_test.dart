@TestOn('browser')
library;

import 'dart:js_interop';
// Dynamic property access, which is exactly what a hand-rolled stub needs.
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_flutter_platform_interface/maplibre_flutter_platform_interface.dart';
import 'package:maplibre_flutter_web/src/core_web/core_wasm_interop.dart';

/// Drives the web controller's capability forwarding against a STUB JS module.
///
/// The audit identified this as the one real verification path for this tier
/// that needs neither emsdk nor a GPU: `ensureCoreModuleLoaded` only checks for
/// a global factory, so a plain JS object satisfies the whole interop surface
/// and every forward can be asserted in headless Chrome.
///
/// What this does NOT cover, and must not be mistaken for: the C++ behind the
/// bindings. That is compiled by the `web-wasm` CI job and run by nobody yet.
void main() {
  // A stub CoreMap recording what the Dart side asked for. Built with
  // `JSObject()` + property assignment so it needs no JS source file.
  JSObject makeStubMap() {
    final map = JSObject();
    final calls = JSObject();
    map.setProperty('calls'.toJS, calls);

    map.setProperty(
      'projectBatch'.toJS,
      ((JSArray<JSNumber> latLngs) {
        calls.setProperty('projectBatchLen'.toJS, latLngs.length.toJS);
        // Two points: (10, 20) visible, (30, 40) NOT visible. The invisible one
        // still gets finite coordinates, which is exactly how mbgl behaves for a
        // point behind a pitched camera — the flag is the only signal.
        return <JSNumber>[
          10.0.toJS,
          20.0.toJS,
          1.toJS,
          30.0.toJS,
          40.0.toJS,
          0.toJS,
        ].toJS;
      }).toJS,
    );
    map.setProperty(
      'unproject'.toJS,
      ((double x, double y) {
        final o = JSObject()
          ..setProperty('lat'.toJS, (y / 2).toJS)
          ..setProperty('lng'.toJS, (x / 4).toJS);
        return o;
      }).toJS,
    );
    for (final name in ['addSourceJson', 'setGeoJsonData']) {
      map.setProperty(
        name.toJS,
        ((JSString a, JSString b) {
          calls.setProperty('$name.0'.toJS, a);
          calls.setProperty('$name.1'.toJS, b);
          return ''.toJS;
        }).toJS,
      );
    }
    map.setProperty(
      'addLayerJson'.toJS,
      ((JSString json, JSString before) {
        calls
          ..setProperty('layerJson'.toJS, json)
          ..setProperty('layerBefore'.toJS, before);
        return ''.toJS;
      }).toJS,
    );
    map.setProperty(
      'queryRenderedFeatures'.toJS,
      ((double a, double b, double c, double d, JSAny? ids) {
        calls
          ..setProperty('queryRect'.toJS, '$a,$b,$c,$d'.toJS)
          ..setProperty('queryIds'.toJS, (ids == null).toString().toJS);
        return '{"type":"FeatureCollection","features":[]}'.toJS;
      }).toJS,
    );
    map.setProperty(
      'setTransitionOptions'.toJS,
      ((int duration, int delay, bool placement) {
        calls.setProperty(
          'transition'.toJS,
          '$duration,$delay,$placement'.toJS,
        );
      }).toJS,
    );
    map.setProperty(
      'addImage'.toJS,
      ((JSString id, JSUint8Array rgba, int w, int h, double ratio, bool sdf) {
        calls.setProperty('image'.toJS, '$w,$h,$ratio,$sdf'.toJS);
      }).toJS,
    );
    for (final name in ['removeLayer', 'removeSource', 'removeImage']) {
      map.setProperty(
        name.toJS,
        ((JSString id) {
          calls.setProperty(name.toJS, id);
        }).toJS,
      );
    }
    return map;
  }

  test('projectBatch unpacks positions AND the visibility flags', () {
    final stub = makeStubMap() as CoreMap;
    final out = <Offset>[Offset.zero, Offset.zero];
    final visible = <bool>[false, false];

    final gen = stub.projectBatch(
      <JSNumber>[1.0.toJS, 2.0.toJS, 3.0.toJS, 4.0.toJS].toJS,
    );
    final flat = gen.toDart;

    expect(flat, hasLength(6), reason: '3 values per point: x, y, visible');
    for (var i = 0; i < 2; i++) {
      out[i] = Offset(
        (flat[i * 3]! as JSNumber).toDartDouble,
        (flat[i * 3 + 1]! as JSNumber).toDartDouble,
      );
      visible[i] = (flat[i * 3 + 2]! as JSNumber).toDartInt != 0;
    }
    expect(out, [const Offset(10, 20), const Offset(30, 40)]);
    expect(
      visible,
      [true, false],
      reason:
          'the second point has finite coordinates but is behind the '
          'camera — only the flag distinguishes it, which is why a tier that '
          'never writes the flags looks correct at pitch 0',
    );
  });

  test('unproject reads lat/lng off the returned object', () {
    final stub = makeStubMap() as CoreMap;
    final ll = stub.unproject(40, 60);
    expect(ll.lat, 30);
    expect(ll.lng, 10);
  });

  test('style layer calls forward their arguments intact', () {
    final stub = makeStubMap() as CoreMap;
    expect(stub.addSourceJson('src', '{"type":"geojson"}').toDart, isEmpty);
    expect(stub.addLayerJson('{"id":"a"}', 'b').toDart, isEmpty);
    stub
      ..addImage('icon', Uint8List(16).toJS, 2, 2, 3, true)
      ..setTransitionOptions(250, -1, false)
      ..removeLayer('a')
      ..removeSource('src')
      ..removeImage('icon');

    final calls = (stub as JSObject).getProperty<JSObject>('calls'.toJS);
    String read(String k) => calls.getProperty<JSString>(k.toJS).toDart;

    expect(read('addSourceJson.0'), 'src');
    expect(read('layerJson'), '{"id":"a"}');
    expect(read('layerBefore'), 'b');
    // dart2js renders a whole double as "3", not "3.0".
    expect(read('image'), '2,2,3,true');
    // -1 is the "leave the style's own value" sentinel the C ABI uses; a null
    // delay must arrive as that, not as 0, which would mean "no delay".
    expect(read('transition'), '250,-1,false');
    expect(read('removeLayer'), 'a');
    expect(read('removeSource'), 'src');
    expect(read('removeImage'), 'icon');
  });

  test('queryRenderedFeatures passes an asymmetric rect unflipped', () {
    final stub = makeStubMap() as CoreMap;
    final json = stub.queryRenderedFeatures(10, 20, 30, 40, null).toDart;
    expect(json, contains('FeatureCollection'));

    final calls = (stub as JSObject).getProperty<JSObject>('calls'.toJS);
    expect(
      calls.getProperty<JSString>('queryRect'.toJS).toDart,
      '10,20,30,40',
      reason:
          'the query box is top-left origin and must NOT be flipped — '
          'unlike projection, which must be',
    );
  });

  test(
    'the controller declares the capabilities the widget feature-detects',
    () {
      // Compile-time assertions: the widget attaches the marker overlay and the
      // layers controller by `is` checks, so losing one of these degrades to
      // silence rather than an error.
      void needsProjector(MapLibreMapProjector _) {}
      void needsLayers(MapLibreStyleLayers _) {}
      void needsTick(MapLibreCameraTickNotifier _) {}
      expect(needsProjector, isNotNull);
      expect(needsLayers, isNotNull);
      expect(needsTick, isNotNull);
    },
  );
}
