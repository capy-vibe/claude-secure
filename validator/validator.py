#!/usr/bin/env python3
"""Call validator service with SQLite storage and iptables enforcement.

Provides HTTP endpoints for call-ID registration and validation.
Manages iptables rules to control outbound traffic from the shared
network namespace (claude + validator containers).
"""
import json
import logging
import os
import socket
import sqlite3
import subprocess
import threading
from datetime import datetime, timedelta
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
DB_PATH = os.environ.get("VALIDATOR_DB_PATH", "/data/validator.db")
CALL_TTL_SECONDS = 10
LISTEN_PORT = 8088
WHITELIST_PATH = "/etc/claude-secure/whitelist.json"
CLEANUP_INTERVAL_SECONDS = 5

logger = logging.getLogger("validator")


class JsonFileHandler(logging.Handler):
    """Writes JSON-formatted log entries to a JSONL file."""

    def __init__(self, filepath):
        super().__init__()
        self.filepath = filepath

    def emit(self, record):
        try:
            entry = json.dumps({
                "ts": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                "svc": "iptables",
                "level": record.levelname.lower(),
                "msg": record.getMessage(),
            })
            with open(self.filepath, "a") as f:
                f.write(entry + "\n")
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def get_db():
    """Return a new per-call SQLite connection with WAL mode."""
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA busy_timeout=5000;")
    return conn


def init_db():
    """Create the calls table and indexes if they do not exist."""
    conn = get_db()
    try:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS calls (
                call_id TEXT PRIMARY KEY,
                domain TEXT NOT NULL,
                ip_address TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                expires_at TEXT NOT NULL,
                used INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_expires ON calls(expires_at);
            CREATE INDEX IF NOT EXISTS idx_used ON calls(used);
        """)
        conn.commit()
        logger.info("Database initialized at %s", DB_PATH)
    finally:
        conn.close()

# ---------------------------------------------------------------------------
# DNS resolution
# ---------------------------------------------------------------------------

def resolve_domain(domain):
    """Resolve *domain* to an IPv4 address string, or None on failure.

    Uses socket.getaddrinfo which will query whatever DNS server the OS
    is configured to use.  In the shared namespace the Docker embedded
    DNS lives at 127.0.0.11 and can resolve both service names and
    external domains.
    """
    old_timeout = socket.getdefaulttimeout()
    try:
        socket.setdefaulttimeout(5)
        results = socket.getaddrinfo(domain, 443, socket.AF_INET, socket.SOCK_STREAM)
        if results:
            ip = results[0][4][0]
            logger.info("Resolved %s -> %s", domain, ip)
            return ip
    except socket.gaierror as exc:
        logger.warning("DNS resolution failed for %s: %s", domain, exc)
    except Exception as exc:
        logger.warning("Unexpected error resolving %s: %s", domain, exc)
    finally:
        socket.setdefaulttimeout(old_timeout)
    return None

# ---------------------------------------------------------------------------
# iptables helpers
# ---------------------------------------------------------------------------

def _run_ipt(*args, check=True):
    """Run an iptables command, returning the CompletedProcess."""
    cmd = ["iptables"] + list(args)
    logger.debug("iptables: %s", " ".join(cmd))
    return subprocess.run(cmd, check=check, capture_output=True, text=True)


def add_iptables_rule(ip, call_id):
    """Insert a temporary ACCEPT rule for *ip* at position 4 in OUTPUT."""
    try:
        _run_ipt(
            "-I", "OUTPUT", "4",
            "-d", ip, "-p", "tcp", "-j", "ACCEPT",
            "-m", "comment", "--comment", f"call-id:{call_id}",
        )
        logger.info("iptables ACCEPT rule added for %s (call-id:%s) with comment", ip, call_id)
    except subprocess.CalledProcessError:
        # Fallback without comment module
        try:
            _run_ipt("-I", "OUTPUT", "4", "-d", ip, "-p", "tcp", "-j", "ACCEPT")
            logger.info("iptables ACCEPT rule added for %s (call-id:%s) without comment (fallback)", ip, call_id)
        except subprocess.CalledProcessError as exc:
            logger.error("Failed to add iptables rule for %s: %s", ip, exc.stderr)


def remove_iptables_rule(ip, call_id):
    """Remove the ACCEPT rule for *ip*.  Best-effort (never raises)."""
    result = _run_ipt(
        "-D", "OUTPUT",
        "-d", ip, "-p", "tcp", "-j", "ACCEPT",
        "-m", "comment", "--comment", f"call-id:{call_id}",
        check=False,
    )
    if result.returncode != 0:
        # Try without comment
        _run_ipt("-D", "OUTPUT", "-d", ip, "-p", "tcp", "-j", "ACCEPT", check=False)
    logger.info("iptables ACCEPT rule removed for %s (call-id:%s)", ip, call_id)


def setup_default_iptables():
    """Set default OUTPUT chain policy: allow loopback + established + proxy, DROP rest."""
    logger.info("Setting up default iptables rules...")

    # 1. Flush OUTPUT chain
    _run_ipt("-F", "OUTPUT")

    # 2. Allow loopback
    _run_ipt("-A", "OUTPUT", "-o", "lo", "-j", "ACCEPT")

    # 3. Allow established/related (response traffic)
    _run_ipt("-A", "OUTPUT", "-m", "state", "--state", "ESTABLISHED,RELATED", "-j", "ACCEPT")

    # 3b. Allow DNS to Docker embedded DNS (needed for domain resolution in call-ID registration)
    _run_ipt("-A", "OUTPUT", "-d", "127.0.0.11", "-p", "udp", "--dport", "53", "-j", "ACCEPT")
    _run_ipt("-A", "OUTPUT", "-d", "127.0.0.11", "-p", "tcp", "--dport", "53", "-j", "ACCEPT")
    logger.info("DNS rule added for 127.0.0.11:53")

    # 4. Allow traffic to proxy on port 8080
    proxy_ip = resolve_domain("proxy")
    if proxy_ip:
        _run_ipt("-A", "OUTPUT", "-d", proxy_ip, "-p", "tcp", "--dport", "8080", "-j", "ACCEPT")
        logger.info("Proxy rule added for %s:8080", proxy_ip)
    else:
        logger.error("Could not resolve 'proxy' hostname -- proxy iptables rule NOT added")

    # 5. Default policy: DROP
    _run_ipt("-P", "OUTPUT", "DROP")
    logger.info("Default iptables OUTPUT policy set to DROP")

# ---------------------------------------------------------------------------
# Background cleanup
# ---------------------------------------------------------------------------

def cleanup_expired():
    """Remove expired call-IDs from the database and their iptables rules."""
    try:
        conn = get_db()
        try:
            # Find expired, unused entries that still have iptables rules
            rows = conn.execute(
                "SELECT call_id, ip_address FROM calls "
                "WHERE expires_at <= datetime('now') AND used = 0"
            ).fetchall()

            for row in rows:
                if row["ip_address"]:
                    remove_iptables_rule(row["ip_address"], row["call_id"])

            # Delete all expired entries (both used and unused)
            deleted = conn.execute(
                "DELETE FROM calls WHERE expires_at <= datetime('now')"
            ).rowcount
            conn.commit()

            if deleted:
                logger.info("Cleanup: removed %d expired call-ID(s)", deleted)
        finally:
            conn.close()
    except Exception as exc:
        logger.error("Cleanup error: %s", exc)


def _cleanup_loop():
    """Run cleanup_expired periodically in a daemon thread."""
    cleanup_expired()
    t = threading.Timer(CLEANUP_INTERVAL_SECONDS, _cleanup_loop)
    t.daemon = True
    t.start()

# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class ValidatorHandler(BaseHTTPRequestHandler):
    """HTTP request handler for the call validator service."""

    def do_POST(self):
        if self.path == "/register":
            self._handle_register()
        else:
            self._send_json(404, {"error": "not found"})

    def do_GET(self):
        if self.path == "/health":
            self._handle_health()
        elif self.path.startswith("/validate"):
            self._handle_validate()
        else:
            self._send_json(404, {"error": "not found"})

    # -- Endpoints ----------------------------------------------------------

    def _handle_register(self):
        """POST /register -- register a call-ID for a domain."""
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
        except (ValueError, json.JSONDecodeError) as exc:
            self._send_json(400, {"status": "error", "reason": f"Invalid JSON: {exc}"})
            return

        call_id = body.get("call_id")
        domain = body.get("domain")

        if not call_id or not domain:
            self._send_json(400, {"status": "error", "reason": "Missing call_id or domain"})
            return

        # Resolve domain to IP (best-effort -- DNS may fail on internal networks)
        ip = resolve_domain(domain)
        if not ip:
            logger.warning("DNS resolution failed for %s -- storing call-ID without iptables rule", domain)

        # Calculate expiry
        expires_at = (datetime.utcnow() + timedelta(seconds=CALL_TTL_SECONDS)).strftime(
            "%Y-%m-%d %H:%M:%S"
        )

        # Store in database
        conn = get_db()
        try:
            conn.execute(
                "INSERT INTO calls (call_id, domain, ip_address, expires_at) VALUES (?, ?, ?, ?)",
                (call_id, domain, ip, expires_at),
            )
            conn.commit()
        except sqlite3.IntegrityError:
            conn.close()
            self._send_json(400, {"status": "error", "reason": f"Duplicate call_id: {call_id}"})
            return
        except sqlite3.Error as exc:
            conn.close()
            self._send_json(500, {"status": "error", "reason": f"Database error: {exc}"})
            return
        finally:
            try:
                conn.close()
            except Exception:
                pass

        # Add iptables rule if IP was resolved (synchronous -- must complete before returning)
        if ip:
            add_iptables_rule(ip, call_id)

        logger.info("Registered call-id:%s for %s (%s), expires %s", call_id, domain, ip, expires_at)
        self._send_json(200, {"status": "ok", "ip": ip, "expires_at": expires_at})

    def _handle_validate(self):
        """GET /validate?call_id=X -- check if a call-ID is valid and mark used."""
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
        call_id = params.get("call_id", [None])[0]

        if not call_id:
            self._send_json(400, {"valid": False, "reason": "Missing call_id parameter"})
            return

        conn = get_db()
        try:
            row = conn.execute(
                "SELECT call_id, domain, ip_address FROM calls "
                "WHERE call_id = ? AND used = 0 AND expires_at > datetime('now')",
                (call_id,),
            ).fetchone()

            if row:
                conn.execute("UPDATE calls SET used = 1 WHERE call_id = ?", (call_id,))
                conn.commit()
                logger.info("Validated call-id:%s for %s (marked used)", call_id, row["domain"])
                self._send_json(200, {"valid": True, "domain": row["domain"]})
            else:
                logger.info("Validation failed for call-id:%s (not found or expired)", call_id)
                self._send_json(200, {"valid": False})
        finally:
            conn.close()

    def _handle_health(self):
        """GET /health -- simple liveness check."""
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"OK")

    # -- Helpers ------------------------------------------------------------

    def _send_json(self, status, data):
        """Send a JSON response."""
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        """Route HTTP access logs through Python logging."""
        logger.info("%s %s", self.client_address[0], format % args)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    if os.environ.get("LOG_IPTABLES") == "1":
        json_handler = JsonFileHandler("/var/log/claude-secure/iptables.jsonl")
        logger.addHandler(json_handler)
        logger.info("JSON file logging enabled: /var/log/claude-secure/iptables.jsonl")

    # Initialize database
    init_db()

    # Set up default iptables rules (may fail outside Docker)
    try:
        setup_default_iptables()
    except Exception as exc:
        logger.warning("iptables setup failed (expected outside Docker): %s", exc)

    # Start background cleanup thread
    cleanup_thread = threading.Timer(CLEANUP_INTERVAL_SECONDS, _cleanup_loop)
    cleanup_thread.daemon = True
    cleanup_thread.start()
    logger.info("Background cleanup thread started (interval=%ds)", CLEANUP_INTERVAL_SECONDS)

    # Start HTTP server
    server = HTTPServer(("0.0.0.0", LISTEN_PORT), ValidatorHandler)
    logger.info("Validator HTTP server listening on :%d", LISTEN_PORT)
    server.serve_forever()
