<h1 align="center">Nanostack</h1>
<p align="center">
  Nanostack convierte tu agente de AI coding en un flujo de delivery: clarifica alcance, planifica el cambio, construye, revisa, prueba, audita y deja registro de lo ocurrido.<br>
  <strong>Sprints en sandbox que corren en minutos. Los proyectos reales mantienen el mismo workflow profesional.</strong>
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
  <a href="#dos-perfiles-mismo-rigor">Perfiles</a> &middot;
  <a href="#el-sprint">El sprint</a> &middot;
  <a href="#autopilot">Autopilot</a> &middot;
  <a href="#guard">Guard</a> &middot;
  <a href="#problemas-comunes">Problemas</a>
</p>

---

> **Nota:** la versión en inglés ([README.md](README.md)) es la canónica. Si encontrás divergencias o algo desactualizado en este documento, por favor abrí un issue.

Inspirado en [gstack](https://github.com/garrytan/gstack) de [Garry Tan](https://x.com/garrytan). 13 skills en total. El sprint principal usa siete especialistas. Cero dependencias. Cero paso de build.

Funciona hoy con adapters verificados en **Claude Code, Cursor, OpenAI Codex, OpenCode y Gemini CLI**. Los skill files son texto plano, así que otros agentes podrían cargarlos, pero solo esos cinco tienen un adapter verificado y declaración de capabilities en [`adapters/`](adapters/).

## Instalación

### Recomendado

```bash
npx create-nanostack
```

Un solo comando. Detecta tus agentes, instala todo, corre setup. Adapters verificados hoy: Claude Code, Cursor, Codex, OpenCode y Gemini CLI.

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

La forma más rápida de entender Nanostack es correrlo en un proyecto que no importa todavía. Elegí un sandbox de la Examples Library:

| Ejemplo | Ideal para | Stack | Tiempo |
|---|---|---|---|
| [`starter-todo`](examples/starter-todo/) | usuarios nuevos o no técnicos | un HTML | 5-10 min |
| [`cli-notes`](examples/cli-notes/) | workflows CLI | Bash | 5-15 min |
| [`api-healthcheck`](examples/api-healthcheck/) | flujos backend | Node HTTP sin dependencias | 10-15 min |
| [`static-landing`](examples/static-landing/) | founders y diseño | HTML/CSS estático | 10-15 min |

Cada ejemplo trae prompt para pegar, flujo esperado, criterios de éxito y pasos de reset. Library completa: [`examples/`](examples/).

### Requisitos

- [Git](https://git-scm.com/)
- [jq](https://jqlang.github.io/jq/) (`brew install jq` en macOS, `apt install jq` en Linux, `choco install jq` en Windows)
- macOS, Linux o Windows (con Git Bash o WSL)
- Un agente de AI coding con adapter verificado: Claude Code, Cursor, OpenAI Codex, OpenCode o Gemini CLI

## Dos perfiles, mismo rigor

Guided cambia el lenguaje, no baja el estándar.

| Perfil | Qué cambia |
|---------|------------|
| **Guiado** | Lenguaje claro, una sola próxima acción, defaults más seguros, sin jerga oculta. |
| **Profesional** | Salida más densa, tradeoffs explícitos, archivos, comandos y riesgos nombrados. |

El modo local usa Guiado por defecto. Un proyecto con git también puede usar Guiado si querés explicaciones más simples.

Las reglas de lenguaje viven en [`reference/plain-language-contract.md`](reference/plain-language-contract.md). Los campos de sesión que seleccionan el perfil viven en [`reference/session-state-contract.md`](reference/session-state-contract.md).

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
        rojo en el ícono que diga "hay algo nuevo" sale esta tarde.

        RECOMENDACIÓN: Reducir alcance. Publicá el puntito. Ver si bajan
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

**Autopilot avanza con un brief completo, no adivinando.** `/think --autopilot` siempre arma un brief primero. Si el brief tiene los campos requeridos (`value_proposition`, `target_user`, `narrowest_wedge`, `key_risk`, `premise_validated`), `/think` continúa a `/nano` sin pausar. Si falta alguno, `/think` para una vez y hace una sola pregunta enfocada. No inventa campos para seguir.

Autopilot solo para si:
- `/think` no puede armar el brief desde el contexto (hace una pregunta y sigue)
- `/review` encuentra issues bloqueantes que necesitan tu decisión
- `/security` encuentra vulnerabilidades críticas o altas
- `/qa` falla los tests
- Aparece una pregunta de producto que el agente no puede responder
- El loop guard detecta 2+ fases sin cambios en el repo (el agente está atascado)

## Guard

Los agentes cometen errores. Corren `rm -rf` cuando querían `rm -r`, hacen force push a main, mandan URLs a un shell. `/guard` los caza antes de que ejecuten.

### Seis tiers de seguridad

Cada comando de Bash pasa por estos seis tiers, en este orden:

1. **Block rules**: las reglas de bloqueo corren primero. 35 reglas cubren borrado masivo (`rm -rf .`, `find . -delete`), destrucción de historia (`git push --force`), lecturas de secretos (`.env`, `*.pem`), drops de DB, deploys a producción y ejecución remota (`curl | sh`). Una coincidencia bloquea aunque el binario esté en el allowlist de abajo.
2. **Allowlist**: para comandos que pasaron las block rules, los allowlisteados (`git status`, `ls`, `cat`, `jq`, etc.) saltan el resto.
3. **In-project**: operaciones que solo tocan archivos del repo actual pasan. El control de versiones es la red de seguridad.
4. **Concurrencia por fase**: durante fases read-only (review, qa, security), las operaciones de escritura quedan bloqueadas para evitar race conditions.
5. **Phase gate**: cuando hay un sprint activo, `git commit` y `git push` quedan bloqueados hasta que existan artifacts frescos de review, security y qa.
6. **Budget gate**: cuando el sprint tiene un presupuesto y se gastó 95%+, todos los comandos no-allowlist quedan bloqueados.

Plus 9 reglas de advertencia para operaciones que requieren atención sin llegar a bloqueo.

Las herramientas Write, Edit y MultiEdit pasan por su propio hook (`guard/bin/check-write.sh`) que niega rutas protegidas: archivos de secretos (`.env` y variantes, `*.pem`, `*.key`, llaves SSH) y directorios de sistema o usuario-secreto (`/etc`, `/var`, `/usr/bin`, `~/.ssh`, `~/.aws`, `~/.kube`). Los symlinks se resuelven antes de matchear, así que un `mylink/config -> ~/.ssh/config` se trata como destino resuelto.

Cuando guard bloquea un comando, no solo dice "no". Sugiere una alternativa segura. El agente la lee y reintenta.

### Qué se aplica en cada agente

Honestidad por host: nanostack manda los mismos archivos de skills a todos los agentes soportados, pero la capa de **enforcement** (los hooks que bloquean acciones antes de ejecutarse) depende de lo que cada host expone. Cada adapter en [`adapters/`](adapters/) declara su capacidad real; setup, doctor, y este cuadro leen de esos archivos. Niveles según [`reference/host-adapter-schema.md`](reference/host-adapter-schema.md):

| Agente | Bash guard | Write/Edit guard | Phase gate | Qué significa |
|---|---|---|---|---|
| Claude Code | enforced (L3) | enforced (L3) | enforced (L3) | Hooks bloquean comandos peligrosos antes de correr. CI verifica continuamente. |
| Cursor | guided (L0) | guided (L0) | guided (L0) | Skills se cargan como reglas de texto. El agente las lee y debe seguirlas. Sin pre-tool-use hook hoy. |
| OpenAI Codex | guided (L0) | guided (L0) | guided (L0) | Skills disponibles, sin hooks de bloqueo. |
| OpenCode | guided (L0) | guided (L0) | guided (L0) | Skills disponibles, sin hooks de bloqueo. |
| Gemini CLI | guided (L0) | guided (L0) | guided (L0) | Instalado como extensión Gemini, sin hooks de bloqueo. |

Si querés enforcement duro, usá Claude Code. Si aceptás disciplina a nivel agente, los demás corren el mismo workflow guiado. Corré `/nano-doctor` después de instalar para ver el estado real de tu install.

## Problemas comunes

¿Las skills no aparecen? Reiniciá tu agente (Cursor y Codex lo necesitan; Claude Code no).

¿`jq: command not found`? Instalalo con `brew install jq` (macOS) o `apt install jq` (Linux).

¿Phase gate bloqueó tu commit? Completá `/review`, `/security`, `/qa` para el sprint activo. O si el commit no es del sprint: `NANOSTACK_SKIP_GATE=1 git commit ...`.

Para la guía completa de problemas en español (slash commands, jq, phase gate, puerto en uso, Windows, sprints atascados, conflictos de nombres), ver [TROUBLESHOOTING.es.md](TROUBLESHOOTING.es.md). Para temas avanzados (proxy corporativo, doble ejecución en autopilot, telemetría) consultá la versión canónica en inglés: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Privacidad

Nanostack no tiene un servicio cloud propio. Guarda planes, artefactos, journals y know-how localmente en `.nanostack/`. No envía tu código, prompts, nombres de proyecto ni rutas de archivo a servidores de Nanostack. Tu proveedor de agente de IA puede procesar el contexto que le des; usá las opciones de privacidad de tu proveedor y tus propias políticas de datos para trabajo sensible.

La telemetría es opt-in y se limita a eventos de uso agregados. No es necesaria para el workflow. Si la activás, los eventos van al Cloudflare Worker documentado en [`TELEMETRY.md`](TELEMETRY.md). El código del Worker, su schema, las invariantes de privacidad y los smoke tests adversarios viven en este repo.

Niveles: `off` (default), `anonymous`, `community`. Las instalaciones desde v0.4 y anteriores quedan en `off` y no ven prompt. Las instalaciones nuevas reciben un prompt una sola vez en el primer skill run.

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
