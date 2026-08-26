<!-- boucle:triage v=1 -->

## TL;DR
{{tldr}}

## Analysis
{{analysis}}

## Draft acceptance criteria
- [ ] **Happy path** — Given {{context}}, When {{action}}, Then {{result}}
- [ ] **Edge case** — Given {{boundary}}, When {{action}}, Then {{result}}
- [ ] **Error state** — Given {{failure}}, When {{action}}, Then {{recovery}}
- [ ] **Non-functional** — Given {{constraint}}, When {{action}}, Then {{bar}}

## Must-haves
- **Truths** — {{truths}}
- **Artifacts** — {{artifacts}}
- **Key links** — {{key_links}}

## Non-goals
- {{non_goal_1}}
- {{non_goal_2}}

## Diagram *(mandatory when ## Metadata declares a structural impact; omit otherwise)*
{{diagram_caption}}

```mermaid
%%{init: {"theme":"base","themeVariables":{"background":"transparent","primaryColor":"#f5c842","primaryTextColor":"#0d1117","primaryBorderColor":"#c9a233","lineColor":"#a0a0b8","secondaryColor":"#fdf3d7","tertiaryColor":"#e8e6f5","clusterBkg":"#faf7f2","clusterBorder":"#c9a233","edgeLabelBackground":"#ffffff","fontFamily":"Sora, system-ui, sans-serif","fontSize":"14px"}}}%%
{{mermaid_body}}
```

<!-- boucle:diagram v=1 types={{diagram_types}} -->

## Recurring theme *(optional — omit if no prior instances found)*
🔁 Part of a recurring class (see #{{prior1}}, #{{prior2}}). Consider a root-cause fix, not a patch.

<!-- boucle:recurring v=1 refs={{prior1}},{{prior2}} -->

## Questions
{{questions}}

If no blocking questions, write "none" on its own line.

## Creative proposals
{{creative_proposals}}

## Consequences
{{consequences}}

## Metadata
<!-- boucle:impacts v=1 kinds={{impacts_kinds}} -->
<!-- boucle:files v=1 paths={{impacted_files}} -->
- **Impacts** — 🏗️ {{impacts_visible}}
- **Impacted files** — 📁 `{{impacted_files}}`
- **Size** — {{size}}
- **Validation** — {{validation}}
- **Disposition** — {{disposition}}
