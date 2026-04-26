# Plain-language contract for Guided profile

This is the wording contract for skills running in `profile == "guided"`. The purpose is to keep the same rigor a Professional sprint has while removing process jargon from the first screen the user sees.

The contract applies to **user-facing output**, not to skill instructions, internal logs, or artifact JSON. A SKILL.md may still say "save the artifact" in its instructions; the user must not see the word "artifact" in the message the skill prints.

## Hard rule

When `profile == "guided"`, the first screen the user sees may not contain any banned term from the table below. Use the translation. If a term has no good translation in the current context, omit it.

## Term table

| Internal term | Guided replacement |
|---|---|
| artifact | saved note, record, or omit |
| PR | "publish request" only if the user already has GitHub context; else omit |
| CI | automatic checks |
| branch | version |
| diff | changes |
| hook | safety check |
| phase | step |
| security audit | safety check |
| QA | test pass |
| scope drift | extra changes |

The list is intentionally short. Anything not on the list is allowed; the goal is to remove process language, not to dumb down rigor.

## Guided output skeleton

This file is the **single source of truth** for Guided output structure. `reference/session-state-contract.md` references this skeleton; if you find a second numbered list of Guided blocks anywhere else in the repo, that is a regression.

Every Guided phase output (think, plan, qa, ship, doctor, review, security) must include these four blocks in order, before any optional technical detail:

1. **Result.** One sentence: what the skill found or did, and whether it is safe to try. (When safety needs more than one sentence — e.g. "safe to try with these caveats" — split it onto a second short line, but keep it inside the Result block.)
2. **How to try.** The exact command or URL to see the result. One action.
3. **What was checked.** Two or three short bullets. Use plain verbs ("I tested", "I reviewed").
4. **What remains.** What this skill could not check. Use a plain bullet list. Examples: "I did not deploy this to the internet", "No probé el flujo de pago real".

Skills MAY include a short technical detail block AFTER the four blocks for users who want it, but the four blocks come first and they pass the banned-term grep.

## Spanish parity

When the project is local mode or the user is interacting in Spanish, the four blocks have a direct Spanish version:

1. **Resultado.**
2. **Como verlo.**
3. **Que revise.**
4. **Pendiente.**

Sprint 5 promotes this to a first-class surface across every skill output. Sprint 4 only requires that Spanish blocks, when present, follow the same banned-term rule (no "artifact", no "branch", etc.).

## Marking blocks for the CI grep

So the CI lint can verify the rule without false positives on prose ("scope drift is informational"), every Guided output block in a SKILL.md is fenced with a marker:

````markdown
<!-- guided-output:start -->
```
Resultado: ...
Como verlo: ...
Que revise: ...
Pendiente: ...
```
<!-- guided-output:end -->
````

The CI lint scans only inside `<!-- guided-output:start -->` ... `<!-- guided-output:end -->` blocks for banned terms. Outside the fence, banned terms are allowed (they are agent instructions, not user output).

## Examples

### /ship — guided close (English)

<!-- guided-output:start -->
```
Ready to try.

How to try:
1. Open index.html in your browser.

What was checked:
- The page loads.
- The main button responds.
- I did not find secrets in visible files.

What remains:
- I did not publish this to the internet.
- I did not check security on the dependencies.
```
<!-- guided-output:end -->

### /ship — guided close (Spanish)

<!-- guided-output:start -->
```
Listo para probar.

Como verlo:
1. Abri index.html en el navegador.

Que revise:
- La pantalla carga.
- El boton principal responde.
- No encontre secretos en archivos visibles.

Pendiente:
- No esta publicado en internet todavia.
- No revise la seguridad de las dependencias.
```
<!-- guided-output:end -->

### /qa — guided close

<!-- guided-output:start -->
```
The feature works.

How to try:
1. Run the command shown above and follow the prompts.

What was checked:
- The happy path completes.
- Error messages are readable.
- The output saves to the expected location.

What remains:
- I did not load-test it.
- I did not test on Windows.
```
<!-- guided-output:end -->

## What this contract does NOT do

- It does not change Professional output. Professional sprints keep findings, evidence, file paths, and exact commands.
- It does not block technical detail. Skills MAY include a fenced "Technical detail" block after the four Guided blocks for users who ask. The contract scans only the marked Guided block.
- It does not police skill instructions or comments. The grep target is the Guided fenced output, not the rest of the file.

## Where the contract lives

This file is the source of truth. Skills link to it. Tests link to it. If the term table changes, change it here first; do not duplicate the list across skills.
