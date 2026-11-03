#!/usr/bin/env python3
"""Read-only tools over the Ituri surveillance tables exported from the R pipeline.

Standard library only, no network access. Every command prints one JSON object. Rule-based
indicators are read from the export, never recomputed here; this file only filters and sums.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import difflib
import hashlib
import json
import os
import re
import sys
import unicodedata
from pathlib import Path
from typing import Any

RACINE = Path(__file__).resolve().parents[4]
MAX_LIGNES = 500
BASE_MIN_VARIATION = 10  # Same threshold as the dashboard's change column.
MALADIES_PALU_CONF = {"PALUDISME CONF"}


class Erreur(Exception):
    """A request the agent can correct: returned as JSON with exit code 2."""


def normaliser(texte: str) -> str:
    sans_accent = unicodedata.normalize("NFKD", texte)
    sans_accent = "".join(c for c in sans_accent if not unicodedata.combining(c))
    return re.sub(r"\s+", " ", sans_accent).strip().casefold()


def nombre(valeur: str) -> float | None:
    return None if valeur == "" else float(valeur)


def entier(valeur: str) -> int | None:
    return None if valeur == "" else int(float(valeur))


class Donnees:
    def __init__(self, dossier: Path) -> None:
        self.dossier = dossier
        chemin = dossier / "catalogue.json"
        if not chemin.is_file():
            raise Erreur(f"Export introuvable dans {dossier}. Lancer export/exporter.R.")
        self.catalogue = json.loads(chemin.read_text(encoding="utf-8"))
        # Real data needs written agreement from MSF and the DPS: there is deliberately no override.
        if self.catalogue.get("synthetique") is not True:
            raise Erreur("Refus : cet outil n'accepte que des données synthétiques.")
        self.semaine_max = int(self.catalogue["semaine_max"])
        self.origine = dt.date.fromisoformat(self.catalogue["origine_semaine1"])
        self.zones = {z["code"]: z for z in self.catalogue["zones"]}
        self.maladies = {m["code"]: m for m in self.catalogue["maladies"]}
        self.pop_totale = sum(z["population"] for z in self.zones.values())
        self._tables: dict[str, list[dict[str, str]]] = {}

    def table(self, nom: str) -> list[dict[str, str]]:
        if nom not in self._tables:
            with (self.dossier / f"{nom}.csv").open(encoding="utf-8", newline="") as flux:
                self._tables[nom] = list(csv.DictReader(flux))
        return self._tables[nom]

    @property
    def source(self) -> dict[str, Any]:
        s = self.catalogue["source"]
        return {"fichier": s["fichier"], "sha256": s["sha256"], "synthetique": True}

    def date(self, semaine: int) -> str:
        return (self.origine + dt.timedelta(days=7 * (semaine - 1))).isoformat()

    def trouver(self, valeur: str, table: dict[str, dict[str, Any]], genre: str) -> str:
        cible = normaliser(valeur)
        noms = {normaliser(code): code for code in table}
        noms.update({normaliser(item["nom"]): code for code, item in table.items()})
        if cible in noms:
            return noms[cible]
        proches = [noms[c] for c in noms if cible and cible in c]
        proches += [noms[c] for c in difflib.get_close_matches(cible, list(noms), n=3, cutoff=0.6)]
        uniques = list(dict.fromkeys(proches))[:6]
        aide = f" Codes proches : {', '.join(uniques)}." if uniques else " Voir la commande catalogue."
        raise Erreur(f"{genre} inconnue : {valeur!r}.{aide}")

    def maladie(self, valeur: str) -> str:
        return self.trouver(valeur, self.maladies, "Maladie")

    def zone(self, valeur: str) -> str:
        return self.trouver(valeur, self.zones, "Zone")

    def semaine(self, valeur: int | None, nom: str = "semaine") -> int:
        if valeur is None:
            return self.semaine_max
        if not 1 <= valeur <= self.semaine_max:
            raise Erreur(f"{nom} {valeur} hors limites : les données couvrent S1 à S{self.semaine_max}.")
        return valeur

    def periode(self, de: int | None, a: int | None) -> tuple[int, int]:
        debut, fin = self.semaine(de if de is not None else 1, "de"), self.semaine(a, "a")
        if debut > fin:
            raise Erreur(f"Période invalide : S{debut} est après S{fin}.")
        return debut, fin

    def zones_ayant_rapporte(self, semaine: int) -> set[str]:
        return {
            l["zs"]
            for l in self.table("rapportage")
            if int(l["semaine_ref"]) == semaine and l["a_rapporte"] == "TRUE"
        }

    def ruptures(self, semaine: int) -> dict[str, int]:
        """Zones with a malaria confirmation break, as known at this week (dashboard rule)."""
        return {
            l["zs"]: int(float(l["debut_rupture"]))
            for l in self.table("ruptures")
            if int(l["semaine_ref"]) == semaine and l["debut_rupture"] != ""
        }


def repere_rupture(d: Donnees, maladie: str, semaine: int, zones: list[str] | None) -> list[str]:
    if maladie not in MALADIES_PALU_CONF:
        return []
    ruptures = d.ruptures(semaine)
    if zones is not None:
        ruptures = {z: s for z, s in ruptures.items() if z in zones}
    if not ruptures:
        return []
    detail = ", ".join(f"{d.zones[z]['nom']} (S{s})" for z, s in sorted(ruptures.items(), key=lambda x: x[1]))
    return [
        "Confirmation du paludisme interrompue, début entre parenthèses : "
        f"{detail}. Les cas confirmés y mesurent le dépistage ou la déclaration, pas la maladie."
    ]


def repere_semaine_partielle(d: Donnees, a_rapporte: dict[int, int]) -> list[str]:
    total = len(d.zones)
    partielles = [f"S{s} ({n}/{total})" for s, n in sorted(a_rapporte.items()) if n < total]
    if not partielles:
        return []
    return [
        "Totaux provinciaux partiels, zones ayant rapporté entre parenthèses : "
        f"{', '.join(partielles)}. Ne pas comparer ces totaux bruts entre semaines."
    ]


def serie(d: Donnees, a: argparse.Namespace) -> dict[str, Any]:
    maladie = d.maladie(a.maladie)
    debut, fin = d.periode(a.de, a.a)
    zones = [d.zone(z) for z in a.zone] if a.zone else None
    obs = [l for l in d.table("observations") if l["maladie"] == maladie and debut <= int(l["semaine"]) <= fin]
    lignes: list[dict[str, Any]] = []
    avertissements: list[str] = []

    if zones is None:
        rapporte = {s: len(d.zones_ayant_rapporte(s)) for s in range(debut, fin + 1)}
        for s in range(debut, fin + 1):
            ici = [l for l in obs if int(l["semaine"]) == s]
            cas = sum(float(l["cas"]) for l in ici)
            lignes.append({
                "territoire": "Province", "semaine": s, "date": d.date(s), "cas": cas,
                "deces": sum(float(l["deces"]) for l in ici),
                "taux_100k": cas / d.pop_totale * 1e5,
                "zones_rapportees": rapporte[s], "zones_avec_ligne": len(ici),
            })
        avertissements += repere_semaine_partielle(d, rapporte)
    else:
        index = {(l["zs"], int(l["semaine"])): l for l in obs}
        for z in zones:
            for s in range(debut, fin + 1):
                ligne = index.get((z, s))
                base = {"territoire": d.zones[z]["nom"], "code_zone": z, "semaine": s, "date": d.date(s)}
                if ligne:
                    cas = float(ligne["cas"])
                    lignes.append({**base, "cas": cas, "deces": float(ligne["deces"]),
                                   "taux_100k": cas / d.zones[z]["population"] * 1e5, "statut": "ligne_presente"})
                else:
                    statut = "zone_a_rapporte_sans_cette_maladie" if z in d.zones_ayant_rapporte(s) else "zone_n_a_pas_rapporte"
                    lignes.append({**base, "cas": None, "deces": None, "taux_100k": None, "statut": statut})
        if any(l["cas"] is None for l in lignes):
            avertissements.append("Valeur nulle = aucune ligne dans la base, ce qui n'est pas un zéro confirmé.")
    avertissements += repere_rupture(d, maladie, fin, zones)
    return reponse(d, "serie", {"maladie": maladie, "zones": zones or "province", "de": debut, "a": fin}, lignes, avertissements)


def classement(d: Donnees, a: argparse.Namespace) -> dict[str, Any]:
    maladie = d.maladie(a.maladie)
    debut, fin = d.periode(a.de, a.a)
    if not 1 <= a.top <= len(d.zones):
        raise Erreur(f"top doit être entre 1 et {len(d.zones)}.")
    cumul: dict[str, dict[str, float]] = {}
    for l in d.table("observations"):
        if l["maladie"] == maladie and debut <= int(l["semaine"]) <= fin:
            c = cumul.setdefault(l["zs"], {"cas": 0.0, "deces": 0.0})
            c["cas"] += float(l["cas"])
            c["deces"] += float(l["deces"])
    n_semaines = fin - debut + 1
    presence = {z: 0 for z in d.zones}
    for s in range(debut, fin + 1):
        for z in d.zones_ayant_rapporte(s):
            presence[z] += 1
    lignes = [
        {"zone": d.zones[z]["nom"], "code_zone": z, "cas": v["cas"], "deces": v["deces"],
         "taux_100k": v["cas"] / d.zones[z]["population"] * 1e5,
         "semaines_rapportees": presence[z], "semaines_periode": n_semaines}
        for z, v in cumul.items() if v["cas"] > 0
    ]
    cle = "taux_100k" if a.mesure == "taux" else "cas"
    lignes.sort(key=lambda l: (-l[cle], l["code_zone"]))
    for rang, ligne in enumerate(lignes, start=1):
        ligne["rang"] = rang
    retenues = lignes[: a.top]
    avertissements = []
    incompletes = [l["zone"] for l in retenues if l["semaines_rapportees"] < n_semaines]
    if incompletes:
        avertissements.append(
            f"Rang à lire avec prudence, semaines manquantes dans : {', '.join(incompletes)}."
        )
    avertissements += repere_rupture(d, maladie, fin, None)
    return reponse(d, "classement", {"maladie": maladie, "de": debut, "a": fin, "mesure": a.mesure, "top": a.top}, retenues, avertissements)


def situation(d: Donnees, a: argparse.Namespace) -> dict[str, Any]:
    s = d.semaine(a.semaine)
    evo = {l["maladie"]: l for l in d.table("evolutions") if int(l["semaine_ref"]) == s}
    totaux: dict[str, dict[str, float]] = {}
    for l in d.table("observations"):
        if int(l["semaine"]) <= s:
            t = totaux.setdefault(l["maladie"], {"cumul": 0.0, "cumul_deces": 0.0, "deces": 0.0})
            t["cumul"] += float(l["cas"])
            t["cumul_deces"] += float(l["deces"])
            if int(l["semaine"]) == s:
                t["deces"] += float(l["deces"])
    lignes = []
    for code, m in d.maladies.items():
        e, t = evo.get(code), totaux.get(code)
        if not e or not t or t["cumul"] == 0:
            continue
        base = float(e["cas_base_comparable"])
        variation = nombre(e["variation"]) if base >= BASE_MIN_VARIATION else None
        lignes.append({
            "maladie": m["nom"], "code": code, "cas_semaine": float(e["cas_province"]), "deces_semaine": t["deces"],
            "variation_zones_comparables": variation, "zones_comparables": int(e["zones_comparables"]),
            "cumul_cas": t["cumul"], "cumul_deces": t["cumul_deces"],
        })
    presentes = d.zones_ayant_rapporte(s)
    absentes = [d.zones[z]["nom"] for z in sorted(set(d.zones) - presentes)]
    pos = next((l for l in d.table("positivite") if int(l["semaine_ref"]) == s and int(l["semaine"]) == s), None)
    ruptures = d.ruptures(s)
    alertes = [
        {"zone": l["zone"], "maladie": d.maladies[l["maladie"]]["nom"], "statut": l["statut"], "cas": float(l["cas"]), "taux_100k": nombre(l["taux_100k"])}
        for l in d.table("alertes") if int(l["semaine_ref"]) == s
    ]
    resume = {
        "semaine": s, "date_debut": d.date(s),
        "zones_rapportees": len(presentes), "zones_total": len(d.zones), "zones_absentes": absentes,
        "confirmes_sur_suspects_toutes_zones": nombre(pos["brute"]) if pos else None,
        "confirmes_sur_suspects_hors_ruptures": nombre(pos["corrigee"]) if pos else None,
        "zones_en_rupture": [{"zone": d.zones[z]["nom"], "depuis": x} for z, x in sorted(ruptures.items(), key=lambda v: v[1])],
        "alertes": alertes,
    }
    avertissements = [
        "La variation porte sur les zones ayant rapporté les deux semaines, à partir de 10 cas ; sinon elle est nulle.",
        "Le rapport confirmés / suspects n'est qu'un indicateur approché : le nombre de patients testés n'est pas dans la base.",
    ]
    return reponse(d, "situation", {"semaine": s}, lignes, avertissements, resume)


def qualite(d: Donnees, a: argparse.Namespace) -> dict[str, Any]:
    s = d.semaine(a.semaine)
    zone = d.zone(a.zone) if a.zone else None
    lignes = [
        {"zone": l["zone"], "code_zone": l["zs"], "a_rapporte_cette_semaine": l["a_rapporte"] == "TRUE",
         "semaines_rapportees": int(l["sem_rapportees"]), "semaines_attendues": s,
         "couverture": float(l["couverture"]), "couverture_4_semaines": float(l["couverture_4s"]),
         "semaines_manquantes_sur_4": l["manquantes_4s"]}
        for l in d.table("rapportage")
        if int(l["semaine_ref"]) == s and (zone is None or l["zs"] == zone)
    ]
    lignes.sort(key=lambda l: (l["couverture_4_semaines"], l["couverture"], l["code_zone"]))
    ruptures = d.ruptures(s)
    conflits = [
        {"zone": l["zone"], "semaine": int(l["semaine"]), "maladie": d.maladies.get(l["maladie"], {}).get("nom", l["maladie"]), "valeurs": l["valeurs"]}
        for l in d.table("conflits") if zone is None or l["zs"] == zone
    ]
    resume = {
        "zones_en_rupture": [{"zone": d.zones[z]["nom"], "depuis": x} for z, x in sorted(ruptures.items(), key=lambda v: v[1]) if zone is None or z == zone],
        "conflits_a_arbitrer": conflits,
        "journal_base_entiere": [{"regle": l["regle"], "occurrences": int(l["occurrences"]), "action": l["action"]} for l in d.table("journal")],
    }
    return reponse(d, "qualite", {"semaine": s, "zone": zone or "toutes"}, lignes, ["Une zone-semaine compte comme rapportée si la zone a soumis au moins une ligne."], resume)


def catalogue(d: Donnees, a: argparse.Namespace) -> dict[str, Any]:
    zones = [{"code": z["code"], "nom": z["nom"], "population": z["population"]} for z in d.catalogue["zones"]]
    maladies = list(d.catalogue["maladies"])
    if a.chercher:
        cible = normaliser(a.chercher)
        zones = [z for z in zones if cible in normaliser(z["nom"])]
        maladies = [m for m in maladies if cible in normaliser(m["nom"]) or cible in normaliser(m["code"])]
    return {
        "ok": True, "outil": "catalogue", "source": d.source,
        "semaines": {"de": 1, "a": d.semaine_max},
        "semaine_declaration_ebola": d.catalogue["semaine_declaration"],
        "zones": zones, "maladies": maladies,
    }


def reponse(d: Donnees, outil: str, filtres: dict[str, Any], lignes: list[dict[str, Any]],
            avertissements: list[str], resume: dict[str, Any] | None = None) -> dict[str, Any]:
    if len(lignes) > MAX_LIGNES:
        raise Erreur(f"Résultat trop large ({len(lignes)} lignes, limite {MAX_LIGNES}) : réduire la période ou le nombre de zones.")
    charge = {"outil": outil, "filtres": filtres, "source": d.source, "avertissements": avertissements, "resume": resume, "lignes": lignes}
    # Same request on the same base gives the same identifier.
    empreinte = hashlib.sha256(json.dumps(charge, ensure_ascii=False, sort_keys=True).encode("utf-8")).hexdigest()
    identifiant = f"r-{empreinte[:12]}"
    dossier = dossier_resultats(d)
    dossier.mkdir(parents=True, exist_ok=True)
    (dossier / f"{identifiant}.json").write_text(json.dumps(charge, ensure_ascii=False), encoding="utf-8")
    sortie = {"ok": True, "resultat_id": identifiant, **charge}
    return {k: v for k, v in sortie.items() if v is not None}


def dossier_resultats(d: Donnees) -> Path:
    return d.dossier.parent / "resultats"


def publier(d: Donnees, a: argparse.Namespace) -> dict[str, Any]:
    """Writes files only from stored results, so a published table cannot hold invented values."""
    sortie = Path(os.environ.get("ITURI_SORTIES", RACINE / "outputs"))
    resultats = []
    for identifiant in a.ids:
        if not re.fullmatch(r"r-[0-9a-f]{12}", identifiant):
            raise Erreur(f"Identifiant invalide : {identifiant!r}.")
        chemin = dossier_resultats(d) / f"{identifiant}.json"
        if not chemin.is_file():
            raise Erreur(f"Résultat inconnu : {identifiant}. Relancer l'outil qui l'a produit.")
        resultats.append((identifiant, json.loads(chemin.read_text(encoding="utf-8"))))
    for _, r in resultats:
        if r["source"]["sha256"] != d.source["sha256"]:
            raise Erreur("Résultat produit sur une autre base : relancer l'outil.")

    titre = " ".join(a.titre.split())
    if not titre:
        raise Erreur("Le titre est vide.")
    lisible = normaliser(titre)
    base = re.sub(r"[^a-z0-9]+", "-", lisible).strip("-")[:50] or "resultat"
    sortie.mkdir(parents=True, exist_ok=True)
    fichiers = []
    md = [f"# {titre}", "", "**DONNÉES SYNTHÉTIQUES : aucune valeur n'est réelle.**", ""]
    for identifiant, r in resultats:
        csv_nom = f"{base}-{identifiant}.csv"
        if r["lignes"]:
            colonnes = list(dict.fromkeys(c for l in r["lignes"] for c in l))
            with (sortie / csv_nom).open("w", encoding="utf-8-sig", newline="") as flux:
                ecrivain = csv.DictWriter(flux, fieldnames=colonnes)
                ecrivain.writeheader()
                ecrivain.writerows(r["lignes"])
            fichiers.append(str(sortie / csv_nom))
        md += [f"## Résultat {identifiant}", "", f"- Outil : {r['outil']}",
               f"- Filtres : `{json.dumps(r['filtres'], ensure_ascii=False)}`",
               f"- Source : {r['source']['fichier']} (empreinte {r['source']['sha256'][:12]})", ""]
        if r["avertissements"]:
            md += ["À lire avec ces réserves :", ""] + [f"- {x}" for x in r["avertissements"]] + [""]
        if r["lignes"]:
            md += [f"Tableau : `{csv_nom}` ({len(r['lignes'])} lignes)", ""]
    md_chemin = sortie / f"{base}.md"
    md_chemin.write_text("\n".join(md), encoding="utf-8")
    fichiers.insert(0, str(md_chemin))
    return {"ok": True, "outil": "publier", "fichiers": fichiers, "source": d.source}


def analyseur() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    sous = p.add_subparsers(dest="commande", required=True)

    c = sous.add_parser("catalogue", help="Zones, maladies et semaines disponibles")
    c.add_argument("--chercher")
    c.set_defaults(fonction=catalogue)

    c = sous.add_parser("serie", help="Cas, décès et taux par semaine")
    c.add_argument("--maladie", required=True)
    c.add_argument("--zone", action="append", help="Répéter pour plusieurs zones ; absent : province")
    c.add_argument("--de", type=int)
    c.add_argument("--a", type=int)
    c.set_defaults(fonction=serie)

    c = sous.add_parser("classement", help="Zones les plus touchées sur une période")
    c.add_argument("--maladie", required=True)
    c.add_argument("--de", type=int)
    c.add_argument("--a", type=int)
    c.add_argument("--top", type=int, default=10)
    c.add_argument("--mesure", choices=["cas", "taux"], default="cas")
    c.set_defaults(fonction=classement)

    c = sous.add_parser("situation", help="Vue d'une semaine : maladies, évolutions, alertes, ruptures")
    c.add_argument("--semaine", type=int)
    c.set_defaults(fonction=situation)

    c = sous.add_parser("qualite", help="Rapportage, ruptures, conflits et journal de nettoyage")
    c.add_argument("--semaine", type=int)
    c.add_argument("--zone")
    c.set_defaults(fonction=qualite)

    c = sous.add_parser("publier", help="Écrit un tableau et ses sources depuis des résultats enregistrés")
    c.add_argument("--ids", nargs="+", required=True)
    c.add_argument("--titre", required=True)
    c.set_defaults(fonction=publier)
    return p


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    args = analyseur().parse_args()
    try:
        dossier = Path(os.environ.get("ITURI_DONNEES", RACINE / "data" / "synthetic"))
        resultat = args.fonction(Donnees(dossier), args)
    except Erreur as exc:
        print(json.dumps({"ok": False, "erreur": str(exc)}, ensure_ascii=False))
        return 2
    print(json.dumps(resultat, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
