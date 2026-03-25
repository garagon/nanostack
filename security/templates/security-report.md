# Security Audit Report

**Project:** {{project name}}
**Date:** {{date}}
**Auditor:** Claude Code + /security skill
**Scope:** {{what was audited — full codebase, specific PR, specific module}}

---

## Executive Summary

**Overall Risk Level:** {{Critical / High / Medium / Low}}

| Severity | Count |
|----------|-------|
| Critical | {{n}} |
| High | {{n}} |
| Medium | {{n}} |
| Low | {{n}} |

{{1-3 sentence summary of the most important findings}}

---

## Findings

### {{FINDING-001}}: {{Title}}

| Field | Value |
|-------|-------|
| **Severity** | {{Critical / High / Medium / Low}} |
| **Category** | {{OWASP category, e.g., A03: Injection}} |
| **Location** | `{{file_path}}:{{line_number}}` |
| **STRIDE** | {{Spoofing / Tampering / Repudiation / Info Disclosure / DoS / Elevation}} |

**Description:**
{{What the vulnerability is and why it matters}}

**Proof of Concept:**
```
{{How to exploit it — specific input, request, or scenario}}
```

**Vulnerable Code:**
```{{language}}
{{the vulnerable code snippet}}
```

**Fix:**
```{{language}}
{{the fixed code}}
```

---

<!-- Repeat for each finding -->

## Dependency Audit

| Package | Version | Severity | CVE | Action |
|---------|---------|----------|-----|--------|
| {{pkg}} | {{ver}} | {{sev}} | {{cve}} | {{update to X / remove / accept risk}} |

## Threat Model Summary

| Component | S | T | R | I | D | E | Notes |
|-----------|---|---|---|---|---|---|-------|
| {{component}} | {{✅/⚠️/❌}} | {{✅/⚠️/❌}} | {{✅/⚠️/❌}} | {{✅/⚠️/❌}} | {{✅/⚠️/❌}} | {{✅/⚠️/❌}} | {{key concern}} |

Legend: ✅ Mitigated | ⚠️ Partial | ❌ Unmitigated

## Recommendations

### Immediate (fix before shipping)
1. {{recommendation}}

### Short-term (fix within sprint)
1. {{recommendation}}

### Long-term (track as tech debt)
1. {{recommendation}}
