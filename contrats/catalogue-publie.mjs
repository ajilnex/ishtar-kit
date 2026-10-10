// Contrat — le « Catalogue publié », v1 (catalogue.json). Écrit par Ishtar
// (`ishtar publish`, CatalogPublisher.swift) et par le Bibliothécaire (fonds
// « Papiers d'Athanor », fonds-athanor.mjs) ; lu par Rayons et le
// Bibliothécaire. Texte : catalogue-publie.md. Audit du 03/10, D9.
//
// Sans dépendance, pur : `erreursCatalogue(json)` rend la liste des écarts
// (vide : conforme). Ce fichier est COPIÉ À L'IDENTIQUE dans les tests des
// dépôts qui produisent ou lisent le format (Rayons, Bibliothécaire) ;
// `node audit/contrats.mjs` vérifie que les copies n'ont pas divergé.
//
//   node contrats/catalogue-publie.mjs "<Catalogue publié>/catalogue.json"

export const VERSION = 1

const SHA256 = /^[0-9a-f]{64}$/
const CLE = /^[\w.-]{1,120}$/
const DATE_ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/
const GENRES = ['livre', 'article', 'manuscrit']
const STATUTS = ['recognized', 'needsReview', 'duplicateCandidate', 'ignored']
const CONFIANCES = ['high', 'probable', 'low']

const chaine = v => typeof v === 'string' && v.length > 0
const chaineOuAbsente = v => v === undefined || v === null || typeof v === 'string'

/// Les écarts d'un catalogue au contrat v1, au plus `limite` (vide : conforme).
export function erreursCatalogue(c, { limite = 50 } = {}) {
  const e = []
  const ecart = m => { if (e.length < limite) e.push(m) }
  if (!c || typeof c !== 'object' || Array.isArray(c)) return ['le catalogue doit être un objet JSON']
  if (c.version !== VERSION) ecart(`version : ${JSON.stringify(c.version)} au lieu de ${VERSION}`)
  if (!chaine(c.generatedAt) || !DATE_ISO.test(c.generatedAt)) ecart('generatedAt : date ISO 8601 attendue')
  if (!chaine(c.library)) ecart('library : chaîne attendue')
  if (c.fonds !== undefined && c.fonds !== null && !(chaine(c.fonds.id) && chaine(c.fonds.nom))) ecart('fonds : { id, nom } attendu')
  if (!Array.isArray(c.editions)) return [...e, 'editions : tableau attendu']

  // Deux éditions peuvent partager un fichier (les articles d'un même numéro de revue).
  const idsCollections = new Set()
  if (c.collections != null) {
    if (!Array.isArray(c.collections)) ecart('collections : tableau attendu')
    else for (const col of c.collections) {
      if (!col || !chaine(col.id) || !chaine(col.name)) ecart('collections : { id, name, parentId? } attendu')
      else if (idsCollections.has(col.id)) ecart('collections : identifiant en double')
      else idsCollections.add(col.id)
    }
  }
  const cles = new Set()
  const anciennes = []
  c.editions.forEach((ed, i) => {
    const ou = `editions[${i}]${ed?.key ? ` (${ed.key})` : ''}`
    if (!ed || typeof ed !== 'object') return ecart(`${ou} : objet attendu`)
    if (!chaine(ed.key) || !CLE.test(ed.key)) ecart(`${ou}.key : clé attendue (${CLE})`)
    else if (cles.has(ed.key)) ecart(`${ou}.key : en double dans le catalogue`)
    else cles.add(ed.key)
    if (!chaine(ed.work)) ecart(`${ou}.work : identifiant d'œuvre attendu`)
    // Les anciennes clés (pierres tombales, 04/10) : elles mènent encore à cette édition.
    if (ed.formerKeys !== undefined && ed.formerKeys !== null) {
      if (!Array.isArray(ed.formerKeys) || !ed.formerKeys.every(k => chaine(k) && CLE.test(k))) ecart(`${ou}.formerKeys : tableau de clés attendu (${CLE})`)
      else for (const k of ed.formerKeys) anciennes.push([k, ou])
    }
    if (!chaine(ed.title)) ecart(`${ou}.title : chaîne attendue`)
    for (const k of ['subtitle', 'publisher', 'language', 'isbn13', 'doi', 'discipline', 'source']) {
      if (!chaineOuAbsente(ed[k])) ecart(`${ou}.${k} : chaîne ou absent`)
    }
    if (!Array.isArray(ed.authors) || !ed.authors.every(a => typeof a === 'string')) ecart(`${ou}.authors : tableau de chaînes attendu`)
    if (ed.people !== undefined && ed.people !== null) {
      if (!Array.isArray(ed.people) || !ed.people.every(p => p && chaine(p.name))) ecart(`${ou}.people : [{ name, sortName?, idref?, bnf?, wikidata? }] attendu`)
    }
    if (ed.kind !== undefined && ed.kind !== null && !GENRES.includes(ed.kind)) ecart(`${ou}.kind : l'un de ${GENRES.join(', ')}`)
    // L'année est une chaîne : « 1951 », « -400 » (avant notre ère), « ND » de préférence.
    for (const k of ['year', 'editionYear']) if (!chaineOuAbsente(ed[k])) ecart(`${ou}.${k} : chaîne ou absent`)
    if (!Array.isArray(ed.collections) || !ed.collections.every(x => typeof x === 'string')) ecart(`${ou}.collections : tableau de chaînes attendu`)
    if (ed.collectionIds != null && (!Array.isArray(ed.collectionIds) || !ed.collectionIds.every(id => idsCollections.has(id)))) ecart(`${ou}.collectionIds : identifiants de collections déclarées attendus`)
    if (!STATUTS.includes(ed.status)) ecart(`${ou}.status : l'un de ${STATUTS.join(', ')}`)
    if (!CONFIANCES.includes(ed.confidence)) ecart(`${ou}.confidence : l'un de ${CONFIANCES.join(', ')}`)
    if (!chaine(ed.dateAdded) || !DATE_ISO.test(ed.dateAdded)) ecart(`${ou}.dateAdded : date ISO 8601 attendue`)
    if (!Array.isArray(ed.files) || ed.files.length === 0) return ecart(`${ou}.files : au moins un fichier`)
    ed.files.forEach((f, j) => {
      const ici = `${ou}.files[${j}]`
      if (!f || typeof f !== 'object') return ecart(`${ici} : objet attendu`)
      if (!SHA256.test(f.sha256 ?? '')) ecart(`${ici}.sha256 : empreinte SHA-256 en hexadécimal minuscule`)
      if (!chaine(f.path) || f.path.startsWith('/') || f.path.split('/').includes('..')) ecart(`${ici}.path : chemin relatif à la bibliothèque, sans « .. »`)
      for (const k of ['label', 'note']) if (!chaineOuAbsente(f[k])) ecart(`${ici}.${k} : chaîne ou absent`)
      if (f.preferred != null && typeof f.preferred !== 'boolean') ecart(`${ici}.preferred : booléen ou absent`)
      if (!chaine(f.format)) ecart(`${ici}.format : chaîne attendue`)
      if (!Number.isInteger(f.size) || f.size < 0) ecart(`${ici}.size : entier positif`)
    })
  })
  // Une ancienne clé ne désigne qu'une édition, et jamais une clé d'aujourd'hui.
  const vues = new Set()
  for (const [k, ou] of anciennes) {
    if (cles.has(k)) ecart(`${ou}.formerKeys : « ${k} » est aussi la clé d'une édition`)
    else if (vues.has(k.toLowerCase())) ecart(`${ou}.formerKeys : « ${k} » mène à deux éditions`)
    vues.add(k.toLowerCase())
  }
  return e
}

// En ligne de commande : vérifier un vrai catalogue. Le script se reconnaît
// par son vrai chemin, pas par son adresse file:// : un chemin accentué
// (« Silicône ») y est encodé, et la comparaison échouait en silence, code 0
// sans rien vérifier (03/10 ; test : contrats/test/contrats.test.mjs).
const lanceDirectement = async () => {
  const { realpathSync } = await import('node:fs')
  const { fileURLToPath } = await import('node:url')
  try { return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1] ?? '') } catch { return false }
}
if (await lanceDirectement()) {
  const { readFileSync } = await import('node:fs')
  const fichier = process.argv[2]
  if (!fichier) { console.error('usage : node catalogue-publie.mjs <catalogue.json>'); process.exit(2) }
  const c = JSON.parse(readFileSync(fichier, 'utf8'))
  const e = erreursCatalogue(c, { limite: 200 })
  console.log(e.length ? `✗ ${e.length} écart(s) au contrat v1 :\n  ${e.join('\n  ')}` : `✓ conforme au contrat v1 (${c.editions.length} éditions)`)
  process.exit(e.length ? 1 : 0)
}
