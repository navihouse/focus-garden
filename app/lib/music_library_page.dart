import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'app_controller.dart';
import 'domain/models.dart';
import 'domain/music_library.dart';

class MusicLibraryPage extends StatefulWidget {
  final AppController controller;
  final Widget Function() playerBuilder;
  const MusicLibraryPage(this.controller,
      {super.key, required this.playerBuilder});
  @override
  State<MusicLibraryPage> createState() => _MusicLibraryPageState();
}

class _MusicLibraryPageState extends State<MusicLibraryPage> {
  AppController get c => widget.controller;
  Future<void> editName([MusicPlaylist? playlist]) async {
    final field = TextEditingController(text: playlist?.name);
    final form = GlobalKey<FormState>();
    final route = DialogRoute<String>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(playlist == null ? '新建歌单' : '重命名歌单'),
                content: SizedBox(
                    width: 360,
                    child: Form(
                        key: form,
                        child: TextFormField(
                            key: const ValueKey('playlist-name'),
                            controller: field,
                            autofocus: true,
                            maxLength: 80,
                            decoration:
                                const InputDecoration(labelText: '歌单名称'),
                            validator: (v) =>
                                c.playlistNameError(v, exceptId: playlist?.id),
                            onFieldSubmitted: (_) {
                              if (form.currentState!.validate()) {
                                Navigator.pop(ctx, field.text.trim());
                              }
                            }))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () {
                        if (form.currentState!.validate()) {
                          Navigator.pop(ctx, field.text.trim());
                        }
                      },
                      child: Text(playlist == null ? '创建并打开' : '保存'))
                ]));
    final name = await Navigator.of(context).push(route);
    if (name != null) {
      await c.perform(() async {
        if (playlist == null) {
          await c.createPlaylist(name);
        } else {
          await c.renamePlaylist(playlist.id, name);
        }
      });
    }
    await route.completed;
    field.dispose();
  }

  Future<void> delete(MusicPlaylist playlist) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('删除歌单？'),
                content: Text('删除“${playlist.name}”及其中的歌曲引用，原音频文件和其他歌单不受影响。'
                    '${playlist.id == c.currentPlaylist.id ? '当前歌单的音乐将停止。' : ''}'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('删除'))
                ]));
    if (confirmed == true) await c.perform(() => c.deletePlaylist(playlist.id));
  }

  Future<void> importFiles() async {
    final targetId = c.currentPlaylist.id;
    // File picking is outside the controller queue so Windows checkpoints keep running.
    try {
      final files = await FilePicker.platform.pickFiles(
          allowMultiple: true,
          type: FileType.custom,
          allowedExtensions: ['mp3', 'flac', 'wav', 'm4a', 'ogg', 'aac']);
      if (files == null || !mounted) return;
      await c.perform(() => c.importMusicFiles(targetId, [
            for (final f in files.files)
              if (f.path != null) {'name': f.name, 'path': f.path!}
          ]));
    } catch (_) {
      await c.perform(() async {
        c.message = '音乐导入未完成，请重新选择可访问的本地音频文件。';
      });
    }
  }

  Future<void> transfer(Json track, {required bool copy}) async {
    final from = c.currentPlaylist.id;
    final target = await showDialog<String>(
        context: context,
        builder: (ctx) =>
            SimpleDialog(title: Text(copy ? '复制到歌单' : '移动到歌单'), children: [
              for (final list in c.playlists.where((p) => p.id != from))
                SimpleDialogOption(
                    key: ValueKey('transfer-to-${list.id}'),
                    onPressed: () => Navigator.pop(ctx, list.id),
                    child: Row(children: [
                      const Icon(Icons.folder_outlined),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Text(list.name,
                              maxLines: 2, overflow: TextOverflow.ellipsis))
                    ])),
            ]));
    if (target != null) {
      await c.perform(() =>
          c.transferTrack(from, track['id'] as String, target, copy: copy));
    }
  }

  Widget playlistMenu(MusicPlaylist list) => PopupMenuButton<String>(
      key: ValueKey('playlist-menu-${list.id}'),
      tooltip: '歌单选项',
      onSelected: (v) => v == 'rename' ? editName(list) : delete(list),
      itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('重命名歌单')),
            PopupMenuItem(value: 'delete', child: Text('删除歌单')),
          ]);
  Widget folder(MusicPlaylist list, {bool compact = false}) {
    final selected = list.id == c.currentPlaylist.id;
    return Semantics(
        selected: selected,
        button: true,
        child: Card(
            key: ValueKey('playlist-${list.id}'),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.transparent,
                    width: 1.5)),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => c.perform(() => c.selectPlaylist(list.id)),
              child: compact
                  ? Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(
                                  selected
                                      ? Icons.folder
                                      : Icons.folder_outlined,
                                  color: Theme.of(context).colorScheme.primary),
                              const Spacer(),
                              playlistMenu(list)
                            ]),
                            Text(list.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall),
                            Text(
                                '${list.tracks.length} 首${selected ? ' · 当前歌单' : ''}',
                                maxLines: 1),
                          ]))
                  : ListTile(
                      leading:
                          Icon(selected ? Icons.folder : Icons.folder_outlined),
                      title: Text(list.name,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${list.tracks.length} 首'),
                      trailing: playlistMenu(list)),
            )));
  }

  Widget get folderHeader => Row(children: [
        Expanded(
            child: Text('我的歌单', style: Theme.of(context).textTheme.titleLarge)),
        IconButton(
            key: const ValueKey('new-playlist'),
            tooltip: '新建歌单',
            onPressed: editName,
            icon: const Icon(Icons.create_new_folder_outlined))
      ]);
  List<Widget> get contents => [
        Text(c.currentPlaylist.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                  key: const ValueKey('add-playlist-files'),
                  onPressed: importFiles,
                  icon: const Icon(Icons.add),
                  label: const Text('添加文件')),
              Text('${c.tracks.length} 首 · 仅播放当前歌单'),
            ]),
        const SizedBox(height: 10),
        Text(c.android
            ? '导入的音乐保存在本机；歌单和音乐不随任务备份传输。'
            : '引用本地文件，移动文件后需重新添加。歌单和音乐不随任务备份传输。'),
        const SizedBox(height: 18),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(20),
                child: widget.playerBuilder())),
        const SizedBox(height: 10),
        Text(c.android
            ? '开始专注后播放当前歌单；暂停、结束和休息时暂停音乐。'
            : '可直接试听当前歌单；暂停计时、结束和休息时暂停音乐。'),
        const Text('切换歌单会切换播放范围；正在播放时从新歌单第一首继续。空歌单会停止播放。'),
        const SizedBox(height: 16),
        if (c.tracks.isEmpty)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 36),
              child: Text('这个歌单还没有歌曲。点击“添加文件”，导入 MP3、FLAC、WAV、M4A、OGG 或 AAC。')),
        for (final (index, track) in c.tracks.indexed)
          ListTile(
              key: ValueKey('song-${c.currentPlaylist.id}-${track['id']}'),
              leading: Icon(index == c.trackIndex && c.playing
                  ? Icons.graphic_eq
                  : Icons.music_note_outlined),
              title: Text(track['name'] as String,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(track['path'] as String,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => c.perform(() => c.music('select', index)),
              trailing: PopupMenuButton<String>(
                  key: ValueKey('song-menu-${track['id']}'),
                  tooltip: '歌曲选项',
                  onSelected: (action) {
                    if (action == 'remove') {
                      c.perform(() => c.removeTrack(
                          c.currentPlaylist.id, track['id'] as String));
                    } else {
                      transfer(track, copy: action == 'copy');
                    }
                  },
                  itemBuilder: (_) => [
                        PopupMenuItem(
                            value: 'move',
                            enabled: c.playlists.length > 1,
                            child: const Text('移动到歌单')),
                        PopupMenuItem(
                            value: 'copy',
                            enabled: c.playlists.length > 1,
                            child: const Text('复制到歌单')),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                            value: 'remove', child: Text('从当前歌单移除')),
                      ])),
      ];
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: c,
      builder: (context, _) => LayoutBuilder(builder: (context, constraints) {
            if (constraints.maxWidth >= 900) {
              return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                        width: 260,
                        child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
                            child: Column(children: [
                              folderHeader,
                              const SizedBox(height: 12),
                              Expanded(
                                  child: ListView.separated(
                                      itemCount: c.playlists.length,
                                      separatorBuilder: (_, index) =>
                                          const SizedBox(height: 10),
                                      itemBuilder: (_, i) =>
                                          folder(c.playlists[i]))),
                            ]))),
                    const VerticalDivider(width: 1),
                    Expanded(
                        child: ListView(
                            padding: const EdgeInsets.all(24),
                            children: contents)),
                  ]);
            }
            return ListView(padding: const EdgeInsets.all(24), children: [
              folderHeader,
              const SizedBox(height: 10),
              SizedBox(
                  height: MediaQuery.textScalerOf(context).scale(140),
                  child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: c.playlists.length,
                      separatorBuilder: (_, index) => const SizedBox(width: 10),
                      itemBuilder: (_, i) => SizedBox(
                          width: 200,
                          child: folder(c.playlists[i], compact: true)))),
              const SizedBox(height: 22),
              ...contents,
            ]);
          }));
}
