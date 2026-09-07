"""
auth.py — JWT Authentication & Password Hashing
Uses PyJWT + hashlib (stdlib) — no bcrypt dependency needed.
"""
import hashlib
import hmac
import os
import time
import uuid
from typing import Optional

# ── JWT implementation using stdlib ─────────────────────────────────────────────
# We use PyJWT if available; fall back to a lightweight manual HMAC-SHA256 impl.
try:
    import jwt as _pyjwt
    _USE_PYJWT = True
except ImportError:
    _USE_PYJWT = False

import base64
import json as _json

JWT_SECRET = os.environ.get("JWT_SECRET", "navix-super-secret-key-change-in-production")
JWT_ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_SECONDS = 60 * 60 * 24 * 7   # 7 days


# ── Password Hashing ─────────────────────────────────────────────────────────────

def hash_password(plain: str) -> str:
    """PBKDF2-HMAC-SHA256 password hash (stdlib, no extra deps)."""
    salt = os.urandom(16)
    dk = hashlib.pbkdf2_hmac("sha256", plain.encode(), salt, 260_000)
    return salt.hex() + ":" + dk.hex()


def verify_password(plain: str, hashed: str) -> bool:
    """Verify a plain-text password against a stored hash."""
    try:
        salt_hex, dk_hex = hashed.split(":")
        salt = bytes.fromhex(salt_hex)
        dk = hashlib.pbkdf2_hmac("sha256", plain.encode(), salt, 260_000)
        return hmac.compare_digest(dk.hex(), dk_hex)
    except Exception:
        return False


# ── JWT Helpers ──────────────────────────────────────────────────────────────────

def _b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _b64url_decode(s: str) -> bytes:
    pad = 4 - len(s) % 4
    return base64.urlsafe_b64decode(s + "=" * (pad % 4))


def create_access_token(payload: dict) -> str:
    """Create a JWT access token."""
    data = {**payload, "iat": int(time.time()), "exp": int(time.time()) + ACCESS_TOKEN_EXPIRE_SECONDS}
    if _USE_PYJWT:
        return _pyjwt.encode(data, JWT_SECRET, algorithm=JWT_ALGORITHM)
    # Manual HMAC-SHA256 JWT
    header = _b64url_encode(_json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    body = _b64url_encode(_json.dumps(data).encode())
    sig_input = f"{header}.{body}".encode()
    sig = hmac.new(JWT_SECRET.encode(), sig_input, hashlib.sha256).digest()
    return f"{header}.{body}.{_b64url_encode(sig)}"


def decode_access_token(token: str) -> Optional[dict]:
    """Decode and validate a JWT. Returns None if invalid/expired."""
    try:
        if _USE_PYJWT:
            return _pyjwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        # Manual decode
        parts = token.split(".")
        if len(parts) != 3:
            return None
        header, body, sig = parts
        sig_input = f"{header}.{body}".encode()
        expected_sig = hmac.new(JWT_SECRET.encode(), sig_input, hashlib.sha256).digest()
        if not hmac.compare_digest(_b64url_decode(sig), expected_sig):
            return None
        data = _json.loads(_b64url_decode(body))
        if data.get("exp", 0) < time.time():
            return None
        return data
    except Exception:
        return None


# ── OTP Generation ───────────────────────────────────────────────────────────────

OTP_EXPIRE_SECONDS = 10 * 60  # 10 minutes


def generate_otp() -> tuple[str, str]:
    """Generate a 6-digit OTP and its expiry ISO timestamp."""
    from datetime import datetime, timezone, timedelta
    otp = str(uuid.uuid4().int % 1_000_000).zfill(6)
    expires_at = (datetime.now(timezone.utc) + timedelta(seconds=OTP_EXPIRE_SECONDS)).isoformat()
    return otp, expires_at


def is_otp_valid(stored_otp: str, stored_expires_at: str, provided_otp: str) -> bool:
    """Check OTP match and expiry."""
    from datetime import datetime, timezone
    if not stored_otp or not stored_expires_at:
        return False
    try:
        expires = datetime.fromisoformat(stored_expires_at)
        if datetime.now(timezone.utc) > expires:
            return False
    except Exception:
        return False
    return hmac.compare_digest(stored_otp, provided_otp.strip())


# ── FastAPI dependency ───────────────────────────────────────────────────────────

from fastapi import HTTPException, status, Depends
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials

_bearer = HTTPBearer(auto_error=False)


async def get_current_user(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(_bearer),
) -> dict:
    """FastAPI dependency: extract and validate the JWT from Authorization header."""
    if not credentials:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated")
    payload = decode_access_token(credentials.credentials)
    if not payload:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid or expired token")
    return payload


async def require_role(*roles: str):
    """Factory: returns a FastAPI dependency that enforces role membership."""
    async def _check(user: dict = Depends(get_current_user)):
        if user.get("role") not in roles:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Insufficient permissions")
        return user
    return _check
