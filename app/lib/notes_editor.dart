import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'app_controller.dart';
import 'domain/note_link.dart';
import 'notes_controller.dart';

class NotesEditor extends StatefulWidget {
  final NotesController controller;
  const NotesEditor({super.key, required this.controller});
  @override
  State<NotesEditor> createState() => _NotesEditorState();
}

class _NotesEditorState extends State<NotesEditor> {
  final fieldKey = GlobalKey();
  NoteFileLink? contextLink;
  String? error;
  RenderEditable? get editable {
    RenderEditable? found;
    void visit(RenderObject object) {
      if (object is RenderEditable) {
        found = object;
        return;
      }
      object.visitChildren(visit);
    }

    final root = fieldKey.currentContext?.findRenderObject();
    if (root != null) visit(root);
    return found;
  }

  NoteFileLink? linkAt(Offset global) {
    final render = editable;
    if (render == null) return null;
    final local = render.globalToLocal(global);
    if (!(Offset.zero & render.size).contains(local)) return null;
    for (final link in widget.controller.links) {
      final boxes = render.getBoxesForSelection(
          TextSelection(baseOffset: link.start, extentOffset: link.end));
      if (boxes.any((box) => box.toRect().contains(local))) return link;
    }
    return null;
  }

  Future<void> openLink(NoteFileLink link) async {
    try {
      await AppController.native
          .invokeMethod('openLocalFile', {'path': link.target});
      if (mounted) setState(() => error = null);
    } catch (_) {
      if (mounted) {
        setState(() => error = '无法打开文件，请确认文件在当前设备上存在、可访问，且已安装对应的打开程序。');
      }
    }
  }

  Future<void> rename(NoteFileLink link) async {
    final name = TextEditingController(
        text: widget.controller.text.substring(link.start, link.end));
    final form = GlobalKey<FormState>();
    final route = DialogRoute<String>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('修改链接显示名称'),
                content: Form(
                    key: form,
                    child: TextFormField(
                        key: const ValueKey('link-name'),
                        autofocus: true,
                        controller: name,
                        maxLength: 200,
                        decoration: const InputDecoration(
                            labelText: '显示名称',
                            helperText: '只修改备注中的名称，不修改文件或打开地址。'),
                        validator: (v) => v == null ||
                                v.trim().isEmpty ||
                                v.trim().length > 200
                            ? '填写 1–200 字的名称'
                            : null,
                        onFieldSubmitted: (_) {
                          if (form.currentState!.validate()) {
                            Navigator.pop(ctx, name.text.trim());
                          }
                        })),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () {
                        if (form.currentState!.validate()) {
                          Navigator.pop(ctx, name.text.trim());
                        }
                      },
                      child: const Text('确定'))
                ]));
    final label = await Navigator.of(context).push(route);
    if (label != null && mounted) {
      if (widget.controller.text.length -
              (link.end - link.start) +
              label.length >
          10000) {
        setState(() => error = '备注最多 10000 字，请缩短显示名称。');
      } else {
        widget.controller.renameLink(link, label);
      }
    }
    await route.completed;
    name.dispose();
  }

  Future<void> addLink() async {
    final path = TextEditingController(), label = TextEditingController();
    final form = GlobalKey<FormState>();
    String? cachedSource;
    final route = DialogRoute<(String, String)>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('添加本地文件链接'),
                content: SizedBox(
                    width: 440,
                    child: Form(
                        key: form,
                        child: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              TextFormField(
                                  key: const ValueKey('link-path'),
                                  controller: path,
                                  maxLines: 3,
                                  decoration:
                                      const InputDecoration(labelText: '文件地址'),
                                  validator: (v) =>
                                      localFilePath(v ?? '') == null
                                          ? '填写完整的本地文件地址'
                                          : null),
                              TextButton.icon(
                                  onPressed: () async {
                                    final files =
                                        await FilePicker.platform.pickFiles();
                                    final file = files?.files.single;
                                    if (file?.path != null && ctx.mounted) {
                                      path.text = file!.path!;
                                      cachedSource = file.path;
                                      if (label.text.isEmpty) {
                                        label.text = file.name;
                                      }
                                    }
                                  },
                                  icon: const Icon(Icons.folder_open),
                                  label: const Text('选择本地文件')),
                              TextFormField(
                                  key: const ValueKey('link-label'),
                                  controller: label,
                                  maxLength: 200,
                                  decoration: const InputDecoration(
                                      labelText: '显示名称（可选）'),
                                  validator: (v) =>
                                      (v?.trim().length ?? 0) > 200
                                          ? '最多 200 字'
                                          : null),
                            ])))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () {
                        if (form.currentState!.validate()) {
                          Navigator.pop(ctx,
                              (localFilePath(path.text)!, label.text.trim()));
                        }
                      },
                      child: const Text('插入'))
                ]));
    final result = await Navigator.of(context).push(route);
    await route.completed;
    path.dispose();
    label.dispose();
    if (result == null || !mounted) return;
    String target = result.$1;
    String display = result.$2.isEmpty
        ? p.basename(target.replaceAll('\\', '/'))
        : result.$2;
    if (display.isEmpty) display = target;
    final controller = widget.controller;
    final selected = controller.selection.isValid
        ? controller.selection
        : TextSelection.collapsed(offset: controller.text.length);
    if (controller.links.length >= 200 ||
        controller.text.length -
                (selected.end - selected.start) +
                display.length >
            10000) {
      setState(() => error = '备注最多 10000 字、200 个文件链接。');
      return;
    }
    try {
      // Android document pickers return a temporary cached copy. Own a stable copy
      // inside the app's note-files directory; Windows keeps the original path.
      if (Platform.isAndroid && target == cachedSource) {
        final root = await getApplicationSupportDirectory();
        final directory = await Directory(p.join(root.path, 'note-files'))
            .create(recursive: true);
        target = (await File(target).copy(p.join(directory.path,
                '${AppController.uuid.v4()}${p.extension(target)}')))
            .path;
      }
      if (!mounted) return;
      controller.insertLink(target, display);
      setState(() => error = null);
    } catch (_) {
      if (mounted) setState(() => error = '文件无法访问，请重新选择。');
    }
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Listener(
            onPointerDown: (event) {
              contextLink = linkAt(event.position);
              if (event.buttons == kPrimaryButton &&
                  HardwareKeyboard.instance.isControlPressed &&
                  contextLink != null) {
                unawaited(openLink(contextLink!));
              }
            },
            child: KeyedSubtree(
                key: fieldKey,
                child: TextFormField(
                    key: const ValueKey('task-notes'),
                    controller: widget.controller,
                    minLines: 4,
                    maxLines: 8,
                    maxLength: 10000,
                    contextMenuBuilder: (ctx, state) {
                      final link = contextLink;
                      return AdaptiveTextSelectionToolbar.buttonItems(
                          anchors: state.contextMenuAnchors,
                          buttonItems: [
                            if (link != null) ...[
                              ContextMenuButtonItem(
                                  label: '修改链接显示名称',
                                  onPressed: () {
                                    state.hideToolbar();
                                    unawaited(rename(link));
                                  }),
                              ContextMenuButtonItem(
                                  label: '打开文件',
                                  onPressed: () {
                                    state.hideToolbar();
                                    unawaited(openLink(link));
                                  }),
                            ],
                            ...state.contextMenuButtonItems,
                          ]);
                    },
                    decoration: const InputDecoration(
                        labelText: '备注',
                        hintText: '记录思路，或粘贴完整的本地文件地址',
                        alignLabelWithHint: true),
                    validator: (v) => (v?.length ?? 0) > 10000
                        ? '备注最多 10000 字'
                        : widget.controller.links.length > 200
                            ? '备注最多 200 个链接'
                            : null))),
        TextButton.icon(
            key: const ValueKey('add-note-link'),
            onPressed: addLink,
            icon: const Icon(Icons.add_link),
            label: const Text('添加本地文件链接')),
        Text(
            Platform.isWindows
                ? 'Ctrl + 单击打开文件；右键链接可修改显示名称。编辑后请保存任务。'
                : '长按链接可打开文件或修改显示名称。文件仅在本机保存，不随备份传输。',
            style: Theme.of(context).textTheme.bodySmall),
        if (error != null)
          Text(error!,
              key: const ValueKey('note-link-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ]);
}
