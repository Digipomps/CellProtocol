"""Verify skills-as-purposes, expose proof addressing limits, retain old checks."""
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

import apply_decisions_2026_09_25_skills as current
import validate_decisions_2026_09_23 as proof_checks
from target_validation import check_schema, engine, validation_errors

HERE = current.HERE
RESULT = HERE / 'TARGET-VALIDATION-2026-09-25-SKILLS.json'


def historical_regressions():
    """Old suites assert historical byte identity; run on their own target only."""
    with tempfile.TemporaryDirectory(prefix='entitydata-skills-regression-') as temporary:
        directory = Path(temporary) / 'review'
        shutil.copytree(HERE, directory, ignore=shutil.ignore_patterns('__pycache__'))
        for script in ('apply_decisions_2026_09_23_groups.py',
                       'validate_decisions_2026_09_23_groups.py'):
            result = subprocess.run([sys.executable, '-B', '-O', script], cwd=directory,
                                    capture_output=True, text=True, env=os.environ.copy())
            if result.returncode:
                raise RuntimeError(script + '\n' + result.stdout + result.stderr)
        result = json.loads((directory / 'TARGET-VALIDATION-2026-09-23-GROUPS.json').read_text())
        return {**result['historicalRegressionChecks'], '2026-09-23-GROUPS': result['checks']}


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
            check(label, any(marker in str(error) for marker in
                             ('FANT IKKE:', 'UVENTET FORM:', 'FINNES ALLEREDE:')))
        else:
            check(label, False)

    before = current.previous.build_artifacts()
    actual = {name: json.loads((HERE / name).read_text()) for name in before}
    schema = actual['EntityData.v2.schema.json']
    graph = actual['EntityRepresentation.v2.schema.json']
    example = actual['EntityData.v2.example.json']
    old_schema = before['EntityData.v2.schema.json']
    old_example = before['EntityData.v2.example.json']

    def accepted(label, data, subschema=None, target=schema):
        check(label, not validation_errors(target, data, subschema))

    def rejected(label, data, keyword, subschema=None, target=schema):
        errors = validation_errors(target, data, subschema)
        check(label, any(error.validator == keyword for error in errors))

    for name, value in current.build_artifacts().items():
        check('Reproducible bytes: ' + name, (HERE / name).read_bytes() == current.encoded(value))
    for name, value in (('EntityData', schema), ('EntityRepresentation', graph)):
        check_schema(value)
        check(name + ': valid Draft 2020-12 schema',
              value['$schema'] == 'https://json-schema.org/draft/2020-12/schema')

        def walk(node):
            if isinstance(node, dict):
                if '$ref' in node:
                    ref = node['$ref']
                    check(name + ': local ref resolves ' + ref, ref.startswith('#/') and
                          current.require(value, *[p.replace('~1', '/').replace('~0', '~')
                                                   for p in ref[2:].split('/')]) is not None)
                for child in node.values():
                    walk(child)
            elif isinstance(node, list):
                for child in node:
                    walk(child)
        walk(value)

    check('Shared definitions identical', graph['$defs'] == schema['$defs'])
    check('Graph metadata mirrors target', graph['x-haven'] == schema['x-haven'])
    check('Schema IDs retained', all(actual[name]['$id'] == before[name]['$id'] for name in
          ('EntityData.v2.schema.json', 'EntityRepresentation.v2.schema.json')))
    check('Runtime baseline unchanged', hashlib.sha256((HERE / 'EntityData.review.schema.json').read_bytes()).hexdigest() ==
          'c62ca8f329d229101775158c61fdfce0b0874b0e00211820bea6fb10500c5e2f')
    check('Decision source hash current', schema['x-haven']['latestDecisionSourceSHA256'] ==
          hashlib.sha256(current.DECISION.read_bytes()).hexdigest())
    check('No Skill or SearchPurpose type introduced', set(schema['$defs']) == set(old_schema['$defs']) and
          not {'Skill', 'SearchPurpose'}.intersection(schema['$defs']))
    check('PersonProfile.skills completely removed from properties',
          'skills' not in schema['$defs']['PersonProfile']['properties'])
    check('No evidenceRefs field remains in target', all(path[-1] != 'evidenceRefs'
          for path in current.previous.previous.proof_ref_paths(schema)))
    check('No skills entries anywhere in example', not current.skill_paths(example))

    # Undo only this task's exact allowed deltas; everything else must be identical.
    restored = copy.deepcopy(schema)
    profile = restored['$defs']['PersonProfile']
    del profile['not']
    profile['properties']['skills'] = old_schema['$defs']['PersonProfile']['properties']['skills']
    profile['description'] = old_schema['$defs']['PersonProfile']['description']
    for path in current.DESCRIPTION_PATHS:
        current.replace(restored, path, current.require(old_schema, *path))
    for field in ('title', 'description', '$comment', 'x-haven'):
        restored[field] = old_schema[field]
    check('Entire schema outside approved deltas unchanged', restored == old_schema)
    check('Proof store and supports contract unchanged', schema['properties']['proofs'] == old_schema['properties']['proofs'])
    check('Required goal and Purpose fields unchanged', schema['$defs']['Purpose']['required'] ==
          old_schema['$defs']['Purpose']['required'] and schema['$defs']['Purpose']['properties'] ==
          old_schema['$defs']['Purpose']['properties'])
    restored_graph = copy.deepcopy(graph)
    for field in ('$defs', 'x-haven', 'title'):
        restored_graph[field] = before['EntityRepresentation.v2.schema.json'][field]
    check('Graph outside shared definitions, metadata and title unchanged',
          restored_graph == before['EntityRepresentation.v2.schema.json'])
    restored_example = copy.deepcopy(example)
    del restored_example['entityRepresentation']
    check('All previous example data including proofs unchanged', restored_example == old_example)
    check('Existing proof and relation references resolve', not proof_checks.fixture_errors(example))
    check('Existing group references resolve', not current.previous.group_reference_errors(example))
    check('No persisted proof index in example', 'index' not in example['proofs'])

    accepted('Complete example validates', example)
    accepted('Partial EntityData accepted', {})
    accepted('Unrelated profile extension retained', {'person': {'fictionalExtension': 'still open'}})
    representation = example['entityRepresentation']
    purpose = representation['purposes'][0]['value']
    accepted('Owner representation uses existing complete node form', representation,
             {'$ref': '#/$defs/EntityRepresentation'}, target=graph)
    accepted('Skill is an ordinary Purpose', purpose, {'$ref': '#/$defs/Purpose'})
    check('Skill has stable fictional node ID', purpose['nodeIdentifier'] == current.SKILL_UUID)
    check('Skill goal states countable completion criteria', all(text in purpose['goal']['description']
          for text in ('nøyaktig tre sider', 'alle tre kan åpnes', 'null brutte lenker', 'Fiktiv')))
    check('Descriptions state intentional measurable-result requirement', all(
          current.SKILL_DESCRIPTION in current.require(schema, *path) for path in current.DESCRIPTION_PATHS))
    for value in ([], [{'label': 'Fiktiv skill', 'level': 'demo', 'taxonomyRef': 'example',
                       'evidenceRefs': []}], None, {}, 'derived view'):
        rejected('person.skills rejected regardless of value: ' + repr(value),
                 {'person': {'skills': value}}, 'not')
    for value in (schema, graph):
        rejected('Shared PersonProfile forbids skills in ' + value['title'], {'skills': []}, 'not',
                 {'$ref': '#/$defs/PersonProfile'}, target=value)
    wrong = copy.deepcopy(example)
    wrong['relations']['records'][current.previous.previous.RELATION_UUID]['entityRepresentation']['person']['skills'] = []
    rejected('Typed contact person.skills rejected', wrong, 'not')
    for value in ('absent', None):
        wrong = copy.deepcopy(example)
        node = wrong['entityRepresentation']['purposes'][0]['value']
        if value == 'absent':
            del node['goal']
        else:
            node['goal'] = value
        rejected('Skill without usable goal rejected: ' + str(value), wrong,
                 'required' if value == 'absent' else 'type')
    vague = copy.deepcopy(purpose)
    vague['goal'] = {'name': 'FiktivtTomtMaal'}
    accepted('Schema limitation: goal object alone does not prove measurability',
             vague, {'$ref': '#/$defs/Purpose'})

    # Show the actual gap without inventing a selector or accepting it as a contract.
    candidate_paths = [
        'entityRepresentation.purposes.0.value',
        'entityRepresentation.purposes[value.nodeIdentifier="' + current.SKILL_UUID + '"].value',
    ]
    for keypath in candidate_paths:
        wrong = copy.deepcopy(example)
        proof_uuid = current.previous.previous.PROOF_UUID
        wrong['proofs']['credentials'][proof_uuid]['supports']['keypaths'] = [keypath]
        accepted('Schema limitation: unverified node path is only a string: ' + keypath, wrong)
        fails('Existing resolver cannot resolve skill path: ' + keypath,
              lambda: current.previous.previous.resolve_fixture_keypath(wrong, keypath))
        check('Existing proof checker reports unresolved skill path: ' + keypath,
              any('Unresolved fixture keypath' in error for error in proof_checks.fixture_errors(wrong)))
    check('Container path resolves a list, not a Purpose node', isinstance(
          current.previous.previous.resolve_fixture_keypath(example, 'entityRepresentation.purposes'), list))
    check('Proof addressing blocker recorded', schema['x-haven']['deferredDecisions']['skills.proofNodeAddressing'] == current.EVIDENCE_BLOCKER)

    # Current-target regression sentinels; exact equality above covers unchanged contracts.
    wrong = copy.deepcopy(example)
    wrong['relations']['bokprosjekt'] = {}
    rejected('Retired bokprosjekt still rejected', wrong, 'additionalProperties')
    wrong = copy.deepcopy(example)
    wrong['groups'][current.previous.ROOT]['partOf'] = current.previous.WORK_A
    accepted('Schema still cannot detect group cycles', wrong)
    check('Separate reference check still rejects group cycles', any('cycle' in error
          for error in current.previous.group_reference_errors(wrong)))
    wrong = copy.deepcopy(example)
    wrong['groups'][current.previous.WORK_A]['members'] = [current.previous.CHAPTER]
    check('Separate check still rejects group member UUID', any('group UUID is forbidden' in error
          for error in current.previous.group_reference_errors(wrong)))

    # Trace each existing target read by the transforms, then remove it one at a time.
    for label, transform, source in [('schema', current.target_schema, old_schema),
                                      ('example', current.transform_data, old_example)]:
        paths = set()
        original_require = current.require

        def trace(value, *path):
            if path and isinstance(value, dict) and (
                    '$schema' in value or ('relations' in value and 'groups' in value)):
                # Only pre-existing input targets; added output fields are not input targets.
                try:
                    original_require(source, *path)
                except ValueError:
                    pass
                else:
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
    for name, fields in {
        'current-review.json': ['schema', 'graphSchema', 'example', 'buildSteps', 'updatedAt',
                                'decisionsAsOf', 'buildCommand', 'validationCommand'],
        'EntityRepresentation.v2.schema.json': ['$defs', 'x-haven', 'title'],
    }.items():
        for field in fields:
            broken = copy.deepcopy(before)
            del broken[name][field]
            with patch.object(current.previous, 'build_artifacts', return_value=broken):
                fails('Missing build target fails: ' + name + '/' + field, current.build_artifacts)
    wrong = copy.deepcopy(old_schema)
    del wrong['$defs']['PersonProfile']['properties']['skills']['items']['properties']['label']
    fails('Incomplete old skill record fails loudly', lambda: current.target_schema(wrong))
    wrong = copy.deepcopy(old_example)
    wrong['person']['skills'] = [{'label': 'Unknown data'}]
    fails('Unexpected prior skill data is not silently discarded', lambda: current.transform_data(wrong))

    historical = historical_regressions()
    check('All historical suites retain their passing counts', historical == {
        '2026-09-22': 235, '2026-09-23': 301, '2026-09-23-GROUPS': 217})
    result = {
        'date': '2026-09-25', 'status': 'schema-and-reference-checks-passed',
        'checks': len(checks), 'passed': checks, 'validator': engine(),
        'historicalRegressionChecks': historical,
        'sha256': {name: hashlib.sha256((HERE / name).read_bytes()).hexdigest() for name in actual},
        'limitations': [current.EVIDENCE_BLOCKER,
                       'JSON Schema requires a goal configuration but cannot prove measurability.',
                       'Historical suites run unchanged on their own targets; exact scope checks and regression sentinels cover the current target.',
                       'No Swift implementation, graph keypath resolver, measurement cell or real-data migration.'],
        'notRun': [
            {'check': 'Visualiseringssjekker', 'status': 'ikke kjørt',
             'reason': 'Historisk suite leser utdaterte eksterne 16.09/17.09-artefakter; oppdaterte 25.09-artefakter og suite mangler.'},
            {'check': 'Swift/runtime, målecelle og migrering', 'status': 'ikke kjørt',
             'reason': 'Oppgaven endrer bare dokumentasjon og målskjema.'},
            {'check': 'GitHub Actions', 'status': 'ikke kjørt av denne jobben',
             'reason': 'Lokale dokumentasjonskontroller; ingen påstand om fjern-CI.'}
        ]
    }
    RESULT.write_bytes(current.encoded(result))
    print(json.dumps({key: result[key] for key in
                     ('status', 'checks', 'validator', 'historicalRegressionChecks', 'notRun')}, ensure_ascii=False))


if __name__ == '__main__':
    main()
