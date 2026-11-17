// 2026-11-17
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Small version+build label shown bottom-right on every screen.
class VersionOverlay extends StatelessWidget {
  const VersionOverlay({super.key, required this.child});
  final Widget child;

  static final Future<PackageInfo> _info = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned(
          right: 6,
          bottom: 4,
          child: IgnorePointer(
            child: FutureBuilder<PackageInfo>(
              future: _info,
              builder: (_, s) => s.hasData
                  ? Text('${s.data!.version}+${s.data!.buildNumber}',
                      style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white54,
                          decoration: TextDecoration.none,
                          fontWeight: FontWeight.normal))
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }
}
