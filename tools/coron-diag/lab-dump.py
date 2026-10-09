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
        # merged timeline: ISR trace + masked samples, by dt
        events = []
        for l in lines:
            if l.startswith(f'ZDIAG lab {c}isr'):
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
