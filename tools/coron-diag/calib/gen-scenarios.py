#!/usr/bin/env python3
"""Mock scenarios for the calibration scripts (review #8, point 8).

Writes sim/<scenario>/<step>.json files that calib-lib.ps1's mock mode replays: a sequence of
USB states, a sequence of console exchanges (dump text + replies), the UF2 drives present and
whether a copy succeeds, and the files with their md5. The dump texts follow diag_boot.c v4's
print_rec/diag_boot_print format exactly (line names a/b/entry1/entry2/us1/us2/fire1..4).
"""
import json, os, sys, copy

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sim')
SERIAL = 'B17318CDBE9A61B1'
IMG = {
    'base': dict(tag='bt4-R-10080217', sysq='0x20009910', main='0x20009848', calib='0x20005d00', spin=0x662ea),
    'alt':  dict(tag='bt4A-R-10080217', sysq='0x2000b688', main='0x2000b5c0', calib='0x20005d18', spin=0x38a08),
}
FILES = {
    'base': ('C:\\T\\coron_R-bt4.uf2', 'df108d7ad2009afccfbfbba66b6ad093'),
    'alt':  ('C:\\T\\coron_R-bt4-alt.uf2', 'e1e62efeeda0f87a1678a3d53f8151cf'),
    'prod': ('C:\\T\\coron_R-prod-2725423.uf2', '889f3a4816c82bdd4adc253b16f28689'),
}
ADDR = 'ZBOOT addr cur=0x2002c818 last=0x2002c6f4 ring=0x2002c008 sysq={sysq} main={main} calib={calib}'


def rec(tag, img, seq, done=1, reason=0, calib='-', stage=12, reinit=0, probes=(30, 30), feeds=28, loops=30,
        fire=None, usb=1200, running=4100):
    """One record as the firmware prints it (list of lines)."""
    lines = [
        f'ZBOOT {tag} a seq={seq} tag={img["tag"]} done={done} reason={reason} phase={1 if done else 0} calib={calib} stage={stage} reset=0x4 reinit={reinit}',
        f'ZBOOT {tag} b fix=0/0/0 probes={probes[0]}/{probes[1]} feeds={feeds} loops={loops} lastfeed_us={loops * 2000000}',
        f'ZBOOT {tag} entry1 lfstat=0x10000 lfrun=1 lfsrc=0x1 lfcopy=0x1 lfev=0',
        f'ZBOOT {tag} entry2 hfstat=0x10001 hfrun=1 hfev=0 rtc1=12345 usbreg=0x3 ficr130=0x8 ficr134=0x1',
        f'ZBOOT {tag} us1 hook=12 pk1=40 clk=300 pk1end=350 sysclk=400 post=600 app=800',
        f'ZBOOT {tag} us2 usb={usb} applast=1500 commit=2500 mainexit=3900 probed=4000 running={running}',
    ]
    if fire:
        lines += [
            f'ZBOOT {tag} fire1 exc=0x{fire["exc"]:x} msp=0x2003f000 psp=0x20008800 frame=0x{fire["frame"]:x} pc=0x{fire["pc"]:x} lr=0x{fire["pc"] + 1:x}',
            f'ZBOOT {tag} fire2 xpsr=0x61000000 handler={fire["handler"]} thread={fire["thread"]} at_us={fire["at_us"]}',
            f'ZBOOT {tag} fire3 usbd en=1 ec=0x0 pullup=1 usbreg=0x3',
            f'ZBOOT {tag} fire4 lfstat=0x10000 lfrun=1 hfstat=0x10001 hfrun=1 cc0=468750',
        ]
    return lines


def inc_h(img, seq):   # cooperative stall on the system workqueue -> WQ_TIMEOUT
    return rec('INC', img, seq, done=1, reason=2, calib='h', stage=12,
               fire=dict(exc=0xfffffffd, frame=0x20009000, pc=img['spin'], handler=0, thread=img['sysq'], at_us=19000000))


def inc_G(img, seq):   # priority-0 spinner starves the feeder -> WQ_TIMEOUT, thread = calib_thread
    return rec('INC', img, seq, done=1, reason=2, calib='G', stage=12,
               fire=dict(exc=0xfffffffd, frame=0x20005f00, pc=img['spin'] + 2, handler=0, thread=img['calib'], at_us=19500000))


def inc_S(img, seq):   # armed stall at APPLICATION 50 -> BOOT_TIMEOUT
    return rec('INC', img, seq, done=0, reason=1, calib='S', stage=6, probes=(0, 0), feeds=0, loops=0, usb=0, running=0,
               fire=dict(exc=0xfffffff9, frame=0x2003fe00, pc=img['spin'], handler=0, thread=img['main'], at_us=20000000))


def dump(img, cur, incs=(), last=None, count=None, dropped=0, invalid=0, reinit=0, calib_live=0, extra='', trunc=False,
         no_end=False, drop_line=None):
    """A full console dump: ZDIAG begin, ZBOOT lines, ZDIAG end (+ replies in extra)."""
    n = len(incs) if count is None else count
    out = ['ZDIAG begin version=prof1 up_ms=65000 boot=1 reset=0x4',
           'ZDIAG now count host_conn=1 host_disc=0 split_conn=1 split_disc=0',
           f'ZBOOT ring count={n} slots=6 dropped={dropped} invalid={invalid} reinit={reinit} calib_live={calib_live}',
           ADDR.format(**img)]
    for i, lines in enumerate(incs):
        out += [l.replace('ZBOOT INC ', f'ZBOOT inc{i} ') for l in lines]
    out += last if last else ['ZBOOT last none']
    out += cur
    if trunc:
        out[3] = out[3][:60] + ' #TRUNC'
    if drop_line:
        out = [l for l in out if not l.startswith(drop_line)]
    if not no_end:
        out.append('ZDIAG end')
    text = '\r\n'.join(out) + '\r\n'
    text = '[calib-io] opened COM5 at 00:00:00.000\n' + text + ('' if no_end else '\n[calib-io] dump complete at 00:00:02.000\n')
    return text + extra


def reply(send, rc=0, returned=False, lost=False, extra=''):
    s = f"[calib-io] sent '{send}' at 00:00:02.100\n"
    if rc is not None:
        s += f'ZDIAG calibrate {send} rc={rc}\r\n'
    s += extra
    if returned:
        s += f'ZDIAG calibrate {send} returned\r\n'
    if lost:
        s += '\n[calib-io] port lost (The device does not recognize the command) at 00:00:14.000\n'
    s += '[calib-io] read window over at 00:00:20.000\n[calib-io] closing at 00:00:20.100\n'
    return s


def ex(send, stdout, exit_code=0, stderr=''):
    return dict(send=send, stdout=stdout, exit=exit_code, stderr=stderr)


def files(**override):
    f = {p: m for p, m in FILES.values()}
    f.update(override)
    return f


def scen(states, exchanges, drives=None, copy='ok', vanish=True, fl=None):
    return dict(states=states, exchanges=exchanges, ports=['COM5'],
                uf2=dict(drives=drives if drives is not None else [], copy=copy, vanish=vanish),
                files=fl if fl is not None else files())


def write(scenario, step, data):
    d = os.path.join(OUT, scenario)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, f'{step}.json'), 'w') as f:
        json.dump(data, f, indent=1)


B, A = IMG['base'], IMG['alt']
OUR = [dict(letter='E', serial=SERIAL)]

# ---------------------------------------------------------------- normal full run
cur = lambda img, seq, **kw: rec('cur', img, seq, **kw)
last = lambda img, seq, **kw: rec('last', img, seq, **kw)
old_incs = [inc_h(B, 3)]  # something left from an earlier run, to be read out and cleared in step 0

write('normal', 'pre', scen(['app'], [ex('', dump(B, cur(B, 10), old_incs))]))
write('normal', 'flash-base', scen(['app', 'boot', 'app'],
      [ex('b', dump(B, cur(B, 10), old_incs, extra="[calib-io] sent 'b' at 00:00:02.100\nZDIAG bootloader rc=0\r\n[calib-io] port lost (gone) at 00:00:02.500\n")),
       ex('', dump(B, cur(B, 11), old_incs, last=last(B, 10, reason=3)))], drives=OUR))
write('normal', '0', scen(['app'],
      [ex('', dump(B, cur(B, 11), old_incs, last=last(B, 10, reason=3))),
       ex('c', dump(B, cur(B, 11), old_incs, last=last(B, 10, reason=3), extra="[calib-io] sent 'c' at 00:00:02.100\nZDIAG ring cleared\r\n")),
       ex('', dump(B, cur(B, 11), [], last=last(B, 10, reason=3)))]))
write('normal', '1', scen(['app'],
      [ex('', dump(B, cur(B, 11, probes=(30, 30), feeds=28), [], last=last(B, 10, reason=3))),
       ex('', dump(B, cur(B, 11, probes=(33, 33), feeds=31), [], last=last(B, 10, reason=3)))]))
i0 = inc_h(B, 11)
write('normal', '2', scen(['app', 'none', 'app'],
      [ex('', dump(B, cur(B, 11), [], last=last(B, 10, reason=3))),
       ex('h', dump(B, cur(B, 11), [], last=last(B, 10, reason=3), extra=reply('h', lost=True))),
       ex('', dump(B, cur(B, 12), [i0], last=last(B, 11, reason=2, calib='h')))]))
write('normal', '4', scen(['app'],
      [ex('', dump(B, cur(B, 12, feeds=40), [i0], last=last(B, 11, reason=2, calib='h'))),
       ex('H', dump(B, cur(B, 12, feeds=40), [i0], last=last(B, 11, reason=2, calib='h'), extra=reply('H', returned=True))),
       ex('', dump(B, cur(B, 12, feeds=56, calib='H'), [i0], last=last(B, 11, reason=2, calib='h')))]))
i1 = inc_G(B, 12)
write('normal', '5', scen(['app', 'none', 'app'],
      [ex('', dump(B, cur(B, 12, calib='H'), [i0], last=last(B, 11, reason=2, calib='h'))),
       ex('G', dump(B, cur(B, 12, calib='H'), [i0], last=last(B, 11, reason=2, calib='h'), extra=reply('G', lost=True))),
       ex('', dump(B, cur(B, 13), [i0, i1], last=last(B, 12, reason=2, calib='G')))]))
i2 = inc_S(B, 14)
write('normal', '6', scen(['app', 'none', 'app'],
      [ex('', dump(B, cur(B, 13), [i0, i1], last=last(B, 12, reason=2, calib='G'))),
       ex('S', dump(B, cur(B, 13), [i0, i1], last=last(B, 12, reason=2, calib='G'), extra=reply('S', returned=True))),
       ex('r', dump(B, cur(B, 13, calib='S'), [i0, i1], last=last(B, 12, reason=2, calib='G'), extra="[calib-io] sent 'r' at 00:00:02.100\nZDIAG reboot\r\n[calib-io] port lost (gone) at 00:00:02.400\n")),
       ex('', dump(B, cur(B, 15), [i0, i1, i2], last=last(B, 14, done=0, reason=1, calib='S', stage=6)))]))
i3 = inc_S(A, 16)
write('normal', '7', scen(['app', 'boot', 'app'],
      [ex('', dump(B, cur(B, 15), [i0, i1, i2], last=last(B, 14, done=0, reason=1, calib='S', stage=6))),
       ex('S', dump(B, cur(B, 15), [i0, i1, i2], last=last(B, 14, done=0, reason=1, calib='S', stage=6), extra=reply('S', returned=True))),
       ex('b', dump(B, cur(B, 15, calib='S'), [i0, i1, i2], last=last(B, 14, done=0, reason=1, calib='S', stage=6), extra="[calib-io] sent 'b' at 00:00:02.100\nZDIAG bootloader rc=0\r\n[calib-io] port lost (gone) at 00:00:02.500\n")),
       ex('', dump(A, cur(A, 17), [i0, i1, i2, i3], last=last(A, 16, done=0, reason=1, calib='S', stage=6)))], drives=OUR))
write('normal', '8', scen(['app'],
      [ex('', dump(A, cur(A, 17), [i0, i1, i2, i3], last=last(A, 16, done=0, reason=1, calib='S', stage=6))),
       ex('c', dump(A, cur(A, 17), [i0, i1, i2, i3], last=last(A, 16, done=0, reason=1, calib='S', stage=6), extra="[calib-io] sent 'c' at 00:00:02.100\nZDIAG ring cleared\r\n")),
       ex('', dump(A, cur(A, 17), [], last=last(A, 16, done=0, reason=1, calib='S', stage=6)))]))
PROD = '[calib-io] opened COM5 at 00:00:00.000\nZDIAG begin version=prof1 up_ms=6690 boot=1 reset=0x2\r\nZDIAG now count host_conn=0 host_disc=0 split_conn=1 split_disc=0\r\nZDIAG end\r\n\n[calib-io] dump complete at 00:00:02.000\n'
write('normal', 'flash-prod', scen(['app', 'boot', 'app'],
      [ex('b', dump(A, cur(A, 17), [], extra="[calib-io] sent 'b' at 00:00:02.100\nZDIAG bootloader rc=0\r\n[calib-io] port lost (gone) at 00:00:02.500\n")),
       ex('', PROD)], drives=OUR))

# ---------------------------------------------------------------- abnormal cases (one step each)
# B. a #TRUNC line in the dump of step 0 -> FAIL before 'c'
write('trunc', '0', scen(['app'], [ex('', dump(B, cur(B, 11), old_incs, trunc=True)),
                                   ex('c', 'should not be sent')]))
# C1. dump without ZDIAG end
write('missing-end', '1', scen(['app'], [ex('', dump(B, cur(B, 11), [], no_end=True)), ex('', dump(B, cur(B, 11), [], no_end=True))]))
# C2. required field missing (cur us2 line absent) -> abort, no default
write('missing-field', '1', scen(['app'], [ex('', dump(B, cur(B, 11), [], drop_line='ZBOOT cur us2')),
                                           ex('', dump(B, cur(B, 11), [], drop_line='ZBOOT cur us2'))]))
# C3. no dump at all (helper reports an error), twice
NODUMP = '[calib-io] error on COM5 (Access to the port is denied) at 00:00:00.100\n[calib-io] closing at 00:00:00.200\n'
write('no-dump', '1', scen(['app'], [ex('', NODUMP, exit_code=1, stderr='diagio: access denied'), ex('', NODUMP, exit_code=1)]))
# D. reset finished before the parent looked: no port-lost marker, USB already app, but seq +1 and the incident filed
write('early-reset', '2', scen(['app', 'app', 'app'],
      [ex('', dump(B, cur(B, 11), [], last=last(B, 10, reason=3))),
       ex('h', dump(B, cur(B, 11), [], last=last(B, 10, reason=3), extra=reply('h', lost=False))),
       ex('', dump(B, cur(B, 12), [i0], last=last(B, 11, reason=2, calib='h')))]))
# D2. no reset at all after 'h': seq unchanged, no incident -> FAIL
write('no-reset', '2', scen(['app', 'app', 'app'],
      [ex('', dump(B, cur(B, 11), [], last=last(B, 10, reason=3))),
       ex('h', dump(B, cur(B, 11), [], last=last(B, 10, reason=3), extra=reply('h', lost=False))),
       ex('', dump(B, cur(B, 11, calib='h'), [], last=last(B, 10, reason=3)))]))
# E1. the only UF2 drive belongs to another serial -> no copy
step7_pre = [ex('', dump(B, cur(B, 15), [i0, i1, i2], last=last(B, 14, done=0, reason=1, calib='S', stage=6))),
             ex('S', dump(B, cur(B, 15), [i0, i1, i2], last=last(B, 14, done=0, reason=1, calib='S', stage=6), extra=reply('S', returned=True))),
             ex('b', dump(B, cur(B, 15, calib='S'), [i0, i1, i2], last=last(B, 14, done=0, reason=1, calib='S', stage=6), extra="[calib-io] sent 'b' at 00:00:02.100\nZDIAG bootloader rc=0\r\n[calib-io] port lost (gone) at 00:00:02.500\n"))]
write('foreign-uf2', '7', scen(['app', 'boot'], step7_pre, drives=[dict(letter='F', serial='DEADBEEF00000001')]))
# E2. our drive plus a foreign one (two bootloaders) -> no copy
write('two-uf2', '7', scen(['app', 'boot'], step7_pre, drives=OUR + [dict(letter='F', serial='DEADBEEF00000001')]))
# F. copy fails
write('copy-fail', '7', scen(['app', 'boot'], step7_pre, drives=OUR, copy='fail'))
# F2. copy "succeeds" but the drive never vanishes (image not taken)
write('copy-not-taken', '7', scen(['app', 'boot'], step7_pre, drives=OUR, vanish=False))
# G. production file missing / md5 mismatch -> preflight FAIL, nothing touched
write('prod-missing', 'pre', scen(['app'], [ex('', dump(B, cur(B, 10)))], fl={p: m for k, (p, m) in FILES.items() if k != 'prod'}))
write('prod-md5', 'pre', scen(['app'], [ex('', dump(B, cur(B, 10)))], fl=files(**{FILES['prod'][0]: '00000000000000000000000000000000'})))
write('prod-md5', 'flash-prod', scen(['app'], [ex('b', 'should not be sent')], drives=OUR, fl=files(**{FILES['prod'][0]: '00000000000000000000000000000000'})))
# H. after the flash, an existing incident keeps its tag but another field changed -> FAIL on verbatim comparison
i1_changed = [l.replace('pc=0x662ec', 'pc=0x662e0') for l in i1]
write('inc-changed', '7', scen(['app', 'boot', 'app'], step7_pre +
      [ex('', dump(A, cur(A, 17), [i0, i1_changed, i2, i3], last=last(A, 16, done=0, reason=1, calib='S', stage=6)))], drives=OUR))
# H2. an existing incident lost one line after the flash
i2_short = i2[:-1]
write('inc-missing-line', '7', scen(['app', 'boot', 'app'], step7_pre +
      [ex('', dump(A, cur(A, 17), [i0, i1, i2_short, i3], last=last(A, 16, done=0, reason=1, calib='S', stage=6)))], drives=OUR))
# I. restore: the device answers but still with ZBOOT lines (the production image did not take)
write('prod-still-test', 'flash-prod', scen(['app', 'boot', 'app'],
      [ex('b', dump(A, cur(A, 17), [], extra="[calib-io] sent 'b' at 00:00:02.100\nZDIAG bootloader rc=0\r\n")),
       ex('', dump(A, cur(A, 18), []))], drives=OUR))
print('scenarios written to', OUT)
