# Table builders shared by the exporter and its tests.

# Real data needs the agreement recorded by the user on this computer. Same rules as the Python tool.
verifier_accord <- function(chemin) {
  refus <- function(m) stop("Refused: ", m, " See accord.local.example.json.", call. = FALSE)
  if (!file.exists(chemin)) refus("no agreement file on this computer.")
  a <- jsonlite::read_json(chemin)
  if (!is.character(a$accorde_par) || !nzchar(trimws(a$accorde_par))) refus("accorde_par is empty.")
  lire_date <- function(x) tryCatch(as.Date(x, format = "%Y-%m-%d"), error = function(e) as.Date(NA))
  debut <- lire_date(a$date_accord)
  fin <- lire_date(a$echeance)
  if (is.na(debut) || is.na(fin)) refus("date_accord and echeance must be valid dates.")
  if (debut > Sys.Date()) refus("the agreement date is in the future.")
  if (fin < Sys.Date()) refus("the agreement has expired.")
  if (!isTRUE(a$couvre_envoi_a_anthropic_avec_abonnement)) refus("the agreement does not cover sending data to Anthropic with a subscription.")
  if (!isTRUE(a$reglage_entrainement_desactive)) refus("the model training setting is not confirmed as off.")
  if (length(a$personnes_autorisees) == 0) refus("personnes_autorisees is empty.")
  if (!identical(trimws(a$exclusions %||% ""), "")) refus("exclusions are not implemented yet: the tables would hold excluded data.")
  a
}

# Zones that reported both weeks AND have a line for this disease in both weeks. A zone in a
# malaria confirmation break reports, but has no confirmed line, so it does not feed the change.
zones_comparables_avec_ligne <- function(d, code, s) {
  rapportees <- function(x) unique(d$zs[d$semaine == x])
  communes <- intersect(rapportees(s), rapportees(s - 1L))
  ligne <- function(x) d$zs[d$maladie == code & d$semaine == x]
  length(Reduce(intersect, list(communes, ligne(s), ligne(s - 1L))))
}

construire_alertes <- function(d, s, cfg) {
  dd <- d[d$semaine <= s, ]
  dplyr::bind_rows(
    alertes_rougeole(dd, s, cfg) |> dplyr::transmute(zs, maladie = "ROUGEOLE", statut = "alerte", cas = cas_S, taux_100k = NA_real_),
    alertes_meningite(dd, s, cfg) |> dplyr::transmute(zs, maladie = "MENINGITE", statut, cas, taux_100k = taux)
  ) |> dplyr::mutate(zone = nom_zone(zs), .after = zs)
}
