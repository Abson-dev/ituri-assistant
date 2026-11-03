# Checks that the Python tools return the pipeline's figures across diseases, zones and weeks.
#   Rscript export/tests/test_parite_outils.R --pipeline="<path>" [--python=python]

args <- commandArgs(trailingOnly = TRUE)
valeur <- function(nom, defaut = NULL) {
  x <- sub(paste0("^--", nom, "="), "", grep(paste0("^--", nom, "="), args, value = TRUE))
  if (length(x)) x[1] else defaut
}
ici <- normalizePath(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])), winslash = "/")
racine <- dirname(dirname(ici))
pipeline <- normalizePath(valeur("pipeline", Sys.getenv("ITURI_PIPELINE")), winslash = "/")
python <- valeur("python", "python")
outil <- file.path(racine, ".claude/skills/ituri-surveillance/scripts/ituri.py")

Sys.setenv(ITURI_DEMO = "1", ITURI_DONNEES = file.path(racine, "data/synthetic"))
setwd(pipeline)
for (f in c("R/donnees.R", "R/indicateurs.R", "R/figures.R", "dashboard/R/donnees_app.R")) {
  source(file.path(pipeline, f), encoding = "UTF-8", local = FALSE)
}
library(testthat)

appel <- function(...) {
  a <- vapply(c(...), shQuote, character(1), type = "cmd", USE.NAMES = FALSE)
  sortie <- system2(python, c(shQuote(outil, type = "cmd"), a), stdout = TRUE)
  jsonlite::fromJSON(paste(sortie, collapse = "\n"))
}

cfg <- lire_config()
ids <- nettoyer_ids(trouver_base(cfg), cfg)
d <- ids$donnees
S <- ids$semaine_max
maladies <- c("PALUDISME SUSP", "PALUDISME CONF", "IRA", "FHA", "ROUGEOLE", "MENINGITE")
zones <- c("MONGBWALU", "NYARAMBE", "BUNIA", "NIA-NIA")

test_that("province series match the dashboard", {
  for (code in maladies) {
    r <- appel("serie", "--maladie", code)$lignes
    a <- serie_cible(d, code, S)
    expect_equal(r$semaine, a$semaine)
    expect_equal(r$cas, a$cas)
    expect_equal(r$deces, a$deces)
    expect_equal(r$zones_rapportees, a$zones)
    expect_equal(r$taux_100k, a$cas / sum(ids$pop$pop_ref) * 1e5, tolerance = 1e-9)
  }
})

test_that("zone series match the dashboard, except that a missing line stays missing", {
  for (code in maladies) for (z in zones) {
    r <- appel("serie", "--maladie", code, "--zone", z)$lignes
    a <- serie_cible(d, code, S, z)
    expect_equal(dplyr::coalesce(r$cas, 0), a$cas)
    presentes <- d$semaine[d$maladie == code & d$zs == z]
    expect_setequal(r$semaine[!is.na(r$cas)], presentes)
    pop <- ids$pop$pop_ref[ids$pop$zs == z]
    # A zone with no line at all gives an all-null column, which R reads as logical.
    expect_equal(as.numeric(r$taux_100k[!is.na(r$cas)]), as.numeric(r$cas[!is.na(r$cas)]) / pop * 1e5, tolerance = 1e-9)
  }
})

test_that("rankings match the pipeline", {
  for (code in maladies) for (s in c(20L, S)) {
    r <- appel("classement", "--maladie", code, "--de", s - 3L, "--a", s, "--top", 36)$lignes
    a <- zones_recentes(d, code, s)
    if (nrow(a) == 0) {
      expect_equal(length(r), 0)
    } else {
      expect_equal(sort(r$cas, decreasing = TRUE), a$cas)
      expect_setequal(r$code_zone, a$zs)
    }
  }
})

test_that("weekly overview matches the report table and the dashboard", {
  codes <- c(unlist(cfg$tableau_principal), unlist(cfg$tableau_autres))
  for (s in c(5L, 20L, 32L, S)) {
    r <- appel("situation", "--semaine", s)
    t <- tableau_maladies(d, codes, s, cfg) |> dplyr::filter(cumul > 0)
    m <- dplyr::inner_join(t, r$lignes, by = c("maladie" = "code"), suffix = c("", "_o"))
    expect_equal(nrow(m), nrow(t))
    expect_equal(m$cas_semaine, m[[paste0("S", s)]])
    expect_equal(m$deces_semaine, m$dc_S)
    expect_equal(m$cumul_cas, m$cumul)
    expect_equal(m$cumul_deces, m$cumul_dc)
    expect_equal(r$resume$zones_rapportees, dplyr::n_distinct(d$zs[d$semaine == s]))
  }
})

test_that("reporting matches the pipeline", {
  for (s in c(5L, S)) {
    r <- appel("qualite", "--semaine", s)$lignes
    a <- rapportage_zones(d, s)
    m <- dplyr::inner_join(a, r, by = c("zs" = "code_zone"))
    expect_equal(nrow(m), nrow(a))
    expect_equal(m$couverture.y, m$couverture.x)
    expect_equal(m$couverture_4_semaines, m$couverture_4s)
  }
})

cat("All parity checks finished.\n")
