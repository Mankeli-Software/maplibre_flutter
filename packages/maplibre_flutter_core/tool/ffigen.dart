// Regenerate desktop core bindings with: `dart run tool/ffigen.dart`
//
// Per CLAUDE.md §5 the generator is configured here in Dart (no YAML). Dart FFI
// cannot bind C++ directly, so we ffigen the thin C ABI shim header in `src/`
// (`maplibre_flutter_core.h`) that wraps mbgl-core's C++ API. The output is
// committed and must never be hand-edited.
import 'dart:io';

import 'package:ffigen/ffigen.dart';
import 'package:logging/logging.dart';

void main() {
  Logger.root.onRecord.listen(
    (r) => stderr.writeln('${r.level}: ${r.message}'),
  );

  FfiGenerator(
    output: Output(
      dartFile: Uri.file(
        'lib/src/maplibre_flutter_core_bindings_generated.dart',
      ),
      style: const NativeExternalBindings(),
      commentType: const CommentType.def(),
    ),
    headers: Headers(entryPoints: [Uri.file('src/maplibre_flutter_core.h')]),
    functions: Functions.includeAll,
    structs: Structs.includeAll,
    enums: Enums.includeAll,
    unnamedEnums: UnnamedEnums.includeAll,
    macros: Macros.includeAll,
    globals: Globals.includeAll,
    typedefs: Typedefs.includeAll,
  ).generate(logger: Logger.root);
}
