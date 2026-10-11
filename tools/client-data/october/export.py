"""Decode every decrypted AION2 table and map file into CUE4Parse-shaped JSON.

usage (repository root):
  python -I tools/client-data/october/export.py
Output: output/decoded/AION2/Content/... plus audit.csv.
Point tools/Import-Aion2GameData.ps1 -TableDirectory at the Data/Table folder to use it.
"""
import argparse, csv, json, os, sys, time
from multiprocessing import Pool

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aion2dat

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
DATA = os.path.join(ROOT, 'output')
SCHEMA = None


def init(usmap, overrides):
    global SCHEMA
    SCHEMA = aion2dat.Schema(usmap, overrides)


def job(args):
    src, rel, out_root = args
    t0 = time.time()
    name = os.path.splitext(os.path.basename(src))[0]
    parts = rel.replace('\\', '/').split('/')
    try:
        data = open(src, 'rb').read()
        if 'MapEvent' in parts:  # already UTF-8 JSON after the XOR layer; validate and keep as is
            try: json.loads(data.decode('utf-8'))
            except (UnicodeDecodeError, ValueError) as e: raise aion2dat.Bad(f'map event is not JSON: {e}') from None
            dst = os.path.join(out_root, os.path.splitext(rel)[0] + '.json')
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, 'wb') as fh: fh.write(data)
            return rel, 'json', 1, '', round(time.time() - t0, 2)
        if 'Map' in parts or 'WorldMap' in parts:
            doc = aion2dat.decode_map(SCHEMA, data, 'MapData' if name == 'MapData' else 'AionWorldMapExportInfo')
            rows = 1
        else:
            doc = aion2dat.decode_table(SCHEMA, data, aion2dat.row_struct(name))
            rows = len(doc['Properties']['Data'])
        dst = os.path.join(out_root, os.path.splitext(rel)[0] + '.json')
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, 'w', encoding='utf-8') as fh:
            json.dump(doc, fh, ensure_ascii=False)
        return rel, 'json', rows, '', round(time.time() - t0, 2)
    except (aion2dat.Bad, RecursionError) as e:
        return rel, 'schema-error', 0, str(e)[:300], round(time.time() - t0, 2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--decrypted', default=os.path.join(DATA, 'decrypted'))
    ap.add_argument('--out', default=os.path.join(DATA, 'decoded'))
    ap.add_argument('--usmap', default=os.path.join(DATA, 'mappings', 'AION2-5.3.2.0.usmap'))
    ap.add_argument('--schema', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), 'october-2026-schema.json'))
    ap.add_argument('--only', nargs='*', help='file names (without extension) to export')
    a = ap.parse_args()

    jobs = []
    content = os.path.join(a.decrypted, 'AION2', 'Content')
    for sub in ('Data/Table', 'StartUpData/Table', 'Data/Map', 'Data/WorldMap', 'Data/MapEvent'):
        base = os.path.join(content, *sub.split('/'))
        for dp, _, files in os.walk(base):
            for f in files:
                if not f.endswith('.bin'): continue
                if sub == 'Data/Map' and f != 'MapData.bin': continue
                if 'L10N' in dp or f == 'key_manifest.bin': continue  # different formats, see client-data-decryption.md
                if a.only and os.path.splitext(f)[0] not in a.only: continue
                src = os.path.join(dp, f)
                jobs.append((src, os.path.relpath(src, a.decrypted), a.out))
    jobs.sort(key=lambda j: -os.path.getsize(j[0]))  # biggest first keeps the pool busy

    init(a.usmap, a.schema)  # fail here, not inside every pool worker
    os.makedirs(a.out, exist_ok=True)
    results = []
    with Pool(initializer=init, initargs=(a.usmap, a.schema)) as pool:
        for r in pool.imap_unordered(job, jobs):
            results.append(r)
            if r[1] != 'json': print('FAIL', r[0], r[3], flush=True)
    results.sort()
    with open(os.path.join(a.out, 'audit.csv'), 'w', newline='', encoding='utf-8') as fh:
        w = csv.writer(fh)
        w.writerow(['virtual_path', 'status', 'rows', 'error', 'seconds'])
        w.writerows(results)
    ok = sum(r[1] == 'json' for r in results)
    print(f'{ok}/{len(results)} files decoded -> {a.out}')
    return 0 if ok == len(results) else 1


if __name__ == '__main__':
    sys.exit(main())
