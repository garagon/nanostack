# Product Standards

Used by `/nano` Section 6 when the plan includes user-facing output. Apply during planning so implementation has clear constraints, not after the code is written. A product built with an AI agent should look and feel better than one built without it.

If the plan is a pure library with no user-facing output, skip this entire reference.

## UI / Frontend

- Use a component library. **Default: shadcn/ui + Tailwind.** Not raw CSS. Not Bootstrap. Not Material UI from 2019. The bar is professional SaaS quality.
- Dark mode support from day one. Not a follow-up. With Tailwind it takes 5 minutes more.
- Mobile responsive. If it doesn't work on a phone, half the users can't use it.
- No AI slop: no purple gradients, no centered-everything landing pages, no generic hero copy, no Inter font as the only choice. If it looks like every other AI-generated site, it's wrong.

## SEO (web-facing)

- Semantic HTML. `<main>`, `<article>`, `<nav>`, proper `<h1>` hierarchy. Not div soup.
- Meta tags on every page: title, description, og:image, og:title, og:description.
- Performance: images optimized, no layout shift, Core Web Vitals passing.
- Sitemap and robots.txt if the site has more than one page.

## LLM SEO (discoverable by AI)

- Structured data (JSON-LD) for the content type: Product, Article, FAQ, HowTo, SoftwareApplication.
- `llms.txt` at the root describing what the site/product does in plain language.
- Clean, descriptive URLs. `/pricing`, not `/page?id=3`.
- Content that answers questions directly in the first paragraph. LLMs extract from the top, not the bottom.

## CLI / TUI (command-line tools)

Use a TUI framework. Defaults by language:

- **Go:** [Bubble Tea](https://github.com/charmbracelet/bubbletea) + [Lip Gloss](https://github.com/charmbracelet/lipgloss) for interactive TUIs. [Cobra](https://github.com/spf13/cobra) for command structure. [Glamour](https://github.com/charmbracelet/glamour) for markdown rendering.
- **Python:** [Rich](https://github.com/Textualize/rich) for output formatting. [Textual](https://github.com/Textualize/textual) for interactive TUIs. [Click](https://github.com/pallets/click) or [Typer](https://github.com/tiangolo/typer) for command structure.
- **Node / TypeScript:** [Ink](https://github.com/vadimdemedes/ink) for interactive TUIs. [Commander](https://github.com/tj/commander.js) for command structure. [Chalk](https://github.com/chalk/chalk) for colors.
- **Rust:** [Ratatui](https://github.com/ratatui-org/ratatui) for interactive TUIs. [Clap](https://github.com/clap-rs/clap) for command structure.

CLI behavior requirements:

- Color output by default. Respect `NO_COLOR` env var and `--no-color` flag.
- Structured output: support `--json` flag for machine-readable output. Human-readable is default.
- Progress indicators for operations that take more than 1 second (spinners, progress bars).
- Error messages must be actionable: what went wrong, why, and what the user should do. Not stack traces.
- Exit codes: 0 for success, 1 for user error, 2 for system error. Consistent across all subcommands.
- Help text: every command and flag has a description. `--help` works on every subcommand.
- No wall-of-text output. Use tables, columns, indentation and color to make output scannable.
- Version flag: `--version` prints version and exits.
