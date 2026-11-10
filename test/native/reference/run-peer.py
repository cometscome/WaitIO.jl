#!/usr/bin/env python3
"""Run on BOTH allocated compute nodes, with PB0=role0 and PB1=role1.
The shared output directory must be fresh. One MPI process per PB only.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import time
from compare import cases


def wait_for(path, timeout):
    deadline = time.monotonic() + timeout
    while not path.exists():
        if time.monotonic() >= deadline:
            raise TimeoutError(str(path))
        time.sleep(0.2)


def listening(port):
    tables = [Path(name) for name in ('/proc/net/tcp', '/proc/net/tcp6') if Path(name).exists()]
    if not tables:
        raise RuntimeError('Linux TCP socket tables are unavailable')
    for table in tables:
        for line in table.read_text().splitlines()[1:]:
            fields = line.split()
            if fields[3] == '0A' and int(fields[1].split(':')[1], 16) == port:
                return True
    return False


def stop(proc):
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
    except ProcessLookupError:
        proc.wait()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('role', type=int, choices=(0, 1))
    ap.add_argument('output', type=Path)
    ap.add_argument('--c-executable', type=Path, required=True)
    ap.add_argument('--project', type=Path, required=True)
    ap.add_argument('--julia', default='julia')
    ap.add_argument('--julia-arg', action='append', default=[], help='additional Julia option; use --julia-arg=--compile=min for slow startup')
    ap.add_argument('--launcher', required=True, help='e.g. "mpiexec.hydra -np 1"')
    ap.add_argument('--case', action='append')
    ap.add_argument('--timeout', type=int, default=60)
    ap.add_argument('--peer-timeout', type=int, default=300)
    ap.add_argument('--base-port', type=int, default=22000)
    args = ap.parse_args()
    here = Path(__file__).resolve().parent
    selected = cases(here / 'cases.tsv')
    if args.case:
        if set(args.case) - {c['id'] for c in selected}:
            ap.error('unknown case ID')
        selected = [c for c in selected if c['id'] in args.case]
    if int(os.environ.get('WAITIO_PBID', '-1')) != args.role or os.environ.get('WAITIO_NPB') != '2':
        ap.error('export WAITIO_NPB=2 and WAITIO_PBID matching the role')
    for name in ('WAITIO_JL_CONFIG', 'REFERENCE_LIBWAITIO', 'REFERENCE_LIBWAITIO_MPI', 'WAITIO_MASTER_HOST'):
        if not os.environ.get(name):
            ap.error('missing ' + name)
    coupler_id = int(os.environ.get('COUPLER_JOB_ID', '0'))
    if not 0 <= coupler_id <= 10000:
        ap.error('invalid COUPLER_JOB_ID')
    if not 1024 <= args.base_port <= 65000 - coupler_id - 4*len(selected):
        ap.error('invalid port range')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Atomic exclusive role claim prevents silently reusing a previous run.
    fingerprint = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                   for p in here.iterdir() if p.suffix in ('.c', '.jl', '.tsv', '.py', '.sh')}
    plan = dict(cases=[c['id'] for c in selected], base_port=args.base_port,
                timeout=args.timeout, coupler_id=coupler_id, sources=fingerprint,
                modes=['c','julia','c-julia','julia-c'])
    with (output / f'plan-{args.role}.json').open('x') as f:
        json.dump(plan, f)
    (output / f'ready-{args.role}').touch()
    wait_for(output / f'ready-{1-args.role}', args.peer_timeout)
    if json.loads((output / f'plan-{1-args.role}.json').read_text()) != plan:
        raise ValueError('participants have different test cases, sources, ports, or timeouts')
    provenance = dict(role=args.role, launcher=shlex.split(args.launcher),
                      c_executable_sha256=hashlib.sha256(args.c_executable.read_bytes()).hexdigest(),
                      configuration_sha256=hashlib.sha256(Path(os.environ['WAITIO_JL_CONFIG']).read_bytes()).hexdigest(),
                      package_sources={str(p.relative_to(args.project)): hashlib.sha256(p.read_bytes()).hexdigest()
                                       for p in sorted((args.project/'src').rglob('*.jl'))},
                      libraries={key: hashlib.sha256(Path(os.environ[key]).read_bytes()).hexdigest()
                                 for key in ('REFERENCE_LIBWAITIO', 'REFERENCE_LIBWAITIO_MPI')})
    (output / f'provenance-{args.role}.json').write_text(json.dumps(provenance, indent=2)+'\n')
    failed = False
    for index, case in enumerate(selected):
        for m, mode in enumerate(plan['modes']):
            label = f"{mode}.{case['id']}"
            port = args.base_port + 4*index + m
            env = dict(os.environ, WAITIO_MASTER_PORT=str(port), COUPLER_JOB_ID=str(coupler_id))
            listen_port = port + coupler_id
            values = [case['id'], case['name'], case['kind'], case['op'], str(case['root']), str(case['count'])]
            cmd = shlex.split(args.launcher)
            language = mode if mode in ('c','julia') else mode.split('-')[args.role]
            cmd += ['/bin/sh', str(here/'capture-peer.sh')]
            cmd += ([str(args.c_executable.resolve())] if language == 'c' else
                    [args.julia, '--startup-file=no'] + args.julia_arg + ['--project='+str(args.project.resolve()), str(here/'peer.jl')])
            cmd += values
            marker = output / (label + '.listening')
            stem = output / f'{label}.{args.role}'
            code = 125
            peer_output = Path(str(stem)+'.peer.log')
            env['WAITIO_REFERENCE_PEER_OUTPUT'] = str(peer_output)
            with Path(str(stem)+'.log').open('x') as log:
                proc = None
                try:
                    if args.role == 1:
                        # Master can fail before binding (e.g. absent native symbol).
                        deadline = time.monotonic() + args.timeout + 10
                        while not marker.exists():
                            if (output / f'{label}.0.exit').exists():
                                raise RuntimeError('master exited before listening')
                            if time.monotonic() >= deadline:
                                raise TimeoutError('master readiness')
                            time.sleep(0.1)
                    elif listening(listen_port):
                        raise RuntimeError('port is already occupied')
                    started = time.monotonic()
                    proc = subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT,
                                            start_new_session=True)
                    if args.role == 0:
                        while proc.poll() is None and not listening(listen_port):
                            if time.monotonic() - started >= args.timeout:
                                raise TimeoutError('master socket startup; listening entries='+repr([line for name in ('/proc/net/tcp','/proc/net/tcp6') if Path(name).exists() for line in Path(name).read_text().splitlines()[1:] if line.split()[3]=='0A']))
                            time.sleep(0.1)
                        if proc.poll() is None:
                            marker.touch()
                    # Give communication/finalization its full budget after startup.
                    # Slow Julia startup must not leave milliseconds for completion.
                    code = proc.wait(timeout=args.timeout)
                except (TimeoutError, subprocess.TimeoutExpired) as exc:
                    code = 124
                    log.write(str(exc)+'\n')
                except (OSError, RuntimeError) as exc:
                    log.write(str(exc)+'\n')
                finally:
                    if proc is not None and proc.poll() is None:
                        stop(proc)
                    if peer_output.exists():
                        log.write(peer_output.read_text(errors='replace'))
            Path(str(stem)+'.exit').write_text(str(code)+'\n')
            failed |= code != 0
            wait_for(output / f'{label}.{1-args.role}.exit', args.timeout+20)
            peer_code=int((output / f'{label}.{1-args.role}.exit').read_text())
            print(label, 'role='+str(args.role), 'exit='+str(code), flush=True)
            if code==124 or peer_code==124:
                print('STOP: timeout; use a fresh scheduler allocation for the remaining cases',flush=True)
                return 1
    return int(failed)


if __name__ == '__main__':
    raise SystemExit(main())
