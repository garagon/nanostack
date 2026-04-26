# /think Archetypes

Archetypes are a first-question lens. They change how `/think` opens the conversation, which examples it points at, and which preset it routes to internally. They do not change the workflow, the artifact contract, the brief gate, or any safety guarantee.

This file is the source of truth for the archetype set. `think/SKILL.md` reads these definitions; CI greps them; new archetypes land here first.

## Canonical Archetypes

Initial v1 set, derived from the four validated examples in the Examples Library:

| Archetype | Source example(s) | Primary user | Typical work | Default profile |
|---|---|---|---|---|
| `founder_validation` | `examples/starter-todo`, partial overlap with `examples/static-landing` | Non-technical founder or product owner | Validate a user-facing idea with the smallest useful version | guided |
| `cli_tooling` | `examples/cli-notes` | Technical user building command-line tools | Flags, commands, file IO, shell edge cases | professional |
| `api_backend` | `examples/api-healthcheck` | Backend / API developer | Endpoint behavior, HTTP semantics, logging, readiness, safety | professional |
| `landing_experience` | `examples/static-landing` | Founder, designer, marketer | Copy, hierarchy, conversion, visual QA, no-script safety | guided |

Reserved for future rounds: `mobile_app`, `data_workflow`, `infra_platform`, `ai_feature`.

`unknown` is a first-class value, not a placeholder for "could not pick". It means: detection ran, no archetype was confident enough, fall back to canonical `/think` flow without forcing a lens.

## Alias Map

User-facing aliases accepted on `--archetype=<value>` and `--type=<value>`. The skill normalizes to the canonical form before any other code path sees the value.

| Alias | Canonical |
|---|---|
| `founder` | `founder_validation` |
| `startup` | `founder_validation` |
| `nontechnical` | `founder_validation` |
| `non-technical` | `founder_validation` |
| `cli` | `cli_tooling` |
| `tool` | `cli_tooling` |
| `devex` | `cli_tooling` |
| `api` | `api_backend` |
| `backend` | `api_backend` |
| `server` | `api_backend` |
| `landing` | `landing_experience` |
| `design` | `landing_experience` |
| `marketing` | `landing_experience` |

Any other value falls back to `unknown` with a one-line warning. The warning lists `founder, cli, api, landing` (the short user-facing aliases), not the canonical underscored names.

## Detection Signals

Detection is deterministic. Each signal contributes a numeric weight; the archetype with the highest score and a clear margin over second place wins. Vague model intuition is never the only source.

### Priority order

1. Explicit `--archetype=<value>` or `--type=<value>` flag.
2. User answer to the one-question classifier (only when confidence is low).
3. Current path matches an example.
4. Strong project-file signal.
5. Prompt keyword score.
6. Session preference (`.archetype` field if `/nano-run` wrote one).
7. Fallback to `unknown`.

### Path signals

| Path fragment | Archetype | Confidence |
|---|---|---|
| `examples/starter-todo` | `founder_validation` | high |
| `examples/cli-notes` | `cli_tooling` | high |
| `examples/api-healthcheck` | `api_backend` | high |
| `examples/static-landing` | `landing_experience` | high |

### Project-file signals

| File signal | Archetype hint | Confidence when alone |
|---|---|---|
| Executable shell script + README mentions CLI | `cli_tooling` | high |
| `server.js`, `routes/`, OpenAPI spec, HTTP handlers | `api_backend` | high |
| Single `index.html`, no `package.json`, marketing-style copy | `landing_experience` | high |
| No code yet OR only a simple UI sandbox | `founder_validation` | medium |

### Prompt keyword signals

These are hints, not rules. Multiple keywords in one prompt accumulate up to a cap.

**`founder_validation`**: idea, validate, users, customers, landing, MVP, waitlist, conversion, non technical, founder, "will people use".

**`cli_tooling`**: CLI, command, flag, script, terminal, shell, notes.sh, stdin, stdout, file format, exit code.

**`api_backend`**: API, endpoint, HTTP, server, route, status code, healthcheck, readiness, logging, auth, webhook, database.

**`landing_experience`**: landing, hero, copy, headline, pricing, testimonial, CTA, layout, mobile, visual, design, conversion.

### Scoring

| Signal | Weight |
|---|---|
| Explicit flag | force canonical (no scoring) |
| Path signal | +5 |
| Project-file signal | +3 |
| Strong keyword match | +2 |
| Weak keyword match | +1 |

Decision rule:

- Top score `>= 5` AND at least 2 points above second place: select with **high** confidence.
- Top score `>= 3` AND at least 1 point above second place: select with **medium** confidence.
- Otherwise: in Guided profile, ask one classifier question; in Professional profile, continue with `unknown` unless the user explicitly asks for guidance.

## One-question Classifier

Used at most once per `/think` run, only when no explicit flag is set and detection confidence is low.

**Guided wording** (Spanish, no internal labels):

```
Para ayudarte mejor, esto se parece mas a:
1. validar una idea o feature chica,
2. mejorar una pantalla o landing,
3. agregar algo tecnico a una herramienta,
4. cambiar una API o backend?
```

**Professional wording**:

```
Which lens should I use: founder_validation, landing_experience, cli_tooling, or api_backend?
```

If the user ignores the question and provides more context instead, infer again. If still unclear, fall back to `unknown` and the canonical `/think` flow. The classifier never repeats and never blocks autopilot when the brief gate fields are otherwise complete.

## Lenses

Each lens defines the primary opening question, diagnostic emphasis, key risks, recommended first wedge, and the example reference saved into the artifact. It does NOT define a separate workflow.

### founder_validation

**Source truth:** `examples/starter-todo` (primary), `examples/static-landing` (overlap for visual founder validation).

**Primary question (Professional):** Who has this problem today, and what are they doing without your product?
**Primary question (Guided):** Quien necesita esto hoy y como lo resuelve ahora?

**Diagnostic emphasis:** target-user specificity, current workaround, smallest useful version, manual delivery test, avoid overbuilding.

**Key risks:** nobody has the problem; solving the wrong symptom; building infrastructure before demand; trying to serve too many users at once.

**Recommended first wedge:** one user, one behavior, one screen or local flow, no accounts/integrations unless required.

**Example reference saved to artifact:**

```json
{
  "name": "starter-todo",
  "path": "examples/starter-todo",
  "why_relevant": "Safe non-technical sandbox for turning vague feature requests into the smallest useful behavior."
}
```

**Do:** push on "who exactly", ask what proves this matters, prefer a manual or local first test.
**Do not:** turn every idea into a startup pitch; force YC-style aggressiveness on Guided users; ask for TAM, market size, or persona deck in v1.

### cli_tooling

**Source truth:** `examples/cli-notes`.

**Primary question (Professional):** What command should exist, what should it print, and what must not break?
**Primary question (Guided):** Que comando queres correr, que deberia mostrar, y que no puede romperse?

**Diagnostic emphasis:** exact command shape, input/output contract, storage format, exit codes, shell quoting, backward compatibility.

**Key risks:** corrupting local files; ambiguous command syntax; unsafe shell expansion; breaking existing commands; adding dependencies for a tiny tool.

**Recommended first wedge:** one command or one flag, one file, no storage migration unless necessary, test current commands still work.

**Example reference saved to artifact:**

```json
{
  "name": "cli-notes",
  "path": "examples/cli-notes",
  "why_relevant": "Validated CLI sandbox for command shape, file IO, shell safety, and regression checks."
}
```

**Do:** ask for exact CLI examples, ask how success is tested from terminal, preserve existing commands.
**Do not:** add frameworks; convert a small shell tool to a full app without a strong reason; ignore quoting, empty input, missing files, or exit codes.

### api_backend

**Source truth:** `examples/api-healthcheck`.

**Primary question (Professional):** What observable API behavior should change, and how will we prove it with a real request?
**Primary question (Guided):** Que respuesta deberia dar el servidor, y como la probamos con una llamada real?

**Diagnostic emphasis:** endpoint semantics, HTTP method and status, response body, backward compatibility, logging safety, readiness/liveness truthfulness, auth and secret boundaries.

**Key risks:** endpoint lies about state; logs leak sensitive data; status code inconsistency; breaking old clients; adding dependencies without need; tests only read code and never send a request.

**Recommended first wedge:** one endpoint or one behavior, real curl probe, no new dependency unless justified, preserve existing paths.

**Example reference saved to artifact:**

```json
{
  "name": "api-healthcheck",
  "path": "examples/api-healthcheck",
  "why_relevant": "Validated backend sandbox for HTTP behavior, status codes, logging risk, and real probes."
}
```

**Do:** ask for request and response, ask what existing behavior must keep working, force real probe in QA handoff.
**Do not:** accept "add endpoint" without status and body; let logging include secrets or full auth headers; let readiness endpoints lie.

### landing_experience

**Source truth:** `examples/static-landing`.

**Primary question (Professional):** Who lands here, what do they need to understand in five seconds, and what should they do next?
**Primary question (Guided):** Quien llega a esta pagina, que tiene que entender rapido, y que accion deberia tomar?

**Diagnostic emphasis:** audience, comparison set, headline clarity, proof, CTA, mobile layout, no third-party scripts, visual QA.

**Key risks:** prettier but less clear; fake social proof; CTA mismatch; adding trackers/scripts; layout breaks on mobile; pricing/copy commits too early.

**Recommended first wedge:** one section or hero rewrite, keep layout unless problem is layout, no external assets/scripts by default, test mobile.

**Example reference saved to artifact:**

```json
{
  "name": "static-landing",
  "path": "examples/static-landing",
  "why_relevant": "Validated landing-page sandbox for copy, visual hierarchy, conversion, and no-script safety."
}
```

**Do:** ask what the visitor compares this to, ask what must be understood in five seconds, treat copy as product behavior.
**Do not:** add vague testimonials; add analytics or third-party scripts; optimize for aesthetics while losing clarity.

## Mode and Preset Interaction

### Modes

Existing `/think` modes (Founder, Startup, Builder) stay. Archetypes are orthogonal: archetype selects the lens, mode selects challenge intensity.

| Archetype | Default mode | Notes |
|---|---|---|
| `founder_validation` | Startup | Use Founder only when the user explicitly asks for hard pushback or pitch stress test. |
| `cli_tooling` | Builder | Respect stated technical pain. Focus on smallest safe behavior. |
| `api_backend` | Builder | Focus on observable behavior, failure modes, and safety. |
| `landing_experience` | Startup | Challenge audience, message, and conversion premise. |
| `unknown` | Existing detection | No behavior change. |

In Guided profile, never print "Startup mode" or "Builder mode" to the user.

### Presets

Presets remain explicit user choice. Archetypes only suggest an internal default lens when no explicit `--preset` is provided.

| Archetype | Internal lens when no `--preset` |
|---|---|
| `founder_validation` | `yc` or `garry`, softened by Guided profile |
| `cli_tooling` | `devex` |
| `api_backend` | `eng` |
| `landing_experience` | `design` |
| `unknown` | `default` |

Rules:

- Explicit `--preset` always wins over the archetype's default lens.
- The lens changes communication and diagnostic emphasis. It does not change the artifact schema.
- It does not skip required phases.
- Preset files are never dumped to the user (PR #170 lock applies).
- Guided output never says "preset".

## Output Rules

### Banned terms in Guided first screen

Same banned set as `reference/plain-language-contract.md`, plus three archetype-specific ones:

- The word `archetype` itself.
- `preset`.
- `mode`.

The Guided first screen names what `/think` will do in plain language. It never says "I selected the founder_validation archetype". It says, for example: "Voy a empezar preguntando quien necesita esto hoy."

### Banned in any profile

`always blocks`, `guaranteed blocks`, `all agents enforce`, `hard-blocks on every agent` (per `start/SKILL.md`'s capability-honesty rule). Archetypes do not override capability honesty.

### Canonical Guided output per archetype

Each archetype's Guided four-block output. Copy these shapes verbatim except for the variable parts. Lint scans inside the fences to verify no banned term leaks.

#### founder_validation (Spanish)

<!-- guided-output:start -->
```
Resultado: Vale la pena probar una version mas chica antes de construir todo.

Como verlo:
1. Cuando me digas "dale", lo convierto en un plan concreto.

Que revise:
- Hay un usuario claro.
- La primera version puede probarse sin cuentas, pagos ni integraciones.
- El mayor riesgo es que estemos resolviendo el sintoma equivocado.

Pendiente:
- No validamos todavia si mas personas tienen este dolor.
- No medimos retencion ni conversion.
```
<!-- guided-output:end -->

#### cli_tooling

<!-- guided-output:start -->
```
Result: The feature is small enough if it stays to one command and preserves the existing file format.

How to try:
1. Run the current command first, then run the new command after the change.

What was checked:
- The command shape is clear.
- Existing behavior has to keep working.
- The main risk is corrupting local data.

What remains:
- I have not tested the command yet.
- Windows shell behavior may need a separate check.
```
<!-- guided-output:end -->

#### api_backend

<!-- guided-output:start -->
```
Result: The safest first version is one endpoint with a real request check.

How to try:
1. Start the server and call the endpoint with curl.

What was checked:
- The response shape is clear.
- Existing status codes must keep working.
- Logging and headers are the main safety risks.

What remains:
- I have not load-tested it.
- I have not checked production deployment settings.
```
<!-- guided-output:end -->

#### landing_experience (Spanish)

<!-- guided-output:start -->
```
Resultado: Primero conviene aclarar el mensaje, no agregar mas secciones.

Como verlo:
1. Abrir la pagina y leer el hero como si fueras un visitante nuevo.

Que revise:
- El visitante tiene que entender el producto en cinco segundos.
- La accion principal tiene que ser obvia.
- No hace falta agregar scripts ni trackers para esta prueba.

Pendiente:
- No medimos conversion real.
- No probamos con usuarios externos.
```
<!-- guided-output:end -->

## Artifact Fields

The five archetype fields the `/think` artifact may include in `summary`:

| Field | Type | When to set |
|---|---|---|
| `archetype` | enum: `founder_validation` / `cli_tooling` / `api_backend` / `landing_experience` / `unknown` | Always when archetype detection ran. Save `unknown` for fallback. |
| `archetype_confidence` | enum: `high` / `medium` / `low` / `user_selected` | `user_selected` when explicit flag or classifier answer; else `high`/`medium`/`low` per the scoring rule. |
| `archetype_source` | enum: `explicit_flag` / `user_answer` / `detected_from_prompt` / `detected_from_files` / `session` / `fallback` | Names the signal that won. |
| `archetype_reason` | string | One-line human-readable explanation. e.g. `"Current project has server.js and the prompt references an endpoint."` |
| `example_reference` | object with `name`, `path`, `why_relevant`, or `null` | Set when the archetype maps to a concrete example. `unknown` archetype may save `example_reference: null`. |

The brief gate **does not** require any of these. A future skill may consume them; today's skills fall back to canonical neutrality when they are missing.

## Brief gate invariant

The autopilot brief gate (Phase 6.6 of `think/SKILL.md`) checks five fields: `value_proposition`, `target_user`, `narrowest_wedge`, `key_risk`, `premise_validated`. It does not check `archetype`. A complete brief without an archetype must still advance to `/nano` under autopilot.

This is a hard rule. The CI lint job `think-archetype-brief-gate` enforces it.
