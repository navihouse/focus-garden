import 'package:flutter/material.dart';
import 'app_controller.dart';
import 'domain/models.dart';

/// Resolve a stored `#RRGGBB` value into the color used across the UI.
Color groupColor(TaskGroup group) =>
    Color(0xFF000000 | int.parse(group.color.substring(1), radix: 16));

/// Small colored marker that ties a task to its group.
Widget groupDot(TaskGroup group, {double size = 10, Key? key}) => Container(
    key: key,
    width: size,
    height: size,
    decoration:
        BoxDecoration(color: groupColor(group), shape: BoxShape.circle));

Future<void> showGroupManager(BuildContext context, AppController controller) =>
    showDialog<void>(
        context: context, builder: (_) => GroupManagerDialog(controller));

/// Create, rename, recolor, reorder, and delete task groups.
/// Editing a group never touches its tasks; deleting one returns them to
/// the ungrouped section.
class GroupManagerDialog extends StatefulWidget {
  final AppController controller;
  const GroupManagerDialog(this.controller, {super.key});
  @override
  State<GroupManagerDialog> createState() => _GroupManagerDialogState();
}

class _GroupManagerDialogState extends State<GroupManagerDialog> {
  AppController get c => widget.controller;
  bool savingOrder = false;

  Color colorOf(String hex) =>
      Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));

  Future<void> edit([TaskGroup? group]) async {
    final name = TextEditingController(text: group?.name);
    final form = GlobalKey<FormState>();
    var color = group?.color ?? TaskGroup.palette.first;
    final route = DialogRoute<(String, String)>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => AlertDialog(
                    title: Text(group == null ? '新建分组' : '编辑分组'),
                    content: SizedBox(
                        width: 360,
                        child: Form(
                            key: form,
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  TextFormField(
                                      key: const ValueKey('group-name'),
                                      controller: name,
                                      autofocus: true,
                                      maxLength: 40,
                                      decoration: const InputDecoration(
                                          labelText: '分组名称'),
                                      validator: (v) => c.groupNameError(v,
                                          exceptId: group?.id),
                                      onFieldSubmitted: (_) {
                                        if (form.currentState!.validate()) {
                                          Navigator.pop(
                                              ctx, (name.text.trim(), color));
                                        }
                                      }),
                                  const SizedBox(height: 8),
                                  Text('颜色',
                                      style:
                                          Theme.of(ctx).textTheme.labelLarge),
                                  const SizedBox(height: 8),
                                  Wrap(spacing: 10, runSpacing: 10, children: [
                                    for (final hex in TaskGroup.palette)
                                      Semantics(
                                          button: true,
                                          selected: hex == color,
                                          label: '分组颜色 $hex',
                                          child: InkWell(
                                              key: ValueKey('group-color-$hex'),
                                              borderRadius:
                                                  BorderRadius.circular(18),
                                              onTap: () =>
                                                  update(() => color = hex),
                                              child: Container(
                                                  width: 32,
                                                  height: 32,
                                                  decoration: BoxDecoration(
                                                      shape: BoxShape.circle,
                                                      color: colorOf(hex),
                                                      border: Border.all(
                                                          color: hex == color
                                                              ? Theme.of(ctx)
                                                                  .colorScheme
                                                                  .onSurface
                                                              : Colors
                                                                  .transparent,
                                                          width: 2)),
                                                  child: hex == color
                                                      ? const Icon(Icons.check,
                                                          size: 18,
                                                          color: Colors.white)
                                                      : null))),
                                  ]),
                                ]))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('取消')),
                      FilledButton(
                          key: const ValueKey('group-save'),
                          onPressed: () {
                            if (form.currentState!.validate()) {
                              Navigator.pop(ctx, (name.text.trim(), color));
                            }
                          },
                          child: Text(group == null ? '创建' : '保存')),
                    ])));
    final result = await Navigator.of(context).push(route);
    // Keep the field alive until the closing animation has finished.
    await route.completed;
    name.dispose();
    if (result == null) return;
    await c.perform(() async {
      if (group == null) {
        await c.createGroup(result.$1, result.$2);
      } else {
        await c.updateGroup(group.id, name: result.$1, color: result.$2);
      }
    });
  }

  Future<void> delete(TaskGroup group) async {
    final count = c.tasks.where((t) => t.groupId == group.id).length;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('删除分组？'),
              content: Text(count == 0
                  ? '将删除“${group.name}”。任务和专注记录不受影响。'
                  : '将删除“${group.name}”，其中 $count 个任务会移到“未分组”，'
                      '已保存的专注记录不受影响。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消')),
                FilledButton(
                    key: const ValueKey('confirm-delete-group'),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('删除')),
              ],
            ));
    if (confirmed == true) await c.perform(() => c.deleteGroup(group.id));
  }

  Widget row(TaskGroup group, int index) {
    final count = c.tasks.where((t) => t.groupId == group.id).length;
    return Column(key: ValueKey('group-row-${group.id}'), children: [
      ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: groupDot(group,
              key: ValueKey('group-swatch-${group.id}'), size: 14),
          title: Text(group.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('$count 个任务'),
          trailing: MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: ReorderableDragStartListener(
              key: ValueKey('group-drag-${group.id}'),
              index: index,
              enabled: !savingOrder,
              child: PopupMenuButton<String>(
                  key: ValueKey('group-menu-${group.id}'),
                  tooltip: '拖动排序，点击打开分组选项',
                  onSelected: (v) => v == 'edit' ? edit(group) : delete(group),
                  itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('重命名与颜色')),
                        PopupMenuDivider(),
                        PopupMenuItem(value: 'delete', child: Text('删除分组')),
                      ]),
            ),
          )),
      if (index < c.groups.length - 1) const Divider(height: 1),
    ]);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final groups = List<TaskGroup>.from(c.groups);
        return AlertDialog(
          key: const ValueKey('group-manager'),
          title: const Text('任务分组'),
          content: SizedBox(
              width: 430,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('用分组整理任务，可自定义名称和颜色。分组只影响列表展示，'
                        '不改变专注记录和统计。'),
                    const SizedBox(height: 8),
                    Text('按住右侧三个点拖动排序，点击可编辑或删除。',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 12),
                    if (groups.isEmpty)
                      const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Text('还没有分组。创建后可在任务详情中选择。'))
                    else
                      ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 320),
                          child: ReorderableListView.builder(
                              key: const ValueKey('group-reorder-list'),
                              padding: EdgeInsets.zero,
                              shrinkWrap: true,
                              buildDefaultDragHandles: false,
                              itemCount: groups.length,
                              onReorderItem: (oldIndex, newIndex) async {
                                final id = groups[oldIndex].id;
                                setState(() => savingOrder = true);
                                try {
                                  await c.perform(
                                      () => c.reorderGroup(id, newIndex));
                                } finally {
                                  if (mounted) {
                                    setState(() => savingOrder = false);
                                  }
                                }
                              },
                              itemBuilder: (_, i) => row(groups[i], i))),
                  ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭')),
            FilledButton.icon(
                key: const ValueKey('new-group'),
                onPressed: edit,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('新建分组')),
          ],
        );
      });
}
