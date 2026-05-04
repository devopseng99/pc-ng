#!/usr/bin/env python3
"""
GitHub webhook receiver for auto-rebuilding PaperclipBuild CRDs.

When a push event arrives for a repo that matches a CRD's spec.repoUrl or
spec.repo, reset that CRD to the appropriate phase to trigger a rebuild.

Usage:
  python webhook-server.py --port 9090 --secret WEBHOOK_SECRET
  python webhook-server.py --port 9090 --secret-file /path/to/secret

GitHub webhook config:
  Payload URL: https://webhooks.istayintek.com/github
  Content type: application/json
  Secret: <shared secret>
  Events: push

Endpoints:
  POST /github  - GitHub webhook handler
  GET  /health  - Health check
  GET  /status  - Recent webhook events (last 50)
"""

import argparse
import hashlib
import hmac
import json
import logging
import os
import subprocess
import sys
import threading
import time
from collections import deque
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NAMESPACE = "paperclip-v3"
LOG_FILE = "/tmp/pc-autopilot/.webhook.log"
MAX_EVENTS = 50
DEBOUNCE_SECONDS = 300  # 5 minutes per repo

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
webhook_secret: bytes = b""
recent_events: deque = deque(maxlen=MAX_EVENTS)
debounce_map: dict = {}  # repo_full_name -> last_trigger_epoch
debounce_lock = threading.Lock()
logger = logging.getLogger("webhook-server")


def setup_logging():
    """Configure logging to both stdout and log file."""
    fmt = logging.Formatter("[%(asctime)s] [WEBHOOK] %(message)s",
                            datefmt="%Y-%m-%d %H:%M:%S")
    logger.setLevel(logging.INFO)

    # Stdout
    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(fmt)
    logger.addHandler(sh)

    # File
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    fh = logging.FileHandler(LOG_FILE)
    fh.setFormatter(fmt)
    logger.addHandler(fh)


# ---------------------------------------------------------------------------
# HMAC verification
# ---------------------------------------------------------------------------
def verify_signature(payload: bytes, signature_header: str) -> bool:
    """Verify X-Hub-Signature-256 HMAC."""
    if not signature_header:
        return False
    if not signature_header.startswith("sha256="):
        return False
    expected = signature_header[7:]
    computed = hmac.new(webhook_secret, payload, hashlib.sha256).hexdigest()
    return hmac.compare_digest(computed, expected)


# ---------------------------------------------------------------------------
# CRD operations
# ---------------------------------------------------------------------------
def find_matching_crds(repo_name: str) -> list:
    """Find PaperclipBuild CRDs matching a GitHub repo name.

    repo_name can be 'owner/repo' or just 'repo'.
    """
    try:
        result = subprocess.run(
            ["kubectl", "get", "pb", "-n", NAMESPACE, "-o", "json"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            logger.error("kubectl get pb failed: %s", result.stderr.strip())
            return []

        data = json.loads(result.stdout)
        matches = []

        # Extract the short repo name (without owner)
        short_name = repo_name.split("/")[-1] if "/" in repo_name else repo_name

        for item in data.get("items", []):
            spec = item.get("spec", {})
            crd_repo = spec.get("repo", "")
            crd_repo_url = spec.get("repoUrl", "")

            # Match by repo field (usually just the repo name)
            if crd_repo and (crd_repo == short_name or crd_repo == repo_name):
                matches.append(item)
                continue

            # Match by repoUrl (full GitHub URL)
            if crd_repo_url and (
                repo_name in crd_repo_url or short_name in crd_repo_url
            ):
                matches.append(item)
                continue

        return matches

    except subprocess.TimeoutExpired:
        logger.error("kubectl timed out searching for CRDs")
        return []
    except Exception as e:
        logger.error("Error finding CRDs: %s", e)
        return []


def reset_crd(crd_name: str, current_phase: str) -> str:
    """Reset a CRD to trigger a rebuild. Returns the action taken."""
    if current_phase in ("Ready", "Deployed"):
        # Code exists, just needs a rebuild
        target_phase = "Building"
        step = "webhook-rebuild"
    else:
        # Failed or other state — full rebuild
        target_phase = "Pending"
        step = "webhook-reset"

    patch = json.dumps({
        "status": {
            "phase": target_phase,
            "currentStep": step,
            "errorMessage": ""
        }
    })

    try:
        result = subprocess.run(
            [
                "kubectl", "patch", "paperclipbuild", crd_name,
                "-n", NAMESPACE, "--type", "merge",
                "-p", patch, "--subresource=status"
            ],
            capture_output=True, text=True, timeout=15
        )
        if result.returncode == 0:
            return f"reset to {target_phase}"
        else:
            logger.error("Patch failed for %s: %s", crd_name, result.stderr.strip())
            return f"patch failed: {result.stderr.strip()[:100]}"
    except Exception as e:
        return f"error: {e}"


def is_debounced(repo_name: str) -> bool:
    """Check if this repo was triggered recently (within DEBOUNCE_SECONDS)."""
    now = time.time()
    with debounce_lock:
        last = debounce_map.get(repo_name, 0)
        if now - last < DEBOUNCE_SECONDS:
            return True
        debounce_map[repo_name] = now
        return False


# ---------------------------------------------------------------------------
# HTTP Handler
# ---------------------------------------------------------------------------
class WebhookHandler(BaseHTTPRequestHandler):
    """Handles GitHub webhook POST requests and status/health GETs."""

    def log_message(self, format, *args):
        """Suppress default access log — we use our own logger."""
        pass

    def _send_json(self, status_code: int, data: dict):
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data, indent=2).encode())

    # --- GET endpoints ---
    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {
                "status": "ok",
                "uptime": time.time() - server_start_time,
                "timestamp": datetime.now(timezone.utc).isoformat()
            })
        elif self.path == "/status":
            self._send_json(200, {
                "recent_events": list(recent_events),
                "debounce_seconds": DEBOUNCE_SECONDS,
                "total_events": len(recent_events),
                "timestamp": datetime.now(timezone.utc).isoformat()
            })
        else:
            self._send_json(404, {"error": "not found"})

    # --- POST /github ---
    def do_POST(self):
        if self.path != "/github":
            self._send_json(404, {"error": "not found"})
            return

        content_length = int(self.headers.get("Content-Length", 0))
        if content_length == 0:
            self._send_json(400, {"error": "empty body"})
            return

        body = self.rfile.read(content_length)

        # HMAC verification
        signature = self.headers.get("X-Hub-Signature-256", "")
        if webhook_secret and not verify_signature(body, signature):
            logger.warning("Invalid HMAC signature from %s", self.client_address[0])
            self._send_json(401, {"error": "invalid signature"})
            return

        # Parse event
        event_type = self.headers.get("X-GitHub-Event", "unknown")
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self._send_json(400, {"error": "invalid JSON"})
            return

        # Only handle push events
        if event_type != "push":
            logger.info("Ignoring event type: %s", event_type)
            self._send_json(200, {"action": "ignored", "event": event_type})
            return

        # Extract repo info
        repo_data = payload.get("repository", {})
        repo_full_name = repo_data.get("full_name", "")
        ref = payload.get("ref", "")
        pusher = payload.get("pusher", {}).get("name", "unknown")
        commit_count = len(payload.get("commits", []))

        if not repo_full_name:
            self._send_json(400, {"error": "no repository in payload"})
            return

        logger.info("Push to %s (%s) by %s — %d commit(s)",
                     repo_full_name, ref, pusher, commit_count)

        # Only trigger on pushes to main/master
        if ref not in ("refs/heads/main", "refs/heads/master"):
            logger.info("Ignoring push to non-default branch: %s", ref)
            event = {
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "repo": repo_full_name,
                "ref": ref,
                "action": "ignored (non-default branch)",
                "pusher": pusher
            }
            recent_events.appendleft(event)
            self._send_json(200, {"action": "ignored", "reason": "non-default branch"})
            return

        # Debounce — max 1 rebuild per repo per DEBOUNCE_SECONDS
        if is_debounced(repo_full_name):
            logger.info("Debounced: %s (triggered within last %ds)",
                         repo_full_name, DEBOUNCE_SECONDS)
            event = {
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "repo": repo_full_name,
                "ref": ref,
                "action": "debounced",
                "pusher": pusher
            }
            recent_events.appendleft(event)
            self._send_json(200, {"action": "debounced",
                                   "message": f"Already triggered within {DEBOUNCE_SECONDS}s"})
            return

        # Find matching CRDs
        matching = find_matching_crds(repo_full_name)

        if not matching:
            logger.info("No matching CRDs for %s", repo_full_name)
            event = {
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "repo": repo_full_name,
                "ref": ref,
                "action": "no matching CRDs",
                "pusher": pusher
            }
            recent_events.appendleft(event)
            self._send_json(200, {"action": "no_match",
                                   "message": f"No CRDs match {repo_full_name}"})
            return

        # Reset each matching CRD
        actions = []
        for item in matching:
            crd_name = item["metadata"]["name"]
            current_phase = item.get("status", {}).get("phase", "Unknown")
            result = reset_crd(crd_name, current_phase)
            actions.append({
                "crd": crd_name,
                "previous_phase": current_phase,
                "result": result
            })
            logger.info("Push to %s -> reset %s to %s (was %s)",
                         repo_full_name, crd_name, result, current_phase)

        # Record event
        event = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "repo": repo_full_name,
            "ref": ref,
            "pusher": pusher,
            "commits": commit_count,
            "action": "triggered",
            "crds_affected": len(actions),
            "details": actions
        }
        recent_events.appendleft(event)

        self._send_json(200, {
            "action": "triggered",
            "repo": repo_full_name,
            "crds_affected": len(actions),
            "details": actions
        })


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
server_start_time = time.time()


def main():
    global webhook_secret, server_start_time

    parser = argparse.ArgumentParser(description="GitHub webhook receiver for PaperclipBuild CRDs")
    parser.add_argument("--port", type=int, default=9090, help="Listen port (default: 9090)")
    parser.add_argument("--secret", type=str, default="", help="Webhook HMAC secret")
    parser.add_argument("--secret-file", type=str, default="",
                        help="Read webhook secret from file")
    parser.add_argument("--bind", type=str, default="0.0.0.0", help="Bind address")
    args = parser.parse_args()

    setup_logging()

    # Load secret
    if args.secret_file:
        with open(args.secret_file) as f:
            webhook_secret = f.read().strip().encode()
        logger.info("Loaded webhook secret from %s", args.secret_file)
    elif args.secret:
        webhook_secret = args.secret.encode()
        logger.info("Webhook secret configured (from CLI arg)")
    else:
        logger.warning("No webhook secret configured — HMAC verification DISABLED")

    server_start_time = time.time()
    server = HTTPServer((args.bind, args.port), WebhookHandler)
    logger.info("Webhook server listening on %s:%d", args.bind, args.port)
    logger.info("Endpoints: POST /github | GET /health | GET /status")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
