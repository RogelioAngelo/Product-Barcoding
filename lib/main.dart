import 'package:flutter/material.dart';
import 'pages/login.dart'; 
import 'database/app_database.dart';
import 'services/sync_service.dart';

void main() async {
  // Required for database initialization
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize Database and Sync Service
  final db = AppDatabase();
  SyncService(db).startListening(); 

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: LoginPage(),
    );
  }
}