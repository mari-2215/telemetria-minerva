from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import time
from typing import Protocol

from minerva_protocol import Telemetry, encode_lora_payload

from .store import OutboxStore


class SerialPort(Protocol):
    def write(self, data: bytes) -> int: ...
    def readline(self) -> bytes: ...
    def reset_input_buffer(self) -> None: ...


class RakCommandError(RuntimeError):
    pass


class Rak3172Modem:
    """Driver minimo para RAK3172/RUI3 por comandos AT."""

    def __init__(self, port: SerialPort, command_timeout_s: float = 5.0) -> None:
        self.port = port
        self.command_timeout_s = command_timeout_s

    def command(self, command: str, *, timeout_s: float | None = None) -> list[str]:
        self.port.reset_input_buffer()
        self.port.write((command + "\r\n").encode("ascii"))
        deadline = time.monotonic() + (timeout_s or self.command_timeout_s)
        lines: list[str] = []
        while time.monotonic() < deadline:
            raw = self.port.readline()
            if not raw:
                continue
            line = raw.decode("ascii", errors="replace").strip()
            if not line or line == command:
                continue
            lines.append(line)
            if line == "OK":
                return lines
            if "ERROR" in line or line.startswith("AT_"):
                raise RakCommandError(f"{command}: {line}")
        raise RakCommandError(f"{command}: timeout; response={lines}")

    def configure_otaa(self, dev_eui: str, app_eui: str, app_key: str, *, band: int = 6) -> None:
        for value, length, name in ((dev_eui, 16, "dev_eui"), (app_eui, 16, "app_eui"), (app_key, 32, "app_key")):
            if len(value) != length or any(character not in "0123456789abcdefABCDEF" for character in value):
                raise ValueError(f"invalid {name}")
        for command in (
            "AT+NWM=1",
            f"AT+BAND={band}",  # 6 = AU915; validar mascara de canais com o gateway escolhido.
            "AT+NJM=1",
            "AT+CLASS=A",
            "AT+ADR=1",
            "AT+CFM=0",
            f"AT+DEVEUI={dev_eui}",
            f"AT+APPEUI={app_eui}",
            f"AT+APPKEY={app_key}",
        ):
            self.command(command)

    def join(self) -> None:
        self.command("AT+JOIN=1:1:8:0", timeout_s=20.0)

    def send(self, payload: bytes, port: int = 2) -> None:
        if not 1 <= port <= 223:
            raise ValueError("LoRaWAN port must be 1..223")
        self.command(f"AT+SEND={port}:{payload.hex().upper()}", timeout_s=15.0)


@dataclass(slots=True)
class LoRaUploadResult:
    sent: int = 0
    failed: int = 0


class LoRaOutboxUploader:
    def __init__(self, store: OutboxStore, modem: Rak3172Modem) -> None:
        self.store = store
        self.modem = modem

    def flush(self, limit: int = 10) -> LoRaUploadResult:
        result = LoRaUploadResult()
        pending = self.store.pending(max(limit, 1000), target="lorawan")
        if not pending:
            return result
        critical = [item for item in pending if item["payload"].get("status", {}).get("severity") == "critical"]
        item = critical[0] if critical else pending[-1]
        if not critical and len(pending) > 1:
            discarded_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            self.store.mark_discarded([candidate["id"] for candidate in pending[:-1]], discarded_at, "lorawan")
        for item in [item]:
            try:
                telemetry = Telemetry.from_dict(item["payload"])
                self.modem.send(encode_lora_payload(telemetry))
            except (ValueError, RakCommandError) as exc:
                self.store.mark_failed(item["id"], str(exc), target="lorawan")
                result.failed += 1
                break
            else:
                sent_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
                self.store.mark_sent(item["id"], sent_at, target="lorawan")
                result.sent += 1
        return result
