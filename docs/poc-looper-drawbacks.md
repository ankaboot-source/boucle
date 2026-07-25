## 2026-07-25T15:13:35Z — worker PR ankaboot-source/m3llm#174 needs manual review (issue #598)
- **Symptom:** worker completed PR ankaboot-source/m3llm#174 but no reviewer loop auto-triggered
- **Quick-win:** manual `looper review ankaboot-source/m3llm#174`
- **Root cause:** issue #598 — coordinator disabled (422 on self-review-request), worker doesn't label PRs

## 2026-07-25T15:13:35Z — worker PR ankaboot-source/m3llm#185 needs manual review (issue #598)
- **Symptom:** worker completed PR ankaboot-source/m3llm#185 but no reviewer loop auto-triggered
- **Quick-win:** manual `looper review ankaboot-source/m3llm#185`
- **Root cause:** issue #598 — coordinator disabled (422 on self-review-request), worker doesn't label PRs

## 2026-07-25T15:35:00Z — daemon not running
- **Symptom:** pgrep looperd empty
- **Quick-win:** restarted daemon
- **Root cause:** unknown (no systemd supervision)

## 2026-07-25T21:40:00Z — daemon not running
- **Symptom:** pgrep looperd empty
- **Quick-win:** restarted daemon
- **Root cause:** unknown (no systemd supervision)

## 2026-07-25T21:45:00Z — daemon not running
- **Symptom:** pgrep looperd empty
- **Quick-win:** restarted daemon
- **Root cause:** unknown (no systemd supervision)

