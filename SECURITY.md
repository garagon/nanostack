# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Nanostack, please report it through
[GitHub Security Advisories](https://github.com/garagon/nanostack/security/advisories/new).

**Do not open a public issue.**

## Scope

### In Scope

- Guard rule bypass (command that should be blocked passes through)
- Artifact injection (malicious data in .nanostack/ artifacts that affects downstream skills)
- Setup script vulnerabilities (symlink attacks, path traversal)
- Secrets exposure in skill output or artifacts
- Command injection through bin/ scripts

### Out of Scope

- Vulnerabilities in the AI agent itself (Claude Code, Codex, etc.)
- Issues in code that nanostack reviews or generates (that's what /security is for)
- Third-party skill sets built on top of nanostack

## Response Timeline

| Stage | Timeline |
|-------|----------|
| Acknowledgment | 48 hours |
| Initial assessment | 7 days |
| Fix or mitigation | 30 days |

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest on main | Yes |
| Older commits | Best effort |

## Disclosure

We follow coordinated disclosure. We will:

1. Confirm the vulnerability
2. Develop a fix
3. Release a patch
4. Credit the reporter (unless anonymity is requested)

## Permission model

`bin/init-project.sh` writes entries to `.claude/settings.json` so autopilot can run without constant permission prompts. Nanostack treats the permission list as the first line of defense and the guard hooks as the authoritative one.

### Default rm scope

New installs receive:

- `Bash(rm:.nanostack/**)` for sprint artifact cleanup
- `Bash(rm:/tmp/**)` for temporary file cleanup

Any `rm` outside these paths prompts the user. Destructive deletion of arbitrary paths should be a conscious choice, not a silent default.

### Broad curl is kept

`Bash(curl:*)` remains in the default list because curl is a common dev-path primitive (testing endpoints, fetching release artifacts, hitting localhost). The dangerous case, piping curl output into a shell, is caught by the guard as a block rule:

- `G-023` blocks `curl ... | sh`
- `G-024` blocks `curl ... | bash`

The guard runs on every Bash tool use, ahead of the in-project fast-path, and logs every block to `.nanostack/audit.log`.

### Existing installs

Installs that existed before the narrowing got `Bash(rm:*)` written to their `.claude/settings.json`. Running `init-project.sh` a second time does NOT remove it. The install keeps what it had.

`/nano-doctor` surfaces a warning when a broad `Bash(rm:*)` entry is present. To migrate without editing JSON by hand, run one of:

| Command | What it does |
|---|---|
| `init-project.sh --check` | Read-only diagnostic. Runs `/nano-doctor` and exits. |
| `init-project.sh --repair` | Adds missing hooks and adds narrow rm rules. Never removes existing entries. Safe to run on any project. |
| `init-project.sh --migrate-hooks` | Adds missing PreToolUse hooks only. |
| `init-project.sh --migrate-permissions` | Removes `Bash(rm:*)` and adds `Bash(rm:.nanostack/**)` and `Bash(rm:/tmp/**)`. |

Every migration path makes a timestamped backup of `.claude/settings.json` before changing anything, and re-runs `/nano-doctor` at the end so you can see the new state without a separate command.

### Write and Edit are hooked too

Coding agents need to write code, so `Write(*)` and `Edit(*)` stay broad in the permission list. The safety boundary for those tools lives in a dedicated PreToolUse hook: `guard/bin/check-write.sh`. It runs before every Write, Edit, and MultiEdit call and rejects a narrow denylist:

- Environment files with real secrets (`.env`, `.env.local`, `.env.production`, `.env.staging`, `.env.development`, `.env.dev`, `.env.prod`). Template files like `.env.example`, `.env.sample`, `.env.template` are allowed.
- Private cryptographic material (`*.pem`, `*.key`, `*.p12`, `*.pfx`).
- SSH keys and config (`id_rsa`, `id_ed25519`, `id_ecdsa`, `id_dsa`, their `.pub` pairs, `authorized_keys`, `known_hosts`).
- Shell history (`.bash_history`, `.zsh_history`, `.python_history`).
- System directories (`/etc`, `/var`, `/usr/bin`, `/usr/sbin`, `/usr/lib`, `/System`, `/private/etc`).
- User secret directories (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.gcp`, `~/.config/gcloud`, `~/.kube`).

Fresh installs receive this hook wired automatically. Existing installs are not modified and need to wire it manually to gain the Write/Edit layer.

### Manual wire-up for existing installs

Add the following to your project's `.claude/settings.json`. The paths assume a standard install at `~/.claude/skills/nanostack`.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "$HOME/.claude/skills/nanostack/guard/bin/check-dangerous.sh"}]
      },
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [{"type": "command", "command": "$HOME/.claude/skills/nanostack/guard/bin/check-write.sh"}]
      }
    ]
  }
}
```

Run `/nano-doctor` to verify; it warns when the hooks are missing.

### Defense layers

| Layer | Purpose | Failure mode |
|---|---|---|
| Permissions (`.claude/settings.json`) | Cheap gate, no network call. | User can grant broad perms manually. |
| Guard hooks (`check-dangerous.sh`, `check-write.sh`) | Pattern match against block rules before a Bash, Write, or Edit call runs. | If hooks are disabled, permissions become the only gate. |
| Audit trail (`.nanostack/audit.log`) | Record every blocked and allowed command for post-hoc review. | If the store path is missing, logging silently no-ops; guard still blocks. |

Each layer is independent. The audit trail works even when the store path is unresolved; the guard works even when permissions are broad; the permissions work even if the guard is missing. That independence is the point.
