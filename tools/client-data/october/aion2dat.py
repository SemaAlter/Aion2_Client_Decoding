"""Strict decoder for decrypted AION2 .dat payloads (October 2026 global client).

Layouts come from the public AION2 usmap plus october-2026-schema.json, which
replaces or adds the structs whose serialized layout changed in this build.
Every decode is checked against two ground truths carried by the files
themselves: the payload must be consumed exactly, and the row's flattened leaf
column count must equal the number of column hashes in the file header.
"""
import json, re, struct

XOR_LONG = bytes([0x25, 0, 0xA8, 0, 0x7E, 0, 0x91, 0])

USMAP_TYPES = ["ByteProperty", "BoolProperty", "IntProperty", "FloatProperty", "ObjectProperty", "NameProperty",
               "DelegateProperty", "DoubleProperty", "ArrayProperty", "StructProperty", "StrProperty", "TextProperty",
               "InterfaceProperty", "MulticastDelegateProperty", "WeakObjectProperty", "LazyObjectProperty",
               "AssetObjectProperty", "SoftObjectProperty", "UInt64Property", "UInt32Property", "UInt16Property",
               "Int64Property", "Int16Property", "Int8Property", "MapProperty", "SetProperty", "EnumProperty",
               "FieldPathProperty", "OptionalProperty", "Utf8StrProperty", "AnsiStrProperty", "ClassProperty",
               "MulticastInlineDelegateProperty", "SoftClassProperty", "VerseStringProperty", "VerseDynamicProperty",
               "VerseFunctionProperty"]
USMAP_TYPES += ["UnknownProperty"] * (0x100 - len(USMAP_TYPES))  # 0xFD-0xFF are custom/unknown, no payload

# Table file name -> row struct, where they differ (from CUE4Parse FAion2DataTableFile).
ROW_STRUCT = {
    "AgitDecoItem": "PersonalAgitDecoItemTableItem", "AgitDecoSlot": "PersonalAgitDecoSlotTableItem",
    "ClientSliderSettings": "SliderSettingsTableItem", "EnvObjData": "EnvObjTableItem",
    "FieldEventPlatformerDilemma": "FieldEventDilemmaTableItem", "KiskData": "KiskTableItem",
    "MonsterPartsData": "PartsDataTableItem", "PeriodItemCollection": "PeriodCollectionTableItem",
    "PeriodItemCollectionList": "PeriodCollectionListTableItem", "RandomShop": "RandomShopCategoryTableItem",
    "Resources": "ResourceTableItem", "RewardData": "RewardTableItem", "RewardLevelScaleData": "RewardLevelScaleTableItem",
    "RewardDataMonsterCube": "MonsterCubeTableItem", "SkillAbnormal": "AbnormalTableItem",
    "SkillAbnormalEffect": "AbnormalEffectTableItem", "SkillAbnormalEffectLv": "AbnormalEffectLevelTableItem",
    "SkillAbnormalEffectType": "AbnormalEffectTypeTableItem", "SkillAbnormalOverlapFx": "AbnormalOverlapFxTableItem",
    "SkillAbnormalProperty": "AbnormalPropertyTableItem", "SkillAcquireData": "SkillAcquireTableItem",
    "SkillProjectile": "ProjectileTableItem", "String": "AionStringTableItem", "ServerMessage": "ServerBroadcastDataTableItem",
    "SeasonRankingReward": "SeasonRankingRewardCommonTableItem", "VehicleList": "VehicleDataTableItem",
    "WaveStepData": "WaveStepTableItem", "CVResource_StartUp": "CVResourceTableItem",
    "InputAction_StartUp": "InputActionTableItem", "InputEvent_StartUp": "InputEventTableItem",
    "InputKeyMapping_StartUp": "InputKeyMappingTableItem", "PackageList_StartUp": "PackageListTableItem",
    "ResourcePak_StartUp": "ResourcePakTableItem", "String_StartUp": "AionStringTableItem",
}
ITEM_SUBS = {"EItemType::Currency": "ItemTableCurrencyInfo", "EItemType::Equip": "ItemTableEquipmentInfo",
             "EItemType::Usable": "ItemTableUsableInfo", "EItemType::Misc": "ItemTableMiscInfo"}

FIXED = {'IntProperty': ('<i', 4), 'UInt32Property': ('<I', 4), 'UInt16Property': ('<H', 2), 'Int64Property': ('<q', 8),
         'UInt64Property': ('<Q', 8), 'Int16Property': ('<h', 2), 'Int8Property': ('<b', 1), 'ByteProperty': ('<B', 1),
         'FloatProperty': ('<f', 4), 'DoubleProperty': ('<d', 8)}


class Bad(Exception):
    pass


def row_struct(table):
    return ROW_STRUCT.get(table, table + "TableItem")


def xor_long(b):
    return bytes(x ^ XOR_LONG[i & 7] for i, x in enumerate(b))


def parse_type(s):
    """'Int', 'Name', 'Enum<EFoo>', 'Struct<X>', 'Array<T>', 'Set<T>', 'Map<K,V>' (also full *Property names)."""
    s = s.strip()
    m = re.fullmatch(r'(\w+)<(.*)>', s)
    if not m:
        return {'t': s if s.endswith('Property') else s + 'Property'}
    head, arg = m.groups()
    if head == 'Enum': return {'t': 'EnumProperty', 'enum': arg}
    if head == 'Struct': return {'t': 'StructProperty', 'struct': arg}
    if head == 'Array': return {'t': 'ArrayProperty', 'inner': parse_type(arg)}
    if head == 'Set': return {'t': 'SetProperty', 'inner': parse_type(arg)}
    if head == 'Map':
        depth = 0
        for i, c in enumerate(arg):
            depth += (c == '<') - (c == '>')
            if c == ',' and depth == 0:
                return {'t': 'MapProperty', 'inner': parse_type(arg[:i]), 'value': parse_type(arg[i + 1:])}
    raise ValueError(s)


def type_str(p):
    t = p['t']
    if t == 'EnumProperty': return f"Enum<{p['enum']}>"
    if t == 'StructProperty': return f"Struct<{p['struct']}>"
    if t == 'ArrayProperty': return f"Array<{type_str(p['inner'])}>"
    if t == 'SetProperty': return f"Set<{type_str(p['inner'])}>"
    if t == 'MapProperty': return f"Map<{type_str(p['inner'])},{type_str(p['value'])}>"
    return t[:-8]


def load_usmap(path):
    """Uncompressed .usmap (versions 0-3) -> {struct: [(name, ptype)]} in serialization order (super first)."""
    d = open(path, 'rb').read()
    o = [0]

    def u(f):
        v = struct.unpack_from(f, d, o[0]); o[0] += struct.calcsize(f); return v[0]
    assert u('<H') == 0x30C4, 'not a usmap'
    ver = u('<B')
    if ver >= 1 and u('<i'):
        u('<i'); u('<i'); o[0] += u('<i') * 20; u('<I')
    if u('<B') != 0: raise ValueError('compressed usmap is not supported')
    u('<I'); u('<I')
    names = []
    for _ in range(u('<I')):
        n = u('<H') if ver >= 2 else u('<B')
        names.append(d[o[0]:o[0] + n].decode()); o[0] += n
    for _ in range(u('<I')):
        u('<I')
        for _ in range(u('<H') if ver >= 3 else u('<B')): u('<I')

    def ptype():
        t = USMAP_TYPES[u('<B')]
        p = {'t': t}
        if t == 'EnumProperty': p['inner'] = ptype(); p['enum'] = names[u('<I')]
        elif t == 'StructProperty': p['struct'] = names[u('<I')]
        elif t in ('ArrayProperty', 'SetProperty', 'OptionalProperty'): p['inner'] = ptype()
        elif t == 'MapProperty': p['inner'] = ptype(); p['value'] = ptype()
        return p
    raw = {}
    for _ in range(u('<I')):
        sn = names[u('<I')]; si = u('<I'); u('<H')
        props = []
        for _ in range(u('<H')):
            idx = u('<H'); dim = u('<B'); pn = names[u('<I')]
            props.append((idx, dim, pn, ptype()))
        raw[sn] = (None if si == 0xFFFFFFFF else names[si], props)

    def flat(sn):
        sup, props = raw[sn]
        out = flat(sup) if sup else []
        for _, dim, pn, p in sorted(props, key=lambda x: x[0]):
            out += [(pn, p)] * dim
        return out
    return {sn: flat(sn) for sn in raw}


class Schema:
    def __init__(self, usmap_path, overrides_path=None):
        self.structs = {k.lower(): v for k, v in load_usmap(usmap_path).items()}
        if overrides_path:
            for k, fields in json.load(open(overrides_path))['structs'].items():
                self.structs[k.lower()] = [(n, parse_type(t)) for n, t in fields]

    def fields(self, name):
        try: return self.structs[name.lower()]
        except KeyError: raise Bad(f'no layout for struct {name}') from None

    def leaves(self, p):
        t = p['t']
        if t == 'StructProperty': return sum(self.leaves(q) for _, q in self.fields(p['struct']))
        if t in ('ArrayProperty', 'SetProperty'): return self.leaves(p['inner'])
        if t == 'MapProperty': return self.leaves(p['inner']) + self.leaves(p['value'])
        return 1

    def row_leaves(self, sname):
        n = self.leaves({'t': 'StructProperty', 'struct': sname})
        if sname == 'ItemTableItem':  # the header lists the base row plus every ItemType sub-struct
            n += sum(self.leaves({'t': 'StructProperty', 'struct': s}) for s in ITEM_SUBS.values())
        return n


class Reader:
    """CUE4Parse-compatible value reader that rejects anything inconsistent."""

    def __init__(self, schema, data, pos=0):
        self.sc, self.d, self.o = schema, data, pos

    def i32(self):
        if self.o + 4 > len(self.d): raise Bad('eof')
        v = struct.unpack_from('<i', self.d, self.o)[0]; self.o += 4; return v

    def string(self, xored=True, cap=1 << 16):
        n = self.i32()
        if n == 0: return ''
        size = n if n > 0 else -2 * n
        if size > cap or self.o + size > len(self.d): raise Bad(f'string length {n}')
        b = self.d[self.o:self.o + size]; self.o += size
        if n > 0:
            if b[-1] != 0: raise Bad('unterminated string')
            try: s = b[:-1].decode('utf-8')
            except UnicodeDecodeError: raise Bad('bad utf-8') from None
        else:
            if b[-2:] != b'\0\0': raise Bad('unterminated string')  # terminator stays raw; only chars are xored
            try: s = (xor_long(b) if xored else b)[:-2].decode('utf-16le')
            except UnicodeDecodeError: raise Bad('bad utf-16') from None
        if '\0' in s: raise Bad('embedded nul')
        return s


    def text(self):
        """FText: uint32 flags, int8 history type; None(-1): bool32 + optional string; Base(0): namespace, key, source."""
        if self.o + 5 > len(self.d): raise Bad('eof')
        flags = struct.unpack_from('<I', self.d, self.o)[0]; hist = struct.unpack_from('<b', self.d, self.o + 4)[0]; self.o += 5
        if flags > 0xFFFF: raise Bad('text flags')
        if hist == -1:
            has = self.i32()
            if has not in (0, 1): raise Bad('text invariant flag')
            return {'Flags': flags, 'CultureInvariantString': self.string(xored=False) if has else None}
        if hist == 0:
            return {'Flags': flags, 'Namespace': self.string(xored=False), 'Key': self.string(xored=False), 'SourceString': self.string(xored=False)}
        raise Bad(f'text history {hist}')

    def count(self):
        n = self.i32()
        if n < 0 or n > len(self.d) - self.o: raise Bad(f'bad count {n}')
        return n

    def struct_tag(self, field):
        """UE FPropertyTag before struct arrays: Name, Type, Size(int64), StructName, Guid, HasPropertyGuid."""
        name, typ = self.string(), self.string()
        if self.o + 8 > len(self.d): raise Bad('eof')
        size = struct.unpack_from('<q', self.d, self.o)[0]; self.o += 8
        self.string(); self.o += 16
        if self.o >= len(self.d): raise Bad('eof')
        flag = self.d[self.o]; self.o += 1 + (16 if self.d[self.o - 1] == 1 else 0)
        if typ != 'StructProperty' or flag > 1 or size < 0: raise Bad('bad struct tag')
        if field and not field.startswith('Unknown') and name.lower() != field.lower():
            raise Bad(f'struct tag {name} where {field} was expected')
        return size

    def value(self, p, tag=True, field=None):
        t = p['t']
        if t in FIXED:
            f, n = FIXED[t]
            if self.o + n > len(self.d): raise Bad('eof')
            v = struct.unpack_from(f, self.d, self.o)[0]; self.o += n
            if t in ('FloatProperty', 'DoubleProperty') and v != v: raise Bad('NaN')
            return v
        if t == 'BoolProperty':
            if self.o >= len(self.d): raise Bad('eof')
            b = self.d[self.o]; self.o += 1
            if b > 1: raise Bad(f'bool {b}')
            return bool(b)
        if t == 'TextProperty': return self.text()
        if t == 'NameProperty': return self.string()
        if t == 'StrProperty': return self.string(xored=False)
        if t == 'EnumProperty':
            s = self.string()
            if s and s != 'None' and not s.startswith(p['enum'] + '::'): raise Bad(f"{s[:40]!r} is not {p['enum']}")
            return s
        if t == 'StructProperty': return self.struct(p['struct'])
        if t == 'ArrayProperty':
            n = self.count(); inner = p['inner']
            if tag and inner['t'] == 'StructProperty':
                size = self.struct_tag(field); a = self.o
                out = [self.value(inner) for _ in range(n)]
                if self.o - a != size: raise Bad(f"struct tag size {size} but {self.o - a} bytes read")
                return out
            return [self.value(inner, tag) for _ in range(n)]
        if t == 'SetProperty':
            for _ in range(self.count()): self.value(p['inner'])
            return self.value({'t': 'ArrayProperty', 'inner': p['inner']}, tag, field)
        if t == 'MapProperty':
            for _ in range(self.count()): self.value(p['inner'])
            return [{'Key': self.value(p['inner'], False), 'Value': self.value(p['value'], False)} for _ in range(self.count())]
        raise Bad(f'unsupported {t}')

    def struct(self, name):
        out = {}
        for i, (fn, ft) in enumerate(self.sc.fields(name)):
            try:
                out[fn] = self.value(ft, True, fn)
            except Bad as e:
                raise Bad(f'{name}.{fn}: {e}') from None
        if name == 'ItemTableItem' and out.get('ItemType') in ITEM_SUBS:
            out.update(self.struct(ITEM_SUBS[out['ItemType']]))
        return out


def header(data, versioned=True):
    """Tables: int32 version + column-hash string. Map files: hash string only (no NUL terminator)."""
    if versioned:
        r = Reader(None, data, 4)
        s = r.string(cap=1 << 24)
        return struct.unpack_from('<i', data, 0)[0], [x for x in s.split(',') if x], r.o
    n = struct.unpack_from('<i', data, 0)[0]
    return 0, [x for x in data[4:4 + n].rstrip(b'\0').decode().split(',') if x], 4 + n


def decode_table(schema, data, sname):
    ver, ids, o = header(data)
    r = Reader(schema, data, o)
    n = r.count()
    rows = []
    for i in range(n):
        try: rows.append(r.struct(sname))
        except Bad as e: raise Bad(f'row {i}: {e}') from None
    if r.o != len(data): raise Bad(f'{len(data) - r.o} trailing bytes')
    if n and schema.row_leaves(sname) != len(ids):
        raise Bad(f'layout has {schema.row_leaves(sname)} columns, header lists {len(ids)}')
    return {'Version': ver, 'Ids': ids, 'Properties': {'Data': rows}}


def decode_map(schema, data, sname):
    _, ids, o = header(data, versioned=False)
    r = Reader(schema, data, o)
    row = r.struct(sname)
    if r.o != len(data): raise Bad(f'{len(data) - r.o} trailing bytes')
    if schema.row_leaves(sname) != len(ids):
        raise Bad(f'layout has {schema.row_leaves(sname)} columns, header lists {len(ids)}')
    return {'Version': 0, 'Ids': ids, 'Properties': {'Data': row}}


if __name__ == '__main__':
    # self-check: type strings round-trip and map/array nesting parses
    for s in ['Int', 'Map<Name,Array<Struct<X>>>', 'Enum<ERace>', 'Set<Name>']:
        assert type_str(parse_type(s)) == s, s
    assert xor_long(xor_long(b'abcdefghij')) == b'abcdefghij'
    print('ok')
