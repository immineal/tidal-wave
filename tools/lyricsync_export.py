#!/usr/bin/env python3
"""Write the lyrics aligner's resource files into assets/lyricsync/.

    python3 -I tools/lyricsync_export.py --ctc <ctc run.pt> \
        --detector <net_0.pt> <net_1.pt> <net_2.pt> [--out assets/lyricsync]

ctc.f16.bin       the CTC letter net, BatchNorm folded in, float16
                  (magic H3CTCNT1; int32 nin, C, kin, k, nblocks, nout, is_f16;
                  the dilations; inp.w [C][nin][kin], inp.b, per block dw.w [C][k],
                  dw.b, pw.w [C][C], pw.b; out.w [nout][C], out.b).
detector.f16.bin  the vocal/line-start detector ensemble, float16
                  (magic LSYNCNN1, uint32 header length, JSON header, arrays).
translit.bin      code point -> the a..z letters Unidecode gives it, for every
                  word character outside ASCII (magic LSYNTRL1, uint32 count,
                  then per entry uint32 code point, uint8 length, letters).
                  The data comes from Unidecode (GPL-2.0-or-later).

Needs torch, numpy and Unidecode. The output is deterministic.
"""
import argparse
import json
import os
import struct
import sys
import unicodedata

import numpy as np

NOUT = 27


def fold(sd, conv, bn):
    # As the reference exporter: float64 weights, float32 BatchNorm statistics.
    w, b = sd[f'{conv}.weight'].astype(np.float64), sd[f'{conv}.bias'].astype(np.float64)
    s = sd[f'{bn}.weight'] / np.sqrt(sd[f'{bn}.running_var'] + np.float32(1e-5))
    return w * s[:, None, None], (b - sd[f'{bn}.running_mean']) * s + sd[f'{bn}.bias']


def export_ctc(path, out):
    import torch
    ck = torch.load(path, map_location='cpu')
    cfg = ck['cfg']
    sd = {k: v.numpy() for k, v in ck['state'].items() if v.dtype.is_floating_point}
    assert not cfg.get('rnn') and cfg.get('sub', 1) == 1 and not cfg.get('start')
    nb, k = cfg.get('nb', 8), cfg.get('k', 9)
    cycle = cfg.get('dil', (1, 2, 4, 1, 2, 4, 1, 2))
    dil = [cycle[i % len(cycle)] for i in range(nb)]
    arrs = list(fold(sd, 'inp', 'bn0'))
    for i in range(nb):
        p = f'blocks.{i}'
        w, b = fold(sd, f'{p}.dw', f'{p}.bn')
        arrs += [w[:, 0, :], b, sd[f'{p}.pw.weight'][:, :, 0], sd[f'{p}.pw.bias']]
    arrs += [sd['out.weight'], sd['out.bias']]
    C, nin, kin = sd['inp.weight'].shape
    with open(out, 'wb') as f:
        f.write(b'H3CTCNT1')
        f.write(struct.pack('<7i', nin, C, kin, k, nb, NOUT, 1))
        f.write(struct.pack(f'<{nb}i', *dil))
        for a in arrs:
            f.write(np.ascontiguousarray(a, '<f2').tobytes())


def export_detector(paths, dilations, out):
    import torch
    nets = [{k: v.numpy().astype(np.float32) for k, v in torch.load(p, map_location='cpu').items()} for p in paths]
    C, nin, _ = nets[0]['inp.weight'].shape
    meta, arrays = [], []
    for n, sd in enumerate(nets):
        for k, v in sd.items():
            meta.append(dict(net=n, name=k, shape=list(v.shape)))
            arrays.append(v.astype('<f2'))
    hdr = json.dumps(dict(nin=int(nin), channels=int(C), dilations=dilations, nets=len(nets),
                          arrays=meta)).encode()
    with open(out, 'wb') as fh:
        fh.write(b'LSYNCNN1')
        fh.write(struct.pack('<I', len(hdr)))
        fh.write(hdr)
        for a in arrays:
            fh.write(a.tobytes())


def export_translit(out):
    from unidecode import unidecode
    entries = []
    for cp in range(0x80, 0x30000):
        if 0xD800 <= cp <= 0xDFFF:
            continue
        c = chr(cp)
        # Only characters text.norm() can leave behind: word characters, no marks.
        if not c.isalnum() or unicodedata.combining(c):
            continue
        letters = ''.join(ch for ch in unidecode(c).lower() if 'a' <= ch <= 'z')
        if letters:
            entries.append((cp, letters.encode('ascii')))
    with open(out, 'wb') as f:
        f.write(b'LSYNTRL1')
        f.write(struct.pack('<I', len(entries)))
        for cp, s in entries:
            f.write(struct.pack('<IB', cp, len(s)))
            f.write(s)
    return len(entries)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ctc')
    ap.add_argument('--detector', nargs='+')
    ap.add_argument('--dilations', default='1,2,4,8,16,1,2,4')
    ap.add_argument('--out', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'assets', 'lyricsync'))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    if a.ctc:
        export_ctc(a.ctc, os.path.join(a.out, 'ctc.f16.bin'))
    if a.detector:
        export_detector(a.detector, [int(x) for x in a.dilations.split(',')], os.path.join(a.out, 'detector.f16.bin'))
    n = export_translit(os.path.join(a.out, 'translit.bin'))
    print('translit entries', n, file=sys.stderr)


if __name__ == '__main__':
    main()
