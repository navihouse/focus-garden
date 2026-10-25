import 'dart:io';
import 'package:flutter/material.dart';

ThemeData wallpaperTheme(ThemeData base, double transparency) => base.copyWith(
      cardTheme: base.cardTheme.copyWith(
        color: base.colorScheme.surfaceContainerLow
            .withValues(alpha: 1 - transparency.clamp(0, 1)),
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
      ),
      appBarTheme: base.appBarTheme.copyWith(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0),
      navigationRailTheme: base.navigationRailTheme
          .copyWith(backgroundColor: Colors.transparent),
      navigationBarTheme: base.navigationBarTheme.copyWith(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent),
    );

class AppBackground extends StatelessWidget {
  final String? path;
  final double opacity;
  final double cardTransparency;
  final Widget child;
  const AppBackground(
      {super.key,
      required this.path,
      required this.opacity,
      this.cardTransparency = .65,
      required this.child});

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
        ColoredBox(color: Theme.of(context).scaffoldBackgroundColor),
        if (path != null) ...[
          Image.file(File(path!),
              key: ValueKey(path),
              fit: BoxFit.cover,
              cacheWidth: 1920,
              excludeFromSemantics: true,
              errorBuilder: (_, error, stack) => const SizedBox.shrink()),
          ColoredBox(
              color: (Theme.of(context).brightness == Brightness.dark
                      ? Colors.black
                      : Colors.white)
                  .withValues(alpha: 1 - opacity)),
        ],
        if (path == null)
          child
        else
          Theme(
              data: wallpaperTheme(Theme.of(context), cardTransparency),
              child: child),
      ]);
}
