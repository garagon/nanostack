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

`/nano-doctor` surfaces a warning when a broad `Bash(rm:*)` entry is present. To migrate, edit `.claude/settings.json`, remove the `Bash(rm:*)` line, and re-run `init-project.sh` to pick up the narrow defaults.

### Defense layers

| Layer | Purpose | Failure mode |
|---|---|---|
| Permissions (`.claude/settings.json`) | Cheap gate, no network call. | User can grant broad perms manually. |
| Guard hooks (`guard/bin/check-dangerous.sh`) | Pattern match against block rules before any command runs. | If hooks are disabled, permissions become the only gate. |
| Audit trail (`.nanostack/audit.log`) | Record every blocked and allowed command for post-hoc review. | If the store path is missing, logging silently no-ops; guard still blocks. |

Each layer is independent. The audit trail works even when the store path is unresolved; the guard works even when permissions are broad; the permissions work even if the guard is missing. That independence is the point.
