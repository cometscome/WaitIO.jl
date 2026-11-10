#!/usr/bin/env python3
"""Compare native C / Julia observations AND independent numerical expectations."""
import argparse
import json
import math
from pathlib import Path


def cases(path):
    result = []
    for line in Path(path).read_text().splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        key, name, kind, op, root, count = line.split('\t')
        result.append(dict(id=key, name=name, kind=kind, op=op,
                           root=int(root), count=int(count)))
    if not result or len({c['id'] for c in result}) != len(result):
        raise ValueError('empty or duplicate case list')
    return result


def fixture(kind, op, rank, i):
    kind = kind[:-5] if kind.endswith('-wide') else kind
    if kind in ('u8', 'i8'):
        if op == 'sum':
            return rank + 1
        return (200 if kind == 'u8' else -56) + i if rank == 0 else 100 - i
    if kind == 'i64':
        return 2**40 + rank * 10 + i
    return (10 if rank == 0 else -10) + i + (0.25 if kind.startswith('f') else 0)


def expected(c, rank):
    n, name = c['count'], c['name'].split('_')[0]
    root = 1 if c['root'] == -1 else c['root']
    data = [[fixture(c['kind'], c['op'], r, i) for i in range(n)] for r in range(2)]
    if name == 'bcast':
        return data[root]
    if name == 'scatter':
        return data[rank]
    if name in ('waitall', 'p2p'):
        return data[1-rank]
    if name in ('gather', 'allgather'):
        return data[0] + data[1] if name == 'allgather' or rank == root else []
    if name in ('reduce', 'allreduce'):
        if name == 'reduce' and rank != root:
            return []
        operation = {'sum': sum, 'min': min, 'max': max}[c['op']]
        return [operation(pair) for pair in zip(*data)]
    raise ValueError('no independent expectation for ' + name)


def close(a, b, kind):
    if len(a) != len(b):
        return False
    # Integer comparisons stay integer-exact (including Int64 > 2^40).
    if not kind.startswith('f'):
        return a == b
    tol = 1e-6 if kind == 'f32' else 1e-12
    return all(math.isfinite(x) and math.isfinite(y) and
               math.isclose(x, y, rel_tol=tol, abs_tol=tol) for x, y in zip(a, b))


def observation(directory, mode, case, rank):
    stem = Path(directory) / f"{mode}.{case['id']}.{rank}"
    code = int(stem.with_suffix(stem.suffix + '.exit').read_text().strip())
    if code != 0:
        raise ValueError(f'exit={code} (77: missing native symbol; 124: timeout)')
    log = stem.with_suffix(stem.suffix + '.log').read_text()
    rows = [line.split('\t') for line in log.splitlines() if line.startswith('RESULT\t')]
    if len(rows) != 1 or len(rows[0]) != 7:
        raise ValueError('expected exactly one complete RESULT record')
    _, key, actual_rank, size, rc, values, status = rows[0]
    if (key, int(actual_rank), int(size), int(rc)) != (case['id'], rank, 2, 0):
        raise ValueError('wrong case/rank/size or nonzero native return code')
    if len([x for x in status.split(',') if x]) != (2 if case['name'] == 'waitall' else 0):
        raise ValueError('missing or unexpected status entries')
    parse = float if case['kind'].startswith('f') else int
    parsed = [parse(x) for x in values.split(',') if x]
    if case['kind'].startswith('f') and not all(math.isfinite(x) for x in parsed):
        raise ValueError('nonfinite numerical output; see raw log')
    diagnostics = [line[line.index('waitio_'):] for line in log.splitlines()
                   if 'waitio_' in line and ('not defined datatype' in line or 'not defined op' in line)]
    return dict(values=parsed, status=[int(x) for x in status.split(',') if x], native_diagnostics=diagnostics)


def compare(directory, selected):
    planpath=Path(directory)/'plan-0.json'
    modes=json.loads(planpath.read_text()).get('modes',['c','julia']) if planpath.exists() else ['c','julia']
    if modes not in (['c','julia'],['c','julia','c-julia','julia-c']):
        raise ValueError('invalid mode matrix')
    records = []
    for c in selected:
        for rank in (0, 1):
            row = dict(case=c['id'], rank=rank, expected=expected(c, rank))
            errors = {}
            for mode in modes:
                try:
                    row[mode] = observation(directory, mode, c, rank)
                    row[mode + '_numerical_ok'] = close(row[mode]['values'], row['expected'], c['kind'])
                except (OSError, ValueError) as exc:
                    errors[mode] = str(exc)
            if errors:
                row['errors'] = errors
            else:
                row['values_match'] = all(close(row['c']['values'], row[m]['values'], c['kind']) for m in modes)
                row['status_match'] = all(row['c']['status'] == row[m]['status'] for m in modes)
                row['native_diagnostics_ok'] = not any(row[m]['native_diagnostics'] for m in modes)
            row['pass'] = (not errors and row['values_match'] and row['status_match'] and row['native_diagnostics_ok'] and
                           all(row[m+'_numerical_ok'] for m in modes))
            records.append(row)
    return dict(pass_all=all(r['pass'] for r in records),
                case_count=len(selected), rank_observations=len(records), records=records,
                modes=modes, mixed_language_planned=('c-julia' in modes),
                mixed_language_tested=('c-julia' in modes and bool(records) and
                    all(m in row for row in records for m in ('c-julia','julia-c'))),
                scope='Output equivalence and, when included, mixed C/Julia communication for listed cases; not all 80 APIs or performance.')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('directory', type=Path)
    ap.add_argument('--cases', type=Path, default=Path(__file__).with_name('cases.tsv'))
    ap.add_argument('--case', action='append', help='exact case ID (repeatable)')
    ap.add_argument('--output', type=Path)
    args = ap.parse_args()
    selected = cases(args.cases)
    if args.case:
        unknown = set(args.case) - {c['id'] for c in selected}
        if unknown:
            ap.error('unknown cases: ' + ', '.join(sorted(unknown)))
        selected = [c for c in selected if c['id'] in args.case]
    report = compare(args.directory, selected)
    output = args.output or args.directory / 'comparison.json'
    output.write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
    for row in report['records']:
        if not row['pass']:
            print('FAIL', row['case'], 'rank=' + str(row['rank']), json.dumps(row, sort_keys=True))
    print(f"{sum(r['pass'] for r in report['records'])}/{len(report['records'])} rank observations passed; {output}")
    return 0 if report['pass_all'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
