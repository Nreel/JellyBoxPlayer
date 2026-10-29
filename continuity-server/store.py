"""Persistent users, passwords and API credentials for the continuity server.

The server used to accept any sign-in and derive a token from the email
address, which meant every client was trusted and nothing survived a restart.
This module stores real accounts in SQLite:

* passwords are hashed with scrypt, never stored or logged in clear text;
* credentials are HMAC-signed tokens that reference a row, so the database
  holds no usable secret while revocation still takes effect immediately.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
import sqlite3
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SCRYPT_N = 2**14
SCRYPT_R = 8
SCRYPT_P = 1
SCRYPT_DKLEN = 32

SESSION_COOKIE = "continuity_admin"
TOKEN_PREFIX = "jbc_"

MIN_PASSWORD_LENGTH = 8
MAX_PASSWORD_LENGTH = 256

KIND_APP = "app"
KIND_API = "api"


class StoreError(Exception):
    """Base class for errors the HTTP layer turns into 4xx responses."""


class NotFound(StoreError):
    pass


class Conflict(StoreError):
    pass


class ValidationError(StoreError):
    pass


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def normalize_login(login: str) -> str:
    """Logins are case-insensitive and whitespace-trimmed."""
    return login.strip().casefold()


def hash_password(password: str) -> str:
    if not MIN_PASSWORD_LENGTH <= len(password) <= MAX_PASSWORD_LENGTH:
        raise ValidationError(
            f"Password must be between {MIN_PASSWORD_LENGTH} and "
            f"{MAX_PASSWORD_LENGTH} characters."
        )
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(
        password.encode("utf-8"),
        salt=salt,
        n=SCRYPT_N,
        r=SCRYPT_R,
        p=SCRYPT_P,
        dklen=SCRYPT_DKLEN,
    )
    return f"scrypt${SCRYPT_N}${SCRYPT_R}${SCRYPT_P}${_b64(salt)}${_b64(digest)}"


def verify_password(password: str, encoded: str) -> bool:
    try:
        scheme, n, r, p, salt_b64, digest_b64 = encoded.split("$")
        if scheme != "scrypt":
            return False
        expected = _unb64(digest_b64)
        actual = hashlib.scrypt(
            password.encode("utf-8"),
            salt=_unb64(salt_b64),
            n=int(n),
            r=int(r),
            p=int(p),
            dklen=len(expected),
        )
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(actual, expected)


def _public_user(row: sqlite3.Row) -> Dict[str, Any]:
    data = dict(row)
    data.pop("password_hash", None)
    for key in ("is_admin", "disabled"):
        if key in data:
            data[key] = bool(data[key])
    return data


class SessionTokens:
    """Signed, stateless administrator session cookies."""

    def __init__(self, secret: bytes, ttl_seconds: int = 12 * 60 * 60) -> None:
        self._secret = secret
        self.ttl_seconds = ttl_seconds

    def issue(self, user_id: str) -> str:
        expires = int(time.time()) + self.ttl_seconds
        payload = _b64(
            json.dumps({"uid": user_id, "exp": expires}, separators=(",", ":"))
            .encode("utf-8")
        )
        signature = hmac.new(
            self._secret, payload.encode("ascii"), hashlib.sha256
        ).hexdigest()
        return f"{payload}.{signature}"

    def verify(self, value: Optional[str]) -> Optional[str]:
        if not value or "." not in value:
            return None
        payload, signature = value.rsplit(".", 1)
        expected = hmac.new(
            self._secret, payload.encode("ascii"), hashlib.sha256
        ).hexdigest()
        if not hmac.compare_digest(signature, expected):
            return None
        try:
            data = json.loads(_unb64(payload))
            if int(data["exp"]) < int(time.time()):
                return None
            return str(data["uid"])
        except (ValueError, KeyError, TypeError):
            return None


class Store:
    def __init__(self, path: str | Path) -> None:
        self.path = str(path)
        if self.path != ":memory:":
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(self.path, check_same_thread=False, timeout=10)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA foreign_keys = ON")
        if self.path != ":memory:":
            self._conn.execute("PRAGMA journal_mode = WAL")
        self._init_schema()
        self._secret = self._load_secret()

    @property
    def secret(self) -> bytes:
        return self._secret

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    def _init_schema(self) -> None:
        with self._lock:
            self._conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS users (
                    id TEXT PRIMARY KEY,
                    login TEXT NOT NULL,
                    login_key TEXT NOT NULL UNIQUE,
                    name TEXT NOT NULL DEFAULT '',
                    password_hash TEXT NOT NULL,
                    is_admin INTEGER NOT NULL DEFAULT 0,
                    disabled INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS credentials (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL DEFAULT 'api',
                    label TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    last_used_at TEXT,
                    revoked_at TEXT
                );

                CREATE INDEX IF NOT EXISTS credentials_user_idx
                    ON credentials(user_id);

                CREATE TABLE IF NOT EXISTS meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """
            )
            self._conn.commit()

    def _load_secret(self) -> bytes:
        row = self._conn.execute(
            "SELECT value FROM meta WHERE key = 'token_secret'"
        ).fetchone()
        if row is None:
            self._conn.execute(
                "INSERT OR IGNORE INTO meta (key, value) VALUES ('token_secret', ?)",
                (_b64(secrets.token_bytes(32)),),
            )
            self._conn.commit()
            row = self._conn.execute(
                "SELECT value FROM meta WHERE key = 'token_secret'"
            ).fetchone()
            assert row is not None
        return _unb64(row["value"])

    # -- users -------------------------------------------------------------

    def count_users(self) -> int:
        with self._lock:
            row = self._conn.execute("SELECT COUNT(*) AS n FROM users").fetchone()
            return int(row["n"])

    def has_admin(self) -> bool:
        with self._lock:
            return self._active_admin_count() > 0

    def _active_admin_count(self) -> int:
        row = self._conn.execute(
            "SELECT COUNT(*) AS n FROM users WHERE is_admin = 1 AND disabled = 0"
        ).fetchone()
        return int(row["n"])

    @staticmethod
    def _is_active_admin(row: sqlite3.Row | Dict[str, Any]) -> bool:
        return bool(row["is_admin"]) and not bool(row["disabled"])

    def _user_row(self, user_id: str) -> Optional[sqlite3.Row]:
        return self._conn.execute(
            "SELECT * FROM users WHERE id = ?", (user_id,)
        ).fetchone()

    def get_user(self, user_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            row = self._user_row(user_id)
            return _public_user(row) if row else None

    def get_user_by_login(self, login: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM users WHERE login_key = ?", (normalize_login(login),)
            ).fetchone()
            return _public_user(row) if row else None

    def list_users(self) -> List[Dict[str, Any]]:
        with self._lock:
            rows = self._conn.execute(
                """
                SELECT u.*,
                       (SELECT COUNT(*) FROM credentials c
                         WHERE c.user_id = u.id) AS credential_count,
                       (SELECT COUNT(*) FROM credentials c
                         WHERE c.user_id = u.id AND c.revoked_at IS NULL)
                         AS active_credential_count
                  FROM users u
                 ORDER BY u.login_key
                """
            ).fetchall()
            return [_public_user(row) for row in rows]

    @staticmethod
    def _clean_login(login: str) -> str:
        value = login.strip()
        if not value:
            raise ValidationError("Login is required.")
        if len(value) > 64:
            raise ValidationError("Login must be 64 characters or fewer.")
        return value

    def _insert_user(
        self,
        login: str,
        password: str,
        name: str,
        is_admin: bool,
        require_no_admin: bool,
    ) -> Dict[str, Any]:
        display_login = self._clean_login(login)
        password_hash = hash_password(password)
        display_name = name.strip()[:80]
        now = _now()
        user_id = uuid.uuid4().hex
        with self._lock:
            if require_no_admin and self._active_admin_count() > 0:
                raise Conflict("Setup has already been completed.")
            try:
                self._conn.execute(
                    """
                    INSERT INTO users
                        (id, login, login_key, name, password_hash,
                         is_admin, disabled, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
                    """,
                    (
                        user_id,
                        display_login,
                        normalize_login(display_login),
                        display_name,
                        password_hash,
                        int(is_admin),
                        now,
                        now,
                    ),
                )
                self._conn.commit()
            except sqlite3.IntegrityError as exc:
                self._conn.rollback()
                raise Conflict("That login already exists.") from exc
            row = self._user_row(user_id)
            assert row is not None
            return _public_user(row)

    def create_user(
        self, login: str, password: str, name: str = "", is_admin: bool = False
    ) -> Dict[str, Any]:
        return self._insert_user(login, password, name, is_admin, False)

    def create_first_admin(
        self, login: str, password: str, name: str = ""
    ) -> Dict[str, Any]:
        return self._insert_user(login, password, name, True, True)

    def update_user(
        self,
        user_id: str,
        *,
        login: Optional[str] = None,
        name: Optional[str] = None,
        password: Optional[str] = None,
        is_admin: Optional[bool] = None,
        disabled: Optional[bool] = None,
    ) -> Dict[str, Any]:
        password_hash = hash_password(password) if password is not None else None
        with self._lock:
            row = self._user_row(user_id)
            if row is None:
                raise NotFound("User not found.")

            new_login = row["login"] if login is None else self._clean_login(login)
            new_name = row["name"] if name is None else name.strip()[:80]
            new_admin = row["is_admin"] if is_admin is None else int(is_admin)
            new_disabled = row["disabled"] if disabled is None else int(disabled)

            if self._is_active_admin(row) and not (
                new_admin and not new_disabled
            ) and self._active_admin_count() <= 1:
                raise Conflict(
                    "Cannot remove or disable the last active administrator."
                )

            new_key = normalize_login(new_login)
            if new_key != row["login_key"] and self._conn.execute(
                "SELECT 1 FROM users WHERE login_key = ? AND id != ?",
                (new_key, user_id),
            ).fetchone():
                raise Conflict("That login already exists.")

            fields: Dict[str, Any] = {
                "login": new_login,
                "login_key": new_key,
                "name": new_name,
                "is_admin": new_admin,
                "disabled": new_disabled,
                "updated_at": _now(),
            }
            if password_hash is not None:
                fields["password_hash"] = password_hash
            assignments = ", ".join(f"{key} = ?" for key in fields)
            try:
                self._conn.execute(
                    f"UPDATE users SET {assignments} WHERE id = ?",
                    (*fields.values(), user_id),
                )
                if password_hash is not None:
                    # A password change must invalidate app tokens minted with
                    # the old password, otherwise a leaked token outlives it.
                    self._conn.execute(
                        "UPDATE credentials SET revoked_at = ? "
                        "WHERE user_id = ? AND kind = ? AND revoked_at IS NULL",
                        (_now(), user_id, KIND_APP),
                    )
                self._conn.commit()
            except sqlite3.IntegrityError as exc:
                self._conn.rollback()
                raise Conflict("That login already exists.") from exc
            updated = self._user_row(user_id)
            assert updated is not None
            return _public_user(updated)

    def delete_user(self, user_id: str) -> None:
        with self._lock:
            row = self._user_row(user_id)
            if row is None:
                raise NotFound("User not found.")
            if self._is_active_admin(row) and self._active_admin_count() <= 1:
                raise Conflict("Cannot delete the last active administrator.")
            self._conn.execute("DELETE FROM users WHERE id = ?", (user_id,))
            self._conn.commit()

    def authenticate_password(
        self, login: str, password: str
    ) -> Optional[Dict[str, Any]]:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM users WHERE login_key = ?",
                (normalize_login(login),),
            ).fetchone()
        if row is None:
            return None
        if not verify_password(password, row["password_hash"]):
            return None
        return _public_user(row)

    # -- credentials -------------------------------------------------------

    def _sign(self, credential_id: str) -> str:
        return hmac.new(
            self._secret, f"cred:{credential_id}".encode("ascii"), hashlib.sha256
        ).hexdigest()[:32]

    def mint_token(self, credential_id: str) -> str:
        return f"{TOKEN_PREFIX}{credential_id}.{self._sign(credential_id)}"

    def _credential_row(self, credential_id: str) -> Optional[sqlite3.Row]:
        return self._conn.execute(
            "SELECT * FROM credentials WHERE id = ?", (credential_id,)
        ).fetchone()

    def _insert_credential(
        self, user_id: str, kind: str, label: str
    ) -> sqlite3.Row:
        credential_id = uuid.uuid4().hex
        self._conn.execute(
            """
            INSERT INTO credentials
                (id, user_id, kind, label, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            (credential_id, user_id, kind, label.strip()[:80], _now()),
        )
        self._conn.commit()
        row = self._credential_row(credential_id)
        assert row is not None
        return row

    def ensure_app_credential(self, user_id: str) -> Tuple[Dict[str, Any], str]:
        """Return the reusable app credential for a user, minting one if needed.

        The token is derived from the credential id and the server secret, so a
        device that signs in twice with the same password keeps its token while
        the credential manager can still revoke it.
        """
        with self._lock:
            if self._user_row(user_id) is None:
                raise NotFound("User not found.")
            row = self._conn.execute(
                "SELECT * FROM credentials WHERE user_id = ? AND kind = ? "
                "AND revoked_at IS NULL ORDER BY created_at DESC LIMIT 1",
                (user_id, KIND_APP),
            ).fetchone()
            if row is None:
                row = self._insert_credential(user_id, KIND_APP, "App sign-in")
            return _public_credential(row), self.mint_token(row["id"])

    def create_credential(
        self, user_id: str, label: str = ""
    ) -> Tuple[Dict[str, Any], str]:
        with self._lock:
            if self._user_row(user_id) is None:
                raise NotFound("User not found.")
            row = self._insert_credential(
                user_id, KIND_API, label or "API credential"
            )
            return _public_credential(row), self.mint_token(row["id"])

    def list_credentials(
        self, user_id: Optional[str] = None
    ) -> List[Dict[str, Any]]:
        query = """
            SELECT c.*, u.login AS user_login
              FROM credentials c
              JOIN users u ON u.id = c.user_id
        """
        params: Tuple[Any, ...] = ()
        if user_id is not None:
            query += " WHERE c.user_id = ?"
            params = (user_id,)
        query += " ORDER BY c.created_at DESC, c.label"
        with self._lock:
            return [
                _public_credential(row)
                for row in self._conn.execute(query, params).fetchall()
            ]

    def revoke_credential(self, credential_id: str) -> Dict[str, Any]:
        with self._lock:
            row = self._credential_row(credential_id)
            if row is None:
                raise NotFound("Credential not found.")
            if row["revoked_at"] is None:
                self._conn.execute(
                    "UPDATE credentials SET revoked_at = ? WHERE id = ?",
                    (_now(), credential_id),
                )
                self._conn.commit()
                row = self._credential_row(credential_id)
                assert row is not None
            return _public_credential(row)

    def delete_credential(self, credential_id: str) -> None:
        with self._lock:
            if self._credential_row(credential_id) is None:
                raise NotFound("Credential not found.")
            self._conn.execute(
                "DELETE FROM credentials WHERE id = ?", (credential_id,)
            )
            self._conn.commit()

    def credential_id_for_token(self, token: str) -> Optional[str]:
        """Return the credential id a token was minted for, if the signature is valid."""
        value = token.strip()
        if not value.startswith(TOKEN_PREFIX) or "." not in value:
            return None
        credential_id, signature = value[len(TOKEN_PREFIX):].rsplit(".", 1)
        if hmac.compare_digest(signature, self._sign(credential_id)):
            return credential_id
        return None

    def user_for_token(self, token: str) -> Optional[Dict[str, Any]]:
        """Resolve a credential token to its (enabled) user, or None."""
        value = token.strip()
        if not value.startswith(TOKEN_PREFIX) or "." not in value:
            return None
        credential_id, signature = value[len(TOKEN_PREFIX):].rsplit(".", 1)
        if not hmac.compare_digest(signature, self._sign(credential_id)):
            return None
        with self._lock:
            row = self._conn.execute(
                """
                SELECT u.*, c.id AS credential_id, c.revoked_at AS credential_revoked
                  FROM credentials c
                  JOIN users u ON u.id = c.user_id
                 WHERE c.id = ?
                """,
                (credential_id,),
            ).fetchone()
            if row is None or row["credential_revoked"] is not None:
                return None
            if row["disabled"]:
                return None
            self._conn.execute(
                "UPDATE credentials SET last_used_at = ? WHERE id = ?",
                (_now(), credential_id),
            )
            self._conn.commit()
            user = _public_user(row)
        user.pop("credential_id", None)
        user.pop("credential_revoked", None)
        return user


def _public_credential(row: sqlite3.Row) -> Dict[str, Any]:
    data = dict(row)
    data["revoked"] = data.get("revoked_at") is not None
    data["prefix"] = f"{TOKEN_PREFIX}{str(data['id'])[:8]}"
    return data


__all__ = [
    "Conflict",
    "KIND_API",
    "KIND_APP",
    "MIN_PASSWORD_LENGTH",
    "NotFound",
    "SESSION_COOKIE",
    "SessionTokens",
    "Store",
    "StoreError",
    "TOKEN_PREFIX",
    "ValidationError",
    "hash_password",
    "normalize_login",
    "verify_password",
]
