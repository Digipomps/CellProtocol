#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Bygger EntityData.v2.schema.json ved å anvende Kjetils beslutninger fra 16.09
på gjennomgangsskjemaet. Hver endring asserter at målet finnes — bommer den,
stopper den høylytt i stedet for å gå videre stille."""

import json, copy, sys

SRC = "/mnt/user-data/uploads/HAVEN/CellProtocol/Docs/EntityData-Review-2026-09-11/EntityData.review.schema.json"
OUT = "/home/claude/EntityData.v2.schema.json"

d = json.load(open(SRC, encoding="utf-8"))
endringer = []

def P(*path):
    """Naviger til en node. Kaster hvis den ikke finnes."""
    n = d
    for k in path:
        assert k in n, "FANT IKKE: " + " / ".join(map(str, path))
        n = n[k]
    return n

def slett(container, key, hvorfor):
    assert key in container, "FANT IKKE for sletting: " + key
    container.pop(key)
    endringer.append(("slettet", key, hvorfor))

def merk(node, beslutning):
    node.setdefault("x-haven", {})["decision"] = "kjetil-2026-09-16"
    node["x-haven"]["decisionNote"] = beslutning

# ---------------------------------------------------------------- toppnivå
d["$id"] = "urn:haven:entity-data:v2-decided:2026-09-16"
d["title"] = "EntityData v2 — besluttet form (ikke implementert i kode)"
d["description"] = (
    "Strukturen slik Kjetil besluttet den 16.09.2026, element for element, i gjennomgangen av "
    "alle 253 elementene i v1-gjennomgangsskjemaet. Dette er den VEDTATTE formen, men den er "
    "IKKE implementert i CellProtocol ennå — koden bygger fortsatt v1. Bruk den som mål å bygge "
    "mot, ikke som beskrivelse av hva som ligger i lagringen i dag. Beslutningsreferat: "
    "Docs/EntityData-Review-2026-09-11/GJENNOMGANG_KJETIL_2026-09-16.md. "
    "Åpne punkter er listet i x-haven.openQuestions nederst."
)

person  = P("properties", "person", "properties")
contact = person["contact"]["properties"] if "properties" in person.get("contact", {}) else None
assert contact is not None, "fant ikke person.contact.properties"

# ------------------------------------------- 1. kontakt: endpoints for alt
for k in ("email", "phone", "emails", "phones"):
    slett(contact, k,
          "Enkeltfelt og typedelte lister utgår. Endpoints er formen for alt: telefon, "
          "e-post, SoMe-nick, URL, cellereferanse. Flere av samme type skilles med label.")

ep = contact["endpoints"]
merk(ep, "Endpoints er nå den eneste kontaktformen i EntityData.")
ep["description"] = (
    "Eierkontrollerte kontaktpunkter. Etter beslutningen 16.09 er dette den ENESTE formen for "
    "kontaktopplysninger: telefon, e-post, SoMe-nick, URL og cellereferanse uttrykkes alle her. "
    "Flere av samme slag skilles med label, f.eks. label=\"primary\"."
)
ep.setdefault("items", {})
ep["items"].setdefault("type", "object")
ep["items"].setdefault("properties", {})
ep["items"]["properties"].update({
    "endpointId": {"type": "string", "description": "Ugjennomsiktig id for kontaktpunktet."},
    "kind": {
        "type": "string",
        "enum": ["phone", "email", "some", "url", "cellReference"],
        "description": "Hva slags kontaktvei dette er. Erstatter de tidligere typedelte listene.",
    },
    "label": {
        "type": "string",
        "description": "Eierlokal etikett, f.eks. primary, work, personal. Skiller flere av samme kind.",
    },
    "value": {
        "type": "string",
        "description": "Selve verdien for kind phone/email/some/url. Tom for cellReference.",
    },
    "endpointCell": {
        "type": "string",
        "description": (
            "Cellen som kan ta imot en signert, formålsbundet forespørsel. "
            "ÅPENT: Kjetil vurderte 16.09 å døpe dette om til cellReference — ikke avgjort."
        ),
    },
    "purposes": {"type": "array", "items": {"type": "string"},
                 "description": "Formål kontaktpunktet aksepterer henvendelser for."},
    "status": {"type": "string",
               "description": "Eierlokal status: unverified, verified, retired. Eierens egen bokføring — bevis hører i proofs."},
})
endringer.append(("utvidet", "person.contact.endpoints[]", "kind, label, value, status lagt til"))

merk(contact["preferredChannel"], "Beholdt. Dubletten under preferences.communication utgår.")

# --------------------------------------- 2. preferanser: dublett og default
komm = person["preferences"]["properties"]["communication"]["properties"]
slett(komm, "preferredChannel",
      "Dublett. person.contact.preferredChannel er den som gjelder.")

vis = person["preferences"]["properties"]["privacy"]["properties"]["defaultVisibility"]
vis["default"] = "private"
merk(vis, "Default er private.")
endringer.append(("default satt", "person.preferences.privacy.defaultVisibility", "private"))

# ------------------------------------------- 3. conference ut av person
konf = person.pop("conference")
merk(konf, "Flyttet ut av person til egen rot. Domeneskiver hører ikke under person.")
d["properties"]["conference"] = konf
endringer.append(("flyttet", "person.conference -> conference", "egen rot"))

# ------------------------------------------- 4. relations som object
rel = P("properties", "relations")
rel.pop("type", None)
rel["type"] = "object"
relp = rel["properties"]
slett(relp, "people",
      "Den eldre listeformen vikes for relations.records med entityRepresentation.")

rel["description"] = (
    "Eierens relasjoner. Etter beslutningen 16.09 er dette et object med RESERVERTE nøkler "
    "(records, identities, entities, contactEndpoints, issuers, chatInvites, "
    "workspaceInvites, workspaceMemberships), og eieren kan i tillegg legge til egne "
    "navngitte lister ved siden av dem — f.eks. relations.venner."
)
rel["additionalProperties"] = {
    "type": "array",
    "description": (
        "Egendefinert navngitt relasjonsliste laget av eieren, f.eks. venner eller kolleger. "
        "Elementene er referanser til relationID i relations.records — ikke kopier av posten."
    ),
    "items": {"type": "string"},
}
merk(rel, "Object med reserverte nøkler pluss egendefinerte navngitte lister.")
endringer.append(("omformet", "relations", "object med reserverte nøkler + egne navngitte lister"))

merk(relp["records"], "Den gjeldende relasjonsformen. Erstatter relations.people[].")

# ------------------------------------------- 5. $defs: EntityRelationRecord
defs = d["$defs"]
rec = defs["EntityRelationRecord"]["properties"]
for k, hvorfor in [
    ("interests", "Erstattes av Interest/Purpose-noder i entityRepresentation-grafen."),
    ("purposeRefs", "Erstattes av grafen."),
    ("channels", "Erstattes av endpoints i entityRepresentation."),
    ("standing", "Status og tillit måles i om relasjonens uttalte formål er oppfylt (vektet), ikke som eget felt."),
    ("evidence", "Erstattes av proofs med keypaths, som for egne bevis."),
]:
    if k in rec:
        slett(rec, k, hvorfor)

for t, hvorfor in [
    ("EntityRelationInterests", "Erstattet av Interest/Purpose."),
    ("EntityRelationChannel", "Erstattet av endpoints i EntityRepresentation."),
    ("EntityRelationStanding", "Erstattet av vektet formålsoppfyllelse."),
    ("EntityRelationEvidence", "Erstattet av proofs med keypaths."),
]:
    if t in defs:
        slett(defs, t, hvorfor)

# ------------------------------------------- 6. signedAgreementEntity: liste
sae = P("properties", "signedAgreementEntity")
merk(sae, "records forblir en LISTE. Dictionary-formen ble vurdert og forkastet: et JSON-objekt "
          "har ingen rekkefølge, og posten er en revisjonskjede der rekkefølgen må bevares.")

# ------------------------------------------- 7. chronicle
chron = P("properties", "chronicle")
chron["type"] = "array"
merk(chron, "Liste. Legacy-initialiseringen med tomt objekt ryddes — den var en feil, ikke en form.")
endringer.append(("strammet", "chronicle", "kun array; tomt objekt ikke lenger tillatt"))

# ------------------------------------------- 8. scaffoldPresence
sp = P("properties", "scaffoldPresence")
spp = sp["properties"]
if "staging" in spp:
    slett(spp, "staging",
          "For spesifikk for utviklingsmiljøet. Erstattes av en generell form uten miljønavn.")
spp["presences"] = {
    "type": "object",
    "description": (
        "Tilstedeværelser nøklet på scaffold-id, ikke på miljønavn. Hver oppføring beskriver "
        "materialiserte nøkkelstiprefikser og eventuelle eksterne mounts. Ikke bevis på aktiv forbindelse."
    ),
    "additionalProperties": {
        "type": "object",
        "properties": {
            "mounts": {"type": "array", "items": {"type": "string"},
                       "description": "Eksterne nøkkelsti-mounts et annet scaffold kan resolve."},
            "observedAt": {"type": "string", "description": "Når tilstedeværelsen sist ble registrert."},
        },
    },
}
merk(sp, "Generell form: presences nøklet på scaffold, ikke scaffoldPresence.staging.")
endringer.append(("omformet", "scaffoldPresence", "presences per scaffold i stedet for staging"))

# ------------------------------------------- 9. åpne punkter
d["x-haven"] = d.get("x-haven", {})
d["x-haven"]["decidedAt"] = "2026-09-16"
d["x-haven"]["implementedInCode"] = False
d["x-haven"]["openQuestions"] = [
    "organization som egen rot for organisasjonsentiteter — Kjetil ba 16.09 om at det vurderes, ikke avgjort.",
    "endpointCell omdøpes til cellReference — vurdert, ikke avgjort.",
    "Skal skills være annonserte formål brukeren hevder å kunne løse, i stedet for egne poster?",
    "Skal person.work bli et array med referanser til arbeidsorganisasjoner?",
    "Toveis binding: array som lister hvilke relasjoner personen er medlem av. Krever grundig vurdering — "
    "avgjør om relasjonsgrafen har én eier av sannheten eller to som kan gå fra hverandre.",
    "Skal sensitive merkelapper kunne lagres i entityRepresentation, altså i det én bruker lagrer om en annen?",
    "Bør chronicle peke til en egen celle, eventuelt i et annet scaffold, siden den kan vokse seg stor?",
    "Hvordan avgjøres det sikkert og utvetydig at to identiteter representerer samme entitet?",
]

json.dump(d, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
open(OUT, "a").write("\n")

print("skrevet:", OUT)
print("endringer anvendt:", len(endringer))
for hva, hvor, hvorfor in endringer:
    print(f"  {hva:14} {hvor}")
print()
print("røtter i v2:", list(d["properties"].keys()))
print("$defs igjen:", len(d["$defs"]))

# ============================================================== ETTERARBEID
# Funnet av validatoren: å slette en property er ikke nok når den står i
# required, når en const er versjonspinnet, eller når erstatningen mangler.

rec_def = d["$defs"]["EntityRelationRecord"]
fjernet_fra_required = [k for k in ("interests", "purposeRefs", "channels", "standing", "evidence")
                        if k in rec_def.get("required", [])]
rec_def["required"] = [k for k in rec_def["required"] if k not in fjernet_fra_required]
if "entityRepresentation" not in rec_def["required"]:
    rec_def["required"].append("entityRepresentation")
endringer.append(("required ryddet", "EntityRelationRecord",
                  "fjernet " + ", ".join(fjernet_fra_required) + "; entityRepresentation er nå påkrevet"))

rec_def["properties"]["schema"]["const"] = "haven.entity-relation-record.v2"
endringer.append(("versjon", "EntityRelationRecord.schema", "v1 -> v2, formen er endret"))

isum = d["$defs"]["EntityRelationInteractionSummary"]
if "byChannel" in isum.get("required", []):
    isum["required"] = [k for k in isum["required"] if k != "byChannel"]
    isum["properties"].pop("byChannel", None)
    endringer.append(("slettet", "EntityRelationInteractionSummary.byChannel",
                      "Kanaler finnes ikke lenger som egen type."))

er_def = d["$defs"]["EntityRepresentation"]
er_def["properties"]["endpoints"] = {
    "type": "array",
    "description": (
        "Kontaktpunkter for entiteten denne representasjonen beskriver. Samme form som "
        "person.contact.endpoints. Erstatter den tidligere EntityRelationChannel-typen."
    ),
    "items": {"$ref": "#/properties/person/properties/contact/properties/endpoints/items"},
}
endringer.append(("lagt til", "EntityRepresentation.endpoints",
                  "erstatter EntityRelationChannel, samme form som person.contact.endpoints"))

json.dump(d, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
open(OUT, "a").write("\n")
print()
print("etterarbeid anvendt. totalt", len(endringer), "endringer.")

# ============================================ ETTERARBEID 2 (validatorfunn)
# a) endpoints modelleres én gang som delt type, ikke som kryssreferanse inn
#    i properties — den brøt når $defs ble brukt frittstående.
ep_items = d["properties"]["person"]["properties"]["contact"]["properties"]["endpoints"]["items"]
d["$defs"]["ContactEndpoint"] = dict(ep_items)
d["$defs"]["ContactEndpoint"]["description"] = (
    "Ett kontaktpunkt. Etter 16.09 er dette den delte formen for all kontakt, både eierens egne "
    "(person.contact.endpoints) og det eieren vet om andre (EntityRepresentation.endpoints)."
)
d["properties"]["person"]["properties"]["contact"]["properties"]["endpoints"]["items"] = \
    {"$ref": "#/$defs/ContactEndpoint"}
d["$defs"]["EntityRepresentation"]["properties"]["endpoints"]["items"] = \
    {"$ref": "#/$defs/ContactEndpoint"}
endringer.append(("delt type", "$defs.ContactEndpoint",
                  "endpoints defineres én gang og brukes både av person og EntityRepresentation"))

# b) Kjetil 16.09: «Purpose ... har den et målbart mål, som er påkrevet.»
#    Det var ikke reflektert — goal var valgfri og nullbar.
pur = d["$defs"]["Purpose"]
pur["properties"]["goal"] = {
    "$ref": "#/$defs/CellConfiguration",
    "description": (
        "Det målbare målet. PÅKREVET etter beslutningen 16.09: det er dette som skiller Purpose "
        "fra Interest — Purpose er den utførende delen av en Interest. Merk at dagens Swift-type "
        "har goal som valgfri og nullbar; kravet er besluttet, ikke implementert."
    ),
}
if "goal" not in pur["required"]:
    pur["required"].append("goal")
merk(pur, "goal er påkrevet. Purpose er den utførende delen av en Interest.")
endringer.append(("påkrevet", "Purpose.goal",
                  "Kjetil 16.09: et målbart mål er påkrevet — skiller Purpose fra Interest"))

json.dump(d, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
open(OUT, "a").write("\n")
print("etterarbeid 2 anvendt. totalt", len(endringer), "endringer.")
