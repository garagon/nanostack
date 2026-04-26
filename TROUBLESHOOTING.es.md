# Solucionar problemas

Problemas comunes y cómo resolverlos, organizados por lo que ves en pantalla.

Si tu síntoma no está acá, abrí un issue: https://github.com/garagon/nanostack/issues

**Primer movimiento para cualquier problema de instalación:** corré `/nano-doctor` (o `~/.claude/skills/nanostack/bin/nano-doctor.sh`). Hace diez chequeos en menos de un segundo y nombra lo que está mal.

> La versión canónica es [TROUBLESHOOTING.md](TROUBLESHOOTING.md). Este documento cubre las entradas más frecuentes para usuarios hispanohablantes. Para temas avanzados (proxy corporativo, doble ejecución en autopilot, telemetría) consultá la versión en inglés.

## Contenido

- [Los comandos slash no aparecen en mi agente](#los-comandos-slash-no-aparecen-en-mi-agente)
- [Command not found: jq](#command-not-found-jq)
- [El phase gate bloqueó mi git commit](#el-phase-gate-bloqueo-mi-git-commit)
- [/qa dice que el puerto está en uso](#qa-dice-que-el-puerto-esta-en-uso)
- [Estoy en Windows](#estoy-en-windows)
- [Empecé un sprint y me quedé colgado a la mitad](#empece-un-sprint-y-me-quede-colgado-a-la-mitad)
- [Conflicto de nombres con otras skills (gstack, superpowers)](#conflicto-de-nombres-con-otras-skills-gstack-superpowers)

---

## Los comandos slash no aparecen en mi agente

Corriste `setup` (o `npx create-nanostack`) y el script imprimió `nanostack ready`, pero al tipear `/think` o `/nano-help` no pasa nada.

**1. ¿Reiniciaste tu agente después de instalar?**

| Agente | Acción |
|--------|--------|
| Claude Code | Listo al instante, no necesita reinicio. |
| Cursor | Cerrá Cursor y abrílo de nuevo. |
| Codex | Corré `codex` en una terminal nueva. |
| OpenCode | Reiniciá tu sesión de OpenCode. |
| Gemini CLI | Corré `gemini` en una terminal nueva. |

**2. ¿Terminó la instalación?**

```bash
cat ~/.nanostack/setup.json
```

Tenés que ver tu agente dentro del array `agents`. Si el archivo no existe, la instalación no se completó. Volvé a correr setup.

**3. ¿Los archivos están donde el agente los busca?**

```bash
# Claude Code
ls ~/.claude/skills/

# Codex / OpenCode
ls ~/.agents/skills/

# Cursor
ls .cursor/rules/
```

Si el directorio está vacío o falta `nanostack`, volvé a correr setup.

**4. ¿Choque de nombres?**

Si tenés otras skills instaladas (gstack, superpowers, etc.), los nombres pueden colisionar. Mirá [Conflicto de nombres](#conflicto-de-nombres-con-otras-skills-gstack-superpowers) más abajo.

---

## Command not found: jq

`jq` es necesario para casi todos los scripts de nanostack. Sin `jq` vas a ver:

```
ERROR: nanostack requires the following commands but they were not found: jq
```

**Instalación:**

| Sistema | Comando |
|---------|---------|
| macOS | `brew install jq` |
| Debian / Ubuntu | `sudo apt install jq` |
| Fedora / RHEL | `sudo dnf install jq` |
| Arch | `sudo pacman -S jq` |
| Windows | `choco install jq` o `winget install jqlang.jq` |

Después de instalar, abrí una terminal nueva (o corré `hash -r`) para que el PATH actualice.

---

## El phase gate bloqueó mi git commit

Tu commit falló con un mensaje parecido a:

```
BLOCKED: phase gate active.
Complete /review, /security, and /qa before committing.
```

**¿Por qué?** Hay un sprint activo, y nanostack pide los tres chequeos antes de permitir el commit.

**Si querés terminar el sprint:** completá los tres chequeos.

```
/review
/security
/qa
```

Cada uno guarda su propia evidencia. Cuando los tres están al día, `/ship` (o un `git commit` manual) puede continuar.

**Si el commit no es del sprint** (estás arreglando un typo en el README, por ejemplo) salteá el gate para este comando:

```bash
NANOSTACK_SKIP_GATE=1 git commit -m "..."
```

Esto aplica solo al comando actual. El gate se reactiva en el siguiente.

---

## /qa dice que el puerto está en uso

`/qa` arrancó tu app pero falló con:

```
Error: listen EADDRINUSE: address already in use :::3000
```

Otro proceso está usando el puerto. Pasos:

```bash
# 1. Encontrar quién lo está usando
lsof -i :3000

# 2. Si es de un /qa anterior que quedó colgado
kill <PID>

# 3. Si es algo legítimo (otro server tuyo), cambiá el puerto
PORT=3001 /qa
```

En Windows con WSL: `netstat -ano | findstr :3000`.

---

## Estoy en Windows

Nanostack funciona en Windows con dos caminos soportados:

- **Git Bash** (incluido con Git for Windows). Corré `setup` desde Git Bash, no desde PowerShell o CMD.
- **WSL2** (recomendado para uso intenso). Funciona como Linux nativo.

PowerShell y CMD no están soportados; los scripts de nanostack usan Bash.

Si las skills no aparecen después del setup en Windows:

1. Confirmá que estás en Git Bash o WSL, no en PowerShell.
2. Corré `~/.claude/skills/nanostack/bin/nano-doctor.sh` para ver el estado real.
3. Si Cursor en Windows no encuentra las skills, cerralo y abrílo de nuevo (no recargues, cerrá la ventana).

---

## Empecé un sprint y me quedé colgado a la mitad

Tu agente paró a mitad del sprint y no sabés cómo seguir.

**1. ¿En qué fase quedaste?**

```bash
~/.claude/skills/nanostack/bin/session.sh status
```

Te dice la fase actual y las completadas. Si la salida dice `"current_phase": "review"` y `"phases_completed": ["think","plan","build"]`, te falta `/review` y lo que sigue.

**2. ¿Qué viene después?**

```bash
~/.claude/skills/nanostack/bin/next-step.sh --json
```

Te devuelve la próxima acción en lenguaje claro (`user_message`) y el nombre de la fase (`next_phase`). En perfil guided te lo dice en una sola oración.

**3. ¿Querés cerrar el sprint sin terminarlo?**

```bash
~/.claude/skills/nanostack/bin/session.sh archive
```

Esto archiva la sesión actual. Tus archivos quedan como están; solo se cierra el sprint. Después podés arrancar uno nuevo cuando quieras.

---

## Conflicto de nombres con otras skills (gstack, superpowers)

Si tenés otras colecciones de skills instaladas (gstack, superpowers), algunos nombres pueden colisionar (`/think`, `/review`, `/qa`).

**Opción 1: renombrar las skills de nanostack al instalar**

```bash
NANOSTACK_PREFIX=nano- npx create-nanostack
```

Eso te deja `/nano-think`, `/nano-review`, etc., y evita el conflicto.

**Opción 2: desinstalar la otra colección**

Si ya no la usás, remové los archivos de skills viejos:

```bash
# Claude Code
rm -rf ~/.claude/skills/<otra-coleccion>/
```

**Opción 3: ver qué skills cargó el agente**

Cada agente lista sus skills en su propia interfaz; en Claude Code es `/help` o `/skills`. Mirá si los slash commands que esperás están definidos por nanostack o por la otra colección.

---

## ¿Sigue sin funcionar?

Abrí un issue con la salida completa de `/nano-doctor`: https://github.com/garagon/nanostack/issues
