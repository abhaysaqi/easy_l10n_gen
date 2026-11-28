import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:translator/translator.dart';

/// Extracts Dart strings and generates Flutter ARB localization files.
class L10nGenerator {
  final String inputPath;
  final List<String> locales;

  final GoogleTranslator _translator = GoogleTranslator();

  /// Supported language codes.
  static const List<String> allLocales = [
    'af',
    'sq',
    'am',
    'ar',
    'hy',
    'as',
    'ay',
    'az',
    'bm',
    'eu',
    'be',
    'bn',
    'bho',
    'bs',
    'bg',
    'ca',
    'ceb',
    'zh-cn',
    'zh-tw',
    'co',
    'hr',
    'cs',
    'da',
    'dv',
    'doi',
    'nl',
    'en',
    'eo',
    'et',
    'ee',
    'fil',
    'fi',
    'fr',
    'fy',
    'gaa',
    'gl',
    'ka',
    'de',
    'el',
    'gn',
    'gu',
    'ht',
    'ha',
    'haw',
    'iw',
    'he',
    'hi',
    'hmn',
    'hu',
    'is',
    'ig',
    'ilo',
    'id',
    'ga',
    'it',
    'ja',
    'jv',
    'kn',
    'kk',
    'km',
    'rw',
    'gom',
    'ko',
    'kri',
    'ku',
    'ckb',
    'ky',
    'lo',
    'la',
    'lv',
    'ln',
    'lt',
    'lg',
    'lb',
    'mk',
    'mai',
    'mg',
    'ms',
    'ml',
    'mt',
    'mi',
    'mr',
    'mni-mtei',
    'lus',
    'mn',
    'my',
    'ne',
    'no',
    'ny',
    'or',
    'om',
    'ps',
    'fa',
    'pl',
    'pt',
    'pa',
    'qu',
    'ro',
    'ru',
    'sm',
    'sa',
    'gd',
    'nso',
    'sr',
    'st',
    'sn',
    'sd',
    'si',
    'sk',
    'sl',
    'so',
    'es',
    'su',
    'sw',
    'sv',
    'tl',
    'tg',
    'ta',
    'tt',
    'te',
    'th',
    'ti',
    'ts',
    'tr',
    'tk',
    'ak',
    'uk',
    'ur',
    'ug',
    'uz',
    'vi',
    'cy',
    'xh',
    'yi',
    'yo',
    'zu',
  ];

  /// Matches simple ARB placeholders such as {name}.
  static final RegExp _placeholderRegex =
      RegExp(r'\{([a-zA-Z_][a-zA-Z0-9_]*)\}');

  /// Matches the beginning of an ICU plural expression.
  static final RegExp _pluralRegex = RegExp(
    r'\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*,\s*plural\s*,',
  );
  final Future<String> Function(String text, String to)? translateOverride;

  L10nGenerator({
    required this.inputPath,
    required List<String> requestedLocales,
    this.translateOverride,
  }) : locales = _normalizeLocales(requestedLocales);

  static List<String> _normalizeLocales(List<String> requestedLocales) {
    final requested = requestedLocales
        .map((locale) => locale.trim().toLowerCase())
        .where((locale) => locale.isNotEmpty)
        .toList();

    final selected = requested.contains('all') ? allLocales : requested;

    return selected.toSet().toList();
  }

  static const Map<String, String> _arbOverrides = {
    'zh-cn': 'zh_Hans',
    'zh-tw': 'zh_Hant',
    'iw': 'he',
    'mni-mtei': 'mni',
  };

  /// Converts a translator code (zh-cn) to an ARB locale (zh_Hans).
  String _arbLocale(String code) =>
      _arbOverrides[code] ?? code.replaceAll('-', '_');

  /// Main generation process.
  Future<void> run() async {
    final libDir = Directory('lib');

    if (!libDir.existsSync()) {
      print(
        '❌ Error: "lib" folder not found. '
        'Please run this from the root of a Flutter project.',
      );
      return;
    }

    final file = File(inputPath);

    if (!file.existsSync()) {
      print('❌ Error: Input file not found: $inputPath');
      return;
    }

    try {
      final content = await file.readAsString();

      // Parse Dart source into an AST.
      final result = parseString(content: content);

      final Map<String, String> sourceData = {};

      for (final declaration in result.unit.declarations) {
        if (declaration is! ClassDeclaration) continue;

        for (final member in declaration.members) {
          if (member is! FieldDeclaration || !member.isStatic) {
            continue;
          }

          for (final variable in member.fields.variables) {
            final initializer = variable.initializer;

            if (initializer is StringLiteral) {
              final value = initializer.stringValue;
              if (value == null) {
                print(
                    '⚠️ Skipped "${variable.name.lexeme}" (uses \$ interpolation)');
                continue;
              }
              sourceData[variable.name.lexeme] = value;
            }
          }
        }
      }

      if (sourceData.isEmpty) {
        print(
          '⚠️ No static strings found. '
          'Use: static const String key = "value";',
        );
        return;
      }

      // English is always the master ARB file.
      final targetLocales = {
        'en',
        ...locales,
      }.toList();

      print('\n⏳ Found ${sourceData.length} source strings.');
      print('🌍 Generating ${targetLocales.length} locale files...\n');

      await _writeArbFiles(sourceData, targetLocales);

      _writeYaml();
      _writeExtension();

      print('\n🚀 Localization files generated successfully!');
      print('📁 ARB directory: lib/l10n');
    } catch (e, stackTrace) {
      print('❌ Generation failed: $e');
      print(stackTrace);
    }
  }

  // ------------------------------------------------------------
  // ARB GENERATION
  // ------------------------------------------------------------

  Future<void> _writeArbFiles(
    Map<String, String> sourceData,
    List<String> targetLocales,
  ) async {
    final dir = Directory('lib/l10n');

    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }

    // Always generate the English master file first.
    await _writeEnglishArb(sourceData);

    for (final locale in targetLocales) {
      if (locale == 'en') continue;

      print('🌍 Processing [$locale]...');

      final arb = _arbLocale(locale);

      final file = File('lib/l10n/app_$arb.arb');

      final existingContent = await _readArb(file);

      final finalContent = <String, dynamic>{
        ...existingContent,
        '@@locale': arb,
      };

      var translatedCount = 0;
      var preservedCount = 0;
      var missingCount = 0;

      for (final entry in sourceData.entries) {
        final key = entry.key;
        final sourceValue = entry.value;

        final existingValue = existingContent[key];

        // Preserve existing non-empty translations.
        if (existingValue is String && existingValue.trim().isNotEmpty) {
          final errors = _validatePlaceholders(
            key: key,
            source: sourceValue,
            target: existingValue,
          );

          if (errors.isNotEmpty) {
            print('⚠️ Placeholder warning in [$locale]:');
            for (final error in errors) {
              print('   $error');
            }
          }

          finalContent[key] = existingValue;
          preservedCount++;

          // Keep existing metadata, but generate it if absent.
          finalContent.putIfAbsent(
            '@$key',
            () => _generateMetadata(sourceValue),
          );

          continue;
        }

        // ICU plural expressions should not be translated as plain text.
        // Preserve the key using the English source as a fallback.
        if (_isIcuPlural(sourceValue)) {
          print(
            '⚠️ [$locale] "$key" contains ICU plural syntax. '
            'Skipped; translate it manually in app_$arb.arb.',
          );

          missingCount++;
          continue;
        }

        // Translate missing simple strings.
        final translatedValue = await _translateSafely(
          sourceValue,
          locale,
          key,
        );

        if (translatedValue == null) {
          missingCount++;
          continue; // not saved, so it will be retried next run
        }
        finalContent[key] = translatedValue;
        finalContent['@$key'] = _generateMetadata(sourceValue);
        translatedCount++;
      }

      // Keep unrelated existing ARB metadata and entries.
      await _writeJson(file, finalContent);

      print(
        '   ✅ Translated: $translatedCount'
        ' | Preserved: $preservedCount'
        ' | Needs attention: $missingCount',
      );

      // Report keys that are missing or empty.
      final missingKeys = _findMissingKeys(
        sourceData.keys.toSet(),
        finalContent,
      );

      if (missingKeys.isNotEmpty) {
        print('   ⚠️ Missing keys: ${missingKeys.join(', ')}');
      }
    }
  }

  Future<void> _writeEnglishArb(
    Map<String, String> sourceData,
  ) async {
    final file = File('lib/l10n/app_en.arb');

    final existingContent = await _readArb(file);

    final finalContent = <String, dynamic>{
      ...existingContent,
      '@@locale': 'en',
    };

    for (final entry in sourceData.entries) {
      finalContent[entry.key] = entry.value;
      finalContent['@${entry.key}'] = _generateMetadata(entry.value);
    }

    await _writeJson(file, finalContent);

    print('✅ English master ARB generated.');
  }

  Future<Map<String, dynamic>> _readArb(File file) async {
    if (!await file.exists()) {
      return {};
    }

    try {
      final content = await file.readAsString();

      if (content.trim().isEmpty) {
        return {};
      }

      final decoded = jsonDecode(content);

      if (decoded is Map<String, dynamic>) {
        return decoded;
      }

      print('⚠️ Invalid ARB structure in ${file.path}.');
      return {};
    } catch (e) {
      print('⚠️ Could not read ${file.path}: $e');
      return {};
    }
  }

  Future<void> _writeJson(
    File file,
    Map<String, dynamic> content,
  ) async {
    final encoder = const JsonEncoder.withIndent('  ');

    await file.writeAsString(
      encoder.convert(content),
      flush: true,
    );
  }

  // ------------------------------------------------------------
  // TRANSLATION
  // ------------------------------------------------------------

  Future<String?> _translateSafely(
    String source,
    String locale,
    String key,
  ) async {
    if (source.trim().isEmpty) {
      return source;
    }

    try {
      // Protect placeholders before sending text to the translator.
      final protected = _protectPlaceholders(source);

      final translatedText = translateOverride != null
          ? await translateOverride!(protected.text, locale)
          : (await _translator.translate(
              protected.text,
              from: 'en',
              to: locale,
            ))
              .text;

      // Do not save a translation if placeholders were changed.
      final translated = _restorePlaceholders(
        translatedText,
        protected.placeholders,
      );

      if (translated == null) {
        print(
          '⚠️ [$locale] Placeholder protection failed for "$key". '
          'Skipped; it will be retried next run.',
        );
        return null;
      }

      return translated;
    } catch (e) {
      print('❌ Translation failed for "$key" [$locale]: $e');
      return null;
    }
  }

  _ProtectedText _protectPlaceholders(String source) {
    final placeholders = <String, String>{};

    var index = 0;

    final protectedText = source.replaceAllMapped(
      _placeholderRegex,
      (match) {
        final placeholder = match.group(0)!;

        final token = '__L10N_PLACEHOLDER_${index}__';

        placeholders[token] = placeholder;
        index++;

        return token;
      },
    );

    return _ProtectedText(
      text: protectedText,
      placeholders: placeholders,
    );
  }

  String? _restorePlaceholders(
    String translated,
    Map<String, String> placeholders,
  ) {
    var result = translated;

    for (final entry in placeholders.entries) {
      if (!result.contains(entry.key)) {
        return null;
      }

      result = result.replaceAll(entry.key, entry.value);
    }

    return result;
  }

  // ------------------------------------------------------------
  // PLACEHOLDER VALIDATION
  // ------------------------------------------------------------

  Set<String> _extractPlaceholders(String value) {
    return _placeholderRegex
        .allMatches(value)
        .map((match) => match.group(1)!)
        .toSet();
  }

  List<String> _validatePlaceholders({
    required String key,
    required String source,
    required String target,
  }) {
    final sourcePlaceholders = _extractPlaceholders(source);
    final targetPlaceholders = _extractPlaceholders(target);

    final missing = sourcePlaceholders.difference(targetPlaceholders);
    final unexpected = targetPlaceholders.difference(sourcePlaceholders);

    final errors = <String>[];

    if (missing.isNotEmpty) {
      errors.add(
        '$key: Missing placeholders: ${missing.join(', ')}',
      );
    }

    if (unexpected.isNotEmpty) {
      errors.add(
        '$key: Unexpected placeholders: ${unexpected.join(', ')}',
      );
    }

    return errors;
  }

  // ------------------------------------------------------------
  // ICU PLURAL SUPPORT
  // ------------------------------------------------------------

  bool _isIcuPlural(String value) {
    return _pluralRegex.hasMatch(value);
  }

  Set<String> _extractPluralVariables(String value) {
    return _pluralRegex
        .allMatches(value)
        .map((match) => match.group(1)!)
        .toSet();
  }

  /// Generates ARB metadata for placeholders.
  ///
  /// ICU plural variables use int.
  /// Other placeholders use String by default.
  Map<String, dynamic> _generateMetadata(String value) {
    final placeholders = _extractPlaceholders(value);

    if (placeholders.isEmpty) {
      return {};
    }

    final pluralVariables = _extractPluralVariables(value);

    return {
      'placeholders': {
        for (final placeholder in placeholders)
          placeholder: {
            'type': pluralVariables.contains(placeholder) ? 'int' : 'String',
          },
      },
    };
  }

  // ------------------------------------------------------------
  // MISSING KEY DETECTION
  // ------------------------------------------------------------

  List<String> _findMissingKeys(
    Set<String> sourceKeys,
    Map<String, dynamic> targetContent,
  ) {
    return sourceKeys.where((key) {
      final value = targetContent[key];

      return value is! String || value.trim().isEmpty;
    }).toList();
  }

  // ------------------------------------------------------------
  // FLUTTER CONFIGURATION
  // ------------------------------------------------------------

  void _writeYaml() {
    File('l10n.yaml').writeAsStringSync('''arb-dir: lib/l10n
template-arb-file: app_en.arb
output-localization-file: app_localizations.dart
''');
  }

  void _writeExtension() {
    File('lib/l10n/l10n_extension.dart').writeAsStringSync('''
import 'package:flutter/widgets.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this)!;
}
''');
  }
}

/// Holds protected text and its original placeholders.
class _ProtectedText {
  final String text;
  final Map<String, String> placeholders;

  const _ProtectedText({
    required this.text,
    required this.placeholders,
  });
}
