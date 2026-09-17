"""Apply Kjetil's review to a target schema, keeping the runtime snapshot intact.

This does not migrate stored data or change a Swift/wire contract. Decisions,
proposed details and unresolved questions are recorded separately.
"""
import copy
import hashlib
import json
import re
from pathlib import Path
from jsonschema import Draft202012Validator, FormatChecker

OUT = Path(__file__).resolve().parent
BASE = OUT / 'EntityData.review.schema.json'
REVIEW = OUT / 'GJENNOMGANG_KJETIL_2026-09-16.md'
TARGET = 'EntityData.v2.schema.json'

def ref(name): return {'$ref': '#/$defs/' + name}
def forbid(node, *names):
    node.setdefault('allOf', []).append({'not': {'anyOf': [{'required': [n]} for n in names]}})
    for n in names:
        node.get('properties', {}).pop(n, None)
        if n in node.get('required', []): node['required'].remove(n)

def target_schema(base):
    s = copy.deepcopy(base)
    s.update({'$id':'urn:haven:entity-data:review-decisions:2026-09-16',
      'title':'EntityData – målmodell etter Kjetils gjennomgang 16. september 2026',
      'description':'Målmodell etter eierens gjennomgang, oppdatert 17. september. Endringene er ikke en ferdig implementert wire-kontrakt. Uavklarte detaljformer er merket.',
      '$comment':'Historisk runtime-skjema er bevart i EntityData.review.schema.json. Ingen data er migrert. Se current-review.json og review-decisions-2026-09-16.json.'})
    s['x-haven']={'status':'decision-target-draft','asOf':'2026-09-17','decisionsAsOf':'2026-09-16',
      'reviewSource':REVIEW.name,'reviewSourceSHA256':hashlib.sha256(REVIEW.read_bytes()).hexdigest(),
      'runtimeBaseline':BASE.name,'runtimeBaselineSHA256':hashlib.sha256(BASE.read_bytes()).hexdigest(),
      'runtimeCompatibility':'not-claimed; migration and caller changes required',
      'validates':'target-structural-shape-only','doesNotValidate':['measurability-of-goal','signature','authorization','reference-resolution','identity-equivalence','migration','replication'],
      'reviewCounts':{'elements':253,'approvedWithoutComment':203,'commented':45,'untouched':5}}
    props=s['properties'];defs=s['$defs']
    person=props['person']
    conference=person['properties'].pop('conference')
    conference['description']='Egen domeneskive ved roten. Formålssnapshot fornyes ved påmelding og deltakelse; consentRecords er ikke autoritativt Agreement-samtykke.'
    conference['x-haven']={'status':'decided-target','movedFrom':'person.conference'}
    props['conference']=conference
    forbid(person,'conference')

    contact=person['properties']['contact']
    forbid(contact,'email','phone')
    endpoint=contact['properties']['endpoints']['items']
    endpoint['properties']['cellReference']=endpoint['properties'].pop('endpointCell')
    endpoint['properties']['cellReference']['description']='Foreslått navn fra gjennomgangen; detaljformen er fortsatt åpen. Eksemplet bruker en cell://-referanse, ikke hele Codable CellReference-kontrakten.'
    endpoint['properties']['cellReference']['x-haven']={'status':'name-and-shape-proposal','replaces':'endpointCell'}
    endpoint['properties']['label']={'type':'string','description':'Brukslabel, eksempelvis primary eller work.'}
    endpoint['description']='Felles endpoint-deskriptor for egen profil og kontaktens persondata. Retningen omfatter telefon, e-post, sosiale navn, URL og cellereferanser. Råverdi-, rute-, status- og bevisskjemaene for alle disse er ennå ikke fastlagt; ingen nye enum-varianter er oppfunnet her.'
    endpoint['x-haven']={'status':'partial-target-contract','openDetails':['raw address variants','routing and confirmation','final cellReference shape']}
    forbid(endpoint,'endpointCell')
    defs['ContactEndpoint']=endpoint
    contact['properties']['endpoints']['items']=ref('ContactEndpoint')
    contact['properties']['phones']['items']['properties']['label']['description']='Label skiller telefonenes bruk; primary erstatter behovet for et separat phone-felt.'
    contact['description']='Felles kontaktstruktur. Endpoints er hovedretningen; de kommenterte emails[]/phones[] beholdes inntil deres forhold til den generelle endpoint-formen er avklart. Status er en påstand, ikke et bevis.'
    defs['PersonContact']=contact
    person['properties']['contact']=ref('PersonContact')
    communication=person['properties']['preferences']['properties']['communication']
    forbid(communication,'preferredChannel')
    privacy=person['properties']['preferences']['properties']['privacy']['properties']['defaultVisibility']
    privacy['default']='private'
    privacy['description']='Private er standard etter gjennomgangen. JSON Schema default fyller ikke inn data og håndhever ikke tilgang; dette krever runtime.'
    person['properties']['displayName']['description']='Beholdes som eierens foretrukne profilnavn. Kontekstspesifikke visningsnavn kan ha mindre scope, blant annet i Perspective.'
    person['properties']['profile']['properties']['interestTags']['description']='Forenklede etiketter for gjenkjenning/annonsering, eksempelvis Nearby userInfo. Kan avledes; erstatter ikke Interest/Purpose-grafen.'
    person['properties']['demographics']['description']='Private som utgangspunkt. Lagring av sensitive kategorier om andre i EntityRepresentation er et åpent vurderingspunkt.'
    defs['PersonProfile']=person
    props['person']=ref('PersonProfile')
    defs['EntityRepresentation']['properties']['person']=ref('PersonProfile')
    defs['EntityRepresentation']['description']='Kontakt er en node i min graf: min representasjon av hva jeg vet om en annen entitet. Persondata bruker den samme profil- og endpoint-strukturen. Lagring gir ingen delingsrett.'
    defs['EntityRepresentation']['x-haven']['status']='decision-target; private-person-shape-alignment'
    defs['Interest']['description']='En node med gjenkjennelig label, definert av relasjonene til andre noder. Wire-feltet constraint inneholder InterestCondition; Swift-egenskapen heter condition.'
    defs['Purpose']['properties']['goal']=ref('CellConfiguration')
    defs['Purpose'].setdefault('required',[]).append('goal')
    defs['Purpose']['description']='Node med label og relasjoner, i tillegg et påkrevd målbart mål. Samme Purpose brukes for egne og søkte formål. Dette er målinvarianten fra gjennomgangen; Swift tillater fortsatt nil. Skjemaet krever en konfigurasjon, men kan ikke bevise at den måler noe.'
    defs['Purpose']['x-haven']['status']='decided-target; runtime-goal-still-optional'
    props['purposes']['description']='Administreres av PerspectiveCell. Den lagrede rotens organisering og den typede bibliotekadapteren er fortsatt ikke ferdig kontraktfestet.'

    relations=props['relations'];relations['type']='object'
    forbid(relations,'people')
    relations['additionalProperties']={'type':'array','items':{}}
    relations['description']='Objekt med reserverte nøkler. Eierdefinerte relasjonsnavn kan inneholde lister; elementkontrakten for disse listene er ikke avgjort. records/<id>/entityRepresentation er den anbefalte typede kontaktbanen.'
    r=defs['EntityRelationRecord']
    forbid(r,'interests','purposeRefs','channels','standing','evidence')
    r['properties']['entityRepresentation']=ref('EntityRepresentation')
    r.setdefault('required',[]).append('entityRepresentation')
    r['properties']['schema']={'type':'string','description':'Målformen har ennå ingen vedtatt wire-versjon. Demoen bruker review-only:-prefiks. Må ikke sendes til dagens v1/v2-validator som om dette var samme kontrakt.'}
    r['description']='Metadata rundt kontaktens EntityRepresentation. Interest/Purpose bæres av grafen; kontaktkanaler ligger i person.contact.endpoints; bevis indekseres under proofs. Formålsoppfyllelse må måles, og er ikke bevist av kantvekten alene. Blokkering, invitasjoner og kilde/proveniens krever en bevart, eksplisitt kontrakt før migrering.'
    r['x-haven']={'status':'decided-target-with-open-migration','runtimeSource':'CellProtocol/Sources/CellBase/PersistingCells/EntityRelationRecordV1.swift'}
    for name in ['EntityRelationInterests','EntityRelationChannel','EntityRelationStanding','EntityRelationEvidence','EntityRelationTrust','EntityRelationEvidenceKind']:
        defs.pop(name,None)
    defs['EntityRelationSubject']['description']='Beholdt som mulig avledet sammendrag; skal vurderes ved bruk. Ikke en separat autoritativ kontaktprofil.'
    defs['EntityRelationInteractionSummary']['description']='Beholdt som mulig sammendrag; skal vurderes ved bruk.'
    defs['EntityRelationInteractionEvent']['description']='Eksisterende relasjonshendelse bevart som beskrevet underkontrakt. Interaction skal forstås generelt. Ny generell hendelseskontrakt og plassering er ikke avgjort; historiske schema-verdier er ikke omdøpt.'
    props['signedAgreementEntity']['properties']['records']=copy.deepcopy(props['signedAgreementEntity']['properties']['records']['oneOf'][0])
    props['signedAgreementEntity']['properties']['records']['description']='Liste, slik den er i dag. Dictionary-formen fra signedAgreementEntity.commit ble foreslått i gjennomgangen 16.09.2026, men eieren tok imot innvendingen samme dag og beholdt listen: posten er en revisjonskjede der rekkefølge må bevares, og et JSON-objekt har ingen rekkefølge. Dictionary-formen er utelatt fra målmodellen.'
    props['chronicle']=copy.deepcopy(props['chronicle']['oneOf'][0])
    props['chronicle']['description']='Ryddet til hendelsesliste i dette målutkastet. Den eldre tomme objektformen {} er tatt ut. Egen historikkcelle, plassering i annet scaffold og referanseform er fortsatt til vurdering.'
    presence=props['scaffoldPresence']
    presence['properties']['mounts']=presence['properties']['staging']['properties']['mounts']
    forbid(presence,'staging')
    presence['description']='Generell scaffoldPresence uten miljønavnet staging. Mounts og registry er fortsatt åpne underkontrakter.'
    presence['x-haven']={'status':'direction-decided; direct-mounts-layout-proposed','replaces':'scaffoldPresence.staging.mounts'}
    props['proofs']['properties']['index']['properties']['byKeypath']['description']='Indeks fra kanonisk lagret nøkkelsti til bevisreferanser. For relasjoner peker stien inn i records/<id>/entityRepresentation. Indeksen finner bevis; den fastslår verken sannhet, gyldighet eller samtykke.'
    props['identityLinks']['description']='Beskyttet kobling mellom identiteter, med records, approvals og brukte approval-JTI-er. Ingen implisitt likhet mellom identiteter basert på navn, e-post eller grafvekt. IdentityPublicKeyDescriptor i koden inneholder uuid, publicKey, algoritme og kurve. Koblingen fra kontaktens EntityRepresentation til Entity og observerte Identity-er må kontraktfestes; de åpne kartene her er ikke en implementasjon av sikker ekvivalenskontroll.'
    return s

def endpoint_data(contact):
    contact=copy.deepcopy(contact)
    contact.pop('email',None);contact.pop('phone',None)
    for i,e in enumerate(contact.get('endpoints',[])):
        if not isinstance(e,dict):continue
        if 'endpointCell' in e:e['cellReference']=e.pop('endpointCell')
        e.setdefault('label','primary' if i==0 else 'work')
    for i,p in enumerate(contact.get('phones',[])):
        if i==0:p['label']='primary'
    return contact

def transform_data(data):
    """Transform fictional examples only; never use this as a migration tool."""
    d=copy.deepcopy(data)
    if 'person' in d:
        p=d['person']
        if 'conference' in p:d['conference']=p.pop('conference')
        if 'contact' in p:p['contact']=endpoint_data(p['contact'])
        prefs=p.get('preferences',{})
        prefs.get('communication',{}).pop('preferredChannel',None)
        if 'privacy' in prefs:prefs['privacy']['defaultVisibility']='private'
    relations=d.get('relations',{})
    if isinstance(relations,dict):
        relations.pop('people',None)
        for rid,r in relations.get('records',{}).items():
            channels=r.pop('channels',[])
            for field in ['interests','purposeRefs','standing','evidence']:r.pop(field,None)
            r['schema']='review-only:entity-relation-record:2026-09-16'
            node=r.get('entityRepresentation')
            if node:
                person=node.setdefault('person',{})
                person.setdefault('displayName',r.get('subject',{}).get('displayName',node['name']))
                if channels:
                    person['contact']={'endpoints':[{'endpointId':c['ref'],'cellReference':f'cell:///DemoContact/{rid}/{i+1}','label':'primary' if i==0 else 'work','purposes':['purpose://contact.communication','purpose://contact.introduction']} for i,c in enumerate(channels)]}
    if isinstance(d.get('scaffoldPresence'),dict):
        staging=d['scaffoldPresence'].pop('staging',{})
        if 'mounts' in staging:d['scaffoldPresence']['mounts']=staging['mounts']
    def visit(v):
        if isinstance(v,dict):
            if 'nodeIdentifier' in v and 'person' in v and isinstance(v['person'],dict) and 'contact' in v['person']:
                v['person']['contact']=endpoint_data(v['person']['contact'])
            # Small historical example omitted goal; supply clearly fictional data.
            if 'nodeIdentifier' in v and 'description' in v and 'helperCells' in v:
                v.setdefault('goal',{'name':'DemoMaalKontroll','description':'Fiktiv målkonfigurasjon; måleligheten er ikke validert her.'})
            for x in v.values():visit(x)
        elif isinstance(v,list):
            for x in v:visit(x)
    visit(d)
    return d

def decisions():
    text=REVIEW.read_text();section='';rows=[]
    for part in re.split(r'(?m)^(## .+|### .+)\n',text):
        if part.startswith('## '):section=part.strip()[3:]
        elif part.startswith('### '):rows.append({'path':part.strip()[4:].strip('`'),'section':section})
        elif rows and part.strip() and 'quote' not in rows[-1]:rows[-1]['quote']=part.strip()
    for row in rows:
        p=row['path'];section=row['section']
        row['status']='open-question' if section.startswith('Til vurdering') else 'documented-meaning' if section.startswith('Presiseringer') else 'applied-to-target'
        if p=='person.contact.endpoints[].endpointCell':row['status']='proposed-name; endpoint-shape-open'
        if p=='scaffoldPresence.staging':row['status']='generic-presence-direction-decided; direct-mounts-layout-proposed'
        if p=='relations.people[].ownerUUID':row['status']='removed-with-people; identity-contract-and-migration-open'
        if p in ['/EntityRelationStanding','/EntityRelationEvidence','/EntityRelationInterests','/EntityRelationChannel']:
            row['status']='removed-from-target; replacement-direction-documented; migration-open'
        if p=='/Purpose':row['status']='required-goal-in-target; runtime-still-optional'
        if p=='/CellConfiguration':row['status']='documented; partial-schema-retained'
        if p=='/chronicle':row['status']='legacy-empty-object-removed; storage-placement-open'
    return rows

def main():
    base=json.loads(BASE.read_text());s=target_schema(base)
    Draft202012Validator.check_schema(s)
    data=transform_data(json.loads((OUT/'EntityData.example.json').read_text()))
    v=Draft202012Validator(s,format_checker=FormatChecker())
    v.validate(data)
    schema_graph={'$schema':s['$schema'],'$id':'urn:haven:entity-representation:review-decisions:2026-09-16',
      'title':'EntityRepresentation – målmodell etter gjennomgangen','$ref':'#/$defs/EntityRepresentation','$defs':s['$defs'],'x-haven':s['x-haven']}
    manifest={'status':'decision-target-draft','updatedAt':'2026-09-17','decisionsAsOf':'2026-09-16','schema':TARGET,
      'graphSchema':'EntityRepresentation.v2.schema.json','example':'EntityData.v2.example.json',
      'documentation':'OPPDATERT-ETTER-GJENNOMGANG-2026-09-16.md','decisions':'review-decisions-2026-09-16.json',
      'runtimeBaseline':BASE.name,'runtimeUpdated':False,'dataMigrated':False,'published':False}
    for name,value in [(TARGET,s),(manifest['graphSchema'],schema_graph),(manifest['example'],data),('review-decisions-2026-09-16.json',{'source':REVIEW.name,'sourceSHA256':hashlib.sha256(REVIEW.read_bytes()).hexdigest(),'comments':decisions()}),('current-review.json',manifest)]:
        (OUT/name).write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
    print(f'Wrote {TARGET}; {len(decisions())} review entries; example valid.')

if __name__=='__main__':main()
