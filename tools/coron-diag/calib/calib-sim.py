#!/usr/bin/env python3
"""Runs every mock scenario as a FULL run through calib-all.ps1 (Windows PowerShell 5.1 via
powershell.exe from WSL; scripts and logs on the WSL side through their UNC path) and compares
the outcome with the scenario's expect.json: exit code, the per-step results line, regexes that
must / must not appear in the logs (optionally restricted to one log file by glob). Any mismatch
makes this script exit 1 (review #9, point 6). No device is touched: mock mode never calls
Get-PnpDevice, CIM, SerialPort or Copy-Item; the calib-io.ps1 child gets a canned port.

  calib-sim.py --out <dir> [--jobs 4] [--only name,name]
Writes <dir>/sim/<scenario>/ (the scenario files), <dir>/logs-<time>/<scenario>/ (every log of the run),
<dir>/report.txt (verdict table + the decisive log lines per scenario) and <dir>/results.json.
"""
import argparse, concurrent.futures, fnmatch, json, os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
SERIAL = 'B17318CDBE9A61B1'
COMMON = ['-Serial', SERIAL,
          '-Uf2Base', 'C:\\T\\coron_R-bt4.uf2', '-Md5Base', 'df108d7ad2009afccfbfbba66b6ad093',
          '-Uf2Alt', 'C:\\T\\coron_R-bt4-alt.uf2', '-Md5Alt', 'e1e62efeeda0f87a1678a3d53f8151cf',
          '-Uf2Prod', 'C:\\T\\coron_R-prod-2725423.uf2', '-Md5Prod', '889f3a4816c82bdd4adc253b16f28689']
DECISIVE = re.compile(r'RESULT|STOPPED before|DEVICE-OP|NOT sent|\[calib-io\] sent|timed out|did not return|CALIBRATION|^.{12} restore|results:|NOTE reset|SKIP|MOCK FILE')


def wpath(p):
    return subprocess.check_output(['wslpath', '-w', p], text=True).strip()


def read_logs(logdir):
    """{filename: text} for every file in the log dir (logs, child stdout/stderr, mock files)."""
    out = {}
    for fn in sorted(os.listdir(logdir)):
        p = os.path.join(logdir, fn)
        if os.path.isfile(p):
            with open(p, encoding='utf-8', errors='replace') as f:
                out[fn] = f.read()
    return out


def results_line(logs):
    m = re.search(r'^.{12} results: (.*)$', logs.get('summary.log', ''), re.M)
    if not m:
        return {}
    return dict(tok.split('=', 1) for tok in m.group(1).split())


def check_regex(logs, item, want_present):
    if isinstance(item, str):
        glob, rx = '*', item
    else:
        glob, rx = item['glob'], item['re']
    text = '\n'.join(t for fn, t in logs.items() if any(fnmatch.fnmatch(fn, g) for g in glob.split('|')))
    found = re.search(rx, text, re.M) is not None
    return found == want_present, f"{'must' if want_present else 'must not'} [{glob}] /{rx}/ -> {'found' if found else 'absent'}"


def run_one(name, simdir, logroot, allps):
    logdir = os.path.join(logroot, name)
    os.makedirs(logdir, exist_ok=True)
    with open(os.path.join(simdir, name, 'expect.json')) as f:
        exp = json.load(f)
    script = wpath(os.path.join(HERE, exp.get('script', 'calib-all.ps1')))   # calib-all.ps1 or calib-loop.ps1
    t0 = time.time()
    with open(os.path.join(logdir, 'console.txt'), 'w') as con:
        rc = subprocess.call(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script] + COMMON + exp.get('args', []) +
                             ['-LogDir', wpath(logdir), '-MockDir', wpath(os.path.join(simdir, name))],
                             stdout=con, stderr=subprocess.STDOUT)
    secs = time.time() - t0
    logs = read_logs(logdir)
    problems = []
    if rc != exp['exit']:
        problems.append(f'exit code: want {exp["exit"]} got {rc}')
    got = results_line(logs)
    if got != exp['results']:
        problems.append(f'results: want {exp["results"]} got {got}')
    for item in exp.get('must', []):
        ok, msg = check_regex(logs, item, True)
        if not ok:
            problems.append(msg)
    for item in exp.get('must_not', []):
        ok, msg = check_regex(logs, item, False)
        if not ok:
            problems.append(msg)
    decisive = []
    for fn, text in logs.items():
        if not (fn.endswith('.log')):
            continue
        for line in text.splitlines():
            if DECISIVE.search(line):
                decisive.append(f'{fn}: {re.sub(r"^[0-9:.]+ ", "", line)}')
    return dict(name=name, rc=rc, want=exp['exit'], results=got, problems=problems, decisive=decisive, secs=round(secs, 1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('--only', default='')
    a = ap.parse_args()
    stamp = time.strftime('%m%d-%H%M%S')
    simdir = os.path.join(a.out, 'sim'); logroot = os.path.join(a.out, 'logs-' + stamp)
    os.makedirs(logroot, exist_ok=True)
    subprocess.check_call([sys.executable, os.path.join(HERE, 'gen-scenarios.py'), '--out', simdir])
    names = sorted(os.listdir(simdir))
    if a.only:
        names = [n for n in names if n in a.only.split(',')]
    # the identification matchers, on instance ids read from the real PC (no device needed)
    st = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', wpath(os.path.join(HERE, 'calib-selftest.ps1'))],
                        capture_output=True, text=True)
    selftest = st.stdout.replace('\r', '')
    with open(os.path.join(a.out, 'selftest.txt'), 'w') as f:
        f.write(selftest)
    print(selftest.strip().splitlines()[-1], f'(exit {st.returncode})', flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as pool:
        futs = {pool.submit(run_one, n, simdir, logroot, None): n for n in names}
        res = {}
        for fut in concurrent.futures.as_completed(futs):
            r = fut.result()
            res[r['name']] = r
            print(f"{'OK      ' if not r['problems'] else 'MISMATCH'} {r['name']:22s} exit={r['rc']} (want {r['want']}) {r['secs']}s", flush=True)
            for p in r['problems']:
                print(f'    {p}', flush=True)
    bad = [n for n in names if res[n]['problems']]
    if st.returncode != 0:
        bad = ['selftest'] + bad
    lines = [f'calib-sim {time.strftime("%Y-%m-%d %H:%M:%S")}: {len(names)} scenarios, {len(bad)} mismatch', '', '--- selftest (identification matchers on real instance ids)'] + selftest.strip().splitlines() + ['']
    lines.append('| scenario | exit want/got | results | verdict |')
    lines.append('|---|---|---|---|')
    for n in names:
        r = res[n]
        rs = ' '.join(f'{k}={v}' for k, v in r['results'].items()) or '(none)'
        lines.append(f"| {n} | {r['want']}/{r['rc']} | {rs} | {'OK' if not r['problems'] else 'MISMATCH: ' + '; '.join(r['problems'])} |")
    for n in names:
        lines += ['', f'=== {n}'] + ['    ' + d for d in res[n]['decisive']]
    with open(os.path.join(a.out, 'report.txt'), 'w') as f:
        f.write('\n'.join(lines) + '\n')
    with open(os.path.join(a.out, 'results.json'), 'w') as f:
        json.dump(res, f, indent=1)
    print(f'report: {os.path.join(a.out, "report.txt")}; mismatches: {bad if bad else "none"}')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
