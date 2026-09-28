"""Schema and separate reference checks for the subgroup documentation target."""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch

import apply_decisions_2026_09_23_groups as current
import validate_decisions_2026_09_23 as proof_checks
from target_validation import check_schema, engine, validation_errors

HERE = current.HERE
RESULT = HERE / 'TARGET-VALIDATION-2026-09-23-GROUPS.json'


def historical_regressions():
    """Run unchanged old suites on their own target in an isolated temp copy."""
    with tempfile.TemporaryDirectory(prefix='entitydata-group-regression-') as temporary:
        directory = Path(temporary) / 'review'
        shutil.copytree(HERE, directory, ignore=shutil.ignore_patterns('__pycache__'))
        commands = ['apply_decisions_2026_09_23.py', 'validate_decisions_2026_09_22.py',
                    'validate_decisions_2026_09_23.py']
        for script in commands:
            result = subprocess.run([sys.executable, '-B', '-O', script], cwd=directory,
                                    capture_output=True, text=True, env=os.environ.copy())
            if result.returncode:
                raise RuntimeError(script + '\n' + result.stdout + result.stderr)
        return {date: json.loads((directory / ('TARGET-VALIDATION-' + date + '.json')).read_text())['checks']
                for date in ('2026-09-22', '2026-09-23')}


def main():
    checks = []

    def check(label, condition):
        if not condition:
            raise AssertionError(label)
        checks.append(label)

    def fails(label, action):
        try:
            action()
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

    def accepted(label, data):
        current.validate_target(schema, data)
        check(label, True)

    def rejected_shape(label, data, keyword):
        errors = validation_errors(schema, data)
        check(label, any(error.validator == keyword for error in errors))

    def rejected_reference(label, data, message):
        check('Schema limitation exposed: ' + label, not validation_errors(schema, data))
        errors = current.group_reference_errors(data)
        check('Reference check rejects: ' + label, any(message in error for error in errors))
        try:
            current.validate_target(schema, data)
        except ValueError as error:
            check('Combined target validation rejects: ' + label, message in str(error))
        else:
            check('Combined target validation rejects: ' + label, False)

    for name, value in current.build_artifacts().items():
        check('Reproducible bytes: ' + name, (HERE / name).read_bytes() == current.encoded(value))
    for name, value in (('EntityData', schema), ('EntityRepresentation', graph)):
        check_schema(value)
        check(name + ': valid Draft 2020-12 schema', value['$schema'] == 'https://json-schema.org/draft/2020-12/schema')

        def walk(node):
            if isinstance(node, dict):
                if '$ref' in node:
                    ref = node['$ref']
                    check(name + ': local ref resolves ' + ref, ref.startswith('#/') and
                          current.require(value, *[p.replace('~1', '/').replace('~0', '~') for p in ref[2:].split('/')]) is not None)
                for child in node.values():
                    walk(child)
            elif isinstance(node, list):
                for child in node:
                    walk(child)
        walk(value)
    check('Shared graph definitions unchanged and identical', graph['$defs'] == schema['$defs'] == old_schema['$defs'])
    check('Graph metadata mirrors target', graph['x-haven'] == schema['x-haven'])
    check('Existing schema IDs retained', all(actual[name]['$id'] == before[name]['$id'] for name in
          ('EntityData.v2.schema.json', 'EntityRepresentation.v2.schema.json')))
    baseline = HERE / 'EntityData.review.schema.json'
    check('Runtime baseline byte identity', hashlib.sha256(baseline.read_bytes()).hexdigest() ==
          'c62ca8f329d229101775158c61fdfce0b0874b0e00211820bea6fb10500c5e2f')
    check('Decision source hash current', schema['x-haven']['latestDecisionSourceSHA256'] ==
          hashlib.sha256(current.DECISION.read_bytes()).hexdigest())
    restored = copy.deepcopy(schema)
    for path in (current.GROUPS, current.RELATIONS):
        current.replace(restored, path, copy.deepcopy(current.require(old_schema, *path)))
    for field in ('description', '$comment', 'x-haven'):
        restored[field] = old_schema[field]
    check('Schema outside groups and relations unchanged', restored == old_schema)
    relations = copy.deepcopy(current.require(schema, *current.RELATIONS))
    old_relations = current.require(old_schema, *current.RELATIONS)
    relations['description'] = old_relations['description']
    relations['properties']['bokprosjekt'] = old_relations['properties']['bokprosjekt']
    check('Relations changed only by retirement and description', relations == old_relations)
    restored_example = copy.deepcopy(example)
    for uuid in (current.ROOT, current.CHAPTER, current.WORK_A, current.WORK_B):
        del restored_example['groups'][uuid]
    check('Existing example including proof data preserved', restored_example == old_example)
    check('Existing proof and relation references still resolve', not proof_checks.fixture_errors(example))

    accepted('Example validates: schema and references', example)
    accepted('Partial EntityData remains valid', {})
    accepted('Root without partOf accepted', {'groups': {current.ROOT: {'name': 'Fiktiv rot', 'members': []}}})
    accepted('Parent group UUID accepted', {'groups': {
        current.ROOT: {'name': 'Fiktiv rot', 'members': []},
        current.CHAPTER: {'name': 'Fiktivt kapittel', 'members': [], 'partOf': current.ROOT}}})
    groups = example['groups']
    check('Example root has no parent', 'partOf' not in groups[current.ROOT])
    check('Example chapter points to root', groups[current.CHAPTER]['partOf'] == current.ROOT)
    check('Example two workgroups point to same chapter', all(groups[key]['partOf'] == current.CHAPTER for key in (current.WORK_A, current.WORK_B)))
    check('Example workgroup has entity member', current.ENTITY_A in groups[current.WORK_A]['members'])
    children = {}
    for uuid, group in groups.items():
        if 'partOf' in group:
            children.setdefault(group['partOf'], []).append(uuid)
    check('Child lists reconstruct solely from partOf', children == {
        current.ROOT: [current.CHAPTER], current.CHAPTER: [current.WORK_A, current.WORK_B]})
    check('Only name and members required', current.require(schema, *current.GROUP, 'required') == ['name', 'members'])
    for value, keyword in [('not-a-uuid', 'pattern'), (current.ROOT + '\n', 'maxLength'), (None, 'type'), ([], 'type')]:
        wrong = copy.deepcopy(example)
        wrong['groups'][current.CHAPTER]['partOf'] = value
        rejected_shape('Invalid partOf rejected: ' + repr(value), wrong, keyword)
    for field in ('name', 'members'):
        wrong = copy.deepcopy(example)
        del wrong['groups'][current.ROOT][field]
        rejected_shape('Required group field missing: ' + field, wrong, 'required')
    for field in ('children', 'parts', 'subgroups', 'groups'):
        wrong = copy.deepcopy(example)
        wrong['groups'][current.ROOT][field] = [current.CHAPTER]
        rejected_shape('Persisted child-list field rejected: ' + field, wrong, 'additionalProperties')
    wrong = copy.deepcopy(example)
    wrong['relations']['bokprosjekt'] = {'members': [], 'groups': []}
    rejected_shape('Retired relations.bokprosjekt rejected', wrong, 'additionalProperties')
    for label, member, message in [('group UUID', current.CHAPTER, 'group UUID is forbidden'),
                                   ('relation UUID', current.previous.RELATION_UUID, 'unknown entity UUID'),
                                   ('unknown UUID', '90000000-0000-4000-8000-000000000009', 'unknown entity UUID')]:
        wrong = copy.deepcopy(example)
        wrong['groups'][current.WORK_A]['members'] = [member]
        rejected_reference(label + ' in members', wrong, message)
    for label, parent in [('entity UUID', current.ENTITY_A), ('unknown UUID', '90000000-0000-4000-8000-000000000009')]:
        wrong = copy.deepcopy(example)
        wrong['groups'][current.WORK_A]['partOf'] = parent
        rejected_reference(label + ' in partOf', wrong, 'unknown parent group UUID')
    for label, parent in [('self cycle', current.ROOT), ('three-level cycle', current.WORK_A)]:
        wrong = copy.deepcopy(example)
        wrong['groups'][current.ROOT]['partOf'] = parent
        rejected_reference(label, wrong, 'cycle')
    # Prove type checking uses maps, not the fixture's convenient UUID prefixes.
    arbitrary = 'abcdefab-cdef-4abc-8def-abcdefabcdef'
    wrong = copy.deepcopy(example)
    wrong['groups'][arbitrary] = {'name': 'Fiktiv gruppe', 'members': []}
    wrong['groups'][current.WORK_A]['members'] = [arbitrary.upper()]
    rejected_reference('arbitrary group UUID with uppercase member', wrong, 'group UUID is forbidden')
    wrong['relations']['entities'][arbitrary] = {'identityRefs': []}
    rejected_reference('group UUID also present in entities', wrong, 'group UUID is forbidden')
    arbitrary_entity = {'relations': {'entities': {arbitrary: {'identityRefs': []}}},
                        'groups': {current.ROOT: {'name': 'Fiktiv rot', 'members': [arbitrary.upper()]}}}
    accepted('Arbitrary entity UUID accepted without type prefix', arbitrary_entity)

    # Trace every existing path read by each transform; deletion must fail loudly.
    for label, transform, source in [('schema', current.target_schema, old_schema),
                                      ('example', current.transform_data, old_example)]:
        paths = set()
        original_require = current.require

        def trace(value, *path):
            if path and isinstance(value, dict) and (
                    ('$schema' in value and 'properties' in value) or ('relations' in value and 'groups' in value)):
                paths.add(path)
            return original_require(value, *path)

        with patch.object(current, 'require', trace):
            transform(source)
        for path in sorted(paths):
            broken = copy.deepcopy(source)
            del original_require(broken, *path[:-1])[path[-1]]
            fails('Missing ' + label + ' target fails: ' + '/'.join(path), lambda: transform(broken))
    fails('Schema cannot be applied twice', lambda: current.target_schema(schema))
    fails('Example cannot be applied twice', lambda: current.transform_data(example))
    for name, fields in {'current-review.json': ['schema', 'graphSchema', 'example', 'buildSteps', 'buildCommand', 'validationCommand'],
                         'EntityRepresentation.v2.schema.json': ['$defs', 'x-haven']}.items():
        for field in fields:
            broken = copy.deepcopy(before)
            del broken[name][field]
            with patch.object(current.previous, 'build_artifacts', return_value=broken):
                fails('Missing build target fails: ' + name + '/' + field, current.build_artifacts)
    historical = historical_regressions()
    check('Unchanged historical suites pass on prior target in temp copy', all(count > 0 for count in historical.values()))
    result = {
        'date': '2026-09-23', 'status': 'schema-and-reference-checks-passed',
        'checks': len(checks), 'passed': checks, 'validator': engine(),
        'historicalRegressionChecks': historical,
        'sha256': {name: hashlib.sha256((HERE / name).read_bytes()).hexdigest() for name in actual},
        'limitations': [
            'JSON Schema validates structure and UUID syntax, not cross-map reference type/existence or partOf cycles.',
            'Group UUID members and cycles are rejected by separate Python documentation checks. The Swift decoder must enforce these rules.',
            'No Swift implementation or real-data migration; UUID prefixes do not encode entity/group type.'
        ],
        'notRun': [
            {'check': 'Visualiseringssjekker', 'status': 'ikke kjørt',
             'reason': 'Historisk suite leser utdaterte eksterne 16.09/17.09-artefakter; ingen oppdaterte undergruppeartefakter eller suite er levert.'},
            {'check': 'Swift/runtime og migrering', 'status': 'ikke kjørt',
             'reason': 'Bare dokumentasjon og målskjema er endret; ny dekoder er ikke implementert.'}
        ]
    }
    if result['validator'].startswith('Ajv '):
        result['notRun'].append({'check': 'Python jsonschema-banen', 'status': 'ikke kjørt',
                                'reason': 'Eksplisitt lokal Ajv-bane brukt; jsonschema er ikke installert i dette miljøet.'})
    RESULT.write_bytes(current.encoded(result))
    print(json.dumps({key: result[key] for key in ('status', 'checks', 'validator', 'historicalRegressionChecks', 'notRun')}, ensure_ascii=False))


if __name__ == '__main__':
    main()
