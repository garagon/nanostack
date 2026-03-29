# Stack Defaults Reference

Use this reference when the user doesn't specify their preferred tools for a category. Suggest the default, explain why in one sentence, and let the user change it.

Do NOT force these choices. If the user says "I want to use Firebase," use Firebase. These defaults exist to help people who don't know what to pick, not to override people who do.

## Principles

**Always use the latest stable version.** Check the docs or registry before pinning a version. Don't use outdated examples from training data. Run `npm info <pkg> version`, `pip index versions <pkg>`, or check the GitHub releases page.

**Prefer tools with a CLI.** The agent works in the terminal. If a tool has a CLI, the agent can use it directly without SDK boilerplate. CLIs reduce integration code, enable local testing of webhooks and events, and work in CI/CD pipelines without extra configuration. When two tools are equivalent, pick the one with the better CLI.

## When to consult this file

- User says "I don't know what to use for auth"
- User is building something new and hasn't mentioned their stack
- User asks "what should I use for X?"
- User is a beginner or this is a hackathon project

## When NOT to consult this file

- User already specified their tools
- Project already has an existing stack (read package.json, go.mod, etc.)
- User is experienced and making deliberate choices

---

## Web App (Next.js ecosystem)

| Category | Default | CLI | Why | Alternative |
|---|---|---|---|---|
| Framework | Next.js (App Router) | `npx create-next-app` | Industry standard, Vercel deploys in seconds | Remix if you need nested layouts with loaders |
| Auth | Clerk | `npx clerk` | 5 min setup, pre-built UI components, free to 10K MAU | Better-Auth for self-hosted with zero per-user cost |
| Database | Supabase | `npx supabase` | Postgres + auth + storage + realtime in one, generous free tier | Neon for just a serverless Postgres without the BaaS |
| ORM | Drizzle | `npx drizzle-kit` | Type-safe, no codegen step, SQL-like, edge compatible | Prisma (`npx prisma`) if the team doesn't know SQL well |
| Hosting | Vercel | `npx vercel` | Zero-config Next.js deploys, preview per PR | Railway (`railway`) if you need backend services alongside |
| Payments | Stripe | `stripe` | Best CLI for testing webhooks and events locally | Lemon Squeezy for indie/global tax compliance |
| Email | Resend | `npx resend` | React components as email templates, cleanest API | SES if sending millions and cost is priority |
| File storage | Cloudflare R2 | `wrangler r2` | S3-compatible, zero egress fees | UploadThing for zero-config uploads |
| AI/LLM | Vercel AI SDK | `npx ai` | Streaming UI in ~20 lines, supports 25+ providers | Direct Anthropic/OpenAI SDK for backend pipelines |
| Real-time | Supabase Realtime | via `npx supabase` | Free if already on Supabase, WebSocket built in | PartyKit for collaborative/multiplayer features |
| Background jobs | Trigger.dev | `npx trigger.dev` | No timeout limits, open source, self-hostable | Inngest (`npx inngest-cli`) for step-based retry |
| Analytics | PostHog | `posthog` | Analytics + session replay + feature flags + A/B in one | Plausible for simple privacy-first pageviews |
| Error tracking | Sentry | `npx @sentry/wizard` | Industry standard, every language, free tier | No serious alternative |
| Testing | Vitest + Playwright | `npx playwright` | 3-5x faster than Jest, real browser E2E | Keep Jest only in legacy projects |
| State | Zustand | n/a | 3KB, simple hooks API, covers 90% of cases | Jotai for atomic state with fine-grained updates |
| Validation | Zod | n/a | TypeScript-first, one schema for runtime + types | Valibot if bundle size is critical (<1KB vs 13KB) |
| CSS | Tailwind v4 + shadcn/ui | `npx shadcn@latest` | Universal standard, copy-paste components | No serious alternative for startups |
| Feature flags | PostHog | via `posthog` | Included if already using PostHog for analytics | LaunchDarkly for enterprise governance |

## Go Backend/CLI

| Category | Default | Why | Alternative |
|---|---|---|---|
| HTTP | net/http + Chi | Standard library compatible, minimal overhead | Fiber for Express-like API |
| CLI | Cobra | De facto standard, used by kubectl, gh, docker | urfave/cli for simpler CLIs |
| TUI | Bubble Tea + Lip Gloss | Best Go TUI ecosystem (Charm.sh) | tview for table-heavy terminal UIs |
| Database | pgx | Fastest Postgres driver for Go | sqlx for less boilerplate |
| Config | Viper | Reads env, yaml, json, flags | envconfig for env-only |
| Testing | Go stdlib + testify | testify/assert is the only dependency worth adding | gomock for interface mocking |
| Logging | slog (stdlib) | Built into Go 1.21+, structured, zero deps | zerolog for performance-critical logging |

## Python Backend/CLI

| Category | Default | Why | Alternative |
|---|---|---|---|
| Web | FastAPI | Async, auto-docs, type hints | Django for full batteries-included |
| CLI | Typer | Type hints as CLI args, built on Click | Click for more control |
| TUI | Rich | Tables, progress bars, markdown, syntax highlighting | Textual for full interactive TUI |
| Database | SQLAlchemy 2.0 | Mature, async support, both ORM and Core | Tortoise for Django-like async ORM |
| Validation | Pydantic v2 | Standard for FastAPI, Rust-powered, fast | msgspec for maximum performance |
| Testing | pytest | Universal standard | No serious alternative |

## User overrides

Users can override any default by creating `.nanostack/stack.json` in their project or `~/.nanostack/stack.json` globally. See [EXTENDING.md](../../EXTENDING.md) for details.
