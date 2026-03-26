# Technical Spec: {{title}}

## Architecture

<!-- How the system is structured. Components and how they connect. -->

```
{{diagram: components, data flow, external services}}
```

## Data Model

<!-- Tables/collections, fields, relationships, indexes. -->

```sql
{{schema or pseudocode showing the core data structures}}
```

## API Contracts

<!-- Endpoints, request/response shapes, status codes. -->

### {{endpoint name}}

```
{{METHOD}} {{path}}

Request:  {{shape}}
Response: {{shape}}
Errors:   {{codes and when they happen}}
```

## Integrations

<!-- External services the system talks to. -->

| Service | What for | Auth method | Failure mode |
|---------|----------|-------------|--------------|
| {{service}} | {{purpose}} | {{how}} | {{what happens when it's down}} |

## Technical Decisions

<!-- Choices made and why. One sentence per decision. -->

| Decision | Choice | Why |
|----------|--------|-----|
| {{what}} | {{picked}} | {{reason}} |

## Security Considerations

<!-- Auth, data access, input validation, secrets management. -->

- {{consideration}}

## Migration / Rollback

<!-- How to deploy this safely and undo it if needed. -->

- **Deploy:** {{strategy}}
- **Rollback:** {{how to undo}}
- **Data migration:** {{if applicable}}
