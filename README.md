# Ituri Assistant

Question-and-answer agent for the Ituri epidemiological surveillance data. Work in progress, on synthetic data only.

The design is inspired by [eurostat-assistant](https://github.com/ainergy-hub/eurostat-assistant): the model chooses data through limited tools, and the server validates what is published.

## Status

| Step | Content | State |
|---|---|---|
| 1 | Export tables from the R pipeline | Done |
| 2 | Command-line agent, with the Claude API | To do |
| 3 | Evaluation on about 30 questions | To do |
| 4 | Password-protected web app | To do |
| 5 | Real data, after written agreement from MSF and the DPS | Blocked |

## Export the tables

Requires R and a local copy of the surveillance pipeline, [ituri-situation-epidemiologique](https://github.com/Abson-dev/ituri-situation-epidemiologique), with its packages installed.

```
Rscript export/exporter.R --pipeline="<path to the pipeline>"
Rscript export/tests/test_export.R --pipeline="<path to the pipeline>"
```

Files go to `data/synthetic/`, which Git ignores. The exporter forces synthetic mode and refuses any other source.

| Table | Content |
|---|---|
| `observations` | Cases and deaths by zone, week and disease |
| `rapportage` | Reporting coverage of each zone, as of each week |
| `ruptures` | Zones with an abrupt loss of malaria confirmation, as of each week |
| `positivite` | Confirmed / suspected ratio in the province, as of each week |
| `evolutions` | Change from the previous week, on comparable zones |
| `alertes` | Measles and meningitis thresholds crossed |
| `journal`, `conflits` | Cleaning log and records to arbitrate with the DPS |
| `catalogue.json` | Zones, diseases, weeks and data source |

Indicators that depend on rules are computed by the pipeline, never by the assistant, so its figures match the dashboard and the reports.

## Data rules

- No real data in this repository, and none sent to a model without written agreement from MSF and the DPS.
- The impact analysis, marked as not for release, is out of scope for now.
