# Checks the exported files against the pipeline and against values displayed by the dashboard.
#   Rscript export/tests/test_export.R --pipeline="<path>" [--sortie="<export folder>"]

args <- commandArgs(trailingOnly = TRUE)
valeur <- function(nom, defaut = NULL) {
  x <- sub(paste0("^--", nom, "="), "", grep(paste0("^--", nom, "="), args, value = TRUE))
  if (length(x)) x[1] else defaut
}
ici <- normalizePath(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])), winslash = "/")
racine <- dirname(dirname(ici))
pipeline <- normalizePath(valeur("pipeline", Sys.getenv("ITURI_PIPELINE")), winslash = "/")
sortie <- valeur("sortie", file.path(racine, "data", "synthetic"))

Sys.setenv(ITURI_DEMO = "1")
setwd(pipeline)
for (f in c("R/donnees.R", "R/indicateurs.R", "R/figures.R", "dashboard/R/donnees_app.R")) {
  source(file.path(pipeline, f), encoding = "UTF-8", local = FALSE)
}
source(file.path(dirname(ici), "tables.R"), encoding = "UTF-8")
library(testthat)

# guess_max = Inf: early weeks leave debut_rupture empty, which would otherwise be read as logical.
lire <- function(nom) readr::read_csv(file.path(sortie, paste0(nom, ".csv")), show_col_types = FALSE, guess_max = Inf)
cfg <- lire_config()
ids <- nettoyer_ids(trouver_base(cfg), cfg)
d <- ids$donnees
obs <- lire("observations")
rap <- lire("rapportage")
rup <- lire("ruptures")
pos <- lire("positivite")
evo <- lire("evolutions")
ale <- lire("alertes")
cat_ <- jsonlite::read_json(file.path(sortie, "catalogue.json"))
S <- ids$semaine_max
semaines_test <- c(5L, 20L, 32L, S - 1L, S)
ids_jusqua <- function(s) {
  x <- ids
  x$donnees <- dplyr::filter(ids$donnees, semaine <= s)
  x$ruptures <- detecter_ruptures_palu(x$donnees, cfg)
  x
}

test_that("the export is synthetic and tied to the synthetic base", {
  expect_true(isTRUE(cat_$synthetique))
  expect_identical(cat_$source$sha256, digest::digest(file = file.path(pipeline, "data/synthetic/raw", cat_$source$fichier), algo = "sha256"))
  reelles <- list.files(file.path(pipeline, "data/raw"), pattern = "\\.xlsx$", full.names = TRUE)
  for (f in reelles) expect_false(identical(cat_$source$sha256, digest::digest(file = f, algo = "sha256")))
})

test_that("observations round-trip without loss", {
  expect_equal(nrow(obs), nrow(d))
  x <- dplyr::arrange(obs, zs, semaine, maladie)
  y <- dplyr::arrange(d, zs, semaine, maladie)
  expect_equal(x$cas, y$cas)
  expect_equal(x$deces, y$deces)
  expect_equal(x$pop, y$pop)
  expect_equal(as.Date(x$date), y$date)
})

test_that("weekly tables rebuilt from the export match the report table", {
  codes <- c(unlist(cfg$tableau_principal), unlist(cfg$tableau_autres))
  for (s in semaines_test) {
    t <- tableau_maladies(d, codes, s, cfg)
    x <- obs |> dplyr::filter(semaine <= s) |> dplyr::group_by(maladie) |>
      dplyr::summarise(cumul = sum(cas), cumul_dc = sum(deces), cas_s = sum(cas[semaine == s]), dc_s = sum(deces[semaine == s]), .groups = "drop")
    m <- dplyr::left_join(t, x, by = "maladie", suffix = c("", "_x")) |>
      dplyr::mutate(dplyr::across(c(cumul_x, cumul_dc_x, cas_s, dc_s), ~ dplyr::coalesce(.x, 0)))
    expect_equal(m$cumul_x, m$cumul)
    expect_equal(m$cumul_dc_x, m$cumul_dc)
    expect_equal(m$cas_s, m[[paste0("S", s)]])
    expect_equal(m$dc_s, m$dc_S)
  }
})

test_that("rule-based tables match the pipeline at each tested week", {
  for (s in semaines_test) {
    r <- rapportage_zones(d, s)
    x <- dplyr::filter(rap, semaine_ref == s)
    expect_equal(nrow(x), length(unique(d$zs)))
    m <- dplyr::inner_join(r, x, by = "zs", suffix = c("", "_x"))
    expect_equal(nrow(m), nrow(r))
    expect_equal(m$couverture_x, m$couverture)
    expect_equal(m$couverture_4s_x, m$couverture_4s)
    expect_setequal(x$zs[x$a_rapporte], unique(d$zs[d$semaine == s]))

    a <- ids_jusqua(s)
    rr <- dplyr::filter(rup, semaine_ref == s) |> dplyr::arrange(zs)
    ar <- dplyr::arrange(a$ruptures, zs)
    expect_equal(rr$debut_rupture, ar$debut_rupture)
    expect_equal(rr$positivite_base, ar$positivite_base)

    p <- positivite_province(a, s)
    pp <- dplyr::filter(pos, semaine_ref == s) |> dplyr::arrange(semaine)
    expect_equal(pp$brute, p$brute)
    expect_equal(pp$corrigee, p$corrigee)

    for (code in c("PALUDISME SUSP", "IRA")) {
      e <- evolution_comparable(d[d$semaine <= s, ], code, s)
      v <- dplyr::filter(evo, semaine_ref == s, maladie == code)
      expect_equal(v$cas_province, e$valeur)
      if (is.na(e$variation)) expect_true(is.na(v$variation)) else expect_equal(v$variation, e$variation)
    }

    n_al <- nrow(alertes_rougeole(d[d$semaine <= s, ], s, cfg)) + nrow(alertes_meningite(d[d$semaine <= s, ], s, cfg))
    expect_equal(sum(ale$semaine_ref == s), n_al)
  }
})

# The synthetic base crosses no threshold, so lowered thresholds exercise the non-empty path.
test_that("alert rows carry the expected fields when thresholds are crossed", {
  bas <- cfg
  bas$seuils$rougeole_min_cas <- 1
  bas$seuils$rougeole_facteur <- 0
  bas$seuils$meningite_alerte <- 0.01
  bas$seuils$meningite_epidemique <- 1000
  a <- construire_alertes(d, S, bas)
  expect_true(all(c("ROUGEOLE", "MENINGITE") %in% a$maladie))
  expect_named(a, c("zs", "zone", "maladie", "statut", "cas", "taux_100k"), ignore.order = TRUE)
  expect_true(all(a$cas > 0))
  m <- a[a$maladie == "MENINGITE", ]
  expect_true(all(m$taux_100k > 0))
  expect_true(all(m$statut == "alerte"))
  r <- a[a$maladie == "ROUGEOLE", ]
  attendu <- d[d$maladie == "ROUGEOLE" & d$semaine == S & d$cas >= 1, ]
  expect_setequal(r$zs, attendu$zs)
})

# Independent check: figures read on the dashboard's synthetic Overview and Data quality pages (S43).
test_that("the export reproduces the figures displayed by the dashboard", {
  skip_if_not(startsWith(cat_$source$sha256, "e39b29d34a6f"), "Synthetic base changed: update these reference values.")
  skip_if_not(S == 43L)
  expect_equal(sum(rap$a_rapporte[rap$semaine_ref == 43]), 35)
  e <- function(code) evo[evo$semaine_ref == 43 & evo$maladie == code, ]
  expect_equal(e("PALUDISME SUSP")$cas_province, 24992)
  expect_equal(round(100 * e("PALUDISME SUSP")$variation, 1), 0.4)
  expect_equal(e("IRA")$cas_province, 7084)
  expect_equal(round(100 * e("IRA")$variation, 1), 5.8)
  fha <- obs[obs$maladie == "FHA", ]
  expect_equal(sum(fha$cas[fha$semaine == 43]), 54)
  expect_equal(sum(fha$deces[fha$semaine == 43]), 11)
  expect_equal(sum(fha$cas), 1133)
  p <- pos[pos$semaine_ref == 43 & pos$semaine == 43, ]
  expect_equal(round(100 * p$corrigee, 1), 59.5)
  expect_equal(round(100 * p$brute, 1), 54.1)
  expect_equal(sum(!is.na(rup$debut_rupture[rup$semaine_ref == 43])), 3)
  expect_equal(nrow(lire("conflits")), 5)
  j <- lire("journal")
  expect_equal(j$occurrences[grepl("Date de début", j$regle, fixed = TRUE)], 287)
})

cat("All export checks finished.\n")
