"""Expiry filtering tests with fixed synthetic dates; no network or credentials."""
import importlib.util
from pathlib import Path
import sys
import unittest
import json
import tempfile
import contextlib
import io
from datetime import datetime, timedelta

SPEC = importlib.util.spec_from_file_location('focus_scraper_expiry', Path(__file__).resolve().parents[1]/'assets/study_scraper.py')
M = importlib.util.module_from_spec(SPEC); sys.modules[SPEC.name] = M; SPEC.loader.exec_module(M)

class ExpiryTests(unittest.TestCase):
    now = datetime(2028, 3, 1, 8, tzinfo=M.CST)
    def item(self, days, status='待完成', extra=None):
        return M.Item('chaoxing', '作业', str(days), '示例课程',
            None if days is None else self.now-timedelta(days=days), status,
            'https://mooc1.chaoxing.com/work', str(days), extra or {})
    def keep(self, items, days=0, include_all=False):
        return M.filter_items(items, include_all, None, self.now, days)
    def test_default_removes_overdue_even_if_source_claims_open(self):
        self.assertEqual(len(self.keep([self.item(1, extra={'open': True}), self.item(-1), self.item(None)])), 2)
        self.assertEqual(self.keep([self.item(0)]), [])
    def test_seven_days_boundary_and_expired_platform_state(self):
        rows=[self.item(6, '已过期', {'open': False}), self.item(7), self.item(7.001)]
        stats={}; kept=M.filter_items(rows, False, None, self.now, 7, stats)
        self.assertEqual(len(kept), 2); self.assertEqual(stats['ignored_expired'], 1)
        self.assertEqual(len(self.keep(rows, 7)), 2, '过滤不得破坏原始 open 标记')
    def test_thirty_days_crosses_leap_month_and_year(self):
        self.assertEqual(len(self.keep([self.item(30), self.item(30.01)], 30)), 1)
        self.assertEqual(len(self.keep([self.item(90)], -1)), 1)
    def test_completion_is_not_revived_by_a_relaxed_expiry_rule(self):
        self.assertEqual(self.keep([self.item(1, '已完成'), self.item(1, extra={'completed':True, 'open':False})], -1), [])
    def test_unknown_deadlines_and_legacy_all_mode(self):
        self.assertEqual(self.keep([self.item(None, '已过期')]), [])
        self.assertEqual(len(self.keep([self.item(None, '已过期')], 7)), 1)
        self.assertEqual(len(M.filter_items([self.item(90,'已完成')],True,None,self.now)),1)
    def test_cli_validation_and_metadata(self):
        p=M.build_parser()
        self.assertEqual(p.parse_args(['--ignore-expired-days','14']).expired_after_days,14)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            p.parse_args(['--ignore-expired-days','3651'])
        with tempfile.TemporaryDirectory(prefix='focus-expiry-synthetic-') as folder:
            for days, ignored, count in [('0', 1, 6), ('7', 0, 7)]:
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(M.main(['--demo', '--quiet', '--ignore-expired-days', days, '--out-dir', folder]), 0)
                data=json.loads((Path(folder)/'demo_todos.json').read_text(encoding='utf-8'))
                self.assertEqual(data['filters']['ignore_expired_days'], int(days))
                self.assertEqual(data['ignored_expired'], ignored)
                self.assertEqual(data['count'], count)
    def test_chaoxing_parser_retains_completion_signal(self):
        rows=M.parse_cx_task_html('<li data="/work/phone/doHomeWork?workId=1"><p>作业</p><span>已提交 截止时间：2028-02-28 12:00</span></li>',M.Course('c','g'), 'work')
        self.assertTrue(rows[0].extra['completed'])
        self.assertEqual(self.keep(rows, -1), [])
    def test_mooc_expired_unsubmitted_and_submitted_are_separate(self):
        course={'name':'示例课程','course_id':'c','term_id':'t'}
        # Raw record metadata must preserve submission evidence independently of expiry.
        record={'id':1,'usedTryCount':1}
        row=M.ic_item_from(record,course,'quiz','测验','1',self.now)
        self.assertTrue(row.extra['completed'])
        self.assertEqual(self.keep([row], -1), [])

if __name__ == '__main__': unittest.main()
