# Custom Stack Templates

Working examples of multi-skill stacks you can copy and adapt. Sister to `examples/custom-skill-template/`, which shows a single skill in isolation; this folder shows how multiple skills compose into a domain workflow.

A stack is a set of custom skills plus a `phase_graph` that wires them into the rest of the sprint. Each skill saves artifacts, reads upstream artifacts, and lets `conductor/bin/sprint.sh` schedule it. The framework contract those skills inherit lives in [`reference/custom-stack-contract.md`](../../reference/custom-stack-contract.md). The spec for this round of examples lives in [`reference/custom-stack-examples-technical-spec.md`](../../reference/custom-stack-examples-technical-spec.md).

## Available stacks

| Stack | What it does | When to copy |
|---|---|---|
| [`compliance-release/`](compliance-release/) | License audit + privacy hygiene + release-readiness composer that gates `/ship` | You ship code that may include third-party licenses or collect personal data, and you want a deterministic release-decision step before `/ship`. |

More stacks land here as they prove out the framework. The first one (`compliance-release/`) is the reference shape: match its `stack.json` schema and README structure when adding new stacks.

## How a stack is structured

```
<stack-name>/
  README.md      # who this stack is for, install steps, expected evidence
  stack.json     # manifest with kind: "custom_stack_example"
  skills/
    <skill-1>/
      SKILL.md
      agents/openai.yaml
      bin/<work>.sh
      bin/smoke.sh
    <skill-2>/...
    <skill-3>/...
```

The `stack.json` is an **example manifest**, not a project-level Nanostack stack-preferences file. The `kind: "custom_stack_example"` field makes the distinction explicit so tooling can validate.

## Contract for a new stack

Before opening a PR with a new stack, run:

```bash
ci/check-custom-stack-examples.sh
```

It validates the manifest schema, the README structure, the skill folder shape, the absence of committed runtime artifacts, and `bash -n` on every helper. The runtime contract for the example stack is in `ci/e2e-custom-stack-examples.sh` (15 cells, 51 assertions on a real `/tmp` project).

## What's covered

- **Manifest + structural lint**: every stack file shape and skill folder layout, validated by `ci/check-custom-stack-examples.sh` (49 checks).
- **Skill behavior**: license audit (npm/pip/go classifier), privacy hygiene (collection signals + privacy-note resolution), release-readiness composer (5-upstream rollup with TAMPERED detection). Each skill has a `bin/smoke.sh` that exercises real cases on a `/tmp` project.
- **Runtime install + journey**: scaffold the stack from `bin/create-skill.sh --from`, save artifacts, resolve, journal, analytics, discard, conductor scheduling — all proven by `ci/e2e-custom-stack-examples.sh`.

Each stack documents its own status and install path on its README.
