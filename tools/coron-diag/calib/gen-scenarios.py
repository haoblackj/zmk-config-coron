#!/usr/bin/env python3
"""Mock scenarios for the calibration scripts (review #8 point 8, review #9 point 6).

Writes <out>/<scenario>/<step>.json (pre, flash-base, 0,1,2,4,5,6,7,8, flash-prod) that the
scripts replay in mock mode, plus <out>/<scenario>/expect.json with the expected outcome of a
FULL run through calib-all.ps1: its exit code, the per-step results line, and regexes that must
(or must not) appear in the logs. calib-sim.py runs every scenario and compares.

Each exchange is what the DEVICE emits (pre = before the command, post = after it; no
"[calib-io]" stamps: the real calib-io.ps1 child produces those from a canned port). The dump
texts follow diag_boot.c v4's print_rec/diag_boot_print format exactly (line names
a/b/entry1/entry2/us1/us2/fire1..4).
"""
import argparse, json, os, copy

SERIAL = 'B17318CDBE9A61B1'
# instance ids as read on the real PC (2026-10-08): the diag console interface, the Studio RPC
# UART interface of the production image, and the UF2 disk of the bootloader
CONSOLE = dict(com='COM5', id='USB\\VID_1D50&PID_615E&MI_00\\9&168EB68&4&0000')
STUDIO = dict(com='COM7', id='USB\\VID_1D50&PID_615E&MI_03\\9&168EB68&4&0003')
UF2_ID = 'USBSTOR\\DISK&VEN_ADAFRUIT&PROD_NRF_UF2&REV_1.0\\A&258725EA&0&{}&0'
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
# the production image (2725423): diag console without the boot instrument -> no ZBOOT line
PROD = ('ZDIAG begin version=prof1 up_ms=6690 boot=1 reset=0x2\r\n'
        'ZDIAG now count host_conn=0 host_disc=0 split_conn=1 split_disc=0\r\nZDIAG end\r\n')
PROD_TRUNC = ('ZDIAG begin version=prof1 up_ms=6690 boot=1 reset=0x2\r\n'
              'ZDIAG now count host_conn=0 host_disc=0 split_co #TRUNC\r\nZDIAG end\r\n')
BOOTLOADER = 'ZDIAG bootloader rc=0\r\n'


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


def inc_abort(img, seq):   # boot interrupted (boot_done=0) without a requested reboot: filed by is_incident(), no firing -> no fire line
    return rec('INC', img, seq, done=0, reason=0, calib='-', stage=5, probes=(0, 0), feeds=0, loops=0, usb=0, running=0)


def dump(img, cur, incs=(), last=None, count=None, dropped=0, invalid=0, reinit=0, calib_live=0, trunc=False,
         no_end=False, drop_line=None, end_text='ZDIAG end'):
    """A full console dump as the device emits it: ZDIAG begin, ZBOOT lines, ZDIAG end."""
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
        out.append(end_text)
    return '\r\n'.join(out) + '\r\n'


def reply(send, rc=0, returned=False):
    s = f'ZDIAG calibrate {send} rc={rc}\r\n'
    if returned:
        s += f'ZDIAG calibrate {send} returned\r\n'
    return s


def ex(send, pre, post='', lost=False, hang_s=0, open_error='', stderr='', io_timeout_s=None):
    # a test image (ZBOOT lines) has no line control and dumps only on 'd'; the production image dumps on DTR
    e = dict(send=send, pre=pre, post=post, lost=lost, dump_on_request=('ZBOOT' in pre))
    if hang_s:
        e['hang_s'] = hang_s
    if open_error:
        e['open_error'] = open_error
    if stderr:
        e['stderr'] = stderr
    if io_timeout_s:
        e['io_timeout_s'] = io_timeout_s
    return e


def files(**override):
    f = {p: m for p, m in FILES.values()}
    f.update(override)
    return f


def scen(states, exchanges, drives=None, copy='ok', vanish=True, fl=None, ports=None, **extra):
    d = dict(states=states, exchanges=exchanges, ports=ports if ports is not None else [CONSOLE],
             uf2=dict(drives=drives if drives is not None else [], copy=copy, vanish=vanish),
             files=fl if fl is not None else files())
    d.update(extra)
    return d


B, A = IMG['base'], IMG['alt']
OUR = [dict(letter='E', pnp=UF2_ID.format(SERIAL))]
cur = lambda img, seq, **kw: rec('cur', img, seq, **kw)
last = lambda img, seq, **kw: rec('last', img, seq, **kw)
STEPS = ['pre', 'flash-base', '0', '1', '2', '4', '5', '6', '7', '8', 'flash-prod']


def normal(from_prod=True, leftover=None):
    """The whole run. from_prod: the device starts on the production image (no ZBOOT line), as
    on the real device; otherwise on a test image with a leftover incident to read out and clear."""
    s = {}
    if from_prod:
        first = PROD
        old = []
    else:
        old = leftover if leftover is not None else [inc_h(B, 3)]
        first = dump(B, cur(B, 9), old)
    s['pre'] = scen(['app'], [ex('', first)])
    s['flash-base'] = scen(['app', 'boot', 'app'],
                           [ex('b', first, post=BOOTLOADER, lost=True),
                            ex('', dump(B, cur(B, 10, reinit=0 if old else 1), old, last=last(B, 9, reason=3) if old else None))],
                           drives=OUR)
    d0 = dump(B, cur(B, 10), old, last=last(B, 9, reason=3) if old else None)
    d0c = dump(B, cur(B, 10), [], last=last(B, 9, reason=3) if old else None)
    s['0'] = scen(['app'], [ex('', d0), ex('c', d0, post='ZDIAG ring cleared\r\n'), ex('', d0c)])
    s['1'] = scen(['app'], [ex('', dump(B, cur(B, 10, probes=(30, 30), feeds=28), [])),
                            ex('', dump(B, cur(B, 10, probes=(33, 33), feeds=31), []))])
    i0 = inc_h(B, 10)
    d = dump(B, cur(B, 10), [])
    s['2'] = scen(['app', 'none', 'app'],
                  [ex('', d), ex('h', d, post=reply('h'), lost=True),
                   ex('', dump(B, cur(B, 11), [i0], last=last(B, 10, reason=2, calib='h')))])
    d = dump(B, cur(B, 11, feeds=40), [i0], last=last(B, 10, reason=2, calib='h'))
    s['4'] = scen(['app'],
                  [ex('', d), ex('H', d, post=reply('H', returned=True)),
                   ex('', dump(B, cur(B, 11, feeds=56, calib='H'), [i0], last=last(B, 10, reason=2, calib='h')))])
    i1 = inc_G(B, 11)
    d = dump(B, cur(B, 11, calib='H'), [i0], last=last(B, 10, reason=2, calib='h'))
    s['5'] = scen(['app', 'none', 'app'],
                  [ex('', d), ex('G', d, post=reply('G'), lost=True),
                   ex('', dump(B, cur(B, 12), [i0, i1], last=last(B, 11, reason=2, calib='G')))])
    i2 = inc_S(B, 13)
    d = dump(B, cur(B, 12), [i0, i1], last=last(B, 11, reason=2, calib='G'))
    dS = dump(B, cur(B, 12, calib='S'), [i0, i1], last=last(B, 11, reason=2, calib='G'))
    s['6'] = scen(['app', 'none', 'app'],
                  [ex('', d), ex('S', d, post=reply('S', returned=True)),
                   ex('r', dS, post='ZDIAG reboot\r\n', lost=True),
                   ex('', dump(B, cur(B, 14), [i0, i1, i2], last=last(B, 13, done=0, reason=1, calib='S', stage=6)))])
    i3 = inc_S(A, 15)
    d = dump(B, cur(B, 14), [i0, i1, i2], last=last(B, 13, done=0, reason=1, calib='S', stage=6))
    dS = dump(B, cur(B, 14, calib='S'), [i0, i1, i2], last=last(B, 13, done=0, reason=1, calib='S', stage=6))
    after7 = dump(A, cur(A, 16), [i0, i1, i2, i3], last=last(A, 15, done=0, reason=1, calib='S', stage=6))
    s['7'] = scen(['app', 'boot', 'app'],
                  [ex('', d), ex('S', d, post=reply('S', returned=True)),
                   ex('b', dS, post=BOOTLOADER, lost=True), ex('', after7)], drives=OUR)
    s['8'] = scen(['app'], [ex('', after7), ex('c', after7, post='ZDIAG ring cleared\r\n'),
                            ex('', dump(A, cur(A, 16), [], last=last(A, 15, done=0, reason=1, calib='S', stage=6)))])
    d8 = dump(A, cur(A, 16), [], last=last(A, 15, done=0, reason=1, calib='S', stage=6))
    s['flash-prod'] = scen(['app', 'boot', 'app'], [ex('b', d8, post=BOOTLOADER, lost=True), ex('', PROD)], drives=OUR)
    s['_incs'] = dict(i0=i0, i1=i1, i2=i2, i3=i3, d=d, dS=dS, after7=after7, d0=d0)
    return s


def results(**over):
    """Expected per-step results line of calib-all.ps1 (keys in its order)."""
    r = {'pre': '0', 'flash-base': '0', '0': '0', '1': '0', '2': '0', '3': '2', '4': '0', '5': '0', '6': '0', '7': '0', '8': '0', 'restore': '0'}
    r.update(over)
    return r


def stopped_after(step, **over):
    """Calibration stopped at <step>: later steps not run, restore still run."""
    order = ['pre', 'flash-base', '0', '1', '2', '3', '4', '5', '6', '7', '8']
    r = results()
    i = order.index(step)
    r[step] = over.pop(step, '1')
    for k in order[i + 1:]:
        r[k] = 'not-run'
    if step == 'pre':
        del r['flash-base']
    r.update(over)
    return r


def expect(exit_code, res, must=(), must_not=()):
    return dict(exit=exit_code, results=res, must=list(must), must_not=list(must_not))


def step_log(step):
    return f'step{step}-*.log' if step not in ('flash-base', 'flash-prod') else f'{step}-*.log'


def in_file(glob, regex):
    return dict(glob=glob, re=regex)


SCENARIOS = {}


def add(name, steps, exp, drop=(), raw=None):
    SCENARIOS[name] = dict(steps={k: v for k, v in steps.items() if not k.startswith('_') and k not in drop},
                           expect=exp, raw=raw or {})


# ------------------------------------------------------------------ normal runs
N = normal(True)
add('normal', N, expect(0, results(),
                        must=[in_file('steppre-*.log', 'no ZBOOT line'), in_file('step0-*.log', "sent 'd' \\(dump request"), in_file('flash-prod-*.log', 'ZDIAG begin version=prof1'),
                              r"DEVICE-OP copy \(mock\)", 'CALIBRATION PASS', in_file('step2-*.log', 'reset observed directly'), in_file('step2-*.log', 'inc0 evidence: ZBOOT inc0 fire4')],
                        must_not=['NOT sent', 'timed out', ' #TRUNC\\s*$', in_file('steppre-*.log', "sent 'd'"), in_file('flash-prod-*-io2.out', "sent 'd'")]))
NT = normal(False)
add('normal-from-test', NT, expect(0, results(), must=[in_file('steppre-*.log', 'saved ZBOOT inc0 fire4'), in_file('step0-*.log', 'saved ZBOOT inc0 a ')],
                                   must_not=['NOT sent', 'timed out']))

# ------------------------------------------------------------------ dump / read failures
I = N['_incs']


def variant(step, scn):
    s = {k: v for k, v in N.items() if not k.startswith('_')}
    s[step] = scn
    return s


d0 = I['d0']
# first read of step 0 has a #TRUNC line -> FAIL before 'c'
add('trunc', variant('0', scen(['app'], [ex('', dump(B, cur(B, 10), [], trunc=True)), ex('c', d0, post='ZDIAG ring cleared\r\n')])),
    expect(1, stopped_after('0'), must=[in_file('step0-*.log', "STOPPED before: send 'c'"), 'no #TRUNC line \\(trunc'],
           must_not=[in_file('step0-*.log', "sent 'c'")]))
# send gate in the child: the first read is fine, the dump read just before the command is broken
add('gate-c', variant('0', scen(['app'], [ex('', d0), ex('c', dump(B, cur(B, 10), [], trunc=True), post='ZDIAG ring cleared\r\n')])),
    expect(1, stopped_after('0'), must=[in_file('step0-*.log', "NOT sent 'c': the dump before it has a #TRUNC line"), in_file('step0-*.log', "STOPPED before: send 'c'")],
           must_not=[in_file('step0-*.log', "\\[calib-io\\] sent 'c'")]))
d = dump(B, cur(B, 10), [])
add('gate-h', variant('2', scen(['app', 'app'], [ex('', d), ex('h', dump(B, cur(B, 10), [], no_end=True), post=reply('h'), lost=True)])),
    expect(1, stopped_after('2'), must=[in_file('step2-*.log', "NOT sent 'h': the dump before it is incomplete"), in_file('step2-*.log', "STOPPED before: send 'h'")],
           must_not=[in_file('step2-*.log', "\\[calib-io\\] sent 'h'")]))
d6 = N['6']['exchanges'][0]['pre']
add('gate-r', variant('6', scen(['app', 'app'], [ex('', d6), ex('S', d6, post=reply('S', returned=True)),
                                                 ex('r', dump(B, cur(B, 12, calib='S'), [I['i0'], I['i1']], last=last(B, 11, reason=2, calib='G'), trunc=True), post='ZDIAG reboot\r\n', lost=True)])),
    expect(1, stopped_after('6'), must=[in_file('step6-*.log', "\\[calib-io\\] sent 'S'"), in_file('step6-*.log', "NOT sent 'r'"), in_file('step6-*.log', "STOPPED before: send 'r'")],
           must_not=[in_file('step6-*.log', "\\[calib-io\\] sent 'r'")]))
d7 = N['7']['exchanges'][0]['pre']
add('gate-b', variant('7', scen(['app', 'app'], [ex('', d7), ex('S', d7, post=reply('S', returned=True)),
                                                 ex('b', dump(B, cur(B, 14, calib='S'), [I['i0'], I['i1'], I['i2']], last=last(B, 13, done=0, reason=1, calib='S', stage=6), no_end=True), post=BOOTLOADER, lost=True)], drives=OUR)),
    expect(1, stopped_after('7'), must=[in_file('step7-*.log', "NOT sent 'b'"), in_file('step7-*.log', "STOPPED before: send 'b'")],
           must_not=[in_file('step7-*.log', "\\[calib-io\\] sent 'b'"), in_file('step7-*.log', 'DEVICE-OP copy')]))
d1 = dump(B, cur(B, 10), [])
add('missing-end', variant('1', scen(['app'], [ex('', dump(B, cur(B, 10), [], no_end=True)), ex('', dump(B, cur(B, 10), [], no_end=True))])),
    expect(1, stopped_after('1'), must=[in_file('step1-*.log', 'dump incomplete \\(no end mark'), in_file('step1-*.log', 'FAIL read 1:dump complete')]))
add('missing-field', variant('1', scen(['app'], [ex('', dump(B, cur(B, 10), [], drop_line='ZBOOT cur us2')), ex('', dump(B, cur(B, 10), [], drop_line='ZBOOT cur us2'))])),
    expect(1, stopped_after('1'), must=[in_file('step1-*.log', 'FAIL read 1:cur us2 line present')]))
add('no-dump', variant('1', scen(['app'], [ex('', '', open_error='Access to the port is denied', stderr='diagio: access denied'),
                                           ex('', '', open_error='Access to the port is denied')])),
    expect(1, stopped_after('1'), must=[in_file('step1-*.log', '\\[stderr\\] diagio: access denied'), in_file('step1-*.log', 'exit=1'), in_file('step1-*.log', 'FAIL read 1:dump present')]))
# ring says count=1 but the incident record is absent -> FAIL before 'c' (review #9, point 4)
add('ring-count-mismatch', variant('0', scen(['app'], [ex('', dump(B, cur(B, 10), [], count=1)), ex('c', d0, post='ZDIAG ring cleared\r\n')])),
    expect(1, stopped_after('0'), must=[in_file('step0-*.log', 'FAIL before clear:inc0 present'), in_file('step0-*.log', "STOPPED before: send 'c'")],
           must_not=[in_file('step0-*.log', "sent 'c'")]))
# the new incident lacks its register lines (fire3/fire4)
i0_noregs = I['i0'][:-2]
add('inc-no-regs', variant('2', scen(['app', 'none', 'app'], [ex('', d), ex('h', d, post=reply('h'), lost=True),
                                                              ex('', dump(B, cur(B, 11), [i0_noregs], last=last(B, 10, reason=2, calib='h')))])),
    expect(1, stopped_after('2'), must=[in_file('step2-*.log', 'FAIL after h:inc0 fire1\\.\\.fire4 \\(exception frame, registers, USBD, clocks\\) present')]))

# ------------------------------------------------------------------ reset observation
add('early-reset', variant('2', scen(['app', 'app', 'app'], [ex('', d), ex('h', d, post=reply('h'), lost=False),
                                                             ex('', dump(B, cur(B, 11), [I['i0']], last=last(B, 10, reason=2, calib='h')))])),
    expect(0, results(), must=[in_file('step2-*.log', 'NOTE reset NOT observed directly')]))
add('no-reset', variant('2', scen(['app', 'app', 'app'], [ex('', d), ex('h', d, post=reply('h'), lost=False),
                                                          ex('', dump(B, cur(B, 10, calib='h'), []))])),
    expect(1, stopped_after('2'), must=[in_file('step2-*.log', 'FAIL boot number advanced by 1'), in_file('step2-*.log', 'FAIL inc0 present')]))

# ------------------------------------------------------------------ UF2 drive / copy
step7_pre = [ex('', d7), ex('S', d7, post=reply('S', returned=True)), ex('b', I['dS'], post=BOOTLOADER, lost=True)]
FOREIGN = [dict(letter='F', pnp=UF2_ID.format('DEADBEEF00000001'))]
add('foreign-uf2', variant('7', scen(['app', 'boot'], step7_pre, drives=FOREIGN)),
    expect(1, stopped_after('7'), must=[in_file('step7-*.log', 'STOPPED before: copy the alt image')], must_not=[in_file('step7-*.log', 'DEVICE-OP copy')]))
add('two-uf2', variant('7', scen(['app', 'boot'], step7_pre, drives=OUR + FOREIGN)),
    expect(1, stopped_after('7'), must=[in_file('step7-*.log', 'STOPPED before: copy the alt image')], must_not=[in_file('step7-*.log', 'DEVICE-OP copy')]))
add('copy-fail', variant('7', scen(['app', 'boot'], step7_pre, drives=OUR, copy='fail')),
    expect(1, stopped_after('7'), must=[in_file('step7-*.log', 'copy error \\(mock\\)'), in_file('step7-*.log', 'FAIL copy raised no error')]))
add('copy-not-taken', variant('7', scen(['app', 'boot'], step7_pre, drives=OUR, vanish=False)),
    expect(1, stopped_after('7'), must=[in_file('step7-*.log', 'FAIL UF2 drive vanished')]))

# ------------------------------------------------------------------ production image file
NO_PROD = {p: m for k, (p, m) in FILES.items() if k != 'prod'}
BAD_PROD = files(**{FILES['prod'][0]: '00000000000000000000000000000000'})
pm = {k: v for k, v in N.items() if not k.startswith('_')}
for k in pm:
    pm[k] = dict(pm[k], files=NO_PROD)
add('prod-missing', pm, expect(3, stopped_after('pre', restore='1'),
                               must=[in_file('steppre-*.log', 'STOPPED before: nothing \\(preflight'), in_file('flash-prod-*.log', 'FAIL prod image exists')],
                               must_not=['DEVICE-OP', "\\[calib-io\\] sent", '\\[calib-io\\] opened']))
pm = {k: v for k, v in N.items() if not k.startswith('_')}
for k in pm:
    pm[k] = dict(pm[k], files=BAD_PROD)
add('prod-md5', pm, expect(3, stopped_after('pre', restore='1'),
                           must=[in_file('steppre-*.log', 'FAIL production image md5'), in_file('flash-prod-*.log', 'FAIL prod image md5')],
                           must_not=['DEVICE-OP', "\\[calib-io\\] sent", '\\[calib-io\\] opened']))

# ------------------------------------------------------------------ retention across the flash (step 7)
def after7_with(incs):
    return dump(A, cur(A, 16), incs, last=last(A, 15, done=0, reason=1, calib='S', stage=6))


i1_changed = [l.replace('pc=0x662ec', 'pc=0x662e0') for l in I['i1']]
add('inc-changed', variant('7', scen(['app', 'boot', 'app'], step7_pre + [ex('', after7_with([I['i0'], i1_changed, I['i2'], I['i3']]))], drives=OUR)),
    expect(1, stopped_after('7'), must=[in_file('step7-*.log', 'FAIL inc1 kept verbatim')]))
add('inc-missing-line', variant('7', scen(['app', 'boot', 'app'], step7_pre + [ex('', after7_with([I['i0'], I['i1'], I['i2'][:-1], I['i3']]))], drives=OUR)),
    expect(1, stopped_after('7'), must=[in_file('step7-*.log', 'FAIL after flash:inc2 fire1\\.\\.fire4')]))
i0_upper = [l.replace('calib=h', 'calib=H') for l in I['i0']]
add('inc-case', variant('7', scen(['app', 'boot', 'app'], step7_pre + [ex('', after7_with([i0_upper, I['i1'], I['i2'], I['i3']]))], drives=OUR)),
    expect(1, stopped_after('7'), must=[in_file('step7-*.log', 'FAIL inc0 kept verbatim')]))

# ------------------------------------------------------------------ restore
d8 = N['flash-prod']['exchanges'][0]['pre']
add('prod-still-test', variant('flash-prod', scen(['app', 'boot', 'app'], [ex('b', d8, post=BOOTLOADER, lost=True), ex('', dump(A, cur(A, 17), []))], drives=OUR)),
    expect(2, results(restore='1'), must=[in_file('flash-prod-*.log', 'FAIL no ZBOOT line')]))

# ------------------------------------------------------------------ mock files (review #9, point 1)
add('mock-missing', N, expect(4, {}, must=['MOCK FILE MISSING/INVALID: flash-prod.json missing'], must_not=['STEP pre start', 'FLASH', 'DEVICE-OP', '\\[calib-io\\]']), drop=('flash-prod',))
add('mock-badjson', N, expect(4, {}, must=['MOCK FILE MISSING/INVALID: flash-base.json invalid'], must_not=['STEP pre start', 'FLASH', 'DEVICE-OP', '\\[calib-io\\]']),
    drop=('flash-base',), raw={'flash-base.json': '{ this is not json'})

# ------------------------------------------------------------------ hangs (review #9, point 5)
add('io-hang', variant('1', scen(['app'], [ex('', d1, hang_s=60, io_timeout_s=3), ex('', d1, hang_s=60, io_timeout_s=3)])),
    expect(1, stopped_after('1'), must=[in_file('step1-*.log', 'FAIL console child returned within 3s \\(timed out; killed'), in_file('step1-*.log', 'timed_out=True')]))
add('step-hang', variant('4', dict(N['4'], step_hang_s=60, step_timeout_s=8)),
    expect(1, stopped_after('4', **{'4': 'TIMEOUT'}), must=['4 did not return within 8s: killed with its process tree', 'step 4 rc=TIMEOUT', 'restore PASS']))
add('restore-hang', variant('flash-prod', dict(N['flash-prod'], step_hang_s=60, step_timeout_s=8)),
    expect(2, results(restore='TIMEOUT'), must=['flash-prod did not return within 8s', 'CALIBRATION PASS .* \\| RESTORE FAIL']))


# ------------------------------------------------------------------ review #10
# 1. an incident filed for an interrupted boot (done=0, reason=0, no fire line) is read and saved
NA = normal(False, leftover=[inc_abort(B, 3)])
add('inc-boot-abort', NA, expect(0, results(), must=[in_file('steppre-*.log', 'saved ZBOOT inc0 us2'), in_file('steppre-*.log', 'inc0 reason=0 \\(boot interrupted without the net firing\\): fire lines not required'),
                                                in_file('step0-*.log', 'saved ZBOOT inc0 a seq=3 .* done=0 reason=0')],
                            must_not=[in_file('steppre-*.log', 'saved ZBOOT inc0 fire'), in_file('step0-*.log', 'saved ZBOOT inc0 fire'), 'NOT sent', 'timed out']))
# 1b. a partial set of fire lines is rejected whatever the reason
i_partial = inc_abort(B, 3) + inc_h(B, 3)[6:8]
add('inc-partial-fire', variant('0', scen(['app'], [ex('', dump(B, cur(B, 10), [i_partial])), ex('c', d0, post='ZDIAG ring cleared\r\n')])),
    expect(1, stopped_after('0'), must=[in_file('step0-*.log', 'FAIL before clear:inc0 fire lines all-or-none')], must_not=[in_file('step0-*.log', "sent 'c'")]))
# 2. the end mark is a whole line: 'ZDIAG endBROKEN' is not one, so the child must not send
add('gate-endbroken', variant('0', scen(['app'], [ex('', d0), ex('c', dump(B, cur(B, 10), [], end_text='ZDIAG endBROKEN'), post='ZDIAG ring cleared\r\n')])),
    expect(1, stopped_after('0'), must=[in_file('step0-*.log', "NOT sent 'c': the dump before it is incomplete"), in_file('step0-*.log', 'ZDIAG endBROKEN')],
           must_not=[in_file('step0-*.log', "\\[calib-io\\] sent 'c'")]))
# 2b. the production restore dump has a #TRUNC line -> restore FAIL
add('prod-trunc', variant('flash-prod', scen(['app', 'boot', 'app'], [ex('b', d8, post=BOOTLOADER, lost=True), ex('', PROD_TRUNC)], drives=OUR)),
    expect(2, results(restore='1'), must=[in_file('flash-prod-*.log', 'FAIL after flash:no #TRUNC line')]))
# 3. termination of a timed-out child must be confirmed before any further device operation
add('kill-fail', variant('1', dict(scen(['app'], [ex('', d1, hang_s=60, io_timeout_s=3), ex('', d1, hang_s=60, io_timeout_s=3)]), kill_mode='fail')),
    expect(3, stopped_after('1', **{'1': '5', 'restore': 'not-attempted'}),
           must=[in_file('step1-*.log', 'kill: taskkill rc=1'), in_file('step1-*.log', 'termination confirmed=False'), in_file('step1-*.log', 'termination NOT confirmed, pids still alive'),
                 in_file('step1-*.log', 'exit 5'), 'reports a console child it could not confirm dead', 'RESTORE NOT ATTEMPTED', 'NOT restored to the production image'],
           must_not=['FLASH prod start', in_file('flash-prod-*.log', '.')]))
add('kill-linger', variant('4', dict(N['4'], step_hang_s=60, step_timeout_s=8, kill_mode='linger')),
    expect(3, stopped_after('4', **{'4': 'TIMEOUT-ALIVE', 'restore': 'not-attempted'}),
           must=['kill: taskkill rc=0: \\(mock\\) taskkill NOT invoked', 'termination confirmed=False', '4 did not return within 8s: termination NOT confirmed', 'RESTORE NOT ATTEMPTED'],
           must_not=['FLASH prod start', in_file('flash-prod-*.log', '.')]))
# 3b. the step's own console child is hanging when the step's deadline passes: the whole tree is killed and confirmed
add('tree-kill', variant('4', dict(scen(['app'], [ex('', N['4']['exchanges'][0]['pre'], hang_s=60, io_timeout_s=50)]), step_timeout_s=8)),
    expect(1, stopped_after('4', **{'4': 'TIMEOUT'}), must=['kill: tree=\\[\\d+(,\\d+)+\\]', 'kill: taskkill rc=0', 'termination confirmed=True', '4 did not return within 8s: killed with its process tree, termination confirmed', 'restore PASS']))
add('restore-kill-linger', variant('flash-prod', dict(N['flash-prod'], step_hang_s=60, step_timeout_s=8, kill_mode='linger')),
    expect(2, results(restore='TIMEOUT-ALIVE'), must=['restore process not confirmed dead', 'termination confirmed=False', 'CALIBRATION PASS .* \\| RESTORE FAIL']))


# ------------------------------------------------------------------ review #11: the termination itself has a deadline
# the enumeration never returns (helper blocks before the CIM query) -> the orchestrator decides within 20 s
add('kill-enum-hang', variant('4', dict(N['4'], step_hang_s=60, step_timeout_s=8, kill_mode='enum-hang')),
    expect(3, stopped_after('4', **{'4': 'TIMEOUT-ALIVE', 'restore': 'not-attempted'}),
           must=['kill: phase=enumerate', 'termination confirmed=False: kill helper did not return within 20s \\(last phase=enumerate\\)', '4 did not return within 8s: termination NOT confirmed', 'RESTORE NOT ATTEMPTED'],
           must_not=['kill: tree=', 'kill: taskkill rc=', 'FLASH prod start', in_file('flash-prod-*.log', '.')]))
# the termination request never returns (helper blocks instead of taskkill)
add('kill-req-hang', variant('4', dict(N['4'], step_hang_s=60, step_timeout_s=8, kill_mode='kill-hang')),
    expect(3, stopped_after('4', **{'4': 'TIMEOUT-ALIVE', 'restore': 'not-attempted'}),
           must=['kill: tree=\\[\\d+', 'kill: phase=terminate', 'termination confirmed=False: kill helper did not return within 20s \\(last phase=terminate\\)', 'RESTORE NOT ATTEMPTED'],
           must_not=['kill: taskkill rc=', 'FLASH prod start', in_file('flash-prod-*.log', '.')]))
# the same at the exchange level: the console child hangs and the request to terminate it never returns
add('io-kill-req-hang', variant('1', dict(scen(['app'], [ex('', d1, hang_s=60, io_timeout_s=3), ex('', d1, hang_s=60, io_timeout_s=3)]), kill_mode='kill-hang')),
    expect(3, stopped_after('1', **{'1': '5', 'restore': 'not-attempted'}),
           must=[in_file('step1-*.log', 'kill helper did not return within 20s \\(last phase=terminate\\)'), in_file('step1-*.log', 'exit 5'), 'RESTORE NOT ATTEMPTED'],
           must_not=['FLASH prod start', in_file('flash-prod-*.log', '.')]))


# ------------------------------------------------------------------ review #13
# 1. the device exposes the diag console (MI_00) AND the Studio RPC UART (MI_03) on the same serial, as the
#    production image does: nothing may ever be written to, or even opened on, the second port
TP = {k: dict(v, ports=[CONSOLE, STUDIO]) for k, v in N.items() if not k.startswith('_')}
add('two-ports', TP, expect(0, results(), must=['opened COM5', in_file('flash-prod-*.log', "sent 'b'")],
                           must_not=['opened COM7', 'console COM7', "COM7.*sent"]))
# 2. the USBSTOR matcher on partial-serial instance ids: our drive is absent, two near misses are present -> no copy
NEAR = [dict(letter='F', pnp=UF2_ID.format('X' + SERIAL)), dict(letter='G', pnp=UF2_ID.format(SERIAL[:-1]))]
add('uf2-partial-serial', variant('7', scen(['app', 'boot'], step7_pre, drives=NEAR)),
    expect(1, stopped_after('7'), must=[in_file('step7-*.log', 'drives of serial=\\[\\] all uf2 drives=\\[F,G\\]'), in_file('step7-*.log', 'STOPPED before: copy the alt image')],
           must_not=[in_file('step7-*.log', 'DEVICE-OP copy')]))
# 2b. the instance id without the Windows prefix (\<serial>&0) is accepted too
NP = {k: v for k, v in N.items() if not k.startswith('_')}
for k in ('flash-base', '7', 'flash-prod'):
    NP[k] = dict(NP[k], uf2=dict(NP[k]['uf2'], drives=[dict(letter='E', pnp='USBSTOR\\DISK&VEN_ADAFRUIT&PROD_NRF_UF2&REV_1.0\\' + SERIAL + '&0')]))
add('uf2-noprefix', NP, expect(0, results(), must=['drives of serial=\\[E\\]']))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    for name, sc in SCENARIOS.items():
        d = os.path.join(a.out, name)
        os.makedirs(d, exist_ok=True)
        for step, data in sc['steps'].items():
            with open(os.path.join(d, f'{step}.json'), 'w') as f:
                json.dump(data, f, indent=1)
        for fn, text in sc['raw'].items():
            with open(os.path.join(d, fn), 'w') as f:
                f.write(text)
        with open(os.path.join(d, 'expect.json'), 'w') as f:
            json.dump(sc['expect'], f, indent=1)
    print(f'{len(SCENARIOS)} scenarios written to {a.out}')


if __name__ == '__main__':
    main()
