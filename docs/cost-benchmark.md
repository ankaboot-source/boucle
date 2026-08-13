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

## Per-role cost, end to end

One feature flows through four roles: **triage** (analyze the issue, draft
the spec) → **worker** (implement, up to 3 iterations) → **reviewer** (verify
the preview, up to 3 iterations) → **e2e** (verify the live deployment). The
cost of one feature is the sum of all role invocations.

| Role | What it does | boucle | $/task | Claude Code | $/task |
| --- | --- | --- | ---: | --- | ---: |
| triage | analyze issue, draft spec | [GLM-5.2](https://z.ai/blog/glm-5.2) (intel 53) | $0.31 | Opus 5 (intel 63) | $2.34 |
| worker (×3) | implement | [DeepSeek V4 Flash 0731](https://artificialanalysis.ai/models/deepseek-v4-flash) (intel 52) | $0.03 | Sonnet 5 (intel 55) | $1.72 |
| reviewer (×3) | verify preview | DeepSeek V4 Flash 0731 (intel 52) | $0.03 | Sonnet 5 (intel 55) | $1.72 |
| e2e | verify live deployment | GLM-5.2 (intel 53) | $0.31 | Opus 5 (intel 63) | $2.34 |

Summing one pass through the loop (1 triage + 1 e2e + 3 worker + 3 reviewer):

| | boucle | Claude Code |
| --- | ---: | ---: |
| **Cost per feature** | **$0.80** | **$15.00** |
| Intelligence (triage / worker) | 53 / 52 | 63 / 55 |

### Published raw data (source of the $/task figures)

Each model runs the same 9-evaluation Intelligence Index suite. Artificial
Analysis publishes the total cost to run the full suite and the total output
tokens generated; the $/task figure is derived from these. Source pages:
[GLM-5.2](https://artificialanalysis.ai/models/glm-5-2),
[DeepSeek V4 Flash 0731](https://artificialanalysis.ai/models/deepseek-v4-flash),
[Kimi K3](https://artificialanalysis.ai/models/kimi-k3),
[Claude Opus 5](https://artificialanalysis.ai/models/claude-opus-5),
[Claude Sonnet 5](https://artificialanalysis.ai/models/claude-sonnet-5).

| Model | Intel | Total II cost | Output tokens | In $/1M | Out $/1M |
| --- | ---: | ---: | ---: | ---: | ---: |
| GLM-5.2 | 53 | $714.52 | 140M | $1.35 | $4.29 |
| DeepSeek V4 Flash 0731 | 52 | $72.03 | 210M | $0.14 | $0.28 |
| Kimi K3 | 60 | $2,425.11 | 130M | $3.00 | $15.00 |
| Claude Opus 5 | 63 | $3,836.05 | 100M | $5.00 | $25.00 |
| Claude Sonnet 5 | 55 | $4,010.51 | 300M | $2.00 | $10.00 |

Cost ratios grounded in these published totals (same benchmark suite):

| Pairing | Total II cost ratio |
| --- | --- |
| GLM-5.2 vs Opus 5 | 5.4× cheaper |
| DeepSeek V4 Flash 0731 vs Sonnet 5 | 55.7× cheaper |
| DeepSeek V4 Flash 0731 vs Opus 5 | 53.3× cheaper |
| GLM-5.2 vs Sonnet 5 | 5.6× cheaper |

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
Cost per issue is estimated as: 1 triage + 1 e2e + 5 worker iterations + 5
reviewer iterations (the default `BOUCLE_MAX_ITERATIONS=5`).

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
  advantage. The worker and reviewer run the most iterations (3 each), so
  boucle puts the cheapest model on the heaviest roles — where the cost
  saving compounds across iterations.
- **Triage** — the strategic role (issue analysis + spec). Three options:
  - **GLM-5.2** (intel 53): 84% of Opus 5, 7.5× cheaper. The current default.
  - **Kimi K3** (intel 60): 95% of Opus 5, 2.3× cheaper. Closes most of the
    gap for +$0.42/issue — a quality upgrade at marginal cost.
  - **DeepSeek** (intel 52): 83% of Opus 5, 78× cheaper. The budget option;
    loses 1 pt vs GLM-5.2 but drops the per-issue cost to $0.24 (62.5×
    cheaper than Claude Code).
- **e2e** — DeepSeek (52) vs GLM-5.2 (53) is a negligible −1 pt at 10×
  less cost. Routing e2e to DeepSeek is a clear win.

## Intelligence-adjusted cost (3-mode rework model)

The face-value $/feature assumes every pass through the loop ships. In
reality, a less intelligent model degrades quality in three distinct ways,
each with a different cost structure. We model them separately, mapping each
mode to the role(s) whose intelligence gap drives it, and weighting by
feature size.

### The three failure modes

| Mode | What happens | Driving role(s) | Cost structure |
| --- | --- | --- | --- |
| **A. Feature KO** | feature completely failed, redone from scratch | worker (Δ 5.5%) | geometric: `cost × 1/(1 − P_KO)` |
| **B. Extra iterations** | degraded spec/review → more back-and-forth in the loop | triage (Δ 15.9%) + reviewer (Δ 5.5%) | linear: `E[extra] × cost_per_iter` |
| **C. Bugs post-ship** | feature ships with defects → new bug issues | reviewer (Δ 5.5%) + e2e (Δ 15.9%) | additive: `E[bugs] × cost_per_feature` |

### Per-role intelligence gap (boucle default vs Claude Code)

| Role | Intel boucle | Intel Claude | Δ | Drives |
| --- | ---: | ---: | ---: | --- |
| triage | 53 | 63 | 15.9% | Mode B (spec iterations) |
| worker | 52 | 55 | 5.5% | Mode A (feature KO) |
| reviewer | 52 | 55 | 5.5% | Mode B (review iterations) + Mode C (missed bugs) |
| e2e | 53 | 63 | 15.9% | Mode C (missed deploy issues) |

### Feature size as a variable

The impact of the intelligence gap scales with feature complexity. We define
sensitivity factors per mode × size:

| Size | Example | s_A (KO) | s_B (iter) | s_C (bugs) |
| --- | --- | ---: | ---: | ---: |
| Small | typo, CSS fix, text | 0.1 | 0.5 | 0.2 |
| Medium | new component, page | 0.3 | 1.5 | 1.0 |
| Large | new section, refactor, multi-page | 0.6 | 3.0 | 3.0 |

### Formulas

```
Δ_role = 1 − (intel_boucle_model / intel_claude_equivalent)

Mode A — P_KO = Δ_worker × s_A
  cost_A = cost_per_feature × 1 / (1 − P_KO)

Mode B — E[extra_spec] = min(Δ_triage × s_B, 2)     [capped at MAX_ITER=3]
         E[extra_review] = min(Δ_reviewer × s_B, 2)
  cost_B = E[extra_spec] × (triage_cost + worker_cost)
         + E[extra_review] × (reviewer_cost + worker_cost)

Mode C — E[bugs] = (Δ_reviewer + Δ_e2e) × s_C
  cost_C = E[bugs] × cost_per_feature

Adjusted cost = cost_A + cost_B + cost_C
```

### Results — nominal scenario, boucle default (GLM-5.2 + DeepSeek)

| Size | Mode A | Mode B | Mode C | **Adjusted $/feature** | vs Claude Code |
| --- | ---: | ---: | ---: | ---: | ---: |
| Small | $0.81 | +$0.03 | +$0.03 | **$0.87** | 17.3× cheaper |
| Medium | $0.81 | +$0.09 | +$0.17 | **$1.07** | 14.0× cheaper |
| **Large** | **$0.83** | **+$0.17** | **+$0.51** | **$1.51** | **9.9× cheaper** |

Mode C (bugs) dominates on Large features (74% of the surcost), because the
e2e role has a 15.9% gap and each bug re-enters the full loop. Mode A (KO) is
negligible — the worker's 5.5% gap produces a near-zero P_KO. Mode B (extra
iterations) is moderate — the triage's 15.9% gap degrades the spec, but
extra iterations cost almost nothing at $0.03 each.

### Sensitivity — all configs, all sizes, pessimistic/nominal/optimistic

**boucle default (GLM-5.2 + DeepSeek) — base $0.80**

| Size | Pessimistic | Nominal | Optimistic |
| --- | ---: | ---: | ---: |
| Small | $0.95 (15.8×) | $0.87 (17.3×) | $0.83 (18.1×) |
| Medium | $1.31 (11.5×) | $1.07 (14.0×) | $0.94 (16.0×) |
| Large | $1.98 (7.6×) | $1.51 (9.9×) | $1.16 (13.0×) |

**boucle full DeepSeek — base $0.24**

| Size | Pessimistic | Nominal | Optimistic |
| --- | ---: | ---: | ---: |
| Small | $0.28 (52.8×) | $0.26 (57.9×) | $0.25 (60.3×) |
| Medium | $0.39 (38.4×) | $0.32 (46.9×) | $0.28 (53.5×) |
| Large | $0.59 (25.2×) | $0.45 (33.0×) | $0.35 (43.2×) |

**boucle Kimi K3 triage + DeepSeek — base $1.22**

| Size | Pessimistic | Nominal | Optimistic |
| --- | ---: | ---: | ---: |
| Small | $1.43 (10.5×) | $1.31 (11.5×) | $1.26 (11.9×) |
| Medium | $1.95 (7.7×) | $1.60 (9.4×) | $1.41 (10.6×) |
| Large | $2.94 (5.1×) | $2.26 (6.6×) | $1.74 (8.6×) |

### Break-even analysis

For boucle default ($0.80 base), the break-even vs Claude Code ($15.00) is
reached at a **18.8× cost multiplier**. The sensitivity factor `s_A` needed
to reach it is **17.4** — meaning each 1% of worker intelligence gap would
need to cause a 17.4% probability of complete feature failure. The nominal
`s_A` for a Large feature is 0.6 — **29× below break-even**. For Mode C,
`s_C` would need to be **83.2** (nominal Large: 3.0 — **28× below**).

No scenario, across any config, size, or sensitivity tier, crosses the
break-even. The worst case (Kimi K3, Large, pessimistic) remains **5.1×
cheaper** than Claude Code.

### What actually impacts quality at this tier

At the 52–63 intelligence range, the outcome of a loop is driven less by raw
model intelligence than by two structural factors:

- **Deterministic CI/CD gates** — spec approval, preview verification, and a
  SHA-anchored post-deploy e2e gate catch failures mechanically, regardless
  of the model's confidence. A less intelligent model that produces a wrong
  output is caught by the gate and reworked; a more intelligent model that
  produces a wrong output is caught the same way. The gate, not the model,
  decides what ships.
- **Specialized agents enriched with skills** — boucle's four roles
  (triage, worker, reviewer, e2e) each carry a focused prompt and a curated
  skill library (UI/UX, design, frontend engineering, codebase graph
  queries). A specialized agent with the right skill outperforms a generalist
  with higher raw intelligence on the task it was built for.

The implication: investing in better gates and richer skills yields more
quality per dollar than investing in a more intelligent model. The model
decides what to *attempt*; the gates and skills decide what *ships*.

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
