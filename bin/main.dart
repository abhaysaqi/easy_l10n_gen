import 'dart:io';

import 'package:easy_l10n_gen/easy_l10n_gen.dart';

Future<void> main() async {
  _printHeader();

  final locales = _askForLocales();

  if (locales == null) {
    stderr.writeln('❌ Error: Invalid or empty language selection.');
    exitCode = 1;
    return;
  }

  final inputPath = _askForInputPath();

  if (inputPath == null) {
    stderr.writeln('❌ Error: File path cannot be empty or invalid.');
    exitCode = 1;
    return;
  }

  _printSeparator();
  print('🚀 Starting localization generation...');
  _printSeparator();

  try {
    final generator = L10nGenerator(
      inputPath: inputPath,
      requestedLocales: locales,
    );

    await generator.run();

    print('\n${'=' * 60}');
    print('✅ Localization generation process finished.');
    print('=' * 60);

    print('\n📦 Expected output files:');
    print('   • lib/l10n/app_en.arb');
    print('   • lib/l10n/app_*.arb');
    print('   • lib/l10n/l10n_extension.dart');
    print('   • l10n.yaml');

    print('\n🎯 Next Steps:');
    print('   1. Add flutter_localizations to pubspec.yaml.');
    print('   2. Set generate: true under flutter: in pubspec.yaml.');
    print('   3. Run: flutter pub get');
    print('   4. Run: flutter gen-l10n');
    print('   5. Use: context.l10n.yourVariableName');

    print('\n💡 Import the extension:');
    print(
      "   import 'package:your_app/l10n/l10n_extension.dart';",
    );

    print('\n⚠️ Review untranslated fallback strings before releasing.');
  } catch (e, stackTrace) {
    stderr.writeln('\n❌ Localization generation failed: $e');
    stderr.writeln(stackTrace);
    exitCode = 1;
  }
}

// ------------------------------------------------------------
// HEADER
// ------------------------------------------------------------

void _printHeader() {
  print('\n🌍 Welcome to easy_l10n_gen');
  print('   Flutter Localization Generator\n');
}

void _printSeparator() {
  print('=' * 60);
}

// ------------------------------------------------------------
// LOCALE INPUT
// ------------------------------------------------------------

List<String>? _askForLocales() {
  print('📝 Enter language codes (comma-separated) or type "all".');
  print('   Examples: en,es,fr');
  print('             hi,pa,de');
  print('             all');

  print('\n   Type "help" to see available language codes.');

  stdout.write('\n➤ ');

  final input = stdin.readLineSync();

  if (input == null || input.trim().isEmpty) {
    return null;
  }

  final normalizedInput = input.trim().toLowerCase();

  if (normalizedInput == 'help') {
    _printAvailableLocales();
    return _askForLocales();
  }

  final locales = normalizedInput
      .split(',')
      .map((locale) => locale.trim())
      .where((locale) => locale.isNotEmpty)
      .toSet()
      .toList();

  if (locales.isEmpty) {
    return null;
  }

  if (locales.contains('all')) {
    if (locales.length > 1) {
      stderr.writeln(
        '⚠️ "all" cannot be combined with individual locale codes.',
      );
      return null;
    }

    return ['all'];
  }

  final supportedLocales = L10nGenerator.allLocales.toSet();

  final invalidLocales =
      locales.where((locale) => !supportedLocales.contains(locale)).toList();

  if (invalidLocales.isNotEmpty) {
    stderr.writeln(
      '\n❌ Unsupported language codes: ${invalidLocales.join(', ')}',
    );

    stderr.writeln(
      '💡 Type "help" to see the supported language codes.',
    );

    return null;
  }

  return locales;
}

void _printAvailableLocales() {
  print('\n🌐 Supported language codes:\n');

  final locales = L10nGenerator.allLocales;

  for (var i = 0; i < locales.length; i += 10) {
    final end = (i + 10 < locales.length) ? i + 10 : locales.length;

    print('   ${locales.sublist(i, end).join(', ')}');
  }

  print('\n   Total: ${locales.length} languages\n');
}

// ------------------------------------------------------------
// SOURCE FILE INPUT
// ------------------------------------------------------------

String? _askForInputPath() {
  print('\n📂 Enter the path to your Dart file containing strings.');
  print('   Examples:');
  print('   lib/constants/app_strings.dart');
  print('   lib/core/constants/app_strings.dart');

  stdout.write('\n➤ ');

  final input = stdin.readLineSync();

  if (input == null || input.trim().isEmpty) {
    return null;
  }

  final path = input.trim();
  final file = File(path);

  if (!file.existsSync()) {
    stderr.writeln('\n❌ File not found: $path');
    return null;
  }

  if (!path.endsWith('.dart')) {
    stderr.writeln('\n❌ Please provide a Dart (.dart) file.');
    return null;
  }

  return path;
}
