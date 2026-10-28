import 'models.dart';

class MusicPlaylist {
  final String id;
  String name;
  List<Json> tracks;
  MusicPlaylist({required this.id, required this.name, List<Json>? tracks})
      : tracks = tracks ?? [];
  Json toJson() => {'id': id, 'name': name, 'tracks': tracks};
  factory MusicPlaylist.fromJson(Json json) {
    final id = json['id'], name = json['name'];
    if (id is! String ||
        id.isEmpty ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 80 ||
        json['tracks'] is! List) {
      throw const FormatException('歌单数据无效');
    }
    final tracks = (json['tracks'] as List).map((value) {
      final t = asJson(value);
      if (['id', 'name', 'path']
          .any((key) => t[key] is! String || (t[key] as String).isEmpty)) {
        throw const FormatException('歌曲数据无效');
      }
      return t;
    }).toList();
    if (tracks.map((t) => t['id']).toSet().length != tracks.length) {
      throw const FormatException('歌单中存在重复歌曲编号');
    }
    return MusicPlaylist(id: id, name: name, tracks: tracks);
  }
}

class MusicLibrary {
  final List<MusicPlaylist> playlists;
  String selectedId;
  int index;
  bool shuffle;
  String repeat;
  MusicLibrary(
      {required this.playlists,
      required this.selectedId,
      this.index = 0,
      this.shuffle = false,
      this.repeat = 'all'});
  factory MusicLibrary.empty() => MusicLibrary(
      playlists: [MusicPlaylist(id: 'default', name: '默认歌单')],
      selectedId: 'default');
  factory MusicLibrary.legacy(List<Json> tracks) => MusicLibrary.fromJson({
        ...MusicLibrary.empty().toJson(),
        'playlists': [
          {'id': 'default', 'name': '默认歌单', 'tracks': tracks}
        ],
      });
  MusicPlaylist get current => playlists.firstWhere((p) => p.id == selectedId);
  Json toJson() => {
        'version': 1,
        'playlists': playlists.map((p) => p.toJson()).toList(),
        'selectedId': selectedId,
        'index': index,
        'shuffle': shuffle,
        'repeat': repeat
      };
  factory MusicLibrary.fromJson(Json json) {
    if (json['version'] != 1 || json['playlists'] is! List) {
      throw const FormatException('不支持的音乐库版本');
    }
    final playlists = (json['playlists'] as List)
        .map((p) => MusicPlaylist.fromJson(asJson(p)))
        .toList();
    if (playlists.isEmpty ||
        playlists.map((p) => p.id).toSet().length != playlists.length ||
        json['selectedId'] is! String ||
        !playlists.any((p) => p.id == json['selectedId'])) {
      throw const FormatException('音乐库歌单编号无效');
    }
    final result = MusicLibrary(
        playlists: playlists,
        selectedId: json['selectedId'],
        index: json['index'] is int ? json['index'] as int : 0,
        shuffle: json['shuffle'] == true,
        repeat: ['all', 'one', 'off'].contains(json['repeat'])
            ? json['repeat'] as String
            : 'all');
    result.index = result.current.tracks.isEmpty
        ? 0
        : result.index.clamp(0, result.current.tracks.length - 1);
    return result;
  }
  MusicLibrary copy() => MusicLibrary.fromJson({
        ...toJson(),
        'playlists': [
          for (final playlist in playlists)
            {
              ...playlist.toJson(),
              'tracks': [
                for (final track in playlist.tracks)
                  Map<String, dynamic>.from(track)
              ],
            }
        ],
      });
}
