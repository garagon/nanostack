# OWASP Top 10 — Detailed Checklist

Use this as a reference during security audits. Each item includes what to search for and common patterns.

---

## A01: Broken Access Control

**Search patterns:**
- Routes/endpoints without auth middleware
- Direct object references using user-supplied IDs without ownership verification
- Missing server-side enforcement (relying only on UI to hide features)
- CORS with `Access-Control-Allow-Origin: *` on authenticated endpoints
- Directory listing enabled on static file servers
- Missing `httpOnly`, `secure`, `sameSite` on cookies

**Grep for:**
```
# Missing auth middleware (framework-specific)
router.get|router.post|app.get|app.post  (without auth/protect/guard in same route)
# CORS wildcards
Access-Control-Allow-Origin.*\*
# Path traversal
req.params|req.query + path.join|fs.read|fs.write
```

---

## A02: Cryptographic Failures

**Search patterns:**
- Passwords stored as plaintext or with MD5/SHA1 (use bcrypt/scrypt/argon2)
- API keys, tokens, or credentials hardcoded in source
- Sensitive data transmitted over HTTP (not HTTPS)
- Weak random number generation (`Math.random()`, `rand()` for security-sensitive operations)
- Missing encryption at rest for PII or financial data

**Grep for:**
```
MD5|SHA1|sha1|md5
password.*=.*['"]
apikey|api_key|secret_key|private_key
Math.random|rand\(\)|random\(\)
http://  (non-localhost URLs in config)
```

---

## A03: Injection

**Search patterns:**
- String concatenation in SQL queries (instead of parameterized queries)
- User input passed to `exec()`, `eval()`, `system()`, shell commands
- Template rendering with unescaped user input
- LDAP queries built from user input
- XML parsers with external entity processing enabled

**Grep for:**
```
# SQL injection
query.*\+.*req\.|query.*\$\{|query.*%s|execute.*format
# Command injection
exec\(|spawn\(|system\(|popen\(|child_process
# eval
eval\(|Function\(|setTimeout\(.*,|setInterval\(.*,
# Template injection
render.*\{\{|render.*\$\{|innerHTML.*=
```

---

## A04: Insecure Design

**Check for:**
- No rate limiting on authentication endpoints
- No account lockout after failed attempts
- Password reset via predictable tokens
- Missing CAPTCHA on public forms
- Business logic that trusts client-side calculations (prices, quantities, permissions)
- Missing abuse case handling (what if someone calls this endpoint 10,000 times?)

---

## A05: Security Misconfiguration

**Check for:**
- Debug/development mode enabled in production configs
- Default credentials in any configuration
- Stack traces or detailed error messages exposed to users
- Unnecessary HTTP methods enabled (TRACE, OPTIONS without CORS)
- Missing security headers: `X-Content-Type-Options`, `X-Frame-Options`, `Content-Security-Policy`, `Strict-Transport-Security`
- Admin interfaces exposed without IP restriction
- Unnecessary services/ports exposed in Docker/k8s configs

---

## A06: Vulnerable Components

**Run:**
```bash
# Node.js
npm audit --json 2>/dev/null
# Python
pip audit 2>/dev/null || safety check 2>/dev/null
# Go
govulncheck ./... 2>/dev/null
# Ruby
bundle audit check 2>/dev/null
# Rust
cargo audit 2>/dev/null
```

**Also check:**
- Lock file exists and is committed (package-lock.json, Pipfile.lock, go.sum)
- No wildcard version ranges in dependencies
- No dependencies pulled from untrusted registries

---

## A07: Authentication Failures

**Check for:**
- No minimum password complexity enforcement
- Session tokens in URLs (leaked via referrer)
- Session not invalidated on logout or password change
- JWT with `alg: none` accepted or weak signing keys
- Missing brute-force protection on login
- Credential stuffing not addressed (no rate limiting, no breach database check)

**Grep for:**
```
jwt.verify|jwt.sign|jsonwebtoken
session.*destroy|session.*invalidate
alg.*none|algorithm.*none
```

---

## A08: Data Integrity Failures

**Check for:**
- Deserialization of untrusted data (pickle, yaml.load, JSON.parse of user input into code execution)
- Auto-update mechanisms without signature verification
- CI/CD pipelines that run untrusted code
- Missing integrity checks on downloaded artifacts
- Insecure plugin/extension loading

---

## A09: Logging & Monitoring Failures

**Check for:**
- Login attempts not logged
- Failed access control not logged
- No log of administrative actions
- Sensitive data in logs (passwords, tokens, credit card numbers, PII)
- Logs stored without integrity protection
- No alerting on suspicious activity patterns

**Grep for:**
```
console.log.*password|log.*token|log.*secret|log.*credit
logger.*password|logging.*token
```

---

## A10: Server-Side Request Forgery (SSRF)

**Check for:**
- User-supplied URLs fetched by the server without validation
- Internal service discovery possible (cloud metadata endpoints: 169.254.169.254)
- DNS rebinding not mitigated
- URL scheme not restricted (file://, gopher://, dict://)
- Redirect following on server-side requests

**Grep for:**
```
fetch\(.*req\.|axios\(.*req\.|request\(.*req\.|http.get\(.*req\.
url.*=.*req\.query|url.*=.*req\.body|url.*=.*req\.params
169.254.169.254|metadata.google|metadata.aws
```
