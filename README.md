# Agent Governance — Omarchy Shell Bar Widget (`thedub.governance`)

Live desktop control plane for [`TheDub-lab/agentcover-sovereign`](https://github.com/TheDub-lab/agentcover-sovereign) (`safety-protocol`).

## What it does

- **Live status in the bar**: shield icon tracks `ENFORCE`, `SHADOW`, `FROZEN`, `OFFLINE`, and flashes an urgent badge whenever a gated action awaits human approval.
- **One-click human-in-the-loop approvals**: polls `safety-guard mcp-proxy` (`GET /pending`, `POST /approve`) and `safety-guard serve`, sends an Omarchy critical notification on new requests, and lets you **Approve** or **Deny** inline.
- **Spend & scope telemetry**: shows allowed/blocked counts, cumulative spend (with budget meter when `budget_limit` is exposed), closed action vocabulary, lint status, and log shipping state.
- **Hash-chained audit stream**: displays the latest decisions and short entry hashes from `GET /audit`.
- **Two-step Kill Switch**: arms and confirms `POST /killswitch` directly from the bar panel.
- **Built-in Demo Guard**: click **Start demo guard** inside the panel to test approvals, prompt-injection blocks, spend tracking, and the kill switch locally without configuring an external agent.

## Connecting to `safety-protocol`

Start either (or both) services locally:

```bash
# HTTP guard service (default: http://127.0.0.1:8080)
safety-guard serve --config guard_config.json

# MCP proxy with approval control server (default: http://127.0.0.1:8788)
safety-guard mcp-proxy \
  --config guard_config.json \
  --approver-secret-file ~/.local/state/safety-guard/approver.secret \
  -- <your-mcp-server-cmd>
```

Then configure `approverSecretFile` (or custom URLs) in `~/.config/omarchy/shell.json` under the `thedub.governance` bar entry, or via CLI:

```bash
omarchy bar set thedub.governance approverSecretFile ~/.local/state/safety-guard/approver.secret
```

## IPC & Keybinding

```bash
omarchy shell thedub.governance toggle
omarchy shell thedub.governance status
```

## Publishing for other Omarchy users

Push this folder as a GitHub repo (e.g. `TheDub-lab/omarchy-agent-governance`) so anyone on Omarchy can install it in one command:

```bash
omarchy plugin add https://github.com/TheDub-lab/omarchy-agent-governance --enable
```
