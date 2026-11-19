#!/usr/bin/env python3
"""
Loopback HTTP bridge between the Omarchy Agent Governance widget and
safety-protocol (`safety-guard serve` and `safety-guard mcp-proxy`).

Security invariants:
- Stdlib only; never invokes a shell.
- Refuses non-loopback plain HTTP URLs (only loopback HTTP or explicit HTTPS).
- Bounds response sizes, list lengths, and string lengths before handing JSON
  back to the unsandboxed Quickshell UI.
- Reads the optional approver secret file locally so the secret never passes
  through QML bindings or command-line arguments.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

MAX_BODY_BYTES = 262_144  # 256 KiB hard response cap
TIMEOUT_SEC = 1.5
MAX_PENDING = 25
MAX_AUDIT = 25
MAX_BOTPOLICE = 20
LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}


def _is_safe_url(raw_url: str) -> tuple[str | None, str | None]:
    url = (raw_url or "").strip().rstrip("/")
    if not url:
        return None, None
    parsed = urllib.parse.urlsplit(url)
    scheme = (parsed.scheme or "").lower()
    host = (parsed.hostname or "").lower()
    if scheme == "http" and (host in LOOPBACK_HOSTS or host.startswith("127.")):
        return url, None
    if scheme == "https" and host:
        return url, None
    return None, f"refused unsafe endpoint URL: {raw_url!r}"


def _clean_str(value, max_len: int = 160) -> str:
    if value is None:
        return ""
    text = str(value)
    # Strip ASCII control chars except space to keep single-line labels safe.
    text = "".join(ch if ord(ch) >= 0x20 and ord(ch) != 0x7F else " " for ch in text)
    text = " ".join(text.split())
    if len(text) > max_len:
        return text[: max_len - 1] + "…"
    return text


def _clean_float(value, default: float = 0.0) -> float:
    try:
        num = float(value)
        if num != num or num in (float("inf"), float("-inf")):
            return default
        return num
    except (TypeError, ValueError):
        return default


def _clean_int(value, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _read_secret(secret_file: str) -> str:
    path = (secret_file or "").strip()
    if not path:
        return ""
    expanded = os.path.expanduser(path)
    try:
        with open(expanded, "r", encoding="utf-8") as fh:
            return fh.read(4096).strip()
    except OSError:
        return ""


def _http_json(
    base_url: str,
    path: str,
    method: str = "GET",
    payload: dict | None = None,
    secret: str = "",
) -> tuple[int, dict | None, str | None]:
    safe_base, err = _is_safe_url(base_url)
    if err:
        return 0, None, err
    if not safe_base:
        return 0, None, "no url configured"

    data = None
    headers = {"Accept": "application/json"}
    if secret:
        headers["X-Approver-Secret"] = secret
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(
        f"{safe_base}{path}", data=data, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SEC) as resp:
            raw = resp.read(MAX_BODY_BYTES + 1)
            if len(raw) > MAX_BODY_BYTES:
                return resp.status, None, "response exceeded size limit"
            parsed = json.loads(raw.decode("utf-8", errors="replace") or "{}")
            if not isinstance(parsed, dict):
                return resp.status, None, "unexpected JSON root type"
            return resp.status, parsed, None
    except urllib.error.HTTPError as exc:
        body = {}
        try:
            raw = exc.read(4096)
            parsed = json.loads(raw.decode("utf-8", errors="replace") or "{}")
            if isinstance(parsed, dict):
                body = parsed
        except Exception:
            body = {}
        return exc.code, body, _clean_str(body.get("error") or f"HTTP {exc.code}", 120)
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
        return 0, None, _clean_str(exc, 120)


def _normalize_pending(raw_list, source: str) -> list[dict]:
    if not isinstance(raw_list, list):
        return []
    out = []
    for item in raw_list[:MAX_PENDING]:
        if not isinstance(item, dict):
            continue
        token = _clean_str(item.get("token"), 64)
        if not token:
            continue
        out.append(
            {
                "token": token,
                "requestId": _clean_str(item.get("request_id"), 64),
                "actionType": _clean_str(item.get("action_type") or "action", 64),
                "target": _clean_str(item.get("target") or "", 140),
                "estimatedCost": max(0.0, _clean_float(item.get("estimated_cost"), 0.0)),
                "urgency": _clean_str(item.get("urgency") or "normal", 24).lower(),
                "channel": _clean_str(item.get("channel") or "", 32),
                "expiresAt": _clean_float(item.get("expires_at"), 0.0),
                "source": source,
            }
        )
    return out


def _normalize_audit(raw_events) -> list[dict]:
    if not isinstance(raw_events, list):
        return []
    tail = raw_events[-MAX_AUDIT:]
    tail.reverse()
    out = []
    for ev in tail:
        if not isinstance(ev, dict):
            continue
        data = ev.get("data") if isinstance(ev.get("data"), dict) else {}
        out.append(
            {
                "seq": _clean_int(ev.get("seq"), 0),
                "eventType": _clean_str(ev.get("event_type") or "event", 48),
                "actionType": _clean_str(data.get("action_type") or "", 48),
                "target": _clean_str(data.get("target") or "", 120),
                "reason": _clean_str(data.get("reason") or "", 140),
                "cost": max(0.0, _clean_float(data.get("cost") or data.get("estimated_cost"), 0.0)),
                "approver": _clean_str(data.get("approver") or "", 48),
                "approved": data.get("approved") if isinstance(data.get("approved"), bool) else None,
                "timestamp": _clean_float(ev.get("timestamp"), 0.0),
                "entryHash": _clean_str(ev.get("entry_hash") or "", 24),
            }
        )
    return out


def _parse_iso_ts(raw_ts) -> float:
    text = str(raw_ts or "").strip()
    if not text:
        return 0.0
    try:
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        return datetime.fromisoformat(text).timestamp()
    except ValueError:
        return 0.0


def _read_botpolice_log(log_path: str) -> dict:
    empty = {
        "present": False,
        "total": 0,
        "high": 0,
        "medium": 0,
        "events": [],
    }
    raw_path = (log_path or "").strip()
    if not raw_path:
        return empty
    expanded = os.path.expanduser(raw_path)
    if not os.path.isfile(expanded):
        return empty

    try:
        with open(expanded, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            start = max(0, size - MAX_BODY_BYTES)
            fh.seek(start)
            chunk = fh.read(MAX_BODY_BYTES)
    except OSError:
        return empty

    lines = chunk.decode("utf-8", errors="replace").splitlines()
    if start > 0 and lines:
        # Drop potentially partial first line when reading from mid-file.
        lines = lines[1:]

    parsed_entries: list[dict] = []
    high = 0
    medium = 0
    for line in lines:
        text = line.strip()
        if not text:
            continue
        try:
            ev = json.loads(text)
        except json.JSONDecodeError:
            continue
        if not isinstance(ev, dict):
            continue
        sev = _clean_str(ev.get("severity") or "low", 16).lower()
        if sev == "high":
            high += 1
        elif sev == "medium":
            medium += 1
        parsed_entries.append(
            {
                "event": _clean_str(ev.get("event") or "event", 48),
                "service": _clean_str(ev.get("service") or "decoy", 32),
                "severity": sev,
                "srcIp": _clean_str(ev.get("src_ip") or "", 64),
                "dstPort": _clean_int(ev.get("dst_port"), 0),
                "summary": _clean_str(ev.get("summary") or "", 140),
                "timestamp": _parse_iso_ts(ev.get("ts")),
                "hash": _clean_str(ev.get("hash") or "", 24),
            }
        )

    recent = parsed_entries[-MAX_BOTPOLICE:]
    recent.reverse()
    return {
        "present": True,
        "total": len(parsed_entries),
        "high": high,
        "medium": medium,
        "events": recent,
    }


def cmd_poll(
    guard_url: str,
    mcp_url: str,
    secret_file: str,
    botpolice_log_path: str = "",
) -> dict:
    secret = _read_secret(secret_file)
    result: dict = {
        "connected": False,
        "guardConnected": False,
        "mcpConnected": False,
        "demo": False,
        "agentId": "",
        "userId": "",
        "state": "offline",
        "mode": "enforce",
        "allowedActionTypes": [],
        "budgetLimit": None,
        "lintCount": 0,
        "shippingEnabled": False,
        "monitor": {
            "actionCount": 0,
            "allowed": 0,
            "blocked": 0,
            "approvalPending": 0,
            "totalCost": 0.0,
            "uptimeSeconds": 0.0,
        },
        "pending": [],
        "audit": [],
        "botpolice": _read_botpolice_log(botpolice_log_path),
        "authError": "",
        "error": "",
    }

    # 1. Poll guard service (safety-guard serve)
    g_code, g_health, _ = _http_json(guard_url, "/health")
    if g_code == 200 and g_health:
        result["guardConnected"] = True
        result["connected"] = True
        result["demo"] = bool(g_health.get("demo", False))
        result["agentId"] = _clean_str(g_health.get("agent_id") or "guard-agent", 64)
        result["userId"] = _clean_str(g_health.get("user_id") or "", 64)
        result["state"] = _clean_str(g_health.get("state") or "active", 24).lower()
        result["mode"] = _clean_str(g_health.get("mode") or "enforce", 24).lower()
        if isinstance(g_health.get("budget_limit"), (int, float)):
            result["budgetLimit"] = max(0.0, _clean_float(g_health.get("budget_limit")))

        vocab = g_health.get("allowed_action_types")
        if isinstance(vocab, list):
            result["allowedActionTypes"] = [_clean_str(v, 32) for v in vocab[:12] if v]

        lint = g_health.get("lint")
        if isinstance(lint, dict):
            findings = lint.get("findings")
            if isinstance(findings, list):
                result["lintCount"] = len(findings)
            else:
                result["lintCount"] = _clean_int(lint.get("count"), 0)

        shipping = g_health.get("shipping")
        if isinstance(shipping, dict):
            result["shippingEnabled"] = bool(shipping.get("enabled", False))

        mon = g_health.get("monitor")
        if isinstance(mon, dict):
            result["monitor"] = {
                "actionCount": _clean_int(mon.get("action_count"), 0),
                "allowed": _clean_int(mon.get("allowed"), 0),
                "blocked": _clean_int(mon.get("blocked"), 0),
                "approvalPending": _clean_int(mon.get("approval_pending"), 0),
                "totalCost": max(0.0, _clean_float(mon.get("total_cost"), 0.0)),
                "uptimeSeconds": max(0.0, _clean_float(mon.get("uptime_seconds"), 0.0)),
            }

        # Optional /pending on guardUrl (supported by demo guard and custom extensions)
        gp_code, gp_body, _ = _http_json(guard_url, "/pending", secret=secret)
        if gp_code == 200 and gp_body and isinstance(gp_body.get("pending"), list):
            result["pending"].extend(_normalize_pending(gp_body["pending"], "guard"))

        # Fetch hash-chained audit trail
        a_code, a_body, _ = _http_json(guard_url, "/audit")
        if a_code == 200 and a_body:
            result["audit"] = _normalize_audit(a_body.get("events"))

    # 2. Poll MCP proxy approval control server (safety-guard mcp-proxy)
    if mcp_url and mcp_url.rstrip("/") != guard_url.rstrip("/"):
        m_code, m_health, _ = _http_json(mcp_url, "/health")
        if m_code == 200 and m_health:
            result["mcpConnected"] = True
            result["connected"] = True
            if not result["guardConnected"]:
                result["agentId"] = "mcp-proxy"
                result["state"] = "active"
                result["mode"] = _clean_str(m_health.get("mode") or "enforce", 24).lower()

            mp_code, mp_body, mp_err = _http_json(mcp_url, "/pending", secret=secret)
            if mp_code == 200 and mp_body:
                seen = {p["token"] for p in result["pending"]}
                for item in _normalize_pending(mp_body.get("pending"), "mcp"):
                    if item["token"] not in seen:
                        result["pending"].append(item)
                        seen.add(item["token"])
            elif mp_code == 401:
                result["authError"] = mp_err or "Approver secret required for MCP control"

    return result


def cmd_decide(
    guard_url: str,
    mcp_url: str,
    secret_file: str,
    source: str,
    token: str,
    approved_str: str,
    approver: str,
) -> dict:
    secret = _read_secret(secret_file)
    approved = approved_str.lower() in ("1", "true", "yes", "approve")
    target_url = mcp_url if source == "mcp" and mcp_url else guard_url
    payload = {
        "token": _clean_str(token, 64),
        "approved": approved,
        "approver": _clean_str(approver or "operator", 64),
        "reason": "Approved via Omarchy governance widget"
        if approved
        else "Denied via Omarchy governance widget",
    }
    code, body, err = _http_json(
        target_url, "/approve", method="POST", payload=payload, secret=secret
    )
    ok = code == 200 and bool(body and (body.get("ok") or body.get("approved") is not None))
    return {"ok": ok, "status": code, "approved": approved, "error": err or ""}


def cmd_killswitch(guard_url: str, reason: str) -> dict:
    payload = {"reason": _clean_str(reason or "Operator kill switch", 160)}
    code, body, err = _http_json(guard_url, "/killswitch", method="POST", payload=payload)
    ok = code == 200 and bool(body and body.get("engaged"))
    return {"ok": ok, "status": code, "error": err or ""}


def cmd_simulate(guard_url: str) -> dict:
    code, body, err = _http_json(guard_url, "/simulate", method="POST", payload={})
    return {"ok": code == 200, "status": code, "error": err or ""}


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(json.dumps({"ok": False, "error": "missing command"}))
        return 1

    cmd = argv[1]
    if cmd == "poll" and len(argv) >= 5:
        bp_path = argv[5] if len(argv) >= 6 else ""
        out = cmd_poll(argv[2], argv[3], argv[4], bp_path)
    elif cmd == "decide" and len(argv) >= 9:
        out = cmd_decide(argv[2], argv[3], argv[4], argv[5], argv[6], argv[7], argv[8])
    elif cmd == "killswitch" and len(argv) >= 4:
        out = cmd_killswitch(argv[2], argv[3])
    elif cmd == "simulate" and len(argv) >= 3:
        out = cmd_simulate(argv[2])
    else:
        out = {"ok": False, "error": f"invalid arguments for {cmd}"}
        print(json.dumps(out))
        return 1

    print(json.dumps(out, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
