#!/usr/bin/env python3
# compare.py — the summary half of tools/compare.sh (json + stdlib only; PIL optional for labels).
# argv: WORKDIR N SECS DUR SRC CROP SINFO OUTDIR q1 q2 ...
import json, os, sys, statistics as st, time

W, N, SECS, DUR, SRC, CROP, SINFO, OUTD = sys.argv[1:9]
N, SECS, DUR = int(N), int(SECS), int(DUR)
QS = [int(q) for q in sys.argv[9:]]
LO, HI = QS[0], QS[-1]

# Thresholds — PROVISIONAL (review against the ledger before treating as law):
JND = 6.0          # VMAF points ≈ one just-noticeable difference at normal viewing
EXPERT = 3.0       # below this a side-by-side expert rarely calls it
SAME = 1.0         # below this: no measurable difference
BAND_SEE = 5.0     # CAMBI ≈ where banding starts to be visible
BAND_ADD = 0.5     # CAMBI the encode must ADD over the source before it counts
PICK_NEG = 1.0     # pick = cheapest dial within this many NEG points of the best tested

def load(p):
    try: return json.load(open(p))
    except Exception: return None

def vkey(d):
    m = d.get('pooled_metrics', {})
    if 'vmaf' in m: return 'vmaf'
    for k in m:
        if k.startswith('vmaf'): return k
    return None

def pct(a, p):
    a = sorted(a); return a[max(0, int(len(a) * p) - 1)] if a else 0.0

R = {q: dict(v=[], neg=[], cam=[], win_v=[], win_neg=[], win_cam=[], bytes=0, md5=[]) for q in QS}
src_cam = []
for i in range(N):
    s = load(f'{W}/w{i}_src.json')
    src_cam.append(s['pooled_metrics']['cambi']['mean'] if s else 0.0)
    for q in QS:
        d = load(f'{W}/w{i}_q{q}.json'); g = load(f'{W}/w{i}_q{q}_neg.json')
        if not d or not g: sys.exit(f'  ✗ missing scores for q{q} window {i+1}')
        k, kg = vkey(d), vkey(g)
        fv = [f['metrics'][k] for f in d['frames'] if k in f['metrics']]
        fg = [f['metrics'][kg] for f in g['frames'] if kg in f['metrics']]
        fc = [f['metrics']['cambi'] for f in d['frames'] if 'cambi' in f['metrics']]
        r = R[q]; r['v'] += fv; r['neg'] += fg; r['cam'] += fc
        r['win_v'].append(st.mean(fv)); r['win_neg'].append(st.mean(fg)); r['win_cam'].append(st.mean(fc) if fc else 0.0)
        bp = f'{W}/w{i}_q{q}.bytes'
        r['bytes'] += int(open(bp).read()) if os.path.exists(bp) else os.path.getsize(f'{W}/w{i}_q{q}.mp4')
        r['md5'].append(open(f'{W}/w{i}_q{q}.md5').read().strip())

same_as = {}
for a in QS:
    for b in QS:
        if b < a and R[a]['md5'] == R[b]['md5'] and b not in same_as:
            same_as[a] = b; break

def proj(q): return R[q]['bytes'] / (N * SECS) * DUR
def fmt(b): return f'{b/1073741824:.2f} GB' if b >= 1073741824 else f'{b/1048576:.0f} MB'

SRC_B = int(os.environ.get('SLIPMAT_SRC_BYTES', '0') or 0)
base_v = st.mean(R[LO]['v']); best_neg = max(st.mean(R[q]['neg']) for q in QS)
starts = [int(open(f'{W}/w{i}.start').read()) for i in range(N)]
def at(i): return f'{starts[i]//60}:{starts[i]%60:02d}'

print(f'\n  {"dial":<6}{"size (whole file)":<22}{"VMAF":>6}{"worst 5%":>10}{"NEG":>7}{"banding":>9}   vs q{LO}')
rows = []
for q in QS:
    r = R[q]; v = st.mean(r['v']); neg = st.mean(r['neg']); cam = st.mean(r['cam']) if r['cam'] else 0.0
    dv = v - base_v; rel = r['bytes'] / R[LO]['bytes'] * 100 - 100
    size = f'≈{fmt(proj(q))}' + (f' ({rel:+.0f}%)' if q != LO else '') + (' ▲src' if SRC_B and proj(q) >= SRC_B else '')
    tag = f'  = q{same_as[q]} (identical bytes)' if q in same_as else ''
    cmp_ = '—' if q == LO else f'{dv:+.1f} pts = {dv/JND:+.2f} JND'
    print(f'  q{q:<5}{size:<22}{v:>6.1f}{pct(r["v"], .05):>10.1f}{neg:>7.1f}{cam:>9.2f}   {cmp_}{tag}')
    rows.append((q, v, neg, cam, dv, rel))

if SRC_B and any(proj(q) >= SRC_B for q in QS): print(f'\n  ▲src = lands at or above the source ({fmt(SRC_B)}) — that dial bloats this file')
print(f'  source banding (CAMBI, the file itself): {st.mean(src_cam):.2f}  ·  ceiling: the source scored against itself ≈ 97.5')
print('  verdicts:')
for q, v, neg, cam, dv, rel in rows[1:]:
    if dv < SAME:      w = 'no measurable difference'
    elif dv < EXPERT:  w = 'expert side-by-side range — invisible in normal viewing'
    elif dv < JND:     w = 'noticeable side by side'
    else:              w = 'a visible step (≥ 1 JND)'
    print(f'   q{q} over q{LO}: {w} · costs {rel:+.0f}% size')
flags = []
# banding is judged by what the ENCODE ADDS over the source (the source itself can band —
# dark stages, night skies); an absolute line alone would blame every dial for the source
def adds(q, i): return R[q]['win_cam'][i] - src_cam[i]
for q in QS:
    for i, c in enumerate(R[q]['win_cam']):
        a = adds(q, i)
        if c >= BAND_SEE and a >= BAND_ADD: flags.append(f'q{q} adds visible banding at {at(i)} ({c:.1f}; source {src_cam[i]:.1f})')
        elif c >= BAND_SEE - 1 and a >= BAND_ADD: flags.append(f'q{q} adds banding near the line at {at(i)} ({c:.1f}; source {src_cam[i]:.1f})')
srcband = [f'{at(i)} ({c:.1f})' for i, c in enumerate(src_cam) if c >= BAND_SEE]
if srcband: print('  the source itself bands at ' + ', '.join(srcband) + ' — no dial can fix that')
print('  banding: ' + ('; '.join(flags) if flags else f'no dial adds banding near the visible line (≈{BAND_SEE:.0f})'))

pick = None
for q in QS:
    okv = st.mean(R[q]['neg']) >= best_neg - PICK_NEG
    okb = not any(c >= BAND_SEE and adds(q, i) >= BAND_ADD for i, c in enumerate(R[q]['win_cam']))
    if okv and okb: pick = q; break
pick = pick or HI
print(f'  pick (PROVISIONAL rule — cheapest dial within {PICK_NEG:.0f} NEG point of the best tested, no visible banding ADDED): q{pick}')

gaps = [abs(R[HI]['win_neg'][i] - R[LO]['win_neg'][i]) for i in range(N)]
worst = gaps.index(max(gaps)); open(f'{W}/worst', 'w').write(str(worst))
print(f'  clip window: {at(worst)} (where q{LO} and q{HI} differ most)')

# labels for the clip (optional — skipped quietly without PIL)
try:
    from PIL import Image, ImageDraw, ImageFont
    fp = next((p for p in ['/System/Library/Fonts/Supplemental/Arial Bold.ttf', '/System/Library/Fonts/Helvetica.ttc'] if os.path.exists(p)), None)
    f = ImageFont.truetype(fp, 24) if fp else ImageFont.load_default()
    texts = ['ORIGINAL (1:1)', f'q{LO}  ≈{fmt(proj(LO))}', f'q{HI}  ≈{fmt(proj(HI))}',
             'damage maps: brighter = more changed (x6)', f'q{LO} damage', f'q{HI} damage']
    for k, t in enumerate(texts):
        w = int(f.getlength(t)) + 16 if hasattr(f, 'getlength') else 12 * len(t)
        im = Image.new('RGBA', (w, 36), (0, 0, 0, 190)); ImageDraw.Draw(im).text((8, 4), t, font=f, fill=(255, 230, 0, 255))
        im.save(f'{W}/lab{k}.png')
except Exception:
    pass

# the ledger: one row per dial per run, for reviewing the thresholds across many files
led = os.path.expanduser('~/.slipmat/logs/compare-ledger.tsv')
hdr = 'date\tfile\tsrc_codec\tsrc_w\tsrc_h\tsrc_kbps\tcrop\twindows\tsecs\tq\tsame_as\tsize_vs_lowest_pct\tproj_bytes\tvmaf\tvmaf_p5\tvmaf_min\tneg\tcambi\tcambi_src\tcambi_max_win\tdelta_vs_lowest\tpick\n'
si = (SINFO.split(',') + ['', '', '', ''])[:4]
kb = str(int(si[3]) // 1000) if si[3].isdigit() else ''
new = not os.path.exists(led)
with open(led, 'a') as fh:
    if new: fh.write(hdr)
    for q, v, neg, cam, dv, rel in rows:
        r = R[q]
        fh.write('\t'.join(map(str, [time.strftime('%Y-%m-%d %H:%M'), os.path.basename(SRC), si[0], si[1], si[2], kb, CROP,
            N, SECS, q, same_as.get(q, ''), f'{rel:.1f}', int(proj(q)), f'{v:.2f}', f'{pct(r["v"], .05):.2f}',
            f'{min(r["v"]):.2f}', f'{neg:.2f}', f'{cam:.3f}', f'{st.mean(src_cam):.3f}', f'{max(r["win_cam"]):.3f}',
            f'{dv:.2f}', int(q == pick)])) + '\n')
print(f'  ledger  {led}')
