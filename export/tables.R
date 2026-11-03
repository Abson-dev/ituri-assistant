# Table builders shared by the exporter and its tests.

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
