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
         no_end=False, drop_line=None, end_text='ZDIAG end', up_ms=65000, hosts=(1, 0, 1, 0)):
    """A full console dump as the device emits it: ZDIAG begin, ZBOOT lines, ZDIAG end."""
    n = len(incs) if count is None else count
    out = [f'ZDIAG begin version=prof1 up_ms={up_ms} boot=1 reset=0x4',
           f'ZDIAG now count host_conn={hosts[0]} host_disc={hosts[1]} split_conn={hosts[2]} split_disc={hosts[3]}',
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
                            ex('', dump(B, cur(B, 10, reinit=0 if old else 1), old, last=last(B, 9, reason=3) if old else None, reinit=0 if old else 1))],
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


# ================================================================== unattended loop (review #14, #15)
# calib-loop.ps1: pre -> flash-base -> baseline (trial 0) -> trials t1..tn (dwell, then ONE write or ONE
# soft reset, ONE boot) -> restore. Files: pre, flash-base, baseline, t1..tn, flash-prod.
# Firmware consistency (review #15 point 1): ring_reinit_this_boot is one per-boot flag printed in the
# ring header AND in cur: the first boot after the base write has reinit=1 in every dump of that boot
# (seq 1); every later boot has 0.
def ldump(img, seq, incs=(), up_ms=4000, dropped=0, count=None, done=1, reinit=None, probes=(30, 30), feeds=28, lst=None, hosts=(1, 0, 1, 0)):
    ri = (1 if seq == 1 else 0) if reinit is None else reinit
    return dump(img, cur(img, seq, reinit=ri, done=done, probes=probes, feeds=feeds), incs, last=lst, up_ms=up_ms, dropped=dropped, count=count, reinit=ri, hosts=hosts)


def loop_trial(img_now, img_next, seq, dwell, mode='write', incs=(), after_incs=None, after_seq=None, after_reinit=None,
               after_dropped=0, dropped=0, states=None, count=None, after_count=None, end_up_ms=None, end_reinit=None,
               after_done=1, after_reads=1, start_up_ms=4000, **extra):
    """One trial's scenario. seq = boot number at the trial start; the boot after the operation is seq+1."""
    d_before = ldump(img_now, seq, incs, up_ms=start_up_ms, dropped=dropped, count=count)
    e_up = (dwell * 60000 + start_up_ms) if end_up_ms is None else end_up_ms
    d_end = ldump(img_now, seq, incs, up_ms=e_up, dropped=dropped, count=count, probes=(dwell * 30, dwell * 30), feeds=dwell * 29, reinit=end_reinit)
    a_incs = incs if after_incs is None else after_incs
    a_seq = seq + 1 if after_seq is None else after_seq
    d_after = ldump(img_next, a_seq, a_incs, up_ms=5000, dropped=after_dropped, count=after_count, done=after_done, reinit=after_reinit,
                    lst=last(img_now, seq, reason=3, reinit=(1 if seq == 1 else 0)))
    afters = [ex('', d_after)] * after_reads
    if mode == 'write':
        exs = [ex('', d_before), ex('', d_end), ex('b', d_end, post=BOOTLOADER, lost=True)] + afters
        st = ['app'] * (1 + dwell) + ['boot', 'app']
    else:
        exs = [ex('', d_before), ex('', d_end), ex('r', d_end, post='ZDIAG reboot\r\n', lost=True)] + afters
        st = ['app'] * (1 + dwell) + ['none', 'app']
    return scen(states if states is not None else st, exs, drives=OUR, **extra)


def loop_files(dwells=(13, 17, 26), mode='write', trial_override=None, baseline_incs=(), baseline_dropped=0, baseline_count=None, fl=None):
    f = {}
    f['pre'] = scen(['app'], [ex('', PROD)], fl=fl)
    f['flash-base'] = scen(['app', 'boot', 'app'], [ex('b', PROD, post=BOOTLOADER, lost=True),
                                                    ex('', ldump(B, 1, baseline_incs, up_ms=3000, dropped=baseline_dropped, count=baseline_count))], drives=OUR, fl=fl)
    f['baseline'] = scen(['app'], [ex('', ldump(B, 1, baseline_incs, up_ms=9000, dropped=baseline_dropped, count=baseline_count))], fl=fl)
    seq = 1; img = B
    for i, dw in enumerate(dwells, 1):
        nxt = (A if img is B else B) if mode == 'write' else img
        ov = dict((trial_override or {}).get(i, {}))
        f[f't{i}'] = loop_trial(img, nxt, seq, dw, mode=mode, incs=baseline_incs, dropped=baseline_dropped, count=baseline_count,
                                after_dropped=ov.pop('after_dropped', baseline_dropped), fl=fl, start_up_ms=(10000 if i == 1 else 12000), **ov)
        seq += 1; img = nxt
    f['flash-prod'] = scen(['app', 'boot', 'app'], [ex('b', ldump(img, seq, baseline_incs, dropped=baseline_dropped, count=baseline_count), post=BOOTLOADER, lost=True), ex('', PROD)], drives=OUR, fl=fl)
    return f


def loop_results(n, **over):
    r = {'pre': '0', 'flash-base': '0', 'baseline': '0'}
    for i in range(1, n + 1):
        r[f't{i}'] = '0'
    r['restore'] = '0'
    r.update(over)
    return r


def loop_stopped(n, at, rc, stop, **over):
    r = loop_results(n)
    r[f't{at}'] = rc
    for i in range(at + 1, n + 1):
        r[f't{i}'] = 'not-run'
    r['stop'] = stop
    r.update(over)
    return r


def loop_expect(exit_code, res, must=(), must_not=(), mode='write', dwells=(13, 17, 26), extra_args=()):
    e = expect(exit_code, res, must, must_not)
    e['script'] = 'calib-loop.ps1'
    e['args'] = ['-Mode', mode, '-Dwells', ','.join(str(d) for d in dwells)] + list(extra_args)
    return e


def add_loop(name, files, exp):
    SCENARIOS[name] = dict(steps=files, expect=exp, raw={})


D3 = (13, 17, 26)
NOTRIAL = [in_file('trial1-*.log', '.')]
LEDGER_W3 = 'ledger: mode=write trials started=3, b sent=3, images written=3 \\(boots after a write\\), boots observed=3, RUNNING confirmed=3, completed without event=3'
add_loop('loop-normal', loop_files(D3), loop_expect(0, loop_results(3, stop='all-trials-done'),
         must=['trial 1 .*image_written=C:\\\\T\\\\coron_R-bt4-alt.uf2 tag_before=bt4-R-10080217 tag_after_planned=bt4A-R-10080217 tag_after_observed=bt4A-R-10080217 .*seq_before=1 seq_after=2 uptime_min_before_op=13.17',
               'trial 3 .*seq_after=4 uptime_min_before_op=26.2', LEDGER_W3, 'LOOP DONE \\(no event\\) \\| RESTORE PASS',
               in_file('trial0-*.log', 'baseline: seq=1 .* reinit=1'), in_file('trial1-*.log', 'end of dwell: seq=1 .* reinit=1'), in_file('trial1-*.log', 'after write \\(read 1\\): seq=2 .* done=1 .* reinit=0'),
               in_file('trial1-*.log', 'dwell measured by the firmware: up_ms 10000 -> 790000, progress 780000 ms'), in_file('trial2-*.log', "sent 'b'"), in_file('trial2-*.log', 'DEVICE-OP copy'),
               in_file('steppre-*.log', 'PASS production image md5')],
         must_not=['NOT sent', 'timed out', 'EVENT']))
add_loop('loop-reset-normal', loop_files((13, 26), mode='reset'), loop_expect(0, loop_results(2, stop='all-trials-done'),
         must=['ledger: mode=reset trials started=2, r sent=2 \\(boots after a soft reset\\), boots observed=2, RUNNING confirmed=2, completed without event=2', in_file('trial1-*.log', "sent 'r'")],
         must_not=['DEVICE-OP copy \\(mock\\) C:\\\\T\\\\coron_R-bt4-alt', 'EVENT'], mode='reset', dwells=(13, 26)))
natA = inc_abort(A, 2)
add_loop('loop-new-incident', loop_files(D3, trial_override={2: dict(after_incs=[natA])}),
         loop_expect(10, loop_stopped(3, 2, '10', 'event:_new-incident_(trial_2)'),
                     must=[in_file('trial2-*.log', 'EVENT after write: incident records count 0 -> 1'), in_file('trial2-*.log', 'saved \\[natural\\] ZBOOT inc0 us2'),
                           in_file('trial2-*.log', 'new natural incident: inc0 seq=2 reason=0'), 'LOOP STOPPED ON EVENT \\| RESTORE PASS', in_file('flash-prod-*.log', 'FLASH prod RESULT PASS'),
                           'images written=2 \\(boots after a write\\), boots observed=2, RUNNING confirmed=1, completed without event=1'],
                     must_not=[in_file('trial3-*.log', '.')]))
full = [inc_h(B, 1)] * 6
add_loop('loop-dropped', loop_files(D3, baseline_incs=full, trial_override={1: dict(after_dropped=1)}),
         loop_expect(10, loop_stopped(3, 1, '10', 'event:_new-incident_(trial_1)'),
                     must=[in_file('trial1-*.log', 'EVENT after write: incident records count 6 -> 6, dropped 0 -> 1'), in_file('trial0-*.log', 'calibration artifact')]))
add_loop('loop-reinit', loop_files(D3, trial_override={1: dict(after_reinit=1)}),
         loop_expect(10, loop_stopped(3, 1, '10', 'event:_ring-reinit_(trial_1)'), must=[in_file('trial1-*.log', 'EVENT after write: the ring was reinitialised in this new boot')]))
add_loop('loop-reinit-flag-change', loop_files(D3, trial_override={1: dict(end_reinit=0)}),
         loop_expect(10, loop_stopped(3, 1, '10', 'event:_reinit-flag-changed-within-boot_(trial_1)'),
                     must=[in_file('trial1-*.log', 'EVENT end of dwell: the reinit flag changed within the same boot \\(1 -> 0\\)')], must_not=[in_file('trial1-*.log', "sent 'b'")]))
# the dump itself is inconsistent: header reinit=1, cur reinit=0 -> rejected by Validate-Dump (script FAIL, restore)
LF = loop_files(D3)
LF['baseline'] = scen(['app'], [ex('', dump(B, cur(B, 1, reinit=0), [], up_ms=9000, reinit=1)), ex('', dump(B, cur(B, 1, reinit=0), [], up_ms=9500, reinit=1))])
add_loop('loop-header-cur-mismatch', LF, loop_expect(1, {'pre': '0', 'flash-base': '0', 'baseline': '1', 't1': 'not-run', 't2': 'not-run', 't3': 'not-run', 'restore': '0', 'stop': 'baseline-failed_(rc=1)'},
         must=[in_file('trial0-*.log', 'FAIL baseline:ring header reinit == cur reinit \\(header=1 cur=0\\)')]))
add_loop('loop-unexpected-seq', loop_files(D3, trial_override={1: dict(after_seq=3)}),
         loop_expect(10, loop_stopped(3, 1, '10', 'event:_unexpected-boot-count_(trial_1)'), must=[in_file('trial1-*.log', 'EVENT after write: boot number 1 -> 3, expected \\+1')]))
# the device reboots on its own during the dwell: USB leaves 'app' at poll 3 -> the dwell ends there, the records are read, no 'b'
LF = loop_files(D3)
LF['t1'] = scen(['app', 'app', 'app', 'none', 'none', 'app', 'app'], [ex('', ldump(B, 1, [], up_ms=10000)), ex('', ldump(B, 2, [], up_ms=20000, lst=last(B, 1, reason=0, reinit=1)))], drives=OUR)
add_loop('loop-left-app', LF, loop_expect(10, loop_stopped(3, 1, '10', 'event:_left-app-during-dwell_(unexpected-boot-count)_(trial_1)'),
         must=[in_file('trial1-*.log', "EVENT dwell: the device left 'app' \\(state=none\\) at poll 3; the dwell ends here"), in_file('trial1-*.log', 'EVENT after leaving app: boot number 1 -> 2'),
               'ledger: mode=write trials started=1, b sent=0, images written=0 \\(boots after a write\\), boots observed=0, RUNNING confirmed=0, completed without event=0'],
         must_not=[in_file('trial1-*.log', "sent 'b'"), in_file('trial1-*.log', 'first seen at poll [4-9]'), in_file('trial1-*.log', 'end of dwell')]))
LF = loop_files(D3)
LF['t1'] = loop_trial(B, A, 1, 13, states=['app'] * 14 + ['boot'] + ['none'] * 200, start_up_ms=10000)
LF['flash-prod'] = scen(['none'], [], drives=[])
add_loop('loop-no-response', LF, loop_expect(13, loop_stopped(3, 1, '11', 'no-observation:_no-external-response_(state=none)_(trial_1)', restore='1'),
         must=[in_file('trial1-*.log', 'NO EXTERNAL RESPONSE'), in_file('flash-prod-*.log', 'FAIL device on USB'), 'LOOP STOPPED, NO OBSERVATION \\| RESTORE FAIL',
               'images written=1 \\(boots after a write\\), boots observed=0']))
LF = loop_files(D3)
LF['t1'] = loop_trial(B, A, 1, 13, copy='fail', start_up_ms=10000)
add_loop('loop-mid-fail', LF, loop_expect(1, loop_stopped(3, 1, '1', 'trial_1_failed_(rc=1)'),
         must=[in_file('trial1-*.log', 'copy error \\(mock\\)'), in_file('trial1-*.log', 'STOPPED before'), 'LOOP FAILED \\| RESTORE PASS', 'b sent=1, images written=0']))
add_loop('loop-deadline', loop_files(D3), loop_expect(0, {'pre': '0', 'flash-base': '0', 'baseline': '0', 't1': 'not-run', 't2': 'not-run', 't3': 'not-run', 'restore': '0',
                                                       'stop': 'deadline:_trial_1_(dwell_13_min_+_reserve)_would_end_after_2026-01-01_00:00'},
         must=['deadline: trial 1', 'LOOP DONE \\(no event\\) \\| RESTORE PASS'], must_not=NOTRIAL, extra_args=('-NoNewTrialAfter', '2026-01-01 00:00')))
LF = loop_files(D3)
LF['t1'] = dict(LF['t1'], step_hang_s=60, step_timeout_s=8, kill_mode='linger')
add_loop('loop-kill-unconfirmed', LF, loop_expect(3, loop_stopped(3, 1, 'TIMEOUT-ALIVE', 'trial_1_failed_(rc=TIMEOUT-ALIVE)', restore='not-attempted'),
         must=['termination confirmed=False', 'RESTORE NOT ATTEMPTED'], must_not=['FLASH prod start']))
LF = loop_files(D3)
LF['flash-prod'] = scen(['app', 'boot', 'app'], [ex('b', ldump(A, 4, []), post=BOOTLOADER, lost=True), ex('', ldump(A, 5, []))], drives=OUR)
add_loop('loop-restore-fail', LF, loop_expect(2, loop_results(3, stop='all-trials-done', restore='1'), must=['LOOP DONE \\(no event\\) \\| RESTORE FAIL']))
old_cal = [inc_h(B, 1), inc_G(B, 1)]
add_loop('loop-old-calib-records', loop_files(D3, baseline_incs=old_cal), loop_expect(0, loop_results(3, stop='all-trials-done'),
         must=[in_file('trial0-*.log', 'saved \\[calibration artifact\\] ZBOOT inc1 a '), LEDGER_W3], must_not=['EVENT']))
nat = inc_abort(B, 1)
add_loop('loop-incident-at-baseline', loop_files(D3, baseline_incs=[nat]), loop_expect(10, {'pre': '0', 'flash-base': '0', 'baseline': '10', 't1': 'not-run', 't2': 'not-run', 't3': 'not-run', 'restore': '0', 'stop': 'event-at-baseline:_incident-at-baseline'},
         must=[in_file('trial0-*.log', 'EVENT baseline: 1 natural incident record'), 'LOOP STOPPED ON EVENT \\| RESTORE PASS']))
# ---- review #15 point 2: the preflight checks every image before any device operation
NO_PROD = {p: m for k, (p, m) in FILES.items() if k != 'prod'}
BAD_ALT = files(**{FILES['alt'][0]: '00000000000000000000000000000000'})
PRE_STOP = {'pre': '1', 't1': 'not-run', 't2': 'not-run', 't3': 'not-run', 'restore': 'not-needed', 'stop': 'pre-failed_(rc=1):_nothing_written_to_the_device'}
add_loop('loop-prod-missing', loop_files(D3, fl=NO_PROD), loop_expect(1, PRE_STOP,
         must=[in_file('steppre-*.log', 'FAIL production image exists'), 'RESTORE NOT NEEDED: no device change was started'],
         must_not=['FLASH base start', 'DEVICE-OP', "\\[calib-io\\] sent", in_file('flash-base-*.log', '.'), in_file('flash-prod-*.log', '.')]))
add_loop('loop-alt-md5', loop_files(D3, fl=BAD_ALT), loop_expect(1, PRE_STOP,
         must=[in_file('steppre-*.log', 'FAIL alt image md5'), 'RESTORE NOT NEEDED'], must_not=['FLASH base start', 'DEVICE-OP', "\\[calib-io\\] sent"]))
# ---- review #15 point 3: done, up_ms, dwell
add_loop('loop-done0', loop_files(D3, trial_override={1: dict(after_done=0, after_reads=3)}),
         loop_expect(10, loop_stopped(3, 1, '10', 'event:_running-not-reached_(trial_1)'),
                     must=[in_file('trial1-*.log', 'done=0 \\(RUNNING not reached yet\\) at read 3 of 3'), in_file('trial1-*.log', 'EVENT after write: the boot never reported done=1'), 'RUNNING confirmed=0, completed without event=0'],
                     must_not=[in_file('trial1-*.log', 'TRIAL 1 RESULT OK')]))
LF = loop_files(D3)
t1 = LF['t1']; d_end_noup = t1['exchanges'][1]['pre'].replace('ZDIAG begin version=prof1 up_ms=790000 ', 'ZDIAG begin version=prof1 ')
t1['exchanges'][1] = ex('', d_end_noup); t1['exchanges'].insert(2, ex('', d_end_noup))
add_loop('loop-upms-missing', LF, loop_expect(1, loop_stopped(3, 1, '1', 'trial_1_failed_(rc=1)'),
         must=[in_file('trial1-*.log', 'FAIL end of dwell:up_ms present')], must_not=[in_file('trial1-*.log', "sent 'b'")]))
add_loop('loop-dwell-short', loop_files(D3, trial_override={1: dict(end_up_ms=300000)}),
         loop_expect(1, loop_stopped(3, 1, '1', 'trial_1_failed_(rc=1)'),
                     must=[in_file('trial1-*.log', 'FAIL dwell progress within tolerance \\(progress=290000 want=780000\\)')], must_not=[in_file('trial1-*.log', "sent 'b'")]))
add_loop('loop-uptime-regress', loop_files(D3, trial_override={1: dict(end_up_ms=5000)}),
         loop_expect(10, loop_stopped(3, 1, '10', 'event:_uptime-regressed_(trial_1)'),
                     must=[in_file('trial1-*.log', 'EVENT end of dwell: up_ms went backwards or stood still within the same boot \\(10000 -> 5000\\)')], must_not=[in_file('trial1-*.log', "sent 'b'")]))
# ---- review #15 point 5: exit 0 without a complete result file of this trial
LF = loop_files(D3)
LF['t1'] = dict(LF['t1'], mock_no_result_file=True)
add_loop('loop-result-missing', LF, loop_expect(1, loop_stopped(3, 1, '0', 'trial_1_returned_0_but_its_result_is_invalid:_result_file_missing_or_not_JSON'),
         must=['result file missing or not JSON', 'stages unknown=1 \\(no result file; these trials may have operated the device\\)', 'LOOP FAILED \\| RESTORE PASS'], must_not=[in_file('trial2-*.log', '.')]))
LF = loop_files(D3)
LF['t2'] = dict(LF['t2'], mock_stale_result=True)
add_loop('loop-result-stale', LF, loop_expect(1, loop_stopped(3, 2, '0', 'trial_2_returned_0_but_its_result_is_invalid:_result_file_is_of_trial_1,_not_2'),
         must=['result file is of trial 1, not 2'], must_not=[in_file('trial3-*.log', '.')]))

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
