from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def stable_test_access_tokens(monkeypatch: pytest.MonkeyPatch) -> None:
    """Evita que tokens exportados no terminal contaminem os testes."""
    monkeypatch.setenv(
        "MINERVA_ACCESS_TOKENS_JSON",
        '{"dev-viewer-token":{"name":"Desenvolvimento","role":"admin"}}',
    )
