"""Build the evolving target: runtime baseline -> 16.09 -> 22.09 -> 23.09.

Documentation/schema only. No Swift implementation or user-data migration.
Every existing transformation target is required; all validation precedes writes.
"""
import copy
import hashlib
import re

import apply_decisions_2026_09_22 as previous
from target_validation import check_schema, validate

HERE = previous.HERE
DECISION = previous.DECISION
UUID_PATTERN = previous.UUID_PATTERN
require, expect, add, replace, encoded = (
    previous.require, previous.expect, previous.add, previous.replace, previous.encoded)
CREDENTIALS = ('properties', 'proofs', 'properties', 'credentials')
RECORD = CREDENTIALS + ('additionalProperties',)
INDEX = ('properties', 'proofs', 'properties', 'index')
BY_KEYPATH = INDEX + ('properties', 'byKeypath')
INDEX_VALUES = BY_KEYPATH + ('additionalProperties',)
REF_DESCRIPTIONS = {
    ('properties', 'relations', 'properties', 'identities', 'additionalProperties',
     'properties', 'proofRefs'):
        'Bevis-uuid-er som peker inn i proofs.credentials og hevdes å understøtte identitetsrelasjonen.',
    ('$defs', 'PersonProfile', 'properties', 'affiliations', 'items', 'properties', 'proofRefs'):
        'Bevis-uuid-er som peker inn i proofs.credentials og hevdes å understøtte tilknytningen.',
    ('$defs', 'PersonProfile', 'properties', 'skills', 'items', 'properties', 'evidenceRefs'):
        'Bevis-uuid-er som peker inn i proofs.credentials og hevdes å understøtte ferdigheten.',
    ('$defs', 'PersonProfile', 'properties', 'attributes', 'items', 'properties', 'proofRefs'):
        'Bevis-uuid-er som peker inn i proofs.credentials og hevdes å understøtte den foreløpige attributtpåstanden.'
}
BOUNDARY = 'Oppslag fastslår ikke sannhet, gyldighet, utstedertillit eller samtykke.'
PROOF_UUID = '50000000-0000-4000-8000-000000000001'
SUPPORTED_KEYPATH = 'relations.identities.' + previous.IDENTITY_A + '.domain'
RELATION_UUIDS = {
    'relation-demo': '40000000-0000-4000-8000-000000000001',
    'rellea': '40000000-0000-4000-8000-000000000002',
}
RELATION_UUID = RELATION_UUIDS['relation-demo']


def resolve_fixture_keypath(data, keypath):
    """Only the fixture's plain dictionary paths; never guess escaping/selectors."""
    if not isinstance(keypath, str) or any(c in keypath for c in '\\[]'):
        raise ValueError('UVENTET FORM: unsupported fixture keypath: ' + repr(keypath))
    return require(data, *keypath.split('.'))


def rewrite_relation_ids(input_data):
    """Rewrite known fictional IDs and resolve every affected local reference.

    Unknown uses of an old ID fail closed. This is a fixture transformation,
    not a migration tool or a general cell/keypath resolver.
    """
    records = require(input_data, 'relations', 'records')
    mapping = {old: new for old, new in RELATION_UUIDS.items() if old in records}
    for old, new in mapping.items():
        expect(require(records[old], 'relationID'), old, 'records/' + old + '/relationID')
        if new in records:
            raise ValueError('FINNES ALLEREDE: relations/records/' + new)
    local_paths = []

    def rewrite_path(value):
        # Check both ends of the rewrite so a pre-existing dangling ref also fails.
        resolve_fixture_keypath(input_data, value)
        parts = value.split('.')
        if len(parts) >= 3 and parts[:2] in (['relations', 'records'], ['relations', 'validatedContacts']):
            parts[2] = mapping.get(parts[2], parts[2])
        result = '.'.join(parts)
        local_paths.append(result)
        return result

    def rewrite_string(value, path, is_key=False):
        hits = [old for old in RELATION_UUIDS if old in value]
        is_proof_path = (is_key and path == ('proofs', 'index', 'byKeypath')) or (
            not is_key and len(path) >= 2 and path[-2:] == ('supports', 'keypaths'))
        if is_proof_path or (not is_key and path[-1:] == ('validatedContactRef',)):
            result = rewrite_path(value)
        elif not hits:
            return value
        elif is_key and path in (('relations', 'records'), ('relations', 'validatedContacts')) and value in mapping:
            result = mapping[value]
        elif not is_key and path[-1:] == ('relationID',) and value in mapping:
            result = mapping[value]
        elif not is_key and path[-1:] == ('cellReference',):
            endpoints = {'cell:///DemoContact/' + old + '/1': 'cell:///DemoContact/' + new + '/1'
                         for old, new in mapping.items()}
            result = endpoints.get(value, value)
        else:
            result = value
        if any(old in result for old in RELATION_UUIDS):
            raise ValueError('UVENTET FORM: unresolved old relation ID at ' + '/'.join(path) + ': ' + value)
        return result

    def walk(node, path=()):
        if isinstance(node, dict):
            result = {}
            for key, value in node.items():
                new_key = rewrite_string(key, path, is_key=True)
                if new_key in result or (new_key != key and new_key in node):
                    raise ValueError('FINNES ALLEREDE: ' + '/'.join(path + (new_key,)))
                result[new_key] = walk(value, path + (key,))
            return result
        if isinstance(node, list):
            return [walk(value, path) for value in node]
        if isinstance(node, str):
            return rewrite_string(node, path)
        return node

    result = walk(input_data)
    for keypath in local_paths:
        resolve_fixture_keypath(result, keypath)
    for key, record in require(result, 'relations', 'records').items():
        if re.fullmatch(UUID_PATTERN, key) is None:
            raise ValueError('UVENTET FORM: non-UUID relation key: ' + key)
        expect(require(record, 'relationID'), key, 'records/' + key + '/relationID')
        contact_path = require(record, 'subject', 'validatedContactRef')
        contact = resolve_fixture_keypath(result, contact_path)
        expect(require(contact, 'relationID'), key, contact_path + '/relationID')
    return result


def proof_ref_paths(node, path=()):
    """Inventory is checked against explicit targets; missing/new refs cannot be skipped."""
    result = set()
    if isinstance(node, dict):
        for key, value in node.items():
            child_path = path + (key,)
            if key in ('proofRefs', 'evidenceRefs'):
                result.add(child_path)
            result.update(proof_ref_paths(value, child_path))
    elif isinstance(node, list):
        for i, value in enumerate(node):
            result.update(proof_ref_paths(value, path + (str(i),)))
    return result


def target_schema(input_schema):
    """Apply 23.09 only to the output of the 22.09 schema transformation."""
    s = copy.deepcopy(input_schema)
    expect(require(s, 'x-haven', 'decisionsAsOf'), '2026-09-22', 'x-haven/decisionsAsOf')
    expect(require(s, *previous.RECORDS, 'additionalProperties'),
           {'$ref': '#/$defs/EntityRelationRecord'}, 'relations/records/additionalProperties')
    add(require(s, *previous.RECORDS), 'propertyNames',
        {'pattern': UUID_PATTERN, 'maxLength': 36}, 'relations/records')
    replace(s, previous.RECORDS + ('description',),
            'Relasjonsposter nøklet på relasjons-uuid der posten faktisk bor. '
            'propertyNames håndhever uuid-form; det fiktive eksempelets nøkler og referanser er omskrevet. '
            'Null er en sletteoperasjon, ikke en lagret relasjonspost. '
            'Målkrav, ikke implementert i Swift eller en ny wire-kontrakt.')
    require(s, 'x-haven', 'deferredDecisions', 'relations.records.propertyNames')
    del s['x-haven']['deferredDecisions']['relations.records.propertyNames']
    expect(proof_ref_paths(s), set(REF_DESCRIPTIONS), 'inventory of proofRefs/evidenceRefs')
    expect(require(s, *CREDENTIALS, 'type'), 'object', 'proofs.credentials/type')
    expect(require(s, *RECORD, 'type'), 'object', 'proofs.credentials record/type')
    replace(s, CREDENTIALS + ('description',),
            'Det ene persisterte, flate lageret for bevisposter, nøklet på bevis-uuid. '
            'Dette er det ene stedet disse bevisene bor; alle bevisreferanser peker hit. '
            'Oppslagskart bygges fra postene ved dekoding. Målkrav, ikke implementert i Swift ennå.')
    # Keep the shared UUID pattern; cap length because regex $ may allow a final newline.
    add(require(s, *CREDENTIALS), 'propertyNames', {'pattern': UUID_PATTERN, 'maxLength': 36}, '/'.join(CREDENTIALS))
    replace(s, RECORD + ('description',),
            'Én bevispost under sin bevis-uuid. De seks beskrevne VCClaim-feltene er uuid, type, '
            'issuer, issuanceDate, credentialSubject og proof. supports er et tillegg i målskjemaet '
            'som ikke er implementert i Swift ennå; dette er ikke en komplett VCClaim-wire-kontrakt. '
            'Kartnøkkelen og uuid skal være like; likheten må kontrolleres utenfor JSON Schema. ' + BOUNDARY)
    fields = {
        'uuid': {'type': 'string', 'pattern': UUID_PATTERN, 'maxLength': 36,
                 'description': 'Bevis-uuid, samme uuid som nøkkelen i proofs.credentials.'},
        'type': {'type': 'array', 'items': {'type': 'string'},
                 'description': 'VCClaim.type: liste over typer for påstanden.'},
        'issuer': {'anyOf': [{'type': 'string'}, {'type': 'object'}],
                   'description': 'VCClaim.issuer: referanse eller innebygd objekt (IssuerType). Ingen utstedertillit fastslås her.'},
        'issuanceDate': {'type': 'string', 'format': 'date-time',
                         'description': 'VCClaim.issuanceDate: RFC3339-tidspunkt.'},
        'credentialSubject': {'type': 'object',
                              'description': 'VCClaim.credentialSubject: objekt med selve påstanden. Interne subject-stier er ikke eierens EntityData-nøkkelstier.'},
        'proof': {'type': 'object',
                  'description': 'VCClaim.proof: VCProof-objekt. Detaljfelter og kryptografisk verifikasjon spesifiseres ikke her.'},
        'supports': {
            'type': 'object', 'additionalProperties': False,
            'required': ['entityRef', 'keypaths'],
            'description': 'Påstand om hva beviset understøtter: hvilken entitet (entitets-uuid) '
                           'og hvilke av eierens nøkkelstier. Ikke en gyldighetserklæring. '
                           'Tillegg i målskjemaet, ikke implementert i Swift VCClaim ennå. ' + BOUNDARY,
            'properties': {
                'entityRef': {'type': 'string', 'pattern': UUID_PATTERN, 'maxLength': 36,
                              'description': 'Entitets-uuid for entiteten beviset hevdes å gjelde, ikke bevis- eller identitets-uuid. Referanseoppløsning og identitetslikhet kontrolleres separat.'},
                'keypaths': {
                    'type': 'array', 'minItems': 1, 'uniqueItems': True,
                    'items': {'type': 'string', 'minLength': 1},
                    'description': 'Kanoniske, escaped nøkkelstier i eierens EntityData som beviset hevdes å understøtte. '
                                   'Dette er oppslagsordene for byKeypath, ikke stier inne i credentialSubject. '
                                   'Nøkkelstienes oppløsning og escaping må kontrolleres separat.'
                }
            }
        }
    }
    record = require(s, *RECORD)
    add(record, 'properties', fields, '/'.join(RECORD))
    add(record, 'required', list(fields), '/'.join(RECORD))
    add(record, 'additionalProperties', False, '/'.join(RECORD))
    for path in (CREDENTIALS, RECORD):
        replace(s, path + ('x-haven', 'status'), 'decision-target-draft')
        add(require(s, *path, 'x-haven'), 'runtimeImplemented', False, '/'.join(path) + '/x-haven')

    descriptions = {
        INDEX: 'Avledede oppslagskart som bygges i minnet ved dekoding fra proofs.credentials. '
               'Ikke persistert sannhet eller en andre kilde. Målkrav, ikke implementert i Swift ennå.',
        BY_KEYPATH: 'Avledet oppslag fra kanonisk, escaped nøkkelsti til en liste av bevis-uuid-er '
                    'i proofs.credentials. Bygges ved dekoding fra hver posts supports.keypaths, '
                    'med supports.entityRef som entitetskontekst, slik entityRepresentationNameReferences '
                    'bygges fordi name ligger på objektet selv. For relasjoner går stien inn i '
                    'relations.records.<id>.entityRepresentation. Ikke persistert sannhet og ikke en '
                    'andre kilde; formen beholdes her for å dokumentere oppslaget. '
                    'Målkrav, ikke implementert i Swift ennå. ' + BOUNDARY,
        INDEX_VALUES: 'Liste av bevis-uuid-er som peker inn i proofs.credentials for én escaped nøkkelsti, '
                      'for eksempel person.addresses[label="home"].street.name. '
                      'Avledet i minnet ved dekoding fra supports.keypaths, ikke persistert. ' + BOUNDARY
    }
    for path, description in descriptions.items():
        expect(require(s, *path, 'type'), 'array' if path == INDEX_VALUES else 'object', '/'.join(path))
        replace(s, path + ('description',), description)
        for key, value in {'derived': True, 'status': 'decision-target-draft', 'storageDomain': 'memory',
                           'mutability': 'read-only', 'sourceOfTruthLabel': 'proofs.credentials'}.items():
            replace(s, path + ('x-haven', key), value)
        for key, value in {'persisted': False, 'runtimeImplemented': False}.items():
            add(require(s, *path, 'x-haven'), key, value, '/'.join(path) + '/x-haven')
    for path, description in REF_DESCRIPTIONS.items():
        expect(require(s, *path, 'type'), 'array', '/'.join(path))
        replace(s, path + ('description',), description + ' ' + BOUNDARY)

    replace(s, ('title',), 'EntityData – løpende målmodell etter beslutningene 23. september 2026')
    replace(s, ('description',),
            'Én løpende målmodell etter eierens gjennomganger 16.09, 22.09 og 23.09.2026. '
            'Uuid-nøkling, uvektede grupper, én lagret retning per kant og bevisposter med supports '
            'som kilde for avledet oppslag. Ingen implementert Swift- eller wire-kontrakt påstås.')
    replace(s, ('$comment',),
            'Bygges av apply_decisions_2026_09_23.py etter 16.09- og 22.09-stegene. '
            'Runtime-grunnlaget EntityData.review.schema.json er urørt. '
            'Bevismønsteret er et målkrav; se current-review.json og beslutningens avsnitt Løst 23.09.2026.')
    for key in ('asOf', 'decisionsAsOf'):
        replace(s, ('x-haven', key), '2026-09-23')
    expect(require(s, 'x-haven', 'latestDecisionSource'), DECISION.name, 'latestDecisionSource')
    replace(s, ('x-haven', 'latestDecisionSourceSHA256'), hashlib.sha256(DECISION.read_bytes()).hexdigest())
    require(s, 'x-haven', 'deferredDecisions', 'proofs.index.byKeypath')
    del s['x-haven']['deferredDecisions']['proofs.index.byKeypath']
    add(s['x-haven'], 'proofPatternImplementation',
        'supports og dekodingsbygget byKeypath er kontraktfestet i målskjemaet, ikke implementert i Swift. '
        'Skjemaet dokumenterer oppslagsformen; x-haven.persisted=false er metadata, ikke et lagringsforbud håndhevet av JSON Schema.',
        'x-haven')
    return s


def transform_data(input_data):
    """Extend the known fictional 22.09 fixture, with no persisted lookup map."""
    require(input_data, 'relations', 'records', 'relation-demo')
    d = rewrite_relation_ids(input_data)
    expect(require(d, 'proofs'), {}, 'example/proofs')
    require(d, 'relations', 'entities', previous.ENTITY_A)
    identity = require(d, 'relations', 'identities', previous.IDENTITY_A)
    domain = require(identity, 'domain')
    add(d['proofs'], 'credentials', {
        PROOF_UUID: {
            'uuid': PROOF_UUID,
            'type': ['VerifiableCredential', 'FictionalIdentityDomainClaim'],
            'issuer': 'did:example:fictional-issuer',
            'issuanceDate': '2026-09-23T09:00:00Z',
            'credentialSubject': {'id': previous.ENTITY_A, 'domain': domain},
            'proof': {},
            'supports': {'entityRef': previous.ENTITY_A, 'keypaths': [SUPPORTED_KEYPATH]}
        }
    }, 'example/proofs')
    add(identity, 'proofRefs', [PROOF_UUID], 'example/relations/identities/' + previous.IDENTITY_A)
    return d


def build_artifacts():
    artifacts = previous.build_artifacts()  # The complete 22.09 result, in memory.
    manifest = require(artifacts, 'current-review.json')
    schema_name = require(manifest, 'schema')
    graph_name = require(manifest, 'graphSchema')
    example_name = require(manifest, 'example')
    s = target_schema(require(artifacts, schema_name))
    data = transform_data(require(artifacts, example_name))
    graph = copy.deepcopy(require(artifacts, graph_name))
    replace(graph, ('title',), 'EntityRepresentation – løpende målmodell etter beslutningene 23. september 2026')
    replace(graph, ('$defs',), copy.deepcopy(require(s, '$defs')))
    replace(graph, ('x-haven',), copy.deepcopy(require(s, 'x-haven')))
    expect(require(manifest, 'buildSteps'),
           ['apply_decisions_2026_09_16.py', 'apply_decisions_2026_09_22.py'], 'manifest/buildSteps')
    replace(manifest, ('buildSteps',), manifest['buildSteps'] + ['apply_decisions_2026_09_23.py'])
    for key, value in {'updatedAt': '2026-09-23', 'decisionsAsOf': '2026-09-23',
                       'buildCommand': 'python -B apply_decisions_2026_09_23.py',
                       'validationCommand': 'python -B validate_decisions_2026_09_23.py'}.items():
        replace(manifest, (key,), value)
    for schema in (s, graph):
        check_schema(schema)
    validate(s, data)
    artifacts[schema_name], artifacts[graph_name], artifacts[example_name] = s, graph, data
    return artifacts


def main():
    artifacts = build_artifacts()
    for name, value in artifacts.items():
        (HERE / name).write_bytes(encoded(value))
    print('16.09 -> 22.09 -> 23.09: relasjons-UUID-er og referanser, bevislager, supports og avledet oppslag traff.')
    print('Målskjemaer, fiktivt eksempel og manifest bygget; eksempelet validerer. Ingen Swift-endringer.')


if __name__ == '__main__':
    main()
