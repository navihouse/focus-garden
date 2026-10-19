import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import '../domain/models.dart';

class LocalStore extends GeneratedDatabase {
  LocalStore(File file) : super(NativeDatabase.createInBackground(file));
  LocalStore.testing(super.executor);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(onCreate: (m) async {
        await customStatement(
            'CREATE TABLE tasks (id TEXT PRIMARY KEY, data TEXT NOT NULL)');
        await customStatement(
            'CREATE TABLE sessions (id TEXT PRIMARY KEY, data TEXT NOT NULL)');
        await customStatement(
            'CREATE TABLE state (id TEXT PRIMARY KEY, data TEXT NOT NULL)');
      });
  Future<List<TaskItem>> tasks() async =>
      (await customSelect('SELECT data FROM tasks').get())
          .map((r) =>
              TaskItem.fromJson(asJson(jsonDecode(r.read<String>('data')))))
          .toList();
  Future<List<FocusSession>> sessions() async =>
      (await customSelect('SELECT data FROM sessions').get())
          .map((r) =>
              FocusSession.fromJson(asJson(jsonDecode(r.read<String>('data')))))
          .toList();
  Future<void> task(TaskItem task) => customStatement(
      'INSERT OR REPLACE INTO tasks VALUES (?,?)',
      [task.id, jsonEncode(task.toJson())]);
  Future<void> session(FocusSession session, {bool replace = false}) =>
      customStatement(
          'INSERT OR ${replace ? 'REPLACE' : 'IGNORE'} INTO sessions VALUES (?,?)',
          [session.id, jsonEncode(session.toJson())]);
  Future<void> put(String id, Object value) => customStatement(
      'INSERT OR REPLACE INTO state VALUES (?,?)', [id, jsonEncode(value)]);
  Future<Object?> get(String id) async {
    final row = await customSelect('SELECT data FROM state WHERE id = ?',
        variables: [Variable(id)]).getSingleOrNull();
    return row == null ? null : jsonDecode(row.read<String>('data'));
  }

  Future<void> remove(String id) =>
      customStatement('DELETE FROM state WHERE id = ?', [id]);
  Future<void> commitCheckpoint(FocusSession s) =>
      put('checkpoint', s.toJson());
  Future<void> commitSession(FocusSession s) => transaction(() async {
        await session(s);
        await remove('checkpoint');
      });
}
