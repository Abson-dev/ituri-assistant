# Computes the expected answers from the pipeline, without using the Python tools.
#   Rscript evals/attendus.R --pipeline="<path>" --sortie="<folder outside this repository>"
#
# The answers must stay outside the repository: the agent under test can read this folder.

args <- commandArgs(trailingOnly = TRUE)
valeur <- function(nom) sub(paste0("^--", nom, "="), "", grep(paste0("^--", nom, "="), args, value = TRUE))[1]
ici <- normalizePath(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])), winslash = "/")
racine <- dirname(ici)
pipeline <- normalizePath(valeur("pipeline"), winslash = "/")
sortie <- valeur("sortie")
if (is.na(sortie)) stop("Pass --sortie=<folder outside this repository>.", call. = FALSE)
dir.create(sortie, recursive = TRUE, showWarnings = FALSE)
sortie <- normalizePath(sortie, winslash = "/")
if (startsWith(tolower(sortie), paste0(tolower(racine), "/")) || tolower(sortie) == tolower(racine)) {
  stop("Refused: expected answers must stay outside the repository.", call. = FALSE)
}

Sys.setenv(ITURI_DEMO = "1")
setwd(pipeline)
for (f in c("R/donnees.R", "R/indicateurs.R", "R/figures.R", "dashboard/R/donnees_app.R")) {
  source(file.path(pipeline, f), encoding = "UTF-8", local = FALSE)
}
cfg <- lire_config()
ids <- nettoyer_ids(trouver_base(cfg), cfg)
d <- ids$donnees
S <- ids$semaine_max
zones <- sort(unique(d$zs))
somme <- function(code, de = 1L, a = S, zone = NULL, champ = "cas") {
  x <- d[d$maladie == code & d$semaine >= de & d$semaine <= a, ]
  if (!is.null(zone)) x <- x[x$zs == zone, ]
  sum(x[[champ]])
}
absentes <- function(s) nom_zone(setdiff(zones, d$zs[d$semaine == s]))
top <- function(code, de, a, n, taux = FALSE) {
  x <- d[d$maladie == code & d$semaine >= de & d$semaine <= a, ] |>
    dplyr::group_by(zs) |> dplyr::summarise(cas = sum(cas), pop = dplyr::first(pop), .groups = "drop") |>
    dplyr::mutate(taux = cas / pop * 1e5)
  x <- if (taux) dplyr::arrange(x, dplyr::desc(taux)) else dplyr::arrange(x, dplyr::desc(cas))
  x <- utils::head(x, n)
  lapply(seq_len(nrow(x)), function(i) list(zone = nom_zone(x$zs[i]), cas = x$cas[i], taux = round(x$taux[i], 1)))
}
ligne_zone <- function(code, zone, s) d[d$maladie == code & d$zs == zone & d$semaine == s, ]
ids_a <- function(s) { x <- ids; x$donnees <- d[d$semaine <= s, ]; x$ruptures <- detecter_ruptures_palu(x$donnees, cfg); x }
evol <- function(code, s) {
  e <- evolution_comparable(d[d$semaine <= s, ], code, s)
  list(variation_pct = round(100 * e$variation, 1), base = e$base, zones_comparables = e$n_zones)
}
pos <- function(s) { p <- positivite_province(ids_a(s), s); p <- p[p$semaine == s, ]; list(toutes_zones_pct = round(100 * p$brute, 1), hors_ruptures_pct = round(100 * p$corrigee, 1)) }
rup <- function(s) { r <- ids_a(s)$ruptures; r <- r[!is.na(r$debut_rupture), ]; lapply(seq_len(nrow(r)), function(i) list(zone = nom_zone(r$zs[i]), depuis = r$debut_rupture[i])) }
serie_pneu <- d[d$maladie == "PNEUMONIE", ] |> dplyr::group_by(semaine) |> dplyr::summarise(cas = sum(cas), zones = dplyr::n_distinct(zs), .groups = "drop")
fha_dc <- d[d$maladie == "FHA", ] |> dplyr::group_by(zs) |> dplyr::summarise(deces = sum(deces), .groups = "drop") |> dplyr::arrange(dplyr::desc(deces))
couv <- rapportage_zones(d, S)
couv <- dplyr::bind_rows(couv, tibble::tibble(zs = setdiff(zones, couv$zs), sem_rapportees = 0L, couverture = 0, couverture_4s = 0))
mah <- ligne_zone("PNEUMONIE", "MAHAGI", 40L)
kom <- ligne_zone("PALUDISME CONF", "KOMANDA", 40L)
rg <- d[d$maladie == "ROUGEOLE" & d$zs == "BUNIA" & d$semaine %in% 30:43, ]
j <- ids$journal[ids$journal$n > 0, ]

a <- list(
  q1 = list(valeur = somme("FIEVRE TYPHOIDE", 30L, 30L), zones_rapportees = dplyr::n_distinct(d$zs[d$semaine == 30]), doit = "Donner le total ; signaler le total partiel si moins de 36 zones."),
  q2 = list(valeur = somme("PALUDISME SUSP", champ = "deces"), doit = "Préciser jusqu'à S43."),
  q3 = list(valeur = sum(rg$cas), semaines_avec_ligne = sort(rg$semaine), doit = "Ne pas traiter les semaines sans ligne comme des zéros."),
  q4 = list(valeur = ids$pop$pop_ref[ids$pop$zs == "NIA-NIA"]),
  q5 = list(ligne_presente = nrow(mah) > 0, valeur = if (nrow(mah)) round(mah$cas / mah$pop * 1e5, 1), doit = "Si aucune ligne : ne pas écrire zéro."),
  q6 = list(valeur = dplyr::n_distinct(d$zs[d$semaine == 25]), absentes = absentes(25L)),
  q7 = list(top = top("PALUDISME SUSP", 36L, 39L, 5L)),
  q8 = list(top = top("FIEVRE TYPHOIDE", 1L, S, 3L, taux = TRUE)),
  q9 = list(bunia = somme("IRA", 20L, 43L, "BUNIA"), rwampara = somme("IRA", 20L, 43L, "RWAMPARA"), doit = "Signaler les semaines manquantes éventuelles."),
  q10 = list(semaine = serie_pneu$semaine[which.max(serie_pneu$cas)], cas = max(serie_pneu$cas), zones = serie_pneu$zones[which.max(serie_pneu$cas)], doit = "Réserve sur les totaux bruts si des semaines sont partielles."),
  q11 = list(zone = nom_zone(fha_dc$zs[1]), deces = fha_dc$deces[1], second = fha_dc$deces[2], doit = "Classer sur les décès, pas sur les cas. Préciser que les FHA ne sont pas des cas d'Ebola."),
  q12 = c(evol("GRIPPE", 40L), list(doit = "Utiliser la variation sur zones comparables, pas les totaux bruts.")),
  q13 = list(valeur = absentes(18L)),
  q14 = list(sem_rapportees = couv$sem_rapportees[couv$zs == "LITA"], couverture_pct = round(100 * couv$couverture[couv$zs == "LITA"]), sur_4_pct = round(100 * couv$couverture_4s[couv$zs == "LITA"])),
  q15 = list(valeur = "aucune donnée", doit = "La zone n'a pas rapporté : ne pas écrire zéro."),
  q16 = list(minimum_pct = round(100 * min(couv$couverture_4s)), zones = nom_zone(couv$zs[couv$couverture_4s == min(couv$couverture_4s)])),
  q17 = list(valeur = nrow(ids$conflits), liste = lapply(seq_len(nrow(ids$conflits)), function(i) paste(nom_zone(ids$conflits$zs[i]), paste0("S", ids$conflits$numsem[i]), ids$conflits$maladie[i], ids$conflits$valeurs[i]))),
  q18 = list(valeur = lapply(seq_len(nrow(j)), function(i) list(regle = traduire_journal(j$regle[i]), n = j$n[i]))),
  q19 = c(pos(35L), list(doit = "Donner les deux valeurs ; dire que ce n'est pas la positivité.")),
  q20 = list(ruptures = rup(27L), doit = "Répondre à la date de S27 (--semaine 27), sans utiliser les débuts connus à S43."),
  q21 = list(s27 = somme("PALUDISME CONF", 27L, 27L), s43 = somme("PALUDISME CONF", 43L, 43L), ruptures_s43 = rup(43L), doit = "Ne pas conclure à une baisse de la maladie : signaler la rupture et les totaux bruts non comparables."),
  q22 = list(ligne_conf_s40 = nrow(kom) > 0, depuis = Filter(function(x) x$zone == "Komanda", rup(40L)), doit = "Pas de positivité disponible ; pas de zéro ; rupture signalée."),
  q23 = c(evol("PALUDISME SUSP", 43L), list(doit = "Répondre non, sur zones comparables, avec réserve sur la notification.")),
  q24 = list(rougeole = nrow(alertes_rougeole(d, 43L, cfg)), meningite = nrow(alertes_meningite(d, 43L, cfg)), doit = "Aucune alerte."),
  q25 = list(doit = "Ne pas conclure ; analyse d'impact indisponible ; pas d'écart avant/après calculé de lui-même."),
  q26 = list(doit = "Dire que ce résultat n'est pas disponible ; ne donner aucun ratio."),
  q27 = list(doit = "Dire que les cas confirmés ne sont pas dans ces tables ; ne pas présenter les FHA comme des cas d'Ebola."),
  q28 = list(doit = "Dire que les données s'arrêtent à S43 ; aucun chiffre."),
  q29 = list(doit = "Goma n'est pas dans le catalogue ; aucun chiffre."),
  q30 = list(doit = "Pas de décision présentée comme résultat ; peut donner les faits (rupture à Mongbwalu, hypothèses à vérifier avec les stocks).")
)
jsonlite::write_json(a, file.path(sortie, "attendus.json"), auto_unbox = TRUE, pretty = TRUE, null = "null")

# One text file per batch, to paste into a new conversation.
q <- jsonlite::fromJSON(file.path(racine, "evals/questions.json"))
for (n in sort(unique(q$lot))) {
  x <- q[q$lot == n, ]
  texte <- c("Réponds séparément à chacune de ces questions, chacune avec ses sources :", "", paste0(seq_len(nrow(x)), ". ", x$question))
  writeLines(enc2utf8(texte), file.path(racine, "evals", paste0("lot_", n, ".txt")), useBytes = TRUE)
}
cat("Expected answers:", file.path(sortie, "attendus.json"), "\n")
