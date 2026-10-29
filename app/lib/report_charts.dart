import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class BarChart extends StatefulWidget {
  final Map<String, int> values;
  final bool counts;
  final bool compact;
  final int? total;
  const BarChart(this.values,
      {super.key, this.counts = false, this.compact = false, this.total});
  @override
  State<BarChart> createState() => _BarChartState();
}

class _BarChartState extends State<BarChart> {
  final _scroll = ScrollController();
  @override
  void didUpdateWidget(BarChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new period starts at its first date instead of keeping the old offset.
    if (!listEquals(
            oldWidget.values.keys.toList(), widget.values.keys.toList()) &&
        _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String valueText(int value) => widget.counts
      ? '$value 次${widget.total != null && widget.total! > 0 ? '（${(value * 100 / widget.total!).toStringAsFixed(1)}%）' : ''}'
      : value == 0
          ? '暂无记录（0.0 分钟）'
          : '${(value / 60000).toStringAsFixed(1)} 分钟';
  @override
  Widget build(BuildContext context) {
    final values = widget.values,
        counts = widget.counts,
        compact = widget.compact;
    if (values.isEmpty) return const Text('暂无数据');
    final maxMs =
        math.max(counts ? 1 : 60000, values.values.fold<int>(0, math.max));
    final entries = values.entries.toList();
    return SizedBox(
        height: 220,
        child: LayoutBuilder(builder: (_, constraints) {
          final width = compact
              ? constraints.maxWidth
              : math.max(constraints.maxWidth, values.length * 38.0);
          final labelStep = compact && width / values.length < 38 ? 3 : 1;
          final overflow = width > constraints.maxWidth;
          return ScrollConfiguration(
              behavior:
                  ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: Scrollbar(
                  controller: _scroll,
                  thumbVisibility: overflow,
                  trackVisibility: overflow,
                  interactive: true,
                  scrollbarOrientation: ScrollbarOrientation.bottom,
                  thickness: 8,
                  radius: const Radius.circular(4),
                  child: SingleChildScrollView(
                      controller: _scroll,
                      primary: false,
                      padding: const EdgeInsets.only(bottom: 18),
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                          width: width,
                          child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: entries
                                  .map((e) => Expanded(
                                      child: Tooltip(
                                          message:
                                              '${e.key}：${valueText(e.value)}',
                                          triggerMode: TooltipTriggerMode.tap,
                                          child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 3),
                                              child: Column(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.end,
                                                  children: [
                                                    if (values.length <= 12)
                                                      Text(
                                                          counts
                                                              ? '${e.value}'
                                                              : (e.value /
                                                                      60000)
                                                                  .toStringAsFixed(
                                                                      1),
                                                          style:
                                                              const TextStyle(
                                                                  fontSize: 10),
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis),
                                                    const SizedBox(height: 4),
                                                    Container(
                                                        height: math.max(
                                                            2,
                                                            e.value /
                                                                maxMs *
                                                                145),
                                                        decoration: BoxDecoration(
                                                            color: e.value == 0
                                                                ? Theme.of(context)
                                                                    .colorScheme
                                                                    .surfaceContainerHighest
                                                                : Theme.of(context)
                                                                    .colorScheme
                                                                    .primary
                                                                    .withValues(
                                                                        alpha:
                                                                            .75),
                                                            borderRadius:
                                                                const BorderRadius
                                                                    .vertical(
                                                                    top: Radius
                                                                        .circular(4)))),
                                                    const SizedBox(height: 8),
                                                    SizedBox(
                                                        height: 28,
                                                        child: OverflowBox(
                                                          alignment: Alignment
                                                              .topCenter,
                                                          minWidth: 0,
                                                          maxWidth: compact
                                                              ? 38
                                                              : math.max(
                                                                  32,
                                                                  width /
                                                                          values
                                                                              .length -
                                                                      6),
                                                          child: Text(
                                                              entries.indexOf(e) %
                                                                          labelStep ==
                                                                      0
                                                                  ? e.key
                                                                  : '',
                                                              style:
                                                                  const TextStyle(
                                                                      fontSize:
                                                                          10),
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis),
                                                        )),
                                                  ])))))
                                  .toList())))));
        }));
  }
}
