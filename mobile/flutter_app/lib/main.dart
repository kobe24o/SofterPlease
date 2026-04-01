import 'package:flutter/material.dart';

void main() {
  runApp(const SofterPleaseApp());
}

class SofterPleaseApp extends StatelessWidget {
  const SofterPleaseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SofterPlease',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const Scaffold(
        body: Center(
          child: Text('SofterPlease Mobile Shell (Phase-4)'),
        ),
      ),
    );
  }
}
