import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// NetFloor Shell: um wrapper fino (WebView) em torno do app hospedado.
/// Isso permite atualizações "OTA" — toda a lógica/UI do NetFloor vive no
/// build web publicado em kNetFloorUrl; este APK só precisa ser reinstalado
/// se o próprio shell mudar (o que deve ser raro).
const String kNetFloorUrl = 'https://rogerdev5690.github.io/netfloor/';

void main() => runApp(const NetFloorShellApp());

class NetFloorShellApp extends StatelessWidget {
  const NetFloorShellApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NetFloor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const ShellPage(),
    );
  }
}

class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFF3F3FA))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() {
            _loading = true;
            _error = null;
          }),
          onPageFinished: (_) => setState(() => _loading = false),
          onWebResourceError: (error) => setState(() {
            _loading = false;
            _error = 'Não foi possível carregar o NetFloor.\nVerifique sua conexão com a internet.';
          }),
        ),
      )
      ..loadRequest(Uri.parse(kNetFloorUrl));
  }

  void _reload() {
    setState(() {
      _loading = true;
      _error = null;
    });
    _controller.loadRequest(Uri.parse(kNetFloorUrl));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            if (_error == null) WebViewWidget(controller: _controller),
            if (_error != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.wifi_off, size: 48, color: Colors.grey),
                      const SizedBox(height: 16),
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _reload,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Tentar novamente'),
                      ),
                    ],
                  ),
                ),
              ),
            if (_loading && _error == null)
              const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }
}
