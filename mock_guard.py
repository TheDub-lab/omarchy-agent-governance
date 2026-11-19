#!/usr/bin/env python3
"""
Local demo guard implementing the exact `safety-guard serve` + `/pending` HTTP
contract on 127.0.0.1:8080 so the Omarchy Agent Governance widget can be tested
immediately without starting an external agent.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import signal
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class DemoGuardState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._start = time.time()
        self.agent_id = "agentcover-demo"
        self.user_id = "thedub-lab"
        self.state = "active"
        self.mode = "enforce"
        self.budget_limit = 25.00
        self.allowed_action_types = ["mcp_tool_call", "api_call", "payment"]
        self.allowed = 0
        self.blocked = 0
        self.total_cost = 0.0
        self.audit: list[dict] = []
        self.pending: dict[str, dict] = {}
        self._head_hash: str | None = None
        self._sim_idx = 0
        self._seed()

    def _append_audit(self, event_type: str, data: dict) -> None:
        entry = {
            "seq": len(self.audit),
            "event_type": event_type,
            "agent_id": self.agent_id,
            "data": data,
            "timestamp": time.time(),
            "prev_hash": self._head_hash,
        }
        raw = json.dumps(entry, sort_keys=True, default=str).encode("utf-8")
        entry["entry_hash"] = hashlib.sha256(raw).hexdigest()[:16]
        self._head_hash = entry["entry_hash"]
        self.audit.append(entry)

    def _add_pending(
        self, action_type: str, target: str, cost: float, urgency: str = "normal"
    ) -> str:
        token = uuid.uuid4().hex[:12]
        req_id = uuid.uuid4().hex[:8]
        expires_at = time.time() + 300.0
        self.pending[token] = {
            "token": token,
            "request_id": req_id,
            "action_type": action_type,
            "target": target,
            "estimated_cost": cost,
            "urgency": urgency,
            "channel": "control",
            "expires_at": expires_at,
        }
        self._append_audit(
            "action_pending_approval",
            {
                "request_id": req_id,
                "action_type": action_type,
                "target": target,
                "estimated_cost": cost,
                "requires_approval_for": token,
            },
        )
        return token

    def _seed(self) -> None:
        self._append_audit(
            "protocol_initialized",
            {
                "user_id": self.user_id,
                "scope_rules_count": 4,
                "budget_limit": self.budget_limit,
                "allowed_action_types": self.allowed_action_types,
            },
        )
        self.allowed += 1
        self.total_cost += 0.45
        self._append_audit(
            "action_allowed",
            {
                "request_id": "req-001",
                "action_type": "api_call",
                "target": "https://api.research.example/v1/search",
                "cost": 0.45,
            },
        )
        self.allowed += 1
        self.total_cost += 1.20
        self._append_audit(
            "action_allowed",
            {
                "request_id": "req-002",
                "action_type": "mcp_tool_call",
                "target": "read_file",
                "cost": 1.20,
            },
        )
        self.blocked += 1
        self._append_audit(
            "action_blocked",
            {
                "request_id": "req-003",
                "action_type": "mcp_tool_call",
                "target": "write_file",
                "reason": "Target '/etc/secrets.env' blocked by least-privilege scope rule",
            },
        )
        self._add_pending(
            "payment",
            "0xMerchant...41e8 (PayPal invoice #409)",
            4.50,
            urgency="high",
        )

    def health(self) -> dict:
        with self._lock:
            return {
                "demo": True,
                "agent_id": self.agent_id,
                "user_id": self.user_id,
                "state": self.state,
                "mode": self.mode,
                "budget_limit": self.budget_limit,
                "lint": {"findings": [], "clean": True},
                "allowed_action_types": self.allowed_action_types,
                "shipping": {"enabled": False},
                "monitor": {
                    "agent_id": self.agent_id,
                    "action_count": self.allowed + self.blocked + len(self.pending),
                    "allowed": self.allowed,
                    "blocked": self.blocked,
                    "approval_pending": len(self.pending),
                    "total_cost": round(self.total_cost, 2),
                    "uptime_seconds": round(time.time() - self._start, 1),
                },
            }

    def get_pending(self) -> list[dict]:
        with self._lock:
            now = time.time()
            expired = [t for t, p in self.pending.items() if p["expires_at"] <= now]
            for t in expired:
                self.pending.pop(t, None)
            return list(self.pending.values())

    def get_audit(self) -> list[dict]:
        with self._lock:
            return list(self.audit)

    def decide(self, token: str, approved: bool, approver: str, reason: str | None) -> bool:
        with self._lock:
            item = self.pending.pop(token, None)
            if not item:
                return False
            self._append_audit(
                "approval_decision",
                {
                    "token": token,
                    "request_id": item["request_id"],
                    "action_type": item["action_type"],
                    "target": item["target"],
                    "approved": approved,
                    "approver": approver,
                    "reason": reason or "",
                    "cost": item["estimated_cost"],
                },
            )
            if approved:
                self.allowed += 1
                self.total_cost += float(item["estimated_cost"])
                self._append_audit(
                    "action_allowed",
                    {
                        "request_id": item["request_id"],
                        "action_type": item["action_type"],
                        "target": item["target"],
                        "cost": item["estimated_cost"],
                    },
                )
            else:
                self.blocked += 1
                self._append_audit(
                    "action_blocked",
                    {
                        "request_id": item["request_id"],
                        "action_type": item["action_type"],
                        "target": item["target"],
                        "reason": f"Denied by {approver}",
                    },
                )
            return True

    def killswitch(self, reason: str) -> None:
        with self._lock:
            self.state = "frozen"
            self.pending.clear()
            self.blocked += 1
            self._append_audit("killswitch_engaged", {"reason": reason})

    def simulate(self) -> dict:
        scenarios = [
            ("pending", "mcp_tool_call", "send_email (finance@acme.io)", 2.50, "high"),
            ("blocked", "mcp_resource_read", "file:///home/mwh/.ssh/id_ed25519", 0.0, "Prompt injection traversal rejected"),
            ("allowed", "api_call", "https://api.research.example/v1/search", 0.35, ""),
            ("pending", "payment", "0xVendor...9b2c (API credit top-up)", 6.00, "critical"),
        ]
        with self._lock:
            if self.state != "active":
                self.blocked += 1
                self._append_audit(
                    "action_blocked",
                    {
                        "action_type": "mcp_tool_call",
                        "target": "read_file",
                        "reason": "Protocol frozen by kill switch — all actions blocked",
                    },
                )
                return {"kind": "frozen_block"}

            kind, action_type, target, cost, extra = scenarios[self._sim_idx % len(scenarios)]
            self._sim_idx += 1
            if kind == "pending":
                token = self._add_pending(action_type, target, cost, urgency=extra)
                return {"kind": "pending", "token": token}
            if kind == "blocked":
                self.blocked += 1
                self._append_audit(
                    "action_blocked",
                    {
                        "action_type": action_type,
                        "target": target,
                        "reason": extra,
                    },
                )
                return {"kind": "blocked"}
            self.allowed += 1
            self.total_cost += cost
            self._append_audit(
                "action_allowed",
                {"action_type": action_type, "target": target, "cost": cost},
            )
            return {"kind": "allowed"}


class DemoHandler(BaseHTTPRequestHandler):
    state: DemoGuardState

    def log_message(self, *args) -> None:
        pass

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(min(length, 65536)).decode("utf-8"))
        except json.JSONDecodeError:
            return {}

    def do_GET(self) -> None:
        if self.path == "/health":
            self._send(200, self.state.health())
        elif self.path == "/pending":
            self._send(200, {"pending": self.state.get_pending()})
        elif self.path == "/audit":
            self._send(200, {"events": self.state.get_audit()})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self) -> None:
        body = self._read_json()
        if self.path == "/approve":
            ok = self.state.decide(
                str(body.get("token") or ""),
                bool(body.get("approved", False)),
                str(body.get("approver") or "operator"),
                body.get("reason"),
            )
            self._send(200 if ok else 404, {"ok": ok, "approved": bool(body.get("approved", False))})
        elif self.path == "/killswitch":
            reason = str(body.get("reason") or "operator")
            self.state.killswitch(reason)
            self._send(200, {"engaged": True, "reason": reason})
        elif self.path == "/simulate":
            self._send(200, self.state.simulate())
        else:
            self._send(404, {"error": "not found"})


def main() -> int:
    ap = argparse.ArgumentParser(description="Local demo safety-guard server")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8080)
    args = ap.parse_args()

    DemoHandler.state = DemoGuardState()
    httpd = ThreadingHTTPServer((args.host, args.port), DemoHandler)

    def _stop(*_args) -> None:
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    try:
        httpd.serve_forever()
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
