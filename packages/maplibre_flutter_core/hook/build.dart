import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'package:logging/logging.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final packageName = input.packageName;
    final cbuilder = CBuilder.library(
      name: packageName,
      // Bindings live under lib/src/, so the asset id must match that path or
      // the @Native resolver looks in the wrong place.
      assetName: 'src/${packageName}_bindings_generated.dart',
      sources: ['src/$packageName.c'],
    );
    await cbuilder.run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = .ALL
        // ignore: avoid_print
        ..onRecord.listen((record) => print(record.message)),
    );
  });
}
