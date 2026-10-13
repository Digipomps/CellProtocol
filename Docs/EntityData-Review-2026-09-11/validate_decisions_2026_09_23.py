"""Positive/negative checks for the 23.09 documentation target, not Swift behavior."""
import copy
import hashlib
import json
from unittest.mock import patch

import apply_decisions_2026_09_23 as current
import validate_decisions_2026_09_22 as prior_checks
from target_validation import check_schema, engine, validation_errors

HERE = current.HERE
RESULT = HERE / 'TARGET-VALIDATION-2026-09-23.json'


def without_annotations(value):
    if isinstance(value, dict):
        return {k: without_annotations(v) for k, v in value.items() if k not in ('description', 'x-haven')}
    if isinstance(value, list):
        return [without_annotations(v) for v in value]
    return value


def fixture_index(data):
    """Illustrate derivation solely from stored records; not a runtime decoder."""
    result = {}
    for uuid, record in sorted(data['proofs']['credentials'].items()):
        for keypath in record['supports']['keypaths']:
            result.setdefault(keypath, []).append(uuid)
    return result


def fixture_errors(data):
    """Resolve this fictional fixture only; no general escaped-keypath resolver."""
    errors = prior_checks.reference_errors(data)
    for uuid, relation in data['relations']['records'].items():
        if relation['relationID'] != uuid:
            errors.append('Relation ID differs from map key: ' + uuid)
        try:
            contact = current.resolve_fixture_keypath(data, relation['subject']['validatedContactRef'])
            if contact['relationID'] != uuid:
                errors.append('Contact relationID differs from relation: ' + uuid)
        except ValueError as error:
            errors.append(str(error))
    credentials = data['proofs']['credentials']
    for uuid, record in credentials.items():
        if uuid != record['uuid']:
            errors.append('Credential uuid differs from map key: ' + uuid)
        if record['supports']['entityRef'] not in data['relations']['entities']:
            errors.append('Unknown supports.entityRef: ' + uuid)
        for keypath in record['supports']['keypaths']:
            node = data
            # The fixture deliberately uses plain dot-separated keys only.
            for part in keypath.split('.'):
                if not isinstance(node, dict) or part not in node:
                    errors.append('Unresolved fixture keypath: ' + keypath)
                    break
                node = node[part]

    def walk(node):
        if isinstance(node, dict):
            for name, value in node.items():
                if name in ('proofRefs', 'evidenceRefs'):
                    for ref in value:
                        if not isinstance(ref, str) or ref not in credentials:
                            errors.append('Unresolved proof ref: ' + repr(ref))
                walk(value)
        elif isinstance(node, list):
            for child in node:
                walk(child)
    walk(data)
    return errors


def main():
    checks = []

    def check(label, condition):
        if not condition:
            raise AssertionError(label)
        checks.append(label)

    def fails(label, function):
        try:
            function()
        except ValueError as error:
            check(label, any(marker in str(error) for marker in ('FANT IKKE:', 'UVENTET FORM:', 'FINNES ALLEREDE:')))
        else:
            check(label, False)

    before = current.previous.build_artifacts()
    actual = {name: json.loads((HERE / name).read_text()) for name in before}
    schema = actual['EntityData.v2.schema.json']
    graph = actual['EntityRepresentation.v2.schema.json']
    example = actual['EntityData.v2.example.json']
    old_schema = before['EntityData.v2.schema.json']
    old_example = before['EntityData.v2.example.json']

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
                    ref = node['$ref']
                    check(name + ': local reference resolves ' + ref,
                          ref.startswith('#/') and current.require(s, *[p.replace('~1', '/').replace('~0', '~') for p in ref[2:].split('/')]) is not None)
                for child in node.values():
                    walk(child)
            elif isinstance(node, list):
                for child in node:
                    walk(child)
        walk(s)

    for name, value in current.build_artifacts().items():
        check('Reproducible bytes: ' + name, (HERE / name).read_bytes() == current.encoded(value))
    check('Shared graph definitions identical', graph['$defs'] == schema['$defs'])
    check('Existing schema identities retained', all(actual[name]['$id'] == before[name]['$id'] for name in ('EntityData.v2.schema.json', 'EntityRepresentation.v2.schema.json')))
    check('Decision source SHA-256 current', schema['x-haven']['latestDecisionSourceSHA256'] == hashlib.sha256(current.DECISION.read_bytes()).hexdigest())
    check('Historical runtime baseline unchanged', hashlib.sha256(current.previous.previous.BASE.read_bytes()).hexdigest() == 'c62ca8f329d229101775158c61fdfce0b0874b0e00211820bea6fb10500c5e2f')

    # Exact scope guard: restore ONLY allowed changes, then compare the whole schema.
    restored = copy.deepcopy(schema)
    for path in (current.CREDENTIALS, current.INDEX, current.previous.RECORDS):
        current.replace(restored, path, copy.deepcopy(current.require(old_schema, *path)))
    for path in current.REF_DESCRIPTIONS:
        old = current.require(old_schema, *path)
        new = current.require(schema, *path)
        check('Ref shape unchanged: ' + '/'.join(path),
              {k: v for k, v in new.items() if k != 'description'} == {k: v for k, v in old.items() if k != 'description'})
        check('Ref names credential UUID store: ' + '/'.join(path), 'uuid' in new['description'] and 'proofs.credentials' in new['description'])
        current.replace(restored, path + ('description',), old['description'])
    for key in ('title', 'description', '$comment', 'x-haven'):
        restored[key] = old_schema[key]
    check('All other 22.09 schema content unchanged (including groups and bokprosjekt)', restored == old_schema)
    check('Index shape retained', without_annotations(current.require(schema, *current.INDEX)) == without_annotations(current.require(old_schema, *current.INDEX)))
    for path in (current.INDEX, current.BY_KEYPATH, current.INDEX_VALUES):
        metadata = current.require(schema, *path, 'x-haven')
        check('Derived and not persisted: ' + '/'.join(path), metadata['derived'] and metadata['persisted'] is False and metadata['storageDomain'] == 'memory' and metadata['runtimeImplemented'] is False)
    check('All four proof reference fields covered', current.proof_ref_paths(schema) == set(current.REF_DESCRIPTIONS))
    record_schema = current.require(schema, *current.RECORD)
    check('Only six requested VCClaim fields plus supports described', set(record_schema['properties']) == {'uuid', 'type', 'issuer', 'issuanceDate', 'credentialSubject', 'proof', 'supports'})
    for text in (record_schema['properties']['supports']['description'], current.require(schema, *current.BY_KEYPATH, 'description')):
        check('Lookup makes no truth/validity/issuer-trust/consent claim', all(word in text for word in ('sannhet', 'gyldighet', 'utstedertillit', 'samtykke')))
        check('Swift implementation explicitly pending', 'ikke implementert i Swift' in text)
    restored_data = copy.deepcopy(example)
    del restored_data['proofs']['credentials']
    del restored_data['relations']['identities'][current.previous.IDENTITY_A]['proofRefs']
    check('Example changes confined to credential, proof reference and relation UUID rewrite',
          restored_data == current.rewrite_relation_ids(old_example))

    relations_schema = current.require(schema, *current.previous.RECORDS)
    relation = example['relations']['records'][current.RELATION_UUID]
    check('Relations use the shared UUID pattern', relations_schema['propertyNames'] == {
        'pattern': current.UUID_PATTERN, 'maxLength': 36})
    check('Records UUID deferral removed', 'relations.records.propertyNames' not in schema['x-haven']['deferredDecisions'])
    for invalid_key in ('relation-demo', 'rellea', 'name-based-id', '123', '{' + current.RELATION_UUID + '}'):
        rejected('Non-UUID relation key rejected: ' + invalid_key,
                 {invalid_key: relation}, relations_schema, 'pattern')
    rejected('Relation UUID with newline rejected', {current.RELATION_UUID + '\n': relation}, relations_schema, 'maxLength')
    accepted('UUID relation key accepted', {current.RELATION_UUID: relation}, relations_schema)
    check('Relation representation validates against standalone graph',
          not validation_errors(graph, relation['entityRepresentation']))
    check('No legacy relation IDs remain anywhere in target example',
          not any(old in json.dumps(example) for old in current.RELATION_UUIDS))

    # Exercise both legacy IDs and both proof-path locations, even though the
    # published example only has relation-demo and no persisted proof index.
    legacy = copy.deepcopy(old_example)
    legacy['relations']['records']['rellea'] = copy.deepcopy(legacy['relations']['records']['relation-demo'])
    legacy['relations']['records']['rellea']['relationID'] = 'rellea'
    legacy['relations']['records']['rellea']['subject']['validatedContactRef'] = 'relations.validatedContacts.rellea'
    legacy['relations']['validatedContacts']['rellea'] = copy.deepcopy(legacy['relations']['validatedContacts']['relation-demo'])
    legacy['relations']['validatedContacts']['rellea']['relationID'] = 'rellea'
    paths = ['relations.records.' + old + '.entityRepresentation.name' for old in current.RELATION_UUIDS]
    legacy['proofs']['credentials'] = copy.deepcopy(example['proofs']['credentials'])
    legacy['proofs']['credentials'][current.PROOF_UUID]['supports']['keypaths'] = paths
    legacy['proofs']['index'] = {'byKeypath': {path: [current.PROOF_UUID] for path in paths}}
    rewritten = current.rewrite_relation_ids(legacy)
    expected_paths = ['relations.records.' + uuid + '.entityRepresentation.name' for uuid in current.RELATION_UUIDS.values()]
    check('Both fixed relation UUIDs used', list(rewritten['relations']['records']) == list(current.RELATION_UUIDS.values()))
    check('supports.keypaths rewritten', rewritten['proofs']['credentials'][current.PROOF_UUID]['supports']['keypaths'] == expected_paths)
    check('byKeypath keys rewritten with proof refs preserved', rewritten['proofs']['index']['byKeypath'] == {path: [current.PROOF_UUID] for path in expected_paths})
    check('Rewritten proof paths agree with derived index', fixture_index(rewritten) == rewritten['proofs']['index']['byKeypath'])
    check('All rewritten fixture refs resolve', not fixture_errors(rewritten))
    accepted('Rewritten validator fixture validates all UUID-keyed maps', rewritten)
    check('No legacy relation IDs remain anywhere in rewritten fixture',
          not any(old in json.dumps(rewritten) for old in current.RELATION_UUIDS))
    for label, mutate in [
        ('unknown old-ID location', lambda d: d.update(unexplained='relation-demo')),
        ('unknown old-ID endpoint', lambda d: d.update(cellReference='cell:///Unknown/relation-demo')),
        ('dangling proof keypath', lambda d: d['proofs']['credentials'][current.PROOF_UUID]['supports'].update(keypaths=['relations.records.rellea.absent'])),
        ('dangling index keypath', lambda d: d['proofs']['index']['byKeypath'].update({'relations.records.absent.entityRepresentation': [current.PROOF_UUID]})),
        ('unsupported keypath escaping', lambda d: d['proofs']['credentials'][current.PROOF_UUID]['supports'].update(keypaths=['relations.records[relationID="rellea"]'])),
        ('UUID map collision', lambda d: d['relations']['records'].update({current.RELATION_UUID: relation})),
        ('missing contact target', lambda d: d['relations']['validatedContacts'].pop('rellea')),
        ('record ID mismatch', lambda d: d['relations']['records']['rellea'].update(relationID='relation-demo'))
    ]:
        broken = copy.deepcopy(legacy)
        mutate(broken)
        fails('UUID rewrite stops on ' + label, lambda: current.rewrite_relation_ids(broken))

    accepted('Partial EntityData still valid', {})
    accepted('Empty credential store valid', {'proofs': {'credentials': {}}})
    accepted('Updated example validates', example)
    check('All example UUID refs and simple keypaths resolve', not fixture_errors(example))
    check('Example has no persisted index', 'index' not in example['proofs'])
    check('Example has a proofRefs link to stored proof', example['relations']['identities'][current.previous.IDENTITY_A]['proofRefs'] == [current.PROOF_UUID])
    expected_index = {current.SUPPORTED_KEYPATH: [current.PROOF_UUID]}
    check('Lookup reconstructs from records alone', fixture_index(example) == expected_index)
    accepted('Documented derived lookup form validates', expected_index, current.require(schema, *current.BY_KEYPATH))
    wrong = copy.deepcopy(example)
    wrong['proofs']['index'] = {'byKeypath': {'irrelevant.cached.path': ['stale']}}
    check('Reconstruction ignores supplied stale lookup', fixture_index(wrong) == expected_index)

    credentials_schema = current.require(schema, *current.CREDENTIALS)
    record = example['proofs']['credentials'][current.PROOF_UUID]
    for key in ('not-a-uuid', '123', '{' + current.PROOF_UUID + '}'):
        rejected('Non-UUID credential key rejected: ' + key, {key: record}, credentials_schema, 'pattern')
    rejected('UUID key with trailing newline rejected', {current.PROOF_UUID + '\n': record}, credentials_schema, 'maxLength')
    accepted('UUID key accepted', {current.PROOF_UUID: record}, credentials_schema)
    for field in record:
        wrong_record = copy.deepcopy(record)
        del wrong_record[field]
        rejected('Required credential field rejected when absent: ' + field, wrong_record, record_schema, 'required')
    for field in ('entityRef', 'keypaths'):
        wrong_record = copy.deepcopy(record)
        del wrong_record['supports'][field]
        rejected('Incomplete supports rejected: ' + field, wrong_record, record_schema, 'required')
    for label, value, keyword in [
        ('null', None, 'type'), ('empty', {}, 'required'),
        ('non-UUID entity', {'entityRef': 'name', 'keypaths': ['person.name']}, 'pattern'),
        ('entity UUID with newline', {'entityRef': current.previous.ENTITY_A + '\n', 'keypaths': ['person.name']}, 'maxLength'),
        ('no keypaths', {'entityRef': current.previous.ENTITY_A, 'keypaths': []}, 'minItems'),
        ('blank keypath', {'entityRef': current.previous.ENTITY_A, 'keypaths': ['']}, 'minLength'),
        ('numeric keypath', {'entityRef': current.previous.ENTITY_A, 'keypaths': [7]}, 'type'),
        ('repeated keypath', {'entityRef': current.previous.ENTITY_A, 'keypaths': ['person.name', 'person.name']}, 'uniqueItems')
    ]:
        rejected('Malformed supports rejected: ' + label, {**record, 'supports': value}, record_schema, keyword)
    for field, value, keyword in [('uuid', 'name', 'pattern'), ('type', 'VC', 'type'),
                                  ('uuid', current.PROOF_UUID + '\n', 'maxLength'),
                                  ('issuer', 1, 'anyOf'), ('issuanceDate', 'not-a-date', 'format'),
                                  ('credentialSubject', [], 'type'), ('proof', 'signed', 'type')]:
        rejected('Invalid VCClaim field rejected: ' + field, {**record, field: value}, record_schema, keyword)
    rejected('Undescribed side field rejected', {**record, 'valid': True}, record_schema, 'additionalProperties')
    accepted('Embedded issuer accepted', {**record, 'issuer': {'id': 'did:example:issuer'}}, record_schema)
    accepted('Multiple supported keypaths accepted', {**record, 'supports': {'entityRef': current.previous.ENTITY_A, 'keypaths': [current.SUPPORTED_KEYPATH, 'person.name']}}, record_schema)
    for label, mutate in [
        ('mismatched record uuid', lambda d: d['proofs']['credentials'][current.PROOF_UUID].update(uuid=current.previous.ENTITY_B)),
        ('unknown entity', lambda d: d['proofs']['credentials'][current.PROOF_UUID]['supports'].update(entityRef=current.PROOF_UUID)),
        ('unknown keypath', lambda d: d['proofs']['credentials'][current.PROOF_UUID]['supports'].update(keypaths=['person.absent'])),
        ('unknown proof ref', lambda d: d['relations']['identities'][current.previous.IDENTITY_A].update(proofRefs=[current.previous.ENTITY_B]))
    ]:
        wrong = copy.deepcopy(example)
        mutate(wrong)
        accepted('Known schema limit: ' + label, wrong)
        check('Fixture check rejects ' + label, bool(fixture_errors(wrong)))

    # Trace every schema-root lookup actually used by the transformer, then remove
    # each target. This covers metadata and descriptions as well as data shapes.
    paths = set()
    original_require = current.require

    def traced_require(value, *path):
        if path and isinstance(value, dict) and '$schema' in value and 'properties' in value:
            paths.add(path)
        return original_require(value, *path)

    with patch.object(current, 'require', traced_require), patch.object(current.previous, 'require', traced_require):
        current.target_schema(old_schema)
    for path in sorted(paths):
        broken = copy.deepcopy(old_schema)
        del current.require(broken, *path[:-1])[path[-1]]
        fails('Missing schema target fails loudly: ' + '/'.join(path), lambda: current.target_schema(broken))
    for path in (('proofs',), ('relations', 'records', 'relation-demo'),
                 ('relations', 'entities', current.previous.ENTITY_A),
                 ('relations', 'identities', current.previous.IDENTITY_A, 'domain')):
        broken = copy.deepcopy(old_example)
        del current.require(broken, *path[:-1])[path[-1]]
        fails('Missing example target fails loudly: ' + '/'.join(path), lambda: current.transform_data(broken))
    fails('Schema step applied twice fails loudly', lambda: current.target_schema(schema))
    fails('Example step applied twice fails loudly', lambda: current.transform_data(example))
    for field in ('properties', 'required', 'additionalProperties'):
        broken = copy.deepcopy(old_schema)
        current.require(broken, *current.RECORD)[field] = {}
        fails('Unexpected pre-existing record contract fails loudly: ' + field, lambda: current.target_schema(broken))
    for name, fields in {'current-review.json': ['schema', 'graphSchema', 'example', 'buildSteps', 'updatedAt', 'decisionsAsOf', 'buildCommand', 'validationCommand'],
                         'EntityRepresentation.v2.schema.json': ['title', '$defs', 'x-haven']}.items():
        for field in fields:
            broken = copy.deepcopy(before)
            del broken[name][field]
            with patch.object(current.previous, 'build_artifacts', return_value=broken):
                fails('Missing build target fails loudly: ' + name + '/' + field, current.build_artifacts)

    selected_engine = engine()
    result = {
        'date': '2026-09-23', 'status': 'structural-checks-passed', 'checks': len(checks),
        'passed': checks, 'validator': selected_engine,
        'notRun': [
            {'check': 'Visualiseringssjekker', 'status': 'ikke kjørt',
             'reason': 'Den historiske suiten leser eksterne, utdaterte 16.09/17.09-artefakter. Ingen oppdaterte 23.09-artefakter er levert; ingen visualiseringssuksess påstås.',
             'externalPath': str(prior_checks.VISUAL)},
            {'check': 'Swift/runtime, ekte dekoding og datamigrering', 'status': 'ikke kjørt',
             'reason': 'Dokumentasjons-/skjemaoppgave. supports og det nye dekodingsoppslaget er ikke implementert i Swift.'}
        ],
        'sha256': {name: hashlib.sha256((HERE / name).read_bytes()).hexdigest() for name in actual},
        'limitations': ['Structural target only, not a full VCClaim wire contract or signature validation.',
                        'Reference resolution, UUID/key equality and keypath existence require separate checks; only the fictional fixture is resolved here.',
                        'x-haven.persisted=false documents the target; JSON Schema does not enforce runtime storage behavior.',
                        'The existing proofRefs/evidenceRefs and byKeypath array shapes remain unchanged.',
                        'Bokprosjekt remains deferred; records UUID keys are now enforced.',
                        'Fictional cell endpoint rewritten consistently; no live endpoint or general escaped-keypath resolver tested.']
    }
    if selected_engine.startswith('Ajv '):
        result['notRun'].append({'check': 'Python jsonschema validator', 'status': 'ikke kjørt',
                                 'reason': 'Python-banen ble ikke brukt; eksplisitt valgt lokal Ajv validerer skjema og formater, uten nedlasting.'})
    RESULT.write_bytes(current.encoded(result))
    print(json.dumps({key: result[key] for key in ('status', 'checks', 'validator', 'notRun')}, ensure_ascii=False))


if __name__ == '__main__':
    main()
