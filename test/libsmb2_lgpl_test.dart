import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// libsmb2 is LGPL-2.1 and is linked statically into the iOS app, so
/// LGPL-2.1 §6(a) requires the library's object code to accompany the app.
/// Every link in that chain is pinned here, because each one can break
/// silently: the build script can stop packaging the objects, the pubspec can
/// stop declaring the asset, the app can stop copying it somewhere the user
/// can reach, and the CI gate can stop running. None of those break the
/// build — they just quietly break the license.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String read(String path) => File(path).readAsStringSync();

  test('the vendored library really is LGPL-2.1', () {
    final licence = read('ios/Runner/libsmb2/LICENCE-LGPL-2.1.txt');
    expect(licence, contains('GNU LESSER GENERAL PUBLIC LICENSE'));
    expect(licence, contains('Version 2.1'));
    // §6 is the clause that makes the object code mandatory.
    expect(licence, contains('object code'));
  });

  test('the build script packages the object code', () {
    final script = read('ios/libsmb2_build.sh');
    expect(script, contains('libsmb2-objects.zip'));
    expect(script, contains('RELINK.txt'));
    expect(script, contains('LICENCE-LGPL-2.1.txt'));
    // The relinkable form is the individual object files, not the archive.
    expect(script, contains(r'cp "$OBJ_DIR"/*.o'));
    // The sources travel too, so the material is self-contained.
    expect(script, contains('source/'));
  });

  test('the packaged archive is declared as a Flutter asset', () {
    final pubspec = read('pubspec.yaml');
    expect(pubspec, contains('assets/libsmb2-objects/'));
  });

  test('the app copies the archive somewhere the user can reach', () {
    final service = read('lib/services/libsmb2_object_code.dart');
    expect(service, contains('assets/libsmb2-objects/libsmb2-objects.zip'));
    // Documents is the directory iOS exposes through the Files app.
    expect(service, contains('getApplicationDocumentsDirectory'));
  });

  test('the licences screen credits libsmb2 and points at the material', () {
    final screen = read('lib/screens/licenses_screen.dart');
    expect(screen, contains('libsmb2'));
    expect(screen, contains('GNU LGPL v2.1'));
    expect(screen, contains('LibSmb2ObjectCode'));
  });

  test('CI fails the build when the IPA has no object code', () {
    final workflow = read('.github/workflows/ios.yml');
    expect(workflow, contains('tool/verify_ipa_libsmb2.py'));
    final verifier = read('tool/verify_ipa_libsmb2.py');
    expect(verifier, contains('libsmb2-objects.zip'));
    expect(verifier, contains('LICENCE-LGPL-2.1.txt'));
  });

  test('the generated archive is not committed', () {
    // It is build output; committing it would make the tree lie about what
    // the build produces.
    final gitignore = read('.gitignore');
    expect(gitignore, contains('assets/libsmb2-objects/*.zip'));
  });
}
