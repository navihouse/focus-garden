import 'package:flutter/material.dart';
import 'domain/note_link.dart';

class NotesController extends TextEditingController {
  List<NoteFileLink> _explicit;
  final _history = <String, List<NoteFileLink>>{};
  NotesController(String text, List<NoteFileLink> links)
      : _explicit = List.from(links),
        super(text: text) {
    _remember();
  }
  List<NoteFileLink> get links => detectedFileLinks(text, _explicit);
  void _remember() {
    _history[text] = List.from(_explicit);
    if (_history.length > 100) _history.remove(_history.keys.first);
  }

  @override
  set value(TextEditingValue next) {
    if (next.text != text) {
      final restored = _history[next.text];
      if (restored != null) {
        _explicit = List.from(restored);
      } else {
        final old = text, fresh = next.text;
        int prefix = 0, suffix = 0;
        while (prefix < old.length &&
            prefix < fresh.length &&
            old[prefix] == fresh[prefix]) {
          prefix++;
        }
        while (suffix < old.length - prefix &&
            suffix < fresh.length - prefix &&
            old[old.length - 1 - suffix] == fresh[fresh.length - 1 - suffix]) {
          suffix++;
        }
        final oldEnd = old.length - suffix, delta = fresh.length - old.length;
        _explicit = [
          for (final link in _explicit)
            if (link.end <= prefix)
              link
            else if (link.start >= oldEnd)
              link.shifted(delta)
            else if (prefix >= link.start &&
                oldEnd <= link.end &&
                link.end + delta > link.start)
              NoteFileLink(link.start, link.end + delta, link.target),
        ];
      }
      super.value = next;
      _remember();
    } else {
      super.value = next;
    }
  }

  void insertLink(String target, String label) {
    final selected = selection.isValid
        ? selection
        : TextSelection.collapsed(offset: text.length);
    _replace(selected.start, selected.end, label, target);
  }

  void renameLink(NoteFileLink link, String label) =>
      _replace(link.start, link.end, label, link.target);
  void _replace(int start, int end, String label, String target) {
    final delta = label.length - (end - start);
    final retained = [
      for (final link in links)
        if (link.end <= start)
          link
        else if (link.start >= end)
          link.shifted(delta)
    ];
    retained.add(NoteFileLink(start, start + label.length, target));
    _explicit = retained..sort((a, b) => a.start.compareTo(b.start));
    super.value = TextEditingValue(
        text: text.replaceRange(start, end, label),
        selection: TextSelection.collapsed(offset: start + label.length));
    _remember();
  }

  @override
  TextSpan buildTextSpan(
      {required BuildContext context,
      TextStyle? style,
      required bool withComposing}) {
    if (withComposing &&
        value.composing.isValid &&
        !value.composing.isCollapsed) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }
    final spans = <InlineSpan>[];
    int cursor = 0;
    for (final link in links) {
      if (cursor < link.start) {
        spans.add(TextSpan(text: text.substring(cursor, link.start)));
      }
      spans.add(TextSpan(
          text: text.substring(link.start, link.end),
          style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              decoration: TextDecoration.underline)));
      cursor = link.end;
    }
    spans.add(TextSpan(text: text.substring(cursor)));
    return TextSpan(style: style, children: spans);
  }
}
