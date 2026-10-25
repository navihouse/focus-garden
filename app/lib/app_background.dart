import 'dart:io';
import 'package:flutter/material.dart';

class AppBackground extends StatelessWidget {
  final String? path;
  final double opacity;
  final Widget child;
  const AppBackground({super.key, required this.path, required this.opacity, required this.child});

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
    ColoredBox(color: Theme.of(context).scaffoldBackgroundColor),
    if (path != null) ...[
      Image.file(File(path!), key: ValueKey(path), fit: BoxFit.cover,
        cacheWidth: 1920, excludeFromSemantics: true,
        errorBuilder: (_, error, stack) => const SizedBox.shrink()),
      ColoredBox(color: (Theme.of(context).brightness == Brightness.dark ? Colors.black : Colors.white)
          .withValues(alpha: 1 - opacity)),
    ],
    child,
  ]);
}
