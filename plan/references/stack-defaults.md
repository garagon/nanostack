# Stack Defaults Reference

Use this reference when the user doesn't specify their preferred tools for a category. Suggest the default, explain why in one sentence, and let the user change it.

Do NOT force these choices. If the user says "I want to use Firebase," use Firebase. These defaults exist to help people who don't know what to pick, not to override people who do.

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

| Category | Default | Why | Alternative |
|---|---|---|---|
| Framework | Next.js (App Router) | Industry standard, Vercel deploys in seconds | Remix if you need nested layouts with loaders |
| Auth | Clerk | 5 min setup, pre-built UI components, free to 10K MAU | Better-Auth for self-hosted with zero per-user cost |
| Database | Supabase | Postgres + auth + storage + realtime in one, generous free tier | Neon for just a serverless Postgres without the BaaS |
| ORM | Drizzle | Type-safe, no codegen step, SQL-like, edge compatible | Prisma if the team doesn't know SQL well |
| Hosting | Vercel | Zero-config Next.js deploys, preview per PR | Railway if you need backend services alongside |
| Payments | Lemon Squeezy | Handles global tax compliance for you, 5% + $0.50 | Stripe for full control and B2B invoicing |
| Email | Resend | React components as email templates, cleanest API | SES if sending millions and cost is priority |
| File storage | Cloudflare R2 | S3-compatible, zero egress fees | UploadThing for zero-config uploads |
| AI/LLM | Vercel AI SDK | Streaming UI in ~20 lines, supports 25+ providers | Direct Anthropic/OpenAI SDK for backend pipelines |
| Real-time | Supabase Realtime | Free if already on Supabase, WebSocket built in | PartyKit for collaborative/multiplayer features |
| Background jobs | Trigger.dev | No timeout limits, open source, self-hostable | Inngest for step-based retry |
| Analytics | PostHog | Analytics + session replay + feature flags + A/B testing in one | Plausible for simple privacy-first pageviews |
| Error tracking | Sentry | Industry standard, every language, free tier | No serious alternative |
| Testing | Vitest + Playwright | 3-5x faster than Jest, real browser E2E | Keep Jest only in legacy projects |
| State | Zustand | 3KB, simple hooks API, covers 90% of cases | Jotai for atomic state with fine-grained updates |
| Validation | Zod | TypeScript-first, one schema for runtime + types | Valibot if bundle size is critical (<1KB vs 13KB) |
| CSS | Tailwind v4 + shadcn/ui | Universal standard, copy-paste components | No serious alternative for startups |
| Feature flags | PostHog | Included if already using PostHog for analytics | LaunchDarkly for enterprise governance |

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

## Avoid (outdated or problematic)

- **Lucia Auth**: deprecated March 2025
- **PlanetScale**: killed free tier, $39/mo minimum
- **Firebase Realtime DB**: proprietary, no SQL, hard to migrate
- **Auth0**: enterprise pricing, overkill for startups
- **TypeORM**: stale, poor TypeScript inference
- **Styled-components / Emotion**: incompatible with React Server Components
- **Jest for new projects**: Vitest is 3-5x faster with compatible API
- **Redux for new projects**: Zustand covers 90% of cases in 3KB
- **Formik**: React Hook Form is faster and lighter
- **Yup**: Zod won the TypeScript ecosystem
- **Mongoose**: use Drizzle/Prisma with Postgres instead of MongoDB for relational data
