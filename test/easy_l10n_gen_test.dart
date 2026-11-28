import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_l10n_gen/easy_l10n_gen.dart';
import 'package:test/test.dart';

late Directory _originalDir;
late Directory _tempDir;

// ---------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------

typedef FakeTranslate = Future<String> Function(String text, String to);

/// Default fake: tests must never reach the real network.
Future<String> _noNetwork(String text, String to) async =>
    throw Exception('Network disabled in tests');

void writeSource(String source) =>
    File('lib/strings.dart').writeAsStringSync(source);

void seedArb(String name, Map<String, dynamic> content) {
  Directory('lib/l10n').createSync(recursive: true);
  File('lib/l10n/$name').writeAsStringSync(jsonEncode(content));
}

Map<String, dynamic> readArb(String name) =>
    jsonDecode(File('lib/l10n/$name').readAsStringSync())
        as Map<String, dynamic>;

Set<String> messageKeys(Map<String, dynamic> arb) =>
    arb.keys.where((k) => !k.startsWith('@')).toSet();

/// Runs the generator and returns everything it printed.
Future<List<String>> generate(
  List<String> locales, {
  FakeTranslate translate = _noNetwork,
}) async {
  final logs = <String>[];

  await runZoned(
    () => L10nGenerator(
      inputPath: 'lib/strings.dart',
      requestedLocales: locales,
      translateOverride: translate,
    ).run(),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => logs.add(line),
    ),
  );

  return logs;
}

void main() {
  setUp(() {
    _originalDir = Directory.current;
    _tempDir = Directory.systemTemp.createTempSync('l10n_test_');
    Directory.current = _tempDir;
    Directory('lib').createSync();
  });

  tearDown(() {
    Directory.current = _originalDir;
    _tempDir.deleteSync(recursive: true);
  });

  // ---------------------------------------------------------------
  // Locale normalisation (no file IO)
  // ---------------------------------------------------------------
  group('locale normalisation', () {
    L10nGenerator make(List<String> l) =>
        L10nGenerator(inputPath: 'x.dart', requestedLocales: l);

    test('trims, lowercases and removes duplicates', () {
      expect(make([' HI ', 'hi', 'Pa']).locales, ['hi', 'pa']);
    });

    test('"all" expands to every supported locale', () {
      expect(
        make(['all']).locales.toSet(),
        L10nGenerator.allLocales.toSet(),
      );
    });

    test('allLocales has no duplicates and includes en', () {
      final all = L10nGenerator.allLocales;
      expect(all.toSet().length, all.length);
      expect(all, contains('en'));
    });
  });

  // ---------------------------------------------------------------
  // Extraction: class styles
  // ---------------------------------------------------------------
  group('string extraction', () {
    test('simple class', () async {
      writeSource(r'''
class AppStrings {
  static const String welcome = "Welcome back";
  static const String loginAction = "Sign In";
}
''');

      await generate(['en']);

      final en = readArb('app_en.arb');
      expect(messageKeys(en), {'welcome', 'loginAction'});
      expect(en['welcome'], 'Welcome back');
      expect(en['@@locale'], 'en');
    });

    test('class with private constructor', () async {
      writeSource(r'''
class AppTexts {
  AppTexts._();

  static const String login = "Sign In";
  static const String logout = "Log out";
}
''');

      await generate(['en']);

      expect(messageKeys(readArb('app_en.arb')), {'login', 'logout'});
    });

    test('abstract final class', () async {
      writeSource(r'''
abstract final class AppLabels {
  static const String logout = "Log out";
  static final String retry = "Try again";
}
''');

      await generate(['en']);

      final en = readArb('app_en.arb');
      expect(messageKeys(en), {'logout', 'retry'});
      expect(en['retry'], 'Try again');
    });

    test('multiple classes in one file are merged', () async {
      writeSource(r'''
class A { static const String one = "One"; }
abstract final class B { static const String two = "Two"; }
class C { C._(); static const String three = "Three"; }
''');

      await generate(['en']);

      expect(messageKeys(readArb('app_en.arb')), {'one', 'two', 'three'});
    });

    test('ignores non-static, non-string and getter members', () async {
      writeSource(r'''
class AppStrings {
  static const String kept = "Kept";
  static const int count = 5;
  final String instanceField = "Nope";
  String get title => "Getter";
}
''');

      await generate(['en']);

      expect(messageKeys(readArb('app_en.arb')), {'kept'});
    });

    test('skips strings with interpolation and warns', () async {
      writeSource(r'''
class AppStrings {
  static const String ok = "Fine";
  static final String bad = "Hi $name";
}
''');

      final logs = await generate(['en']);

      expect(messageKeys(readArb('app_en.arb')), {'ok'});
      expect(logs.any((l) => l.contains('Skipped "bad"')), isTrue);
    });

    test('no static strings: warns and writes nothing', () async {
      writeSource('class Empty {}');

      final logs = await generate(['en']);

      expect(logs.any((l) => l.contains('No static strings found')), isTrue);
      expect(Directory('lib/l10n').existsSync(), isFalse);
    });

    test('missing lib folder is reported', () async {
      Directory('lib').deleteSync(recursive: true);

      final logs = await generate(['en']);

      expect(logs.any((l) => l.contains('"lib" folder not found')), isTrue);
    });

    test('missing input file is reported', () async {
      final logs = await generate(['en']);

      expect(logs.any((l) => l.contains('Input file not found')), isTrue);
    });
  });

  // ---------------------------------------------------------------
  // English master ARB
  // ---------------------------------------------------------------
  group('English ARB', () {
    test('generates placeholder metadata', () async {
      writeSource(r'''
class AppStrings {
  static const String greeting = "Hello, {name}!";
  static const String items = "{count, plural, =0{No items} other{{count} items}}";
}
''');

      await generate(['en']);

      final en = readArb('app_en.arb');
      expect(en['@greeting']['placeholders']['name']['type'], 'String');
      expect(en['@items']['placeholders']['count']['type'], 'int');
    });

    test('keeps unrelated existing entries', () async {
      seedArb('app_en.arb', {'legacy': 'Old value'});
      writeSource(r'''
class AppStrings { static const String welcome = "Welcome"; }
''');

      await generate(['en']);

      final en = readArb('app_en.arb');
      expect(en['legacy'], 'Old value');
      expect(en['welcome'], 'Welcome');
    });

    test('updates changed English text', () async {
      seedArb('app_en.arb', {'welcome': 'Old text'});
      writeSource(r'''
class AppStrings { static const String welcome = "New text"; }
''');

      await generate(['en']);

      expect(readArb('app_en.arb')['welcome'], 'New text');
    });
  });

  // ---------------------------------------------------------------
  // Config files
  // ---------------------------------------------------------------
  group('config files', () {
    test('writes l10n.yaml and l10n_extension.dart', () async {
      writeSource(r'''
class AppStrings { static const String welcome = "Welcome"; }
''');

      await generate(['en']);

      final yaml = File('l10n.yaml').readAsStringSync();
      expect(yaml, contains('arb-dir: lib/l10n'));
      expect(yaml, contains('template-arb-file: app_en.arb'));

      final ext = File('lib/l10n/l10n_extension.dart').readAsStringSync();
      expect(ext, contains('extension AppLocalizationsX on BuildContext'));
      expect(ext, contains('AppLocalizations get l10n'));
    });
  });

  // ---------------------------------------------------------------
  // Other locales (pre-seeded, so no translation is needed)
  // ---------------------------------------------------------------
  group('other locales', () {
    test('existing translations are preserved', () async {
      seedArb('app_hi.arb', {'welcome': 'स्वागत है'});
      writeSource(r'''
class AppStrings { static const String welcome = "Welcome"; }
''');

      await generate(['hi']);

      final hi = readArb('app_hi.arb');
      expect(hi['welcome'], 'स्वागत है');
      expect(hi['@@locale'], 'hi');
    });

    test('placeholder mismatch in existing translation warns but keeps it',
        () async {
      seedArb('app_hi.arb', {'greeting': 'नमस्ते'});
      writeSource(r'''
class AppStrings { static const String greeting = "Hello, {name}!"; }
''');

      final logs = await generate(['hi']);

      expect(logs.any((l) => l.contains('Missing placeholders: name')), isTrue);
      expect(readArb('app_hi.arb')['greeting'], 'नमस्ते');
    });

    test('ICU plural is skipped, not saved as English', () async {
      seedArb('app_hi.arb', {'welcome': 'स्वागत है'});
      writeSource(r'''
class AppStrings {
  static const String welcome = "Welcome";
  static const String items = "{count, plural, =0{No items} other{{count} items}}";
}
''');

      final logs = await generate(['hi']);

      final hi = readArb('app_hi.arb');
      expect(hi.containsKey('items'), isFalse);
      expect(hi.containsKey('@items'), isFalse);
      expect(logs.any((l) => l.contains('ICU plural')), isTrue);
    });

    // translator code -> ARB file name
    const arbNames = {
      'zh-cn': 'zh_Hans',
      'zh-tw': 'zh_Hant',
      'iw': 'he',
      'mni-mtei': 'mni',
    };

    for (final entry in arbNames.entries) {
      test('${entry.key} is written as app_${entry.value}.arb', () async {
        seedArb('app_${entry.value}.arb', {'welcome': 'translated'});
        writeSource(r'''
class AppStrings { static const String welcome = "Welcome"; }
''');

        await generate([entry.key]);

        expect(
          File('lib/l10n/app_${entry.value}.arb').existsSync(),
          isTrue,
        );
        expect(readArb('app_${entry.value}.arb')['@@locale'], entry.value);

        if (entry.key.contains('-')) {
          expect(
            File('lib/l10n/app_${entry.key}.arb').existsSync(),
            isFalse,
          );
        }
      });
    }

    test('translator receives the original code, not the ARB code', () async {
      writeSource(r'''
class AppStrings { static const String welcome = "Welcome"; }
''');

      final receivedCodes = <String>[];

      await generate(['zh-cn'], translate: (text, to) async {
        receivedCodes.add(to);
        return '[$to] $text';
      });

      expect(receivedCodes, ['zh-cn']);
      expect(readArb('app_zh_Hans.arb')['welcome'], '[zh-cn] Welcome');
    });
  });

  // ---------------------------------------------------------------
  // Translation behaviour (fake translator)
  // ---------------------------------------------------------------
  group('translation (fake translator)', () {
    const source = r'''
class AppStrings {
  static const String welcome = "Welcome";
  static const String greeting = "Hello, {name}!";
}
''';

    test('translates missing keys and restores placeholders', () async {
      writeSource(source);

      await generate(['hi'], translate: (text, to) async => '[$to] $text');

      final hi = readArb('app_hi.arb');
      expect(hi['welcome'], '[hi] Welcome');
      expect(hi['greeting'], '[hi] Hello, {name}!');
      expect(hi['@greeting']['placeholders']['name']['type'], 'String');
    });

    test('failed translation is NOT saved, and is retried next run', () async {
      writeSource(source);

      // Run 1: translator fails (like a rate limit).
      await generate(
        ['hi'],
        translate: (text, to) async => throw Exception('429'),
      );

      expect(messageKeys(readArb('app_hi.arb')), isEmpty);

      // Run 2: translator works, so the keys are filled in.
      await generate(['hi'], translate: (text, to) async => '[$to] $text');

      final hi = readArb('app_hi.arb');
      expect(hi['welcome'], '[hi] Welcome');
      expect(hi['greeting'], '[hi] Hello, {name}!');
    });

    test('lost placeholder is NOT saved', () async {
      writeSource(source);

      // Fake translator that destroys the placeholder token.
      await generate(['hi'], translate: (text, to) async => 'नमस्ते');

      final hi = readArb('app_hi.arb');
      expect(hi.containsKey('greeting'), isFalse);
      expect(hi.containsKey('@greeting'), isFalse);
    });

    test('partial failure saves only the keys that worked', () async {
      writeSource(source);

      await generate(['hi'], translate: (text, to) async {
        if (text.contains('Hello')) throw Exception('boom');
        return '[$to] $text';
      });

      final hi = readArb('app_hi.arb');
      expect(hi['welcome'], '[hi] Welcome');
      expect(hi.containsKey('greeting'), isFalse);
    });

    test('existing translations are never overwritten', () async {
      seedArb('app_hi.arb', {'welcome': 'मौजूदा'});
      writeSource(source);

      await generate(['hi'], translate: (text, to) async => '[$to] $text');

      final hi = readArb('app_hi.arb');
      expect(hi['welcome'], 'मौजूदा');
      expect(hi['greeting'], '[hi] Hello, {name}!');
    });

    test('empty source string is kept without calling the translator',
        () async {
      writeSource(r'''
class AppStrings { static const String empty = ""; }
''');

      var calls = 0;

      await generate(['hi'], translate: (text, to) async {
        calls++;
        return text;
      });

      expect(calls, 0);
      expect(readArb('app_hi.arb').containsKey('empty'), isTrue);
    });
  });
}
