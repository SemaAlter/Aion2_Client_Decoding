"""Marks decryption-manifest.csv rows whose October JSON exists as structured.

usage: python -I finish_manifest.py <output dir>
Tables and maps are decoded by tools/client-data/october/export.py into decoded/;
the database import (Initialize-GameDatabase.ps1, Import-StructuredClientData.ps1) reads the
status and path from the manifest.
"""
import csv
import os
import sys

output_root = os.path.abspath(sys.argv[1])
manifest = os.path.join(output_root, 'decryption-manifest.csv')
with open(manifest, encoding='utf-8-sig', newline='') as fh:
    reader = csv.DictReader(fh)
    fields, rows = reader.fieldnames, list(reader)

structured = 0
for row in rows:
    if row['structured_status'] == 'json':
        structured += 1
        continue
    relative = os.path.join('decoded', os.path.splitext(row['virtual_path'])[0] + '.json')
    path = os.path.join(output_root, relative)
    if os.path.exists(path) and os.path.getsize(path) > 2:
        row['structured_status'] = 'json'
        row['structured_json_path'] = relative.replace('\\', '/')
        structured += 1

with open(manifest, 'w', encoding='utf-8', newline='') as fh:
    writer = csv.DictWriter(fh, fieldnames=fields, quoting=csv.QUOTE_ALL, lineterminator='\r\n')
    writer.writeheader()
    writer.writerows(rows)
print(f'{structured}/{len(rows)} manifest rows have structured JSON')
