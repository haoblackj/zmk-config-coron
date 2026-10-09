#!/usr/bin/env python3
"""Read a console dump of the lab image (diag_lab.c) and print its crash records as a readable
timeline: addresses resolved with addr2line against the image's ELF, IRQ numbers named, the
ISR/thread trace and the masked-region samples merged in time order around the crash.
usage: lab-dump.py <dump.out or flash-*-io*.out> [--elf zmk.elf] [--addr2line PATH] [--live]
"""
import argparse
import re
import subprocess
import sys

IRQ = {0: 'POWER_CLOCK', 1: 'RADIO', 2: 'UARTE0', 3: 'SPIM0', 4: 'SPIM1', 5: 'NFCT', 6: 'GPIOTE', 7: 'SAADC',
       8: 'TIMER0', 9: 'TIMER1', 10: 'TIMER2', 11: 'RTC0', 12: 'TEMP', 13: 'RNG', 14: 'ECB', 15: 'CCM_AAR',
       16: 'WDT', 17: 'RTC1', 18: 'QDEC', 19: 'COMP', 20: 'SWI0', 21: 'SWI1', 22: 'SWI2', 23: 'SWI3',
       24: 'SWI4', 25: 'SWI5', 26: 'TIMER3', 27: 'TIMER4', 28: 'PWM0', 29: 'PDM', 32: 'MWU', 33: 'PWM1',
       34: 'PWM2', 35: 'SPIM2', 36: 'RTC2', 37: 'I2S', 38: 'FPU', 39: 'USBD', 40: 'UARTE1', 41: 'QSPI',
       42: 'CRYPTOCELL', 45: 'PWM3', 47: 'SPIM3'}


def irq_names(iabr0, iabr1l):
    names = [IRQ.get(i, str(i)) for i in range(32) if iabr0 >> i & 1]
    names += [IRQ.get(32 + i, str(32 + i)) for i in range(16) if iabr1l >> i & 1]
    return ','.join(names) or '-'


class Resolver:
    def __init__(self, elf, a2l):
        self.elf, self.a2l, self.cache = elf, a2l, {}

    def __call__(self, addr):
        if not self.elf or not addr:
            return ''
        if addr not in self.cache:
            try:
                out = subprocess.run([self.a2l, '-f', '-e', self.elf, hex(addr)], capture_output=True, text=True,
                                     env={'PATH': '/usr/bin:/bin'}).stdout.split('\n')
                fn = out[0].strip()
                loc = out[1].strip().split('/')[-1] if len(out) > 1 else ''
                self.cache[addr] = f'{fn} ({loc})'
            except Exception as e:  # noqa: BLE001
                self.cache[addr] = f'? ({e})'
        return self.cache[addr]


def kv(line):
    return {m.group(1): m.group(2) for m in re.finditer(r'(\w+)=(\S+)', line)}


def s24(v):
    """signed 24-bit tick difference"""
    v &= 0xffffff
    return v - 0x1000000 if v & 0x800000 else v


CONN_BASE = 5  # TICKER_ID_CONN_BASE (printed by liveprepstat "conn=id-5")


def tid(i):
    if i == 0:
        return 'PREEMPT'
    if i >= CONN_BASE and i < CONN_BASE + 8:
        return f'conn{i - CONN_BASE}'
    return f'id{i}'


def ctl_text(body):
    """one 'ctl' line body ('dt=.. <name> a= b= c= d=') -> words (enum lab_ctl_type, diag_lab.h)"""
    m = re.match(r'dt=(-?\d+) (\S+) a=(\d+) b=([0-9a-f]+) c=(\d+) d=(\d+)', body)
    if not m:
        return body
    dt, name, a, b, c, d = int(m.group(1)), m.group(2), int(m.group(3)), int(m.group(4), 16), int(m.group(5)), int(m.group(6))
    h = lambda x: 'NULL' if x == 0xff else ('?' if x == 0xfe else f'conn{x}')
    if name == 'prepcalc':
        t = f'lateness check {tid(a)}: event at {c}, now {d} ({s24(d - c):+d} ticks) -> {"LATE overhead=" + str(b) if b else "ok"}'
    elif name == 'prepare':
        flags = ('resume ' if b & 1 else '') + ('dequeue ' if b & 2 else '') + (f'lazy={b >> 2} ' if b >> 2 else '')
        ret = d - 0x100000000 if d & 0x80000000 else d
        t = f'prepare {h(a)} {flags}ticks_at_expire={c} -> {"queued (-EINPROGRESS)" if ret == -119 else ("ran, ret=" + str(ret))}'
    elif name == 'tstart':
        t = f'ticker_start {tid(a)} user={b & 0xff} anchor={c} first={d} (expiry {(c + d) & 0xffffff}) -> {"ok" if (b >> 8) == 0 else ("busy (job pending)" if (b >> 8) == 2 else "FAIL " + str(b >> 8))}'
    elif name == 'tstop':
        t = f'ticker_stop {tid(a)} user={b & 0xff} now={c} -> {"ok" if (b >> 8) == 0 else ("busy (job pending)" if (b >> 8) == 2 else "FAIL " + str(b >> 8))}'
    elif name == 'tstart-op':
        t = f'preempt ticker start answered: status={b} now={c}'
    elif name == 'tstop-op':
        t = f'preempt ticker stop answered: status={b} now={c}'
    elif name == 'preempt':
        t = f'PREEMPT TICKER FIRED for {h(a)}: at_expire={c} now={d} lazy={b & 0xff} force={b >> 8}'
    elif name == 'is-abort':
        ret = c - 0x100000000 if c & 0x80000000 else c
        t = f'is_abort? curr={h(a)} ({"peripheral" if b >> 8 & 1 else "central"}{", FORCED" if b >> 9 & 1 else ""}) next={h(b & 0xff)} -> {"keep running (0)" if ret == 0 else ("abort (-ECANCELED)" if ret == -140 else ("busy" if ret == -16 else ("resume (-EAGAIN)" if ret == -11 else str(ret))))} now={d}'
    elif name == 'abort':
        t = f'abort {h(a)}: {"cancel queued prepare ticks_at_expire=" + str(c) if b else "abort the running event now=" + str(c)}'
    elif name == 'enqueue':
        t = f'enqueue {h(a)} {"resume " if b else ""}ticks_at_expire={c}{"" if d else " PIPELINE FULL"}'
    elif name == 'dequeue':
        t = f'dequeue (run the pipeline) caller={a} now={c}'
    elif name == 'tupdate':
        t = f'ticker_update {tid(a)} lazy={b & 0x7fff}{" FORCE" if b & 0x8000 else ""} drift+={c} drift-={d}'
    elif name == 'MARK':
        t = f'*** late prepare recorded: {tid(a)} late={c} ticks'
    else:
        t = body
    return f'{dt:8d}  {t}'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dump')
    ap.add_argument('--elf')
    ap.add_argument('--addr2line',
                    default='/nix/store/57hybry1spzvsy5ml99wdm6p49hlr3nh-zephyr-sdk-0.16.9/arm-zephyr-eabi/bin/arm-zephyr-eabi-addr2line')
    ap.add_argument('--live', action='store_true', help='also print the live latency ring and prepare stats')
    a = ap.parse_args()
    res = Resolver(a.elf, a.addr2line)
    text = open(a.dump, encoding='utf-8', errors='replace').read().replace('\r', '')
    lines = text.split('\n')

    for l in lines:
        if l.startswith('ZDIAG begin') or l.startswith('ZDIAG crumb') or l.startswith('ZDIAG lab live '):
            print(l)
    if a.live:
        for l in lines:
            if l.startswith('ZDIAG lab livelat') or l.startswith('ZDIAG lab liveprepstat'):
                d = kv(l)
                pc = int(d.get('pc', '0'), 16)
                print(l, res(pc) if pc else '')
        print('  -- live controller steps (dt us relative to the dump):')
        for l in lines:
            if l.startswith('ZDIAG lab livectl '):
                print('   ', ctl_text(l[len('ZDIAG lab livectl '):]))

    crashes = sorted({m.group(1) for m in re.finditer(r'^ZDIAG lab (crash\d+) ', text, re.M)})
    for c in crashes:
        print(f'\n===== {c} =====')
        hdr = next(l for l in lines if l.startswith(f'ZDIAG lab {c} '))
        d = kv(hdr)
        pc, lr = int(d['pc'], 16), int(d['lr'], 16)
        print(hdr)
        print(f'  interrupted thread pc: {res(pc)}   lr: {res(lr)}')
        print(f'  active ISRs at crash: {irq_names(int(d["iabr"].split("/")[0], 16), int(d["iabr"].split("/")[1], 16) & 0xffff)}'
              f'   crashing context ipsr={d["ipsr"]} ({IRQ.get(int(d["ipsr"]) - 16, "?") if int(d["ipsr"]) >= 16 else "thread"})')
        for l in lines:
            if l.startswith(f'ZDIAG lab {c}stat') or l.startswith(f'ZDIAG lab {c}conn') or l.startswith(f'ZDIAG lab {c}prepstat'):
                print(' ', l[len('ZDIAG lab '):])
        print('  -- connection events (ms since boot):')
        for l in lines:
            if l.startswith(f'ZDIAG lab {c}ev '):
                print('   ', l[len(f'ZDIAG lab {c}ev '):])
        print('  -- printk tail:')
        for l in lines:
            if l.startswith(f'ZDIAG lab {c}pk '):
                print('   ', l[len(f'ZDIAG lab {c}pk '):])
        print('  -- latency events (>=100 us) before the crash:')
        for l in lines:
            if l.startswith(f'ZDIAG lab {c}lat '):
                e = kv(l)
                print('   ', l[len(f'ZDIAG lab {c}lat '):], '->', res(int(e['pc'], 16)))
        print('  -- prepare checks before the crash (dt us relative to the crash; late in RTC ticks, 30.52 us):')
        for l in lines:
            if l.startswith(f'ZDIAG lab {c}prep '):
                print('   ', l[len(f'ZDIAG lab {c}prep '):])
        # merged timeline: ISR trace + masked samples + controller steps, by dt
        events = []
        for l in lines:
            if l.startswith(f'ZDIAG lab {c}ctl '):
                txt = ctl_text(l[len(f'ZDIAG lab {c}ctl '):])
                events.append((int(txt.split()[0]), 'CTL ' + txt[10:]))
            elif l.startswith(f'ZDIAG lab {c}isr'):
                for item in l[len(f'ZDIAG lab {c}isr'):].split():
                    m = re.match(r'(-?\d+):(.*)', item)
                    if not m:
                        continue
                    dt, what = int(m.group(1)), m.group(2)
                    if what.startswith('T'):
                        events.append((dt, f'thread -> {what[1:]}'))
                    else:
                        n, sign = int(what[:-1]), what[-1]
                        events.append((dt, f'{IRQ.get(n, n)} {"enter" if sign == "+" else "exit"}'))
            elif l.startswith(f'ZDIAG lab {c}msk '):
                e = kv(l)
                pc = int(e['pc'], 16)
                i0, i1 = e['iabr'].split('/')
                events.append((int(e['dt']), f'sample: masked bp={e["bp"]} pm={e["pm"]} in {("thread" if e["ipsr"] == "0" else IRQ.get(int(e["ipsr"]) - 16, e["ipsr"]))}'
                               f' active={irq_names(int(i0, 16), int(i1, 16))} pc={pc:x} {res(pc)}'))
        events.sort()
        print('  -- timeline before the crash (dt in us, 0 = the crash):')
        for dt, what in events:
            print(f'    {dt:8d}  {what}')
        print('  -- activity (1 ms ticks, run-length):')
        for l in lines:
            if l.startswith(f'ZDIAG lab {c}act '):
                e = kv(l)
                i0, i1 = e['isr'].split('/')
                pcs = e['pc'].split('..')
                print('   ', l[len(f'ZDIAG lab {c}act '):], '|', irq_names(int(i0, 16), int(i1, 16)), '|', res(int(pcs[0], 16)))


if __name__ == '__main__':
    sys.exit(main())
