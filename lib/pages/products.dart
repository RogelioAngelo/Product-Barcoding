import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'barcode.dart';

class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  List allProducts = [];
  List filteredProducts = [];
  List brands = [];
  List categories = [];

  List<Map<String, dynamic>> recentScans = [];

  bool isLoading = true;
  String searchQuery = "";
  String? selectedBrandId;
  String? selectedCategoryId;
  
  // Pagination
  static const int _pageSize = 30;
  int _displayLimit = _pageSize;
  bool _isLoadingMore = false;

  // Barcode Filter state
  String? selectedBarcodeStatus;

  final ScrollController _scrollController = ScrollController();
  double _scrollProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _loadData();
    _loadStoredHistory();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
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

    // Try to load more when user nears the bottom
    _maybeLoadMore();
  }

  void _maybeLoadMore() {
    if (!_scrollController.hasClients) return;
    if (_isLoadingMore) return;
    final max = _scrollController.position.maxScrollExtent;
    final offset = _scrollController.offset;

    // If within 200px of bottom and there are more items to show
    if (offset >= (max - 200) && filteredProducts.length > _displayLimit) {
      _isLoadingMore = true;
      // small delay to show indicator smoothly
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
      return tempMap;
    }).toList());
    await prefs.setString('barcode_history_key', encodedData);
  }

  Future<void> _loadStoredHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final String? historyString = prefs.getString('barcode_history_key');
    if (historyString != null) {
      final List decodedList = json.decode(historyString);
      setState(() {
        recentScans = decodedList.map((item) {
          return {
            'product_name': item['product_name'],
            'barcode': item['barcode'],
            'is_rescan': item['is_rescan'] ?? false,
            'time': DateTime.tryParse(item['time'] ?? '') ?? DateTime.now(),
            'original_data': item['original_data'],
          };
        }).toList();
      });
    }
  }

  Future<void> _clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('barcode_history_key');
    setState(() => recentScans.clear());
  }

  // --- API DATA ---

  Future<void> _loadData() async {
    setState(() => isLoading = true);
    try {
      await Future.wait([
        _fetchProducts(),
        _fetchBrands(),
        _fetchCategories(),
      ]);
    } catch (e) {
      _showSnackBar('Init Error: $e');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> _fetchProducts() async {
    final response = await http.get(Uri.parse('http://192.168.0.143:8056/items/products'));
    if (response.statusCode == 200) {
      List data = json.decode(response.body)['data'];
      data.sort((a, b) {
        final bool hasA = a['barcode'] != null && a['barcode'].toString().trim().isNotEmpty;
        final bool hasB = b['barcode'] != null && b['barcode'].toString().trim().isNotEmpty;
        if (!hasA && hasB) return -1;
        if (hasA && !hasB) return 1;
        String nameA = (a['product_name'] ?? '').toString().toLowerCase();
        String nameB = (b['product_name'] ?? '').toString().toLowerCase();
        return nameA.compareTo(nameB);
      });
      allProducts = data;
      _applyFilters();
    }
  }

  Future<void> _fetchBrands() async {
    final res = await http.get(Uri.parse('http://192.168.0.143:8056/items/brand'));
    if (res.statusCode == 200) {
      setState(() => brands = json.decode(res.body)['data']);
    }
  }

  Future<void> _fetchCategories() async {
    final res = await http.get(Uri.parse('http://192.168.0.143:8056/items/categories'));
    if (res.statusCode == 200) {
      setState(() => categories = json.decode(res.body)['data']);
    }
  }

  void _applyFilters() {
    setState(() {
      filteredProducts = allProducts.where((p) {
        final name = (p['product_name'] ?? "").toString().toLowerCase();
        final matchesSearch = name.contains(searchQuery.toLowerCase());
        
        final String? pBrand = p['product_brand']?.toString();
        final bool matchesBrand = selectedBrandId == null || pBrand == selectedBrandId;
        
        final String? pCategory = p['product_category']?.toString();
        final bool matchesCategory = selectedCategoryId == null || pCategory == selectedCategoryId;

        final bool hasBarcode = p['barcode'] != null && p['barcode'].toString().trim().isNotEmpty;
        bool matchesStatus = true;
        if (selectedBarcodeStatus == 'missing') {
          matchesStatus = !hasBarcode;
        } else if (selectedBarcodeStatus == 'has') {
          matchesStatus = hasBarcode;
        }

        return matchesSearch && matchesBrand && matchesCategory && matchesStatus;
      }).toList();
      // reset pagination when filters change
      _displayLimit = _pageSize;
      // ensure list scrolls to top when filters applied
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    });
  }

  // --- UNIQUE CHECK LOGIC ---

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

  Future<void> updateProductBarcode(Map<String, dynamic> product, String newBarcode, {bool isRescan = false}) async {
    final currentId = _getProductId(product);
    final duplicateProduct = allProducts.firstWhere(
      (p) => p['barcode']?.toString() == newBarcode && _getProductId(p) != currentId,
      orElse: () => null,
    );

    if (duplicateProduct != null) {
      _showDuplicateError(newBarcode, duplicateProduct['product_name'] ?? "Another product");
      return;
    }

    final id = currentId;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final response = await http.patch(
        Uri.parse('http://192.168.0.143:8056/items/products/$id'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'barcode': newBarcode}),
      );

      Navigator.pop(context);
      if (response.statusCode == 200) {
        setState(() {
          recentScans.insert(0, {
            'product_name': product['product_name'],
            'barcode': newBarcode,
            'time': DateTime.now(),
            'is_rescan': isRescan,
            'original_data': product,
          });
        });

        await _saveHistoryToDisk();
        _showSuccessDialog(product['product_name'] ?? 'Product', newBarcode);
        _fetchProducts();
      } else {
        _showSnackBar('❌ Update Failed');
      }
    } catch (e) {
      Navigator.pop(context);
      _showSnackBar('Error: $e');
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

  dynamic _getProductId(Map<String, dynamic> product) {
    const idFieldNames = ['product_id', 'id', 'itemId', 'item_id', 'productId'];
    for (var key in idFieldNames) {
      if (product[key] != null) return product[key];
    }
    return null;
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
        title: const Text('Products Barcoding ', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.blue.shade900,
        foregroundColor: Colors.white,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(130), // Reduced height since filters are in one row
          child: _buildFilterSection(),
        ),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
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
                      String formattedDateTime = "Unknown time";
                      if (item['time'] != null && item['time'] is DateTime) {
                        formattedDateTime = DateFormat('MMM d, h:mm a').format(item['time']);
                      }
                      return ListTile(
                        onTap: () async {
                          Navigator.pop(context);
                          if (item['original_data'] != null) {
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
                              updateProductBarcode(item['original_data'], result, isRescan: true);
                            }
                          }
                        },
                        title: Row(
                          children: [
                            Expanded(child: Text(item['product_name'] ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.bold))),
                            if (isRescan)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                            Row(
                              children: [
                                const Icon(Icons.access_time, size: 14, color: Colors.grey),
                                const SizedBox(width: 4),
                                Text(
                                  formattedDateTime,
                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                                ),
                              ],
                            ),
                          ],
                        ),
                        trailing: Icon(Icons.qr_code_scanner, size: 20, color: isRescan ? Colors.orange : Colors.blue),
                        leading: Icon(isRescan ? Icons.published_with_changes : Icons.check_circle, color: isRescan ? Colors.orange : Colors.green),
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
              // 1. Brand Dropdown
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
              // 2. Category Dropdown
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
              // 3. Barcode Status Dropdown
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
                  selectedBarcodeStatus = null;
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
          // Loading indicator at the end while more items are being prepared
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(Colors.blue.shade900))),
            ),
          );
        }

        final product = filteredProducts[index];
        final bool hasBarcode = product['barcode']?.toString().isNotEmpty ?? false;
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
            title: Text(product['product_name'] ?? 'Unnamed Product', style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(hasBarcode ? 'Barcode: ${product['barcode']}' : '⚠️ Missing Barcode', style: TextStyle(color: hasBarcode ? Colors.grey.shade600 : Colors.red.shade700, fontWeight: hasBarcode ? FontWeight.normal : FontWeight.bold)),
            trailing: Icon(Icons.qr_code_scanner, color: Colors.blue.shade800),
            onTap: () async {
              final String? result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CameraScannerPage(
                    productName: product['product_name'] ?? 'Unnamed',
                    oldBarcode: product['barcode'] ?? 'NONE',
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