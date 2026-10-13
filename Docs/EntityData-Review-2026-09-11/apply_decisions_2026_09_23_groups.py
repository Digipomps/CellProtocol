"""Append subgroup decisions to the 23.09 target, never to Swift/runtime data.

All transformations and checks finish in memory before generated files are written.
The reference check is documentation tooling for complete local example maps,
not an implementation of the future decoder or a user-data migration.
"""
import copy

import apply_decisions_2026_09_23 as previous
from target_validation import check_schema, validate

HERE = previous.HERE
DECISION = previous.DECISION
UUID_PATTERN = previous.UUID_PATTERN
require, expect, add, encoded = previous.require, previous.expect, previous.add, previous.encoded
GROUPS = ('properties', 'groups')
GROUP = GROUPS + ('additionalProperties',)
MEMBERS = GROUP + ('properties', 'members')
RELATIONS = previous.previous.RELATIONS
BOKPROSJEKT = previous.previous.BOKPROSJEKT
ROOT = '30000000-0000-4000-8000-000000000003'
CHAPTER = '30000000-0000-4000-8000-000000000004'
WORK_A = '30000000-0000-4000-8000-000000000005'
WORK_B = '30000000-0000-4000-8000-000000000006'
ENTITY_A = previous.previous.ENTITY_A
ENTITY_B = previous.previous.ENTITY_B
STEP = 'apply_decisions_2026_09_23_groups.py'


def replace(value, path, child):
    require(value, *path)
    require(value, *path[:-1])[path[-1]] = child


def target_schema(input_schema):
    s = copy.deepcopy(input_schema)
    expect(require(s, 'x-haven', 'decisionsAsOf'), '2026-09-23', 'decisionsAsOf')
    expect(require(s, *GROUP, 'type'), 'object', 'group/type')
    expect(require(s, *GROUP, 'required'), ['name', 'members'], 'group/required')
    expect(require(s, *GROUP, 'additionalProperties'), False, 'group/additionalProperties')
    expect(set(require(s, *GROUP, 'properties')), {'name', 'members'}, 'group/properties')
    expect(require(s, *MEMBERS, 'items', 'pattern'), UUID_PATTERN, 'members/items/pattern')
    add(require(s, *GROUP, 'properties'), 'partOf', {
        'type': 'string', 'pattern': UUID_PATTERN, 'maxLength': 36,
        'description': 'Valgfri gruppe-uuid som peker fra barnet til foreldregruppen i groups. '
                       'En rotgruppe har ikke partOf. Barnelisten persisteres ikke; den bygges '
                       'ved dekoding, som alle andre bakveier i modellen. JSON Schema kontrollerer '
                       'uuid-form, ikke at referansen peker på en gruppe eller at grafen er asyklisk. '
                       'Dekoderen må avvise ukjente foreldre, entitetsreferanser og sykler, også selvreferanser. '
                       'Målkrav, ikke implementert i Swift.'
    }, 'group/properties')
    replace(s, GROUPS + ('description',),
            'Grupper nøkles på gruppe-uuid og har uvektede medlemslister over entiteter. '
            'Undergrupper peker oppover med partOf; barnelisten persisteres ikke, men bygges '
            'ved dekoding som alle andre bakveier i modellen. Hvilke grupper en entitet '
            'tilhører bygges også ved dekoding. Relasjoner bærer den vektede perspektivgrafen. '
            'JSON Schema kan ikke oppdage sykler i partOf; dekoderen må avvise dem. '
            'Referansenes type og eksistens må kontrolleres separat. Målkrav, ikke implementert i Swift.')
    replace(s, MEMBERS + ('description',),
            'Flat liste med bare entitets-uuid-er til relations.entities, uten vekter eller kopier. '
            'Samme entitet kan stå i flere grupper. Gruppe-uuid-er i members skal avvises; '
            'gruppemedlemskap og undergrupper blandes ikke i samme felt. Undergrupper bruker partOf. '
            'UUID-syntaks skiller ikke referansetypene; dekoderen må kontrollere type og eksistens.')
    replace(s, MEMBERS + ('items', 'description'),
            'Entitets-uuid til relations.entities. En gruppe-uuid eller relasjons-uuid skal avvises '
            'ved referansekontroll; JSON Schema kontrollerer bare UUID-syntaks.')
    # The retired tree is required to exist, including both parallel membership forms.
    expect(require(s, *BOKPROSJEKT, 'type'), 'object', 'bokprosjekt/type')
    require(s, *BOKPROSJEKT, 'properties', 'members')
    require(s, *BOKPROSJEKT, 'properties', 'groups')
    expect(require(s, *RELATIONS, 'additionalProperties'), False, 'relations/additionalProperties')
    del require(s, *RELATIONS, 'properties')['bokprosjekt']
    replace(s, RELATIONS + ('description',),
            'Objekt med bare reserverte nøkler. Eierdefinerte navngitte lister og det gamle '
            'relations.bokprosjekt-undertreet er erstattet av groups-roten. Relasjoner bærer '
            'den vektede perspektivgrafen; groups.members er uvektet entitetsmedlemskap og '
            'groups.partOf peker til foreldregruppen. records/<uuid>/entityRepresentation '
            'er den typede kontaktbanen. Den gamle formen avvises av målskjemaet; '
            'dagens Swift-lagring og runtime-grunnlaget er ikke endret.')
    require(s, 'x-haven', 'deferredDecisions', 'relations.bokprosjekt')
    del require(s, 'x-haven', 'deferredDecisions')['relations.bokprosjekt']
    add(require(s, 'x-haven'), 'groupHierarchyImplementation',
        'partOf og avvikling av relations.bokprosjekt er besluttet i målskjemaet, ikke implementert '
        'i Swift. Dekoderen må kontrollere entitetsmedlemmer, gruppeforeldre og sykler, og bygge '
        'barnelisten i minnet. Migrering av eksisterende bokprosjektdata gjenstår.', 'x-haven')
    replace(s, ('description',), require(s, 'description') +
            ' Undergrupper bruker partOf på barnet; relations.bokprosjekt er tatt ut av målskjemaet.')
    replace(s, ('$comment',),
            'Bygges av apply_decisions_2026_09_23_groups.py etter 16.09-, 22.09- og 23.09-stegene. '
            'EntityData.review.schema.json er urørt. Undergrupper og avviklet bokprosjekt-tre '
            'er besluttet, ikke implementert; se current-review.json og beslutningsdokumentet.')
    return s


def transform_data(input_data):
    d = copy.deepcopy(input_data)
    # Require the exact prior fixture, rather than silently replacing an unknown tree.
    expect(require(d, 'groups'), {
        previous.previous.GROUP_A: {'name': 'Venner', 'members': [ENTITY_A, ENTITY_B]},
        previous.previous.GROUP_B: {'name': 'Samarbeidspartnere', 'members': [ENTITY_A]}
    }, 'example/groups')
    for entity in (ENTITY_A, ENTITY_B):
        require(d, 'relations', 'entities', entity)
    if 'bokprosjekt' in require(d, 'relations'):
        raise ValueError('UVENTET FORM: example/relations/bokprosjekt; no user-data migration allowed')
    for uuid, group in {
        ROOT: {'name': 'Bokverkstedet ved Månesjøen (fiktivt)', 'members': []},
        CHAPTER: {'name': 'Broer mellom ideer', 'partOf': ROOT, 'members': []},
        WORK_A: {'name': 'Broer mellom ideer (gruppe 1)', 'partOf': CHAPTER, 'members': [ENTITY_A]},
        WORK_B: {'name': 'Broer mellom ideer (gruppe 2)', 'partOf': CHAPTER, 'members': [ENTITY_B]}
    }.items():
        add(require(d, 'groups'), uuid, group, 'example/groups')
    return d


def group_reference_errors(data):
    """Semantic checks AFTER schema validation, for complete local maps only.

    UUID hexadecimal case is immaterial. No UUID prefixes imply a reference type.
    Missing maps are empty; an unresolved reference fails rather than being guessed.
    This is documentation verification, not the Swift decoder.
    """
    errors = []
    raw_groups = data.get('groups', {})
    groups = {key.lower(): value for key, value in raw_groups.items()}
    entities = {key.lower() for key in data.get('relations', {}).get('entities', {})}
    if len(groups) != len(raw_groups):
        errors.append('groups: duplicate UUID keys differing only in case')
    for uuid, group in groups.items():
        for member in group['members']:
            if member.lower() in groups:
                errors.append(f'groups/{uuid}/members: group UUID is forbidden: {member}')
            elif member.lower() not in entities:
                errors.append(f'groups/{uuid}/members: unknown entity UUID: {member}')
        if 'partOf' in group and group['partOf'].lower() not in groups:
            errors.append(f'groups/{uuid}/partOf: unknown parent group UUID: {group["partOf"]}')
    done = set()
    for start in groups:
        path = set()
        node = start
        while node in groups and node not in done:
            if node in path:
                errors.append(f'groups/{start}/partOf: cycle at {node}; decoder must reject')
                break
            path.add(node)
            parent = groups[node].get('partOf')
            if parent is None:
                break
            node = parent.lower()
        done.update(path)
    return errors


def validate_target(schema, data):
    validate(schema, data)
    errors = group_reference_errors(data)
    if errors:
        raise ValueError('; '.join(errors))


def build_artifacts():
    artifacts = previous.build_artifacts()
    manifest = require(artifacts, 'current-review.json')
    schema_name = require(manifest, 'schema')
    graph_name = require(manifest, 'graphSchema')
    example_name = require(manifest, 'example')
    s = target_schema(require(artifacts, schema_name))
    data = transform_data(require(artifacts, example_name))
    graph = copy.deepcopy(require(artifacts, graph_name))
    replace(graph, ('$defs',), copy.deepcopy(require(s, '$defs')))
    replace(graph, ('x-haven',), copy.deepcopy(require(s, 'x-haven')))
    expect(require(manifest, 'buildSteps'),
           ['apply_decisions_2026_09_16.py', 'apply_decisions_2026_09_22.py',
            'apply_decisions_2026_09_23.py'], 'manifest/buildSteps')
    replace(manifest, ('buildSteps',), manifest['buildSteps'] + [STEP])
    replace(manifest, ('buildCommand',), 'python -B ' + STEP)
    replace(manifest, ('validationCommand',), 'python -B validate_decisions_2026_09_23_groups.py')
    for schema in (s, graph):
        check_schema(schema)
    validate_target(s, data)
    artifacts[schema_name], artifacts[graph_name], artifacts[example_name] = s, graph, data
    return artifacts


def main():
    artifacts = build_artifacts()
    for name, value in artifacts.items():
        (HERE / name).write_bytes(encoded(value))
    print('16.09 -> 22.09 -> 23.09 -> undergrupper: partOf, avviklet bokprosjekt og tre nivåer bygget.')
    print('Skjema og referanser validert før skriving. Besluttet, ikke implementert i Swift.')


if __name__ == '__main__':
    main()
