# huddy

A heads-up display for a team's coding agents: one page showing every agent's
goal, its current tasks, and the decisions it wants a human to look at. Agents
report over MCP. A decision model ([Jev](https://api.typesafe.ai/docs)) reviews
what they post: it flags statements that are unclear, duplicated, overlapping
or outdated, and tells the agent, which decides what to do. The model also
ranks what the display shows.

- **Design:** [`docs/DESIGN.md`](docs/DESIGN.md)
- **Stack:** Gleam on Erlang/OTP 29, mist + wisp, one JSON state file, no
  frontend framework (server-rendered HTML, zone swaps over SSE, ~150 lines of
  vanilla JS).

## Run it

Requirements: Erlang/OTP 29, Gleam 1.19, rebar3 (see `.tool-versions`).

```sh
cp huddy.example.json huddy.json        # edit: team, base_url, allowlist, email, decision model
export HUDDY_SECRET_KEY=$(openssl rand -base64 48)
export TYPESAFE_API_KEY=...             # or OpenRouter: see deploy/huddy.compose.json; or "enabled": false
gleam run -- --config huddy.json
```

For local development, use `"base_url": "http://localhost:8080"` and
`"email": {"from": "...", "transport": "log"}`. Login codes are then printed to
the log instead of being sent. Login codes are the only e-mail Huddy sends.

### Docker Compose (Huddy + Mailpit)

```sh
cp deploy/.env.example .env      # HUDDY_SECRET_KEY, DECISION_MODEL_API_KEY (OpenRouter), allowed domain
docker compose up --build
```

Huddy runs at http://localhost:8080, and Mailpit (which catches the sign-in
codes) at http://localhost:8025. The compose config is
[`deploy/huddy.compose.json`](deploy/huddy.compose.json); it uses Jev through
OpenRouter (`typesafe/jev-1.13`).

### Docker

```sh
docker build -t huddy .
docker run -p 8080:8080 \
  -v huddy-data:/var/lib/huddy \
  -v $PWD/huddy.json:/etc/huddy/huddy.json:ro \
  -e HUDDY_SECRET_KEY -e TYPESAFE_API_KEY -e SMTP_PASSWORD \
  huddy
```

To keep the state in S3 instead of a volume, see [State in S3](#state-in-s3).

Put Huddy behind a TLS-terminating reverse proxy. List the proxy in
`server.trusted_proxies` so rate limits see real client IPs, and have the proxy
redact `/mcp/k/…` paths from its access logs (they contain secrets). The state
volume must be a local POSIX filesystem (or use S3).

Huddy honours `HTTPS_PROXY`/`NO_PROXY` for its outbound calls (decision model,
client metadata). For builds without GitHub access, or behind a TLS-intercepting
proxy, see the comments at the top of the [`Dockerfile`](Dockerfile).

### State in S3

Set `storage.path` to an S3 URL. Backups then go to the `backups/` prefix next
to it (or set `storage.backup_dir`, local or `s3://`):

```json
"storage": {
  "path": "s3://acme-huddy/prod/huddy.json",
  "s3": { "region": "eu-west-1" }
}
```

Credentials come from `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and
`AWS_SESSION_TOKEN`, or from `storage.s3.access_key_id` etc. Region defaults to
`AWS_REGION`. For MinIO, R2 and other S3-compatible stores, add
`"endpoint": "https://minio.internal:9000"` (path-style addressing is then the
default; override with `path_style`). Huddy needs `s3:GetObject`,
`s3:PutObject`, `s3:DeleteObject` and `s3:ListBucket`. Details:
[DESIGN.md §5.7](docs/DESIGN.md#57-state-in-s3).

## Connect an agent

Agents talk to `https://<your huddy>/mcp` (MCP Streamable HTTP; protocol
versions 2026-07-28 and 2025-11-25).

- **OAuth:** point the client at the URL and it signs in through your browser.

  ```sh
  claude mcp add --transport http huddy https://huddy.acme.dev/mcp
  ```

  For Codex, add this to `~/.codex/config.toml`:

  ```toml
  [mcp_servers.huddy]
  url = "https://huddy.acme.dev/mcp"
  ```
- **Secret URL:** create one in *Settings* (optionally pinned to an agent name
  and project, and optionally read-only), then use it as the server URL.

The server's instructions teach agents the protocol. They set one goal, keep a
few tasks open, post decisions when unsure (marked blocking if they have
stopped), act on review findings or dismiss them with a reason, and close items
when done.

## Configuration

One JSON file. Every field is shown in
[`huddy.example.json`](huddy.example.json) and explained in
[DESIGN.md §3](docs/DESIGN.md#3-configuration-single-json-file). Any string
value can be `{"$env": "NAME"}`.

## Develop

```sh
gleam test                      # unit + end-to-end tests (boots the app on local ports)
gleam format --check src test
gleam build --warnings-as-errors
```

## Fonts

The bundled fonts (Excalifont, Nunito) are licensed under the SIL OFL 1.1, see
[`priv/static/FONTS-LICENSE.txt`](priv/static/FONTS-LICENSE.txt).
