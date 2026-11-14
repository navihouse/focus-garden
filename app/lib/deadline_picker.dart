import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'domain/reports.dart';

class TaskDeadline {
  final DateTime date;
  final TimeOfDay? time;
  const TaskDeadline(this.date, this.time);
}

Future<TaskDeadline?> pickTaskDeadline(BuildContext context,
    {DateTime? date, TimeOfDay? time}) async {
  final today = beijing(DateTime.now());
  final picked = await showDatePicker(
      context: context,
      initialDate: date ?? DateTime(today.year, today.month, today.day),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100));
  if (picked == null || !context.mounted) return null;
  return showDialog<TaskDeadline>(
      context: context,
      builder: (_) => DeadlineTimeDialog(
          date: picked,
          initialTime: time,
          initialAllDay: date != null && time == null));
}

class DeadlineTimeDialog extends StatefulWidget {
  final DateTime date;
  final TimeOfDay? initialTime;
  final bool initialAllDay;
  const DeadlineTimeDialog(
      {super.key,
      required this.date,
      this.initialTime,
      this.initialAllDay = false});
  @override
  State<DeadlineTimeDialog> createState() => _DeadlineTimeDialogState();
}

class _DeadlineTimeDialogState extends State<DeadlineTimeDialog> {
  final form = GlobalKey<FormState>();
  late bool allDay = widget.initialAllDay;
  late final hour = TextEditingController(
      text: '${widget.initialTime?.hour ?? 23}'.padLeft(2, '0'));
  late final minute = TextEditingController(
      text: '${widget.initialTime?.minute ?? 59}'.padLeft(2, '0'));
  @override
  void initState() {
    super.initState();
    hour.selection =
        TextSelection(baseOffset: 0, extentOffset: hour.text.length);
  }

  @override
  void dispose() {
    hour.dispose();
    minute.dispose();
    super.dispose();
  }

  Widget field(String name, TextEditingController controller, int maximum) =>
      Expanded(
          child: TextFormField(
              key: ValueKey('deadline-$name'),
              controller: controller,
              enabled: !allDay,
              autofocus: name == 'hour' && !allDay,
              keyboardType: TextInputType.number,
              textInputAction:
                  name == 'hour' ? TextInputAction.next : TextInputAction.done,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(2)
              ],
              decoration: InputDecoration(
                  labelText: name == 'hour' ? '小时' : '分钟',
                  helperText: '00–${maximum.toString().padLeft(2, '0')}'),
              validator: (text) {
                if (allDay) return null;
                final value = int.tryParse(text ?? '');
                return value == null || value < 0 || value > maximum
                    ? '填写 0–$maximum'
                    : null;
              }));

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('截止日期和时间'),
        content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
                child: Form(
                    key: form,
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(dayKey(widget.date),
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          const Text('截止时间（北京时间 · 24 小时制）'),
                          const SizedBox(height: 18),
                          Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                field('hour', hour, 23),
                                const Padding(
                                    padding: EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 12),
                                    child: Text(':')),
                                field('minute', minute, 59)
                              ]),
                          CheckboxListTile(
                              key: const ValueKey('deadline-all-day'),
                              contentPadding: EdgeInsets.zero,
                              title: const Text('全天'),
                              subtitle: const Text('只设置日期，无需选择截止时间'),
                              value: allDay,
                              onChanged: (value) {
                                FocusScope.of(context).unfocus();
                                setState(() => allDay = value!);
                              }),
                        ])))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              key: const ValueKey('deadline-confirm'),
              onPressed: () {
                if (!form.currentState!.validate()) return;
                Navigator.pop(
                    context,
                    TaskDeadline(
                        DateTime.utc(widget.date.year, widget.date.month,
                            widget.date.day),
                        allDay
                            ? null
                            : TimeOfDay(
                                hour: int.parse(hour.text),
                                minute: int.parse(minute.text))));
              },
              child: const Text('确定'))
        ],
      );
}
