#!/usr/bin/env python3
"""Collect the T1 'ZBOOT snap' lines from the logs of one or more loop runs and print a table:
one row per (run, log file, point), one column per register. Also prints, per point, which
registers differ between boots and the forbidden-condition flags (A: POWER_CLOCK line asserted at
the hook; D: USBD enabled at the hook).

usage: snap-collect.py <logdir> [<logdir> ...]
"""
import glob, os, re, sys

PTS = ('hook', 'clk', 'usb')
LINES = ('k', 'c', 'p', 'r', 'u', 's')
POWER_CLOCK_IRQ = 0     # nRF52840 IRQ 0 = POWER_CLOCK
RTC1_IRQ = 17
USB_INTEN = 0x80 | 0x100 | 0x200   # USBDETECTED | USBREMOVED | USBPWRRDY (POWER INTEN bits 7..9)


def parse_log(path):
    """Return {boot_key: {pt: {reg: value}}} for every dump in the log (keyed by the dump's seq)."""
    boots = {}
    cur_seq = None
    for line in open(path, encoding='utf-8', errors='replace'):
        line = line.rstrip('\r\n')
        m = re.match(r'^ZBOOT snap hdr seq=(\d+) taken=0x([0-9a-f]+)', line)
        if m:
            cur_seq = int(m.group(1))
            boots.setdefault(cur_seq, {'_taken': int(m.group(2), 16)})
            continue
        m = re.match(r'^ZBOOT snap (hook|clk|usb)([kcprus]) (.*)$', line)
        if m and cur_seq is not None:
            pt, ln, rest = m.group(1), m.group(2), m.group(3)
            d = boots[cur_seq].setdefault(pt, {})
            for kv in rest.split(' '):
                if '=' in kv:
                    k, v = kv.split('=', 1)
                    d[f'{ln}.{k}'] = v
    return boots


def flags(pt_regs):
    """Forbidden-condition flags from the hook point."""
    f = []
    h = pt_regs.get('hook', {})
    if not h:
        return ['no-hook-snap']
    pwr_inten = int(h.get('p.inten', '0x0'), 16)
    usb_ev = any(h.get(k, '0') != '0' for k in ('p.det', 'p.rem', 'p.rdy'))
    # POWER and CLOCK share INTENSET (peripheral 0): keep only the clock bits
    # (HFCLKSTARTED 0, LFCLKSTARTED 1, DONE 3, CTTO 4, CTSTARTED 10, CTSTOPPED 11)
    clk_inten = int(h.get('c.inten', '0x0'), 16) & (0x1B | 0xC00)
    clk_ev = h.get('c.lfev', '0') != '0' or h.get('c.hfev', '0') != '0'
    ispr0 = int(h.get('k.ispr', '0x0/0x0').split('/')[0], 16)
    if pwr_inten & USB_INTEN:
        f.append('POWER.INTEN usb bits set')
        if usb_ev:
            f.append('A: POWER usb event pending with INTEN')
    if clk_inten and clk_ev:
        f.append('A?: CLOCK INTEN=0x%x with *STARTED event' % clk_inten)
    if ispr0 & (1 << POWER_CLOCK_IRQ):
        f.append('A: NVIC POWER_CLOCK pending at hook')
    if h.get('u.en', '0') != '0':
        f.append('D: USBD enabled at hook')
    if h.get('c.lfrun', '0') != '0':
        f.append('C?: LFCLKRUN=1 at hook')
    return f or ['none']


def main():
    rows = []
    for logdir in sys.argv[1:]:
        for path in sorted(glob.glob(os.path.join(logdir, '*.log'))):
            if re.search(r'-io\d+', path):
                continue
            for seq, pts in parse_log(path).items():
                rows.append((os.path.basename(logdir), os.path.basename(path), seq, pts))
    if not rows:
        print('no snap lines found')
        return
    # the register columns, in first-seen order
    cols = []
    for _, _, _, pts in rows:
        for pt in PTS:
            for k in pts.get(pt, {}):
                c = f'{pt}:{k}'
                if c not in cols:
                    cols.append(c)
    print('| run | log | seq | ' + ' | '.join(cols) + ' | flags |')
    print('|' + '---|' * (4 + len(cols)))
    for run, log, seq, pts in rows:
        vals = [pts.get(c.split(':')[0], {}).get(c.split(':', 1)[1], '') for c in cols]
        print(f'| {run} | {log} | {seq} | ' + ' | '.join(vals) + ' | ' + '; '.join(flags(pts)) + ' |')
    # variation per column
    print()
    print('registers that vary between boots (per point):')
    for c in cols:
        vs = {pts.get(c.split(':')[0], {}).get(c.split(':', 1)[1], '') for _, _, _, pts in rows}
        vs.discard('')
        if len(vs) > 1 and not c.endswith(('.t', '.cnt', '.cvr', '.reset')):
            print(f'  {c}: {sorted(vs)}')


if __name__ == '__main__':
    main()
