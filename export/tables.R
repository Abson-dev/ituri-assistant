# Table builders shared by the exporter and its tests.

construire_alertes <- function(d, s, cfg) {
  dd <- d[d$semaine <= s, ]
  dplyr::bind_rows(
    alertes_rougeole(dd, s, cfg) |> dplyr::transmute(zs, maladie = "ROUGEOLE", statut = "alerte", cas = cas_S, taux_100k = NA_real_),
    alertes_meningite(dd, s, cfg) |> dplyr::transmute(zs, maladie = "MENINGITE", statut, cas, taux_100k = taux)
  ) |> dplyr::mutate(zone = nom_zone(zs), .after = zs)
}
