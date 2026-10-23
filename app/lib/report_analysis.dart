import 'package:flutter/material.dart';
import 'domain/reports.dart';
import 'report_charts.dart';

String _minutes(int ms) => (ms / 60000).toStringAsFixed(1);

/// All data belongs to the report selected by the existing period controls.
class FocusTimeAnalysis extends StatelessWidget {
  final Report report;
  const FocusTimeAnalysis(this.report, {super.key});

  Widget _panel(BuildContext context, String title, List<Widget> children) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 16),
                ...children,
              ],
            ),
          ),
        ),
      );

  Widget _hours(String title, List<HourInvestment> hours) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            for (final entry in hours)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('${hourLabel(entry.hour)} · '
                    '${_minutes(entry.milliseconds)} 分钟${entry.tied ? '（并列）' : ''}'),
              ),
          ],
        ),
      );

  String _count(int n) => report.interrupted == 0
      ? '$n 次'
      : '$n 次（${(n * 100 / report.interrupted).toStringAsFixed(1)}%）';

  List<Widget> _largestCounts(List<int> counts, List<String> labels) {
    final ranked = [
      for (var i = 0; i < counts.length; i++)
        if (counts[i] > 0) i
    ]..sort((a, b) {
        final n = counts[b].compareTo(counts[a]);
        return n != 0 ? n : a.compareTo(b);
      });
    return [
      for (final i in ranked.take(3))
        Text('${labels[i]} · ${_count(counts[i])}'
            '${ranked.where((j) => counts[j] == counts[i]).length > 1 ? '（并列）' : ''}'),
    ];
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _panel(context, '活跃与低投入时段', [
            const Text('北京时间，每小时累计本期实际专注时长。'),
            if (!report.enoughSamples)
              Text('样本不足：本期 ${report.sampleCount} 次记录；以下仅展示原始分布，暂不作规律判断。'),
            const SizedBox(height: 12),
            if (report.hourly.every((ms) => ms == 0))
              const Text('暂无记录')
            else if (!report.hasHourVariation)
              const Text('已有记录的时段投入相同，或仅有一个时段，暂无明显差异。')
            else ...[
              _hours('投入最多的时段（最多列出三个）', report.investmentHours()),
              _hours('已记录时段中投入较少（最多列出三个）',
                  report.investmentHours(descending: false)),
              const Text('同值标注并列，超过三个时按钟点先后列出。'),
            ],
            const SizedBox(height: 8),
            const Text('零投入时段表示暂无记录；投入少不代表情绪低落或学习效率低。'),
          ]),
          _panel(context, '中断发生在什么时候', [
            const Text('包含主动提前结束及其他未完成记录，不包含正常完成。'),
            if (report.interrupted == 0)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('本期暂无未完成记录'),
              ),
            if (report.interrupted > 0 && report.interrupted < 5)
              const Text('未完成样本不足五次，仅展示分布，不推断中断规律。'),
            const SizedBox(height: 16),
            const Text('记录结束的钟点（次）'),
            ..._largestCounts(report.hourlyInterruptions,
                [for (var h = 0; h < 24; h++) hourLabel(h)]),
            BarChart(
              {
                for (var h = 0; h < 24; h++)
                  '$h时': report.hourlyInterruptions[h]
              },
              counts: true,
              compact: true,
              total: report.interrupted,
            ),
            const SizedBox(height: 16),
            const Text('中断时的专注进度（次）'),
            ..._largestCounts(
                report.interruptionStages, interruptionStageLabels),
            BarChart(
              {
                for (var i = 0; i < 4; i++)
                  interruptionStageLabels[i]: report.interruptionStages[i]
              },
              counts: true,
              total: report.interrupted,
            ),
            const SizedBox(height: 12),
            for (final entry in interruptionReasonLabels.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                    '${entry.value}：${_count(report.interruptionReasons[entry.key] ?? 0)}'),
              ),
            const SizedBox(height: 8),
            const Text('次数排序最多列出三项；并列超过三项时按钟点或阶段先后列出。'),
            const Text('点击或悬停柱形查看次数与占全部未完成记录的比例；该比例不是中断概率。'
                '进度按整次实际专注时间 ÷ 计划时长计算，排除暂停；25%、50%、75% 归入后一阶段。'
                '异常结束的钟点可能为最后一次可靠检查点，无法确定故障发生的准确时刻。'),
          ]),
          _panel(context, '完整番茄数前三科目 / 项目', [
            const Text('按本期完整番茄数排名；同数时按本期投入时长、名称排序。'),
            const SizedBox(height: 12),
            if (report.topSubjects.isEmpty) const Text('暂无已分类且在本期完成的番茄记录'),
            for (final subject in report.topSubjects) ...[
              Text(subject.name, style: Theme.of(context).textTheme.titleSmall),
              Text('${subject.completed} 个完整番茄 · '
                  '${_minutes(subject.milliseconds)} 分钟实际投入（含未完成）'),
              if (subject.records < 5) const Text('该科目样本不足五次，仅展示原始投入分布。'),
              if (subject.peakHours.isNotEmpty)
                Text(
                    '本期投入最多：${subject.peakHours.take(3).map(hourLabel).join('、')}'
                    '${subject.peakHours.length > 1 ? '（并列${subject.peakHours.length > 3 ? '，共 ${subject.peakHours.length} 个时段' : ''}）' : ''}，'
                    '每时段 ${_minutes(subject.hourly[subject.peakHours.first])} 分钟'),
              BarChart({for (var h = 0; h < 24; h++) '$h时': subject.hourly[h]},
                  compact: true),
              const SizedBox(height: 16),
            ],
            if (report.unclassifiedRecords > 0)
              Text('另有 ${report.unclassifiedRecords} 次未分类记录，不参与学科排名。'),
            const Text('图表按本期实际专注区间分配时长；完整番茄数按结束日期归属。'
                '跨期结束的番茄可能在本期计数、但本期投入为零。时段仅作为安排任务的参考。'),
          ]),
        ],
      );
}
