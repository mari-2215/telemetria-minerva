from collections import deque
import json
from pathlib import Path
import tempfile

from minerva_boat.rak3172 import LoRaOutboxUploader, Rak3172Modem
from minerva_boat.store import OutboxStore
from minerva_protocol import Telemetry


class FakeSerial:
    def __init__(self):
        self.commands = []
        self.responses = deque()

    def reset_input_buffer(self):
        pass

    def write(self, data):
        command = data.decode().strip()
        self.commands.append(command)
        self.responses.extend([b"OK\r\n"])
        return len(data)

    def readline(self):
        return self.responses.popleft() if self.responses else b""


def value(sequence=1):
    return {
        "schema_version": 1,
        "boat_id": "azimutal-01",
        "sequence": sequence,
        "recorded_at": "2026-07-14T20:00:00Z",
        "position": {"latitude_deg": -22.8, "longitude_deg": -43.2, "fix": 3},
        "status": {"severity": "ok", "alarms": []},
    }


def test_configure_and_send():
    serial = FakeSerial()
    modem = Rak3172Modem(serial)
    modem.configure_otaa("0011223344556677", "0102030405060708", "00112233445566778899AABBCCDDEEFF")
    modem.join()
    modem.send(b"abc")
    assert "AT+BAND=6" in serial.commands
    assert serial.commands[-1] == "AT+SEND=2:616263"


def test_lora_delivery_is_independent_from_cloud_delivery():
    with tempfile.TemporaryDirectory() as directory:
        store = OutboxStore(Path(directory) / "outbox.db")
        store.append(Telemetry.from_dict(value()))
        serial = FakeSerial()
        result = LoRaOutboxUploader(store, Rak3172Modem(serial)).flush()
        assert result.sent == 1
        assert store.pending(target="lorawan") == []
        assert len(store.pending(target="cloud")) == 1
        store.close()


def test_lora_coalesces_normal_samples_but_preserves_critical_alarm():
    with tempfile.TemporaryDirectory() as directory:
        store = OutboxStore(Path(directory) / "outbox.db")
        store.append(Telemetry.from_dict(value(1)))
        store.append(Telemetry.from_dict(value(2)))
        critical = value(3)
        critical["status"] = {"severity": "critical", "alarms": ["WATER_DETECTED"]}
        store.append(Telemetry.from_dict(critical))
        store.append(Telemetry.from_dict(value(4)))
        serial = FakeSerial()
        uploader = LoRaOutboxUploader(store, Rak3172Modem(serial))
        assert uploader.flush().sent == 1
        assert "AT+SEND=2:" in serial.commands[-1]
        pending_sequences = [item["payload"]["sequence"] for item in store.pending(target="lorawan")]
        assert pending_sequences == [1, 2, 4]
        store.close()
