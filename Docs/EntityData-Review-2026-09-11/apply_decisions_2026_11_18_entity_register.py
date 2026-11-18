"""Append the owner's single entity register decision (18.11.2026) after the 25.09 step.

Documentation target only. Every transformation target is required, and all
schema and reference checks finish in memory before anything is written.
No Swift, runtime, wire or user-data migration is implied.

Decision (Kjetil, 17.-18.11.2026):
- One register `entities.<uuid>` at the root holds the full entityRepresentation.
  A uuid lookup must not need to know whether it is a person, an organisation,
  a group or a conference, so all of them live in the same register.
- Relations, groups, conference, proofs and Perspective refer to the register.
  What a relation is called is up to the owner; the entity is found without it.
- Groups get their uuid in the register (kind = group); `groups` keeps membership only.
- `conference` is keyed per conference entity: `conference.<entity-uuid>`.
"""
import copy

import apply_decisions_2026_09_25_skills as previous
from target_validation import check_schema, validate

HERE, DECISION = previous.HERE, previous.DECISION
require, expect, add, replace, encoded = (
    previous.require, previous.expect, previous.add, previous.replace, previous.encoded)
groups_step = previous.previous
UUID_PATTERN = groups_step.UUID_PATTERN
forbid_field = groups_step.previous.previous.forbid_field
STEP = 'apply_decisions_2026_11_18_entity_register.py'
VALIDATION = 'validate_decisions_2026_11_18_entity_register.py'

RELATIONS = ('properties', 'relations')
OLD_ENTITIES = RELATIONS + ('properties', 'entities')
GROUP = ('properties', 'groups', 'additionalProperties')
MEMBERS = GROUP + ('properties', 'members')
RECORD = ('$defs', 'EntityRelationRecord')
SUBJECT = ('$defs', 'EntityRelationSubject')
CONFERENCE = ('properties', 'conference')
SUPPORTS_ENTITY = ('properties', 'proofs', 'properties', 'credentials', 'additionalProperties',
                   'properties', 'supports', 'properties', 'entityRef')

KINDS = ['person', 'organization', 'group', 'event']
ENTITY_A = groups_step.ENTITY_A
ENTITY_B = groups_step.ENTITY_B
IDENTITY_A = groups_step.previous.previous.IDENTITY_A
GROUP_B = groups_step.previous.previous.GROUP_B
ORGANIZATION = '70000000-0000-4000-8000-000000000001'
CONFERENCE_ENTITY = '70000000-0000-4000-8000-000000000002'
RELATION = '40000000-0000-4000-8000-000000000001'

NOT_IMPLEMENTED = 'Besluttet 18.11.2026, ikke implementert i Swift.'
STORAGE = (
    'Logisk sannhet er eierens EntityData; registeret er der entiteten bor. Fysisk plassering er '
    'ikke en enhet: eieren bruker iPhone, iPad, Mac og sky, og det mest tilgjengelige stedet er '
    'ikke nødvendigvis telefonen eller den lokale Mac-en. Registeret skal derfor kunne ha replikaer '
    'på flere enheter og i sky, og oppslag går til den replikaen som er tilgjengelig. Valg av '
    'replika, synk og konflikthåndtering er en egen lagringskontrakt som ikke er skrevet. Indeks '
    '(B-tre eller database) for store registre er lagringsimplementasjon og står ikke i skjemaet. '
    'Perspective er en avledet visning bygget fra registeret, ikke et eget lager.')


def minimal_representation(name, node):
    return {'name': name, 'nodeIdentifier': node, 'types': [], 'subTypes': [], 'parts': [],
            'partOf': [], 'interests': [], 'purposes': [], 'entities': [], 'states': []}


def entity_schema(old_record):
    record = copy.deepcopy(old_record)
    expect(set(require(record, 'properties')), {'identityRefs', 'contactEndpointRefs'},
           'relations/entities/record/properties')
    expect(require(record, 'allOf'), [{'not': {'required': ['relationRefs']}}],
           'relations/entities/record/allOf')
    for key in ('identityRefs', 'contactEndpointRefs'):
        replace(record, ('properties', key, 'x-haven', 'keypath'), 'entities.<entityID>.' + key)
    replace(record, ('x-haven', 'keypath'), 'entities.<entityID>')
    replace(record, ('x-haven', 'status'), 'decided-target')
    replace(record, ('x-haven', 'sourceOfTruthLabel'), 'EntityData/EntityAnchorCell')
    replace(record, ('title',), 'Entity register record')
    replace(record, ('description',),
            'Én post per entitet, nøklet på entitets-uuid: person, organisasjon, gruppe eller '
            'arrangement. Posten bærer hele entityRepresentation og er det ene stedet entiteten '
            'bor. relationRefs persisteres ikke; de bygges fra relasjonenes subject.entityRef ved '
            'dekoding, i minnet. ' + NOT_IMPLEMENTED)
    add(record, 'required', ['kind', 'entityRepresentation'], 'entities/record')
    add(require(record, 'properties'), 'kind', {
        'type': 'string', 'enum': KINDS,
        'description': 'Hva slags entitet uuid-en er. Et oppslag trenger ikke vite dette på forhånd; '
                       'det står i posten. group brukes for grupper i groups, event for konferanser '
                       'og andre arrangementer. Listen er et forslag og kan utvides ved beslutning.'
    }, 'entities/record/properties')
    add(require(record, 'properties'), 'entityRepresentation', {
        '$ref': '#/$defs/EntityRepresentation',
        'description': 'Hele representasjonen av entiteten, sett fra eieren. Relasjonsposter, '
                       'grupper, konferanseskiver, bevis og Perspective refererer hit med uuid i '
                       'stedet for å bære egne kopier.'
    }, 'entities/record/properties')
    return record


def target_schema(input_schema):
    s = copy.deepcopy(input_schema)
    expect(require(s, 'x-haven', 'decisionsAsOf'), '2026-09-25', 'decisionsAsOf')
    if 'entities' in require(s, 'properties'):
        raise ValueError('FINNES ALLEREDE: properties/entities')

    # 1. The register moves to the root and gets the full representation.
    old = require(s, *OLD_ENTITIES)
    register = {
        'type': 'object',
        'title': 'Entity register',
        'description': 'Registeret over alle entiteter eieren kjenner, nøklet på entitets-uuid. '
                       'Et oppslag på uuid trenger ikke vite om det gjelder et individ, en '
                       'organisasjon, en gruppe eller en konferanse. relations.records, groups, '
                       'conference, proofs.credentials.supports og Perspective peker hit. ' + STORAGE
                       + ' ' + NOT_IMPLEMENTED,
        'x-haven': {**copy.deepcopy(require(old, 'x-haven')), 'keypath': 'entities',
                    'status': 'decided-target', 'sourceOfTruthLabel': 'EntityData/EntityAnchorCell',
                    'movedFrom': 'relations.entities'},
        'propertyNames': copy.deepcopy(require(old, 'propertyNames')),
        'additionalProperties': entity_schema(require(old, 'additionalProperties')),
    }
    replace(register, ('propertyNames',), {'pattern': UUID_PATTERN, 'maxLength': 36})
    add(require(s, 'properties'), 'entities', register, 'properties')
    del require(s, *RELATIONS, 'properties')['entities']
    expect(require(s, *RELATIONS, 'additionalProperties'), False, 'relations/additionalProperties')
    replace(s, RELATIONS + ('description',),
            'Objekt med bare reserverte nøkler. Relasjoner bærer den vektede perspektivgrafen og '
            'peker på entiteten i registeret entities med subject.entityRef; selve '
            'entityRepresentation ligger i registeret, ikke i relasjonsposten. Hva relasjonen '
            'heter, er opp til eieren. relations.entities er flyttet til roten entities. '
            'Dagens Swift-lagring og runtime-grunnlaget er ikke endret.')

    # 2. Relation records refer to the register; the embedded copy goes.
    expect(require(s, *RECORD, 'properties', 'entityRepresentation'),
           {'$ref': '#/$defs/EntityRepresentation'}, 'record/entityRepresentation')
    forbid_field(s, RECORD, 'entityRepresentation')
    replace(s, RECORD + ('description',), require(s, *RECORD, 'description') +
            ' Relasjonsposten bærer ikke entityRepresentation; den ligger i entities.<entityRef>. '
            'Relasjonsspesifikke kanter og vekter er en åpen kontrakt. ' + NOT_IMPLEMENTED)
    subject = require(s, *SUBJECT)
    expect(require(subject, 'required'), ['displayName'], 'subject/required')
    replace(s, SUBJECT + ('required',), ['displayName', 'entityRef'])
    replace(s, SUBJECT + ('properties', 'entityRef'), {
        'type': 'string', 'pattern': UUID_PATTERN, 'maxLength': 36,
        'description': 'Påkrevd entitets-uuid i entities, lagret bare fra relasjon til entitet. '
                       'Motsatt retning bygges ved dekoding, i minnet. ' + NOT_IMPLEMENTED})

    # 3. Groups are entities; `groups` keeps membership and hierarchy only.
    expect(require(s, *GROUP, 'required'), ['name', 'members'], 'group/required')
    expect(require(s, *GROUP, 'additionalProperties'), False, 'group/additionalProperties')
    expect(set(require(s, *GROUP, 'properties')), {'name', 'members', 'partOf'}, 'group/properties')
    del require(s, *GROUP, 'properties')['name']
    replace(s, GROUP + ('required',), ['members'])
    replace(s, ('properties', 'groups', 'description'),
            'Medlemskap og hierarki for grupper. Nøkkelen er gruppens entitets-uuid, og gruppen selv '
            'står i entities med kind = group; navnet ligger i entityRepresentation.name der, ikke her. '
            'members er en uvektet liste over entitets-uuid-er; partOf peker til foreldregruppen. '
            'Barnelister og hvilke grupper en entitet tilhører bygges ved dekoding. JSON Schema kan '
            'ikke oppdage sykler eller kontrollere referansetyper; dekoderen må gjøre det. ' + NOT_IMPLEMENTED)
    replace(s, MEMBERS + ('description',),
            'Flat liste med entitets-uuid-er i entities, uten vekter eller kopier. Samme entitet kan '
            'stå i flere grupper. En entitet med kind = group skal avvises her; undergrupper bruker partOf.')
    replace(s, MEMBERS + ('items', 'description'),
            'Entitets-uuid i entities, ikke en gruppe. JSON Schema kontrollerer bare UUID-syntaks.')

    # 4. The conference slice is keyed per conference entity.
    slice_schema = copy.deepcopy(require(s, *CONFERENCE))
    expect(require(slice_schema, 'title'), 'Conference participant slice', 'conference/title')
    replace(s, CONFERENCE, {
        'type': 'object',
        'title': 'Conference participant slices',
        'description': 'Én deltakerskive per konferanse, nøklet på konferansens entitets-uuid i '
                       'entities (kind = event). Uuid-en slås opp i registeret uten å kjenne noen '
                       'relasjon. Forslagene conference.<uuid>.cells[] og matchConsent er ikke '
                       'besluttet og er ikke lagt inn. ' + NOT_IMPLEMENTED,
        'x-haven': {'status': 'decided-target', 'movedFrom': 'conference'},
        'propertyNames': {'pattern': UUID_PATTERN, 'maxLength': 36},
        'additionalProperties': slice_schema,
    })

    # 5. Everything else that pointed at relations.entities points at the register.
    replace(s, SUPPORTS_ENTITY + ('description',), require(s, *SUPPORTS_ENTITY, 'description') +
            ' Uuid-en slås opp i entities.')
    xh = require(s, 'x-haven')
    replace(s, ('x-haven', 'decisionsAsOf'), '2026-11-18')
    add(xh, 'entityRegisterImplementation',
        'Ett register entities.<uuid> med hele entityRepresentation og kind. relations.entities, '
        'entityRepresentation i relasjonsposten og name i groups er tatt ut. ' + NOT_IMPLEMENTED +
        ' Dekoderen må kontrollere at alle entitetsreferanser finnes og har riktig kind. '
        'Migrering av eksisterende relations.entities og relations.records gjenstår.', 'x-haven')
    add(xh, 'entityRegisterStorage', STORAGE, 'x-haven')
    deferred = require(xh, 'deferredDecisions')
    for key, text in {
        'conference.cells': 'Forslag 24.09: conference.<uuid>.cells[] for celler konferansen har utstedt. '
                            'Må avklares mot scaffoldPresence.mounts/bindings. Ikke besluttet.',
        'conference.matchConsent': 'Forslag 24.09: conference.<uuid>.matchConsent, egne identiteter og formål '
                                   'eieren lar seg matche på. Ikke besluttet.',
        'agreements.membershipProofCondition': 'Forslag 24.09: grant-betingelse «gyldig medlemskapsbevis i '
                                               'proofs.credentials med supports.entityRef = X». Ikke besluttet.',
        'relations.records.perspectiveEdges': 'Relasjonsspesifikke kanter og vekter når entityRepresentation '
                                              'ligger i entities. Ingen kontrakt er skrevet.',
        'entities.storageContract': 'Replikaer på iPhone, iPad, Mac og sky; valg av replika, synk og konflikt. '
                                    'Ikke skrevet.',
    }.items():
        add(deferred, key, text, 'x-haven/deferredDecisions')
    replace(s, ('description',), require(s, 'description') +
            ' 18.11: ett entitetsregister ved roten; relasjoner, grupper og konferanser refererer til det.')
    replace(s, ('$comment',),
            'Bygges av ' + STEP + ' etter 16.09-, 22.09-, 23.09-, undergruppe- og skills-stegene. '
            'Entitetsregisteret er besluttet, ikke implementert; runtime-grunnlaget er urørt.')
    return s


def transform_data(input_data):
    d = copy.deepcopy(input_data)
    relations = require(d, 'relations')
    expect(set(require(relations, 'entities')), {ENTITY_A, ENTITY_B}, 'example/relations/entities')
    expect(set(require(relations, 'records')), {RELATION}, 'example/relations/records')
    if 'entities' in d or 'conference' in d:
        raise ValueError('UVENTET FORM: example already has entities or conference')
    old = relations.pop('entities')
    record = require(relations, 'records', RELATION)
    expect(require(record, 'subject', 'entityRef'), ENTITY_A, 'example/record/entityRef')
    representation = record.pop('entityRepresentation')
    entities = {
        ENTITY_A: {'kind': 'person', 'entityRepresentation': representation, **old[ENTITY_A]},
        ENTITY_B: {'kind': 'person', **old[ENTITY_B],
                   'entityRepresentation': minimal_representation('Fiktiv venn', 'entity-friend-demo')},
        ORGANIZATION: {'kind': 'organization', 'identityRefs': [],
                       'entityRepresentation': minimal_representation('Fiktivt forlag ved Månesjøen',
                                                                      'entity-publisher-demo')},
        CONFERENCE_ENTITY: {'kind': 'event', 'identityRefs': [],
                            'entityRepresentation': minimal_representation('Fiktiv konferanse ved Månesjøen',
                                                                           'entity-conference-demo')},
    }
    for uuid, group in require(d, 'groups').items():
        name = group.pop('name')
        entities[uuid] = {'kind': 'group', 'identityRefs': [],
                          'entityRepresentation': minimal_representation(name, 'group-' + uuid[-4:])}
    require(d, 'groups', GROUP_B, 'members').append(ORGANIZATION)
    d['entities'] = entities
    d['conference'] = {CONFERENCE_ENTITY: {}}
    return d


def reference_errors(data):
    """Semantic checks AFTER schema validation, for the complete local example only.

    Case-insensitive UUIDs. A missing or wrongly typed reference fails; nothing is guessed.
    Documentation verification, not the Swift decoder.
    """
    errors = []
    raw = data.get('entities', {})
    kinds = {key.lower(): value['kind'] for key, value in raw.items()}
    if len(kinds) != len(raw):
        errors.append('entities: duplicate UUID keys differing only in case')
    identities = {key.lower() for key in data.get('relations', {}).get('identities', {})}

    def entity(ref, where, allowed=None, forbidden=None):
        kind = kinds.get(ref.lower())
        if kind is None:
            errors.append(f'{where}: unknown entity UUID: {ref}')
        elif allowed and kind not in allowed:
            errors.append(f'{where}: entity {ref} has kind {kind}, expected {"/".join(allowed)}')
        elif forbidden and kind in forbidden:
            errors.append(f'{where}: entity {ref} has forbidden kind {kind}')

    for uuid, record in raw.items():
        for ref in record.get('identityRefs', []):
            if ref.lower() not in identities:
                errors.append(f'entities/{uuid}/identityRefs: unknown identity UUID: {ref}')
    for uuid, record in data.get('relations', {}).get('records', {}).items():
        entity(record['subject']['entityRef'], f'relations/records/{uuid}/subject/entityRef')
    groups = {key.lower(): value for key, value in data.get('groups', {}).items()}
    for uuid, group in groups.items():
        entity(uuid, f'groups/{uuid}', allowed=['group'])
        for member in group['members']:
            entity(member, f'groups/{uuid}/members', forbidden=['group'])
        if 'partOf' in group and group['partOf'].lower() not in groups:
            errors.append(f'groups/{uuid}/partOf: unknown parent group UUID: {group["partOf"]}')
    done = set()
    for start in groups:
        path, node = set(), start
        while node in groups and node not in done:
            if node in path:
                errors.append(f'groups/{start}/partOf: cycle at {node}; decoder must reject')
                break
            path.add(node)
            parent = groups[node].get('partOf')
            if parent is None:
                break
            node = parent.lower()
        done.update(path)
    for uuid in data.get('conference', {}):
        entity(uuid, f'conference/{uuid}', allowed=['event'])
    for uuid, proof in data.get('proofs', {}).get('credentials', {}).items():
        entity(proof['supports']['entityRef'], f'proofs/credentials/{uuid}/supports/entityRef')
    return errors


def validate_target(schema, data):
    validate(schema, data)
    errors = reference_errors(data)
    if errors:
        raise ValueError('; '.join(errors))


def build_artifacts():
    artifacts = previous.build_artifacts()
    manifest = require(artifacts, 'current-review.json')
    schema_name = require(manifest, 'schema')
    graph_name = require(manifest, 'graphSchema')
    example_name = require(manifest, 'example')
    s = target_schema(require(artifacts, schema_name))
    data = transform_data(require(artifacts, example_name))
    graph = copy.deepcopy(require(artifacts, graph_name))
    replace(graph, ('$defs',), copy.deepcopy(require(s, '$defs')))
    replace(graph, ('x-haven',), copy.deepcopy(require(s, 'x-haven')))
    replace(graph, ('title',), 'EntityRepresentation – løpende målmodell etter beslutningen 18. november 2026')
    expect(require(manifest, 'buildSteps'),
           ['apply_decisions_2026_09_16.py', 'apply_decisions_2026_09_22.py',
            'apply_decisions_2026_09_23.py', 'apply_decisions_2026_09_23_groups.py',
            'apply_decisions_2026_09_25_skills.py'], 'manifest/buildSteps')
    replace(manifest, ('buildSteps',), manifest['buildSteps'] + [STEP])
    for key, value in {'updatedAt': '2026-11-18', 'decisionsAsOf': '2026-11-18',
                       'latestDecisions': 'BESLUTNING-ENTITETSREGISTER-2026-11-18.md',
                       'buildCommand': 'python -B ' + STEP,
                       'validationCommand': 'python -B ' + VALIDATION}.items():
        replace(manifest, (key,), value)
    for schema in (s, graph):
        check_schema(schema)
    validate_target(s, data)
    artifacts[schema_name], artifacts[graph_name], artifacts[example_name] = s, graph, data
    return artifacts


def main():
    artifacts = build_artifacts()
    for name, value in artifacts.items():
        (HERE / name).write_bytes(encoded(value))
    print('16.09 -> 22.09 -> 23.09 -> undergrupper -> skills -> entitetsregister: bygget og validert.')
    print('Ett register entities.<uuid>; relasjoner, grupper og konferanser refererer. Ingen Swift-endringer.')


if __name__ == '__main__':
    main()
