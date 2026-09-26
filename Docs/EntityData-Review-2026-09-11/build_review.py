"""Build a dated discussion schema from local sources; never modifies runtime code."""
import ast
import copy
import hashlib
import json
import re
from pathlib import Path
import perspective_schema

OUT = Path(__file__).resolve().parent
CP = OUT.parents[1]
HAVEN = CP.parent
REGISTRY = HAVEN / 'CellScaffold/Sources/App/Support/EntityAnchorDataV1Contract.swift'
RELATION = CP / 'Sources/CellBase/PersistingCells/EntityRelationRecordV1.swift'
DIALECT = 'https://json-schema.org/draft/2020-12/schema'


def write(name, value):
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def obj(properties=None, required=None, closed=False):
    result = {'type': 'object', 'additionalProperties': not closed}
    if properties is not None:
        result['properties'] = properties
    if required:
        result['required'] = required
    return result


def string(**kw):
    return {'type': 'string', **kw}


def arr(item=None, **kw):
    return {'type': 'array', 'items': item if item is not None else {}, **kw}


def ref(name):
    return {'$ref': '#/$defs/' + name}


def dictionary(item, description=''):
    result = {'type': 'object', 'additionalProperties': item}
    if description:
        result['description'] = description
    return result


source = REGISTRY.read_text()
literal = re.search(r'static let jsonSchemaString: String = (""".*?""")', source, re.S)
# The source body is JSON, but Swift consumes the escaped quotes around
# label="home" and consequently emits invalid JSON. Preserve that evidence.
runtime_text = ast.literal_eval(literal.group(1))
(OUT / 'EntityAnchorData.v1.runtime-output.txt').write_text(runtime_text + '\n')
baseline = json.loads(literal.group(1)[3:-3])
baseline['$comment'] = 'JSON fra kildekodens dokumenterte struktur. Swift-strengen mister escaping rundt home i en beskrivelse; denne filen bevarer gyldig JSON. Se runtime-output.txt og LES-MEG.md.'
write('EntityAnchorData.v1.documented.schema.json', baseline)
schema = copy.deepcopy(baseline)
schema.update({
    '$id': 'urn:haven:review:entity-data:2026-09-11',
    'title': 'EntityData – kildebasert gjennomgang 2026-09-11',
    'description': 'Diskusjonsskjema for lagret Entity-tilstand. Utvider eksisterende strukturregister med kjente runtime-former. Dette er ikke en ny vedtatt wire-kontrakt eller en autorisasjonsvalidator.',
    '$comment': 'Ingen påkrevde rotfelt. Fleksible røtter er åpne. x-haven er kun dokumentasjon. Ukjente felt og ufullstendig beskrevne delkontrakter krever separat gjennomgang.',
    'x-haven': {
        'status': 'review-draft',
        'asOf': '2026-09-11',
        'registryVersion': 'haven.entity-anchor-data.v1',
        'validates': 'structural-shape-only',
        'doesNotValidate': ['signature', 'authorization', 'keypath-to-id-binding', 'UTF-8-byte-limits', 'replication', 'deletion', 'migration'],
        'source': 'CellScaffold/Sources/App/Support/EntityAnchorDataV1Contract.swift'
    },
    '$defs': {}
})


def target_for(path):
    """Map registry [] / [+] to items, and <id> to dictionary values."""
    node = schema
    for segment in path.replace('[+]', '[]').split('.'):
        if segment.startswith('<') and segment.endswith('>'):
            node.setdefault('type', 'object')
            if not isinstance(node.get('additionalProperties'), dict):
                node['additionalProperties'] = {}
            node = node['additionalProperties']
            continue
        is_array = segment.endswith('[]')
        name = segment[:-2] if is_array else segment
        node.setdefault('type', 'object')
        node = node.setdefault('properties', {}).setdefault(name, {})
        if is_array:
            node['type'] = 'array'
            node = node.setdefault('items', {})
    return node


descriptors = []
for line_number, line in enumerate(source.splitlines(), 1):
    if not line.lstrip().startswith('d("'):
        continue
    values = [json.loads('"' + v + '"') for v in re.findall(r'"((?:[^"\\]|\\.)*)"', line)]
    path, title, description, value_type, privacy, domain, owner, mutability, authority = values[:9]
    derived = re.search(r',\s*(true|false),\s*\[', line).group(1) == 'true'
    metadata = {'keypath': path, 'sourceLine': line_number, 'status': 'registry-described',
                'visibilityClass': privacy, 'storageDomain': domain,
                'mutability': mutability, 'sourceOfTruthLabel': authority, 'derived': derived}
    node = target_for(path)
    # Keep the existing root union (relations: object|array), despite registry object label.
    if value_type != 'any' and not isinstance(node.get('type'), list):
        node['type'] = value_type
    node.update({'title': title, 'description': description, 'x-haven': metadata})
    descriptors.append({'path': path, 'valueType': value_type, **metadata})

assert len(descriptors) == 240
write('keypaths.source-index.json', {'source': str(REGISTRY.relative_to(HAVEN)), 'count': len(descriptors), 'keypaths': descriptors})

# Precisely scoped Codable shapes for the new relation family. No computed fields.
relation_source = RELATION.read_text()
definitions = schema['$defs']
definitions.update(perspective_schema.definitions())
enum_names = ['EntityRelationOriginKind', 'EntityRelationChannelKind', 'EntityRelationTrust',
              'EntityRelationDirection', 'EntityRelationEvidenceKind',
              'EntityRelationInteractionKind', 'EntityRelationInteractionPolicyMode']
struct_names = ['EntityRelationOrigin', 'EntityRelationRole', 'EntityRelationInterests',
                'EntityRelationChannel', 'EntityRelationStanding', 'EntityRelationEvidence',
                'EntityRelationInteractionSummary', 'EntityRelationSubject',
                'EntityRelationRecord', 'EntityRelationInteractionEvent']


def swift_block(kind, name):
    match = re.search(r'public ' + kind + ' ' + name + r'\b[^\{]*\{', relation_source)
    start = match.end()
    # All selected declarations are top-level, and stored properties precede methods.
    next_decl = re.search(r'^public (?:struct|enum) ', relation_source[start:], re.M)
    return relation_source[start:start + next_decl.start()] if next_decl else relation_source[start:]


for name in enum_names:
    cases = re.findall(r'^    case (\w+)(?: = "([^"]+)")?\s*$', swift_block('enum', name), re.M)
    assert cases, name
    definitions[name] = string(enum=[raw or case for case, raw in cases])


def swift_type(type_name):
    optional = type_name.endswith('?')
    if optional:
        return {'anyOf': [swift_type(type_name[:-1]), {'type': 'null'}]}
    primitive = {'String': string(), 'Date': string(format='date-time'),
                 'Int': {'type': 'integer'}, 'Bool': {'type': 'boolean'}}
    if type_name in primitive:
        return copy.deepcopy(primitive[type_name])
    if type_name.startswith('[String: '):
        return dictionary(swift_type(type_name[9:-1]))
    if type_name.startswith('['):
        return arr(swift_type(type_name[1:-1]))
    assert type_name in enum_names + struct_names or type_name in definitions, type_name
    return ref(type_name)


for name in struct_names:
    fields = re.findall(r'^    public var (\w+): ([A-Za-z\[\]: ?]+)\s*$', swift_block('struct', name), re.M)
    assert fields, name
    definitions[name] = obj({key: swift_type(type_name.strip()) for key, type_name in fields},
                            [key for key, type_name in fields if not type_name.strip().endswith('?')])
    definitions[name]['x-haven'] = {'status': 'runtime-model', 'source': 'CellProtocol/Sources/CellBase/PersistingCells/EntityRelationRecordV1.swift',
                                    'validationBoundary': 'Codable structure plus selected constraints; runtime validation is still required.'}

definitions['EntityRelationRecord']['properties']['schema'] = {'const': 'haven.entity-relation-record.v1'}
definitions['EntityRelationRecord']['properties']['revision']['minimum'] = 1
definitions['EntityRelationInteractionSummary']['properties']['count']['minimum'] = 0
definitions['EntityRelationInteractionEvent']['properties']['schema'] = {'const': 'haven.relation-interaction-event.v1'}
definitions['EntityRelationInteractionEvent']['allOf'] = [{
    'if': {'properties': {'contentMode': {'enum': ['off', 'metadata']}}, 'required': ['contentMode']},
    'then': {'properties': {'summary': {'type': 'null'}}}
}]

target_for('relations.records').update(dictionary(ref('EntityRelationRecord'),
    'Nyere, typede relasjonsposter indeksert med relationID. Runtime kontrollerer ID-binding og egen batch-kontrakt. Null er en sletteoperasjon, ikke en lagret relasjonspost.'))
target_for('person.relations.interactionPolicy').update(obj({
    'mode': ref('EntityRelationInteractionPolicyMode'), 'updatedAt': string(format='date-time'),
    'fullContentWarningAccepted': {'type': 'boolean'}
}, ['mode']))
target_for('entityRepresentation')['properties'].update(copy.deepcopy(definitions['EntityRepresentation']['properties']))
target_for('entityRepresentation')['description'] = 'Registerets eldre, delvise representasjonsrot. Feltene er valgfrie her for kompatibilitet; en komplett Codable-node finnes i $defs.EntityRepresentation og relations.records.<id>.entityRepresentation. representationPolicy/representationOf er registermetadata, ikke implementerte PerspectiveNode-felt.'
write('EntityRepresentation.schema.json', {'$schema': DIALECT, '$id': 'urn:haven:review:entity-representation:2026-09-11',
      'title': 'EntityRepresentation – den felles vektede nodemodellen',
      '$ref': '#/$defs/EntityRepresentation', '$defs': perspective_schema.definitions()})
write('EntityRepresentation.example.json', perspective_schema.example())

# Validated contacts have a deliberately closed shape in the runtime.
definitions['ValidatedContact'] = obj({
    'schema': {'const': 'haven.entity-validated-contact-record.v1'},
    'relationID': string(minLength=1, **{'x-maxUTF8Bytes': 128}),
    'displayName': string(minLength=1, **{'x-maxUTF8Bytes': 256}),
    'channels': {**obj({
        'email': string(minLength=1, maxLength=254, pattern=r'^[\x21-\x3f\x41-\x7e]{1,64}@(?!\.)(?![^@]*\.\.)(?![^@]*\.$)[\x21-\x3f\x41-\x7e]*\.[\x21-\x3f\x41-\x7e]+$',
                        description='Avspeiler den avgrensede ASCII-kontrollen i runtime; dette er ikke bevis på at adressen kan motta e-post.'),
        'phoneE164': string(pattern=r'^\+[1-9][0-9]{7,14}$')
    }, closed=True), 'minProperties': 1},
    'provenance': obj({
        'sourceKind': string(enum=['macos-contacts', 'recipient-confirmed', 'user-supplied']),
        'sourceLabel': string(minLength=1, **{'x-maxUTF8Bytes': 256}),
        'observedAt': string(format='date-time')
    }, ['sourceKind', 'sourceLabel', 'observedAt'], True),
    'purposeRefs': arr(string(enum=['purpose://access.audit.privacy', 'purpose://contact.communication', 'purpose://contact.introduction']),
        uniqueItems=True, allOf=[{'contains': {'const': 'purpose://access.audit.privacy'}}, {'contains': {'const': 'purpose://contact.communication'}}]),
    'retention': obj({'storageAuthorized': {'const': True}, 'disclosureAuthorized': {'const': False}},
                     ['storageAuthorized', 'disclosureAuthorized'], True),
    'status': {'const': 'owner-accepted'}
}, ['schema', 'relationID', 'displayName', 'channels', 'provenance', 'purposeRefs', 'retention', 'status'], True)
definitions['ValidatedContact']['x-haven'] = {
    'status': 'runtime-validated-subset',
    'source': 'CellProtocol/Sources/CellBase/PersistingCells/EntityValidatedContactRecordV1.swift',
    'runtimeChecksStillRequired': ['trimmed strings and UTF-8 byte limits', 'Unicode alphanumeric relationID',
                                  'metadata/keypath/relationID equality', 'owner-signed commit', 'authorization']
}
target_for('relations.validatedContacts').update(dictionary(ref('ValidatedContact'),
    'Rå kontaktverdier i eiers private lagring. Kobles til relations.records med samme relationID. Skrives via haven.entity-validated-contact-batch.v1.'))

# Two source-backed agreement shapes coexist. Preserve both, do not silently migrate.
legacy_records = copy.deepcopy(target_for('signedAgreementEntity.records'))
definitions['CommittedAgreementRecord'] = obj({
    'id': string(), 'recordState': {'const': 'signed'},
    'signatureValidationState': {'const': 'verified'}, 'signingSemantics': string(),
    'counterpartySignatureState': {'const': 'not_present'}, 'immutable': {'const': True},
    'contractHash': string(), 'immutableContentHash': string(),
    'contract': obj(), 'metadata': obj(), 'credentialReceipts': arr(obj()),
    'committedAt': string(format='date-time')
}, ['id', 'recordState', 'signatureValidationState', 'signingSemantics', 'counterpartySignatureState',
    'immutable', 'contractHash', 'immutableContentHash', 'contract', 'metadata', 'credentialReceipts', 'committedAt'])
definitions['CommittedAgreementRecord']['description'] = 'Formen fra SignedAgreementEntitySupport.recordObject. Contract og credentialReceipts har egne delkontrakter som ikke er fullstendig ekspandert her. Signaturverifisering utføres av runtime.'
target_for('signedAgreementEntity')['properties']['records'] = {
    'description': 'To eksisterende former: listen i v1-registeret og dictionary fra signedAgreementEntity.commit. Ingen automatisk migrering er definert her.',
    'oneOf': [legacy_records, dictionary(ref('CommittedAgreementRecord'))],
    'x-haven': {'status': 'known-shape-divergence', 'source': 'CellProtocol/Sources/CellVapor/Cells/EntityAnchorCell.swift:553'}
}
target_for('signedAgreementEntity.receipts').update(dictionary(obj(), 'Signerte persistenskvitteringer per receiptID. Egen delkontrakt i SignedAgreementEntityCommit.swift.'))

# List is the registry shape, but the local initializer also emits an empty object.
chronicle = copy.deepcopy(schema['properties']['chronicle'])
chronicle['items'] = {
    'type': 'object',
    'if': {'properties': {'schema': {'const': 'haven.relation-interaction-event.v1'}}, 'required': ['schema']},
    'then': ref('EntityRelationInteractionEvent')
}
schema['properties']['chronicle'] = {
    'description': 'Historikkliste; tomt objekt tillates kun for å representere den observerte legacy-initialiseringen. Andre hendelser enn relasjonshendelser har egne kontrakter.',
    'oneOf': [chronicle, {'type': 'object', 'maxProperties': 0}],
    'x-haven': {'status': 'known-initialization-divergence', 'source': 'CellProtocol/Sources/CellVapor/Cells/EntityAnchorCell.swift:630'}
}

schema['properties']['identityLinks'] = obj({
    'records': dictionary(obj(), 'IdentityLinkRecord per kodet recordKey; feltformatet er definert i IdentityLinkingModels.swift.'),
    'approvals': dictionary(obj(), 'Godkjenningsdata per kodet approvalKey.'),
    'usedApprovalJTIs': dictionary({}, 'Forbrukte godkjennings-ID-er for replay-beskyttelse.')
})
schema['properties']['identityLinks'].update({
    'description': 'Vedvarende innmelding, kobling og tilbakekalling av operative identiteter. identityLinks.state er en beregnet API-visning og lagres ikke som felt her.',
    'x-haven': {'status': 'runtime-structure-partial', 'source': 'CellProtocol/Sources/CellVapor/Cells/EntityAnchorCell.swift:833'}
})
schema['properties']['dataInventory'] = obj()
schema['properties']['dataInventory'].update({
    'description': 'Privat inventar for autoriserte datarepresentasjoner og sikkerhetskopier. UserDataInventoryContracts.swift definerer typene; intern rotorganisering er ikke fastsatt av dette skjemaet.',
    'x-haven': {'status': 'runtime-root-partial', 'source': 'CellProtocol/Sources/CellBase/PersistingCells/UserDataInventoryContracts.swift'}
})
schema['x-haven']['registryDescriptorCount'] = len(descriptors)
write('EntityData.review.schema.json', schema)

example = {
    'person': {
        'name': {'first': 'Eksempel', 'last': 'Person'},
        'displayName': 'Eksempelperson',
        'profile': {'headline': 'Fiktiv profil for gjennomgang', 'websiteURLs': ['https://example.org']},
        'contact': {'emails': [{'id': 'email-demo', 'label': 'work', 'value': 'owner@example.org'}]},
        'languages': [{'tag': 'nb', 'label': 'Norsk bokmål', 'preferredForCommunication': True}],
        'preferences': {'locale': 'nb-NO', 'timezone': 'Europe/Oslo'},
        'relations': {'interactionPolicy': {'mode': 'metadata', 'updatedAt': '2026-09-11T09:00:00Z', 'fullContentWarningAccepted': False}}
    },
    'relations': {
        'records': {'relation-demo': {
            'schema': 'haven.entity-relation-record.v1', 'relationID': 'relation-demo',
            'entityRepresentation': perspective_schema.example(),
            'subject': {'displayName': 'Fiktiv samarbeidspartner', 'validatedContactRef': 'relations.validatedContacts.relation-demo'},
            'origin': {'kind': 'manual', 'at': '2026-09-11T09:00:00Z', 'sourceLabel': 'Fiktivt eksempel'},
            'roles': [{'context': 'Gjennomgang av EntityData', 'role': 'Samarbeidspartner'}],
            'interests': {'declared': ['Datastrukturer'], 'inferred': []},
            'purposeRefs': ['purpose://contact.communication'],
            'channels': [{'kind': 'email', 'ref': 'contact-endpoint-demo', 'confirmed': False, 'preferred': True}],
            'standing': {'trust': 'none'}, 'evidence': [],
            'interactions': {'count': 0, 'byChannel': {}, 'byKind': {}},
            'tags': ['fiktivt-eksempel'], 'createdAt': '2026-09-11T09:00:00Z',
            'updatedAt': '2026-09-11T09:00:00Z', 'revision': 1
        }},
        'validatedContacts': {'relation-demo': {
            'schema': 'haven.entity-validated-contact-record.v1', 'relationID': 'relation-demo',
            'displayName': 'Fiktiv samarbeidspartner', 'channels': {'email': 'collaborator@example.org'},
            'provenance': {'sourceKind': 'user-supplied', 'sourceLabel': 'Fiktivt eksempel', 'observedAt': '2026-09-11T09:00:00Z'},
            'purposeRefs': ['purpose://access.audit.privacy', 'purpose://contact.communication'],
            'retention': {'storageAuthorized': True, 'disclosureAuthorized': False}, 'status': 'owner-accepted'
        }}
    },
    'proofs': {}, 'chronicle': []
}
write('EntityData.example.json', example)

sources = [REGISTRY, RELATION,
    *[CP / ('Sources/CellBase/PurposeAndInterest/' + name + '.swift') for name in
      ['PerspectiveNode', 'EntityRepresentation', 'EntityRepresentationDataCodec', 'Interest', 'Purpose', 'Weight', 'Perspective', 'WeightedGraphRuntime', 'Constraint', 'PurposeComposition']],
    CP / 'Sources/CellBase/PersistingCells/EntityRelationPerspective.swift',
    HAVEN / 'Binding/Cells/RelationsCell.swift', HAVEN / 'Binding/Cells/RelationEntityStore.swift',
    HAVEN / 'Binding/Cells/HavenRelationKit.swift',
    CP / 'Sources/CellBase/ValueTypes/Types/Object.swift',
    CP / 'Sources/CellVapor/Cells/EntityAnchorCell.swift',
    CP / 'Sources/CellApple/Cells/EntityAnchorCell.swift',
    CP / 'Sources/CellBase/PersistingCells/EntityValidatedContactRecordV1.swift',
    CP / 'Sources/CellBase/Agreement/SignedAgreementEntity.swift',
    CP / 'Sources/CellBase/Agreement/SignedAgreementEntityCommit.swift',
    CP / 'Sources/CellBase/PersistingCells/EntityAuthorityCommit.swift',
    CP / 'Sources/CellBase/PersistingCells/EntityAuthorityReplicaStore.swift',
    CP / 'Sources/CellBase/PersistingCells/UserDataInventoryContracts.swift',
    CP / 'Sources/CellBase/Identity/IdentityLinkingModels.swift',
    HAVEN / 'CellProtocolDocuments/Book/03_Identity_Model.md',
    HAVEN / 'CellProtocolDocuments/Book/07_Scaffold_Runtime.md',
    HAVEN / 'CellProtocolDocuments/Deliverables/PDD_entitetsdata-egen-kontroll_2026-09-08/FORMAALSSPEC.md',
    HAVEN / 'CellProtocolDocuments/Deliverables/PDD_entitetsdata-egen-kontroll_2026-09-08/STATUS.md']
write('sources.json', {
    'asOf': '2026-09-11', 'basis': 'local-working-tree-files; not deployment verification',
    'sources': [{'path': str(p.relative_to(HAVEN)), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in sources],
    'discussionContext': [{'title': 'Design sikker Entitetssammenslåing', 'threadID': '01a08bdf-7a94-74a3-985d-cb1d59869d50',
                           'usedFor': 'Conceptual distinction between linking identities and merging populated entities; implementation claims were not taken from the conversation.'}],
    'architectureReference': '/Users/kjetil/.codex/skills/cellprotocol-distributed-entity-data/references/entity-data-contract.md',
    'externalReferences': ['https://json-schema.org/draft/2020-12/json-schema-core', 'https://json-schema.org/draft/2020-12/json-schema-validation']
})
print(f'Built {len(descriptors)} registry descriptors, {len(schema["properties"])} roots, {len(definitions)} definitions.')
