import gzip
import ipaddress
import json
import multiprocessing
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from common import ROOT, engine, model
from sbm.core import audit, network_policy

BASH = shutil.which('bash')
FPR = '2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C'


class ShellCase(unittest.TestCase):
    def setUp(self):
        td=tempfile.TemporaryDirectory();self.addCleanup(td.cleanup);self.p=pathlib.Path(td.name)
        for f in ['systemctl','ss']:(ROOT/'tests/mocks'/f).chmod(0o755)
        (self.p/'service.json').write_text(json.dumps({'active':True,'enabled':True}))

    def run_bash(self,script,expected=0,answers='yes\n'*10):
        env=dict(os.environ,PROJECT=str(ROOT),TEST_ROOT=str(self.p),PYTHONDONTWRITEBYTECODE='1')
        r=subprocess.run([BASH,'-c','source "$PROJECT/tests/transaction_harness.sh"\n'+script],env=env,
                         input=answers,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        self.assertEqual(r.returncode,expected,r.stdout)
        return r.stdout


SYSCTL_MOCK = r'''
BBR_CONF=$TEST_ROOT/90-bbr.conf
CC_AVAILABLE=$TEST_ROOT/available
printf 'reno cubic bbr\n' >"$CC_AVAILABLE"
[[ -f $TEST_ROOT/sysctl.state ]] || printf 'net.ipv4.tcp_congestion_control=reno\nnet.core.default_qdisc=pfifo_fast\n' >"$TEST_ROOT/sysctl.state"
sysctl() {
    local state=$TEST_ROOT/sysctl.state
    case $1 in
        -n) sed -n "s/^$2=//p" "$state";;
        -w) printf '%s\n' "$2" >>"$TEST_ROOT/sysctl.log"; python3 - "$state" "$2" <<'PY'
import sys
path,item=sys.argv[1],sys.argv[2];key,value=item.split('=',1)
rows=dict(line.split('=',1) for line in open(path).read().split())
rows[key]=value;open(path,'w').write(''.join(k+'='+v+'\n' for k,v in rows.items()))
PY
            ;;
        -p) [[ ! -f $TEST_ROOT/fail-sysctl-p ]] || { sysctl -w net.core.default_qdisc=fq; return 1; }
            local line; while read -r line; do [[ $line == \#* || -z $line ]] || sysctl -w "$line" >/dev/null; done <"$2";;
        --system) printf 'system\n' >>"$TEST_ROOT/sysctl.log";;
    esac
}
modprobe() { :; }
'''


class BbrRestore(ShellCase):
    def state(self):
        return dict(line.split('=',1) for line in (self.p/'sysctl.state').read_text().split())

    def test_enable_records_and_disable_restores_original_cc_and_qdisc(self):
        self.run_bash(SYSCTL_MOCK+'bbr_action')
        self.assertEqual(self.state(),{'net.ipv4.tcp_congestion_control':'bbr','net.core.default_qdisc':'fq'})
        saved=(self.p/'state/bbr-original.conf').read_text()
        self.assertIn('tcp_congestion_control=reno',saved);self.assertIn('default_qdisc=pfifo_fast',saved)
        self.assertEqual(oct((self.p/'state/bbr-original.conf').stat().st_mode&0o777),'0o600')
        self.run_bash(SYSCTL_MOCK+'bbr_action')
        self.assertEqual(self.state(),{'net.ipv4.tcp_congestion_control':'reno','net.core.default_qdisc':'pfifo_fast'})
        self.assertFalse((self.p/'90-bbr.conf').exists());self.assertFalse((self.p/'state/bbr-original.conf').exists())

    def test_legacy_enable_without_record_falls_back_to_cubic(self):
        (self.p/'90-bbr.conf').write_text('# Managed by singbox-manager.sh\n')
        (self.p/'sysctl.state').write_text('net.ipv4.tcp_congestion_control=bbr\nnet.core.default_qdisc=fq\n')
        self.run_bash(SYSCTL_MOCK+'bbr_action')
        self.assertEqual(self.state()['net.ipv4.tcp_congestion_control'],'cubic')

    def test_unsupported_recorded_algorithm_warns_and_uses_cubic(self):
        self.run_bash(SYSCTL_MOCK+'bbr_action')
        (self.p/'state/bbr-original.conf').write_text('tcp_congestion_control=vegas\ndefault_qdisc=pfifo_fast\n')
        output=self.run_bash(SYSCTL_MOCK+'bbr_action')
        self.assertIn('已回退为 cubic',output);self.assertEqual(self.state()['net.ipv4.tcp_congestion_control'],'cubic')

    def test_rejected_enable_restores_partial_change_and_removes_record(self):
        (self.p/'fail-sysctl-p').write_text('')
        self.run_bash(SYSCTL_MOCK+'bbr_action',1)
        self.assertEqual(self.state(),{'net.ipv4.tcp_congestion_control':'reno','net.core.default_qdisc':'pfifo_fast'})
        self.assertFalse((self.p/'90-bbr.conf').exists());self.assertFalse((self.p/'state/bbr-original.conf').exists())

    def test_cancel_changes_nothing(self):
        self.run_bash(SYSCTL_MOCK+'bbr_action',answers='no\n')
        self.assertEqual(self.state()['net.ipv4.tcp_congestion_control'],'reno')
        self.assertFalse((self.p/'state/bbr-original.conf').exists())


def gpg_mock(pubs, fpr, fail=False):
    rows=''.join(f'pub:-:4096:1:6D9152172A2B2F0C:1:::::scESC::::::23::0:\\nfpr:::::::::{fpr}:\\n' for _ in range(pubs))
    body='return 1' if fail else f"printf '{rows}'"
    return 'gpg() { '+body+'; }\n'


class AptKeyPin(ShellCase):
    def test_only_the_single_pinned_primary_key_is_accepted(self):
        self.run_bash(gpg_mock(1,FPR)+'sagernet_key_check "$TEST_ROOT/key.asc"')
        self.run_bash(gpg_mock(1,'0'*40)+'sagernet_key_check "$TEST_ROOT/key.asc"',1)
        self.run_bash(gpg_mock(2,FPR)+'sagernet_key_check "$TEST_ROOT/key.asc"',1)
        self.run_bash(gpg_mock(1,FPR,fail=True)+'sagernet_key_check "$TEST_ROOT/key.asc"',1)

    def test_repo_setup_refuses_a_different_key_before_writing_apt_files(self):
        script=gpg_mock(1,'A'*40)+'''curl() { : >"${@: -1}"; }
install() { echo "UNEXPECTED install $*" >>"$TEST_ROOT/writes"; }
repo_setup'''
        output=self.run_bash(script,1)
        self.assertIn(FPR,output);self.assertFalse((self.p/'writes').exists())

    def test_pinned_value_is_the_cross_checked_fingerprint(self):
        source=(ROOT/'src/core/runtime.sh').read_text()
        self.assertIn('SAGERNET_KEY_FPR='+FPR,source)


class AuditRotation(unittest.TestCase):
    def setUp(self):
        td=tempfile.TemporaryDirectory();self.addCleanup(td.cleanup);self.dir=pathlib.Path(td.name);self.path=self.dir/'audit.jsonl'
        for name,value in (('ROTATE_ENTRIES',4),('KEEP_SEGMENTS',20)):
            patcher=patch.object(audit,name,value);patcher.start();self.addCleanup(patcher.stop)

    def append(self,count):
        for i in range(count):audit.append(self.path,'action-start','a'+str(i),'started')

    def segments(self):return sorted(p for p in self.dir.iterdir() if p.name.endswith('.gz'))

    def test_rotation_bounds_the_current_segment_and_keeps_a_verified_chain(self):
        self.append(13)
        report=audit.verify(self.path)
        self.assertTrue(report['valid']);self.assertLessEqual(report['entries'],4)
        self.assertEqual(report['segments'],len(self.segments()));self.assertGreaterEqual(report['segments'],3)
        self.assertFalse(report['history_truncated'])
        rows=[]
        for segment in self.segments():rows+=gzip.decompress(segment.read_bytes()).decode().splitlines()
        rows+=self.path.read_text().splitlines()
        events=[json.loads(r) for r in rows]
        self.assertEqual(sum(e['event']=='action-start' for e in events),13)
        self.assertTrue(all(oct(s.stat().st_mode&0o777)=='0o400' for s in self.segments()))
        first=json.loads(self.path.read_text().splitlines()[0])
        self.assertEqual(first['event'],'audit-rotate');self.assertEqual(first['previous'],first['previous_segment']['last_hash'])

    def test_tampered_or_mismatched_sealed_segment_is_detected(self):
        self.append(9);segment=self.segments()[-1];segment.chmod(0o600)
        data=gzip.decompress(segment.read_bytes()).replace(b'started',b'finished!',1)
        segment.write_bytes(gzip.compress(data,mtime=0))
        with self.assertRaisesRegex(ValueError,'摘要不符'):audit.verify(self.path)

    def test_rotation_row_only_allowed_first_and_must_link(self):
        self.append(5);lines=self.path.read_text().splitlines()
        row=json.loads(lines[0]);row['previous']='f'*64;row.pop('hash');row['hash']=audit.digest(row)
        self.path.write_text(json.dumps(row,separators=(',',':'))+'\n'+'\n'.join(lines[1:])+('\n' if lines[1:] else ''))
        with self.assertRaises(ValueError):audit.verify(self.path)

    def test_old_segments_are_pruned_and_reported_as_truncated_history(self):
        with patch.object(audit,'KEEP_SEGMENTS',2):self.append(20)
        self.assertEqual(len(self.segments()),2)
        report=audit.verify(self.path);self.assertTrue(report['valid']);self.assertTrue(report['history_truncated'])
        self.assertEqual(report['segments'],2)

    def test_crash_orphan_segment_is_removed_at_next_rotation(self):
        self.append(5);orphan=self.dir/'audit.jsonl.20260101T000000Z-0badf00d.gz';orphan.write_bytes(gzip.compress(b'x',mtime=0))
        self.append(4);self.assertFalse(orphan.exists());self.assertTrue(audit.verify(self.path)['valid'])

    def test_pre_rotation_logs_still_verify_and_append(self):
        with patch.object(audit,'ROTATE_ENTRIES',10**6):self.append(3)
        self.assertEqual(audit.verify(self.path)['entries'],3)
        self.append(3);self.assertTrue(audit.verify(self.path)['valid'])

    def test_concurrent_writers_never_append_to_a_rotated_inode(self):
        context=multiprocessing.get_context('fork')
        workers=[context.Process(target=worker,args=(str(self.path),)) for _ in range(4)]
        for w in workers:w.start()
        for w in workers:w.join();self.assertEqual(w.exitcode,0)
        rows=[]
        for segment in self.segments():rows+=gzip.decompress(segment.read_bytes()).decode().splitlines()
        rows+=self.path.read_text().splitlines()
        self.assertEqual(sum(json.loads(r)['event']=='action-start' for r in rows),40)
        self.assertTrue(audit.verify(self.path)['valid'])


def worker(path):
    for _ in range(10):audit.append(path,'action-start','w','started')


def documentation_public(address):
    # Tests may only use RFC 5737 / 3849 documentation ranges; treat them as public here.
    return address.is_global or any(address in ipaddress.ip_network(n) for n in ('198.51.100.0/24','203.0.113.0/24','2001:db8::/32') if address.version==ipaddress.ip_network(n).version)


class PublicAddress(unittest.TestCase):
    def setUp(self):
        patcher=patch.object(network_policy,'is_public',side_effect=documentation_public);patcher.start();self.addCleanup(patcher.stop)

    def runner(self,answers):
        calls=[]
        def run(command,**kwargs):
            calls.append(command[-1]);value=answers.get(command[-1])
            if isinstance(value,BaseException):raise value
            if value is None:raise subprocess.CalledProcessError(7,command)
            return value
        return run,calls

    def test_detection_falls_back_to_later_sources_and_rejects_bad_answers(self):
        run,calls=self.runner({'https://api.ipify.org':'10.0.0.5\n','https://ipv4.icanhazip.com':subprocess.TimeoutExpired('curl',20),
                               'https://checkip.amazonaws.com':'203.0.113.9\n'})
        address,source=network_policy.detect_public(4,runner=run)
        self.assertEqual(str(address),'203.0.113.9');self.assertEqual(source,'https://checkip.amazonaws.com');self.assertEqual(len(calls),3)
        run,_=self.runner({'https://api6.ipify.org':'203.0.113.9\n'})
        self.assertEqual(network_policy.detect_public(6,runner=run),(None,None))

    def test_every_probe_is_https_only(self):
        seen=[]
        def run(command,**kwargs):seen.append(command);raise subprocess.CalledProcessError(7,command)
        network_policy.detect_public(4,runner=run);network_policy.detect_public(6,runner=run)
        self.assertEqual(len(seen),5);self.assertTrue(all('--proto' in c and '=https' in c for c in seen))

    def dns_model(self):
        m=model();m['nodes']=[m['nodes'][0]];m['nodes'][0]['server']='198.51.100.20';return m

    def test_interface_global_address_is_enough_when_probes_fail(self):
        with patch.object(engine.network_policy,'collect_local',return_value={'198.51.100.20','10.0.0.2'}),\
             patch.object(engine.network_policy,'detect_public',return_value=(None,None)),\
             patch.object(engine.network_policy,'confirmed_load',return_value=[]),\
             patch.object(engine,'protocol') as adapter:
            engine.verify_dns(self.dns_model())
        adapter.assert_called()

    def test_confirmed_address_covers_nat_and_error_explains_how(self):
        m=self.dns_model()
        with patch.object(engine.network_policy,'collect_local',return_value={'10.0.0.2'}),\
             patch.object(engine.network_policy,'detect_public',return_value=(None,None)),\
             patch.object(engine.network_policy,'confirmed_load',return_value=[]):
            with self.assertRaisesRegex(ValueError,'public-ip add'):engine.verify_dns(m)
        with patch.object(engine.network_policy,'collect_local',return_value={'10.0.0.2'}),\
             patch.object(engine.network_policy,'detect_public',return_value=(ipaddress.ip_address('203.0.113.1'),'https://api.ipify.org')),\
             patch.object(engine.network_policy,'confirmed_load',return_value=[ipaddress.ip_address('198.51.100.20')]),\
             patch.object(engine,'protocol'):
            engine.verify_dns(m)

    def test_confirmed_list_roundtrip_rejects_private_addresses(self):
        with tempfile.TemporaryDirectory() as state:
            network_policy.confirmed_command(state,'add','198.51.100.20')
            self.assertEqual([str(a) for a in network_policy.confirmed_load(state)],['198.51.100.20'])
            for bad in ('10.0.0.1','127.0.0.1','not-an-ip','::1'):
                with self.assertRaises(ValueError):network_policy.confirmed_command(state,'add',bad)
            with self.assertRaises(ValueError):network_policy.confirmed_command(state,'remove','203.0.113.4')
            network_policy.confirmed_command(state,'remove','198.51.100.20');self.assertEqual(network_policy.confirmed_load(state),[])
            network_policy.confirmed_command(state,'add','198.51.100.21');network_policy.confirmed_command(state,'clear')
            self.assertEqual(network_policy.confirmed_load(state),[])
            path=pathlib.Path(state)/'public-addresses.json';path.write_text('{"format":1,"addresses":["192.168.1.1"]}')
            with self.assertRaises(ValueError):network_policy.confirmed_load(state)

    def test_confirmed_list_reads_state_from_environment(self):
        with tempfile.TemporaryDirectory() as state:
            network_policy.confirmed_command(state,'add','198.51.100.22')
            with patch.dict(os.environ,{'SBM_STATE':state}):
                self.assertEqual([str(a) for a in network_policy.confirmed_load()],['198.51.100.22'])
            with patch.dict(os.environ,{},clear=True):self.assertEqual(network_policy.confirmed_load(),[])


class PublicAddressCli(ShellCase):
    def test_cli_argument_validation(self):
        self.assertIn('用法',self.run_bash('main security public-ip add',1))
        self.assertIn('公网地址操作无效',self.run_bash('main security public-ip bogus',1))
        self.assertIn('用法',self.run_bash('main security public-ip remove 198.51.100.1 extra',1))


if __name__=='__main__':unittest.main()
