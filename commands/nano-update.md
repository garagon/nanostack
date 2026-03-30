---
description: Update nanostack to the latest version
allowed-tools: Bash
---

Run the nanostack upgrade script:

```bash
~/.claude/skills/nanostack/bin/upgrade.sh
```

If the upgrade pulls new commits, report what changed. If setup needs to re-run, it will do so automatically.

Do NOT initialize a git repository if one does not exist. The upgrade script handles both git clone and npx installations automatically.
