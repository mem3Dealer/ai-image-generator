import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'active_generation.dart';
import 'app_session.dart';
import 'generation_options.dart';
import 'history_entry.dart';
import 'subscription_status.dart';

class LocalStore {
  LocalStore._({
    required Database database,
    required Directory imagesDirectory,
  }) : _database = database,
       _imagesDirectory = imagesDirectory;

  final Database _database;
  final Directory _imagesDirectory;

  static Future<LocalStore> open() async {
    final Directory documents = await getApplicationDocumentsDirectory();
    return openAt(
      databasePath: p.join(documents.path, 'app.db'),
      imagesPath: p.join(documents.path, 'images'),
    );
  }

  static Future<LocalStore> openAt({
    required String databasePath,
    required String imagesPath,
  }) async {
    final Directory imagesDirectory = Directory(imagesPath);
    await imagesDirectory.create(recursive: true);
    final Database database = await openDatabase(
      databasePath,
      version: 1,
      onCreate: _createSchema,
    );
    return LocalStore._(database: database, imagesDirectory: imagesDirectory);
  }

  Future<void> close() {
    return _database.close();
  }

  Future<AppSession> ensureUserId() async {
    final AppSession session = await readSession();
    if (session.userId != null) {
      return session;
    }
    final String userId = const Uuid().v4().toLowerCase();
    await _database.insert('app_state', <String, Object?>{
      'id': 1,
      'user_id': userId,
    });
    return AppSession(
      userId: userId,
      subscriptionStatus: SubscriptionStatus.unknown,
      activeGeneration: session.activeGeneration,
    );
  }

  Future<AppSession> readSession() async {
    final List<Map<String, Object?>> identityRows = await _database.query(
      'app_state',
      limit: 1,
    );
    final List<Map<String, Object?>> activeRows = await _database.query(
      'active_generation',
      limit: 1,
    );
    return AppSession(
      userId: _readUserId(identityRows),
      subscriptionStatus: _readSubscription(identityRows),
      activeGeneration: _readActive(activeRows),
    );
  }

  Future<void> saveSubscription(SubscriptionStatus status) async {
    final int updated = await _database.update('app_state', <String, Object?>{
      'subscription_status': _storedSubscription(status),
    });
    if (updated == 0) {
      throw StateError('User id is not initialized');
    }
  }

  Future<void> saveActiveGeneration(ActiveGeneration generation) {
    return _database.insert(
      'active_generation',
      _activeRow(generation),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> clearActiveGeneration() {
    return _database.delete('active_generation');
  }

  Future<HistoryEntry> saveGeneration({
    required ActiveGeneration generation,
    required HistoryStatus status,
    Uint8List? imageBytes,
  }) async {
    final String? fileName = await _writeImage(generation.id, imageBytes);
    await _insertHistory(
      generation: generation,
      status: status,
      fileName: fileName,
    );
    return _historyEntry(
      generation: generation,
      status: status,
      fileName: fileName,
    );
  }

  Future<List<HistoryEntry>> readHistory() async {
    final List<Map<String, Object?>> rows = await _database.query(
      'history',
      orderBy: 'created_at DESC',
    );
    final List<HistoryEntry> entries = <HistoryEntry>[];
    for (final Map<String, Object?> row in rows) {
      entries.add(_historyFromRow(row));
    }
    return entries;
  }

  Future<String?> _writeImage(String generationId, Uint8List? imageBytes) async {
    if (imageBytes == null) {
      return null;
    }
    final String fileName = '$generationId.png';
    final File file = File(p.join(_imagesDirectory.path, fileName));
    await file.writeAsBytes(imageBytes, flush: true);
    return fileName;
  }

  Future<void> _insertHistory({
    required ActiveGeneration generation,
    required HistoryStatus status,
    required String? fileName,
  }) {
    return _database.transaction((Transaction transaction) async {
      await transaction.insert(
        'history',
        _historyRow(generation: generation, status: status, fileName: fileName),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await transaction.delete('active_generation');
    });
  }

  HistoryEntry _historyEntry({
    required ActiveGeneration generation,
    required HistoryStatus status,
    required String? fileName,
  }) {
    return HistoryEntry(
      id: generation.id,
      prompt: generation.prompt,
      options: generation.options,
      createdAt: generation.startedAt.toUtc(),
      status: status,
      imagePath: fileName == null ? null : p.join(_imagesDirectory.path, fileName),
    );
  }

  HistoryEntry _historyFromRow(Map<String, Object?> row) {
    final String? fileName = _optionalText(row, 'file_name');
    return HistoryEntry(
      id: _requiredText(row, 'generation_id'),
      prompt: _requiredText(row, 'prompt'),
      options: _optionsFromRow(row),
      createdAt: DateTime.parse(_requiredText(row, 'created_at')).toUtc(),
      status: _historyStatus(_requiredText(row, 'status')),
      imagePath: fileName == null ? null : p.join(_imagesDirectory.path, p.basename(fileName)),
    );
  }

  ActiveGeneration? _readActive(List<Map<String, Object?>> rows) {
    if (rows.isEmpty) {
      return null;
    }
    return _activeFromRow(rows.first);
  }

  ActiveGeneration _activeFromRow(Map<String, Object?> row) {
    return ActiveGeneration(
      id: _requiredText(row, 'generation_id'),
      prompt: _requiredText(row, 'prompt'),
      options: _optionsFromRow(row),
      startedAt: DateTime.parse(_requiredText(row, 'started_at')).toUtc(),
    );
  }
}

Future<void> _createSchema(Database database, int version) async {
  await database.execute(
    'CREATE TABLE app_state ('
    'id INTEGER PRIMARY KEY CHECK (id = 1), '
    'user_id TEXT NOT NULL, '
    'subscription_status TEXT CHECK (subscription_status IN (\'free\', \'premium\'))'
    ')',
  );
  await database.execute(
    'CREATE TABLE active_generation ('
    'id INTEGER PRIMARY KEY CHECK (id = 1), '
    'generation_id TEXT NOT NULL, '
    'prompt TEXT NOT NULL, '
    'style TEXT NOT NULL, '
    'aspect_ratio TEXT NOT NULL, '
    'quality TEXT NOT NULL, '
    'started_at TEXT NOT NULL'
    ')',
  );
  await database.execute(
    'CREATE TABLE history ('
    'generation_id TEXT PRIMARY KEY, '
    'prompt TEXT NOT NULL, '
    'style TEXT NOT NULL, '
    'aspect_ratio TEXT NOT NULL, '
    'quality TEXT NOT NULL, '
    'created_at TEXT NOT NULL, '
    'status TEXT NOT NULL CHECK (status IN (\'completed\', \'failed\')), '
    'file_name TEXT'
    ')',
  );
}

String? _readUserId(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) {
    return null;
  }
  return _requiredText(rows.first, 'user_id');
}

SubscriptionStatus _readSubscription(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) {
    return SubscriptionStatus.unknown;
  }
  return _subscriptionFromStored(_optionalText(rows.first, 'subscription_status'));
}

SubscriptionStatus _subscriptionFromStored(String? value) {
  if (value == 'free') {
    return SubscriptionStatus.free;
  }
  if (value == 'premium') {
    return SubscriptionStatus.premium;
  }
  return SubscriptionStatus.unknown;
}

String _storedSubscription(SubscriptionStatus status) {
  switch (status) {
    case SubscriptionStatus.free:
      return 'free';
    case SubscriptionStatus.premium:
      return 'premium';
    case SubscriptionStatus.unknown:
      throw ArgumentError('Unknown subscription is not stored');
  }
}

Map<String, Object?> _activeRow(ActiveGeneration generation) {
  return <String, Object?>{
    'id': 1,
    'generation_id': generation.id,
    'prompt': generation.prompt,
    'style': generation.options.style,
    'aspect_ratio': generation.options.aspectRatio,
    'quality': generation.options.quality,
    'started_at': generation.startedAt.toUtc().toIso8601String(),
  };
}

Map<String, Object?> _historyRow({
  required ActiveGeneration generation,
  required HistoryStatus status,
  required String? fileName,
}) {
  return <String, Object?>{
    'generation_id': generation.id,
    'prompt': generation.prompt,
    'style': generation.options.style,
    'aspect_ratio': generation.options.aspectRatio,
    'quality': generation.options.quality,
    'created_at': generation.startedAt.toUtc().toIso8601String(),
    'status': status.name,
    'file_name': fileName,
  };
}

GenerationOptions _optionsFromRow(Map<String, Object?> row) {
  return GenerationOptions(
    style: _requiredText(row, 'style'),
    aspectRatio: _requiredText(row, 'aspect_ratio'),
    quality: _requiredText(row, 'quality'),
  );
}

HistoryStatus _historyStatus(String value) {
  if (value == HistoryStatus.completed.name) {
    return HistoryStatus.completed;
  }
  if (value == HistoryStatus.failed.name) {
    return HistoryStatus.failed;
  }
  throw StateError('Unknown history status');
}

String _requiredText(Map<String, Object?> row, String key) {
  final Object? value = row[key];
  if (value is! String) {
    throw StateError('Expected text in $key');
  }
  return value;
}

String? _optionalText(Map<String, Object?> row, String key) {
  final Object? value = row[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw StateError('Expected text in $key');
  }
  return value;
}
