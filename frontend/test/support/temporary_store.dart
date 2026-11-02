import 'dart:io';

import 'package:ai_image_generator/core/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TemporaryStore {
  TemporaryStore({
    required this.root,
    required this.imagesPath,
    required this.store,
  });

  final Directory root;
  final String imagesPath;
  final LocalStore store;

  Future<void> delete() async {
    await store.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }
}

bool _factoryReady = false;

Future<TemporaryStore> openTemporaryStore() async {
  if (!_factoryReady) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _factoryReady = true;
  }
  final Directory root = await Directory.systemTemp.createTemp('ai_image_generator_');
  final String imagesPath = p.join(root.path, 'images');
  final LocalStore store = await LocalStore.openAt(
    databasePath: p.join(root.path, 'app.db'),
    imagesPath: imagesPath,
  );
  expect(root.path.startsWith(Directory.systemTemp.path), isTrue);
  expect(root.path.contains('${Platform.pathSeparator}Documents'), isFalse);
  expect(imagesPath.startsWith(root.path), isTrue);
  return TemporaryStore(root: root, imagesPath: imagesPath, store: store);
}
