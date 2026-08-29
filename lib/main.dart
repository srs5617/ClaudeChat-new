import 'package:flutter/material.dart';

import 'app.dart';
import 'app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final controller = await AppController.bootstrap();
    runApp(ClaudeChatApp(controller: controller));
  } on Object catch (error, stack) {
    debugPrint('$error\n$stack');
    runApp(_StartupFailure(error: error));
  }
}

class _StartupFailure extends StatelessWidget {
  const _StartupFailure({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(
                  Icons.error_outline,
                  size: 52,
                  color: Colors.redAccent,
                ),
                const SizedBox(height: 16),
                const Text(
                  'ClaudeChat 启动失败',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                SelectableText('$error', textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
