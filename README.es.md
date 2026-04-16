<h1 align="center">Nanostack</h1>
<p align="center">
  Convertí a tu agente de IA en un equipo de ingeniería que cuestiona el alcance, planifica, revisa, prueba, audita y ships.<br>
  Un sprint. Minutos, no semanas.
</p>

<br>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue.svg" alt="License"></a>
  <a href="https://github.com/garagon/nanostack/stargazers"><img src="https://img.shields.io/github/stars/garagon/nanostack?style=flat" alt="GitHub Stars"></a>
</p>

<p align="center">
  <strong>English version (canonical):</strong> <a href="README.md">README.md</a>
</p>

<p align="center">
  <a href="#instalacion">Instalación</a> &middot;
  <a href="#el-sprint">El sprint</a> &middot;
  <a href="#autopilot">Autopilot</a> &middot;
  <a href="#guard">Guard</a> &middot;
  <a href="#problemas-comunes">Problemas</a>
</p>

---

> **Nota:** la versión en inglés ([README.md](README.md)) es la canónica. Si encontrás divergencias o algo desactualizado en este documento, por favor abrí un issue.

Inspirado en [gstack](https://github.com/garrytan/gstack) de [Garry Tan](https://x.com/garrytan). 13 skills. Cero dependencias. Cero build step.

Funciona con Claude Code, Cursor, OpenAI Codex, OpenCode, Gemini CLI, Antigravity, Amp y Cline.

## Instalación

### Recomendado

```bash
npx create-nanostack
```

Un solo comando. Detecta tus agentes, instala todo, corre setup. Funciona con Claude Code, Cursor, Codex, Gemini CLI, Amp, Cline, OpenCode y Antigravity.

Después corré `/nano-run` en tu agente para configurar el proyecto a través de una conversación.

### Activación según el agente

Después del install, según tu agente:

| Agente | Acción |
|--------|--------|
| Claude Code | Listo. Escribí `/nano-help` para ver los comandos. |
| Cursor | Cerrá Cursor y abrílo de nuevo, después escribí `/nano-help`. |
| Codex | Corré `codex` en una terminal nueva. |
| OpenCode | Reiniciá tu sesión de OpenCode. |
| Gemini CLI | Corré `gemini` en una terminal nueva. |

### Probar primero sin riesgo

¿Querés probar antes de tocar tu proyecto real? `examples/starter-todo/` es una app TODO chica con tres ideas para arrancar. Ver [`examples/starter-todo/README.md`](examples/starter-todo/README.md).

### Requisitos

- [Git](https://git-scm.com/)
- [jq](https://jqlang.github.io/jq/) (`brew install jq` en macOS, `apt install jq` en Linux, `choco install jq` en Windows)
- macOS, Linux o Windows (con Git Bash o WSL)
- Uno de: Claude Code, Cursor, OpenAI Codex, OpenCode, Gemini CLI, Antigravity, Amp, Cline

## Ejemplo

```
Vos:    Necesito agregar notificaciones a mi app. Los usuarios se
        pierden las respuestas a sus posts.
Vos:    /think

Agente: Antes de construir nada, ¿cómo lo están manejando hoy?

Vos:    Abren la app 3 o 4 veces por día solo para chequear. A veces
        se pierden las respuestas por horas. Están frustrados.

Agente: Voy a empujar contra "notificaciones". Dijiste que abren la
        app 3-4 veces por día. Eso es alta interacción. Ya vuelven.
        El problema no es que no se les pueda avisar. El problema es
        que cuando llegan, no pueden ver qué cambió.

        Eso es un problema de visibilidad, no de mensajería.

        Un sistema de notificaciones (email, push, in-app, preferencias,
        digest, unsubscribe) es un proyecto de 3 semanas. Un puntito
        rojo en el ícono que diga "hay algo nuevo" se ships esta tarde.

        RECOMENDACIÓN: Reducir alcance. Ship el puntito. Ver si bajan
        los reclamos. Si bajan, te ahorraste 3 semanas. Si no bajan,
        ahí construís push notifications, pero ya con datos.

Vos:    Tiene sentido. Hagamos el puntito.
Vos:    /nano
        [3 pasos, 2 archivos]

Vos:    [construye]

Vos:    /review
        Review: 2 hallazgos (1 auto-arreglado, 1 detalle menor).

Vos:    /ship
        Ship: PR creado. Tests pasaron.
```

Vos dijiste "notificaciones". El agente dijo "tus usuarios tienen un problema de visibilidad" y encontró una solución que sale en una tarde en lugar de tres semanas. Cuatro comandos. Eso no es un copilot. Es un compañero que piensa.

## El sprint

Nanostack es un proceso, no una colección de herramientas. Las skills corren en el orden de un sprint:

```
/think → /nano → build → /review → /qa → /security → /ship
```

| Skill | Tu especialista | Qué hace |
|-------|-----------------|----------|
| `/think` | **CEO / Founder** | Cuestiona el alcance antes de construir. Tres modos de intensidad (Founder, Startup, Builder). Seis preguntas de calibración. `--autopilot` corre el sprint completo después de aprobar el brief. `--retro` reflexiona sobre lo que ya se hizo. |
| `/nano` | **Eng Manager** | Genera specs de producto (alcance Mediano) o specs de producto + técnico (alcance Grande) antes de los pasos de implementación. Estándares por tipo de proyecto (web, CLI/TUI). |
| `/review` | **Staff Engineer** | Revisión de código en dos pasadas: estructural y luego adversarial. Auto-arregla cosas mecánicas. Detecta scope drift contra el plan. |
| `/qa` | **QA Lead** | Testing funcional + Visual QA. Toma screenshots y analiza la UI contra los estándares de producto. Modos browser, API, CLI y debug. |
| `/security` | **Security Engineer** | Auto-detecta tu stack, escanea secretos, inyecciones, auth, CI/CD, vulnerabilidades de IA/LLM. Reporte calificado A-F. |
| `/ship` | **Release Engineer** | Pre-flight + checks de calidad del repo. Crea el PR, monitorea CI, genera el sprint journal. Después del commit pregunta: corro local, deploy a producción, o terminé. |

### Modos de intensidad

No todo cambio necesita una auditoría completa. `/review`, `/qa` y `/security` soportan tres modos:

| Modo | Flag | Cuándo usar |
|------|------|-------------|
| **Quick** | `--quick` | Typos, configs, docs. Solo lo obvio. |
| **Standard** | (default) | Features y bug fixes normales. |
| **Thorough** | `--thorough` | Auth, pagos, infra. Marca todo lo sospechoso. |

## Autopilot

Discutí la idea, aprobá el brief, alejate. El agente corre el sprint completo:

```
/think --autopilot
```

`/think` es interactivo: el agente pregunta, vos contestás, alinean en el brief. Después que aprobás, todo lo demás corre automáticamente:

```
/nano → build → /review → /security → /qa → /ship
```

Autopilot solo para si:
- `/review` encuentra issues bloqueantes que necesitan tu decisión
- `/security` encuentra vulnerabilidades críticas o altas
- `/qa` falla los tests
- Aparece una pregunta de producto que el agente no puede responder
- El loop guard detecta 2+ fases sin cambios en el repo (el agente está atascado)

## Guard

Los agentes cometen errores. Corren `rm -rf` cuando querían `rm -r`, hacen force push a main, mandan URLs a un shell. `/guard` los caza antes de que ejecuten.

### Seis tiers de seguridad

1. **Allowlist**: comandos como `git status`, `ls`, `cat` pasan sin chequeo.
2. **In-project**: operaciones que solo tocan archivos del repo actual pasan. El control de versiones es la red.
3. **Concurrencia por fase**: durante fases read-only (review, qa, security), las operaciones de escritura quedan bloqueadas para evitar race conditions.
4. **Phase gate**: cuando hay un sprint activo, `git commit` y `git push` quedan bloqueados hasta que existan artifacts frescos de review, security y qa.
5. **Budget gate**: cuando el sprint tiene un presupuesto y se gastó 95%+, todos los comandos no-allowlist quedan bloqueados.
6. **Pattern matching**: todo lo demás se chequea contra reglas de bloqueo y advertencia. 33 reglas para borrado masivo, destrucción de historia, drops de DB, deploys a producción, ejecución remota de código.

Cuando guard bloquea un comando, no solo dice "no". Sugiere una alternativa segura. El agente la lee y reintenta.

## Problemas comunes

¿Las skills no aparecen? Reiniciá tu agente (Cursor y Codex lo necesitan; Claude Code no).

¿`jq: command not found`? Instalalo con `brew install jq` (macOS) o `apt install jq` (Linux).

¿Phase gate bloqueó tu commit? Completá `/review`, `/security`, `/qa` para el sprint activo. O si el commit no es del sprint: `NANOSTACK_SKIP_GATE=1 git commit ...`.

Para la guía completa de problemas (Windows, proxy corporativo, sprints atascados, conflictos de nombres), ver [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Más documentación

Esta es una traducción de las secciones críticas. Para los temas avanzados (know-how, compounding, conductor, build on nanostack, analytics) consultá el [README en inglés](README.md):

- [Know-how y memoria entre sprints](README.md#know-how)
- [Sprints en paralelo (`/conductor`)](README.md#parallel-sprints)
- [Build on nanostack: extender con tus propias skills](README.md#build-on-nanostack)
- [Privacidad](README.md#privacy)

## Contribuir

Las contribuciones son bienvenidas. Ver [CONTRIBUTING.md](CONTRIBUTING.md) para setup, estructura del proyecto y guidelines de PR.

- [Reportar bugs](https://github.com/garagon/nanostack/issues/new?template=bug_report.yml)
- [Pedir features](https://github.com/garagon/nanostack/issues/new?template=feature_request.yml)
- Vulnerabilidades de seguridad: [SECURITY.md](SECURITY.md)

## Licencia

Apache 2.0
