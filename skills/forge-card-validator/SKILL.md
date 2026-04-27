---
name: forge-card-validator
description: Automated D-018 leak detection + template placeholder validation on the freshly registered HF model card. Hard fails the forge before the public flip if any branding leaks (NEXLESS, MGMO, SIF, internal client names) appear in the published README, OR if any unfilled template placeholders ({{...}}) made it through. Replaces the manual "review the card" step.
---

# forge-card-validator

## When this fires

**Phase position: CARD_VALIDATOR** — after REGISTER (which publishes private), before PUBLISH (the public flip). Hard-fails if checks fail; PUBLISH never runs.

## What it checks

1. Pull current README.md from the HF model repo
2. Case-sensitive grep for: `NEXLESS`, `MGMO`, `SIF`, `Intellident`, `ToothFerry`, `Dshamir`, `blucap`
3. Regex for unfilled template placeholders: `\{\{[a-z_]+\}\}`
4. Required sections present: `## Model Details`, `## Limitations`, `## How to Use`
5. Param count is a real number (not the placeholder cap)
6. License field set
7. base_model field set in YAML frontmatter

## Output (machine-readable)

```json
{
  "status": "pass" | "fail",
  "checks": {
    "d018_leaks": {"passed": true, "hits": []},
    "template_placeholders": {"passed": true, "hits": []},
    "required_sections": {"passed": true, "missing": []},
    "param_count_real": {"passed": true, "value": "1.5B"},
    "yaml_frontmatter": {"passed": true}
  }
}
```
