import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_controller.dart';
import 'automation_controller.dart';
import 'domain/automation.dart';
import 'domain/models.dart';
import 'domain/reports.dart';
import 'study_scraper.dart';

class AutomationPage extends StatefulWidget {
  final AppController controller;
  final Future<void> Function(String id) onOpenTask;
  const AutomationPage(this.controller, {super.key, required this.onOpenTask});
  @override
  State<AutomationPage> createState() => _AutomationPageState();
}

class _AutomationPageState extends State<AutomationPage> {
  bool scraperPage = false, busy = false;
  String notice = '';
  AutomationController? get auto => widget.controller.automation;

  String stamp(DateTime value) {
    final civil = beijing(value);
    return '${dayKey(civil)} ${minuteLabel(civil.hour * 60 + civil.minute)}';
  }

  Future<void> execute(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      notice = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() =>
            notice = e is FormatException ? e.message : '操作未完成，请检查文件或本机环境后重试。');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> chooseTime(bool morning) async {
    final service = auto!;
    final minute = morning
        ? service.settings.morningMinute
        : service.settings.scraperMinute;
    final picked = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60));
    if (picked == null || !mounted) return;
    await execute(() => service.saveSettings(service.settings.copyWith({
          morning ? 'morningMinute' : 'scraperMinute':
              picked.hour * 60 + picked.minute
        })));
  }

  Widget panel(List<Widget> children) => Card(
      child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children)));

  Widget morningSettings(AutomationController service) => panel([
        SwitchListTile(
            key: const ValueKey('auto-morning-enabled'),
            contentPadding: EdgeInsets.zero,
            title: const Text('每日发送今日开始'),
            subtitle: const Text('生成今日截止、昨日完成和昨日逾期未完成的任务摘要。'),
            value: service.settings.morningEnabled,
            onChanged: busy
                ? null
                : (value) => execute(() => service.saveSettings(
                    service.settings.copyWith({'morningEnabled': value})))),
        Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                  key: const ValueKey('auto-morning-time'),
                  onPressed: busy ? null : () => chooseTime(true),
                  icon: const Icon(Icons.schedule),
                  label: Text(
                      '发送时间 ${minuteLabel(service.settings.morningMinute)}')),
              FilledButton.tonal(
                  key: const ValueKey('auto-send-morning'),
                  onPressed:
                      busy ? null : () => execute(service.generateMorning),
                  child: const Text('生成今日开始')),
            ]),
        const SizedBox(height: 12),
        Text(service.nextMorning == null
            ? '每日发送尚未开启。'
            : '下次发送 ${stamp(service.nextMorning!)}'),
        const SizedBox(height: 6),
        const Text('软件打开或托盘运行时执行，重开后补发当天已到时间的摘要，每天一封。'),
      ]);

  Future<void> openMessage(MorningMessage message) async {
    final service = auto!;
    await execute(() async {
      await service.markRead(message.day);
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
                title: Text('今日开始 · ${message.day}'),
                content: SizedBox(
                    width: 640,
                    height: MediaQuery.sizeOf(ctx).height * .6,
                    child: ListView(children: [
                      Text('发送于 ${stamp(message.generatedAt)}'),
                      const SizedBox(height: 8),
                      const Text('以下内容保留发送时的任务状态。昨日未完成仅统计昨天截止且发送时仍未完成的任务。'),
                      ...messageSection('今日截止', message.dueToday),
                      ...messageSection('昨日完成', message.completedYesterday),
                      ...messageSection('昨日未完成', message.unfinishedYesterday),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('关闭'))
                ],
              ));
    });
  }

  List<Widget> messageSection(String title, List<Json> tasks) => [
        const SizedBox(height: 18),
        Text('$title · ${tasks.length}',
            style: Theme.of(context).textTheme.titleMedium),
        if (tasks.isEmpty)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 12), child: Text('暂无任务')),
        for (final task in tasks)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(task['name'] as String),
            subtitle: Text((task['category'] as String).isEmpty
                ? task['deadline'] as String
                : '${task['category'] as String}\n${task['deadline'] as String}'),
            trailing: widget.controller.tasks.any((t) => t.id == task['id'])
                ? IconButton(
                    tooltip: '查看任务',
                    icon: const Icon(Icons.open_in_new),
                    onPressed: () => widget.onOpenTask(task['id'] as String))
                : null,
          ),
      ];

  List<Widget> morningCards(AutomationController service) => [
        morningSettings(service),
        const SizedBox(height: 18),
        Text('今日开始收件箱', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (service.messages.isEmpty)
          panel([
            const Text('还没有摘要。可设置发送时间，也可点击“生成今日开始”。'),
          ]),
        for (final message in service.messages)
          Card(
              child: ListTile(
            key: ValueKey('auto-message-${message.day}'),
            leading: Badge(
                isLabelVisible: message.unread,
                child: const Icon(Icons.wb_sunny_outlined)),
            title: Text('今日开始 · ${message.day}'),
            subtitle: Text(
                '今日截止 ${message.dueToday.length} · 昨日完成 ${message.completedYesterday.length} · 昨日未完成 ${message.unfinishedYesterday.length}'),
            isThreeLine: true,
            onTap: busy ? null : () => openMessage(message),
            trailing: Text(message.unread ? '未读' : '已读'),
          )),
      ];

  Future<void> importJson() async {
    await execute(() async {
      final files = await FilePicker.platform.pickFiles(
          dialogTitle: '选择脚本生成的 todos.json',
          type: FileType.custom,
          allowedExtensions: ['json']);
      final path = files?.files.single.path;
      if (path == null || auto == null) return;
      final file = File(path);
      if (await file.length() > 10 * 1024 * 1024) {
        throw const FormatException('采集结果超过 10 MB');
      }
      final payload = ScrapePayload.parse(await file.readAsString());
      final result = await auto!.importPayload(payload);
      if (mounted) setState(() => notice = result.label);
    });
  }

  Future<void> configureExpiry(AutomationController service) async {
    final old = service.settings.expiredAfterDays;
    var selected = [-1, 0, 7, 30].contains(old) ? old : -2;
    final days = TextEditingController(text: '${old > 0 ? old : 7}');
    final form = GlobalKey<FormState>();
    final route = DialogRoute<int>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => AlertDialog(
                  title: const Text('过期任务规则'),
                  content: SizedBox(
                      width: 440,
                      child: SingleChildScrollView(
                          child: Form(
                              key: form,
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    DropdownButtonFormField<int>(
                                        key: const ValueKey('auto-expiry-rule'),
                                        initialValue: selected,
                                        isExpanded: true,
                                        decoration: const InputDecoration(
                                            labelText: '忽略规则'),
                                        items: [
                                          for (final value in [
                                            0,
                                            7,
                                            30,
                                            -2,
                                            -1
                                          ])
                                            DropdownMenuItem(
                                                value: value,
                                                child: Text(value == -2
                                                    ? '自定义过期天数'
                                                    : expiredRuleLabel(value)))
                                        ],
                                        onChanged: (value) =>
                                            update(() => selected = value!)),
                                    if (selected == -2)
                                      Padding(
                                          padding:
                                              const EdgeInsets.only(top: 16),
                                          child: TextFormField(
                                              key: const ValueKey(
                                                  'auto-expiry-days'),
                                              controller: days,
                                              keyboardType:
                                                  TextInputType.number,
                                              inputFormatters: [
                                                FilteringTextInputFormatter
                                                    .digitsOnly,
                                                LengthLimitingTextInputFormatter(
                                                    4)
                                              ],
                                              decoration: const InputDecoration(
                                                  labelText: '过期超过多少天后忽略'),
                                              validator: (value) {
                                                final n =
                                                    int.tryParse(value ?? '');
                                                return n == null ||
                                                        n < 0 ||
                                                        n > 3650
                                                    ? '填写 0–3650 天'
                                                    : null;
                                              })),
                                    const SizedBox(height: 14),
                                    const Text(
                                        '7 天即一周，30 天约一个月；按当前时间向前计算，恰好 N 天的保留。'
                                        '无截止时间的任务不按天数推断。规则只影响采集和 JSON 导入，不删除已有任务。'),
                                  ])))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消')),
                    FilledButton(
                        key: const ValueKey('auto-save-expiry'),
                        onPressed: () {
                          if (form.currentState!.validate()) {
                            Navigator.pop(
                                ctx,
                                selected == -2
                                    ? int.parse(days.text)
                                    : selected);
                          }
                        },
                        child: const Text('保存'))
                  ],
                )));
    final value = await Navigator.of(context).push(route);
    await route.completed;
    days.dispose();
    if (value != null && mounted) {
      await execute(() => service.saveSettings(
          service.settings.copyWith({'expiredAfterDays': value})));
    }
  }

  Future<void> configureScraper(AutomationController service) async {
    final config = service.settings;
    final python = TextEditingController(text: config.pythonPath);
    final script = TextEditingController(text: config.scriptPath);
    final cx = TextEditingController(text: config.chaoxingCookiePath);
    final mooc = TextEditingController(text: config.moocCookiePath);
    var cxEnabled = config.chaoxing, moocEnabled = config.mooc;
    var groupId =
        widget.controller.groups.any((g) => g.id == config.importGroupId)
            ? config.importGroupId
            : '';
    final form = GlobalKey<FormState>();
    String? validation;
    final route = DialogRoute<AutomationSettings>(
        context: context,
        builder: (ctx) => StatefulBuilder(builder: (ctx, update) {
              Widget pathField(String key, String label,
                      TextEditingController controller) =>
                  Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                                child: TextFormField(
                              key: ValueKey(key),
                              controller: controller,
                              decoration: InputDecoration(labelText: label),
                              validator: (value) =>
                                  value == null || value.trim().isEmpty
                                      ? '请填写或选择文件'
                                      : null,
                            )),
                            IconButton(
                                tooltip: '选择$label',
                                icon: const Icon(Icons.folder_open),
                                onPressed: () async {
                                  final selected = await FilePicker.platform
                                      .pickFiles(dialogTitle: '选择$label');
                                  final path = selected?.files.single.path;
                                  if (path != null && ctx.mounted) {
                                    controller.text = path;
                                  }
                                }),
                          ]));
              return AlertDialog(
                  title: const Text('配置学习平台采集'),
                  content: SizedBox(
                      width: 560,
                      child: SingleChildScrollView(
                          child: Form(
                              key: form,
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                        '使用本机 Python 和已有脚本读取你的学习平台任务。Python 需要 requests 依赖。'),
                                    const SizedBox(height: 16),
                                    pathField('auto-python-path',
                                        'Python 程序或命令', python),
                                    pathField(
                                        'auto-script-path', '采集脚本', script),
                                    CheckboxListTile(
                                        contentPadding: EdgeInsets.zero,
                                        title: const Text('学习通'),
                                        value: cxEnabled,
                                        onChanged: (value) =>
                                            update(() => cxEnabled = value!)),
                                    if (cxEnabled)
                                      pathField('auto-chaoxing-cookie',
                                          '学习通 Cookie 文件', cx),
                                    CheckboxListTile(
                                        contentPadding: EdgeInsets.zero,
                                        title: const Text('中国大学MOOC'),
                                        value: moocEnabled,
                                        onChanged: (value) =>
                                            update(() => moocEnabled = value!)),
                                    if (moocEnabled)
                                      pathField('auto-mooc-cookie',
                                          'MOOC Cookie 文件', mooc),
                                    DropdownButtonFormField<String>(
                                        key:
                                            const ValueKey('auto-import-group'),
                                        initialValue: groupId,
                                        isExpanded: true,
                                        decoration: const InputDecoration(
                                            labelText: '任务保存到'),
                                        items: [
                                          const DropdownMenuItem(
                                              value: '', child: Text('未分组')),
                                          for (final group
                                              in widget.controller.groups)
                                            DropdownMenuItem(
                                                value: group.id,
                                                child: Text(group.name,
                                                    overflow:
                                                        TextOverflow.ellipsis)),
                                        ],
                                        onChanged: (value) =>
                                            groupId = value ?? ''),
                                    const SizedBox(height: 12),
                                    const Text('Cookie 文件仅在本机读取。登录过期后更新文件即可。'),
                                    if (validation != null)
                                      Text(validation!,
                                          style: TextStyle(
                                              color: Theme.of(ctx)
                                                  .colorScheme
                                                  .error)),
                                  ])))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消')),
                    FilledButton(
                        key: const ValueKey('auto-save-scraper-config'),
                        onPressed: () {
                          if (!form.currentState!.validate()) return;
                          if (!cxEnabled && !moocEnabled) {
                            update(() => validation = '请选择至少一个平台');
                            return;
                          }
                          Navigator.pop(
                              ctx,
                              config.copyWith({
                                'pythonPath': python.text.trim(),
                                'scriptPath': script.text.trim(),
                                'chaoxingCookiePath': cx.text.trim(),
                                'moocCookiePath': mooc.text.trim(),
                                'chaoxing': cxEnabled,
                                'mooc': moocEnabled,
                                'importGroupId': groupId,
                              }));
                        },
                        child: const Text('保存')),
                  ]);
            }));
    final saved = await Navigator.of(context).push(route);
    await route.completed;
    for (final controller in [python, script, cx, mooc]) {
      controller.dispose();
    }
    if (saved != null && mounted) {
      await execute(() => service.saveSettings(saved));
    }
  }

  List<Widget> scraperCards(AutomationController service) => [
        panel([
          Text('学习平台任务采集', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (service.supportsScraper) ...[
            SwitchListTile(
                contentPadding: EdgeInsets.zero,
                key: const ValueKey('auto-scraper-enabled'),
                title: const Text('每日自动采集'),
                subtitle: const Text('学习通和中国大学MOOC的作业、考试、测验将保存为任务。'),
                value: service.settings.scraperEnabled,
                onChanged: busy || service.scraping
                    ? null
                    : (value) => execute(() => service.saveSettings(
                        service.settings.copyWith({'scraperEnabled': value})))),
            Wrap(spacing: 10, runSpacing: 8, children: [
              OutlinedButton.icon(
                  key: const ValueKey('auto-scraper-time'),
                  icon: const Icon(Icons.schedule),
                  onPressed:
                      busy || service.scraping ? null : () => chooseTime(false),
                  label: Text(
                      '采集时间 ${minuteLabel(service.settings.scraperMinute)}')),
              OutlinedButton(
                  key: const ValueKey('auto-configure-scraper'),
                  onPressed: busy || service.scraping
                      ? null
                      : () => configureScraper(service),
                  child: const Text('配置采集')),
              FilledButton(
                  key: const ValueKey('auto-run-scraper'),
                  onPressed: busy || service.scraping
                      ? null
                      : () => execute(service.runScraper),
                  child: const Text('立即采集')),
              if (service.scraping)
                OutlinedButton(
                    onPressed: service.cancelScraper,
                    child: const Text('取消采集')),
            ]),
            const SizedBox(height: 12),
            Text(service.nextScrape == null
                ? '每日采集尚未开启。'
                : '下次采集 ${stamp(service.nextScrape!)}'),
            const SizedBox(height: 8),
            const Text('在软件打开或托盘运行时执行，重开后补跑当天已到时间的采集。'),
          ] else
            const Text(
                'Python 定时采集在 Windows 上运行。手机可导入脚本生成的 todos.json，或通过任务备份获取电脑版已采集的任务。'),
          const SizedBox(height: 14),
          Text(expiredRuleLabel(service.settings.expiredAfterDays)),
          OutlinedButton.icon(
              key: const ValueKey('auto-configure-expiry'),
              onPressed: busy || service.scraping
                  ? null
                  : () => configureExpiry(service),
              icon: const Icon(Icons.filter_alt_outlined),
              label: const Text('过期任务规则')),
          const SizedBox(height: 10),
          OutlinedButton.icon(
              key: const ValueKey('auto-import-json'),
              onPressed: busy || service.scraping ? null : importJson,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('导入采集结果')),
          const SizedBox(height: 8),
          const Text('相同平台任务按来源编号去重。会保留任务完成状态、分组、子任务、备注以及手动修改。'),
        ]),
        if (service.scraping)
          const Padding(
              padding: EdgeInsets.all(12),
              child: Column(children: [
                LinearProgressIndicator(),
                SizedBox(height: 8),
                Text('正在采集，番茄钟可继续使用。')
              ])),
        panel([
          Text('最近一次采集', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(service.scrapeStatus['lastRunAt'] == null
              ? '暂无采集记录'
              : stamp(utc(service.scrapeStatus['lastRunAt'] as String))),
          if (service.scrapeStatus['summary'] != null)
            Text(service.scrapeStatus['summary'] as String),
          if ((service.scrapeStatus['error'] as String? ?? '').isNotEmpty)
            Text(service.scrapeStatus['error'] as String,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ]),
      ];

  @override
  Widget build(BuildContext context) {
    final service = auto;
    if (service == null) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('自动化暂不可用'),
        TextButton(
            onPressed: busy
                ? null
                : () => execute(widget.controller.initializeAutomation),
            child: const Text('重新加载')),
      ]));
    }
    return ListView(padding: const EdgeInsets.all(24), children: [
      Text('自动化', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 6),
      const Text('定时整理学习任务 · 时间均为北京时间'),
      const SizedBox(height: 18),
      Wrap(spacing: 10, runSpacing: 8, children: [
        ChoiceChip(
            key: const ValueKey('auto-morning-tab'),
            label: Badge(
                isLabelVisible: service.hasUnread,
                child: const Padding(
                    padding: EdgeInsets.only(right: 6), child: Text('今日开始'))),
            selected: !scraperPage,
            onSelected: (_) => setState(() => scraperPage = false)),
        ChoiceChip(
            key: const ValueKey('auto-scraper-tab'),
            label: const Text('学习平台采集'),
            selected: scraperPage,
            onSelected: (_) => setState(() => scraperPage = true)),
      ]),
      const SizedBox(height: 14),
      if (notice.isNotEmpty || service.error.isNotEmpty)
        panel([Text(notice.isNotEmpty ? notice : service.error)]),
      ...(scraperPage ? scraperCards(service) : morningCards(service)),
    ]);
  }
}
