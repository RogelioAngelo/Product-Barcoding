import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'products.dart'; 

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _rememberMe = false; // Checkbox state
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _checkRememberMe();
  }

  // --- 1. Startup Logic: Check for Saved Credentials ---
  Future<void> _checkRememberMe() async {
    final prefs = await SharedPreferences.getInstance();
    final bool remember = prefs.getBool('remember_me') ?? false;
    final String? cachedEmail = prefs.getString('cached_email');
    final String? cachedPass = prefs.getString('cached_password');

    if (remember && cachedEmail != null && cachedPass != null) {
      setState(() {
        _rememberMe = true;
        _emailController.text = cachedEmail;
        _passwordController.text = cachedPass;
      });
    }
  }

  // --- 2. Cache Helper ---
  Future<void> _cacheUserCredentials(String email, String password) async {
    final prefs = await SharedPreferences.getInstance();
    // Cache credentials for both offline login AND Remember Me
    await prefs.setString('cached_email', email);
    await prefs.setString('cached_password', password);
    // Save the user's preference
    await prefs.setBool('remember_me', _rememberMe);
  }

  // --- 3. Login Logic ---
  Future<void> _handleLogin() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    setState(() => _errorMessage = null);

    if (email.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = "Please fill in all fields.");
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    
    // Check Lockout
    String? lockoutStr = prefs.getString('lockout_time_$email');
    if (lockoutStr != null) {
      final lockoutTime = DateTime.parse(lockoutStr);
      final difference = DateTime.now().difference(lockoutTime);
      if (difference.inMinutes < 5) {
        int remaining = 5 - difference.inMinutes;
        setState(() => _errorMessage = "Account locked. Try again in $remaining mins.");
        return;
      } else {
        await prefs.remove('lockout_time_$email');
        await prefs.remove('failed_attempts_$email');
      }
    }

    setState(() => _isLoading = true);

    try {
      // --- TRY ONLINE LOGIN ---
      final response = await http.get(Uri.parse('http://192.168.0.143:8056/items/user'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final List users = json.decode(response.body)['data'];
        
        final user = users.cast<Map<String, dynamic>?>().firstWhere(
          (u) => u?['user_email'] == email,
          orElse: () => null,
        );

        if (user == null) {
          setState(() => _errorMessage = "Account not found.");
        } else if (user['user_password'] == password) {
          await _loginSuccess(email, password); 
        } else {
          await _handleFailedAttempt(email, prefs);
        }
      } else {
        setState(() => _errorMessage = "Server error: ${response.statusCode}");
      }
    } catch (e) {
      // --- OFFLINE FALLBACK ---
      print("Network failed, checking offline cache: $e");
      
      final cachedEmail = prefs.getString('cached_email');
      final cachedPass = prefs.getString('cached_password');

      if (cachedEmail == email && cachedPass == password) {
        _showOfflineSnackbar();
        await _loginSuccess(email, password);
      } else {
        setState(() => _errorMessage = "Offline: Invalid credentials or no cached user.");
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loginSuccess(String email, String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('failed_attempts_$email');
    await prefs.remove('lockout_time_$email');
    
    // Save credentials logic
    if (_rememberMe) {
      await _cacheUserCredentials(email, password);
    } else {
      // If "Remember Me" is UNCHECKED, we still cache credentials for "Offline Login" capability,
      // but we explicitly set 'remember_me' to false so fields won't auto-fill on restart.
      await _cacheUserCredentials(email, password);
      await prefs.setBool('remember_me', false); 
    }

    if (!mounted) return;
    Navigator.pushReplacement(
      context, 
      MaterialPageRoute(builder: (context) => const ProductsScreen())
    );
  }

  Future<void> _handleFailedAttempt(String email, SharedPreferences prefs) async {
    int attempts = (prefs.getInt('failed_attempts_$email') ?? 0) + 1;
    await prefs.setInt('failed_attempts_$email', attempts);

    if (attempts >= 3) {
      await prefs.setString('lockout_time_$email', DateTime.now().toIso8601String());
      setState(() => _errorMessage = "3 failed attempts. Account Locked.");
    } else {
      setState(() => _errorMessage = "Invalid password. Attempt $attempts/3");
    }
  }

  void _showOfflineSnackbar() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Logged in securely (Offline Mode)"),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Background
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF1A237E), Color(0xFF1976D2), Color(0xFF64B5F6)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          Positioned(
            top: -100,
            right: -50,
            child: CircleAvatar(
              radius: 150,
              backgroundColor: Colors.white.withOpacity(0.1),
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: Container(
                padding: const EdgeInsets.all(28.0),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.95),
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    )
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.barcode_reader, size: 50, color: Colors.blue.shade900),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      "Products Barcoding",
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue.shade900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Enter your credentials to continue",
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
                    ),
                    const SizedBox(height: 30),

                    if (_errorMessage != null)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 20),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(15),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline, color: Colors.red, size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),

                    _buildTextField(
                      controller: _emailController,
                      label: "Email Address",
                      icon: Icons.email_outlined,
                      type: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 20),

                    _buildTextField(
                      controller: _passwordController,
                      label: "Password",
                      icon: Icons.lock_outline_rounded,
                      isPassword: true,
                      obscure: _obscurePassword,
                      onToggle: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                    
                    // --- REMEMBER ME CHECKBOX ---
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Checkbox(
                          value: _rememberMe,
                          activeColor: Colors.blue.shade900,
                          onChanged: (val) {
                            setState(() => _rememberMe = val ?? false);
                          },
                        ),
                        const Text("Remember Me"),
                      ],
                    ),
                    
                    const SizedBox(height: 20),

                    SizedBox(
                      width: double.infinity,
                      height: 55,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _handleLogin,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue.shade900,
                          foregroundColor: Colors.white,
                          elevation: 4,
                          shadowColor: Colors.blue.withOpacity(0.5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                        ),
                        child: _isLoading 
                          ? const SizedBox(
                              height: 24,
                              width: 24,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                            )
                          : const Text(
                              'SIGN IN',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 1.1),
                            ),
                      ),
                    ),
                    const SizedBox(height: 15),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool isPassword = false,
    bool obscure = false,
    VoidCallback? onToggle,
    TextInputType type = TextInputType.text,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: type,
      style: const TextStyle(fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: Colors.blue.shade700),
        suffixIcon: isPassword 
          ? IconButton(
              icon: Icon(obscure ? Icons.visibility : Icons.visibility_off, color: Colors.grey),
              onPressed: onToggle,
            ) 
          : null,
        filled: true,
        fillColor: Colors.grey.shade50,
        contentPadding: const EdgeInsets.symmetric(vertical: 18),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide(color: Colors.grey.shade200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide(color: Colors.blue.shade700, width: 1.5),
        ),
      ),
    );
  }
}