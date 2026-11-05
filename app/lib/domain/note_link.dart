/// A file or web reference occupies a range in the visible plain-text note.
class NoteFileLink {
  final int start, end;
  final String target;
  bool get isWeb => webLinkUrl(target) != null;
  const NoteFileLink(this.start, this.end, this.target);
  NoteFileLink shifted(int delta) =>
      NoteFileLink(start + delta, end + delta, target);
  Map<String, dynamic> toJson() =>
      {'start': start, 'end': end, 'target': target};
  factory NoteFileLink.fromJson(Map<String, dynamic> value) {
    if (value['start'] is! int ||
        value['end'] is! int ||
        value['target'] is! String) {
      throw const FormatException('备注链接格式无效');
    }
    return NoteFileLink(value['start'], value['end'], value['target']);
  }
}

String? webLinkUrl(String input) {
  final value = input.trim();
  final scheme = RegExp(r'^https?://', caseSensitive: false).firstMatch(value);
  if (value.length > 4096 ||
      scheme == null ||
      value.contains(RegExp(r'[\s\x00-\x1f\x7f\\]'))) {
    return null;
  }
  final authority = value.substring(scheme.end).split(RegExp(r'[/#?]')).first;
  if (authority.contains(RegExp(r'[@%]')) || authority.endsWith(':')) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.host.isEmpty ||
      uri.host.contains('%') ||
      uri.port < 1 ||
      uri.port > 65535) {
    return null;
  }
  final normalized = uri.toString();
  return normalized.length <= 4096 ? normalized : null;
}

String? noteLinkTarget(String input) =>
    webLinkUrl(input) ?? localFilePath(input);

String? localFilePath(String input) {
  var value = input.trim();
  if (value.startsWith('"') && value.endsWith('"') && value.length > 1) {
    value = value.substring(1, value.length - 1);
  }
  if (value.startsWith('file:')) {
    try {
      final uri = Uri.parse(value);
      if (uri.host.isNotEmpty && uri.host != 'localhost') return null;
      value =
          uri.toFilePath(windows: RegExp(r'^/[A-Za-z]:/').hasMatch(uri.path));
    } catch (_) {
      return null;
    }
  }
  if (value.isEmpty ||
      value.length > 4096 ||
      value.contains(RegExp(r'[\x00-\x1f]'))) {
    return null;
  }
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) return value;
  if (value.startsWith('/') && !value.startsWith('//')) return value;
  return null;
}

List<NoteFileLink> detectedFileLinks(String text, List<NoteFileLink> explicit) {
  final links = List<NoteFileLink>.from(explicit);
  // Quoted paths may share a line. Unquoted paths extend to the end of a line,
  // allowing spaces, Chinese characters and parentheses in file names.
  final pattern = RegExp(
      r'"(?:[A-Za-z]:[\\/]|/)[^"\r\n]+"|file:///[^\s]+|[A-Za-z]:[\\/][^\r\n"<>|]+|(?<=^|\n)/[^\r\n]+');
  for (final match in pattern.allMatches(text)) {
    var start = match.start, end = match.end;
    var raw = match.group(0)!;
    if (raw.startsWith('"')) {
      start++;
      end--;
      raw = raw.substring(1, raw.length - 1);
    }
    end -= raw.length - raw.trimRight().length;
    final target = localFilePath(raw);
    if (target == null || links.any((l) => start < l.end && end > l.start)) {
      continue;
    }
    links.add(NoteFileLink(start, end, target));
  }
  return links..sort((a, b) => a.start.compareTo(b.start));
}
