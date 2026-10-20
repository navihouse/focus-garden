import 'package:flutter/material.dart';
import 'app_controller.dart';
import 'domain/models.dart';

class TaskEditor extends StatefulWidget {
  final TaskItem? task;
  const TaskEditor({super.key, this.task});
  @override
  State<TaskEditor> createState() => _TaskEditorState();
}

class _SubtaskDraft {
  final String id;
  final TextEditingController name;
  bool completed;
  _SubtaskDraft(SubtaskItem item)
      : id = item.id,
        name = TextEditingController(text: item.name),
        completed = item.completed;
}

class _TaskEditorState extends State<TaskEditor> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.task?.name);
  late final category = TextEditingController(text: widget.task?.category);
  late final estimate =
      TextEditingController(text: '${widget.task?.estimate ?? 1}');
  late final notes = TextEditingController(text: widget.task?.notes);
  final nextStep = TextEditingController();
  late final subtasks =
      (widget.task?.subtasks ?? []).map(_SubtaskDraft.new).toList();
  // Keep removed controllers alive until the dialog finishes its exit frame.
  final retired = <TextEditingController>[];
  late String status = widget.task?.status ?? 'todo';
  late DateTime? due = widget.task?.due;

  @override
  void dispose() {
    for (final field in [
      name,
      category,
      estimate,
      notes,
      nextStep,
      ...subtasks.map((s) => s.name),
      ...retired
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  void addStep() {
    final value = nextStep.text.trim();
    if (value.isEmpty || value.length > 200 || subtasks.length >= 200) return;
    setState(() {
      subtasks.add(
          _SubtaskDraft(SubtaskItem(id: AppController.uuid.v4(), name: value)));
      nextStep.clear();
    });
  }

  void save() {
    if (!form.currentState!.validate()) return;
    if (nextStep.text.trim().isNotEmpty) {
      if (subtasks.length >= 200) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('每个任务最多 200 个子任务')));
        return;
      }
      addStep();
    }
    final task = TaskItem.fromJson(TaskItem(
      id: widget.task?.id ?? AppController.uuid.v4(),
      name: name.text.trim(),
      category: category.text.trim(),
      estimate: int.parse(estimate.text),
      status: status,
      due: due,
      notes: notes.text,
      subtasks: subtasks
          .map((s) => SubtaskItem(
              id: s.id, name: s.name.text.trim(), completed: s.completed))
          .toList(),
      modified: DateTime.now().toUtc(),
    ).toJson());
    Navigator.pop(context, task);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        insetPadding: const EdgeInsets.all(16),
        title: Text(widget.task == null ? '新建任务' : '任务详情'),
        content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
                child: Form(
                    key: form,
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextFormField(
                              key: const ValueKey('task-name'),
                              controller: name,
                              maxLength: 200,
                              decoration:
                                  const InputDecoration(labelText: '任务名称'),
                              validator: (v) => v!.trim().isEmpty
                                  ? '请填写任务名称'
                                  : v.length > 200
                                      ? '最多 200 字'
                                      : null),
                          const SizedBox(height: 8),
                          Text(
                              '子任务 · ${subtasks.where((s) => s.completed).length}/${subtasks.length} 完成',
                              style: Theme.of(context).textTheme.titleSmall),
                          const SizedBox(height: 6),
                          for (final entry in subtasks.indexed)
                            Row(
                                key: ValueKey('step-${entry.$2.id}'),
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Checkbox(
                                      value: entry.$2.completed,
                                      semanticLabel:
                                          '完成子任务 ${entry.$2.name.text}',
                                      onChanged: (v) => setState(
                                          () => entry.$2.completed = v!)),
                                  Expanded(
                                      child: TextFormField(
                                          key: ValueKey(
                                              'step-name-${entry.$2.id}'),
                                          controller: entry.$2.name,
                                          maxLength: 200,
                                          style: TextStyle(
                                              decoration: entry.$2.completed
                                                  ? TextDecoration.lineThrough
                                                  : null),
                                          decoration: const InputDecoration(
                                              hintText: '子任务', counterText: ''),
                                          validator: (v) => v!.trim().isEmpty
                                              ? '请填写子任务，或从菜单删除'
                                              : v.length > 200
                                                  ? '最多 200 字'
                                                  : null)),
                                  PopupMenuButton<String>(
                                      tooltip: '子任务选项',
                                      onSelected: (action) => setState(() {
                                            final i = entry.$1;
                                            if (action == 'remove') {
                                              retired.add(
                                                  subtasks.removeAt(i).name);
                                            } else {
                                              final destination = action == 'up'
                                                  ? i - 1
                                                  : i + 1;
                                              if (destination >= 0 &&
                                                  destination <
                                                      subtasks.length) {
                                                final item =
                                                    subtasks.removeAt(i);
                                                subtasks.insert(
                                                    destination, item);
                                              }
                                            }
                                          }),
                                      itemBuilder: (_) => [
                                            PopupMenuItem(
                                                value: 'up',
                                                enabled: entry.$1 > 0,
                                                child: const Text('上移')),
                                            PopupMenuItem(
                                                value: 'down',
                                                enabled: entry.$1 + 1 <
                                                    subtasks.length,
                                                child: const Text('下移')),
                                            const PopupMenuItem(
                                                value: 'remove',
                                                child: Text('删除子任务')),
                                          ]),
                                ]),
                          const SizedBox(height: 8),
                          Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                    child: TextFormField(
                                        key: const ValueKey('new-subtask'),
                                        controller: nextStep,
                                        enabled: subtasks.length < 200,
                                        maxLength: 200,
                                        onFieldSubmitted: (_) => addStep(),
                                        decoration: const InputDecoration(
                                            hintText: '添加下一步', counterText: ''),
                                        validator: (v) => (v?.length ?? 0) > 200
                                            ? '最多 200 字'
                                            : null)),
                                IconButton(
                                    tooltip: '添加子任务',
                                    onPressed:
                                        subtasks.length < 200 ? addStep : null,
                                    icon: const Icon(Icons.add)),
                              ]),
                          const SizedBox(height: 20),
                          TextFormField(
                              key: const ValueKey('task-notes'),
                              controller: notes,
                              minLines: 4,
                              maxLines: 8,
                              maxLength: 10000,
                              decoration: const InputDecoration(
                                  labelText: '备注',
                                  hintText: '添加备注，记录思路、要求或参考信息',
                                  alignLabelWithHint: true),
                              validator: (v) => (v?.length ?? 0) > 10000
                                  ? '备注最多 10000 字'
                                  : null),
                          const SizedBox(height: 12),
                          TextFormField(
                              controller: category,
                              maxLength: 100,
                              decoration:
                                  const InputDecoration(labelText: '科目或项目'),
                              validator: (v) =>
                                  (v?.length ?? 0) > 100 ? '最多 100 字' : null),
                          const SizedBox(height: 12),
                          TextFormField(
                              controller: estimate,
                              keyboardType: TextInputType.number,
                              decoration:
                                  const InputDecoration(labelText: '预计番茄数'),
                              validator: (v) {
                                final n = int.tryParse(v ?? '') ?? 0;
                                return n < 1 || n > 999 ? '填写 1–999' : null;
                              }),
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                              initialValue: status,
                              decoration:
                                  const InputDecoration(labelText: '状态'),
                              items: const [
                                DropdownMenuItem(
                                    value: 'todo', child: Text('待办')),
                                DropdownMenuItem(
                                    value: 'doing', child: Text('进行中')),
                                DropdownMenuItem(
                                    value: 'done', child: Text('已完成'))
                              ],
                              onChanged: (v) => status = v!),
                          const SizedBox(height: 8),
                          Row(children: [
                            Expanded(
                                child: Text(due == null
                                    ? '不设截止日期'
                                    : '${due!.year}.${due!.month}.${due!.day}')),
                            TextButton(
                                onPressed: () async {
                                  final selected = await showDatePicker(
                                      context: context,
                                      initialDate: due ?? DateTime.now(),
                                      firstDate: DateTime(2000),
                                      lastDate: DateTime(2100));
                                  if (selected != null && mounted) {
                                    setState(() => due = selected);
                                  }
                                },
                                child: const Text('选择日期')),
                            IconButton(
                                tooltip: '清除截止日期',
                                onPressed: () => setState(() => due = null),
                                icon: const Icon(Icons.clear)),
                          ]),
                        ])))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: save, child: const Text('保存'))
        ],
      );
}
