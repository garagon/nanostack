# Review Checklist

Reference checklist for structural review. Skip sections that don't apply.

## Logic & Correctness
- [ ] All branches return/handle correctly (if/else, switch, match)
- [ ] Loop bounds are correct (off-by-one, empty collections, single element)
- [ ] Null/nil/undefined handled at system boundaries (API responses, DB results, user input)
- [ ] Error paths don't swallow errors silently
- [ ] Async operations have proper error handling and cancellation
- [ ] Type conversions are explicit and checked (string→int, float→int, etc.)

## State & Data
- [ ] Mutable shared state is protected (locks, atomic operations, or immutability)
- [ ] Database transactions cover the full unit of work (no partial commits)
- [ ] Cache invalidation is correct (what updates the cache? what if it's stale?)
- [ ] File handles, connections, and resources are closed/released on all paths

## API & Interface
- [ ] Public APIs validate input at the boundary
- [ ] Error responses are informative (not "something went wrong")
- [ ] Breaking changes are intentional and documented
- [ ] Rate limiting, pagination, and timeouts are considered for external calls

## Security (quick pass)
- [ ] No secrets, tokens, or credentials in code or config committed to repo
- [ ] User input is sanitized before use in queries, commands, or HTML
- [ ] File paths from user input are validated against traversal
- [ ] Authentication/authorization checks are present on new endpoints
- [ ] Logging does not include sensitive data (passwords, tokens, PII)

## Tests
- [ ] Tests cover the behavior change, not just the code change
- [ ] Edge cases from the change are tested (empty, nil, boundary values)
- [ ] Tests are deterministic (no time-dependent, order-dependent, or flaky assertions)
- [ ] Test names describe the scenario, not the implementation

## Deployment
- [ ] Database migrations are backward-compatible (can roll back without data loss)
- [ ] Feature flags or gradual rollout for risky changes
- [ ] Monitoring/alerting covers the new behavior
- [ ] Config changes are documented
