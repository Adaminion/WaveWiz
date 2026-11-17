// 2026-11-17
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_store.dart';
import 'ui/browser_page.dart';
import 'ui/version_overlay.dart';

const String _waveVivadoLicence = '''
The WAVE file format and codestream layout used by this app are derived from
WAVE-Vivado (https://github.com/coltonshane/WAVE-Vivado).

Copyright (C) 2019 by Shane W. Colton

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
''';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppStore.init();
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(['WAVE-Vivado'], _waveVivadoLicence);
  });
  runApp(const WaveWizApp());
}

class WaveWizApp extends StatelessWidget {
  const WaveWizApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WaveWiz',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.indigo, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      builder: (context, child) => VersionOverlay(child: child ?? const SizedBox.shrink()),
      home: const BrowserPage(),
    );
  }
}
