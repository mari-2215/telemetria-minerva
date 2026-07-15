from __future__ import annotations

from contextlib import asynccontextmanager
import hmac
import os
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, WebSocket, WebSocketDisconnect, status
from fastapi.middleware.cors import CORSMiddleware

from minerva_protocol import Telemetry, TelemetryValidationError, decode_base64_lora_payload

from .store import TelemetryStore
from .auth import Principal, authenticate_token, current_principal, require_roles


class ConnectionManager:
    def __init__(self) -> None:
        self._connections: dict[str, set[WebSocket]] = {}

    async def connect(self, boat_id: str, websocket: WebSocket) -> None:
        await websocket.accept()
        self._connections.setdefault(boat_id, set()).add(websocket)

    def disconnect(self, boat_id: str, websocket: WebSocket) -> None:
        listeners = self._connections.get(boat_id)
        if listeners:
            listeners.discard(websocket)
            if not listeners:
                self._connections.pop(boat_id, None)

    async def publish(self, boat_id: str, payload: dict[str, Any]) -> None:
        dead: list[WebSocket] = []
        for websocket in self._connections.get(boat_id, set()).copy():
            try:
                await websocket.send_json(payload)
            except RuntimeError:
                dead.append(websocket)
        for websocket in dead:
            self.disconnect(boat_id, websocket)


def create_app(store: TelemetryStore | None = None) -> FastAPI:
    owned_store = store is None

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if app.state.store is None:
            database_path = Path(os.getenv("MINERVA_DB_PATH", "data/backend.db"))
            database_path.parent.mkdir(parents=True, exist_ok=True)
            app.state.store = TelemetryStore(database_path)
        yield
        if owned_store and app.state.store is not None:
            app.state.store.close()

    app = FastAPI(title="Telemetria Minerva API", version="0.1.0", lifespan=lifespan)
    app.state.store = store
    app.state.connections = ConnectionManager()
    origins = [value.strip() for value in os.getenv("MINERVA_CORS_ORIGINS", "http://localhost:3000").split(",") if value.strip()]
    app.add_middleware(CORSMiddleware, allow_origins=origins, allow_methods=["GET", "POST"], allow_headers=["*"])

    def current_store(request: Request) -> TelemetryStore:
        return request.app.state.store

    @app.get("/healthz")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/v1/ingest", status_code=status.HTTP_201_CREATED)
    async def ingest(
        payload: dict[str, Any],
        request: Request,
        x_device_token: str | None = Header(default=None),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> dict[str, Any]:
        expected = os.getenv("MINERVA_DEVICE_TOKEN", "dev-device-token")
        if not x_device_token or not hmac.compare_digest(x_device_token, expected):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid device token")
        try:
            telemetry = Telemetry.from_dict(payload)
        except TelemetryValidationError as exc:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=str(exc)) from exc
        inserted = telemetry_store.insert(telemetry)
        if inserted:
            await request.app.state.connections.publish(telemetry.boat_id, telemetry.data)
        return {"accepted": inserted, "duplicate": not inserted}

    @app.post("/v1/integrations/chirpstack", status_code=status.HTTP_201_CREATED)
    async def chirpstack(
        payload: dict[str, Any],
        request: Request,
        x_integration_token: str | None = Header(default=None),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> dict[str, Any]:
        expected = os.getenv("MINERVA_CHIRPSTACK_TOKEN", "dev-chirpstack-token")
        if not x_integration_token or not hmac.compare_digest(x_integration_token, expected):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid integration token")
        try:
            device = payload["deviceInfo"]
            boat_id = device.get("deviceName") or device["devEui"]
            rx_info = (payload.get("rxInfo") or [{}])[0]
            telemetry = decode_base64_lora_payload(
                payload["data"],
                boat_id,
                rssi_dbm=rx_info.get("rssi"),
                snr_db=rx_info.get("snr"),
            )
        except (KeyError, IndexError, TypeError, TelemetryValidationError) as exc:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=str(exc)) from exc
        inserted = telemetry_store.insert(telemetry)
        if inserted:
            await request.app.state.connections.publish(telemetry.boat_id, telemetry.data)
        return {"accepted": inserted, "duplicate": not inserted}

    @app.get("/v1/me")
    def me(principal: Principal = Depends(current_principal)) -> dict[str, str]:
        return {"name": principal.name, "role": principal.role}

    @app.get("/v1/boats", dependencies=[Depends(current_principal)])
    def boats(telemetry_store: TelemetryStore = Depends(current_store)) -> list[dict[str, Any]]:
        return telemetry_store.boats()

    @app.get("/v1/boats/{boat_id}/latest", dependencies=[Depends(current_principal)])
    def latest(boat_id: str, telemetry_store: TelemetryStore = Depends(current_store)) -> dict[str, Any]:
        result = telemetry_store.latest(boat_id)
        if result is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="boat not found")
        return result

    @app.get("/v1/boats/{boat_id}/samples", dependencies=[Depends(current_principal)])
    def samples(
        boat_id: str,
        limit: int = Query(default=500, ge=1, le=5000),
        before_sequence: int | None = Query(default=None, ge=0),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> list[dict[str, Any]]:
        return telemetry_store.history(boat_id, limit, before_sequence)

    @app.get("/v1/alerts")
    def alerts(
        active_only: bool = Query(default=True),
        limit: int = Query(default=500, ge=1, le=5000),
        _: Principal = Depends(current_principal),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> list[dict[str, Any]]:
        return telemetry_store.alerts(active_only=active_only, limit=limit)

    @app.post("/v1/alerts/{alert_id}/ack")
    def acknowledge_alert(
        alert_id: int,
        principal: Principal = Depends(require_roles("admin", "operator", "laboratory")),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> dict[str, bool]:
        acknowledged = telemetry_store.acknowledge_alert(alert_id, Telemetry.utc_now(), principal.name)
        if not acknowledged:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="active alert not found")
        return {"acknowledged": True}

    @app.websocket("/v1/ws/boats/{boat_id}")
    async def stream(websocket: WebSocket, boat_id: str, token: str = Query()) -> None:
        if authenticate_token(token) is None:
            await websocket.close(code=4401)
            return
        manager: ConnectionManager = websocket.app.state.connections
        await manager.connect(boat_id, websocket)
        try:
            while True:
                await websocket.receive_text()
        except WebSocketDisconnect:
            manager.disconnect(boat_id, websocket)

    return app
