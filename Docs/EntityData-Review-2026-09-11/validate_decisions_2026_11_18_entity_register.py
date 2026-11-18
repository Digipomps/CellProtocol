"""Verify the single entity register (18.11.2026) and keep the older suites passing."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import apply_decisions_2026_11_18_entity_register as current
from target_validation import check_schema, engine, validation_errors

HERE = current.HERE
RESULT = HERE / 'TARGET-VALIDATION-2026-11-18-ENTITY-REGISTER.json'


def historical_regressions():
    """Older suites assert their own byte identity; run them on their own target only."""
    with tempfile.TemporaryDirectory(prefix='entitydata-register-regression-') as temporary:
        directory = Path(temporary) / 'review'
        shutil.copytree(HERE, directory, ignore=shutil.ignore_patterns('__pycache__'))
        for script in ('apply_decisions_2026_09_25_skills.py', 'validate_decisions_2026_09_25_skills.py'):
            result = subprocess.run([sys.executable, '-B', '-O', script], cwd=directory,
                                    capture_output=True, text=True, env=os.environ.copy())
            if result.returncode:
                raise RuntimeError(script + '\n' + result.stdout + result.stderr)
        result = json.loads((directory / 'TARGET-VALIDATION-2026-09-25-SKILLS.json').read_text())
        return {**result['historicalRegressionChecks'], '2026-09-25-SKILLS': result['checks']}


def main():
    checks = []

    def check(label, condition):
        if not condition:
            raise AssertionError(label)
        checks.append(label)

    built = current.build_artifacts()
    actual = {name: json.loads((HERE / name).read_text()) for name in built}
    for name in built:
        check(f'{name}: written file equals in-memory build', actual[name] == built[name])
    schema = actual['EntityData.v2.schema.json']
    graph = actual['EntityRepresentation.v2.schema.json']
    example = actual['EntityData.v2.example.json']
    for s in (schema, graph):
        check_schema(s)
    check('example passes schema', not validation_errors(schema, example))
    check('example passes reference checks', not current.reference_errors(example))

    def rejected_by_schema(label, mutate):
        data = copy.deepcopy(example)
        mutate(data)
        check('schema rejects: ' + label, bool(validation_errors(schema, data)))

    def rejected_by_references(label, mutate):
        data = copy.deepcopy(example)
        mutate(data)
        check('schema accepts but references reject: ' + label,
              not validation_errors(schema, data) and bool(current.reference_errors(data)))

    a, b = current.ENTITY_A, current.ENTITY_B
    org, conf, rel, group = (current.ORGANIZATION, current.CONFERENCE_ENTITY,
                             current.RELATION, current.GROUP_B)
    rejected_by_schema('relations.entities (old location)',
                       lambda d: d['relations'].__setitem__('entities', {a: {'identityRefs': []}}))
    rejected_by_schema('entityRepresentation embedded in relation record',
                       lambda d: d['relations']['records'][rel].__setitem__(
                           'entityRepresentation', d['entities'][a]['entityRepresentation']))
    rejected_by_schema('relation subject without entityRef',
                       lambda d: d['relations']['records'][rel]['subject'].pop('entityRef'))
    rejected_by_schema('relation entityRef that is not a uuid',
                       lambda d: d['relations']['records'][rel]['subject'].__setitem__('entityRef', 'entity-a'))
    rejected_by_schema('group with its own name', lambda d: d['groups'][group].__setitem__('name', 'Kopi'))
    rejected_by_schema('entity without kind', lambda d: d['entities'][a].pop('kind'))
    rejected_by_schema('entity with unknown kind', lambda d: d['entities'][a].__setitem__('kind', 'robot'))
    rejected_by_schema('entity without entityRepresentation', lambda d: d['entities'][org].pop('entityRepresentation'))
    rejected_by_schema('entity key that is not a uuid',
                       lambda d: d['entities'].__setitem__('forlaget', d['entities'][org]))
    rejected_by_schema('conference key that is not a uuid',
                       lambda d: d['conference'].__setitem__('arendalsuka', {}))
    rejected_by_schema('entity with relationRefs', lambda d: d['entities'][a].__setitem__('relationRefs', [rel]))

    rejected_by_references('relation pointing at unknown entity',
                           lambda d: d['relations']['records'][rel]['subject'].__setitem__(
                               'entityRef', '70000000-0000-4000-8000-0000000000ff'))
    rejected_by_references('group member that is a group',
                           lambda d: d['groups'][group]['members'].append(current.groups_step.ROOT))
    rejected_by_references('groups key whose entity is not kind group',
                           lambda d: d['groups'].__setitem__(org, {'members': [a]}))
    rejected_by_references('groups key missing from register',
                           lambda d: d['groups'].__setitem__('70000000-0000-4000-8000-0000000000fe', {'members': [a]}))
    rejected_by_references('conference keyed by a person',
                           lambda d: d['conference'].__setitem__(b, {}))
    rejected_by_references('conference key missing from register',
                           lambda d: d['conference'].__setitem__('70000000-0000-4000-8000-0000000000fd', {}))
    rejected_by_references('proof supporting unknown entity',
                           lambda d: next(iter(d['proofs']['credentials'].values()))['supports'].__setitem__(
                               'entityRef', '70000000-0000-4000-8000-0000000000fc'))
    rejected_by_references('identityRef to unknown identity',
                           lambda d: d['entities'][b]['identityRefs'].append('20000000-0000-4000-8000-0000000000ff'))
    rejected_by_references('partOf cycle',
                           lambda d: d['groups'][current.groups_step.ROOT].__setitem__(
                               'partOf', current.groups_step.WORK_A))

    check('organisation and person resolve in the same register',
          example['entities'][org]['kind'] == 'organization' and example['entities'][a]['kind'] == 'person')
    check('organisation is a member next to a person', {a, org} <= set(example['groups'][group]['members']))
    check('group names moved into register',
          example['entities'][group]['entityRepresentation']['name'] == 'Samarbeidspartnere')
    check('relation representation moved into register',
          example['entities'][a]['entityRepresentation']['name'] == 'Fiktiv samarbeidspartner')
    check('runtime baseline untouched', (HERE / 'EntityData.review.schema.json').read_bytes() ==
          subprocess.run(['git', 'show', 'HEAD:./EntityData.review.schema.json'], cwd=HERE,
                         capture_output=True, check=True).stdout)

    result = {
        'status': 'schema-and-reference-checks-passed',
        'checks': len(checks),
        'validator': engine(),
        'historicalRegressionChecks': historical_regressions(),
        'notRun': [
            {'check': 'Swift/runtime, lagringskontrakt og migrering', 'status': 'ikke kjørt',
             'reason': 'Oppgaven endrer bare dokumentasjon og målskjema.'},
            {'check': 'GitHub Actions', 'status': 'ikke kjørt av denne jobben',
             'reason': 'Lokale dokumentasjonskontroller; ingen påstand om fjern-CI.'},
        ],
        'labels': checks,
    }
    RESULT.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'labels'}, ensure_ascii=False))


if __name__ == '__main__':
    main()
