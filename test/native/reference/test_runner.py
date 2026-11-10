"""Exercise orchestration with a tiny socket stub, not a WaitIO implementation."""
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from compare import cases, compare

HERE = Path(__file__).resolve().parent
CASE = 'allreduce-i32-sum-r0-n3'


class RunnerTests(unittest.TestCase):
    def run_pair(self, missing=False, hang=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = root / 'socket_stub.py'
            fake.write_text('#!'+sys.executable+'\n'+'''import os, socket, sys
from pathlib import Path
sys.path.insert(0, %r)
from compare import cases, expected
if os.environ.get('STUB_MISSING') == 'yes':
    raise SystemExit(77)
if os.environ.get('STUB_HANG') == 'yes':
    import time
    time.sleep(30)
case = next(c for c in cases(Path(%r)/'cases.tsv') if c['id']==sys.argv[-6])
rank = int(os.environ['WAITIO_PBID'])
port = int(os.environ['WAITIO_MASTER_PORT']) + int(os.environ['COUPLER_JOB_ID'])
with socket.socket() as sock:
    if rank == 0:
        sock.bind(('127.0.0.1', port)); sock.listen()
        conn, _ = sock.accept()
        with conn: conn.sendall(b'ok')
    else:
        sock.connect(('127.0.0.1', port)); assert sock.recv(2)==b'ok'
print('RESULT\\t%%s\\t%%d\\t2\\t0\\t%%s\\t' %% (case['id'], rank, ','.join(map(str, expected(case,rank)))))
''' % (str(HERE), str(HERE)))
            fake.chmod(0o755)
            launcher = root / 'launcher.sh'
            launcher.write_text('#!/bin/sh\nexec "$@"\n')
            launcher.chmod(0o755)
            config = root / 'config.toml'; config.write_text('# stub only\n')
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
            if port > 64000:
                self.skipTest('ephemeral port too high')
            output = root / 'results'
            workers = []
            try:
                for role in (0, 1):
                    env = dict(os.environ, WAITIO_PBID=str(role), WAITIO_NPB='2',
                               WAITIO_JL_CONFIG=str(config), REFERENCE_LIBWAITIO='/dev/null',
                               REFERENCE_LIBWAITIO_MPI='/dev/null', WAITIO_MASTER_HOST='127.0.0.1',
                               COUPLER_JOB_ID='0', STUB_MISSING='yes' if missing else 'no', STUB_HANG='yes' if hang else 'no')
                    cmd = [sys.executable, str(HERE/'run-peer.py'), str(role), str(output),
                           '--c-executable', str(fake), '--julia', str(fake), '--project', str(root),
                           '--launcher', str(launcher), '--case', CASE, '--base-port', str(port),
                           '--timeout', '3', '--peer-timeout', '5']
                    workers.append(subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True))
                for proc in workers:
                    text, _ = proc.communicate(timeout=30)
                    self.assertEqual(proc.returncode, int(missing or hang), text+'\n'+'\n'.join(p.read_text() for p in output.glob('*.log')))
                report = compare(output, [c for c in cases(HERE/'cases.tsv') if c['id']==CASE])
                self.assertEqual(report['pass_all'], not (missing or hang))
                if hang:
                    self.assertEqual(len(list(output.glob('*.exit'))),2)
                self.assertEqual(report['mixed_language_tested'],not (missing or hang))
                self.assertEqual(report['modes'], ['c','julia','c-julia','julia-c'])
            finally:
                for proc in workers:
                    if proc.poll() is None:
                        proc.kill(); proc.wait()
                    if proc.stdout is not None:
                        proc.stdout.close()

    def test_socket_orchestration(self):
        self.run_pair()

    def test_timeout_stops_remaining_launches(self):
        self.run_pair(hang=True)

    def test_missing_symbol_stops_waiting_peer(self):
        self.run_pair(missing=True)


if __name__ == '__main__':
    unittest.main()
