"""Validate review decisions, without claiming Swift/runtime compatibility."""
import copy
import hashlib
import importlib.metadata
import json
from pathlib import Path
from jsonschema import Draft202012Validator, FormatChecker
from apply_decisions_2026_09_16 import target_schema

HERE = Path(__file__).resolve().parent
VISUAL = Path('/Users/kjetil/.codex/visualizations/2026/09/11/01a090eb-528a-76d3-87d1-41a0b84f4d47')
manifest = json.loads((HERE/'current-review.json').read_text())
schema = json.loads((HERE/manifest['schema']).read_text())
baseline = json.loads((HERE/manifest['runtimeBaseline']).read_text())
validator = Draft202012Validator(schema, format_checker=FormatChecker())
checks = []

def check(label, condition):
    assert condition, label
    checks.append(label)

def accepted(label, value, subschema=None):
    check(label, validator.evolve(schema=subschema or schema).is_valid(value))

def rejected(label, value, subschema=None):
    check(label, not validator.evolve(schema=subschema or schema).is_valid(value))

Draft202012Validator.check_schema(schema)
check('Reproducible target schema', schema == target_schema(baseline))
check('Historical baseline preserved', hashlib.sha256((HERE/manifest['runtimeBaseline']).read_bytes()).hexdigest() == 'c62ca8f329d229101775158c61fdfce0b0874b0e00211820bea6fb10500c5e2f')
review = json.loads((HERE/manifest['decisions']).read_text())
check('All 45 comments preserved', len(review['comments']) == 45 and all(row.get('quote') for row in review['comments']))
check('Review source hash matches', review['sourceSHA256'] == hashlib.sha256((HERE/review['source']).read_bytes()).hexdigest() == schema['x-haven']['reviewSourceSHA256'])
check('Runtime and migration not claimed', manifest['runtimeUpdated'] is False and manifest['dataMigrated'] is False)
check('Documentation present', (HERE/manifest['documentation']).exists())

refs = []
def walk(v):
    if isinstance(v, dict):
        if '$ref' in v:
            dest = schema
            for key in v['$ref'].split('/')[1:]: dest = dest[key]
            refs.append(v['$ref'])
        for child in v.values(): walk(child)
    elif isinstance(v, list):
        for child in v: walk(child)
walk(schema)
check('All local schema references resolve', bool(refs))

accepted('Partial entity remains valid', {})
accepted('Conference at root', {'conference': {'purposeSnapshot': {}}})
rejected('Conference no longer in person', {'person': {'conference': {}}})
contact = {'endpoints': [{'endpointId':'demo-a', 'cellReference':'cell:///DemoEndpoint', 'label':'primary'}], 'phones':[{'label':'primary','value':'+12025550101'}]}
accepted('Endpoints in own profile', {'person':{'contact':contact}})
node = {'name':'Fiktiv kontakt', 'nodeIdentifier':'demo-contact', 'person':{'contact':contact}}
for edge in ['types','subTypes','parts','partOf','interests','purposes','entities','states']: node[edge] = []
accepted('Same endpoints in contact representation', node, schema['$defs']['EntityRepresentation'])
check('Profile and contact representation share schema', schema['properties']['person'] == schema['$defs']['EntityRepresentation']['properties']['person'])
for key, value in [('email','demo@example.org'),('phone','+12025550101')]:
    rejected('Obsolete scalar contact '+key, {'person':{'contact':{key:value}}})
    invalid = copy.deepcopy(node); invalid['person']['contact'][key] = value
    rejected('Obsolete scalar rejected in representation '+key, invalid, schema['$defs']['EntityRepresentation'])
rejected('Old endpointCell name excluded from target proposal', {'person':{'contact':{'endpoints':[{'endpointCell':'cell:///Demo'}]}}})
accepted('Canonical preferredChannel retained', {'person':{'contact':{'preferredChannel':'haven-chat'}}})
rejected('Duplicated preferredChannel removed', {'person':{'preferences':{'communication':{'preferredChannel':'haven-chat'}}}})
check('Private default annotation', schema['$defs']['PersonProfile']['properties']['preferences']['properties']['privacy']['properties']['defaultVisibility']['default'] == 'private')

accepted('Owner-defined relation lists', {'relations':{'atelier':[{'relationRef':'lea'},{'relationRef':'amir'}]}})
rejected('Owner-defined relation must be a list', {'relations':{'atelier':{}}})
rejected('Relations root cannot be a list', {'relations':[]})
rejected('Legacy people excluded', {'relations':{'people':[]}})
accepted('Agreement list retained', {'signedAgreementEntity':{'records':[]}})
rejected('Agreement dictionary excluded', {'signedAgreementEntity':{'records':{}}})
accepted('Chronicle list accepted', {'chronicle':[]})
rejected('Legacy chronicle empty object excluded', {'chronicle':{}})
accepted('Generic scaffold presence accepted', {'scaffoldPresence':{'mounts':['demo-a','demo-b']}})
rejected('Development-specific staging excluded', {'scaffoldPresence':{'staging':{}}})

purpose = {'name':'Verksted', 'nodeIdentifier':'demo-purpose', 'description':'Fiktivt mål', 'helperCells':[], 'goal':{'name':'DemoMaal'}}
for edge in ['types','subTypes','parts','partOf','interests','purposes','entities','states']: purpose[edge] = []
accepted('Purpose with goal', purpose, schema['$defs']['Purpose'])
without_goal = {key:value for key,value in purpose.items() if key != 'goal'}
rejected('Purpose requires goal in target', without_goal, schema['$defs']['Purpose'])
rejected('Purpose goal cannot be null in target', dict(purpose, goal=None), schema['$defs']['Purpose'])
old_validator = Draft202012Validator(baseline).evolve(schema=baseline['$defs']['Purpose'])
check('Baseline still permits missing goal: deliberate runtime gap', old_validator.is_valid(without_goal))

example = json.loads((HERE/manifest['example']).read_text())
accepted('Updated compact example', example)
data = json.loads((VISUAL/'entitydata-mock-data.json').read_text())
accepted('Complete visualization mock', data)
record = data['relations']['records']['rellea']
for key, value in [('interests',{}),('purposeRefs',[]),('channels',[]),('standing',{}),('evidence',[])]:
    rejected('Duplicated relation field excluded: '+key, dict(record, **{key:value}), schema['$defs']['EntityRelationRecord'])
rejected('Canonical relation requires representation', {key:value for key,value in record.items() if key != 'entityRepresentation'}, schema['$defs']['EntityRelationRecord'])
payload = json.loads((VISUAL/'entitydata-visual-payload.json').read_text())
check('Visualization uses current target, not stale snapshot', json.loads((VISUAL/'entitydata-schema-snapshot.json').read_text()) == schema)
check('Visualization hash matches schema', payload['report']['schemaSHA256'] == hashlib.sha256((HERE/manifest['schema']).read_bytes()).hexdigest())
check('Conference adds 13th root', payload['report']['roots'] == 13 and 'conference' in data)
check('Every defined property position covered', payload['report']['propertyCoverage']['covered'] == payload['report']['propertyCoverage']['total'] and not payload['report']['propertyCoverage']['missing'])
check('Every visual list has multiple items', not payload['report']['arraysWithFewerThanTwoItems'])
check('Obsolete storage variants not presented', not any(v['label'].startswith('Eldre ') for v in payload['variants']))
for variant in payload['variants']:
    validator.evolve(schema=variant['schema']).validate(variant['data'])
check('All displayed variants validate', len(payload['variants']) == 32)
check('Finite graph fixtures with unique definitions and resolved references', all(g['nodes'] == 6 and g['references'] == 91 for g in payload['report']['graphs']))

result = dict(date='2026-09-17', status='passed', checks=len(checks), passed=checks,
    validator='jsonschema '+importlib.metadata.version('jsonschema'),
    schema=manifest['schema'], schemaSHA256=payload['report']['schemaSHA256'], visualCoverage=payload['report'],
    limitations=['target shape only', 'no Swift changes or runtime verification', 'no user-data migration', 'no signature, identity equivalence or authorization proof', 'no proof that a goal is measurable', 'UI checked separately'])
(HERE/'TARGET-VALIDATION-2026-09-17.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
print(json.dumps({'status':'passed','checks':len(checks),'validator':result['validator']}, ensure_ascii=False))
