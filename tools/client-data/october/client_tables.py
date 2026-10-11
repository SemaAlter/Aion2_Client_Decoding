"""Load every decoded client table into its own MySQL table (ct_<snake_name>) with real columns.

usage (repository root):  python -I tools/client-data/october/client_tables.py
Connection comes from config/database.ini.

Column mapping per client field:
  bool -> TINYINT(1), integer -> BIGINT, float -> DOUBLE, string/enum -> TEXT,
  TableItemId {"Value": n} -> BIGINT, TableString/TableL10NText {"Key": ...} -> TEXT plus <field>_text
  with the English string, anything nested (arrays, maps, structs) -> JSON.
Tables with more columns than InnoDB allows (GlobalSetting) become setting/value rows.
ct_l10n_string holds every localized string for all shipped locales.
"""
import configparser, glob, json, os, re, subprocess, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
DATA = os.path.join(ROOT, 'output')
STRUCTURED = os.path.join(DATA, 'decoded', 'AION2', 'Content')
L10N_DIR = os.path.join(DATA, 'decrypted', 'AION2', 'Content', 'Data', 'Table', 'L10N')
WORK = os.path.join(DATA, 'database-import', 'client-tables')
MYSQL = os.environ.get('MYSQL_PATH', r'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe')
MAX_COLUMNS = 900


def snake(name):
    return re.sub(r'(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])', '_', name).lower()


def kind(v):
    if v is None: return None
    if isinstance(v, bool): return 'bool'
    if isinstance(v, int): return 'int'
    if isinstance(v, float): return 'float'
    if isinstance(v, str): return 'str'
    if isinstance(v, dict) and set(v) == {'Value'} and isinstance(v['Value'], int): return 'id'
    if isinstance(v, dict) and set(v) in ({'Key'}, {'Key', 'StringKey'}) and isinstance(v.get('Key'), str): return 'text'
    return 'json'


def merge(a, b):
    if a is None or a == b: return b
    if b is None: return a
    if {a, b} <= {'int', 'float'}: return 'float'
    if {a, b} <= {'int', 'id'}: return 'int'
    return 'json'


SQL_TYPE = {'bool': 'TINYINT(1)', 'int': 'BIGINT', 'float': 'DOUBLE', 'str': 'TEXT', 'id': 'BIGINT', 'text': 'TEXT', 'json': 'JSON'}


def tsv(v):
    if v is None: return r'\N'
    if isinstance(v, bool): v = int(v)
    s = v if isinstance(v, str) else str(v)
    return s.replace('\\', '\\\\').replace('\t', '\\t').replace('\n', '\\n').replace('\r', '\\r')


def cell(k, v, english):
    if v is None: return [None] if k != 'text' else [None, None]
    if k == 'id': return [v['Value'] if isinstance(v, dict) else v]
    if k == 'text':
        key = v['Key']
        return [key, english(key)]
    if k == 'json': return [json.dumps(v, ensure_ascii=False)]
    if k == 'float': return [repr(float(v))]
    return [v]


def build(table, rows, english, out_sql):
    name = 'ct_' + snake(table)
    if len(name) > 64: name = name[:64]
    path = os.path.join(WORK, name + '.tsv')
    cols, kinds = [], {}
    for r in rows:
        for k, v in r.items():
            if k not in kinds: cols.append(k); kinds[k] = None
            kinds[k] = merge(kinds[k], kind(v))
    width = sum(2 if kinds[c] == 'text' else 1 for c in cols)
    out_sql.append(f'DROP TABLE IF EXISTS `{name}`;')
    if width > MAX_COLUMNS:  # too wide for InnoDB: one row per setting
        out_sql.append(f'CREATE TABLE `{name}` (`_row` INT UNSIGNED NOT NULL, `setting` VARCHAR(191) NOT NULL, `value` TEXT NULL,'
                       f' PRIMARY KEY (`_row`, `setting`)) ENGINE=InnoDB;')
        with open(path, 'w', encoding='utf-8', newline='\n') as fh:
            for i, r in enumerate(rows):
                for c in cols:
                    v = r.get(c)
                    v = json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list)) else v
                    fh.write(f'{i}\t{tsv(c)}\t{tsv(v)}\n')
        load_cols = '(`_row`, `setting`, `value`)'
    else:
        seen, defs, load = set(), ['`_row` INT UNSIGNED NOT NULL PRIMARY KEY'], ['`_row`']
        colnames = {}
        for c in cols:
            base = c[:60]; cn = base; n = 2
            while cn.lower() in seen: cn = f'{base}_{n}'; n += 1
            seen.add(cn.lower()); colnames[c] = cn
            k = kinds[c] or 'str'
            defs.append(f'`{cn}` {SQL_TYPE[k]} NULL'); load.append(f'`{cn}`')
            if k == 'text':
                tn = f'{cn}_text'[:64]; seen.add(tn.lower())
                defs.append(f'`{tn}` TEXT NULL'); load.append(f'`{tn}`')
        index = [f'KEY `ix_id` (`{colnames[c]}`)' for c in cols[:1] if c in ('ID', 'Id') and kinds[c] in ('id', 'int')]
        out_sql.append(f'CREATE TABLE `{name}` ({", ".join(defs + index)}) ENGINE=InnoDB;')
        with open(path, 'w', encoding='utf-8', newline='\n') as fh:
            for i, r in enumerate(rows):
                values = [i]
                for c in cols:
                    values += cell(kinds[c] or 'str', r.get(c), english)
                fh.write('\t'.join(tsv(v) for v in values) + '\n')
        load_cols = '(' + ', '.join(load) + ')'
    sql_path = path.replace('\\', '/').replace("'", "''")
    out_sql.append(f"LOAD DATA LOCAL INFILE '{sql_path}' INTO TABLE `{name}` CHARACTER SET utf8mb4 "
                   f"FIELDS TERMINATED BY '\\t' ESCAPED BY '\\\\' LINES TERMINATED BY '\\n' {load_cols};")
    return name, len(rows)


def main():
    cfg = configparser.ConfigParser()
    cfg.read(os.path.join(ROOT, 'config', 'database.ini'))
    db = cfg['database']
    os.makedirs(WORK, exist_ok=True)

    locales = {}
    for path in sorted(glob.glob(os.path.join(L10N_DIR, '*', 'L10NString.json'))):
        with open(path, encoding='utf-8') as fh:
            locales[os.path.basename(os.path.dirname(path))] = json.load(fh)['Entries']
    en = locales.get('en-US', {})

    def english(key):
        if not key or key == 'None': return None
        return en.get(key) or en.get(f'String_{key}_body')

    sql = ['SET SESSION innodb_strict_mode=0;', 'SET FOREIGN_KEY_CHECKS=0;']
    summary = []
    for sub in ('Data/Table', 'StartUpData/Table'):
        for path in sorted(glob.glob(os.path.join(STRUCTURED, *sub.split('/'), '*.json'))):
            table = os.path.splitext(os.path.basename(path))[0]
            with open(path, encoding='utf-8') as fh:
                data = json.load(fh)['Properties']['Data']
            rows = [r if isinstance(r, dict) else {'value': r} for r in data]
            summary.append(build(table, rows, english, sql))

    # all localized strings, one row per (locale, key)
    l10n = os.path.join(WORK, 'ct_l10n_string.tsv')
    with open(l10n, 'w', encoding='utf-8', newline='\n') as fh:
        for loc, entries in locales.items():
            for k, v in entries.items():
                fh.write(f'{tsv(loc)}\t{tsv(k)}\t{tsv(v)}\n')
    sql += ['DROP TABLE IF EXISTS `ct_l10n_string`;',
            'CREATE TABLE `ct_l10n_string` (`locale` VARCHAR(16) NOT NULL, `string_key` VARCHAR(255) NOT NULL, `text` TEXT NULL,'
            ' PRIMARY KEY (`locale`, `string_key`)) ENGINE=InnoDB;',
            f"LOAD DATA LOCAL INFILE '{l10n.replace(chr(92), '/')}' INTO TABLE `ct_l10n_string` CHARACTER SET utf8mb4 "
            "FIELDS TERMINATED BY '\\t' ESCAPED BY '\\\\' LINES TERMINATED BY '\\n' (`locale`, `string_key`, `text`);",
            'SET FOREIGN_KEY_CHECKS=1;']
    sql_file = os.path.join(WORK, 'load.sql')
    with open(sql_file, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(sql) + '\n')

    print(f"Target database: {db['database']} at {db['host']}:{db['port']} (from config/database.ini)")
    with open(sql_file, 'rb') as fh:
        proc = subprocess.run([MYSQL, '--protocol=tcp', '-h', db['host'], '-P', db['port'], '-u', db['user'],
                               f"--password={db['password']}", '--default-character-set=utf8mb4', '--local-infile=1',
                               '--show-warnings=0', db['database']], stdin=fh, capture_output=True)
    err = proc.stderr.decode('utf-8', 'replace')
    err = '\n'.join(l for l in err.splitlines() if 'Using a password' not in l)
    if proc.returncode != 0:
        print(err); sys.exit(1)
    print(f'Loaded {len(summary)} client tables ({sum(n for _, n in summary)} rows) and '
          f'{sum(len(e) for e in locales.values())} localized strings into ct_* tables.')


if __name__ == '__main__':
    main()
