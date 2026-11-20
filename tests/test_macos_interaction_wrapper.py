#!/usr/bin/env python3
"""Exercise the real shell wrapper against isolated native-command fixtures.

The fixture replaces only OS binaries in a private copy; production has no
injected executable paths. No LaunchServices, TCC, or GUI input is exercised.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MacWrapperTests(unittest.TestCase):
    def run_wrapper(self, mode):
        temporary = tempfile.TemporaryDirectory(prefix="mac-wrapper-test-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        install = root / "installed app with spaces"
        install.mkdir()
        app = install / "FesTermVMEvidenceInteraction.app"
        executable = app / "Contents/MacOS/FesTermVMEvidenceInteraction"
        executable.parent.mkdir(parents=True)
        executable.write_text("fixture")
        executable.chmod(0o700)
        fixture = root / "native.py"
        fixture.write_text('''#!''' + sys.executable + '''
import json,os,pathlib,signal,subprocess,sys,time
root=pathlib.Path(os.environ['FIXTURE_ROOT']);op=sys.argv[1];args=sys.argv[2:]
def alive(pid):
 try: os.kill(pid,0);return True
 except ProcessLookupError:return False
if op=='codesign':sys.exit(0)
if op=='plutil':print(100);sys.exit(0)
if op=='ps':
 opened=root/'open.json'
 if '-p' in args and opened.exists():
  launched=json.loads(opened.read_text())
  if args[args.index('-p')+1]==str(launched['pid']):
   if not alive(launched['pid']):sys.exit(0)
   if 'uid=' in args:print(os.getuid())
   elif 'comm=' in args:print('/usr/bin/open')
   elif 'command=' in args:print(launched['argv'])
   elif 'lstart=' in args:
    reads=root/'open-birth-reads';n=int(reads.read_text())if reads.exists()else 0;reads.write_text(str(n+1))
    print('replacement open lifetime' if os.environ['FIXTURE_MODE']=='open-changed-birth' and n>0 else 'original open lifetime')
   sys.exit(0)
 state=root/'child.json'
 if os.environ['FIXTURE_MODE']=='existing' and not state.exists():
  if args==['-ww','-axo','pid=,comm=']:print('987654 '+os.environ['FIXTURE_EXE'])
  sys.exit(0)
 if not state.exists():sys.exit(0)
 child=json.loads(state.read_text());pid=child['pid']
 if not alive(pid):sys.exit(0)
 if args==['-ww','-axo','pid=,comm=']:print(str(pid)+' '+os.environ['FIXTURE_EXE'])
 elif 'uid=' in args:print(os.getuid())
 elif 'comm=' in args:print(os.environ['FIXTURE_EXE'])
 elif 'command=' in args:print(child['argv'])
 elif 'lstart=' in args:
  reads=root/'birth-reads';n=int(reads.read_text())if reads.exists()else 0;reads.write_text(str(n+1))
  print('replacement lifetime' if os.environ['FIXTURE_MODE']=='changed-birth' and n>0 else 'original lifetime')
 sys.exit(0)
if op=='open':
 (root/'open.json').write_text(json.dumps({'pid':os.getpid(),'argv':' '.join(['/usr/bin/open']+args)}))
 assert args[:3]==['-n','-g','-W']
 def value(flag):return args[args.index(flag)+1]
 session=pathlib.Path(args[args.index('--session')+1]);command=pathlib.Path(value('--stdin'));output=pathlib.Path(value('--stdout'));error=pathlib.Path(value('--stderr'))
 assert session.parent==command.parent==output.parent==error.parent
 assert session.parent.stat().st_mode&0o777==0o700
 assert all(p.stat().st_mode&0o777==0o600 for p in(session,command,output,error))
 assert value('-a')==os.environ['FIXTURE_APP']
 if os.environ['FIXTURE_MODE']=='deferred-child':
  def deferred(*unused):
   assert not session.exists()
   (root/'session-revoked-before-deferred-child').write_text('yes')
   child=subprocess.Popen(['/bin/sleep','30'],start_new_session=True,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   (root/'child.json').write_text(json.dumps({'pid':child.pid,'argv':os.environ['FIXTURE_EXE']+' --session '+str(session)+' --artifact-root '+value('--artifact-root')}))
   sys.exit(0)
  signal.signal(signal.SIGTERM,deferred)
  while True:time.sleep(.02)
 child=subprocess.Popen(['/bin/sleep','30'],start_new_session=True,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 (root/'child.json').write_text(json.dumps({'pid':child.pid,'argv':os.environ['FIXTURE_EXE']+' --session '+str(session)+' --artifact-root '+value('--artifact-root')}))
 if os.environ['FIXTURE_MODE']=='success':
  output.write_text('fixture-result\\n');time.sleep(.2);child.terminate();child.wait();sys.exit(0)
 if os.environ['FIXTURE_MODE']=='open-fails':
  child.terminate();child.wait();sys.exit(19)
 def reap(*unused):
  child.poll();sys.exit(0)
 signal.signal(signal.SIGTERM,reap)
 while child.poll()is None or os.environ['FIXTURE_MODE']=='open-changed-birth':time.sleep(.02)
 sys.exit(0)
''')
        fixture.chmod(0o700)
        source = (ROOT / "interaction/macos/driver-command.sh").read_text()
        for command in ("codesign", "plutil"):
            source = source.replace("/usr/bin/" + command, '"' + str(fixture) + '" ' + command)
        source = source.replace("\n/usr/bin/open ", '\n"' + str(fixture) + '" open ')
        source = source.replace("/bin/ps", '"' + str(fixture) + '" ps')
        wrapper = install / "driver-command.sh"
        wrapper.write_text(source)
        wrapper.chmod(0o700)
        session = root / "input-session.json"
        command = root / "input-command.json"
        session.write_text(json.dumps({"limits": {"command_timeout_ms": 100}}))
        command.write_text("{}")
        env = os.environ.copy()
        env.update(FIXTURE_ROOT=str(root), FIXTURE_MODE=mode,
                   FIXTURE_EXE=str(executable), FIXTURE_APP=str(app), TMPDIR=str(root))
        if mode == "locked":
            (install / ".interaction-command-lock").mkdir(mode=0o700)
        try:
            result = subprocess.run([str(wrapper), str(session), str(command), str(root / "artifacts")],
                                    env=env, capture_output=True, timeout=16)
            state = root / "child.json"
            child = json.loads(state.read_text())["pid"] if state.exists() else None
            if mode == "open-changed-birth":
                opened = json.loads((root / "open.json").read_text())["pid"]
                os.kill(opened, 0)  # Different open lifetime was never killed.
            if mode == "changed-birth":
                self.assertIsNotNone(child)
                os.kill(child, 0)  # The replacement lifetime was never terminated.
            elif child:
                with self.assertRaises(ProcessLookupError):
                    os.kill(child, 0)
            return result, root
        finally:
            opened = root / "open.json"
            if opened.exists():
                try:
                    os.kill(json.loads(opened.read_text())["pid"], 15)
                except ProcessLookupError:
                    pass
            state = root / "child.json"
            if state.exists():
                try:
                    os.kill(json.loads(state.read_text())["pid"], 15)
                except ProcessLookupError:
                    pass

    def test_launchservices_private_io_and_result(self):
        result, root = self.run_wrapper("success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"fixture-result\n")
        self.assertFalse(list(root.glob("vm-evidence-interaction.*")))

    def test_open_failure_propagates(self):
        result, _ = self.run_wrapper("open-fails")
        self.assertEqual(result.returncode, 19, result.stderr)
        self.assertEqual(result.stdout, b"")

    def test_existing_helper_is_not_adopted(self):
        result, root = self.run_wrapper("existing")
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertFalse((root / "child.json").exists())

    def test_existing_command_lock_is_not_adopted(self):
        result, root = self.run_wrapper("locked")
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertFalse((root / "child.json").exists())

    def test_deadline_terminates_exact_new_lifetime(self):
        result, root = self.run_wrapper("timeout")
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertFalse(list(root.glob("vm-evidence-interaction.*")))

    def test_deferred_child_is_found_after_open_stops(self):
        result, root = self.run_wrapper("deferred-child")
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertEqual((root / "session-revoked-before-deferred-child").read_text(), "yes")
        self.assertFalse(list(root.glob("vm-evidence-interaction.*")))

    def test_changed_open_birth_is_not_killed(self):
        result, root = self.run_wrapper("open-changed-birth")
        self.assertEqual(result.returncode, 125, result.stderr)
        self.assertEqual(len(list(root.glob("vm-evidence-interaction.*"))), 1)

    def test_changed_birth_is_not_killed_and_evidence_retained(self):
        result, root = self.run_wrapper("changed-birth")
        self.assertEqual(result.returncode, 125, result.stderr)
        self.assertEqual(len(list(root.glob("vm-evidence-interaction.*"))), 1)


if __name__ == "__main__":
    unittest.main()
