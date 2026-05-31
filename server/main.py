"""
ElyCam Signaling Server
=======================
FastAPI-based WebSocket signaling server for WebRTC camera streaming.
Manages rooms where one publisher (iPhone camera) streams to multiple
subscribers (OBS browser sources) over a local network.

Usage:
    python main.py
    # or: uvicorn main:app --host 0.0.0.0 --port 8080
"""

import asyncio
import json
import logging
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

# ---------------------------------------------------------------------------
# Logging configuration
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("elycam")

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
HEARTBEAT_INTERVAL = 30  # seconds between server pings
HEARTBEAT_TIMEOUT = 10   # seconds to wait for pong before assuming dead

# PyInstaller bundles static files into a temp dir (sys._MEIPASS).
# Detect this so the EXE build can find the static/ folder correctly.
if getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
    BASE_DIR = Path(sys._MEIPASS)
else:
    BASE_DIR = Path(__file__).parent
STATIC_DIR = BASE_DIR / "static"

# ---------------------------------------------------------------------------
# Room model
# ---------------------------------------------------------------------------

class Room:
    """
    Represents a single camera room.

    Each room has exactly one publisher (the camera source) and zero or more
    subscribers (OBS viewers). The server relays WebRTC signaling messages
    between publisher and subscribers.
    """

    def __init__(self, room_id: str):
        self.room_id: str = room_id
        self.publisher: Optional[WebSocket] = None
        self.subscribers: list[WebSocket] = []
        self.publisher_meta: dict = {}          # optional camera metadata
        self.created_at: datetime = datetime.now(timezone.utc)

    @property
    def has_publisher(self) -> bool:
        return self.publisher is not None

    @property
    def subscriber_count(self) -> int:
        return len(self.subscribers)

    def to_dict(self) -> dict:
        """Serialize room state for the REST API."""
        return {
            "room_id": self.room_id,
            "has_publisher": self.has_publisher,
            "subscriber_count": self.subscriber_count,
            "publisher_meta": self.publisher_meta,
            "created_at": self.created_at.isoformat(),
        }


# Global rooms registry: room_id -> Room
rooms: dict[str, Room] = {}

# Track per-connection heartbeat tasks so we can cancel them on disconnect
heartbeat_tasks: dict[WebSocket, asyncio.Task] = {}


def get_or_create_room(room_id: str) -> Room:
    """Return existing room or create a new one."""
    if room_id not in rooms:
        rooms[room_id] = Room(room_id)
        logger.info("Room '%s' created", room_id)
    return rooms[room_id]


def maybe_cleanup_room(room_id: str) -> None:
    """Remove the room if it has no publisher and no subscribers."""
    room = rooms.get(room_id)
    if room and not room.has_publisher and room.subscriber_count == 0:
        del rooms[room_id]
        logger.info("Room '%s' removed (empty)", room_id)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def send_json(ws: WebSocket, data: dict) -> bool:
    """
    Send a JSON message to a WebSocket connection.
    Returns False if the send fails (connection already closed).
    """
    try:
        await ws.send_json(data)
        return True
    except Exception:
        return False


async def heartbeat(ws: WebSocket, room_id: str) -> None:
    """
    Periodically send {type: ping} to a connected client.
    If the client doesn't respond with pong within HEARTBEAT_TIMEOUT seconds,
    we close the connection to trigger cleanup.
    """
    try:
        while True:
            await asyncio.sleep(HEARTBEAT_INTERVAL)
            ok = await send_json(ws, {"type": "ping"})
            if not ok:
                logger.warning("Heartbeat send failed for room '%s', closing", room_id)
                await ws.close()
                break
    except asyncio.CancelledError:
        # Task cancelled on disconnect — perfectly normal
        pass
    except Exception as exc:
        logger.debug("Heartbeat task ended for room '%s': %s", room_id, exc)


# ---------------------------------------------------------------------------
# FastAPI application
# ---------------------------------------------------------------------------

app = FastAPI(title="ElyCam Signaling Server", version="1.0.0")

# CORS — allow everything for LAN access
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ------------------------------------------------------------------
# REST endpoints
# ------------------------------------------------------------------

@app.get("/api/health")
async def health() -> JSONResponse:
    """Server health check."""
    return JSONResponse({
        "status": "ok",
        "uptime_rooms": len(rooms),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    })


@app.get("/api/cameras")
async def list_cameras() -> JSONResponse:
    """Return a list of active rooms that have a publisher connected."""
    active = [
        room.to_dict()
        for room in rooms.values()
        if room.has_publisher
    ]
    return JSONResponse(active)


@app.get("/view")
async def viewer_page() -> FileResponse:
    """Serve the viewer HTML (OBS browser source entry point)."""
    return FileResponse(STATIC_DIR / "index.html", media_type="text/html")


# ------------------------------------------------------------------
# WebSocket signaling
# ------------------------------------------------------------------

@app.websocket("/ws/{room_id}")
async def websocket_endpoint(ws: WebSocket, room_id: str) -> None:
    """
    Main signaling endpoint.

    Lifecycle
    ---------
    1. Client connects and sends a ``join`` message with a ``role``.
    2. The server registers the client as publisher or subscriber.
    3. Subsequent messages are relayed between publisher ↔ subscribers.
    4. On disconnect the server cleans up and notifies the remaining peers.
    """
    await ws.accept()
    logger.info("WebSocket connected: room='%s'", room_id)

    room = get_or_create_room(room_id)
    role: Optional[str] = None  # will be set on 'join'

    # Start heartbeat background task
    hb_task = asyncio.create_task(heartbeat(ws, room_id))
    heartbeat_tasks[ws] = hb_task

    try:
        async for raw in ws.iter_json():
            msg_type = raw.get("type")

            # ---- JOIN ----
            if msg_type == "join":
                role = raw.get("role")

                if role == "publisher":
                    if room.has_publisher:
                        await send_json(ws, {
                            "type": "error",
                            "message": "Room already has a publisher",
                        })
                        logger.warning(
                            "Rejected duplicate publisher for room '%s'", room_id
                        )
                        continue

                    room.publisher = ws
                    room.publisher_meta = {
                        k: raw[k]
                        for k in ("camera", "resolution", "fps")
                        if k in raw
                    }
                    await send_json(ws, {"type": "joined", "room": room_id})
                    logger.info(
                        "Publisher joined room '%s' meta=%s",
                        room_id,
                        room.publisher_meta,
                    )

                    # If subscribers are already waiting, ask publisher to
                    # create an offer immediately.
                    if room.subscriber_count > 0:
                        await send_json(ws, {"type": "create-offer"})
                        logger.info(
                            "Requested offer from publisher (subscribers waiting)"
                        )

                elif role == "subscriber":
                    room.subscribers.append(ws)
                    await send_json(ws, {"type": "joined", "room": room_id})
                    logger.info(
                        "Subscriber joined room '%s' (total=%d)",
                        room_id,
                        room.subscriber_count,
                    )

                    # Notify publisher that a new peer arrived
                    if room.has_publisher:
                        await send_json(room.publisher, {"type": "peer-joined"})
                        await send_json(room.publisher, {"type": "create-offer"})
                        logger.info(
                            "Notified publisher to create offer for new subscriber"
                        )

                else:
                    await send_json(ws, {
                        "type": "error",
                        "message": f"Invalid role: {role}",
                    })

            # ---- OFFER (publisher → server → subscribers) ----
            elif msg_type == "offer":
                if role != "publisher":
                    await send_json(ws, {
                        "type": "error",
                        "message": "Only publishers can send offers",
                    })
                    continue

                sdp = raw.get("sdp", "")
                logger.info(
                    "Relaying offer to %d subscriber(s) in room '%s'",
                    room.subscriber_count,
                    room_id,
                )
                for sub in list(room.subscribers):
                    await send_json(sub, {"type": "offer", "sdp": sdp})

            # ---- ANSWER (subscriber → server → publisher) ----
            elif msg_type == "answer":
                if role != "subscriber":
                    await send_json(ws, {
                        "type": "error",
                        "message": "Only subscribers can send answers",
                    })
                    continue

                sdp = raw.get("sdp", "")
                if room.has_publisher:
                    logger.info("Relaying answer to publisher in room '%s'", room_id)
                    await send_json(room.publisher, {"type": "answer", "sdp": sdp})

            # ---- ICE CANDIDATE (bidirectional relay) ----
            elif msg_type == "ice-candidate":
                candidate_data = {
                    "type": "ice-candidate",
                    "candidate": raw.get("candidate"),
                    "sdpMLineIndex": raw.get("sdpMLineIndex"),
                    "sdpMid": raw.get("sdpMid"),
                }

                if role == "publisher":
                    # Relay to all subscribers
                    for sub in list(room.subscribers):
                        await send_json(sub, candidate_data)
                elif role == "subscriber":
                    # Relay to publisher
                    if room.has_publisher:
                        await send_json(room.publisher, candidate_data)

            # ---- PONG (heartbeat response) ----
            elif msg_type == "pong":
                # Client is alive — nothing to do
                pass

            else:
                logger.warning(
                    "Unknown message type '%s' from %s in room '%s'",
                    msg_type,
                    role,
                    room_id,
                )

    except WebSocketDisconnect:
        logger.info("WebSocket disconnected: room='%s' role='%s'", room_id, role)
    except Exception as exc:
        logger.error(
            "WebSocket error in room '%s' role='%s': %s", room_id, role, exc
        )
    finally:
        # ----- Cleanup -----
        # Cancel heartbeat task
        hb_task.cancel()
        heartbeat_tasks.pop(ws, None)

        if role == "publisher" and room.publisher is ws:
            room.publisher = None
            room.publisher_meta = {}
            logger.info("Publisher left room '%s'", room_id)

            # Notify all subscribers that the publisher is gone
            for sub in list(room.subscribers):
                await send_json(sub, {"type": "peer-left"})

        elif role == "subscriber" and ws in room.subscribers:
            room.subscribers.remove(ws)
            logger.info(
                "Subscriber left room '%s' (remaining=%d)",
                room_id,
                room.subscriber_count,
            )

            # Notify publisher that a subscriber left
            if room.has_publisher:
                await send_json(room.publisher, {"type": "peer-left"})

        maybe_cleanup_room(room_id)


# ------------------------------------------------------------------
# Static files (must be mounted AFTER routes so /view etc. take priority)
# ------------------------------------------------------------------
app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="static")


# ------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn

    logger.info("Starting ElyCam signaling server on 0.0.0.0:8080")
    uvicorn.run(
        app,              # Pass object directly (not "main:app") for PyInstaller
        host="0.0.0.0",
        port=8080,
        log_level="info",
    )
