import 'dart:async';
import 'dart:convert';
import 'package:drift/drift.dart' as drift; 
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:connectivity_plus/connectivity_plus.dart'; 
import 'barcode.dart';
import '../database/app_database.dart'; 

class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  late AppDatabase _database;
  
  // Connectivity
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;
  bool _isOnline = true;

  List<LocalProduct> allProducts = [];
  List<LocalProduct> filteredProducts = [];
  
  List brands = [];
  List categories = [];
  List<Map<String, dynamic>> recentScans = [];

  bool isLoading = true;
  bool isSyncing = false; 
  String searchQuery = "";
  String? selectedBrandId;
  String? selectedCategoryId;
  
  static const int _pageSize = 30;
  int _displayLimit = _pageSize;
  bool _isLoadingMore = false;

  // --- KEY CHANGE HERE ---
  // Default to 'missing' so scanned items disappear from the list automatically
  String? selectedBarcodeStatus = 'missing';

  final ScrollController _scrollController = ScrollController();
  double _scrollProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _database = AppDatabase();
    
    _initConnectivity();
    _loadData();
    _loadStoredHistory();
    _scrollController.addListener(_onScroll);
  }

  Future<void> _initConnectivity() async {
    final result = await Connectivity().checkConnectivity();
    _updateConnectionStatus(result);
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(_updateConnectionStatus);
  }

  void _updateConnectionStatus(List<ConnectivityResult> results) {
    bool isConnected = results.any((r) => 
      r == ConnectivityResult.mobile || 
      r == ConnectivityResult.wifi || 
      r == ConnectivityResult.ethernet);

    setState(() => _isOnline = isConnected);

    if (isConnected) {
      _processPendingSyncs();
      if (allProducts.isEmpty || brands.isEmpty) {
        _loadData(); 
      }
    }
  }

  @override
  void dispose() {
    _connectivitySubscription.cancel();
    _database.close();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    double progress = 0.0;
    if (_scrollController.hasClients && _scrollController.position.maxScrollExtent > 0) {
      progress = _scrollController.offset / _scrollController.position.maxScrollExtent;
    }
    setState(() {
      _scrollProgress = progress.clamp(0.0, 1.0);
    });
    _maybeLoadMore();
  }

  void _maybeLoadMore() {
    if (!_scrollController.hasClients) return;
    if (_isLoadingMore) return;
    final max = _scrollController.position.maxScrollExtent;
    final offset = _scrollController.offset;

    if (offset >= (max - 200) && filteredProducts.length > _displayLimit) {
      _isLoadingMore = true;
      Future.delayed(const Duration(milliseconds: 200), () {
        if (!mounted) return;
        setState(() {
          _displayLimit = (_displayLimit + _pageSize).clamp(0, filteredProducts.length);
          _isLoadingMore = false;
        });
      });
    }
  }

  // --- PERSISTENCE ---

  Future<void> _saveHistoryToDisk() async {
    final prefs = await SharedPreferences.getInstance();
    final String encodedData = json.encode(recentScans.map((item) {
      var tempMap = Map<String, dynamic>.from(item);
      if (tempMap['time'] is DateTime) {
        tempMap['time'] = (tempMap['time'] as DateTime).toIso8601String();
      }
      tempMap.remove('original_data'); 
      return tempMap;
    }).toList());
    await prefs.setString('barcode_history_key', encodedData);
  }

  Future<void> _loadStoredHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final String? historyString = prefs.getString('barcode_history_key');
    
    if (historyString != null) {
      final List decodedList = json.decode(historyString);
      final List<Map<String, dynamic>> loadedHistory = decodedList.map((item) {
        return {
          'product_name': item['product_name'],
          'barcode': item['barcode'],
          'is_rescan': item['is_rescan'] ?? false,
          'synced': item['synced'] ?? true, 
          'time': DateTime.tryParse(item['time'] ?? '') ?? DateTime.now(),
          'original_data': null, 
        };
      }).toList().cast<Map<String, dynamic>>();

      if (mounted) {
        setState(() {
          recentScans.addAll(loadedHistory);
        });
      }
    }
  }

  Future<void> _clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('barcode_history_key');
    setState(() => recentScans.clear());
  }

  // --- BACKGROUND SYNC ---

  Future<void> _processPendingSyncs() async {
    if (!_isOnline) return;

    final pendingItems = await (_database.select(_database.localProducts)..where((t) => t.syncRequired.equals(true))).get();
    
    if (pendingItems.isEmpty) return;

    setState(() => isSyncing = true);
    bool historyWasUpdated = false;

    for (final product in pendingItems) {
      if (product.productId == null) continue;

      try {
        final response = await http.patch(
          Uri.parse('http://192.168.0.143:8056/items/products/${product.productId}'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'barcode': product.barcode}),
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          await _database.update(_database.localProducts).replace(product.copyWith(syncRequired: false));
          
          for (var item in recentScans) {
            if (item['barcode'] == product.barcode && item['synced'] == false) {
              item['synced'] = true; 
              historyWasUpdated = true;
            }
          }
        }
      } catch (e) {
        print("Sync failed for ${product.productName}: $e");
      }
    }

    if (historyWasUpdated && mounted) {
      _saveHistoryToDisk();
      _refreshLocalData(); 
      _showSnackBar("✅ Offline data synced successfully!");
    }
    
    if (mounted) setState(() => isSyncing = false);
  }

  // --- DATA LOADING ---

  Future<void> _loadData() async {
    setState(() => isLoading = true);
    await _refreshLocalData();
    
    if (!_isOnline) {
      if (mounted) {
        setState(() => isLoading = false);
        _showSnackBar("⚠️ You are Offline. Showing local data.");
      }
      return;
    }

    try {
      await Future.wait([
        _fetchBrands(),
        _fetchCategories(),
      ]).timeout(const Duration(seconds: 5));

      if (mounted) {
        setState(() => isLoading = false);
        _syncProductsDownloader();
      }
    } catch (e) {
      print("Error loading external data: $e");
      if (mounted) {
        setState(() => isLoading = false);
        if (_isOnline) _showSnackBar("⚠️ Connection Error. Showing local data.");
      }
    }
  }

  Future<void> _refreshLocalData() async {
    final localData = await _database.getAllCachedProducts();
    // Sort so items with NO barcode come first (Priority)
    localData.sort((a, b) {
      final bool hasA = a.barcode != null && a.barcode!.trim().isNotEmpty;
      final bool hasB = b.barcode != null && b.barcode!.trim().isNotEmpty;
      if (!hasA && hasB) return -1;
      if (hasA && !hasB) return 1;
      String nameA = (a.productName ?? '').toLowerCase();
      String nameB = (b.productName ?? '').toLowerCase();
      return nameA.compareTo(nameB);
    });

    if (mounted) {
      setState(() {
        allProducts = localData;
        _applyFilters();
      });
    }
  }

  Future<void> _syncProductsDownloader() async {
    if (isSyncing) return;
    setState(() => isSyncing = true);

    try {
      final response = await http.get(Uri.parse('http://192.168.0.143:8056/items/products'))
         .timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        List apiData = json.decode(response.body)['data'];
        
        final existingProducts = await _database.getAllCachedProducts();
        final Map<String, LocalProduct> existingMap = {
          for (var p in existingProducts) 
            if (p.productId != null) p.productId!: p
        };

        await _database.batch((batch) {
          for (var item in apiData) {
            final String? pId = item['product_id']?.toString();
            final String? barcode = item['barcode']?.toString();
            final String? name = item['product_name'];
            final String? brand = item['product_brand']?.toString();
            final String? category = item['product_category']?.toString();

            if (pId != null) {
              final existing = existingMap[pId];
              if (existing != null) {
                if (!existing.syncRequired) {
                  batch.update(
                    _database.localProducts,
                    LocalProductsCompanion(
                      id: drift.Value(existing.id),
                      productName: drift.Value(name),
                      barcode: drift.Value(barcode),
                      productBrand: drift.Value(brand),
                      productCategory: drift.Value(category),
                    ),
                  );
                }
              } else {
                batch.insert(
                  _database.localProducts,
                  LocalProductsCompanion.insert(
                    productId: drift.Value(pId),
                    productName: drift.Value(name),
                    barcode: drift.Value(barcode),
                    productBrand: drift.Value(brand),
                    productCategory: drift.Value(category),
                    syncRequired: drift.Value(false),
                  ),
                );
              }
            }
          }
        });

        await _refreshLocalData();
      }
    } catch (e) {
      print("Downloader Sync Error: $e");
    } finally {
      if (mounted) setState(() => isSyncing = false);
    }
  }

  Future<void> _fetchBrands() async {
    if (!_isOnline) return;
    final res = await http.get(Uri.parse('http://192.168.0.143:8056/items/brand'));
    if (res.statusCode == 200) {
      setState(() => brands = json.decode(res.body)['data']);
    }
  }

  Future<void> _fetchCategories() async {
    if (!_isOnline) return;
    final res = await http.get(Uri.parse('http://192.168.0.143:8056/items/categories'));
    if (res.statusCode == 200) {
      setState(() => categories = json.decode(res.body)['data']);
    }
  }

  void _applyFilters() {
    setState(() {
      filteredProducts = allProducts.where((p) {
        final name = (p.productName ?? "").toLowerCase();
        final matchesSearch = name.contains(searchQuery.toLowerCase());
        
        final String? pBrand = p.productBrand;
        final bool matchesBrand = selectedBrandId == null || pBrand == selectedBrandId;
        
        final String? pCategory = p.productCategory;
        final bool matchesCategory = selectedCategoryId == null || pCategory == selectedCategoryId;

        final bool hasBarcode = p.barcode != null && p.barcode!.trim().isNotEmpty;
        bool matchesStatus = true;
        
        // This logic ensures scanned items disappear if 'missing' is selected
        if (selectedBarcodeStatus == 'missing') {
          matchesStatus = !hasBarcode;
        } else if (selectedBarcodeStatus == 'has') {
          matchesStatus = hasBarcode;
        }

        return matchesSearch && matchesBrand && matchesCategory && matchesStatus;
      }).toList();
      
      _displayLimit = _pageSize;
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    });
  }

  // --- UPDATE LOGIC ---

  void _showDuplicateError(String barcode, String existingProductName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Duplicate Barcode", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
        content: Text("The barcode '$barcode' is already assigned to:\n\n$existingProductName"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("OK")),
        ],
      ),
    );
  }

  Future<void> updateProductBarcode(LocalProduct product, String newBarcode, {bool isRescan = false}) async {
    final duplicate = allProducts.firstWhere(
      (p) => p.barcode == newBarcode && p.id != product.id,
      orElse: () => const LocalProduct(id: -1, syncRequired: false),
    );

    if (duplicate.id != -1) {
      _showDuplicateError(newBarcode, duplicate.productName ?? "Another product");
      return;
    }

    final updatedProduct = product.copyWith(
      barcode: drift.Value(newBarcode),
      syncRequired: true, 
    );

    await _database.update(_database.localProducts).replace(updatedProduct);

    setState(() {
      // 1. Update the main list
      final index = allProducts.indexWhere((p) => p.id == product.id);
      if (index != -1) {
        allProducts[index] = updatedProduct;
      }
      
      // 2. Refresh Filters 
      // (This will cause the item to DISAPPEAR from view because it now has a barcode)
      _applyFilters();
      
      // 3. Add to History
      recentScans.insert(0, {
        'product_name': product.productName,
        'barcode': newBarcode,
        'time': DateTime.now(),
        'is_rescan': isRescan,
        'synced': false,
        'original_data': updatedProduct, 
      });
    });
    
    _saveHistoryToDisk();
    _showSuccessDialog(product.productName ?? 'Product', newBarcode);

    if (_isOnline) {
      _processPendingSyncs();
    }
  }

  void _showSuccessDialog(String name, String code) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_outline, color: Colors.green, size: 80),
              const SizedBox(height: 16),
              const Text("Update Successful!", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                _isOnline ? "Saved and Syncing..." : "Saved locally (Offline)", 
                textAlign: TextAlign.center, 
                style: const TextStyle(fontSize: 12, color: Colors.grey)
              ),
              const SizedBox(height: 12),
              Text("The barcode for $name has been updated to:", textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
                child: Text(code, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 2, fontFamily: 'monospace')),
              ),
            ],
          ),
          actions: [
            Center(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade900, foregroundColor: Colors.white),
                onPressed: () => Navigator.pop(context),
                child: const Text("GREAT!"),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7F9),
      endDrawer: _buildHistoryDrawer(),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Products Barcoding', style: TextStyle(fontWeight: FontWeight.bold)),
            if (isSyncing)
              const Text('Syncing data...', style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal)),
            if (!_isOnline)
              const Text('Offline Mode', style: TextStyle(fontSize: 12, color: Colors.orangeAccent, fontWeight: FontWeight.bold)),
          ],
        ),
        backgroundColor: Colors.blue.shade900,
        foregroundColor: Colors.white,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(130),
          child: _buildFilterSection(),
        ),
      ),
      body: isLoading && allProducts.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                if (_isOnline) {
                  await _loadData();
                } else {
                  _showSnackBar("Cannot refresh while offline");
                }
              },
              child: _buildProductList(),
            ),
    );
  }

  Widget _buildHistoryDrawer() {
    return Drawer(
      child: Column(
        children: [
          DrawerHeader(
            decoration: BoxDecoration(color: Colors.blue.shade900),
            child: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history_rounded, size: 48, color: Colors.white),
                  SizedBox(height: 10),
                  Text('History', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
          if (recentScans.isNotEmpty)
            TextButton.icon(
              onPressed: _clearHistory,
              icon: const Icon(Icons.delete_forever, color: Colors.red),
              label: const Text("Clear All History", style: TextStyle(color: Colors.red)),
            ),
          Expanded(
            child: recentScans.isEmpty
                ? const Center(child: Text("No scan history found"))
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: recentScans.length,
                    separatorBuilder: (context, index) => const Divider(),
                    itemBuilder: (context, index) {
                      final item = recentScans[index];
                      final bool isRescan = item['is_rescan'] ?? false;
                      final bool isSynced = item['synced'] ?? true; 

                      String formattedDateTime = "Unknown time";
                      if (item['time'] != null && item['time'] is DateTime) {
                        formattedDateTime = DateFormat('MMM d, h:mm a').format(item['time']);
                      }
                      
                      LocalProduct? originalObj = item['original_data'] as LocalProduct?;

                      return ListTile(
                        onTap: () async {
                          Navigator.pop(context);
                          if (originalObj != null) {
                            final String? result = await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => CameraScannerPage(
                                  productName: item['product_name'] ?? 'Unnamed',
                                  oldBarcode: item['barcode'] ?? 'NONE',
                                ),
                              ),
                            );
                            if (result != null && result.isNotEmpty) {
                              updateProductBarcode(originalObj, result, isRescan: true);
                            }
                          } else {
                            _showSnackBar("Cannot re-edit from history (Product data lost)");
                          }
                        },
                        title: Row(
                          children: [
                            Expanded(child: Text(item['product_name'] ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.bold))),
                            if (isRescan)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                margin: const EdgeInsets.only(left: 4),
                                decoration: BoxDecoration(color: Colors.orange.shade100, borderRadius: BorderRadius.circular(4)),
                                child: const Text("RE-SCANNED", style: TextStyle(fontSize: 9, color: Colors.orange, fontWeight: FontWeight.bold)),
                              ),
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Barcode: ${item['barcode']}'),
                            const SizedBox(height: 4),
                            Text(formattedDateTime, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                          ],
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              isSynced ? Icons.cloud_done : Icons.cloud_off, 
                              size: 20, 
                              color: isSynced ? Colors.green : Colors.orange
                            ),
                            Text(
                              isSynced ? "Saved" : "Pending", 
                              style: TextStyle(fontSize: 8, color: isSynced ? Colors.green : Colors.orange)
                            )
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterSection() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      decoration: BoxDecoration(color: Colors.blue.shade900),
      child: Column(
        children: [
          TextField(
            onChanged: (val) {
              searchQuery = val;
              _applyFilters();
            },
            decoration: InputDecoration(
              hintText: "Search product name...",
              prefixIcon: const Icon(Icons.search),
              fillColor: Colors.white,
              filled: true,
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _buildDropdown(
                  hint: "Brand",
                  value: selectedBrandId,
                  items: brands,
                  idKey: 'brand_id',
                  nameKey: 'brand_name',
                  onChanged: (val) {
                    setState(() => selectedBrandId = val);
                    _applyFilters();
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildDropdown(
                  hint: "Cat.",
                  value: selectedCategoryId,
                  items: categories,
                  idKey: 'category_id',
                  nameKey: 'category_name',
                  onChanged: (val) {
                    setState(() => selectedCategoryId = val);
                    _applyFilters();
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildBarcodeStatusDropdown(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBarcodeStatusDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15), 
        borderRadius: BorderRadius.circular(8)
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: selectedBarcodeStatus,
          hint: const Text("Status", style: TextStyle(color: Colors.white70, fontSize: 12)),
          dropdownColor: Colors.blue.shade900,
          iconEnabledColor: Colors.white,
          isExpanded: true,
          style: const TextStyle(color: Colors.white, fontSize: 12),
          items: const [
            DropdownMenuItem(value: null, child: Text("All")),
            DropdownMenuItem(value: 'missing', child: Text("Missing Barcode")),
            DropdownMenuItem(value: 'has', child: Text("Has Barcode")),
          ],
          onChanged: (val) {
            setState(() => selectedBarcodeStatus = val);
            _applyFilters();
          },
        ),
      ),
    );
  }

  Widget _buildDropdown({
    required String hint,
    required String? value,
    required List items,
    required String idKey,
    required String nameKey,
    required Function(String?) onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          hint: Text(hint, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          dropdownColor: Colors.blue.shade900,
          iconEnabledColor: Colors.white,
          isExpanded: true,
          style: const TextStyle(color: Colors.white, fontSize: 12),
          items: [
            DropdownMenuItem(value: null, child: Text("All $hint")),
            ...items.map((item) {
              return DropdownMenuItem(
                value: item[idKey].toString(),
                child: Text(item[nameKey].toString(), overflow: TextOverflow.ellipsis),
              );
            }),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildProductList() {
    if (filteredProducts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.search_off, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text("No products found."),
            TextButton(
              onPressed: () {
                setState(() {
                  searchQuery = "";
                  selectedBrandId = null;
                  selectedCategoryId = null;
                  selectedBarcodeStatus = null; // Reset to 'All' if they click this
                });
                _applyFilters();
              },
              child: const Text("Reset Filters"),
            )
          ],
        ),
      );
    }
    final int visibleCount = filteredProducts.length < _displayLimit ? filteredProducts.length : _displayLimit;
    final bool hasMore = filteredProducts.length > visibleCount;

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(12),
      itemCount: visibleCount + (hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= visibleCount) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(Colors.blue.shade900))),
            ),
          );
        }

        final product = filteredProducts[index];
        final bool hasBarcode = product.barcode != null && product.barcode!.trim().isNotEmpty;
        final bool isSyncPending = product.syncRequired;

        return Card(
          elevation: 0,
          margin: const EdgeInsets.only(bottom: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey.shade200)),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: CircleAvatar(
              backgroundColor: hasBarcode ? Colors.green.shade50 : Colors.red.shade50,
              child: Icon(hasBarcode ? Icons.inventory_2_rounded : Icons.priority_high_rounded, color: hasBarcode ? Colors.green : Colors.red),
            ),
            title: Text(product.productName ?? 'Unnamed Product', style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Row(
              children: [
                Expanded(
                  child: Text(hasBarcode ? 'Barcode: ${product.barcode}' : '⚠️ Missing Barcode', style: TextStyle(color: hasBarcode ? Colors.grey.shade600 : Colors.red.shade700, fontWeight: hasBarcode ? FontWeight.normal : FontWeight.bold)),
                ),
                if (isSyncPending)
                  const Row(
                    children: [
                      Icon(Icons.cloud_upload, size: 14, color: Colors.orange),
                      SizedBox(width: 4),
                      Text("Unsaved", style: TextStyle(fontSize: 10, color: Colors.orange)),
                    ],
                  )
              ],
            ),
            trailing: Icon(Icons.qr_code_scanner, color: Colors.blue.shade800),
            onTap: () async {
              final String? result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CameraScannerPage(
                    productName: product.productName ?? 'Unnamed',
                    oldBarcode: product.barcode ?? 'NONE',
                  ),
                ),
              );
              if (result != null && result.isNotEmpty) {
                updateProductBarcode(product, result, isRescan: false);
              }
            },
          ),
        );
      },
    );
  }
}