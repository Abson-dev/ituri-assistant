# Ituri Assistant

Question-and-answer agent for the Ituri epidemiological surveillance data. Work in progress, on synthetic data only.

The design is inspired by [eurostat-assistant](https://github.com/ainergy-hub/eurostat-assistant): the model chooses data through limited tools, and the server validates what is published.

## Status

| Step | Content | State |
|---|---|---|
| 1 | Export tables from the R pipeline | Done |
| 2 | Read-only tools and a Claude Code skill | Done |
| 3 | Evaluation on 30 questions | Done, see `evals/RESULTATS.md` |
| 4 | Password-protected web app, with the Claude API | To do |
| 5 | Real data | Lock ready; off until the agreement file is filled in, then a new evaluation |

## Use the skill

Open this folder in Claude Code and ask a question about the surveillance data, for example: "Which zones were most affected by acute respiratory infections over the last four weeks?"

Run the export first. The skill is in `.claude/skills/ituri-surveillance/`. A Claude subscription covers it within its usage limits, with no API key.

The tools use the Python standard library only, have no network access, and refuse any export that is not marked as synthetic. The data they return is still sent to Anthropic as part of the conversation.

```
python .claude/skills/ituri-surveillance/scripts/ituri.py situation
python .claude/skills/ituri-surveillance/scripts/ituri.py serie --maladie IRA --zone BUNIA --de 30 --a 43
```

## Tests

No model call or API key is needed.

```
python -m unittest discover -s tests
Rscript export/tests/test_parite_outils.R --pipeline="<path to the pipeline>"
```

The second command compares the tools with the pipeline across diseases, zones and weeks.

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

## Evaluation

`evals/questions.json` holds 30 questions, split into five batches (`evals/lot_1.txt` to `lot_5.txt`). Paste each batch into a new Claude Code conversation.

`evals/attendus.R` computes the expected answers from the R pipeline, without the Python tools. It refuses to write them inside this repository, because the agent under test can read this folder.

## Data rules

- No real data in this repository, and none sent to a model without written agreement from MSF and the DPS.
- Real data stays on this computer's disk, but a Claude subscription runs the model at Anthropic: the questions and every row the agent reads are sent there.
- To turn real data on, copy `accord.local.example.json` to `accord.local.json`, fill it in, and run `Rscript export/exporter.R --pipeline="<path>" --reelles`. Git ignores that file. The tools refuse real data if it is missing, incomplete or expired, and they never fall back silently to synthetic data. Delete the file to turn real data off.
- The impact analysis, marked as not for release, is out of scope for now.
