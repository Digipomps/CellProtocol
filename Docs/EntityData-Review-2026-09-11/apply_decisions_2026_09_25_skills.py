"""Append the owner's skills-as-purposes decision after the 23.09 group step.

Documentation target only. Require every existing target and validate everything
in memory before writing. No new node type, evidence field or runtime behavior.
"""
import copy

import apply_decisions_2026_09_23_groups as previous
from target_validation import check_schema

HERE, DECISION = previous.HERE, previous.DECISION
require, expect, add, replace, encoded = (
    previous.require, previous.expect, previous.add, previous.replace, previous.encoded)
PERSON = ('$defs', 'PersonProfile')
SKILLS = PERSON + ('properties', 'skills')
PURPOSE = ('$defs', 'Purpose')
STEP = 'apply_decisions_2026_09_25_skills.py'
SKILL_UUID = '60000000-0000-4000-8000-000000000001'
OWNER_NODE_UUID = '60000000-0000-4000-8000-000000000002'
SKILL_DESCRIPTION = (
    'En skill er et formål brukeren hevder å kunne oppfylle, med samme Purpose-nodeform '
    'som ethvert annet formål. Grafen er det ene stedet skills bor; person.skills utgår '
    'helt, også som avledet liste. Ingen egen SearchPurpose eller Skill-type. '
    'Purpose.goal er påkrevd og må si hva oppfyllelse er: en skill uten et målbart '
    'resultat kan ikke uttrykkes i denne formen, og det er med vilje. '
    'Skjemaet krever goal-konfigurasjonen, men kan ikke bevise målbarhet. '
    'Besluttet 25.09.2026, ikke implementert i Swift.')
EVIDENCE_BLOCKER = (
    'person.skills[].evidenceRefs er fjernet sammen med listen. proofs.credentials og '
    'supports.keypaths er uendret. keypaths tillater en ikke-tom streng, men en stabil '
    'sti til en Purpose-node gjennom WeightOfPurpose-lister og value/reference er '
    'ikke kontraktfestet eller verifisert. Dagens fixture-oppløser støtter bare '
    'objektstier. Åpen sperre: bevis kan ikke hevdes koblet til en bestemt skill-node '
    'før nodeadressering og referanseoppløsning er avklart. Ingen nye bevisfelt innføres.')
DESCRIPTION_PATHS = (
    ('properties', 'purposes', 'description'),
    ('properties', 'entityRepresentation', 'description'),
    ('$defs', 'EntityRepresentation', 'description'),
    PURPOSE + ('description',),
)


def skill_paths(value, path=()):
    """Inventory only: do not silently migrate unknown example data."""
    result = []
    if isinstance(value, dict):
        for key, child in value.items():
            if key == 'skills':
                result.append(path + (key,))
            result.extend(skill_paths(child, path + (key,)))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            result.extend(skill_paths(child, path + (str(index),)))
    return result


def target_schema(input_schema):
    s = copy.deepcopy(input_schema)
    expect(require(s, 'x-haven', 'decisionsAsOf'), '2026-09-23', 'decisionsAsOf')
    require(s, 'x-haven', 'groupHierarchyImplementation')
    expect(require(s, *SKILLS, 'type'), 'array', 'PersonProfile.skills/type')
    expect(require(s, *SKILLS, 'items', 'type'), 'object', 'skills/items/type')
    expect(set(require(s, *SKILLS, 'items', 'properties')),
           {'label', 'level', 'taxonomyRef', 'evidenceRefs'}, 'skills record fields')
    for field, kind in [('label', 'string'), ('level', 'string'),
                        ('taxonomyRef', 'string'), ('evidenceRefs', 'array')]:
        expect(require(s, *SKILLS, 'items', 'properties', field, 'type'), kind, 'skills/' + field)
    expect(require(s, *PERSON, 'additionalProperties'), True, 'PersonProfile/additionalProperties')
    if 'goal' not in require(s, *PURPOSE, 'required'):
        raise ValueError('UVENTET FORM: Purpose.goal must already be required')
    expect(require(s, *PURPOSE, 'properties', 'goal'),
           {'$ref': '#/$defs/CellConfiguration'}, 'Purpose.goal')
    del require(s, *PERSON, 'properties')['skills']
    # Keep unrelated extensibility, but reject this retired key regardless of value.
    add(require(s, *PERSON), 'not', {'required': ['skills']}, 'PersonProfile')
    replace(s, PERSON + ('description',), require(s, *PERSON, 'description') +
            ' person.skills er forbudt; skills er formålsnoder i grafen, ikke egne poster eller en avledet liste.')
    for path in DESCRIPTION_PATHS:
        replace(s, path, require(s, *path) + ' ' + SKILL_DESCRIPTION)
    for key in ('asOf', 'decisionsAsOf'):
        expect(require(s, 'x-haven', key), '2026-09-23', 'x-haven/' + key)
        replace(s, ('x-haven', key), '2026-09-25')
    add(require(s, 'x-haven', 'deferredDecisions'), 'skills.proofNodeAddressing',
        EVIDENCE_BLOCKER, 'x-haven/deferredDecisions')
    replace(s, ('title',), 'EntityData – løpende målmodell etter beslutningene 25. september 2026')
    replace(s, ('description',), require(s, 'description') + ' ' + SKILL_DESCRIPTION)
    replace(s, ('$comment',),
            'Bygges av apply_decisions_2026_09_25_skills.py etter 16.09-, 22.09-, '
            '23.09- og undergruppestegene. Skills er bare formål. Runtime-grunnlaget '
            'er urørt; se beslutningsdokumentet for åpen sperre om bevis til formålsnoder.')
    return s


def transform_data(input_data):
    d = copy.deepcopy(input_data)
    require(d, 'person')
    require(d, 'relations', 'records', previous.previous.RELATION_UUID, 'entityRepresentation', 'purposes')
    expect(skill_paths(d), [], 'prior example has no skills entries to migrate')
    node = {
        'name': 'Levere en liten nettside (fiktiv skill)',
        'nodeIdentifier': SKILL_UUID,
        'types': [], 'subTypes': [], 'parts': [], 'partOf': [],
        'interests': [], 'purposes': [], 'entities': [], 'states': [],
        'description': 'Den oppdiktede eieren hevder å kunne oppfylle dette formålet. '
                       'Dette er en skill i vanlig Purpose-form, uten separat skill-post.',
        'goal': {
            'name': 'FiktivNettsideLeveranse',
            'description': 'Oppfylt når én levert nettside har nøyaktig tre sider '
                           '(forside, om og kontakt), alle tre kan åpnes, og en kontroll '
                           'av samtlige interne lenker finner null brutte lenker. '
                           'Fiktiv målkonfigurasjon med målbare kriterier; ingen målecelle '
                           'er implementert eller kjørt.'
        }
    }
    add(d, 'entityRepresentation', {
        'name': 'Den fiktive eierens representasjon', 'nodeIdentifier': OWNER_NODE_UUID,
        'types': [], 'subTypes': [], 'parts': [], 'partOf': [], 'interests': [],
        'purposes': [{'weight': 1, 'value': node}], 'entities': [], 'states': []
    }, 'example')
    return d


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
    replace(graph, ('title',), 'EntityRepresentation – løpende målmodell etter beslutningene 25. september 2026')
    expect(require(manifest, 'buildSteps'),
           ['apply_decisions_2026_09_16.py', 'apply_decisions_2026_09_22.py',
            'apply_decisions_2026_09_23.py', 'apply_decisions_2026_09_23_groups.py'], 'manifest/buildSteps')
    replace(manifest, ('buildSteps',), manifest['buildSteps'] + [STEP])
    for key, value in {'updatedAt': '2026-09-25', 'decisionsAsOf': '2026-09-25',
                       'buildCommand': 'python -B ' + STEP,
                       'validationCommand': 'python -B validate_decisions_2026_09_25_skills.py'}.items():
        replace(manifest, (key,), value)
    for schema in (s, graph):
        check_schema(schema)
    previous.validate_target(s, data)
    artifacts[schema_name], artifacts[graph_name], artifacts[example_name] = s, graph, data
    return artifacts


def main():
    artifacts = build_artifacts()
    for name, value in artifacts.items():
        (HERE / name).write_bytes(encoded(value))
    print('16.09 -> 22.09 -> 23.09 -> undergrupper -> skills som formål: bygget og validert.')
    print('person.skills avvises. Bevis til formålsnode er en åpen sperre. Ingen Swift-endringer.')


if __name__ == '__main__':
    main()
