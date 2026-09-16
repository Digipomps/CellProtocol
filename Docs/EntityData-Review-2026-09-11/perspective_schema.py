"""Codable shapes of the existing PerspectiveNode subclasses (source list in build_review.py)."""

def definitions():
    def ref(name): return {'$ref': '#/$defs/' + name}
    def arr(name): return {'type': 'array', 'items': ref(name)}
    def obj(properties, required=()):
        return {'type': 'object', 'properties': properties, 'required': list(required), 'additionalProperties': True}
    text = {'type': 'string'}
    number = {'type': 'number'}
    nullable = lambda shape: {'anyOf': [shape, {'type': 'null'}]}
    result = {}
    for kind in ('EntityRepresentation', 'Interest', 'Purpose'):
        result['WeightOf' + kind] = {
            **obj({'weight': number, 'value': ref(kind), 'reference': text}, ['weight']),
            'anyOf': [{'required': ['value']}, {'required': ['reference']}],
            'description': f'Weight<{kind}>. Inline value eller referanse til en eksisterende node av samme type. Encoder velger én. Ved gjentakelse/sirkel bruker Codable samme typede ID-register via userInfo og skriver referansen. Ett registersett per dokument. Referanseoppløsning kontrolleres av runtime; vekt er ikke en sannsynlighet eller et Grant.'
        }
        same = 'WeightOf' + kind
        properties = {'name': text, 'nodeIdentifier': nullable(text),
                      **{k: arr(same) for k in ('types', 'subTypes', 'parts', 'partOf')},
                      'interests': arr('WeightOfInterest'), 'purposes': arr('WeightOfPurpose'),
                      'entities': arr('WeightOfEntityRepresentation'), 'states': arr('WeightOfInterest')}
        required = ['name', 'types', 'subTypes', 'parts', 'partOf', 'interests', 'purposes', 'entities', 'states']
        if kind == 'EntityRepresentation':
            properties.update({'person': {'type': 'object', 'additionalProperties': True,
                                          'description': 'Eierprivat Entity/Object med eierens kunnskap. Kun eksplisitt eierprivat kodek bevarer feltet. Ingen automatisk delingsrett.'},
                               'projectionSource': nullable(text), 'agreementRefs': arr('AgreementReference')})
        elif kind == 'Interest':
            properties['constraint'] = nullable(ref('InterestCondition'))
        else:
            properties.update({'description': nullable(text), 'goal': nullable(ref('CellConfiguration')),
                               'helperCells': nullable(arr('CellConfiguration')), 'composition': nullable(ref('PurposeComposition'))})
        result[kind] = obj(properties, required)
        result[kind]['x-haven'] = {'baseType': 'PerspectiveNodeImpl', 'status': 'runtime-model',
                                   'source': f'CellProtocol/Sources/CellBase/PurposeAndInterest/{kind}.swift'}
    result['EntityRepresentation']['description'] = 'Min representasjon av en entitet, inkludert en kontakt. Samme vektede nodetype brukes til lagring og et eksplisitt valgt matchingutsnitt. identities og fulfilled inngår foreløpig ikke i denne Codable-formen.'
    result['AgreementReference'] = obj({k: text for k in ('id', 'label')}, ['id', 'label'])
    for k in ('counterparty', 'purpose', 'dataPointer', 'savedAtText', 'recordKeypath', 'sourceEntityKeypath'):
        result['AgreementReference']['properties'][k] = nullable(text)
    result['AgreementReference']['properties']['savedAt'] = nullable({'type': 'integer'})
    result['AgreementReference']['properties']['recordState'] = nullable(text)
    result['AgreementReference']['description'] = 'Referansemetadata; recordState og selve avtalen må valideres mot avtalekontrakten.'
    result['CellConfiguration'] = obj({'name': text, 'uuid': text, 'description': nullable(text),
        'cellReferences': nullable({'type': 'array', 'items': {'type': 'object'}}), 'skeleton': {}}, ['name'])
    result['CellConfiguration']['x-haven'] = {'status': 'partial-contract', 'source': 'CellProtocol/Sources/CellBase/CellConfiguration/CellConfiguration.swift',
                                            'limitation': 'Dette skjemaet ekspanderer ikke Skeleton, CellReference, discovery eller localization. Runtime kreves.'}
    result['PurposeComposition'] = {'oneOf': [
        obj({'type': {'const': 'purpose'}, 'purposeRef': text, 'name': nullable(text)}, ['type', 'purposeRef']),
        obj({'type': {'enum': ['allOf', 'anyOf', 'sequence']}, 'children': arr('PurposeComposition')}, ['type', 'children']),
        obj({'type': {'const': 'atLeast'}, 'requiredCount': {'type': 'integer'}, 'children': arr('PurposeComposition')}, ['type', 'requiredCount', 'children'])]}
    result['InterestCondition'] = {'oneOf': [
        obj({'type': {'const': 'always'}}, ['type']),
        obj({'type': {'const': 'purposeSolvedWithin'}, 'purposeRef': text, 'maxAgeSeconds': {'type': 'number', 'minimum': 0},
             'status': {'enum': ['started', 'succeeded', 'failed']}}, ['type', 'purposeRef', 'maxAgeSeconds']),
        obj({'type': {'const': 'metadataFreshness'}, 'key': text, 'maxAgeSeconds': {'type': 'number', 'minimum': 0}}, ['type', 'key', 'maxAgeSeconds']),
        obj({'type': {'enum': ['all', 'any']}, 'conditions': arr('InterestCondition')}, ['type', 'conditions']),
        obj({'type': {'const': 'not'}, 'condition': ref('InterestCondition')}, ['type', 'condition'])]}
    return result


def example():
    def node(name, identifier):
        return {'name': name, 'nodeIdentifier': identifier, **{key: [] for key in
                ('types', 'subTypes', 'parts', 'partOf', 'interests', 'purposes', 'entities', 'states')}}
    interest = node('Datastrukturer', 'interest-data-demo')
    interest['constraint'] = {'type': 'metadataFreshness', 'key': 'owner-confirmed', 'maxAgeSeconds': 86400}
    purpose = node('Gjennomgå EntityData sammen', 'purpose-review-demo')
    purpose.update({'description': 'Fiktivt formål, samme nodetype for eget formål og et formål man leter etter.',
                    'helperCells': [{'name': 'Gjennomgang', 'uuid': 'helper-review-demo',
                                     'cellReferences': [{'endpoint': 'cell:///ExampleReview', 'subscribeFeed': False, 'label': 'Fiktiv hjelper'}]}],
                    'composition': {'type': 'purpose', 'purposeRef': 'purpose-read-demo'},
                    'interests': [{'weight': 0.65, 'value': interest}]})
    entity = node('Fiktiv samarbeidspartner', 'entity-collaborator-demo')
    entity.update({'person': {'displayName': 'Fiktiv samarbeidspartner', 'work': {'title': 'Fiktiv fagrolle'}},
                   'purposes': [{'weight': 0.8, 'value': purpose}],
                   'interests': [{'weight': 0.65, 'reference': 'interest-data-demo'}],
                   'agreementRefs': []})
    return entity
