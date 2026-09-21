import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// NetFloor Shell: um wrapper fino (WebView) em torno do app hospedado.
///
/// - Toda a UI/lógica do NetFloor vive no build web publicado em [kNetFloorUrl],
///   então atualizações chegam sem trocar o APK.
/// - Expõe ao app web a ponte JS `NetFloorNative` (Wi-Fi scan, RSSI/PHY e ping),
///   implementada em MainActivity.kt, para a aba "NetFloor Diagnostic".
/// - Abre o seletor de arquivos do Android para o upload de plantas, logo e projetos (.json).
/// - Entrega arquivos gerados pelo app web (laudo em PDF, projeto .json): salva em
///   Downloads/NetFloor ou abre a folha de compartilhamento (método `saveFile`).
const String kNetFloorUrl = 'https://rogerdev5690.github.io/netfloor/';
const String kAllowedHost = 'rogerdev5690.github.io';
const String kShellVersion = '3.2.0';

const MethodChannel _diagChannel = MethodChannel('netfloor/diag');

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
      ..addJavaScriptChannel('NetFloorNative', onMessageReceived: (msg) => _onBridgeMessage(msg.message))
      ..setNavigationDelegate(
        NavigationDelegate(
          // A ponte nativa só pode ser alcançada por páginas do próprio NetFloor.
          onNavigationRequest: (request) {
            final host = Uri.tryParse(request.url)?.host ?? '';
            return host == kAllowedHost ? NavigationDecision.navigate : NavigationDecision.prevent;
          },
          onPageStarted: (_) => setState(() {
            _loading = true;
            _error = null;
          }),
          onPageFinished: (_) => setState(() => _loading = false),
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) return;
            setState(() {
              _loading = false;
              _error = 'Não foi possível carregar o NetFloor.\nVerifique sua conexão com a internet.';
            });
          },
        ),
      )
      ..loadRequest(Uri.parse(kNetFloorUrl));

    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      platform.setOnShowFileSelector(_onShowFileSelector);
    }
  }

  // <input type="file"> do app web (upload de planta) -> seletor nativo do Android.
  // Suporta seleção múltipla (várias plantas de uma vez = vários pavimentos).
  Future<List<String>> _onShowFileSelector(FileSelectorParams params) async {
    // Importação de projeto (.json): o app web pede application/json.
    final wantsJson = params.acceptTypes.any((t) => t.toLowerCase().contains('json'));
    if (wantsJson) {
      final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['json']);
      return file == null ? <String>[] : [file.uri.toString()];
    }
    if (params.mode == FileSelectorMode.openMultiple) {
      final files = await FilePicker.pickFiles(type: FileType.image);
      return [for (final f in files) f.uri.toString()];
    }
    final file = await FilePicker.pickFile(type: FileType.image);
    return file == null ? <String>[] : [file.uri.toString()];
  }

  Future<void> _onBridgeMessage(String raw) async {
    Map<String, dynamic> request;
    try {
      request = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    Map<String, dynamic> response;
    try {
      final args = (request['args'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      final data = await _dispatch(request['method'] as String, args);
      response = {'id': request['id'], 'ok': true, 'data': data};
    } catch (e) {
      response = {'id': request['id'], 'ok': false, 'error': e.toString()};
    }
    // jsonEncode duas vezes: o resultado é um literal de string JS válido.
    final js = 'window.__netfloorNativeResponse && window.__netfloorNativeResponse(${jsonEncode(jsonEncode(response))});';
    await _controller.runJavaScript(js);
  }

  Future<Map<String, dynamic>> _dispatch(String method, Map<String, dynamic> args) async {
    switch (method) {
      case 'hello':
        return {'platform': 'android', 'shellVersion': kShellVersion};
      case 'permissions':
        return _requestPermissions();
      case 'scan':
      case 'linkInfo':
        return _callNative(method);
      case 'ping':
        return _callNative('ping', {'host': args['host']});
      case 'saveFile':
        return _saveFile(args);
      default:
        throw UnsupportedError('Método desconhecido: $method');
    }
  }

  // O app web envia o arquivo em pedaços de base64 (mensagens grandes na ponte JS
  // são frágeis); aqui remontamos e entregamos os bytes ao código nativo.
  final StringBuffer _fileBuffer = StringBuffer();

  Future<Map<String, dynamic>> _saveFile(Map<String, dynamic> args) async {
    final chunk = (args['chunk'] as num).toInt();
    final chunks = (args['chunks'] as num).toInt();
    if (chunk == 0) _fileBuffer.clear();
    _fileBuffer.write(args['data'] as String);
    if (chunk + 1 < chunks) return {'done': false};

    final bytes = Uint8List.fromList(base64Decode(_fileBuffer.toString()));
    _fileBuffer.clear();
    final raw = await _diagChannel.invokeMethod<String>('saveFile', {
      'name': args['name'],
      'mime': args['mime'],
      'share': args['share'] == true,
      'bytes': bytes,
    });
    final data = jsonDecode(raw ?? '{}') as Map<String, dynamic>;
    if (data['error'] != null) throw StateError('${data['error']}');
    return {'done': true, ...data};
  }

  Future<Map<String, dynamic>> _callNative(String method, [Map<String, dynamic>? args]) async {
    final raw = await _diagChannel.invokeMethod<String>(method, args);
    return jsonDecode(raw ?? '{}') as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _requestPermissions() async {
    final location = await Permission.locationWhenInUse.request();
    var nearby = false;
    try {
      nearby = (await Permission.nearbyWifiDevices.request()).isGranted;
    } catch (_) {
      // Android < 13 não tem essa permissão.
    }
    final servicesOn = await Permission.locationWhenInUse.serviceStatus.isEnabled;
    return {'location': location.isGranted, 'nearby': nearby, 'locationServices': servicesOn};
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
            if (_loading && _error == null) const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }
}
