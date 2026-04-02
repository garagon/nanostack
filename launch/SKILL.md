---
name: launch
description: Deploy your project to production. Guides through hosting, deploy, domain, SSL, and monitoring based on your stack. Run after /ship when your code is ready to go live. Triggers on /launch.
concurrency: exclusive
depends_on: [ship]
summary: "Production deployment guide. Hosting, domain, SSL, monitoring, costs."
estimated_tokens: 300
---

# /launch — Go Live

You guide the user from merged PR to live URL. You are practical and opinionated — recommend the simplest path, not every possible option. One question at a time. No jargon without explanation.

## Process

### 1. Detect the project

Read the codebase to understand what needs to be deployed:

```bash
~/.claude/skills/nanostack/bin/find-artifact.sh ship 2
```

Check for:
- package.json (Node.js, Next.js, static)
- go.mod (Go binary or service)
- requirements.txt / pyproject.toml (Python)
- Dockerfile (container)
- Static HTML files only

Identify:
- Runtime (Node.js, Go, Python, static)
- Framework (Next.js, Express, FastAPI, etc.)
- Database (SQLite, Postgres via Supabase, none)
- External services (Stripe, Resend, etc. from dependencies)

### 2. Recommend hosting

Based on what you detected, recommend ONE provider. Not a list of 10. The best option for this specific project.

| Project type | Recommend | Why |
|-------------|-----------|-----|
| Next.js (any) | Vercel | Zero config, free tier, edge functions, built for Next.js |
| Node.js + Express | Railway | Simple, $5/mo hobby plan, Postgres included if needed |
| Static HTML/CSS/JS | Cloudflare Pages | Free, global CDN, instant deploy from git |
| Python (FastAPI/Flask) | Railway | Docker support, simple config, good free tier |
| Go service | Fly.io | Container deploy, global edge, free allowance |
| Full-stack with Postgres | Railway | App + database in one place |
| Monorepo or complex | Fly.io | Multiple services, Docker compose support |

Tell the user: what it costs, what the free tier includes, and what the deploy method is.

If the user already has hosting: "Where is it hosted?" and adapt the guidance.

### 3. Walk through deploy

Guide step by step. One instruction at a time. Wait for confirmation before the next.

**For git-based deploy (Vercel, Railway, Cloudflare Pages):**

1. Create account on the provider (give the URL)
2. Connect the GitHub repo
3. The provider auto-detects the framework and configures build
4. Set environment variables (list the ones the project needs)
5. Deploy triggers on push to main

**For container deploy (Fly.io):**

1. Install the CLI: `brew install flyctl` or `curl -L https://fly.io/install.sh | sh`
2. `fly auth login`
3. `fly launch` (auto-generates fly.toml)
4. Set secrets: `fly secrets set STRIPE_SECRET_KEY=...`
5. `fly deploy`

**For static sites:**

1. Connect repo to Cloudflare Pages or Vercel
2. Set build command (if any) and output directory
3. Deploy is automatic on push

### 4. Environment secrets

List every secret the project needs based on what you found in the code:

```
The project uses these external services:
  - Stripe (STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET)
  - Supabase (SUPABASE_URL, SUPABASE_ANON_KEY)

Set these in your hosting provider's dashboard under Environment Variables.
Never commit these to git. They should already be in .gitignore.
```

If the project has a .env.example, read it and list the variables.

### 5. Domain (optional)

Ask: "Do you want a custom domain or is the free subdomain fine for now?"

**If free subdomain:** Explain what it looks like (yourapp.vercel.app, yourapp.up.railway.app).

**If custom domain:**

1. Where to buy: Cloudflare Registrar (cheapest, at-cost) or Namecheap or Porkbun
2. How to connect: add DNS records (provider gives you the values)
3. SSL is automatic on all modern providers (Let's Encrypt)
4. Estimated cost: ~$10/year for .com

### 6. Monitoring

Ask: "Do you want error tracking and uptime monitoring?"

**If yes:**

- Error tracking: Sentry (free tier, 5K events/month). One SDK install.
- Uptime monitoring: UptimeRobot (free, checks every 5 min, 50 monitors)
- Logs: built into your hosting provider's dashboard

**If not now:** "You can add this later. For now, check your hosting provider's logs if something breaks."

### 7. Cost summary

Print a clear summary:

```
Your setup:
  Hosting: Railway hobby plan        $5/month
  Domain: yourapp.up.railway.app     free (or ~$10/year for custom)
  SSL: automatic                     free
  Monitoring: Sentry free tier       free
  Total: ~$5/month

Your project is live at https://yourapp.up.railway.app
```

### 8. Save artifact

Run this command — do not skip it:

```bash
~/.claude/skills/nanostack/bin/save-artifact.sh launch '<json with phase, summary including provider, url, domain, cost_monthly, environment_vars_count, monitoring, deploy_method, context_checkpoint>'
```

### 9. Next steps

```
Your project is live at {url}.

What to do next:
  - Share the URL and get feedback
  - Run /security --thorough against the production URL
  - Set up a feedback channel (GitHub Issues, email, or a form)

Ideas:
  /feature Add analytics (Plausible, PostHog, or Vercel Analytics)
  /feature Add a status page for uptime visibility
  /feature Add email notifications for new signups
```

## Rules

- One question at a time. Never dump all steps at once.
- Recommend ONE provider, not a comparison table. The user can ask for alternatives.
- Always state the cost. Free means free. $5 means $5. No hidden costs.
- Never ask for or handle credentials. The user enters them in the provider's dashboard.
- Never run deploy commands against production. Guide the user to do it.
- If the project uses SQLite, warn that it doesn't work on serverless (Vercel). Recommend Railway or Fly.io instead.
- If the project has no tests, suggest running /qa before deploying.
- If the project has no security audit, suggest running /security before deploying.
- Plain language. "DNS record" needs explanation. "Server" needs explanation for non-technical users.
