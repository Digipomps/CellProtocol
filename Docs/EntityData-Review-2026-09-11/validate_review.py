"""Validate the review artifacts, including negative cases and declared limits."""
import copy
import importlib.metadata
import json
from pathlib import Path
from jsonschema import Draft202012Validator, FormatChecker

OUT = Path(__file__).resolve().parent
schema = json.loads((OUT / 'EntityData.review.schema.json').read_text())
baseline = json.loads((OUT / 'EntityAnchorData.v1.documented.schema.json').read_text())
example = json.loads((OUT / 'EntityData.example.json').read_text())
graph_schema = json.loads((OUT / 'EntityRepresentation.schema.json').read_text())
for document in (schema, baseline, graph_schema):
    Draft202012Validator.check_schema(document)

# Resolve every local reference, including definitions not exercised by examples.
reference_count = 0
def check_refs(value):
    global reference_count
    if isinstance(value, list):
        for item in value:
            check_refs(item)
    if not isinstance(value, dict):
        return
    if '$ref' in value:
        pointer = value['$ref']
        assert pointer.startswith('#/'), pointer
        resolved = schema
        for segment in pointer[2:].split('/'):
            resolved = resolved[segment.replace('~1', '/').replace('~0', '~')]
        reference_count += 1
    for item in value.values():
        check_refs(item)
check_refs(schema)

validator = Draft202012Validator(schema, format_checker=FormatChecker())
results = []
def case(name, value, valid):
    errors = list(validator.iter_errors(value))
    assert (not errors) == valid, (name, [e.message for e in errors])
    results.append({'case': name, 'expectedValid': valid, 'passed': True})

def contact_change(field, value):
    data = copy.deepcopy(example)
    data['relations']['validatedContacts']['relation-demo'][field] = value
    return data

case('full-fictional-example', example, True)
case('empty-entity-is-allowed', {}, True)
case('partial-profile-is-allowed', {'person': {'displayName': 'Demo'}}, True)
case('unknown-extension-is-intentionally-allowed', {'demoExtension': {'value': 1}}, True)
case('name-must-be-string-when-present', {'person': {'name': {'first': 123}}}, False)
case('address-items-must-be-objects', {'person': {'addresses': ['not-an-address-object']}}, False)
case('legacy-relations-array', {'relations': []}, True)
case('legacy-empty-chronicle-object', {'chronicle': {}}, True)
case('nonempty-object-is-not-the-declared-chronicle-form', {'chronicle': {'entry': 1}}, False)
case('legacy-agreement-list', {'signedAgreementEntity': {'records': [{'counterparty': 'demo'}]}}, True)
case('new-agreement-map-empty', {'signedAgreementEntity': {'records': {}}}, True)
case('contact-rejects-unknown-fields', contact_change('unexpected', True), False)
case('contact-requires-nonempty-channels', contact_change('channels', {}), False)
case('contact-rejects-leading-zero-phone', contact_change('channels', {'phoneE164': '+0123456789'}), False)
case('contact-rejects-space-in-email', contact_change('channels', {'email': 'someone @example.org'}), False)
case('contact-rejects-disclosure-true', contact_change('retention', {'storageAuthorized': True, 'disclosureAuthorized': True}), False)
case('contact-rejects-storage-false', contact_change('retention', {'storageAuthorized': False, 'disclosureAuthorized': False}), False)
case('contact-requires-audit-purpose', contact_change('purposeRefs', ['purpose://contact.communication']), False)
case('contact-rejects-duplicate-purpose', contact_change('purposeRefs', ['purpose://access.audit.privacy', 'purpose://contact.communication', 'purpose://contact.communication']), False)
case('contact-rejects-bad-observation-time', contact_change('provenance', {'sourceKind': 'user-supplied', 'sourceLabel': 'Example', 'observedAt': 'tomorrow'}), False)
record = copy.deepcopy(example['relations']['records']['relation-demo'])
record['revision'] = 0
case('relation-revision-must-be-positive', {'relations': {'records': {'relation-demo': record}}}, False)
record = copy.deepcopy(example['relations']['records']['relation-demo'])
del record['subject']
case('relation-requires-subject', {'relations': {'records': {'relation-demo': record}}}, False)
event = {'id': 'demo-event', 'schema': 'haven.relation-interaction-event.v1', 'relationID': 'relation-demo',
         'kind': 'message.sent', 'at': '2026-09-11T09:00:00Z', 'contentMode': 'metadata',
         'purposeRef': 'purpose://contact.communication', 'sourceCell': 'cell:///Demo'}
case('metadata-event-without-content', {'chronicle': [event]}, True)
case('metadata-event-rejects-content', {'chronicle': [{**event, 'summary': 'Private content'}]}, False)
# These passing cases document why a schema result is not a security decision.
case('id-binding-requires-runtime-validation', contact_change('relationID', 'different-id'), True)
case('utf8-byte-limit-requires-runtime-validation', contact_change('displayName', 'é' * 200), True)

# Validate a nonempty current commit record as well as its missing-contract negative.
commit_record = {'id': 'demo-contract', 'recordState': 'signed', 'signatureValidationState': 'verified',
                 'signingSemantics': 'demo-only', 'counterpartySignatureState': 'not_present',
                 'immutable': True, 'contractHash': 'demo-hash', 'immutableContentHash': 'demo-content-hash',
                 'contract': {}, 'metadata': {}, 'credentialReceipts': [], 'committedAt': '2026-09-11T09:00:00Z'}
case('current-commit-record-structure-only', {'signedAgreementEntity': {'records': {'demo-contract': commit_record}}}, True)
del commit_record['contract']
case('current-commit-record-requires-contract-field', {'signedAgreementEntity': {'records': {'demo-contract': commit_record}}}, False)

# The owner's representation is a complete PerspectiveNode graph, not a tag map.
graph = json.loads((OUT / 'EntityRepresentation.example.json').read_text())
graph_validator = Draft202012Validator(graph_schema)
assert not list(graph_validator.iter_errors(graph))
def graph_case(name, change, valid):
    data = copy.deepcopy(example)
    change(data['relations']['records']['relation-demo']['entityRepresentation'])
    case(name, data, valid)
graph_case('graph-requires-all-codable-relation-arrays', lambda n: n.pop('parts'), False)
graph_case('graph-rejects-flat-purpose-tags', lambda n: n.update(purposes=['review']), False)
graph_case('weight-requires-numeric-weight', lambda n: n['purposes'][0].update(weight='high'), False)
graph_case('weight-requires-inline-value-or-reference', lambda n: n.update(purposes=[{'weight': 0.8}]), False)
graph_case('external-reference-validity-needs-perspective-context', lambda n: n.update(purposes=[{'weight': 0.8, 'reference': 'external'}]), True)
graph_case('weight-is-not-constrained-to-probability-range', lambda n: n['purposes'][0].update(weight=7), True)
graph_case('purpose-helper-requires-configuration-name', lambda n: n['purposes'][0]['value'].update(helperCells=[{}]), False)
graph_case('purpose-composition-requires-leaf-ref', lambda n: n['purposes'][0]['value'].update(composition={'type': 'purpose'}), False)
graph_case('condition-requires-freshness-key', lambda n: n['purposes'][0]['value']['interests'][0]['value'].update(constraint={'type': 'metadataFreshness', 'maxAgeSeconds': 60}), False)
case('interaction-policy-is-object', {'person': {'relations': {'interactionPolicy': {'mode': 'metadata'}}}}, True)
case('interaction-policy-rejects-old-mistaken-schema-string', {'person': {'relations': {'interactionPolicy': 'metadata'}}}, False)
legacy = copy.deepcopy(example)
legacy['relations']['records']['relation-demo'].pop('entityRepresentation')
case('legacy-relation-needs-no-automatic-migration', legacy, True)

try:
    json.loads((OUT / 'EntityAnchorData.v1.runtime-output.txt').read_text())
    raise AssertionError('Expected the observed source escaping defect')
except json.JSONDecodeError as error:
    baseline_defect = {'status': 'confirmed-by-JSON-parser', 'line': error.lineno, 'column': error.colno,
                       'reason': 'Swift consumes escaped quotes around home inside a JSON description.'}

result = {'validator': 'python-jsonschema', 'version': importlib.metadata.version('jsonschema'),
          'draft': '2020-12', 'formatChecksEnabled': True,
          'metaSchemasValid': 3, 'localReferencesResolved': reference_count,
          'caseCount': len(results), 'cases': results, 'originalSchemaStringDefect': baseline_defect,
          'notRun': ['Full Swift test suite', 'remote deployment check', 'full authorization audit',
                     'replication/convergence tests', 'storage benchmarks'],
          'limits': ['Open roots allow undeclared fields.', 'Partial contracts remain open.',
                     'Runtime must enforce signatures, authority, id binding, UTF-8 limits and deletion semantics.']}
(OUT / 'validation.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print(f'PASS: 3 schemas, {reference_count} resolved references, {len(results)} cases.')
