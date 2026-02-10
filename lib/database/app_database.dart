import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

part 'app_database.g.dart';

// This table mirrors your API product structure
class LocalProducts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get productId => text().nullable()(); 
  TextColumn get productName => text().nullable()();
  TextColumn get barcode => text().nullable()();
  TextColumn get productBrand => text().nullable()();
  TextColumn get productCategory => text().nullable()();
  // FIXED: Removed illegal characters '监听'
  BoolColumn get syncRequired => boolean().withDefault(const Constant(false))();
}

@DriftDatabase(tables: [LocalProducts])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 1;

  // FIXED: Drift names generated classes by stripping the 's' (LocalProducts -> LocalProduct)
  Future insertOrUpdateProduct(LocalProduct product) => 
      into(localProducts).insertOnConflictUpdate(product);

  Future<List<LocalProduct>> getAllCachedProducts() => select(localProducts).get();

  Future<List<LocalProduct>> getPendingSync() => 
      (select(localProducts)..where((t) => t.syncRequired.equals(true))).get();

  // Return a product that already has this barcode, or null.
  Future<LocalProduct?> findByBarcode(String barcode) async {
    final query = (select(localProducts)..where((t) => t.barcode.equals(barcode)));
    return query.getSingleOrNull();
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'db.sqlite'));
    return NativeDatabase(file);
  });
}