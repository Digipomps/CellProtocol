"""Structural target checks; no runtime, migration or UI success is implied."""
import argparse
import copy
import hashlib
import json
from collections import Counter
from pathlib import Path

import apply_decisions_2026_09_16 as previous
import apply_decisions_2026_09_22 as current
from target_validation import check_schema, engine, validation_errors

HERE = Path(__file__).resolve().parent
RESULT = HERE / 'TARGET-VALIDATION-2026-09-22.json'
VISUAL = Path('/Users/kjetil/.codex/visualizations/2026/09/11/01a090eb-528a-76d3-87d1-41a0b84f4d47')


def reference_errors(data):
    """Check the example's new edges separately from JSON Schema validation.

    UUID syntax cannot establish that a reference denotes an entity rather than
    a relation, nor can Draft 2020-12 look up a dynamic key in another data map.
    This is a fixture check, not a new runtime resolver or identity proof.
    """
    relations = data['relations']
    entities = relations['entities']
    identities = relations['identities']
    errors = []
    for group_id, group in data['groups'].items():
        for i, member in enumerate(group['members']):
            if not isinstance(member, str) or member not in entities:
                errors.append(f'groups/{group_id}/members/{i}: ingen entitet for {member!r}')
    for entity_id, entity in entities.items():
        for identity in entity['identityRefs']:
            if identity not in identities:
                errors.append(f'relations/entities/{entity_id}/identityRefs: ukjent identitet')
    for record_id, record in relations['records'].items():
        if 'entityRef' in record['subject'] and record['subject']['entityRef'] not in entities:
            errors.append(f'relations/records/{record_id}/subject/entityRef: ukjent entitet')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--visual-dir', type=Path,
                        help='Run the historical visual checks on explicitly refreshed 22.09 artifacts.')
    args = parser.parse_args()
    checks = []

    def check(label, condition):
        if not condition:
            raise AssertionError(label)
        checks.append(label)

    schema = json.loads((HERE / 'EntityData.v2.schema.json').read_text())
    graph = json.loads((HERE / 'EntityRepresentation.v2.schema.json').read_text())
    example = json.loads((HERE / 'EntityData.v2.example.json').read_text())
    baseline = json.loads(previous.BASE.read_text())
    before = previous.target_schema(baseline)
    before_data = previous.transform_data(json.loads((HERE / 'EntityData.example.json').read_text()))
    # Keep the 22.09 regression checks usable on the single evolving target.
    latest = None
    if schema['x-haven']['decisionsAsOf'] == '2026-09-23':
        import apply_decisions_2026_09_23 as latest
    expected_artifacts = (latest or current).build_artifacts()
    expected_schema = expected_artifacts['EntityData.v2.schema.json']

    def accepted(label, value, subschema=None):
        errors = validation_errors(schema, value, subschema)
        check(label + (': ' + '; '.join(e.message for e in errors) if errors else ''), not errors)

    def rejected(label, value, subschema=None, keyword=None):
        errors = validation_errors(schema, value, subschema)
        check(label, bool(errors) and (keyword is None or any(e.validator == keyword for e in errors)))

    for name, s in [('EntityData', schema), ('EntityRepresentation', graph)]:
        check_schema(s)
        check(name + ': valid Draft 2020-12 schema', s['$schema'] == 'https://json-schema.org/draft/2020-12/schema')
        def walk(node):
            if isinstance(node, dict):
                if '$ref' in node:
                    pointer = node['$ref']
                    check(name + ': local reference ' + pointer, pointer.startswith('#/'))
                    dest = s
                    for part in pointer[2:].split('/'):
                        dest = dest[part.replace('~1', '/').replace('~0', '~')]
                for child in node.values():
                    walk(child)
            elif isinstance(node, list):
                for child in node:
                    walk(child)
        walk(s)

    for name, value in expected_artifacts.items():
        check('Reproducible bytes: ' + name, (HERE / name).read_bytes() == current.encoded(value))
    check('Historical runtime baseline SHA-256 unchanged',
          hashlib.sha256(previous.BASE.read_bytes()).hexdigest() == 'c62ca8f329d229101775158c61fdfce0b0874b0e00211820bea6fb10500c5e2f')
    if latest is None:
        check('All proofs schema untouched', schema['properties']['proofs'] == before['properties']['proofs'])
        check('All proofs example data untouched', example['proofs'] == before_data['proofs'])
    else:
        check('Proof schema follows the 23.09 successor', schema['properties']['proofs'] == expected_schema['properties']['proofs'])
        check('Proof example follows the 23.09 successor', example['proofs'] == expected_artifacts['EntityData.v2.example.json']['proofs'])
    check('Bokprosjekt subtree untouched (deferred, not migrated)',
          schema['properties']['relations']['properties']['bokprosjekt'] == before['properties']['relations']['properties']['bokprosjekt'])
    check('Standalone graph uses identical shared definitions', graph['$defs'] == schema['$defs'])
    check('Prior schema identities retained', schema['$id'] == before['$id'])
    check('22.09 source hash matches', schema['x-haven']['latestDecisionSourceSHA256'] == hashlib.sha256(current.DECISION.read_bytes()).hexdigest())

    # Scope guard: unrelated roots/definitions remain exactly as produced by 16.09.
    for key, value in before['properties'].items():
        if key != 'relations':
            if latest is not None and key == 'proofs':
                continue  # Checked above; the successor deliberately changes this root.
            check('16.09 root preserved: ' + key, schema['properties'][key] == value)
    for key, value in before['$defs'].items():
        if key != 'EntityRelationSubject':
            if latest is not None and key == 'PersonProfile':
                value = copy.deepcopy(value)
                for field, ref in [('affiliations', 'proofRefs'), ('skills', 'evidenceRefs'), ('attributes', 'proofRefs')]:
                    value['properties'][field]['items']['properties'][ref]['description'] = expected_schema['$defs'][key]['properties'][field]['items']['properties'][ref]['description']
            check('16.09 definition preserved: ' + key, schema['$defs'][key] == value)
    reserved = before['properties']['relations']['properties']
    check('Every reserved relation key retained', set(reserved) == set(schema['properties']['relations']['properties']))
    for key, value in reserved.items():
        if key not in ('entities', 'identities', 'records'):
            check('Reserved relation contract preserved: ' + key, schema['properties']['relations']['properties'][key] == value)

    accepted('Partial EntityData remains valid', {})
    check('Groups root exists', 'groups' in schema['properties'])
    accepted('Empty groups map allowed', {'groups': {}})
    accepted('Updated example validates', example)
    representation = next(iter(example['relations']['records'].values()))['entityRepresentation']
    check('Example representation validates against standalone graph schema',
          not validation_errors(graph, representation))
    rejected('Date-time format validation is active', 'not-a-date', {'type': 'string', 'format': 'date-time'}, 'format')
    check('Every group member resolves to an entity; forward edges resolve', not reference_errors(example))
    check('At least one group has two members', any(len(g['members']) >= 2 for g in example['groups'].values()))
    memberships = Counter(member for group in example['groups'].values() for member in set(group['members']))
    check('At least one entity is in two groups', any(n >= 2 for n in memberships.values()))
    group_id = next(iter(example['groups']))
    group = example['groups'][group_id]
    group_schema = schema['properties']['groups']['additionalProperties']
    rejected('Group without name rejected', {'members': group['members']}, group_schema, 'required')
    rejected('Group without members rejected', {'name': 'Venner'}, group_schema, 'required')
    rejected('Empty group name rejected', dict(group, name=''), group_schema, 'minLength')
    rejected('Weight on group rejected', dict(group, weight=0.8), group_schema, 'additionalProperties')
    rejected('Weighted member rejected', dict(group, members=[{'reference': current.ENTITY_A, 'weight': 0.8}]), group_schema)
    rejected('Embedded entity rejected', dict(group, members=[{'entityRef': current.ENTITY_A}]), group_schema)
    rejected('Non-UUID member rejected', dict(group, members=['not-a-uuid']), group_schema, 'pattern')
    rejected('Owner-defined relation list rejected', {'relations': {'venner': [current.ENTITY_A]}}, keyword='additionalProperties')
    rejected('Owner-defined relation object rejected', {'relations': {'venner': {}}}, keyword='additionalProperties')

    for path in ('entities', 'identities', 'groups'):
        node = schema['properties']['groups'] if path == 'groups' else schema['properties']['relations']['properties'][path]
        for invalid_key in ('name-based-id', '123', '{' + current.ENTITY_A + '}'):
            rejected('Non-UUID map key rejected: ' + path + '/' + invalid_key,
                     {invalid_key: group if path == 'groups' else {}}, node, 'pattern')
        accepted('UUID map key accepted: ' + path,
                 {current.ENTITY_A: group if path == 'groups' else {}}, node)
    records_schema = schema['properties']['relations']['properties']['records']
    if latest is None:
        check('Historical records UUID deferral is explicitly documented', 'propertyNames' not in records_schema and 'uuid' in records_schema['description'])
    else:
        check('Records UUID pattern enforced by 23.09 successor', records_schema['propertyNames']['pattern'] == current.UUID_PATTERN)
        record = next(iter(example['relations']['records'].values()))
        for key in ('relation-demo', 'rellea'):
            rejected('Legacy relation key rejected: ' + key, {key: record}, records_schema, 'pattern')
    accepted('Current example relation keys valid', {'relations': {'records': example['relations']['records']}})

    for root, field in [('identities', 'entityRefs'), ('entities', 'relationRefs')]:
        node = schema['properties']['relations']['properties'][root]['additionalProperties']
        check('Removed property absent: ' + root + '/' + field, field not in node['properties'])
        check('Removed property not required: ' + root + '/' + field, field not in node.get('required', []))
        for value in ([], [current.ENTITY_A], None):
            rejected('Reverse field rejected: ' + root + '/' + field + '=' + str(value),
                     {'relations': {root: {current.ENTITY_A: {field: value}}}}, keyword='not')
    check('Identity reverse decoding documented', 'ved dekoding, i minnet' in schema['properties']['relations']['properties']['entities']['additionalProperties']['properties']['identityRefs']['description'])
    check('Relation reverse decoding documented', 'ved dekoding, i minnet' in schema['$defs']['EntityRelationSubject']['properties']['entityRef']['description'])

    wrong = copy.deepcopy(example)
    relation_uuid = '40000000-0000-4000-8000-000000000099'
    record = copy.deepcopy(next(iter(example['relations']['records'].values())))
    record['relationID'] = relation_uuid
    wrong['relations']['records'][relation_uuid] = record
    wrong['groups'][group_id]['members'] = [relation_uuid]
    accepted('UUID syntax alone cannot reject relation UUID in members (known schema limit)', wrong)
    check('Fixture resolver rejects relation UUID used as entity member', bool(reference_errors(wrong)))
    wrong['groups'][group_id]['members'] = ['50000000-0000-4000-8000-000000000001']
    check('Fixture resolver rejects unknown entity UUID', bool(reference_errors(wrong)))

    # Removing each actual transformation target must raise, never silently skip.
    paths = [
        current.RELATIONS + ('additionalProperties',), current.RELATIONS + ('description',),
        current.RECORDS + ('additionalProperties',), current.RECORDS + ('description',),
        current.ENTITIES + ('type',), current.IDENTITIES + ('type',),
        current.ENTITIES + ('additionalProperties', 'properties', 'relationRefs'),
        current.IDENTITIES + ('additionalProperties', 'properties', 'entityRefs'),
        current.ENTITIES + ('additionalProperties', 'properties', 'identityRefs', 'description'),
        ('$defs', 'EntityRelationSubject', 'properties', 'entityRef'), current.PROOFS_INDEX,
        current.BOKPROSJEKT + ('properties', 'members', 'items', 'properties', 'relation', 'properties', 'groupRefs')
    ]
    for path in paths:
        broken = copy.deepcopy(before)
        del current.require(broken, *path[:-1])[path[-1]]
        try:
            current.target_schema(broken)
        except ValueError as error:
            check('Missing target fails loudly: ' + '/'.join(path), 'FANT IKKE:' in str(error))
        else:
            check('Missing target silently skipped: ' + '/'.join(path), False)
    for label, function, value in [('schema applied twice', current.target_schema, schema),
                                    ('example applied twice', current.transform_data, example),
                                    ('example without known record', current.transform_data, {'relations': {'records': {}}})]:
        try:
            function(value)
        except ValueError:
            check('Unexpected input fails loudly: ' + label, True)
        else:
            check('Unexpected input silently accepted: ' + label, False)

    not_run = [
        {'check': 'Swift/runtime, migration and decoder behavior', 'reason': 'Documentation/schema task; no Swift changes or real-data migration authorized.'}
    ]
    if args.visual_dir is None:
        not_run.append({'check': 'Historical visualization suite', 'status': 'ikke kjørt', 'reason':
            'Not run: requires refreshed external visual artifacts. Pass --visual-dir to run against 22.09; '
            'the 16.09 suite assumes owner lists, 13 roots and the earlier schema.', 'externalPath': str(VISUAL)})
    else:
        # These checks mirror the old suite; incompatible or absent inputs FAIL.
        visual = args.visual_dir
        data = json.loads((visual / 'entitydata-mock-data.json').read_text())
        payload = json.loads((visual / 'entitydata-visual-payload.json').read_text())
        accepted('Complete visualization mock', data)
        check('Visualization uses current target', json.loads((visual / 'entitydata-schema-snapshot.json').read_text()) == schema)
        check('Visualization hash matches target', payload['report']['schemaSHA256'] == hashlib.sha256((HERE / 'EntityData.v2.schema.json').read_bytes()).hexdigest())
        check('Visualization has all 14 roots', payload['report']['roots'] == 14 and 'conference' in data and 'groups' in data)
        coverage = payload['report']['propertyCoverage']
        check('Every visual property covered', coverage['covered'] == coverage['total'] and not coverage['missing'])
        check('Every visual list has multiple items', not payload['report']['arraysWithFewerThanTwoItems'])
        check('Obsolete variants not shown', not any(v['label'].startswith('Eldre ') for v in payload['variants']))
        for variant in payload['variants']:
            accepted('Visual variant ' + variant['label'], variant['data'], variant['schema'])
        check('All displayed variants checked', len(payload['variants']) == 32)
        check('Finite visual graphs', bool(payload['report']['graphs']) and all(g['nodes'] == 6 and g['references'] == 91 for g in payload['report']['graphs']))

    result = {
        'date': '2026-09-22', 'targetDecisionsAsOf': schema['x-haven']['decisionsAsOf'],
        'status': 'structural-checks-passed', 'checks': len(checks),
        'passed': checks, 'notRun': not_run, 'validator': engine(),
        'sha256': {name: hashlib.sha256((HERE / name).read_bytes()).hexdigest() for name in
                   ['EntityData.v2.schema.json', 'EntityData.v2.example.json', 'EntityRepresentation.v2.schema.json']},
        'limitations': ['Target structure only; no implemented wire contract.',
                        *(['records UUID keys documented, not enforced in historical 22.09 stage.'] if latest is None else []),
                        'Bokprosjekt migration deferred.',
                        'Reference resolution tested only for fictional fixture edges; no general identity proof.']
    }
    RESULT.write_bytes(current.encoded(result))
    print(json.dumps({key: result[key] for key in ['status', 'checks', 'validator', 'notRun']}, ensure_ascii=False))


if __name__ == '__main__':
    main()
