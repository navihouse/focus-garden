import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'app_controller.dart';
import 'music_library_page.dart';
import 'app_background.dart';
import 'hotkey_editor.dart';
import 'domain/hotkey.dart';
import 'data/backup.dart';
import 'domain/models.dart';
import 'domain/reports.dart';
import 'domain/timer_engine.dart';
import 'task_editor.dart';
import 'report_charts.dart';
import 'report_analysis.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    MediaKit.ensureInitialized();
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(const Size(460, 640));
    await windowManager.setSize(const Size(1140, 820));
    await windowManager.setTitle('专注花园 · Focus Garden');
  }
  final controller = AppController();
  try {
    await controller.initialize();
    runApp(FocusApp(controller));
  } catch (e) {
    runApp(MaterialApp(
        home: Scaffold(
            body: Center(
                child: SelectableText('启动未完成\n$e\n请保留数据文件，检查磁盘空间后重试。')))));
  }
}

String minutes(int ms) => (ms / 60000).toStringAsFixed(1);
String dateText(DateTime d) =>
    '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';
String clockText(int ms) {
  final seconds = (ms / 1000).ceil();
  return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

const taskStatuses = {'todo': '待办', 'doing': '进行中', 'done': '已完成'};
const reasons = {
  'completed': '完整完成',
  'early': '提前结束',
  'interrupted': '意外中断',
  'sleep': '电脑睡眠',
  'exit': '退出应用'
};

class FocusApp extends StatefulWidget {
  final AppController controller;
  const FocusApp(this.controller, {super.key});
  @override
  State<FocusApp> createState() => _FocusAppState();
}

class _FocusAppState extends State<FocusApp>
    with WindowListener, TrayListener, WidgetsBindingObserver {
  AppController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _prepareTray();
    }
  }

  Future<void> _prepareTray() async {
    await trayManager.setIcon(p.join(p.dirname(Platform.resolvedExecutable),
        'data', 'flutter_assets', 'assets', 'tray.ico'));
    await trayManager.setToolTip('专注花园');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: '打开专注花园'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '保存并退出')
    ]));
    await windowManager.setPreventClose(true);
  }

  @override
  void onWindowMinimize() {
    windowManager.hide();
  }

  @override
  void onWindowClose() {
    windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem item) async {
    if (item.key == 'show') {
      await windowManager.show();
      await windowManager.focus();
    }
    if (item.key == 'quit') {
      await c.shutdown();
      await trayManager.destroy();
      await windowManager.destroy();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && c.android) {
      c.perform(() async {
        await c.pollAndroid();
        c.permissions =
            asJson(await AppController.native.invokeMethod('permissions'));
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: c,
      builder: (_, child) {
        ThemeData theme(Brightness brightness) => ThemeData(
            useMaterial3: true,
            brightness: brightness,
            colorSchemeSeed: const Color(0xff476e58),
            scaffoldBackgroundColor: brightness == Brightness.light
                ? const Color(0xfff6f7f2)
                : const Color(0xff141a17),
            cardTheme:
                const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
            inputDecorationTheme: const InputDecorationTheme(
                border: OutlineInputBorder(), isDense: true));
        return MaterialApp(
            title: '专注花园',
            debugShowCheckedModeBanner: false,
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: theme(Brightness.light),
            darkTheme: theme(Brightness.dark),
            themeMode: c.settings.theme == 'light'
                ? ThemeMode.light
                : c.settings.theme == 'dark'
                    ? ThemeMode.dark
                    : ThemeMode.system,
            home: Home(c));
      });
}

class Home extends StatefulWidget {
  final AppController c;
  const Home(this.c, {super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int page = 0;
  bool taskDoneExpanded = false, focusDoneExpanded = false;
  AppController get c => widget.c;
  static const titles = ['专注', '任务', '音乐库', '历史记录', '统计报告'];
  static const icons = [
    Icons.timelapse_rounded,
    Icons.checklist_rounded,
    Icons.library_music_outlined,
    Icons.history_rounded,
    Icons.insights_rounded
  ];
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 850;
    final pinned = c.focusPinned;
    final body = switch (pinned ? 0 : page) {
      0 => focusPage(),
      1 => taskPage(),
      2 => musicPage(),
      3 => HistoryPage(c),
      _ => ReportsPage(c)
    };
    return AppBackground(
        path: c.settings.backgroundPath,
        opacity: c.settings.backgroundOpacity,
        cardTransparency: c.settings.cardTransparency,
        child: Scaffold(
            backgroundColor:
                c.settings.backgroundPath == null ? null : Colors.transparent,
            appBar: AppBar(
                title: Text(wide ? '专注花园  /  ${titles[page]}' : titles[page]),
                actions: [
                  if (Platform.isWindows && (page == 0 || pinned))
                    IconButton(
                        key: const ValueKey('focus-pin'),
                        tooltip: pinned ? '取消专注置顶' : '专注置顶',
                        isSelected: pinned,
                        icon: const Icon(Icons.push_pin_outlined),
                        selectedIcon: const Icon(Icons.push_pin),
                        onPressed: () =>
                            c.perform(() => c.setFocusPinned(!c.focusPinned))),
                  if (!pinned) ...[
                    IconButton(
                        tooltip: '备份与合并',
                        onPressed: backupDialog,
                        icon: const Icon(Icons.import_export)),
                    IconButton(
                        tooltip: '设置',
                        onPressed: settingsDialog,
                        icon: const Icon(Icons.tune)),
                  ],
                  const SizedBox(width: 12)
                ]),
            bottomNavigationBar: wide || pinned
                ? null
                : NavigationBar(
                    selectedIndex: page,
                    onDestinationSelected: (v) => setState(() => page = v),
                    destinations: List.generate(
                        5,
                        (i) => NavigationDestination(
                            icon: Icon(icons[i]), label: titles[i]))),
            body: Row(children: [
              if (wide && !pinned)
                NavigationRail(
                    selectedIndex: page,
                    labelType: NavigationRailLabelType.all,
                    onDestinationSelected: (v) => setState(() => page = v),
                    destinations: List.generate(
                        5,
                        (i) => NavigationRailDestination(
                            icon: Icon(icons[i]), label: Text(titles[i])))),
              Expanded(
                  child: Column(children: [
                if (c.message.isNotEmpty)
                  MaterialBanner(content: Text(c.message), actions: [
                    TextButton(
                        onPressed: () => setState(() => c.message = ''),
                        child: const Text('知道了'))
                  ]),
                if (c.recoveryMessage.isNotEmpty)
                  MaterialBanner(content: Text(c.recoveryMessage), actions: [
                    TextButton(
                        onPressed: () => setState(() => c.recoveryMessage = ''),
                        child: const Text('知道了'))
                  ]),
                Expanded(child: body),
              ])),
            ])));
  }

  Widget section(String title, Widget child, {String? subtitle}) => Card(
      child: Padding(
          padding: const EdgeInsets.all(22),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (subtitle != null)
              Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(subtitle,
                      style: Theme.of(context).textTheme.bodySmall)),
            const SizedBox(height: 18),
            child
          ])));
  Widget focusPage() {
    final now = DateTime.now().toUtc();
    final today = beijing(now);
    final day = dayKey(today);
    final week = buildReport(c.sessions, ReportPeriod(PeriodKind.week, today));
    final todayMs = week.daily[day] ?? 0;
    final status = c.isRest
        ? '给自己一点休息时间'
        : c.phase == Phase.paused
            ? '计时已暂停'
            : c.phase == Phase.focus
                ? '把注意力留给眼前这一件事'
                : '从一段安静的专注开始';
    return taskListView(focus: true, before: [
      Text(status, style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 8),
      const Text('离线记录 · 音乐相伴 · 每一点投入都算数'),
      const SizedBox(height: 24),
      Card(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(children: [
                SizedBox(
                    width: 420,
                    child: c.active
                        ? InputDecorator(
                            decoration:
                                const InputDecoration(labelText: '本次任务'),
                            child: Text(c.currentTaskName,
                                overflow: TextOverflow.ellipsis))
                        : DropdownButtonFormField<String?>(
                            key: ValueKey('focus-task-${c.selectedTask}'),
                            initialValue: c.selectedTask,
                            decoration:
                                const InputDecoration(labelText: '本次任务'),
                            items: [
                              const DropdownMenuItem(
                                  value: null, child: Text('自由专注')),
                              ...c.tasks
                                  .where((t) =>
                                      t.status != 'done' ||
                                      t.id == c.selectedTask)
                                  .map((t) => DropdownMenuItem(
                                      value: t.id,
                                      child: Text(t.name,
                                          overflow: TextOverflow.ellipsis)))
                            ],
                            onChanged: c.active
                                ? null
                                : (v) => setState(() => c.selectedTask = v))),
                const SizedBox(height: 30),
                SizedBox(
                    width: 260,
                    height: 260,
                    child: Stack(alignment: Alignment.center, children: [
                      SizedBox.expand(
                          child: CircularProgressIndicator(
                              strokeWidth: 8,
                              value: (1 -
                                      c.remainingMs / math.max(1, c.durationMs))
                                  .clamp(0, 1),
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              color: c.isRest
                                  ? Colors.teal
                                  : Theme.of(context).colorScheme.primary)),
                      Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(c.isRest ? '休息' : '专注',
                            style: Theme.of(context).textTheme.labelLarge),
                        Text(clockText(c.remainingMs),
                            style: const TextStyle(
                                fontSize: 58,
                                fontWeight: FontWeight.w300,
                                fontFeatures: [FontFeature.tabularFigures()])),
                        Text(c.phase == Phase.paused
                            ? '已暂停'
                            : c.phase == Phase.focus || c.isRest
                                ? '正在计时'
                                : '准备就绪')
                      ]),
                    ])),
                const SizedBox(height: 28),
                Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    alignment: WrapAlignment.center,
                    children: [
                      if (!c.active)
                        FilledButton.icon(
                            onPressed: () => c.perform(c.startFocus),
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('开始专注')),
                      if (c.active)
                        FilledButton.icon(
                            onPressed: () => c.perform(c.pauseResume),
                            icon: Icon(c.phase == Phase.paused
                                ? Icons.play_arrow
                                : Icons.pause),
                            label: Text(
                                c.phase == Phase.paused ? '继续计时' : '暂停计时')),
                      if (c.active)
                        OutlinedButton(
                            onPressed: () => c.perform(() => c.end()),
                            child: const Text('提前结束')),
                      if (!c.active)
                        OutlinedButton(
                            onPressed: () => c.perform(c.startRest),
                            child: Text(c.completedCycle > 0 &&
                                    c.completedCycle % 4 == 0
                                ? '开始长休息'
                                : '开始短休息')),
                    ]),
                const SizedBox(height: 18),
                Text('已完成 ${c.completedCycle} 个番茄 · 专注后自动休息，休息后手动专注'),
                const SizedBox(height: 20),
                musicControls(),
              ]))),
      const SizedBox(height: 20),
      Wrap(spacing: 16, runSpacing: 16, children: [
        metric('今日专注', '${minutes(todayMs)} 分钟'),
        metric('本周投入', '${minutes(week.milliseconds)} 分钟'),
        metric('本周完成', '${week.completed} 个番茄')
      ]),
      const SizedBox(height: 24),
      Row(children: [
        Expanded(
            child: Text('专注任务', style: Theme.of(context).textTheme.titleLarge)),
        TextButton.icon(
            onPressed: () => editTask(),
            icon: const Icon(Icons.add),
            label: const Text('添加任务')),
      ]),
      if (c.tasks.isEmpty) const Text('添加任务后，可点击左侧圆环标记完成。'),
    ], after: [
      if (c.android && c.permissions['liveSupported'] == true)
        Padding(
            padding: const EdgeInsets.only(top: 20),
            child: section(
                '实时通知 / 灵动胶囊',
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c.androidState['livePromoted'] == true
                      ? '系统已提升本次专注通知。'
                      : c.permissions['liveEnabled'] == true
                          ? '实时通知已允许；胶囊展示由系统决定。'
                          : '尚未允许实时通知，请先开启通知权限及实时通知。'),
                  const Text(
                      'ColorOS 16 / MagicOS 10 可使用 Android 16 实时通知。点击计时通知查看左侧已专注、右侧剩余时间的卡片。'),
                  TextButton(
                      onPressed: () => c.perform(() async {
                            await AppController.native
                                .invokeMethod('requestLiveUpdates');
                          }),
                      child: const Text('实时通知设置')),
                ]))),
      if (c.android &&
          (c.permissions['notifications'] != true ||
              c.permissions['exact'] != true))
        Padding(
            padding: const EdgeInsets.only(top: 20),
            child: section(
                '提醒权限',
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('通知或准确提醒权限尚未开启，到点提醒可能不显示或延迟。计时记录仍会保存。'),
                  TextButton(
                      onPressed: () => c.perform(() async {
                            await AppController.native
                                .invokeMethod('requestPermissions');
                          }),
                      child: const Text('开启提醒权限'))
                ]))),
      if (Platform.isWindows)
        const Padding(
            padding: EdgeInsets.only(top: 20),
            child: Text('关闭窗口或最小化后仍在托盘运行；右键托盘图标可保存并退出。')),
    ]);
  }

  Widget metric(String label, String value) => SizedBox(
      width: MediaQuery.sizeOf(context).width < 650
          ? (MediaQuery.sizeOf(context).width - 64) / 2
          : 205,
      child: Card(
          child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label),
                    const SizedBox(height: 8),
                    Text(value, style: Theme.of(context).textTheme.titleLarge)
                  ]))));
  Widget musicControls() => Column(children: [
        DropdownButtonFormField<String>(
            key: ValueKey('playing-playlist-${c.currentPlaylist.id}'),
            initialValue: c.currentPlaylist.id,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '播放歌单'),
            items: c.playlists
                .map((p) => DropdownMenuItem(
                    value: p.id,
                    child: Text(p.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis)))
                .toList(),
            onChanged: (id) {
              if (id != null) c.perform(() => c.selectPlaylist(id));
            }),
        const SizedBox(height: 12),
        Text(
            c.tracks.isEmpty
                ? '当前歌单为空，可前往音乐库添加歌曲'
                : c.tracks[c.trackIndex.clamp(0, c.tracks.length - 1)]['name']
                    as String,
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.center,
            children: [
              IconButton(
                  tooltip: '上一首',
                  onPressed: c.tracks.isEmpty
                      ? null
                      : () => c.perform(() => c.music('previous')),
                  icon: const Icon(Icons.skip_previous)),
              IconButton(
                  tooltip: c.playing ? '暂停音乐' : '播放音乐',
                  onPressed: c.tracks.isEmpty
                      ? null
                      : () => c.perform(() => c.music('toggle')),
                  icon: Icon(c.playing
                      ? Icons.pause_circle_outline
                      : Icons.play_circle_outline)),
              IconButton(
                  tooltip: '下一首',
                  onPressed: c.tracks.isEmpty
                      ? null
                      : () => c.perform(() => c.music('next')),
                  icon: const Icon(Icons.skip_next)),
              IconButton(
                  tooltip: '随机播放',
                  onPressed: () => c.perform(() => c.music('shuffle')),
                  color:
                      c.shuffle ? Theme.of(context).colorScheme.primary : null,
                  icon: const Icon(Icons.shuffle)),
              IconButton(
                  tooltip:
                      '循环：${{'all': '列表', 'one': '单曲', 'off': '关闭'}[c.repeat]}',
                  onPressed: () => c.perform(() => c.music('repeat')),
                  icon:
                      Icon(c.repeat == 'one' ? Icons.repeat_one : Icons.repeat),
                  color: c.repeat != 'off'
                      ? Theme.of(context).colorScheme.primary
                      : null),
              IconButton(
                  tooltip: c.muted ? '取消静音' : '保持静音',
                  onPressed: () => c.perform(() => c.music('mute')),
                  icon: Icon(c.muted ? Icons.volume_off : Icons.volume_up)),
              SizedBox(
                  width: 125,
                  child: Slider(
                      value: c.volume,
                      onChanged: (v) => c.perform(() => c.music('volume', v)))),
            ]),
      ]);
  Widget taskPage() => taskListView(focus: false, before: [
        Row(children: [
          Expanded(
              child: Text('把大目标，变成眼前的小任务',
                  style: Theme.of(context).textTheme.titleLarge)),
          FilledButton.icon(
              onPressed: () => editTask(),
              icon: const Icon(Icons.add),
              label: const Text('新建'))
        ]),
        const SizedBox(height: 20),
        if (c.tasks.isEmpty)
          const Padding(
              padding: EdgeInsets.all(40),
              child: Text('还没有任务。添加一个任务，记录预计番茄数与实际投入。')),
      ]);
  Widget taskListView(
      {required bool focus,
      required List<Widget> before,
      List<Widget> after = const []}) {
    final active = c.tasks.where((t) => t.status != 'done').toList();
    return CustomScrollView(slivers: [
      SliverPadding(
          padding: const EdgeInsets.all(24),
          sliver: SliverMainAxisGroup(slivers: [
            SliverList.list(children: before),
            SliverReorderableList(
                key: ValueKey(focus ? 'focus-task-list' : 'main-task-list'),
                itemCount: active.length,
                onReorderItem: (oldIndex, newIndex) => c.perform(
                    () => c.reorderTask(active[oldIndex].id, newIndex)),
                itemBuilder: (_, index) =>
                    taskCard(active[index], dragIndex: index)),
            SliverList.list(children: [...taskGroups(focus: focus), ...after]),
          ]))
    ]);
  }

  List<Widget> taskGroups({required bool focus}) {
    final completed = c.tasks.where((t) => t.status == 'done').toList()
      ..sort((a, b) {
        final time = b.completionTime.compareTo(a.completionTime);
        return time != 0 ? time : a.id.compareTo(b.id);
      });
    final expanded = focus ? focusDoneExpanded : taskDoneExpanded;
    return [
      if (completed.isNotEmpty) ...[
        const Divider(),
        Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: ValueKey(focus ? 'completed-focus' : 'completed-tasks'),
              style: TextButton.styleFrom(
                  backgroundColor:
                      Theme.of(context).colorScheme.surfaceContainerHigh),
              onPressed: () => setState(() {
                if (focus) {
                  focusDoneExpanded = !focusDoneExpanded;
                } else {
                  taskDoneExpanded = !taskDoneExpanded;
                }
              }),
              icon: Icon(expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 18),
              label: Text('已完成 ${completed.length}'),
            )),
        const SizedBox(height: 10),
        if (expanded) ...completed.map(taskCard),
      ],
    ];
  }

  Widget taskCard(TaskItem t, {int? dragIndex}) {
    final records =
        c.sessions.where((s) => s.taskId == t.id && s.includedInStatistics);
    final menu = PopupMenuButton<String>(
        key: ValueKey('task-menu-${t.id}'),
        tooltip: '任务选项',
        onSelected: (v) {
          if (v == 'delete') {
            deleteTask(t);
            return;
          }
          c.perform(() => c.saveTask(TaskItem.fromJson({
                ...t.toJson(),
                'status': v,
                'modified': DateTime.now().toUtc().toIso8601String()
              })));
        },
        itemBuilder: (_) => [
              ...taskStatuses.entries.where((e) => e.key != 'done').map(
                  (e) => PopupMenuItem(value: e.key, child: Text(e.value))),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'delete', child: Text('删除任务')),
            ]);
    return Padding(
        key: ValueKey('task-card-${t.id}'),
        padding: const EdgeInsets.only(bottom: 12),
        child: Card(
            child: ListTile(
                leading: IconButton(
                    key: ValueKey('complete-task-${t.id}'),
                    tooltip: t.status == 'done' ? '恢复为待办' : '完成任务',
                    onPressed: () =>
                        c.perform(() => c.toggleTaskCompleted(t.id)),
                    icon: Icon(t.status == 'done'
                        ? Icons.check_circle_outline
                        : Icons.radio_button_unchecked)),
                title: Text(t.name,
                    style: TextStyle(
                        decoration: t.status == 'done'
                            ? TextDecoration.lineThrough
                            : null)),
                subtitle: Text(
                    '${t.category.isEmpty ? '未分类' : t.category} · ${taskStatuses[t.status]}\n'
                    '完成 ${records.where((s) => s.completed).length} / ${t.estimate} 个番茄 · ${minutes(records.fold(0, (n, s) => n + s.milliseconds))} 分钟${t.due == null ? '' : '\n截止 ${dateText(t.due!)}'}${t.subtasks.isEmpty ? '' : '\n子任务 ${t.subtasks.where((s) => s.completed).length}/${t.subtasks.length} 完成'}${t.notes.isEmpty ? '' : '\n备注：${t.notes.replaceAll('\n', ' ')}'}',
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis),
                isThreeLine: true,
                onTap: () => editTask(t),
                trailing: dragIndex == null
                    ? menu
                    : MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: ReorderableDragStartListener(
                            key: ValueKey('task-drag-${t.id}'),
                            index: dragIndex,
                            child: menu)))));
  }

  Future<void> deleteTask(TaskItem task) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('删除任务？'),
              content: Text('将删除“${task.name}”及其子任务和备注，已保存的专注历史会保留。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('删除')),
              ],
            ));
    if (confirmed == true) await c.perform(() => c.deleteTask(task.id));
  }

  Future<void> editTask([TaskItem? task]) async {
    final saved = await showDialog<TaskItem>(
        context: context, builder: (_) => TaskEditor(task: task));
    if (saved != null) {
      await c.perform(() async {
        await c.saveTask(saved);
      });
    }
  }

  Widget musicPage() => MusicLibraryPage(c, playerBuilder: musicControls);

  Future<void> settingsDialog() async {
    final form = GlobalKey<FormState>();
    final focus = TextEditingController(text: '${c.settings.focus}'),
        short = TextEditingController(text: '${c.settings.shortBreak}'),
        long = TextEditingController(text: '${c.settings.longBreak}');
    final goals = {
      for (final kind in PeriodKind.values)
        kind.name: TextEditingController(
            text: c.settings.goals[kind.name]?.toString() ?? '')
    };
    String theme = c.settings.theme;
    String? background = c.settings.backgroundPath;
    double backgroundOpacity = c.settings.backgroundOpacity;
    double cardTransparency = c.settings.cardTransparency;
    HotkeyBinding musicHotkey = c.settings.musicHotkey,
        timerHotkey = c.settings.timerHotkey;
    final stagedBackgrounds = <String>{};
    bool importingBackground = false;
    bool dialogClosed = false;
    String? backgroundError;
    String? saveError;
    bool savingSettings = false;
    bool launchAtLogin = c.startupEnabled;
    final route = DialogRoute<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => PopScope(
                canPop: !savingSettings,
                child: AlertDialog(
                    title: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('专注设置'),
                          if (saveError != null)
                            Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(saveError!,
                                    key: const ValueKey('settings-error'),
                                    style: TextStyle(
                                        fontSize: 14,
                                        color:
                                            Theme.of(ctx).colorScheme.error))),
                        ]),
                    content: SizedBox(
                        width: 430,
                        child: SingleChildScrollView(
                            child: Form(
                                key: form,
                                child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      for (final pair in [
                                        (focus, '专注分钟'),
                                        (short, '短休息分钟'),
                                        (long, '长休息分钟')
                                      ])
                                        Padding(
                                            padding: const EdgeInsets.only(
                                                bottom: 14),
                                            child: TextFormField(
                                                controller: pair.$1,
                                                keyboardType:
                                                    TextInputType.number,
                                                decoration: InputDecoration(
                                                    labelText: pair.$2),
                                                validator: (v) => (int.tryParse(
                                                                    v ?? '') ??
                                                                0) <
                                                            1 ||
                                                        (int.tryParse(
                                                                    v ?? '') ??
                                                                0) >
                                                            180
                                                    ? '填写 1–180'
                                                    : null)),
                                      DropdownButtonFormField<String>(
                                          initialValue: theme,
                                          decoration: const InputDecoration(
                                              labelText: '主题'),
                                          items: const [
                                            DropdownMenuItem(
                                                value: 'system',
                                                child: Text('跟随系统')),
                                            DropdownMenuItem(
                                                value: 'light',
                                                child: Text('浅色')),
                                            DropdownMenuItem(
                                                value: 'dark',
                                                child: Text('深色'))
                                          ],
                                          onChanged: (v) => theme = v!),
                                      const SizedBox(height: 16),
                                      const Align(
                                          alignment: Alignment.centerLeft,
                                          child: Text('自定义背景')),
                                      if (background != null)
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 10),
                                          child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                              child: SizedBox(
                                                  height: 120,
                                                  width: double.infinity,
                                                  child: Image.file(
                                                      File(background!),
                                                      fit: BoxFit.cover,
                                                      cacheWidth: 600,
                                                      errorBuilder: (_, error,
                                                              stack) =>
                                                          const Center(
                                                              child: Text(
                                                                  '图片不可用，请重新选择'))))),
                                        ),
                                      Wrap(spacing: 8, children: [
                                        OutlinedButton.icon(
                                            key: const ValueKey(
                                                'choose-background'),
                                            onPressed: importingBackground
                                                ? null
                                                : () async {
                                                    update(() {
                                                      importingBackground =
                                                          true;
                                                      backgroundError = null;
                                                    });
                                                    try {
                                                      final files = await FilePicker
                                                          .platform
                                                          .pickFiles(
                                                              type: FileType
                                                                  .custom,
                                                              allowedExtensions: [
                                                            'jpg',
                                                            'jpeg',
                                                            'png',
                                                            'webp'
                                                          ]);
                                                      final source = files
                                                          ?.files.single.path;
                                                      if (source != null) {
                                                        final path = await c
                                                            .importBackground(
                                                                source);
                                                        if (dialogClosed ||
                                                            !ctx.mounted) {
                                                          await c
                                                              .discardUnusedBackground(
                                                                  path);
                                                          return;
                                                        }
                                                        stagedBackgrounds
                                                            .add(path);
                                                        if (ctx.mounted) {
                                                          update(() =>
                                                              background =
                                                                  path);
                                                        }
                                                      }
                                                    } catch (_) {
                                                      if (ctx.mounted) {
                                                        update(() =>
                                                            backgroundError =
                                                                '图片导入失败，请选择 20 MB 以内的静态 JPG、PNG 或 WebP 图片。');
                                                      }
                                                    } finally {
                                                      if (ctx.mounted) {
                                                        update(() =>
                                                            importingBackground =
                                                                false);
                                                      }
                                                    }
                                                  },
                                            icon: const Icon(Icons
                                                .add_photo_alternate_outlined),
                                            label: Text(importingBackground
                                                ? '正在处理图片…'
                                                : '选择背景图片')),
                                        if (background != null)
                                          TextButton(
                                              key: const ValueKey(
                                                  'remove-background'),
                                              onPressed: importingBackground
                                                  ? null
                                                  : () => update(
                                                      () => background = null),
                                              child: const Text('移除背景')),
                                      ]),
                                      if (backgroundError != null)
                                        Text(backgroundError!,
                                            style: TextStyle(
                                                color: Theme.of(ctx)
                                                    .colorScheme
                                                    .error)),
                                      if (background != null) ...[
                                        Text(
                                            '图片可见度 ${(backgroundOpacity * 100).round()}%'),
                                        Slider(
                                            key: const ValueKey(
                                                'background-opacity'),
                                            value: backgroundOpacity,
                                            min: .05,
                                            max: 1,
                                            onChanged: (v) => update(
                                                () => backgroundOpacity = v)),
                                        Text(
                                            '卡片透明度 ${(cardTransparency * 100).round()}%'),
                                        Slider(
                                            key: const ValueKey(
                                                'card-transparency'),
                                            value: cardTransparency,
                                            min: 0,
                                            max: 1,
                                            divisions: 100,
                                            onChanged: (v) => update(
                                                () => cardTransparency = v)),
                                        const Text(
                                            '0% 不透明，100% 完全透明；文字与操作按钮保持清晰。'),
                                        SizedBox(
                                            height: 100,
                                            width: double.infinity,
                                            child: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                child: AppBackground(
                                                    path: background,
                                                    opacity: backgroundOpacity,
                                                    cardTransparency:
                                                        cardTransparency,
                                                    child: const Padding(
                                                        padding:
                                                            EdgeInsets.all(12),
                                                        child: Card(
                                                            key: ValueKey(
                                                                'background-card-preview'),
                                                            child: Center(
                                                                child: Text(
                                                                    '卡片透明效果预览'))))))),
                                      ],
                                      const Text('图片保存在本机，不随任务备份传输；点击保存后生效。'),
                                      if (Platform.isWindows) ...[
                                        const SizedBox(height: 20),
                                        const Divider(),
                                        const Text('全局快捷键（窗口最小化或在托盘时也有效）'),
                                        HotkeySetting(
                                            key: const ValueKey('music-hotkey'),
                                            title: '音乐播放 / 暂停',
                                            binding: musicHotkey,
                                            controller: c,
                                            onChanged: (v) => update(() {
                                                  musicHotkey = v;
                                                  saveError = null;
                                                })),
                                        HotkeySetting(
                                            key: const ValueKey('timer-hotkey'),
                                            title: '当前计时暂停 / 继续',
                                            binding: timerHotkey,
                                            controller: c,
                                            onChanged: (v) => update(() {
                                                  timerHotkey = v;
                                                  saveError = null;
                                                })),
                                        if (c.hotkeyStatus['music'] == false ||
                                            c.hotkeyStatus['timer'] == false)
                                          const Text('部分快捷键被其他程序占用，请修改后保存。'),
                                        TextButton(
                                            key:
                                                const ValueKey('reset-hotkeys'),
                                            onPressed: () => update(() {
                                                  musicHotkey = HotkeyBinding
                                                      .musicDefault;
                                                  timerHotkey = HotkeyBinding
                                                      .timerDefault;
                                                  saveError = null;
                                                }),
                                            child: const Text('恢复默认快捷键')),
                                        const Text('修改后点击保存生效；两组按键不能相同。'),
                                        const Text('计时快捷键不会从待机状态自动开始新番茄钟。'),
                                        SwitchListTile.adaptive(
                                            key: const ValueKey(
                                                'launch-at-login'),
                                            contentPadding: EdgeInsets.zero,
                                            title: const Text('开机自启动'),
                                            subtitle: const Text(
                                                '保存后生效。登录 Windows 后进入托盘，不自动计时或播放。'),
                                            value: launchAtLogin,
                                            onChanged:
                                                c.desktopIntegrationAvailable
                                                    ? (v) => update(
                                                        () => launchAtLogin = v)
                                                    : null),
                                        if (launchAtLogin &&
                                            !c.startupCurrentPath)
                                          const Text(
                                              '保存时会使用当前程序位置，请保留解压后的完整文件夹。'),
                                        TextButton.icon(
                                            onPressed: () async {
                                              await c.perform(
                                                  c.createStartMenuShortcut);
                                              if (ctx.mounted) update(() {});
                                            },
                                            icon: const Icon(Icons.apps),
                                            label: const Text('添加 / 修复开始菜单入口')),
                                        const Text(
                                            '按 Win 键搜索 FocusGarden 或专注花园即可打开。移动程序后可在这里修复入口。'),
                                      ],
                                      const SizedBox(height: 20),
                                      const Text('可选目标：填写每个周期的专注分钟数；留空则不设目标。'),
                                      for (final entry in goals.entries)
                                        Padding(
                                            padding:
                                                const EdgeInsets.only(top: 14),
                                            child: TextFormField(
                                                controller: entry.value,
                                                keyboardType:
                                                    TextInputType.number,
                                                decoration: InputDecoration(
                                                    labelText: '${{
                                                  'week': '每周',
                                                  'month': '每月',
                                                  'year': '每年'
                                                }[entry.key]}目标（分钟）'),
                                                validator: (v) => v!.isEmpty ||
                                                        ((int.tryParse(v) ??
                                                                    0) >
                                                                0 &&
                                                            (int.tryParse(v) ??
                                                                    0) <=
                                                                525600)
                                                    ? null
                                                    : '填写正整数，或留空')),
                                      const SizedBox(height: 14),
                                      const Text(
                                          '统计时区固定为北京时间（UTC+8），每周从周一开始。修改时长从下一次计时生效。'),
                                    ])))),
                    actions: [
                      TextButton(
                          onPressed: savingSettings
                              ? null
                              : () => Navigator.pop(ctx, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: importingBackground || savingSettings
                              ? null
                              : () async {
                                  if (!form.currentState!.validate()) return;
                                  if (musicHotkey.sameAs(timerHotkey)) {
                                    update(() => saveError = '音乐和计时的快捷键不能相同。');
                                    return;
                                  }
                                  update(() {
                                    savingSettings = true;
                                    saveError = null;
                                  });
                                  await c.perform(() async {
                                    try {
                                      await c.saveSettings(Settings(
                                          focus: int.parse(focus.text),
                                          shortBreak: int.parse(short.text),
                                          longBreak: int.parse(long.text),
                                          theme: theme,
                                          backgroundPath: background,
                                          backgroundOpacity: backgroundOpacity,
                                          cardTransparency: cardTransparency,
                                          musicHotkey: musicHotkey,
                                          timerHotkey: timerHotkey,
                                          goals: {
                                            for (final e in goals.entries)
                                              if (e.value.text.isNotEmpty)
                                                e.key: int.parse(e.value.text)
                                          }));
                                      if (Platform.isWindows &&
                                          c.desktopIntegrationAvailable &&
                                          (launchAtLogin != c.startupEnabled ||
                                              (launchAtLogin &&
                                                  !c.startupCurrentPath))) {
                                        await c.setLaunchAtLogin(launchAtLogin);
                                      }
                                      if (ctx.mounted) Navigator.pop(ctx, true);
                                    } catch (e) {
                                      if (ctx.mounted) {
                                        update(() => saveError = '保存失败：$e');
                                      }
                                    } finally {
                                      if (ctx.mounted) {
                                        update(() => savingSettings = false);
                                      }
                                    }
                                  });
                                },
                          child: Text(savingSettings ? '正在保存…' : '保存'))
                    ]))));
    await Navigator.of(context, rootNavigator: true).push(route);
    dialogClosed = true;
    for (final path in stagedBackgrounds) {
      await c.discardUnusedBackground(path);
    }
    // Popping completes push() before the closing animation removes the form.
    // Keep controllers alive until the route has actually left the overlay.
    await route.completed;
    for (final field in [focus, short, long, ...goals.values]) {
      field.dispose();
    }
  }

  Future<void> backupDialog() async {
    await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('备份与合并'),
                content: const Text(
                    '备份包含任务与专注记录，不包含音乐和设备设置。可用同一备份在电脑与手机间合并记录；请先备份，再卸载应用。'),
                actions: [
                  TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        importData();
                      },
                      child: const Text('导入并预览')),
                  FilledButton(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await c.perform(() async {
                          final bytes =
                              utf8.encode(exportBackup(c.tasks, c.sessions));
                          final file = await FilePicker.platform.saveFile(
                              dialogTitle: '导出备份',
                              fileName:
                                  'focus-garden-${dayKey(beijing(DateTime.now()))}.json',
                              type: FileType.custom,
                              allowedExtensions: ['json'],
                              bytes: bytes);
                          if (file != null) {
                            if (!c.android) {
                              await File(file).writeAsBytes(bytes, flush: true);
                            }
                            c.message = '备份已导出。';
                          }
                        });
                      },
                      child: const Text('导出备份'))
                ]));
  }

  Future<void> importData() async {
    BackupPreview? preview;
    await c.perform(() async {
      final picked = await FilePicker.platform
          .pickFiles(type: FileType.custom, allowedExtensions: ['json']);
      if (picked == null || picked.files.single.path == null) return;
      final file = File(picked.files.single.path!);
      if (await file.length() > 50 * 1024 * 1024) {
        throw const FormatException('备份超过 50 MB');
      }
      preview = previewBackup(await file.readAsString(), c.tasks, c.sessions);
    });
    if (preview == null || !mounted) return;
    final data = preview!;
    final importedTasks = <String>{}, excluded = <String>{};
    final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => AlertDialog(
                    title: const Text('导入预览'),
                    content: SizedBox(
                        width: 500,
                        child: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text(
                                  '备份内 ${data.tasks.length} 个任务\n新增 ${data.sessions.length} 条记录，跳过 ${data.duplicateRecords} 条重复记录。'),
                              if (data.conflicts.isNotEmpty)
                                const Padding(
                                    padding: EdgeInsets.only(top: 16),
                                    child: Text('任务存在差异：默认保留本机版本，勾选则采用导入版本。')),
                              ...data.conflicts.map((t) => CheckboxListTile(
                                  value: importedTasks.contains(t.id),
                                  title: Text(t.name),
                                  subtitle: Text(
                                      '采用导入版本：${t.category} · ${taskStatuses[t.status]}'),
                                  onChanged: (v) => update(() {
                                        v!
                                            ? importedTasks.add(t.id)
                                            : importedTasks.remove(t.id);
                                      }))),
                              if (data.overlapsExisting.isNotEmpty)
                                const Padding(
                                    padding: EdgeInsets.only(top: 16),
                                    child: Text(
                                        '以下新增记录与其他记录时间重叠。默认均保留并累计；如属于误记，勾选后排除该条统计。')),
                              ...data.sessions
                                  .where((s) =>
                                      data.overlapsExisting.contains(s.id))
                                  .map((s) => CheckboxListTile(
                                      value: excluded.contains(s.id),
                                      title: Text(s.taskName),
                                      subtitle: Text(
                                          '${dateText(beijing(s.started))} · ${minutes(s.milliseconds)} 分钟 · 排除统计'),
                                      onChanged: (v) => update(() {
                                            v!
                                                ? excluded.add(s.id)
                                                : excluded.remove(s.id);
                                          }))),
                            ]))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('确认合并'))
                    ])));
    if (confirm == true) {
      await c.perform(() async {
        await importBackup(c.store, data,
            useImportedTaskIds: importedTasks, excludeSessionIds: excluded);
        await c.refresh();
        c.message = '合并完成，报告已更新。';
      });
    }
  }
}

class HistoryPage extends StatefulWidget {
  final AppController c;
  const HistoryPage(this.c, {super.key});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  String query = '', filter = 'all';
  DateTimeRange? range;
  @override
  Widget build(BuildContext context) {
    final records = widget.c.sessions
        .where((s) =>
            '${s.taskName} ${s.category}'
                .toLowerCase()
                .contains(query.toLowerCase()) &&
            (filter == 'all' ||
                (filter == 'complete'
                    ? s.countsAsPomodoro
                    : filter == 'excluded'
                        ? s.excluded
                        : filter == 'invalid'
                            ? !s.isValidFocus
                            : s.isValidFocus && !s.completed)) &&
            (range == null ||
                (!beijing(s.started).isBefore(DateTime.utc(range!.start.year,
                        range!.start.month, range!.start.day)) &&
                    beijing(s.started).isBefore(DateTime.utc(range!.end.year,
                        range!.end.month, range!.end.day + 1)))))
        .toList();
    return ListView(padding: const EdgeInsets.all(24), children: [
      TextField(
          decoration: const InputDecoration(
              labelText: '搜索任务或科目', prefixIcon: Icon(Icons.search)),
          onChanged: (v) => setState(() => query = v)),
      const SizedBox(height: 12),
      Wrap(spacing: 10, runSpacing: 8, children: [
        for (final e in {
          'all': '全部',
          'complete': '完整完成',
          'partial': '未完成',
          'invalid': '无效自习',
          'excluded': '已排除'
        }.entries)
          ChoiceChip(
              label: Text(e.value),
              selected: filter == e.key,
              onSelected: (_) => setState(() => filter = e.key)),
        ActionChip(
            label: Text(range == null
                ? '选择日期'
                : '${dateText(range!.start)}–${dateText(range!.end)}'),
            onPressed: () async {
              final selected = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                  initialDateRange: range);
              if (selected != null) setState(() => range = selected);
            }),
        if (range != null)
          ActionChip(
              label: const Text('清除日期'),
              onPressed: () => setState(() => range = null))
      ]),
      const SizedBox(height: 20),
      Text(
          '${records.length} 条记录 · 有效专注 ${minutes(records.where((s) => s.includedInStatistics).fold(0, (n, s) => n + s.milliseconds))} 分钟'),
      const Text('单次实际专注不足 1 分钟为无效自习，仅保留历史，不计入统计与番茄数；暂停不计时。'),
      const SizedBox(height: 12),
      if (records.isEmpty)
        const Padding(
            padding: EdgeInsets.all(40),
            child: Text('这里还没有记录。开始一次专注，或导入另一台设备的备份。')),
      ...records.map((s) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Card(
              child: ListTile(
                  leading: Icon(!s.isValidFocus
                      ? Icons.timer_off_outlined
                      : s.excluded
                          ? Icons.visibility_off_outlined
                          : s.completed
                              ? Icons.check_circle_outline
                              : Icons.timelapse),
                  title: Text(s.taskName),
                  subtitle: Text(
                      '${dateText(beijing(s.started))} ${clockText((beijing(s.started).hour * 60 + beijing(s.started).minute) * 60000)}\n${s.category} · ${!s.isValidFocus ? '无效自习（不足 1 分钟）' : reasons[s.reason]}${s.excluded ? ' · 已排除统计' : ''}'),
                  trailing: Text('${minutes(s.milliseconds)} 分钟'),
                  isThreeLine: true,
                  onTap: () => showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                              title: Text(s.taskName),
                              content: SingleChildScrollView(
                                  child: SelectableText(
                                      '科目：${s.category}\n开始：${beijing(s.started).toIso8601String().replaceAll('Z', '')} 北京时间\n结束：${beijing(s.ended).toIso8601String().replaceAll('Z', '')} 北京时间\n计划：${s.plannedSeconds ~/ 60} 分钟\n实际：${minutes(s.milliseconds)} 分钟\n暂停：${s.pauses.length} 次\n结束原因：${reasons[s.reason]}\n设备：${s.device}\n记录编号：${s.id}\n\n专注区间：\n${s.spans.map((x) => '${beijing(x.start).toIso8601String().replaceAll('Z', '')} → ${beijing(x.end).toIso8601String().replaceAll('Z', '')}').join('\n')}\n\n暂停区间：\n${s.pauses.map((x) => '${beijing(x.start).toIso8601String().replaceAll('Z', '')} → ${beijing(x.end).toIso8601String().replaceAll('Z', '')}').join('\n')}')),
                              actions: [
                                if (s.isValidFocus)
                                  TextButton(
                                      onPressed: () async {
                                        Navigator.pop(ctx);
                                        await widget.c.perform(() async {
                                          await widget.c.store.session(
                                              s.withExcluded(!s.excluded),
                                              replace: true);
                                          await widget.c.refresh();
                                        });
                                      },
                                      child:
                                          Text(s.excluded ? '恢复计入统计' : '排除统计')),
                                FilledButton(
                                    onPressed: () => Navigator.pop(ctx),
                                    child: const Text('关闭'))
                              ])))))),
    ]);
  }
}

class ReportsPage extends StatefulWidget {
  final AppController c;
  const ReportsPage(this.c, {super.key});
  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  PeriodKind kind = PeriodKind.week;
  DateTime selected = beijing(DateTime.now());
  @override
  Widget build(BuildContext context) {
    final period = ReportPeriod(kind, selected),
        report = buildReport(widget.c.sessions, ReportPeriod(kind, selected));
    final previous = buildReport(widget.c.sessions, period.previous);
    final open = period.isOpen(DateTime.now());
    final goal = widget.c.settings.goals[kind.name];
    final chart = <String, int>{};
    for (var day = period.start;
        day.isBefore(period.end);
        day = day.add(const Duration(days: 1))) {
      final key =
          kind == PeriodKind.year ? '${day.month}月' : '${day.month}/${day.day}';
      chart.update(key, (v) => v + (report.daily[dayKey(day)] ?? 0),
          ifAbsent: () => report.daily[dayKey(day)] ?? 0);
    }
    Widget panel(String title, Widget child) => Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Card(
            child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 18),
                      child
                    ]))));
    Widget metric(String label, String value) => SizedBox(
        width: MediaQuery.sizeOf(context).width < 650
            ? (MediaQuery.sizeOf(context).width - 60) / 2
            : 175,
        child: Card(
            child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label),
                      const SizedBox(height: 8),
                      Text(value, style: Theme.of(context).textTheme.titleLarge)
                    ]))));
    Widget breakdown(Map<String, int> values) {
      final entries = values.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      if (entries.isEmpty) return const Text('暂无数据');
      return Column(
          children: entries
              .map((e) => Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(children: [
                    Row(children: [
                      Expanded(child: Text(e.key)),
                      Text('${minutes(e.value)} 分钟')
                    ]),
                    const SizedBox(height: 7),
                    LinearProgressIndicator(
                        value: report.milliseconds == 0
                            ? 0
                            : e.value / report.milliseconds,
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(3))
                  ])))
              .toList());
    }

    return ListView(padding: const EdgeInsets.all(24), children: [
      Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<PeriodKind>(segments: const [
            ButtonSegment(value: PeriodKind.week, label: Text('周报')),
            ButtonSegment(value: PeriodKind.month, label: Text('月报')),
            ButtonSegment(value: PeriodKind.year, label: Text('年报'))
          ], selected: {
            kind
          }, onSelectionChanged: (v) => setState(() => kind = v.first))),
      const SizedBox(height: 16),
      Row(children: [
        IconButton(
            tooltip: '上一周期',
            onPressed: () => setState(() => selected = period.previous.start),
            icon: const Icon(Icons.chevron_left)),
        Expanded(
            child: TextButton(
                onPressed: () async {
                  final date = await showDatePicker(
                      context: context,
                      initialDate:
                          DateTime(selected.year, selected.month, selected.day),
                      firstDate: DateTime(2000),
                      lastDate: DateTime.now());
                  if (date != null) setState(() => selected = date);
                },
                child: Text(
                    '${dateText(period.start)} – ${dateText(period.end.subtract(const Duration(days: 1)))}\n${open ? '进行中' : '完整周期'}'))),
        IconButton(
            tooltip: '下一周期',
            onPressed: period.next.start.isAfter(beijing(DateTime.now()))
                ? null
                : () => setState(() => selected = period.next.start),
            icon: const Icon(Icons.chevron_right)),
        TextButton(
            onPressed: () => setState(() => selected = beijing(DateTime.now())),
            child: const Text('本期'))
      ]),
      const SizedBox(height: 16),
      Wrap(spacing: 12, runSpacing: 12, children: [
        metric('累计专注', '${minutes(report.milliseconds)} 分钟'),
        metric('完整番茄', '${report.completed} 个'),
        metric('未完成', '${report.interrupted} 次'),
        metric(
            '平均单次',
            report.averageMinutes == null
                ? '暂无数据'
                : '${report.averageMinutes!.toStringAsFixed(1)} 分钟'),
        metric(
            '完成率',
            report.completionRate == null
                ? '暂无数据'
                : '${(report.completionRate! * 100).toStringAsFixed(1)}%'),
        metric('活跃天数', '${report.activeDays} 天'),
        metric('最长连续专注', '${report.longestStreak} 天'),
        metric(
            '目标完成度',
            goal == null
                ? '未设置目标'
                : '${(report.milliseconds / 60000 / goal * 100).toStringAsFixed(1)}%'),
        metric(
            '较上一完整周期',
            open
                ? '进行中'
                : previous.milliseconds == 0
                    ? '暂无基准'
                    : '${((report.milliseconds / previous.milliseconds - 1) * 100).toStringAsFixed(1)}%'),
      ]),
      const SizedBox(height: 20),
      panel(kind == PeriodKind.year ? '每月专注趋势（分钟）' : '每日专注趋势（分钟）',
          BarChart(chart)),
      if (kind == PeriodKind.month)
        panel('每周投入（以周一日期标识，仅累计本月部分）', BarChart(report.weekly)),
      if (kind == PeriodKind.month) panel('本月专注热力图', Heatmap(report)),
      if (kind == PeriodKind.year) panel('全年专注热力图', Heatmap(report)),
      panel('科目 / 项目分布', breakdown(report.category)),
      panel('任务投入', breakdown(report.tasks)),
      panel(
          '北京时间时段分布（分钟）',
          BarChart({for (var h = 0; h < 24; h++) '$h时': report.hourly[h]},
              compact: true)),
      const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text('统计仅包含单次实际专注满 1 分钟且未被排除的记录。跨周期按整次专注判断有效性，暂停与休息不计入。')),
      FocusTimeAnalysis(report),
      panel(
          '基于记录的观察',
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final advice in report.advice)
              Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(advice)),
            const Text(
                '计时反映投入时间，不直接衡量学习效果。跨日记录按时间区间分配时长；完成数归入结束日期；平均单次按本期有投入的记录计算，只累计本期部分。')
          ])),
    ]);
  }
}

class Heatmap extends StatelessWidget {
  final Report report;
  const Heatmap(this.report, {super.key});
  @override
  Widget build(BuildContext context) {
    final first = report.period.start;
    final gridStart = first.subtract(Duration(days: first.weekday - 1));
    final weeks = (report.period.end.difference(gridStart).inDays / 7).ceil();
    final maxMs = math.max(1, report.daily.values.fold<int>(0, math.max));
    final monthly = report.period.kind == PeriodKind.month;
    final cellSize = monthly ? 32.0 : 14.0;
    final colors = Theme.of(context).colorScheme;
    Color intensity(int value) => value == 0
        ? colors.surfaceContainerHighest
        : colors.primary.withValues(alpha: .25 + .75 * value / maxMs);
    final grid = SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Column(children: [
            for (final d in ['一', '二', '三', '四', '五', '六', '日'])
              SizedBox(
                  width: 20,
                  height: cellSize + 3,
                  child: Center(
                      child: Text(d, style: const TextStyle(fontSize: 10))))
          ]),
          for (var w = 0; w < weeks; w++)
            Column(children: [
              for (var d = 0; d < 7; d++)
                Builder(builder: (context) {
                  final date = gridStart.add(Duration(days: w * 7 + d));
                  final value = report.daily[dayKey(date)] ?? 0;
                  final within =
                      !date.isBefore(first) && date.isBefore(report.period.end);
                  final description = '${dayKey(date)}：${minutes(value)} 分钟';
                  final cell = Container(
                      key: within ? ValueKey('heatmap-${dayKey(date)}') : null,
                      width: cellSize,
                      height: cellSize,
                      alignment: Alignment.center,
                      margin: const EdgeInsets.all(1.5),
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(2),
                          color:
                              !within ? Colors.transparent : intensity(value)),
                      child: monthly && within
                          ? Text('${date.day}',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: value == maxMs
                                      ? colors.onPrimary
                                      : colors.onSurface))
                          : null);
                  if (!within) return cell;
                  return Semantics(
                      label: description,
                      child: Tooltip(
                          message: description,
                          triggerMode: TooltipTriggerMode.tap,
                          excludeFromSemantics: true,
                          child: ExcludeSemantics(child: cell)));
                })
            ]),
        ]));
    if (!monthly) return grid;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      grid,
      const SizedBox(height: 14),
      Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('少', style: TextStyle(fontSize: 11)),
            for (final fraction in [0.0, .25, .5, .75, 1.0])
              Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                      color: intensity((maxMs * fraction).round()),
                      borderRadius: BorderRadius.circular(2))),
            const Text('多', style: TextStyle(fontSize: 11)),
          ]),
      const SizedBox(height: 8),
      Text(
          report.milliseconds == 0
              ? '本月暂无有效专注记录。点击或悬停日期可查看时长。'
              : '颜色按本月每日投入相对深浅显示，空格为月外日期。点击或悬停日期查看分钟数。',
          style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}
