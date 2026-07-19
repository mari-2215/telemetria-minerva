from __future__ import annotations

from dataclasses import dataclass
import hmac
import json
import os

from fastapi import Depends, Header, HTTPException, status


ROLES = {"admin", "operator", "laboratory", "read", "captain", "crew"}


@dataclass(frozen=True, slots=True)
class Principal:
    name: str
    role: str

    @property
    def is_captain(self) -> bool:
        return self.role in {"admin", "operator", "captain"}


@dataclass(frozen=True, slots=True)
class CapabilitySet:
    can_control: bool
    can_acknowledge_alerts: bool


def capabilities_for(principal: Principal) -> CapabilitySet:
    return CapabilitySet(
        can_control=principal.role in {"admin", "operator", "captain"},
        can_acknowledge_alerts=principal.role in {"admin", "operator", "captain", "laboratory"},
    )


def configured_tokens() -> dict[str, Principal]:
    raw = os.getenv(
        "MINERVA_ACCESS_TOKENS_JSON",
        '{"dev-viewer-token":{"name":"Desenvolvimento","role":"admin"}}',
    )
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError("MINERVA_ACCESS_TOKENS_JSON is invalid") from exc
    result: dict[str, Principal] = {}
    for token, value in decoded.items():
        if not isinstance(token, str) or len(token) < 8 or not isinstance(value, dict):
            raise RuntimeError("invalid access token entry")
        role = value.get("role")
        name = value.get("name")
        if role not in ROLES or not isinstance(name, str) or not name:
            raise RuntimeError("invalid access token principal")
        result[token] = Principal(name=name, role=role)
    return result


def authenticate_token(token: str) -> Principal | None:
    for expected, principal in configured_tokens().items():
        if hmac.compare_digest(token, expected):
            return principal
    return None


def current_principal(authorization: str | None = Header(default=None)) -> Principal:
    supplied = authorization.removeprefix("Bearer ") if authorization else ""
    principal = authenticate_token(supplied)
    if principal is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid access token")
    return principal


def require_roles(*roles: str):
    def dependency(principal: Principal = Depends(current_principal)) -> Principal:
        if principal.role not in roles:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="insufficient role")
        return principal

    return dependency
