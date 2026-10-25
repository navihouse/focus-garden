/// Persist platform-neutral modifiers and a Windows virtual key code.
class HotkeyBinding {
  final int modifiers, keyCode;
  const HotkeyBinding(this.modifiers, this.keyCode);
  static const musicDefault = HotkeyBinding(6, 0x20); // Ctrl + Shift
  static const timerDefault = HotkeyBinding(3, 0x20); // Ctrl + Alt
  bool get valid =>
      modifiers > 0 &&
      modifiers <= 7 &&
      modifiers & 3 != 0 &&
      supportedKey(keyCode);
  static bool supportedKey(int key) =>
      key == 0x20 ||
      (key >= 0x30 && key <= 0x39) ||
      (key >= 0x41 && key <= 0x5a) ||
      (key >= 0x70 && key <= 0x7a); // F12 is reserved by Windows.
  bool sameAs(HotkeyBinding other) =>
      modifiers == other.modifiers && keyCode == other.keyCode;
  Map<String, int> toJson() => {'modifiers': modifiers, 'keyCode': keyCode};
  static HotkeyBinding fromJson(Object? value, HotkeyBinding fallback) {
    if (value is! Map || value['modifiers'] is! int || value['keyCode'] is! int) {
      return fallback;
    }
    final binding =
        HotkeyBinding(value['modifiers'] as int, value['keyCode'] as int);
    return binding.valid ? binding : fallback;
  }

  String get label => [
        if (modifiers & 2 != 0) 'Ctrl',
        if (modifiers & 1 != 0) 'Alt',
        if (modifiers & 4 != 0) 'Shift',
        if (keyCode == 0x20)
          '空格'
        else if (keyCode >= 0x70)
          'F${keyCode - 0x6f}'
        else
          String.fromCharCode(keyCode),
      ].join(' + ');
}
