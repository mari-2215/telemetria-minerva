from __future__ import annotations

import argparse
from contextlib import ExitStack
import logging
import os
from pathlib import Path
import signal
import threading
import time

from .service import BoatTelemetryService
from .store import OutboxStore
from .uplink import HttpOutboxUploader
from .rak3172 import LoRaOutboxUploader, Rak3172Modem
from .autopilot import HttpMissionClient, MissionAutopilot, MissionSyncError


def main() -> None:
    parser = argparse.ArgumentParser(description="Servico embarcado Telemetria Minerva")
    parser.add_argument("--serial", default=os.getenv("MINERVA_SERIAL_PORT", "/dev/ttyACM0"))
    parser.add_argument("--baud", type=int, default=int(os.getenv("MINERVA_SERIAL_BAUD", "115200")))
    parser.add_argument("--database", default=os.getenv("MINERVA_EDGE_DB", "/var/lib/minerva-telemetry/outbox.db"))
    parser.add_argument("--api", default=os.getenv("MINERVA_API_URL"))
    parser.add_argument("--device-token", default=os.getenv("MINERVA_DEVICE_TOKEN"))
    parser.add_argument("--boat-id", default=os.getenv("MINERVA_BOAT_ID", "azimutal-01"))
    parser.add_argument("--lora-serial", default=os.getenv("MINERVA_LORA_SERIAL"))
    parser.add_argument("--lora-dev-eui", default=os.getenv("MINERVA_LORA_DEV_EUI"))
    parser.add_argument("--lora-app-eui", default=os.getenv("MINERVA_LORA_APP_EUI"))
    parser.add_argument("--lora-app-key", default=os.getenv("MINERVA_LORA_APP_KEY"))
    args = parser.parse_args()

    try:
        import serial
    except ImportError as exc:
        raise SystemExit("pyserial nao instalado; execute pip install -e .") from exc

    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
    Path(args.database).parent.mkdir(parents=True, exist_ok=True)
    store = OutboxStore(args.database)
    service = BoatTelemetryService(store)
    uploader = HttpOutboxUploader(store, args.api, args.device_token) if args.api and args.device_token else None
    mission_client = HttpMissionClient(args.api, args.device_token) if args.api and args.device_token else None
    autopilot = MissionAutopilot(store, args.boat_id, mission_client)
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())

    try:
        with ExitStack() as stack:
            port = stack.enter_context(serial.Serial(args.serial, args.baud, timeout=0.25))
            lora_uploader = None
            if args.lora_serial:
                if not all((args.lora_dev_eui, args.lora_app_eui, args.lora_app_key)):
                    raise SystemExit("credenciais OTAA incompletas para o RAK3172")
                lora_port = stack.enter_context(serial.Serial(args.lora_serial, 115200, timeout=0.5))
                modem = Rak3172Modem(lora_port)
                modem.configure_otaa(args.lora_dev_eui, args.lora_app_eui, args.lora_app_key)
                modem.join()
                lora_uploader = LoRaOutboxUploader(store, modem)
            logging.info("coletando telemetria em %s @ %d", args.serial, args.baud)
            last_flush = 0.0
            last_lora_flush = 0.0
            while not stop.is_set():
                chunk = port.read(4096)
                if chunk:
                    service.ingest_serial_bytes(chunk)
                now = time.monotonic()
                try:
                    if autopilot.poll_remote(now):
                        logging.info("nova missao salva e ativada para %s", args.boat_id)
                except MissionSyncError as exc:
                    logging.warning("sincronizacao de missao indisponivel: %s", exc)
                try:
                    command = autopilot.build_command(service.last_telemetry, now)
                    if command:
                        port.write(command)
                except (MissionSyncError, ValueError) as exc:
                    logging.error("comando de piloto automatico rejeitado localmente: %s", exc)
                if uploader and now - last_flush >= 1.0:
                    outcome = uploader.flush(limit=50)
                    if outcome.sent or outcome.failed:
                        logging.info("uplink sent=%d failed=%d", outcome.sent, outcome.failed)
                    last_flush = now
                if lora_uploader and now - last_lora_flush >= 2.0:
                    outcome = lora_uploader.flush(limit=1)
                    if outcome.sent or outcome.failed:
                        logging.info("lorawan sent=%d failed=%d", outcome.sent, outcome.failed)
                    last_lora_flush = now
    finally:
        logging.info("encerrando accepted=%d invalid=%d crc_errors=%d", service.stats.accepted, service.stats.invalid_payloads, service.decoder.crc_errors)
        store.close()


if __name__ == "__main__":
    main()
