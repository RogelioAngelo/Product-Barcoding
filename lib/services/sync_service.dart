import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:drift/drift.dart';
import '../database/app_database.dart';

class SyncService {
  final AppDatabase db;
  SyncService(this.db);

  void startListening() {
    // Accept dynamic because connectivity_plus may emit either a single
    // ConnectivityResult or a List<ConnectivityResult> depending on version.
    Connectivity().onConnectivityChanged.listen((dynamic result) async {
      bool online = false;
      if (result is List && result.isNotEmpty) {
        online = result.first != ConnectivityResult.none;
      } else if (result is ConnectivityResult) {
        online = result != ConnectivityResult.none;
      }

      if (online) {
        await _syncPendingData();
        await fetchAndSyncProducts(); // Automatically download latest data when back online
      }
    });
  }

  // Fetch all products from API and store in Local DB
  Future<void> fetchAndSyncProducts() async {
    try {
      final response = await http.get(Uri.parse('http://192.168.0.143:8056/items/products'));
      if (response.statusCode == 200) {
        final List data = json.decode(response.body)['data'];
        
        // Batch insert/update for performance
        await db.batch((batch) {
          for (var item in data) {
            batch.insert(
              db.localProducts,
              LocalProductsCompanion.insert(
                productId: Value(item['product_id']?.toString() ?? item['id']?.toString()),
                productName: Value(item['product_name']),
                barcode: Value(item['barcode']),
                productBrand: Value(item['product_brand']?.toString()),
                productCategory: Value(item['product_category']?.toString()),
                syncRequired: const Value(false),
              ),
              mode: InsertMode.insertOrReplace,
            );
          }
        });
      }
    } catch (e) {
      print("Sync Background Fetch Failed: $e"); // Graceful failure if offline
    }
  }

  Future<void> _syncPendingData() async {
    final pending = await db.getPendingSync();
    for (var item in pending) {
      try {
        final response = await http.patch(
          Uri.parse('http://192.168.0.143:8056/items/products/${item.productId}'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'barcode': item.barcode}),
        );
        if (response.statusCode == 200) {
          await db.insertOrUpdateProduct(item.copyWith(syncRequired: false));
        }
      } catch (_) {}
    }
  }

  // Public wrapper so callers can trigger pending syncs (manual button)
  Future<void> syncPendingData() async => await _syncPendingData();
}