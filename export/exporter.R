# Exports the surveillance tables read by the assistant.
#   Rscript export/exporter.R --pipeline="<path to ituri-situation-epidemiologique>"
#
# The assistant never recomputes an indicator: every value that depends on rules (reporting,
# malaria breaks, positivity, comparable trends, alerts) comes from the pipeline's own functions.
# Synthetic by default. --reelles needs the agreement recorded in accord.local.json.

args <- commandArgs(trailingOnly = TRUE)
valeur <- function(nom, defaut = NULL) {
  x <- sub(paste0("^--", nom, "="), "", grep(paste0("^--", nom, "="), args, value = TRUE))
  if (length(x)) x[1] else defaut
}
ici <- normalizePath(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])), winslash = "/")
pipeline <- valeur("pipeline", Sys.getenv("ITURI_PIPELINE"))
if (!nzchar(pipeline) || !file.exists(file.path(pipeline, "R", "donnees.R"))) {
  stop("Pass --pipeline=<path to the surveillance pipeline repository>.", call. = FALSE)
}
pipeline <- normalizePath(pipeline, winslash = "/")
reelles <- "--reelles" %in% args
sortie <- valeur("sortie", file.path(dirname(ici), "data", if (reelles) "reelles" else "synthetic"))
source(file.path(ici, "tables.R"), encoding = "UTF-8")
accord <- if (reelles) verifier_accord(valeur("accord", Sys.getenv("ITURI_ACCORD", file.path(dirname(ici), "accord.local.json"))))

# Forced, whatever the caller's environment says.
Sys.setenv(ITURI_DEMO = if (reelles) "0" else "1")
setwd(pipeline)
for (f in c("R/donnees.R", "R/indicateurs.R", "R/figures.R", "dashboard/R/donnees_app.R")) {
  source(file.path(pipeline, f), encoding = "UTF-8", local = FALSE)
}

cfg <- lire_config()
if (!reelles && !dir.exists(chemin_donnees("raw"))) {
  source(file.path(pipeline, "R/donnees_synthetiques.R"), encoding = "UTF-8")
  generer_donnees_synthetiques(cfg)
}
base <- trouver_base(cfg)
attendu <- if (reelles) "/data/raw/" else "/data/synthetic/raw/"
if (!grepl(attendu, normalizePath(base, winslash = "/"), fixed = TRUE)) {
  stop("Refused: unexpected data source for this mode.", call. = FALSE)
}
ids <- nettoyer_ids(base, cfg)
d <- ids$donnees
zones <- sort(unique(d$zs))
semaines <- sort(unique(d$semaine))
# A monitored disease with no line stays known, so it is never mistaken for an unknown disease.
suivies <- unique(c(unlist(cfg$tableau_principal), unlist(cfg$tableau_autres)))
codes <- suivies[suivies %in% unique(d$maladie)]

# The dashboard filters to data available up to week S before applying the break rule.
ids_jusqua <- function(s) {
  x <- ids
  x$donnees <- dplyr::filter(ids$donnees, semaine <= s)
  x$ruptures <- detecter_ruptures_palu(x$donnees, cfg)
  x
}
par_semaine <- function(f) dplyr::bind_rows(lapply(semaines, function(s) dplyr::mutate(f(s), semaine_ref = s, .before = 1)))

observations <- d |>
  dplyr::transmute(zs, zone = nom_zone(zs), semaine, date, maladie, libelle = libelle(maladie, cfg), cas, deces, pop)

rapportage <- par_semaine(function(s) {
  tibble::tibble(zs = zones) |>
    dplyr::left_join(rapportage_zones(d, s), by = "zs") |>
    dplyr::mutate(sem_rapportees = dplyr::coalesce(sem_rapportees, 0L),
                  couverture = dplyr::coalesce(couverture, 0),
                  couverture_4s = dplyr::coalesce(couverture_4s, 0),
                  a_rapporte = zs %in% d$zs[d$semaine == s],
                  zone = nom_zone(zs), .after = zs)
})

ruptures <- par_semaine(function(s) {
  ids_jusqua(s)$ruptures |>
    dplyr::mutate(zone = nom_zone(zs), .after = zs)
})

positivite <- par_semaine(function(s) positivite_province(ids_jusqua(s), s))

evolutions <- par_semaine(function(s) {
  dplyr::bind_rows(lapply(codes, function(code) {
    e <- evolution_comparable(d[d$semaine <= s, ], code, s)
    tibble::tibble(maladie = code, cas_province = e$valeur, variation = e$variation,
                   cas_base_comparable = e$base, zones_comparables = e$n_zones,
                   zones_comparables_avec_ligne = zones_comparables_avec_ligne(d[d$semaine <= s, ], code, s))
  }))
})

alertes <- par_semaine(function(s) construire_alertes(d, s, cfg))

journal <- ids$journal |>
  dplyr::filter(n > 0) |>
  dplyr::transmute(regle = traduire_journal(regle), occurrences = n, action = traduire_journal(action))

conflits <- ids$conflits |>
  dplyr::transmute(zs, zone = nom_zone(zs), semaine = as.integer(numsem), maladie, valeurs)

catalogue <- list(
  synthetique = !reelles,
  source = list(fichier = ids$fichier, sha256 = ids$sha256),
  semaine_max = ids$semaine_max,
  semaine_declaration = cfg$epidemie$semaine_rupture,
  origine_semaine1 = cfg$donnees$origine_semaine1,
  zones = lapply(zones, function(z) list(code = z, nom = nom_zone(z), population = ids$pop$pop_ref[ids$pop$zs == z])),
  maladies = lapply(suivies, function(k) list(code = k, nom = libelle(k, cfg), lignes_dans_la_base = k %in% codes)),
  seuils_alerte = list(
    rougeole = sprintf("Au moins %d cas dans une zone et au moins %d fois la moyenne des %d semaines précédentes",
                       cfg$seuils$rougeole_min_cas, cfg$seuils$rougeole_facteur, cfg$seuils$rougeole_fenetre),
    meningite = sprintf("Alerte à partir de %d et épidémie à partir de %d cas par semaine pour 100 000 habitants ; seuils à valider avec la DPS",
                        cfg$seuils$meningite_alerte, cfg$seuils$meningite_epidemique)
  ),
  tables = c("observations", "rapportage", "ruptures", "positivite", "evolutions", "alertes", "journal", "conflits")
)

dir.create(sortie, recursive = TRUE, showWarnings = FALSE)
ecrire <- function(x, nom) readr::write_csv(x, file.path(sortie, paste0(nom, ".csv")), na = "")
ecrire(observations, "observations")
ecrire(rapportage, "rapportage")
ecrire(ruptures, "ruptures")
ecrire(positivite, "positivite")
ecrire(evolutions, "evolutions")
ecrire(alertes, "alertes")
ecrire(journal, "journal")
ecrire(conflits, "conflits")
jsonlite::write_json(catalogue, file.path(sortie, "catalogue.json"), auto_unbox = TRUE, pretty = TRUE)

cat(sprintf("%s export written to %s\n  %d observations, %d zones, weeks %d-%d\n",
            if (reelles) "REAL DATA" else "Synthetic", sortie, nrow(observations), length(zones), min(semaines), max(semaines)))
