# Cost & quality benchmark

> All figures from [Artificial Analysis](https://artificialanalysis.ai) Intelligence Index v4.1.1
> (max-effort reasoning), retrieved 2026-08-09. Plan prices from
> [Ollama pricing](https://ollama.com/pricing) and
> [Claude pricing](https://claude.com/pricing) / [Anthropic support](https://support.claude.com/en/articles/11049741-what-is-the-max-plan).

## Per-task cost (Artificial Analysis, max-effort reasoning)

| Model | Intelligence | Cost per task | $/intel-pt |
| --- | ---: | ---: | ---: |
| [GLM-5.2](https://z.ai/blog/glm-5.2) | 53 | $0.31 | $0.0058 |
| [DeepSeek V4 Flash 0731](https://artificialanalysis.ai/models/deepseek-v4-flash) | 52 | $0.03 | $0.0006 |
| [Kimi K3](https://artificialanalysis.ai/models/kimi-k3) | 60 | ~$1.01¹ | $0.0168 |
| Claude Opus 5 | 63 | $2.34 | $0.0371 |
| Claude Sonnet 5 | 55 | $1.72 | $0.0313 |

¹ Estimated: total Intelligence Index eval cost $2425.11 ÷ ~2401 tasks
(inferred from DeepSeek: $72.03 / $0.03 per task). Not displayed as a figure
on the Artificial Analysis page; derived from the cost-per-task chart.

## Monthly plan comparison

| | boucle (Ollama) | Claude Code |
| --- | --- | --- |
| Cheapest usable plan | **Pro — $20/mo** | Pro — $20/mo (usage too low for an autonomous loop) |
| Recommended plan | **Max — $100/mo** (continuous agents, 10 concurrent) | **Max 20× — $200/mo** (20× Pro usage) |
| Capacity model | session limits reset every 5h, weekly every 7d; compute-weighted | usage limits, 5× or 20× Pro |
| Concurrency | Pro: 3 models · Max: 10 models | (not published) |
| Models included | GLM-5.2, DeepSeek V4 Flash 0731, Kimi K3, + 40k community | Opus 5, Sonnet 5, Haiku |
| Data retention | zero data retention, no training on prompts | Anthropic's standard policy |

Source: [Ollama pricing](https://ollama.com/pricing),
[Claude pricing](https://claude.com/pricing),
[Anthropic support — Max plan](https://support.claude.com/en/articles/11049741-what-is-the-max-plan)
(Max 5× = $100/mo, Max 20× = $200/mo).

## Configurations compared

Each configuration assigns a model per role (triage, e2e, worker, reviewer).
Cost per issue is estimated as: 1 triage + 1 e2e + 3 worker iterations + 3
reviewer iterations (the default `BOUCLE_MAX_ITERATIONS=3`).

### Role assignments

| Role | boucle actuelle | boucle Kimi+DeepSeek | boucle full DeepSeek | Claude Code |
| --- | --- | --- | --- | --- |
| triage | GLM-5.2 (53) | Kimi K3 (60) | DeepSeek (52) | Opus 5 (63) |
| e2e | GLM-5.2 (53) | DeepSeek (52) | DeepSeek (52) | Opus 5 (63) |
| worker | DeepSeek (52) | DeepSeek (52) | DeepSeek (52) | Sonnet 5 (55) |
| reviewer | DeepSeek (52) | DeepSeek (52) | DeepSeek (52) | Sonnet 5 (55) |

### Aggregated metrics

| Config | Intel avg | $/task avg | $/issue | vs Claude Code |
| --- | ---: | ---: | ---: | ---: |
| boucle actuelle (GLM-5.2 + DeepSeek) | 52.5 | $0.170 | $0.80 | 18.8× cheaper |
| boucle Kimi K3 triage + DeepSeek | 54.0 | $0.275 | $1.22 | 12.3× cheaper |
| boucle full DeepSeek | 52.0 | $0.030 | $0.24 | 62.5× cheaper |
| Claude Code (Opus 5 + Sonnet 5) | 59.0 | $2.030 | $15.00 | — |

## Key comparisons (triage role)

| Pairing | Intel delta | Cost ratio |
| --- | --- | --- |
| Kimi K3 vs GLM-5.2 | +7 pts (113%) | 3.3× more expensive |
| Kimi K3 vs Opus 5 | −3 pts (95%) | 2.3× cheaper |
| GLM-5.2 vs Opus 5 | −10 pts (84%) | 7.5× cheaper |
| DeepSeek vs GLM-5.2 (e2e) | −1 pt | 10× cheaper |
| DeepSeek vs Opus 5 (e2e) | −11 pts (83%) | 78× cheaper |

## Reading

The quality gap is real but asymmetric across roles:

- **Worker** — DeepSeek V4 Flash 0731 reaches 95% of Sonnet 5's intelligence
  (52 vs 55) at 57× less cost. Near-equal quality, overwhelming cost
  advantage. This role runs the most iterations, so the cost saving compounds.
- **Triage** — the strategic role (issue analysis + spec). Three options:
  - **GLM-5.2** (intel 53): 84% of Opus 5, 7.5× cheaper. The current default.
  - **Kimi K3** (intel 60): 95% of Opus 5, 2.3× cheaper. Closes most of the
    gap for +$0.42/issue — a quality upgrade at marginal cost.
  - **DeepSeek** (intel 52): 83% of Opus 5, 78× cheaper. The budget option;
    loses 1 pt vs GLM-5.2 but drops the per-issue cost to $0.24 (62.5×
    cheaper than Claude Code).
- **e2e** — DeepSeek (52) vs GLM-5.2 (53) is a negligible −1 pt at 10×
  less cost. Routing e2e to DeepSeek is a clear win.

## Trade-off summary

| Config | Triage quality | $/issue | Use case |
| --- | --- | --- | --- |
| full DeepSeek | intel 52 (lowest) | $0.24 (cheapest) | Minimal budget, sufficient quality — triage DeepSeek is near-equal to GLM (−1 pt) at 10× lower cost on that role |
| actuelle (GLM + DeepSeek) | intel 53 | $0.80 | Current default — GLM adds +1 pt on triage for 10× the cost of DeepSeek on that role |
| Kimi K3 triage + DeepSeek | intel 60 (highest) | $1.22 | Max triage quality — closes the gap vs Opus 5 (from −10 to −3 pts) for +$0.42/issue, still 12.3× cheaper than Claude Code |

The full-DeepSeek configuration ($0.24/issue, 62.5× cheaper than Claude Code)
is the cost floor, but triage at intel 52 is the weak link — it is the role
that analyzes the issue and produces the spec that guides everything else.
The Kimi K3 configuration is the inverse: it invests +$0.42/issue to gain +8
pts on the triage role (the strategic one), remaining 12.3× cheaper than
Claude Code. boucle's gates (human spec approval + live-preview verification)
compensate for the intelligence gap on any of the three configs — the model
decides what to attempt, the gates decide what ships.
