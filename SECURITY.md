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
