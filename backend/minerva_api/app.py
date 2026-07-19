from __future__ import annotations

from contextlib import asynccontextmanager
import hmac
import os
from pathlib import Path
from typing import Any
from uuid import uuid4

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, WebSocket, WebSocketDisconnect, status
from fastapi.middleware.cors import CORSMiddleware

from minerva_protocol import Mission, MissionValidationError, Telemetry, TelemetryValidationError, decode_base64_lora_payload

from .store import TelemetryStore
from .auth import Principal, authenticate_token, capabilities_for, current_principal, require_roles


CAPTAIN_ROLES = ("admin", "operator", "captain")
ALERT_ROLES = ("admin", "operator", "captain", "laboratory")


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

    app = FastAPI(title="Telemetria Minerva API", version="0.3.0", lifespan=lifespan)
    app.state.store = store
    app.state.connections = ConnectionManager()
    origins = [value.strip() for value in os.getenv("MINERVA_CORS_ORIGINS", "http://localhost:3000").split(",") if value.strip()]
    app.add_middleware(
        CORSMiddleware,
        allow_origins=origins,
        allow_methods=["GET", "POST", "DELETE"],
        allow_headers=["*"],
    )

    def current_store(request: Request) -> TelemetryStore:
        return request.app.state.store

    def require_device_token(x_device_token: str | None) -> None:
        expected = os.getenv("MINERVA_DEVICE_TOKEN", "dev-device-token")
        if not x_device_token or not hmac.compare_digest(x_device_token, expected):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid device token")

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
        require_device_token(x_device_token)
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
    def me(principal: Principal = Depends(current_principal)) -> dict[str, Any]:
        capabilities = capabilities_for(principal)
        return {
            "name": principal.name,
            "role": principal.role,
            "can_control": capabilities.can_control,
            "can_acknowledge_alerts": capabilities.can_acknowledge_alerts,
        }

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
        principal: Principal = Depends(require_roles(*ALERT_ROLES)),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> dict[str, bool]:
        acknowledged = telemetry_store.acknowledge_alert(alert_id, Telemetry.utc_now(), principal.name)
        if not acknowledged:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="active alert not found")
        return {"acknowledged": True}

    @app.post("/v1/missions", status_code=status.HTTP_201_CREATED)
    def create_mission(
        payload: dict[str, Any],
        principal: Principal = Depends(require_roles(*CAPTAIN_ROLES)),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> dict[str, Any]:
        candidate = dict(payload)
        candidate["mission_id"] = candidate.get("mission_id") or uuid4().hex[:12]
        candidate["status"] = "draft"
        try:
            mission = Mission.from_dict(candidate)
        except MissionValidationError as exc:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=str(exc)) from exc
        try:
            return telemetry_store.create_mission(mission.to_dict(), principal.name, Telemetry.utc_now())
        except Exception as exc:
            if "UNIQUE constraint failed" in str(exc):
                raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="mission_id already exists") from exc
            raise

    @app.get("/v1/missions", dependencies=[Depends(current_principal)])
    def missions(
        boat_id: str | None = Query(default=None),
        mission_status: str | None = Query(default=None, alias="status"),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> list[dict[str, Any]]:
        return telemetry_store.missions(boat_id, mission_status)

    @app.post("/v1/missions/{mission_id}/activate")
    def activate_mission(
        mission_id: str,
        _: Principal = Depends(require_roles(*CAPTAIN_ROLES)),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> dict[str, Any]:
        try:
            mission = telemetry_store.activate_mission(mission_id, Telemetry.utc_now())
        except RuntimeError as exc:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc
        if mission is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="mission not found")
        return mission

    @app.post("/v1/missions/{mission_id}/ready")
    def confirm_mission_start(
        mission_id: str,
        payload: dict[str, Any],
        _: Principal = Depends(require_roles(*CAPTAIN_ROLES)),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> dict[str, Any]:
        ready = payload.get("ready")
        if not isinstance(ready, bool):
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail="ready must be boolean")
        try:
            mission = telemetry_store.set_mission_ready(mission_id, ready, Telemetry.utc_now())
        except RuntimeError as exc:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc
        if mission is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="mission not found")
        return mission

    @app.delete("/v1/missions/{mission_id}")
    def delete_mission(
        mission_id: str,
        _: Principal = Depends(require_roles(*CAPTAIN_ROLES)),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> dict[str, bool]:
        try:
            deleted = telemetry_store.delete_mission(mission_id)
        except RuntimeError as exc:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc
        if not deleted:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="mission not found")
        return {"deleted": True}

    @app.get("/v1/boats/{boat_id}/recordings/active")
    def active_recording(
        boat_id: str,
        _: Principal = Depends(current_principal),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> dict[str, Any] | None:
        return telemetry_store.active_recording(boat_id)

    @app.post("/v1/boats/{boat_id}/recordings/start", status_code=status.HTTP_201_CREATED)
    def start_recording(
        boat_id: str,
        payload: dict[str, Any],
        principal: Principal = Depends(require_roles(*CAPTAIN_ROLES)),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> dict[str, Any]:
        name = str(payload.get("name") or "Trajetória de prova").strip()
        strategy = str(payload.get("strategy") or "balanced")
        try:
            cruise_throttle = float(payload.get("cruise_throttle", 0.45))
            return telemetry_store.start_recording(
                recording_id=f"rec-{uuid4().hex[:16]}",
                boat_id=boat_id,
                name=name,
                strategy=strategy,
                cruise_throttle=cruise_throttle,
                actor=principal.name,
                now=Telemetry.utc_now(),
            )
        except RuntimeError as exc:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc
        except (TypeError, ValueError) as exc:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=str(exc)) from exc

    @app.post("/v1/recordings/{recording_id}/stop")
    def stop_recording(
        recording_id: str,
        principal: Principal = Depends(require_roles(*CAPTAIN_ROLES)),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> dict[str, Any]:
        try:
            result = telemetry_store.stop_recording(recording_id, principal.name, Telemetry.utc_now())
        except RuntimeError as exc:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=str(exc)) from exc
        if result is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="recording not found")
        return result

    @app.get("/v1/boats/{boat_id}/missions/pending")
    def pending_mission(
        boat_id: str,
        x_device_token: str | None = Header(default=None),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> dict[str, Any] | None:
        require_device_token(x_device_token)
        return telemetry_store.pending_mission(boat_id)

    @app.get("/v1/boats/{boat_id}/missions/authorized")
    def authorized_pending_mission(
        boat_id: str,
        x_device_token: str | None = Header(default=None),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> dict[str, Any] | None:
        require_device_token(x_device_token)
        return telemetry_store.authorized_pending_mission(boat_id)

    @app.post("/v1/missions/{mission_id}/ready/device")
    def set_device_mission_ready(
        mission_id: str,
        payload: dict[str, Any],
        x_device_token: str | None = Header(default=None),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> dict[str, Any]:
        require_device_token(x_device_token)
        ready = payload.get("ready")
        if not isinstance(ready, bool):
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail="ready must be boolean")
        try:
            mission = telemetry_store.set_mission_ready(mission_id, ready, Telemetry.utc_now())
        except RuntimeError as exc:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc
        if mission is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="mission not found")
        return mission

    @app.post("/v1/boats/{boat_id}/recordings", status_code=status.HTTP_201_CREATED)
    def upload_recording(
        boat_id: str,
        payload: dict[str, Any],
        x_device_token: str | None = Header(default=None),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> dict[str, Any]:
        require_device_token(x_device_token)
        candidate = dict(payload)
        candidate["boat_id"] = boat_id
        candidate["status"] = "draft"
        try:
            mission = Mission.from_dict(candidate)
        except MissionValidationError as exc:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=str(exc)) from exc
        existing = telemetry_store.mission(mission.mission_id)
        if existing is not None:
            return existing
        return telemetry_store.create_mission(mission.to_dict(), f"boat:{boat_id}", Telemetry.utc_now())

    @app.post("/v1/missions/{mission_id}/status")
    def set_mission_status(
        mission_id: str,
        payload: dict[str, Any],
        x_device_token: str | None = Header(default=None),
        telemetry_store: TelemetryStore = Depends(current_store),
    ) -> dict[str, Any]:
        require_device_token(x_device_token)
        mission_status = payload.get("status")
        if mission_status not in {"pending", "active", "completed", "cancelled", "failed"}:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail="invalid mission status")
        result = telemetry_store.update_mission_status(
            mission_id, mission_status, Telemetry.utc_now(), payload.get("error")
        )
        if result is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="mission not found")
        return result

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
