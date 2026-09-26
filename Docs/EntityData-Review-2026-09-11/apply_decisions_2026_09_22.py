"""Build the single evolving target: runtime baseline -> 16.09 -> 22.09.

Only schemas, the fictional example and current-review.json are written. The
16.09 step runs in memory so an interrupted first step cannot downgrade the
on-disk target. This is not a user-data migration tool.
"""
import copy
import hashlib
import json
from pathlib import Path

import apply_decisions_2026_09_16 as previous
from target_validation import check_schema, validate

HERE = Path(__file__).resolve().parent
DECISION = HERE / 'BESLUTNING-UUID-OG-GRUPPER-2026-09-22.md'
UUID_PATTERN = r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
ENTITY_A = '10000000-0000-4000-8000-000000000001'
ENTITY_B = '10000000-0000-4000-8000-000000000002'
IDENTITY_A = '20000000-0000-4000-8000-000000000001'
GROUP_A = '30000000-0000-4000-8000-000000000001'
GROUP_B = '30000000-0000-4000-8000-000000000002'
RELATIONS = ('properties', 'relations')
ENTITIES = RELATIONS + ('properties', 'entities')
IDENTITIES = RELATIONS + ('properties', 'identities')
RECORDS = RELATIONS + ('properties', 'records')
BOKPROSJEKT = RELATIONS + ('properties', 'bokprosjekt')
PROOFS_INDEX = ('properties', 'proofs', 'properties', 'index', 'properties', 'byKeypath')


def require(value, *path):
    """No optional lookup for a transformation target, including under python -O."""
    node = value
    for key in path:
        if not isinstance(node, dict) or key not in node:
            raise ValueError('FANT IKKE: ' + '/'.join(path))
        node = node[key]
    return node


def expect(value, expected, path):
    if value != expected:
        raise ValueError(f'UVENTET FORM: {path}: forventet {expected!r}, fikk {value!r}')


def add(value, key, child, path):
    if key in value:
        raise ValueError(f'FINNES ALLEREDE: {path}/{key}')
    value[key] = child


def replace(value, path, child):
    require(value, *path)
    require(value, *path[:-1])[path[-1]] = child


def forbid_field(schema, path, field):
    node = require(schema, *path)
    require(node, 'properties', field)
    del node['properties'][field]
    # These historical records are open objects: deletion alone is insufficient.
    if 'required' in node:
        node['required'] = [key for key in node['required'] if key != field]
    if 'allOf' not in node:
        node['allOf'] = []
    node['allOf'].append({'not': {'required': [field]}})


def target_schema(input_schema):
    """Apply only the 22.09 changes to the result of target_schema from 16.09."""
    s = copy.deepcopy(input_schema)
    expect(require(s, 'x-haven', 'decisionsAsOf'), '2026-09-16', 'x-haven/decisionsAsOf')
    # Also require the blocked paths; losing either must stop the build.
    require(s, *PROOFS_INDEX)
    require(s, *BOKPROSJEKT, 'properties', 'members', 'items', 'properties',
            'relation', 'properties', 'groupRefs')

    add(require(s, 'properties'), 'groups', {
        'type': 'object',
        'propertyNames': {'pattern': UUID_PATTERN},
        'description': 'Grupper nøkles på gruppe-uuid og er uvektede medlemslister over entiteter. '
                       'Relasjoner bærer den vektede perspektivgrafen. Hvilke grupper en entitet '
                       'tilhører bygges ved dekoding, i minnet; ingen medlemsbakkanter persisteres.',
        'additionalProperties': {
            'type': 'object',
            'additionalProperties': False,
            'required': ['name', 'members'],
            'properties': {
                'name': {'type': 'string', 'minLength': 1},
                'members': {
                    'type': 'array',
                    'items': {
                        'type': 'string', 'pattern': UUID_PATTERN,
                        'description': 'Entitets-uuid som refererer til relations.entities, aldri en relasjonsreferanse.'
                    },
                    'description': 'Flat liste med entitetsreferanser uten vekter eller kopier av entiteter. '
                                   'Samme entitet kan stå i flere grupper. Referanseoppløsning må kontrolleres separat.'
                }
            }
        }
    }, 'properties')

    expect(require(s, *RELATIONS, 'additionalProperties'), {'type': 'array', 'items': {}},
           'relations/additionalProperties')
    replace(s, RELATIONS + ('additionalProperties',), False)
    replace(s, RELATIONS + ('description',),
            'Objekt med bare reserverte nøkler. Eierdefinerte navngitte lister er erstattet av groups. '
            'Relasjoner bærer den vektede perspektivgrafen; groups er uvektet medlemskap. '
            'records/<uuid>/entityRepresentation er den typede kontaktbanen. '
            'bokprosjekt er et bevart, uavklart migreringsunntak, ikke en ny eierdefinert liste.')

    for path, description in [
        (ENTITIES, 'Entitetsposter nøklet på entitets-uuid. Relasjoners subject.entityRef og groups.members peker hit.'),
        (IDENTITIES, 'Identitetsposter nøklet på identitets-uuid; andre steder refererer til denne nøkkelen.')
    ]:
        expect(require(s, *path, 'type'), 'object', '/'.join(path))
        require(s, *path, 'additionalProperties', 'properties')
        add(require(s, *path), 'propertyNames', {'pattern': UUID_PATTERN}, '/'.join(path))
        replace(s, path + ('description',), description)

    expect(require(s, *RECORDS, 'additionalProperties'), {'$ref': '#/$defs/EntityRelationRecord'},
           'relations/records/additionalProperties')
    replace(s, RECORDS + ('description',),
            'Målkrav: relasjonsposter nøkles på relasjons-uuid der posten faktisk bor. '
            'propertyNames med uuid-mønster er utsatt for dette kartet fordi eksisterende eksempler '
            'bruker relation-demo (og visualiseringsdata bruker rellea). Disse nøklene avvises derfor ikke av dette kartet. '
            'Null er en sletteoperasjon, ikke en lagret relasjonspost. Dette er ingen ny wire-kontrakt.')

    entity_record = ENTITIES + ('additionalProperties',)
    identity_record = IDENTITIES + ('additionalProperties',)
    forbid_field(s, identity_record, 'entityRefs')
    forbid_field(s, entity_record, 'relationRefs')
    replace(s, entity_record + ('description',),
            'Entitetspost nøklet på entitets-uuid med identityRefs og valgfrie kontaktreferanser. '
            'relationRefs persisteres ikke; de bygges fra relasjonenes subject.entityRef ved dekoding, i minnet.')
    replace(s, identity_record + ('description',),
            'Identitetspost nøklet på identitets-uuid. entityRefs persisteres ikke; '
            'de bygges fra entitetenes identityRefs ved dekoding, i minnet.')
    replace(s, entity_record + ('properties', 'identityRefs', 'description'),
            'Referanser til relations.identities, lagret bare fra entitet til identitet. '
            'Motsatt retning, fra identitet til entiteter, bygges ved dekoding, i minnet.')
    subject = ('$defs', 'EntityRelationSubject')
    require(s, *subject, 'properties', 'entityRef', 'anyOf')
    add(require(s, *subject, 'properties', 'entityRef'), 'description',
        'Referanse til entitets-uuid i relations.entities, lagret bare fra relasjon til entitet. '
        'Motsatt retning, fra entitet til relasjoner, bygges ved dekoding, i minnet.',
        '$defs/EntityRelationSubject/properties/entityRef')
    replace(s, subject + ('description',),
            'entityRef er den persisterte kanten til entiteten. Øvrige felt er beholdt '
            'som mulige avledede sammendrag, til vurdering; ingen separat autoritativ kontaktprofil.')

    replace(s, ('title',), 'EntityData – løpende målmodell etter beslutningene 22. september 2026')
    replace(s, ('description',),
            'Én løpende målmodell etter eierens gjennomganger 16.09 og 22.09.2026. '
            'Uuid-nøkling, uvektede grupper og én lagret retning per kant. '
            'Åpne detaljer og utsatte grep er merket; ingen implementert Swift- eller wire-kontrakt påstås.')
    replace(s, ('$comment',),
            'Bygges av apply_decisions_2026_09_22.py etter 16.09-steget. Runtime-grunnlaget '
            'EntityData.review.schema.json er urørt. proofs.index.byKeypath og bokprosjekt er bevart. '
            'Se current-review.json og BESLUTNING-UUID-OG-GRUPPER-2026-09-22.md.')
    replace(s, ('x-haven', 'asOf'), '2026-09-22')
    replace(s, ('x-haven', 'decisionsAsOf'), '2026-09-22')
    add(s['x-haven'], 'latestDecisionSource', DECISION.name, 'x-haven')
    add(s['x-haven'], 'latestDecisionSourceSHA256', hashlib.sha256(DECISION.read_bytes()).hexdigest(), 'x-haven')
    add(s['x-haven'], 'deferredDecisions', {
        'relations.records.propertyNames': 'Uuid-kravet er beskrevet, ikke håndhevet, for å bevare eksisterende eksempler.',
        'relations.bokprosjekt': 'Urørt: mangler autoritativ kobling fra recipientID til entitets-uuid '
                                'og fra eksisterende gruppe-id/label til gruppe-uuid i groups. Ingen bokprosjekt-data i repoeksempelet.',
        'proofs.index.byKeypath': 'Urørt: dekodingsbeslutningen er sperret til bevispostenes '
                                 'entitets-/nøkkelstikobling er besluttet og kontraktfestet.'
    }, 'x-haven')
    expect(require(s, *PROOFS_INDEX), require(input_schema, *PROOFS_INDEX), 'proofs.index.byKeypath urørt')
    expect(require(s, *BOKPROSJEKT), require(input_schema, *BOKPROSJEKT), 'bokprosjekt urørt')
    return s


def transform_data(input_data):
    """Extend the known fictional compact example, never arbitrary stored data."""
    d = copy.deepcopy(input_data)
    relations = require(d, 'relations')
    record = require(d, 'relations', 'records', 'relation-demo')
    expect(require(record, 'relationID'), 'relation-demo', 'example/relationID')
    add(require(record, 'subject'), 'entityRef', ENTITY_A, 'example/subject')
    add(relations, 'entities', {
        ENTITY_A: {'identityRefs': [IDENTITY_A]},
        ENTITY_B: {'identityRefs': []}
    }, 'example/relations')
    add(relations, 'identities', {
        IDENTITY_A: {'identityUUID': IDENTITY_A, 'domain': 'example.org'}
    }, 'example/relations')
    add(d, 'groups', {
        GROUP_A: {'name': 'Venner', 'members': [ENTITY_A, ENTITY_B]},
        GROUP_B: {'name': 'Samarbeidspartnere', 'members': [ENTITY_A]}
    }, 'example')
    expect(require(d, 'proofs'), require(input_data, 'proofs'), 'example/proofs urørt')
    return d


def build_artifacts():
    baseline = json.loads(previous.BASE.read_text())
    s = target_schema(previous.target_schema(baseline))
    data = transform_data(previous.transform_data(json.loads((HERE / 'EntityData.example.json').read_text())))
    graph = {
        '$schema': s['$schema'], '$id': 'urn:haven:entity-representation:review-decisions:2026-09-16',
        'title': 'EntityRepresentation – løpende målmodell etter beslutningene 22. september 2026',
        '$ref': '#/$defs/EntityRepresentation', '$defs': copy.deepcopy(s['$defs']),
        'x-haven': copy.deepcopy(s['x-haven'])
    }
    # Retain the existing schema identities and filenames; the date is provenance.
    manifest = {
        'status': 'decision-target-draft', 'updatedAt': '2026-09-22', 'decisionsAsOf': '2026-09-22',
        'schema': previous.TARGET, 'graphSchema': 'EntityRepresentation.v2.schema.json',
        'example': 'EntityData.v2.example.json', 'documentation': 'V2-BESLUTTET-FORM.md',
        'decisions': 'review-decisions-2026-09-16.json', 'latestDecisions': DECISION.name,
        'buildSteps': ['apply_decisions_2026_09_16.py', 'apply_decisions_2026_09_22.py'],
        'buildCommand': 'python apply_decisions_2026_09_22.py',
        'validationCommand': 'python validate_decisions_2026_09_22.py',
        'runtimeBaseline': previous.BASE.name, 'runtimeUpdated': False,
        'dataMigrated': False, 'published': False
    }
    for schema in (s, graph):
        check_schema(schema)
    validate(s, data)
    return {previous.TARGET: s, manifest['example']: data, manifest['graphSchema']: graph,
            'current-review.json': manifest}


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8')


def main():
    artifacts = build_artifacts()  # All preconditions and validation precede writes.
    for name, value in artifacts.items():
        (HERE / name).write_bytes(encoded(value))
    print('16.09 -> 22.09: målskjemaer, fiktivt eksempel og manifest bygget; eksempelet validerer.')
    print('UTSATT: records UUID-mønster; bokprosjekt. URØRT: proofs.index.byKeypath og runtime-grunnlag.')


if __name__ == '__main__':
    main()
