"""Tests for the surveillance tools. No API key or model call: run with
    python -m unittest discover -s tests -v
"""

from __future__ import annotations

import csv
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

RACINE = Path(__file__).resolve().parents[1]
OUTIL = RACINE / ".claude" / "skills" / "ituri-surveillance" / "scripts" / "ituri.py"
DONNEES = RACINE / "data" / "synthetic"
SHA_REFERENCE = "e39b29d34a6f"


@unittest.skipUnless((DONNEES / "catalogue.json").is_file(), "Run export/exporter.R first.")
class Outils(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory()
        cls.travail = Path(cls.temp.name)
        cls.donnees = cls.travail / "donnees" / "synthetic"
        shutil.copytree(DONNEES, cls.donnees)
        cls.sorties = cls.travail / "sorties"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def lancer(self, *args: str, donnees: Path | None = None) -> tuple[int, dict]:
        env = {**os.environ, "ITURI_DONNEES": str(donnees or self.donnees), "ITURI_SORTIES": str(self.sorties)}
        p = subprocess.run([sys.executable, str(OUTIL), *args], capture_output=True, encoding="utf-8", env=env)
        self.assertEqual(p.stderr, "")
        return p.returncode, json.loads(p.stdout)

    def ok(self, *args: str) -> dict:
        code, r = self.lancer(*args)
        self.assertEqual(code, 0, r)
        return r

    def erreur(self, *args: str, donnees: Path | None = None) -> str:
        code, r = self.lancer(*args, donnees=donnees)
        self.assertEqual(code, 2, r)
        self.assertFalse(r["ok"])
        return r["erreur"]

    def test_source_toujours_synthetique(self) -> None:
        for args in (["catalogue"], ["situation"], ["qualite"], ["serie", "--maladie", "IRA"]):
            self.assertTrue(self.ok(*args)["source"]["synthetique"])

    def test_refuse_un_export_non_synthetique(self) -> None:
        with tempfile.TemporaryDirectory() as t:
            autre = Path(t) / "x"
            shutil.copytree(self.donnees, autre)
            cat = json.loads((autre / "catalogue.json").read_text(encoding="utf-8"))
            cat["synthetique"] = False
            (autre / "catalogue.json").write_text(json.dumps(cat), encoding="utf-8")
            self.assertIn("Refus", self.erreur("catalogue", donnees=autre))
            del cat["synthetique"]
            (autre / "catalogue.json").write_text(json.dumps(cat), encoding="utf-8")
            self.assertIn("Refus", self.erreur("situation", donnees=autre))

    def test_chiffres_du_tableau_de_bord_s43(self) -> None:
        r = self.ok("situation", "--semaine", "43")
        if not r["source"]["sha256"].startswith(SHA_REFERENCE):
            self.skipTest("Synthetic base changed.")
        m = {l["code"]: l for l in r["lignes"]}
        self.assertEqual(m["PALUDISME SUSP"]["cas_semaine"], 24992)
        self.assertEqual(round(100 * m["PALUDISME SUSP"]["variation_zones_comparables"], 1), 0.4)
        self.assertEqual(m["IRA"]["cas_semaine"], 7084)
        self.assertEqual(round(100 * m["IRA"]["variation_zones_comparables"], 1), 5.8)
        self.assertEqual(m["FHA"]["cas_semaine"], 54)
        self.assertEqual(m["FHA"]["deces_semaine"], 11)
        self.assertEqual(m["FHA"]["cumul_cas"], 1133)
        self.assertEqual(m["PALUDISME SUSP"]["cumul_cas"], 1111656)
        s = r["resume"]
        self.assertEqual(s["zones_rapportees"], 35)
        self.assertEqual(s["zones_absentes"], ["Nyarambe"])
        self.assertEqual(round(100 * s["confirmes_sur_suspects_hors_ruptures"], 1), 59.5)
        self.assertEqual(round(100 * s["confirmes_sur_suspects_toutes_zones"], 1), 54.1)
        self.assertEqual({z["zone"] for z in s["zones_en_rupture"]}, {"Bambu", "Komanda", "Mongbwalu"})

    def test_variation_masquee_sous_le_seuil(self) -> None:
        m = {l["code"]: l for l in self.ok("situation", "--semaine", "43")["lignes"]}
        self.assertIsNone(m["ROUGEOLE"]["variation_zones_comparables"])

    def test_zone_absente_n_est_pas_un_zero(self) -> None:
        r = self.ok("serie", "--maladie", "IRA", "--zone", "NYARAMBE", "--de", "43", "--a", "43")
        l = r["lignes"][0]
        self.assertIsNone(l["cas"])
        self.assertEqual(l["statut"], "zone_n_a_pas_rapporte")
        self.assertTrue(any("zéro confirmé" in a for a in r["avertissements"]))

    def test_semaine_sans_ligne_en_province_n_est_pas_un_zero(self) -> None:
        r = self.ok("serie", "--maladie", "FHA", "--de", "19", "--a", "20")
        sans, avec = r["lignes"]
        self.assertIsNone(sans["cas"])
        self.assertIsNone(sans["deces"])
        self.assertIsNone(sans["taux_100k"])
        self.assertEqual(sans["zones_avec_ligne"], 0)
        self.assertEqual(sans["statut"], "aucune_ligne_dans_la_base")
        self.assertIsNotNone(avec["cas"])
        self.assertTrue(any("zéro confirmé" in a for a in r["avertissements"]))

    def test_semaine_sans_ligne_dans_la_situation_n_est_pas_un_zero(self) -> None:
        r = self.ok("situation", "--semaine", "43")
        m = {l["code"]: l for l in r["lignes"]}
        self.assertEqual(m["DIARR SANGLANTE"]["zones_avec_ligne"], 0)
        self.assertIsNone(m["DIARR SANGLANTE"]["cas_semaine"])
        self.assertIsNone(m["DIARR SANGLANTE"]["deces_semaine"])
        self.assertGreater(m["DIARR SANGLANTE"]["cumul_cas"], 0)
        self.assertTrue(any("zéro confirmé" in a for a in r["avertissements"]))

    def test_vrai_zero_reste_un_zero(self) -> None:
        with (self.donnees / "observations.csv").open(encoding="utf-8", newline="") as flux:
            zero = next((l for l in csv.DictReader(flux) if float(l["cas"]) == 0), None)
        if zero is None:
            self.skipTest("No recorded zero in this export.")
        s = zero["semaine"]
        r = self.ok("serie", "--maladie", zero["maladie"], "--zone", zero["zs"], "--de", s, "--a", s)
        self.assertEqual(r["lignes"][0]["cas"], 0)
        self.assertEqual(r["lignes"][0]["statut"], "ligne_presente")

    def test_province_partielle_signalee(self) -> None:
        r = self.ok("serie", "--maladie", "IRA", "--de", "43", "--a", "43")
        self.assertEqual(r["lignes"][0]["zones_rapportees"], 35)
        self.assertTrue(any("S43 (35/36)" in a for a in r["avertissements"]))

    def test_rupture_signalee_pour_les_confirmes(self) -> None:
        r = self.ok("serie", "--maladie", "PALUDISME CONF", "--zone", "MONGBWALU", "--de", "40", "--a", "43")
        self.assertTrue(any("Mongbwalu" in a for a in r["avertissements"]))
        r = self.ok("serie", "--maladie", "PALUDISME SUSP", "--zone", "MONGBWALU", "--de", "40", "--a", "43")
        self.assertFalse(any("interrompue" in a for a in r["avertissements"]))

    def test_noms_sans_accent_ni_casse(self) -> None:
        r = self.ok("serie", "--maladie", "fievre typhoide", "--zone", "nia-nia", "--de", "1", "--a", "2")
        self.assertEqual(r["filtres"]["maladie"], "FIEVRE TYPHOIDE")
        self.assertEqual(r["filtres"]["zones"], ["NIA-NIA"])

    def test_erreurs_corrigeables(self) -> None:
        self.assertIn("MONGBWALU", self.erreur("serie", "--maladie", "IRA", "--zone", "Mongbwal"))
        self.assertIn("PALUDISME", self.erreur("serie", "--maladie", "paludisme"))
        self.assertIn("S1 à S43", self.erreur("situation", "--semaine", "99"))
        self.assertIn("S1 à S43", self.erreur("situation", "--semaine", "0"))
        self.assertIn("Période invalide", self.erreur("serie", "--maladie", "IRA", "--de", "10", "--a", "5"))
        self.assertIn("top", self.erreur("classement", "--maladie", "IRA", "--top", "0"))

    def test_limite_de_lignes(self) -> None:
        zones = [z["code"] for z in self.ok("catalogue")["zones"]]
        args = ["serie", "--maladie", "IRA"]
        for z in zones:
            args += ["--zone", z]
        self.assertIn("trop large", self.erreur(*args))

    def test_classement_ordonne(self) -> None:
        l = self.ok("classement", "--maladie", "IRA", "--de", "40", "--a", "43", "--top", "5")["lignes"]
        self.assertEqual(len(l), 5)
        self.assertEqual([x["rang"] for x in l], [1, 2, 3, 4, 5])
        self.assertEqual(l, sorted(l, key=lambda x: -x["cas"]))
        t = self.ok("classement", "--maladie", "IRA", "--de", "40", "--a", "43", "--mesure", "taux", "--top", "5")["lignes"]
        self.assertEqual(t, sorted(t, key=lambda x: -x["taux_100k"]))

    def test_publier_ecrit_les_sources(self) -> None:
        r = self.ok("serie", "--maladie", "IRA", "--de", "40", "--a", "43")
        p = self.ok("publier", "--ids", r["resultat_id"], "--titre", "IRA : province")
        md = Path(p["fichiers"][0]).read_text(encoding="utf-8")
        self.assertIn("DONNÉES SYNTHÉTIQUES", md)
        self.assertIn(r["source"]["sha256"][:12], md)
        self.assertEqual(len(Path(p["fichiers"][1]).read_text(encoding="utf-8-sig").splitlines()), 5)

    def test_publier_refuse_un_resultat_inconnu_ou_invente(self) -> None:
        self.assertIn("inconnu", self.erreur("publier", "--ids", "r-000000000000", "--titre", "x"))
        self.assertIn("invalide", self.erreur("publier", "--ids", "../../secret", "--titre", "x"))

    def test_titre_ne_sort_pas_du_dossier(self) -> None:
        r = self.ok("serie", "--maladie", "IRA", "--de", "40", "--a", "41")
        p = self.ok("publier", "--ids", r["resultat_id"], "--titre", "../../hors du dossier")
        for f in p["fichiers"]:
            self.assertEqual(Path(f).resolve().parent, self.sorties.resolve())

    def test_outil_sans_reseau_ni_ecriture_de_donnees(self) -> None:
        source = OUTIL.read_text(encoding="utf-8")
        for module in ("socket", "urllib", "http.client", "requests", "subprocess"):
            self.assertNotIn(f"import {module}", source)
        avant = {f.name: f.stat().st_mtime_ns for f in self.donnees.iterdir()}
        self.ok("situation")
        self.assertEqual(avant, {f.name: f.stat().st_mtime_ns for f in self.donnees.iterdir()})


if __name__ == "__main__":
    unittest.main()
