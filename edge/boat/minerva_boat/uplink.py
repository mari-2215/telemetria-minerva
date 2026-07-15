from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import json
import urllib.error
import urllib.request

from .store import OutboxStore


@dataclass(slots=True)
class UploadResult:
    sent: int = 0
    failed: int = 0


class HttpOutboxUploader:
    def __init__(self, store: OutboxStore, endpoint: str, device_token: str, timeout_s: float = 10.0) -> None:
        self.store = store
        self.endpoint = endpoint.rstrip("/") + "/v1/ingest"
        self.device_token = device_token
        self.timeout_s = timeout_s

    def flush(self, limit: int = 100) -> UploadResult:
        result = UploadResult()
        for item in self.store.pending(limit, target="cloud"):
            body = json.dumps(item["payload"], separators=(",", ":")).encode("utf-8")
            request = urllib.request.Request(
                self.endpoint,
                data=body,
                method="POST",
                headers={"Content-Type": "application/json", "X-Device-Token": self.device_token},
            )
            try:
                with urllib.request.urlopen(request, timeout=self.timeout_s) as response:
                    if response.status not in {200, 201}:
                        raise RuntimeError(f"unexpected status {response.status}")
            except (OSError, urllib.error.HTTPError, urllib.error.URLError, RuntimeError) as exc:
                self.store.mark_failed(item["id"], str(exc), target="cloud")
                result.failed += 1
                break
            else:
                sent_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
                self.store.mark_sent(item["id"], sent_at, target="cloud")
                result.sent += 1
        return result
