import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrib_desktop/services/atomic_write.dart';

/// Tests the Windows-atomic-rename helper. The critical property: writing
/// over an existing file must succeed, and on Windows must not leave
/// `.tmp` or `.bak` files behind on the happy path.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_atomic_');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  String p(String name) => '${tmp.path}${Platform.pathSeparator}$name';

  test('writeBytes creates a new file', () async {
    final path = p('new.bin');
    final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
    await AtomicWrite.writeBytes(path, bytes);
    expect(await File(path).readAsBytes(), bytes);
  });

  test('writeBytes overwrites an existing file', () async {
    final path = p('existing.bin');
    await File(path).writeAsBytes([9, 9, 9]);
    await AtomicWrite.writeBytes(path, Uint8List.fromList([1, 2, 3]));
    expect(await File(path).readAsBytes(), [1, 2, 3]);
  });

  test('writeString round-trips', () async {
    final path = p('note.txt');
    await AtomicWrite.writeString(path, 'hello world');
    expect(await File(path).readAsString(), 'hello world');
  });

  test('no .tmp file remains after successful write', () async {
    final path = p('clean.bin');
    await AtomicWrite.writeBytes(path, Uint8List.fromList([1]));
    final tmpFile = File('$path.tmp');
    expect(await tmpFile.exists(), isFalse);
  });

  test('recoverIfNeeded removes orphaned .tmp files', () async {
    await File(p('orphan.tmp')).writeAsBytes([0]);
    await AtomicWrite.recoverIfNeeded(tmp.path);
    expect(await File(p('orphan.tmp')).exists(), isFalse);
  });

  test('recoverIfNeeded restores .bak when primary is missing', () async {
    // Simulate crash: user has a .bak but no primary.
    await File(p('note.txt.bak')).writeAsString('recovered');
    await AtomicWrite.recoverIfNeeded(tmp.path);
    expect(await File(p('note.txt')).exists(), isTrue);
    expect(await File(p('note.txt')).readAsString(), 'recovered');
    expect(await File(p('note.txt.bak')).exists(), isFalse);
  });

  test('recoverIfNeeded deletes .bak when primary exists (stale backup)', () async {
    await File(p('note.txt')).writeAsString('current');
    await File(p('note.txt.bak')).writeAsString('stale');
    await AtomicWrite.recoverIfNeeded(tmp.path);
    expect(await File(p('note.txt')).readAsString(), 'current');
    expect(await File(p('note.txt.bak')).exists(), isFalse);
  });

  test('recoverIfNeeded is a no-op on a clean directory', () async {
    await File(p('a.txt')).writeAsString('a');
    await File(p('b.txt')).writeAsString('b');
    await AtomicWrite.recoverIfNeeded(tmp.path);
    expect(await File(p('a.txt')).readAsString(), 'a');
    expect(await File(p('b.txt')).readAsString(), 'b');
  });

  test('recoverIfNeeded on non-existent directory does not throw', () async {
    await AtomicWrite.recoverIfNeeded('${tmp.path}/does-not-exist');
  });
}
