# Spec: Git dependency wording

**Date:** 2026-04-07
**Status:** Para implementar
**Affects:** README.md, site /learn/getting-started/install, /framework/architecture, /learn/safety/guard

---

## Problema

Git está listado como un requirement mas en una lista de bullets. No se explica que es la infraestructura base de nanostack. Un usuario podria pensar que git es opcional o que solo se usa para clonar el repo.

En realidad, 9 scripts dependen de git para funcionar. Sin git:
- No hay store path (artifacts se guardan relativo al git root)
- No hay phase gate (usa `git log` para timestamps)
- No hay scope drift (usa `git diff` para comparar plan vs realidad)
- No hay in-project safety (usa `git rev-parse` para detectar limites del repo)
- No hay contexto en artifacts (branch, changed files, recent commits)

## Principio de wording

Git no es un "requirement." Git es el runtime de nanostack. Explicar esto en una oracion, no en un parrafo. Ponerlo antes de los bullets de requirements, no dentro de ellos.

---

## Wording por superficie

### README.md — Requirements section

Antes:
```
### Requirements
- macOS, Linux or Windows (Git Bash or WSL)
- jq for artifact processing
- Git
- One of: Claude Code, Cursor, ...
```

Despues:
```
### Requirements

Nanostack runs on git. Artifacts are stored relative to the git root. The phase gate uses git history to verify sprint compliance. Scope drift compares planned files against `git diff`. Guard uses the repo boundary for in-project safety. Every project that uses nanostack must be a git repository.

- macOS, Linux or Windows (Git Bash or WSL)
- [Git](https://git-scm.com/)
- [jq](https://jqlang.github.io/jq/) for artifact processing (`brew install jq`, `apt install jq`, or `choco install jq`)
- One of: Claude Code, Cursor, OpenAI Codex, OpenCode, Gemini CLI, Antigravity, Amp, Cline
```

Git moves to first position in the list. It has a link. The paragraph above explains WHY, not just WHAT.

### Site: /learn/getting-started/install

Agregar un callout antes de los pasos de instalacion:

```
> nanostack requires git. Not just for installation — git is the runtime.
> Artifacts live at the git root. The phase gate reads git history.
> Scope drift compares against git diff. Your project must be a git repo.
```

Requirements list: misma estructura que el README. Git primero, con link.

### Site: /framework/architecture

En la seccion "3. Scripts are the glue", la linea sobre store-path.sh ya dice:

```
1. NANOSTACK_STORE env var (explicit override)
2. Git root .nanostack/ (project-local, default)
3. ~/.nanostack/ (fallback if not in a git repo)
```

Agregar antes de esta lista:

```
Git is the default anchor. All scripts resolve paths relative to `git rev-parse --show-toplevel`.
The phase gate reads `git log` for timestamp comparison. Scope drift reads `git diff`.
Artifact context includes branch, changed files and recent commits from git state.
The fallback (~/.nanostack/) exists but is not recommended — without git, phase gate,
scope drift and in-project safety are disabled.
```

### Site: /learn/safety/guard

En la descripcion de Tier 2 (In-project), agregar:

```
"In-project" means inside the git repository root. Guard uses `git rev-parse --show-toplevel`
to detect the boundary. Files outside the repo go to Tier 3 pattern matching.
Without git, Tier 2 is skipped entirely.
```

---

## Donde NO agregar wording

- Landing page hero: no. El hero es sobre el valor, no sobre requerimientos.
- /examples: no. Los ejemplos asumen que ya esta instalado.
- SKILL.md files: no. Los skills no necesitan explicar la infraestructura.
- Social media: no, salvo que se haga un post especifico sobre la arquitectura.

---

## Verificacion

Despues de implementar, grep por "requirement" y "install" en todas las superficies.
Cada mencion de requerimientos debe tener git explicito con la explicacion de que es el runtime, no un dependency mas.
