"""Checks that comparison cannot pass missing output or two identical wrong answers."""
import json
import tempfile
import unittest
from pathlib import Path
from compare import cases, compare, expected


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.all_cases = cases(Path(__file__).with_name('cases.tsv'))
        self.case = next(c for c in self.all_cases if c['id'] == 'allreduce-u8-max-r0-n3')

    def write(self, mode, rank, values=None, code=0, status='', extra=''):
        c = self.case
        values = expected(c, rank) if values is None else values
        stem = self.path / f"{mode}.{c['id']}.{rank}"
        Path(str(stem)+'.log').write_text('native diagnostic noise\n' +
            f"RESULT\t{c['id']}\t{rank}\t2\t0\t" + ','.join(map(str, values)) + '\t' + status + '\n' + extra)
        Path(str(stem)+'.exit').write_text(str(code))

    def populate(self):
        for mode in ('c', 'julia'):
            for rank in (0, 1):
                self.write(mode, rank)

    def report(self):
        return compare(self.path, [self.case])

    def test_correct(self):
        self.populate()
        self.assertTrue(self.report()['pass_all'])

    def test_both_wrong(self):
        for mode in ('c', 'julia'):
            for rank in (0, 1):
                self.write(mode, rank, [100, 99, 98])
        result = self.report()
        self.assertFalse(result['pass_all'])
        self.assertTrue(result['records'][0]['values_match'])
        self.assertFalse(result['records'][0]['julia_numerical_ok'])

    def test_different(self):
        self.populate(); self.write('julia', 1, [100, 99, 98])
        self.assertFalse(self.report()['records'][1]['values_match'])

    def test_missing(self):
        self.populate()
        (self.path / f"c.{self.case['id']}.0.log").unlink()
        self.assertFalse(self.report()['pass_all'])

    def test_failed_timeout_missing_symbol_and_finalize(self):
        for code in (1, 77, 124, 125):
            with self.subTest(code=code):
                self.populate(); self.write('c', 1, code=code)
                self.assertFalse(self.report()['pass_all'])

    def test_duplicate(self):
        self.populate()
        path = self.path / f"c.{self.case['id']}.0.log"
        path.write_text(path.read_text()*2)
        self.assertFalse(self.report()['pass_all'])

    def test_wrong_rank(self):
        self.populate()
        path = self.path / f"c.{self.case['id']}.0.log"
        path.write_text(path.read_text().replace('\t0\t2\t0\t', '\t1\t2\t0\t'))
        self.assertFalse(self.report()['pass_all'])

    def test_status_mismatch(self):
        self.case = next(c for c in self.all_cases if c['name']=='waitall')
        for rank in (0, 1):
            self.write('c', rank, status='-777,-777')
            self.write('julia', rank, status='0,0')
        result = self.report()
        self.assertFalse(result['pass_all'])
        self.assertTrue(result['records'][0]['values_match'])
        self.assertFalse(result['records'][0]['status_match'])

    def test_status_missing(self):
        self.case = next(c for c in self.all_cases if c['name']=='waitall')
        self.populate()
        self.assertFalse(self.report()['pass_all'])

    def test_integer_exactness(self):
        self.case = dict(self.case, kind='i64')
        self.populate(); self.write('julia', 0, [2**40+1, 2**40+2, 2**40+3])
        self.assertFalse(self.report()['pass_all'])

    def test_float_nonfinite(self):
        self.case = next(c for c in self.all_cases if c['kind']=='f64')
        self.populate(); self.write('c', 0, [float('nan')]*3)
        self.assertFalse(self.report()['pass_all'])

    def test_float_tolerance(self):
        self.case = next(c for c in self.all_cases if c['kind']=='f64')
        self.populate()
        self.write('julia', 0, [x+1e-13 for x in expected(self.case, 0)])
        self.assertTrue(self.report()['pass_all'])
        self.write('julia', 0, [x+1e-4 for x in expected(self.case, 0)])
        self.assertFalse(self.report()['pass_all'])

    def populate_mixed(self):
        modes = ['c', 'julia', 'c-julia', 'julia-c']
        (self.path / 'plan-0.json').write_text(json.dumps(dict(modes=modes)))
        for mode in modes:
            for rank in (0, 1):
                self.write(mode, rank)

    def test_mixed_correct(self):
        self.populate_mixed()
        self.assertTrue(self.report()['pass_all'])
        self.assertTrue(self.report()['mixed_language_tested'])

    def test_mixed_missing(self):
        self.populate_mixed()
        (self.path / f"c-julia.{self.case['id']}.1.log").unlink()
        self.assertFalse(self.report()['pass_all'])
        self.assertFalse(self.report()['mixed_language_tested'])

    def test_mixed_wrong(self):
        self.populate_mixed()
        self.write('julia-c', 0, [100, 99, 98])
        self.assertFalse(self.report()['pass_all'])

    def test_native_unsupported_message_fails_even_if_values_match(self):
        self.populate_mixed()
        self.write('c', 0, extra='host:0:0 waitio_mpi_reduce not defined datatype 80003\n')
        row=self.report()['records'][0]
        self.assertTrue(row['values_match'])
        self.assertTrue(row['c_numerical_ok'])
        self.assertFalse(row['native_diagnostics_ok'])
        self.assertFalse(row['pass'])

    def test_all_fixtures(self):
        self.assertEqual(len(self.all_cases), 57)
        for c in self.all_cases:
            for rank in (0, 1):
                self.assertIsInstance(expected(c, rank), list)


if __name__ == '__main__':
    unittest.main()
