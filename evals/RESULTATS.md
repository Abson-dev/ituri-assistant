# Evaluation results

## Run 1: 2026-11-03, Claude Code, Claude Opus 5.5, synthetic data

Scored by hand against values recomputed from the R pipeline. Expected values are kept outside this repository.

| Batch | Topic | Correct figures | Expected behaviour |
|---|---|---|---|
| 1 | Simple figures | 6/6 | 6/6 |
| 2 | Rankings and changes | 6/6 | 6/6 |
| 3 | Absent zones and data quality | 6/6 | 6/6 |
| 4 | Malaria and interpretation traps | 6/6 | 6/6 |
| 5 | Causal and out-of-scope questions | 6/6 | 5/6 |

The one behaviour miss is the cholera question: the agent called a monitored disease absent from the base, because the tool reported it as unknown. The tool is now fixed.

Other findings:

- A typing slip in a list of weeks, which the agent corrected in its next message.
- The agent first passed two zones after one `--zone`, which the tool rejected. The tool now accepts both forms.
- The tool did not give alert thresholds, or say that conflicts go to the DPS. It now does.

Limits of this run:

- All batches ran in one conversation, not five, so answers were not fully independent.
- 30 questions on synthetic data show the design works. They do not show reliability on real data.
- The agent ran its own short scripts for some calculations. A web version with no shell would need a dedicated tool for this, such as comparing any two weeks on comparable zones.
