"""Build typed catalogs from the decoded October 2026 client data.

usage (ExtractGameData folder):  python -I tools/client-data/october/catalogs.py
Writes items/npcs/monsters/spawns/quests/maps/npc_skills/loot/quest objective+reward CSVs to
output/catalogs/; tools/Initialize-GameDatabase.ps1 loads them.

The client ships no NPC combat stats (health, attack, defense). Monster rows
therefore use placeholder stats derived from level and rank (see placeholder_stats);
everything else comes straight from the client tables.
"""
import csv, glob, json, os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
DATA = os.path.join(ROOT, 'output')
TABLES = os.path.join(DATA, 'decoded', 'AION2', 'Content', 'Data', 'Table')
MAPS = os.path.join(DATA, 'decoded', 'AION2', 'Content', 'Data', 'Map')
MAP_EVENTS = os.path.join(DATA, 'decoded', 'AION2', 'Content', 'Data', 'MapEvent')
L10N = os.path.join(DATA, 'decrypted', 'AION2', 'Content', 'Data', 'Table', 'L10N', 'en-US', 'L10NString.json')
OUT = os.path.join(DATA, 'catalogs')
FIRST_SPAWN_ID = 1_000_000  # leaves IDs below it free for spawns added by hand

WEAPONS = {'Sword', 'Greatsword', 'Dagger', 'Bow', 'Magicbook', 'Orb', 'Mace', 'Staff', 'Guarder', 'Gauntlet'}
RANK = {'ENpcSubType::EliteMonster': 'elite', 'ENpcSubType::HeroMonster': 'boss', 'ENpcSubType::LegendMonster': 'boss'}
MERCHANT_FUNCS = {'BuySell', 'Blacksmith', 'Storage', 'GuildStorage', 'SkinExtraction'}


def rows(table):
    with open(os.path.join(TABLES, table + '.json'), encoding='utf-8') as fh:
        return json.load(fh)['Properties']['Data']


def enum_member(v):
    return v.split('::', 1)[1] if v and '::' in v else (v or '')


def faction(*values):
    text = ' '.join(values)
    if 'Light' in text: return 'elyos'
    if 'Dark' in text: return 'asmodian'
    return 'neutral'


def placeholder_stats(level, rank):
    """Not client data: the client has no NPC combat stats."""
    mult = {'normal': 1, 'elite': 3, 'boss': 10}[rank]
    return 100 * max(1, level) * mult, (1 + level) * mult, level * mult


def write(name, header, data):
    path = os.path.join(OUT, name)
    with open(path, 'w', newline='', encoding='utf-8') as fh:
        w = csv.writer(fh, lineterminator='\n')
        w.writerow(header); w.writerows(data)
    print(f'{name}: {len(data)} rows')


def main():
    os.makedirs(OUT, exist_ok=True)
    with open(L10N, encoding='utf-8') as fh:
        text = json.load(fh)['Entries']

    def name(key, fallback):
        return text.get(f'String_{key}_body') or fallback

    # items
    items = []
    for r in rows('Item'):
        kind = enum_member(r['ItemType'])
        equip = enum_member(r.get('EquipCategory'))
        category = ('weapon' if equip in WEAPONS else 'armor') if kind == 'Equip' else \
            'consumable' if kind == 'Usable' else 'material'
        items.append([r['ID']['Value'], name(r['Desc']['Key'], r['Name']), category,
                      max(1, r['MaxStackCount']), max(0, r['PermitLevelMin'])])
    write('items.csv', ['id', 'name', 'category', 'max_stack', 'required_level'], items)

    # skills ranges (for monster attack range) and aggro ranges
    skill_range = {r['ID']['Value']: r['NeedSkillUseRange'] for r in rows('Skill')}
    aggro_radius = {r['AggroDetectType']: r['AggroRangeInfo']['Radius'] for r in rows('NpcAggroData')}

    npcs, monsters, npc_kind = [], [], {}
    for r in rows('NpcData'):
        nid = r['ID']['Value']
        func = enum_member(r['FunctionType'])
        is_monster = r['NpcType'] == 'ENpcType::Monster'
        kind = 'monster' if is_monster else 'merchant' if func in MERCHANT_FUNCS else \
            'teleporter' if func == 'NpcTeleport' else 'ambient'
        npcs.append([nid, name(r['Desc']['Key'], r['Name']), kind, max(1, r['Level']),
                     faction(r['RelationshipEntity']), '' if func == 'None' else func])
        npc_kind[nid] = kind
        skills = [s['Value'] for s in r['ActiveSkillList'] if s['Value']]
        if is_monster and skills:
            rank = RANK.get(r['NpcSubType'], 'normal')
            hp, atk, dfn = placeholder_stats(r['Level'], rank)
            rng = skill_range.get(skills[0], 0) / 100.0
            monsters.append([nid, nid, rank, hp, atk, dfn,
                             aggro_radius.get(r['AggroDetectRange'], 2000) / 100.0,
                             max(0.1, r['BaseMoveSpeed'] / 100.0), rng if rng > 0 else 3.0, skills[0], 1500])
    write('npcs.csv', ['id', 'name', 'kind', 'level', 'faction', 'interaction'], npcs)
    write('monsters.csv', ['id', 'npc_id', 'rank', 'max_health', 'attack', 'defense', 'aggro_radius', 'move_speed',
                           'attack_range', 'server_skill_id', 'attack_interval_ms'], monsters)
    monster_ids = {m[0] for m in monsters}

    # spawns: one row per spawn position; NpcIdList candidates collapse to the first entry
    spawns, sid, skipped = [], FIRST_SPAWN_ID, 0
    for path in sorted(glob.glob(os.path.join(MAPS, '**', 'MapData.json'), recursive=True)):
        with open(path, encoding='utf-8') as fh:
            m = json.load(fh)['Properties']['Data']
        for s in m['SpawnInfoList']:
            npc_ids = [x['Value'] for x in s['NpcIdList'] if x['Value'] in npc_kind]
            if not npc_ids:
                skipped += len(s['Positions']); continue  # environment objects or unknown templates
            template = npc_ids[0]
            kind = 'monster' if template in monster_ids else 'npc'
            for p in s['Positions']:
                loc = p['Location']
                spawns.append([sid, template, kind, m['MapId'], round(loc['X'], 3), round(loc['Y'], 3),
                               round(loc['Z'], 3), round(p['Rotation']['Yaw'] % 360.0, 2), 0])
                sid += 1
    write('spawns.csv', ['id', 'template_id', 'kind', 'map_id', 'x', 'y', 'z', 'heading', 'respawn_seconds'], spawns)
    print(f'  skipped {skipped} positions without an NPC template (environment objects)')

    # quests
    quests = []
    for r in rows('Quest'):
        title = text.get(f"QuestString_{r['QuestText']}_quest_title") or r['Name']
        # repeatability is not a quest column in this build; 0 until it is mapped from DutyScroll/DutyMission data
        quests.append([r['ID']['Value'], title, max(0, r['UnlockLevel']), faction(r['Race']), 0])
    quests_by_id = {q[0] for q in quests}
    write('quests.csv', ['id', 'name', 'minimum_level', 'faction', 'repeatable'], quests)

    # maps: Map table rows, plus MapData-only IDs (instance layers) so every spawn map resolves
    maps = {r['ID']['Value']: [r['ID']['Value'], name(r['Desc']['Key'], r['Filename'] or r['GroupName']), ''] for r in rows('Map')}
    for path in glob.glob(os.path.join(MAPS, '**', 'MapData.json'), recursive=True):
        with open(path, encoding='utf-8') as fh:
            mid = json.load(fh)['Properties']['Data']['MapId']
        maps.setdefault(mid, [mid, os.path.basename(os.path.dirname(path)), ''])
    write('maps.csv', ['id', 'name', 'walk_mesh_path'], sorted(maps.values()))

    # world events: one per MapEvent script; stage/step directives become ordered actions
    events, actions = [], []
    for event_id, path in enumerate(sorted(glob.glob(os.path.join(MAP_EVENTS, '*.json'))), 1):
        with open(path, encoding='utf-8') as fh:
            ev = json.load(fh)
        start = ev.get('StartConditions') or []
        first = start[0][0]['Type'] if start and start[0] else 'Always'
        events.append([event_id, ev['Name'], ev['MapID'], first, json.dumps(start, ensure_ascii=False)[:1024], 1,
                       json.dumps(ev, ensure_ascii=False)])
        k = 0
        for stage in ev.get('Stages', []):
            phases = [('stage_fail', None, d) for d in stage.get('FailDirectives', [])]
            for step in stage.get('Steps', []):
                phases += [('pre', step['Id'], d) for d in step.get('PreDirectives', [])]
                phases += [('post', step['Id'], d) for d in step.get('PostDirectives', [])]
            for phase, step_id, d in phases:
                actions.append([event_id, k, d.get('Type', ''), 0,
                                json.dumps({'stage': stage.get('Id'), 'step': step_id, 'phase': phase, 'directive': d}, ensure_ascii=False)])
                k += 1
    write('world_events.csv', ['id', 'name', 'map_id', 'trigger_type', 'trigger_value', 'enabled', 'source_payload'], events)
    write('world_event_actions.csv', ['event_id', 'action_index', 'action_type', 'delay_ms', 'payload'], actions)

    # npc_skills: ActiveSkillList order is the priority
    known_skills = set(skill_range)
    npc_skills = [[r['ID']['Value'], sid, i, ''] for r in rows('NpcData')
                  for i, sid in enumerate(dict.fromkeys(x['Value'] for x in r['ActiveSkillList'] if x['Value'] in known_skills))]
    write('npc_skills.csv', ['npc_id', 'skill_id', 'priority', 'cooldown_override_ms'], npc_skills)

    # loot graph. One namespace of named loot tables:
    #   RewardItem / RewardPackageItem -> item entries      (ItemProb out of 100,000,000)
    #   RewardPackage / RewardDecomposePackage -> child tables (Prob out of 100,000,000)
    #   LevelScaleDropGroup -> member tables by level range
    #   BoxReward -> item entries of an openable box item
    # A race-specific table is named "<name>@<Race>".
    item_id = {r['Name']: r['ID']['Value'] for r in rows('Item')}
    loot_id, loot_tables = {}, []

    def table(tname):
        if tname not in loot_id:
            loot_id[tname] = len(loot_tables) + 1
            loot_tables.append([loot_id[tname], tname])
        return loot_id[tname]

    def race_name(base, race):
        r = enum_member(race)
        return base if r in ('', 'All', 'None') else f'{base}@{r}'

    entries, unresolved = {}, 0

    def add_entry(tid, item, lo, hi, prob):
        nonlocal unresolved
        iid = item_id.get(item)
        if iid is None:
            unresolved += 1; return
        m = entries.setdefault((tid, iid), [tid, iid, lo, hi, 0.0])
        m[2] = min(m[2], lo); m[3] = max(m[3], hi); m[4] = round(min(1.0, m[4] + prob), 8)

    for r in rows('RewardItem'):
        tid = table(race_name(r['Name'], r['Race']))
        for e in r['Items']: add_entry(tid, e['ItemName'], e['ItemCountMin'], e['ItemCountMax'], e['ItemProb'] / 1e8)
    for r in rows('RewardPackageItem'):
        tid = table(r['PackageName'])
        for e in r['Items']: add_entry(tid, e['ItemName'], e['ItemCountMin'], e['ItemCountMax'], e['ItemProb'] / 1e8)
    for r in rows('BoxReward'):
        tid = table(race_name(r['Group'], r['Race']))
        for e in r['Items'] + r['SelectItems']: add_entry(tid, e['Item'], e['Count'], e['Count'], 1.0)

    pending_links = []  # parent table, child name, chance, count, level_min, level_max, source
    for r in rows('RewardPackage'):
        parent = table(race_name(r['Name'], r['Unknown1_Name']))
        for e in r['PackageItems']: pending_links.append((parent, e['Item'], e['Prob'] / 1e8, e['Count'], 0, 0, 'package'))
    for r in rows('RewardDecomposePackage'):
        parent = table(r['Name'])
        for e in r['Packages']: pending_links.append((parent, e['Item'], e['Prob'] / 1e8, e['Count'], 0, 0, 'decompose'))
    levelscale = {}
    for r in rows('LevelScaleDropGroup'):
        parent = table(r['GroupLevelscaleReward'])
        levelscale.setdefault(r['GroupLevelscaleReward'], []).append(r)
        pending_links.append((parent, r['Name'], 1.0, 1, r['LevelMin'], r['LevelMax'], 'level_scale'))

    variants = {}
    for tname, tid in loot_id.items():
        variants.setdefault(tname.split('@')[0], []).append(tid)

    def resolve(tname):
        return [loot_id[tname]] if tname in loot_id else variants.get(tname, [])

    links, unresolved_links = {}, 0
    for parent, child, chance, count, lmin, lmax, src in pending_links:
        targets = resolve(child)
        if not targets: unresolved_links += 1
        for c in targets:
            if c != parent:
                links.setdefault((parent, c), [parent, c, round(min(1.0, chance), 8), count, lmin, lmax, src])

    write('loot_tables.csv', ['id', 'name'], loot_tables)
    write('loot_table_entries.csv', ['loot_table_id', 'item_id', 'minimum_count', 'maximum_count', 'chance'], list(entries.values()))
    write('loot_table_links.csv', ['parent_loot_table_id', 'child_loot_table_id', 'chance', 'item_count', 'level_min', 'level_max',
                                   'link_source'], list(links.values()))
    print(f'  skipped {unresolved} loot entries naming no known item, {unresolved_links} links naming no loot table')

    # quest objectives: one row per QuestStep goal, ordered by step
    quest_id = {r['Name']: r['ID']['Value'] for r in rows('Quest')}
    npc_by_name = {r['Name']: r['ID']['Value'] for r in rows('NpcData')}
    steps = sorted((s for s in rows('QuestStep') if s['QuestName'] in quest_id), key=lambda s: (s['QuestName'], s['Order']))
    objectives, counter = [], {}
    for st in steps:
        q = quest_id[st['QuestName']]
        for goal in st['GoalList']:
            idx = counter[q] = counter.get(q, -1) + 1
            vals = goal['Value']
            first = vals[0] if vals else ''
            target = int(first) if first.isdigit() else npc_by_name.get(first, item_id.get(first, ''))
            count = int(vals[1]) if len(vals) > 1 and vals[1].isdigit() else 1
            payload = {'step_id': st['ID']['Value'], 'step_order': st['Order'], **goal}
            objectives.append([q, idx, enum_member(goal['Type']), target, count, json.dumps(payload, ensure_ascii=False)])
    write('quest_objectives.csv', ['quest_id', 'objective_index', 'objective_type', 'target_id', 'required_count', 'payload'], objectives)

    # quest rewards: row 0 = experience + Gold, then each item reward (class-specific rewards stay in raw records)
    rewards, unresolved = [], 0
    for r in rows('QuestReward'):
        if not r['Group'].isdigit() or int(r['Group']) not in quests_by_id: continue
        q = int(r['Group'])
        items = r['ItemRewards'] + r['ItemNormalRewards'] + r['ItemSelectRewards']
        gold = sum(i['Count'] for i in items if i['Item'] == 'Gold')
        rewards.append([q, 0, '', 0, r['ExpReward'], gold])
        for i in items:
            if i['Item'] == 'Gold': continue
            iid = item_id.get(i['Item'])
            if iid is None:
                unresolved += 1; continue
            rewards.append([q, len([x for x in rewards if x[0] == q]), iid, i['Count'], 0, 0])
    write('quest_rewards.csv', ['quest_id', 'reward_index', 'item_id', 'item_count', 'experience', 'currency'], rewards)
    print(f'  skipped {unresolved} quest reward items naming no known item')

    # class-specific quest rewards
    class_rewards, counter = [], {}
    for r in rows('QuestClassReward'):
        if not r['Group'].isdigit() or int(r['Group']) not in quests_by_id: continue
        q, cls = int(r['Group']), enum_member(r['Class'])
        for i in r['ItemRewards'] + r['ItemNormalRewards'] + r['ItemSelectRewards']:
            iid = item_id.get(i['Item'])
            if iid is None: continue
            k = counter[(q, cls)] = counter.get((q, cls), -1) + 1
            class_rewards.append([q, cls, k, iid, i['Count']])
    write('quest_class_rewards.csv', ['quest_id', 'character_class', 'reward_index', 'item_id', 'item_count'], class_rewards)

    # skill effects: each Skill time-data entry points at a SkillEffect group
    effects_by_group = {}
    for e in rows('SkillEffect'):
        effects_by_group.setdefault(e['SkillEffectGroupId']['Value'], []).append(e)
    skill_effects = []
    for sk in rows('Skill'):
        if not sk['ID']['Value']: continue
        n = 0
        for t in sk['SkillEffectTimeDataList']:
            group = t['SkillEffectGroupId']['Value']
            for e in effects_by_group.get(group, []) if group else []:
                payload = {'time_data': t, 'effect': e}
                skill_effects.append([sk['ID']['Value'], n, enum_member(e['EffectType']), ','.join(e['EffectValueList'])[:1024],
                                      t['SkillEffectFilterId']['Value'] or '', json.dumps(payload, ensure_ascii=False)])
                n += 1
    write('skill_effects.csv', ['skill_id', 'effect_index', 'effect_type', 'value_expression', 'target_filter_id', 'source_payload'], skill_effects)

    # environment objects (gather nodes, portals, chests...) and their spawn positions
    env_ids, env_objects = set(), []
    for r in rows('EnvObjData'):
        env_ids.add(r['ID']['Value'])
        env_objects.append([r['ID']['Value'], text.get(r['Desc']['Key']) or r['Name'], enum_member(r['Usage']),
                            '' if r['UsageValue'] == 'None' else r['UsageValue'], max(0, r['InteractRange']),
                            max(0, r['InteractTime']), json.dumps(r, ensure_ascii=False)])
    write('env_objects.csv', ['id', 'name', 'usage_type', 'usage_value', 'interact_range', 'interact_time_ms', 'source_payload'], env_objects)
    env_spawns, eid = [], 1
    for path in sorted(glob.glob(os.path.join(MAPS, '**', 'MapData.json'), recursive=True)):
        with open(path, encoding='utf-8') as fh:
            m = json.load(fh)['Properties']['Data']
        for sp in m['SpawnInfoList']:
            if any(x['Value'] in npc_kind for x in sp['NpcIdList']): continue  # already an NPC spawn
            objs = [x['Value'] for x in sp['EnvObjIdList'] if x['Value'] in env_ids]
            if not objs: continue
            for pos in sp['Positions']:
                loc = pos['Location']
                env_spawns.append([eid, objs[0], m['MapId'], round(loc['X'], 3), round(loc['Y'], 3), round(loc['Z'], 3),
                                   round(pos['Rotation']['Yaw'] % 360.0, 2)])
                eid += 1
    write('env_object_spawns.csv', ['id', 'env_object_id', 'map_id', 'x', 'y', 'z', 'heading'], env_spawns)

    # loot owners: every client-table field that names a loot table (RewardData, Dungeon, Item, Quest*, ...)
    loot_definitions = {'RewardItem', 'RewardPackageItem', 'RewardPackage', 'RewardDecomposePackage', 'LevelScaleDropGroup',
                        'BoxReward', 'BoxClassReward'}
    kind_of_table = {'NpcData': 'npc', 'EnvObjData': 'env_object', 'Dungeon': 'dungeon', 'Item': 'item', 'Quest': 'quest',
                     'QuestReward': 'quest', 'QuestClassReward': 'quest', 'FieldEvent': 'field_event',
                     'RewardDataMonsterCube': 'field_event', 'RewardOdEnergyCube': 'dungeon'}

    def owner_kind(table_name, oid):
        if table_name == 'RewardData' and oid is not None:
            return 'npc' if oid in npc_kind else 'env_object' if oid in env_ids else 'other'
        return kind_of_table.get(table_name, 'other')

    owners = {}

    def scan(v, path, table_name, key, oid):
        if isinstance(v, str):
            for tid in resolve(v) if v and v != 'None' else ():
                owners.setdefault((table_name, key, tid, path), [table_name, key, oid if oid is not None else '',
                                                                 owner_kind(table_name, oid), tid, path, 'client'])
        elif isinstance(v, dict):
            for k2, x in v.items(): scan(x, f'{path}.{k2}' if path else k2, table_name, key, oid)
        elif isinstance(v, list):
            for x in v: scan(x, path + '[]', table_name, key, oid)

    for path_json in sorted(glob.glob(os.path.join(TABLES, '*.json'))):
        table_name = os.path.basename(path_json)[:-5]
        if table_name in loot_definitions or table_name in ('L10NString',): continue
        with open(path_json, encoding='utf-8') as fh:
            data = json.load(fh)['Properties']['Data']
        if not isinstance(data, list): continue
        for i, r in enumerate(data):
            if not isinstance(r, dict): continue
            idv = r.get('ID') or r.get('Id')
            oid = idv.get('Value') if isinstance(idv, dict) else idv if isinstance(idv, int) else None
            key = str(oid) if oid is not None else str(r.get('Name') or r.get('Group') or i)
            scan(r, '', table_name, key[:255], oid)
    # openable box items own their box table
    for r in rows('BoxReward'):
        iid = item_id.get(r['Group'])
        if iid is not None:
            for tid in resolve(race_name(r['Group'], r['Race'])):
                owners.setdefault(('Item', str(iid), tid, 'BoxReward'), ['Item', str(iid), iid, 'item', tid, 'BoxReward', 'client'])
    # reward tables named after an NPC ID
    for tname, tid in loot_id.items():
        tail = tname.split('@')[0].rsplit('_', 1)[-1]
        if tail.isdigit() and int(tail) in npc_kind:
            owners.setdefault(('NpcData', tail, tid, 'name_suffix'), ['NpcData', tail, int(tail), 'npc', tid, 'name_suffix', 'name_suffix'])

    # monsters the client gives no loot: inferred from their zone's level-scaled basic group
    has_loot = {o[2] for o in owners.values() if o[3] == 'npc' and o[2] != ''}
    zone_group = {}
    spawn_maps = {}
    for sp in spawns:
        spawn_maps.setdefault(sp[1], set()).add(sp[3])
    rd_group = {r['ID']['Value']: r['GroupLevelscaleRewardName'] for r in rows('RewardData') if r['GroupLevelscaleRewardName'] != 'None'}
    for nid, group in rd_group.items():
        for mid in spawn_maps.get(nid, ()):
            zone_group.setdefault(mid, {}).setdefault(group, 0)
            zone_group[mid][group] += 1
    npc_level = {r['ID']['Value']: r['Level'] for r in rows('NpcData')}
    inferred = 0
    for nid in sorted(monster_ids - has_loot):
        votes = {}
        for mid in spawn_maps.get(nid, ()):
            for g, c in zone_group.get(mid, {}).items(): votes[g] = votes.get(g, 0) + c
        if not votes: continue
        group = max(votes, key=votes.get)
        lvl = npc_level.get(nid, 1)
        member = next((m['Name'] for m in levelscale.get(group, []) if m['LevelMin'] <= lvl <= m['LevelMax']), None)
        for tid in resolve(member) if member else resolve(group):
            owners.setdefault(('NpcData', str(nid), tid, 'zone_group'),
                              ['NpcData', str(nid), nid, 'npc', tid, 'zone_group', 'inferred_zone_group'])
            inferred += 1
    write('loot_owners.csv', ['owner_table', 'owner_key', 'owner_id', 'owner_kind', 'loot_table_id', 'link_field', 'link_source'],
          list(owners.values()))
    print(f'  inferred zone loot for {inferred} monster links')


if __name__ == '__main__':
    main()
