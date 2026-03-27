# Conflict Precedents

Known conflicts between skills with pre-defined resolutions. Check this table before resolving a new conflict. If the conflict is not listed, resolve it and add it.

## Error Messages: Usability vs Security

| ID | /review says | /security says | Tension | Resolution |
|----|-------------|----------------|---------|------------|
| CP-001 | "Error messages are too vague, add detail" | "Don't expose internals in errors" | Complementary | **Structured errors**: error code + generic message to user, full details to server logs. Both win. |
| CP-002 | "Log request/response for debugging" | "Don't log sensitive data (PII, tokens)" | Scope | **Segment**: log structure (method, path, status) but redact body. Use an allowlist of loggable fields. |

## Validation: Simplicity vs Defense

| ID | /review says | /security says | Tension | Resolution |
|----|-------------|----------------|---------|------------|
| CP-003 | "Remove redundant validation, simplify" | "Defense in depth, keep the layers" | Tradeoff | **Security wins at trust boundaries**: validate at every boundary (API input, DB query, template render). Within the same boundary, /review wins. Don't duplicate. |
| CP-004 | "This helper is over-engineered for a single use" | "The helper sanitizes input, don't remove it" | Complementary | **Keep the helper** but document why it exists. If it sanitizes, it's not over-engineering. It's security. |

## Testing: Coverage vs Speed

| ID | /qa says | /review says | Tension | Resolution |
|----|---------|-------------|---------|------------|
| CP-005 | "Add tests for every edge case" | "Too many tests make the code hard to refactor" | Tradeoff | **Test behavior, not implementation**. Many tests are fine if they test observable behavior. Tests that test internals are the ones that block refactors. |
| CP-006 | "Types make the test setup too verbose" | "Strict type safety across the codebase" | Temporal | **Types now, helpers later**. Keep strict types. If the setup is verbose, create test factories/fixtures in a separate PR. |

## Scope: Iteration vs Atomicity

| ID | /nano says | /review says | Tension | Resolution |
|----|-----------|-------------|---------|------------|
| CP-007 | "Ship incremental, 3 small PRs" | "These changes are atomic, don't split" | Tradeoff | **Atomicity wins if there's real coupling**. If the system breaks with a subset of the changes, it's one PR. If each subset is independent and deployable, split. Test: can you rollback one PR without breaking the others? |
| CP-008 | "Add feature X to the scope" | "Scope creep. File a separate issue" | Tradeoff | **/review wins by default**. Scope additions during implementation are almost always scope creep. The exception: you discovered X is a prerequisite of what was planned (not "nice to have" but "breaks without it"). |

## Observability vs Privacy

| ID | /qa says | /security says | Tension | Resolution |
|----|---------|----------------|---------|------------|
| CP-009 | "Add more logging to reproduce bugs" | "Excessive logging exposes sensitive data" | Complementary | **Structured logging with levels**: DEBUG for development (verbose, can include data), INFO for prod (events only, no data), ERROR with sanitized context. Never log tokens, passwords, or PII at any level. |

## Performance vs Correctness

| ID | /review says | /security says | Tension | Resolution |
|----|-------------|----------------|---------|------------|
| CP-010 | "Cache this expensive operation" | "Cache invalidation is an attack vector" | Scope | **Cache with short TTL and no sensitive data**. Cache public queries: yes. Cache auth decisions: no (TOCTOU). Cache user data: only with invalidation on write. |

---

## How to add a precedent

1. Assign sequential ID: `CP-NNN`
2. Document both sides of the conflict with quotes from the skill
3. Classify the tension: Complementary, Tradeoff, Scope, Temporal
4. Write the resolution as an applicable rule, not a specific case
5. If the resolution depends on context, document the contexts
