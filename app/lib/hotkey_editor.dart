import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_controller.dart';
import 'domain/hotkey.dart';

HotkeyBinding? bindingForKey(LogicalKeyboardKey key,
    {required bool control, required bool alt, required bool shift}) {
  const functions = [
    LogicalKeyboardKey.f1,
    LogicalKeyboardKey.f2,
    LogicalKeyboardKey.f3,
    LogicalKeyboardKey.f4,
    LogicalKeyboardKey.f5,
    LogicalKeyboardKey.f6,
    LogicalKeyboardKey.f7,
    LogicalKeyboardKey.f8,
    LogicalKeyboardKey.f9,
    LogicalKeyboardKey.f10,
    LogicalKeyboardKey.f11
  ];
  final label = key.keyLabel.toUpperCase();
  final code = key == LogicalKeyboardKey.space
      ? 0x20
      : functions.contains(key)
          ? 0x70 + functions.indexOf(key)
          : label.length == 1
              ? label.codeUnitAt(0)
              : 0;
  final result =
      HotkeyBinding((control ? 2 : 0) | (alt ? 1 : 0) | (shift ? 4 : 0), code);
  return result.valid ? result : null;
}

Future<HotkeyBinding?> captureHotkey(
    BuildContext context, AppController c) async {
  await c.suspendHotkeys();
  try {
    if (!context.mounted) return null;
    return await showDialog<HotkeyBinding>(
        context: context, builder: (_) => const _CaptureDialog());
  } finally {
    await c.resumeHotkeys();
  }
}

class _CaptureDialog extends StatefulWidget {
  const _CaptureDialog();
  @override
  State<_CaptureDialog> createState() => _CaptureDialogState();
}

class _CaptureDialogState extends State<_CaptureDialog> {
  String? error;
  final node = FocusNode();
  @override
  void dispose() {
    node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
      autofocus: true,
      focusNode: node,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.handled;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.escape) {
          Navigator.pop(context);
          return KeyEventResult.handled;
        }
        if ([
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.controlRight,
          LogicalKeyboardKey.altLeft,
          LogicalKeyboardKey.altRight,
          LogicalKeyboardKey.shiftLeft,
          LogicalKeyboardKey.shiftRight
        ].contains(key)) {
          return KeyEventResult.handled;
        }
        final keyboard = HardwareKeyboard.instance;
        final binding = keyboard.isMetaPressed
            ? null
            : bindingForKey(key,
                control: keyboard.isControlPressed,
                alt: keyboard.isAltPressed,
                shift: keyboard.isShiftPressed);
        if (binding == null) {
          setState(() => error = '请按 Ctrl 或 Alt，加字母、数字、空格或 F1–F11；可同时按 Shift。');
        } else {
          Navigator.pop(context, binding);
        }
        return KeyEventResult.handled;
      },
      child: AlertDialog(
          title: const Text('按下新的快捷键'),
          content: Text(
              error ?? '按 Ctrl 或 Alt，加字母、数字、空格或 F1–F11；可同时按 Shift。\n按 Esc 取消。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消录入'))
          ]));
}

class HotkeySetting extends StatelessWidget {
  final String title;
  final HotkeyBinding binding;
  final AppController controller;
  final ValueChanged<HotkeyBinding> onChanged;
  const HotkeySetting(
      {super.key,
      required this.title,
      required this.binding,
      required this.controller,
      required this.onChanged});
  @override
  Widget build(BuildContext context) => ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(binding.label),
      trailing: OutlinedButton(
          onPressed: () async {
            try {
              final result = await captureHotkey(context, controller);
              if (result != null && context.mounted) onChanged(result);
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('快捷键录入失败，请重试。')));
              }
            }
          },
          child: const Text('修改')));
}
