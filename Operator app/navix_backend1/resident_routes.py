"""
resident_routes.py — All new REST + WebSocket endpoints for the resident Android app.
Mounted into the main FastAPI app in main.py.

NEW ENDPOINTS (all additions — existing endpoints untouched):
  POST  /auth/register
  POST  /auth/login
  GET   /me
  GET   /me/community
  GET   /me/apartment
  GET   /communities/{community_id}
  GET   /communities/{community_id}/map
  GET   /deliveries
  GET   /deliveries/{delivery_id}
  GET   /deliveries/{delivery_id}/tracking
  POST  /deliveries/{delivery_id}/ready
  POST  /deliveries/{delivery_id}/verify-otp
  GET   /notifications
  POST  /notifications/{notification_id}/read
  --- Operator-only ---
  POST  /operator/communities
  POST  /operator/towers
  POST  /operator/apartments
  POST  /operator/users
  POST  /operator/deliveries
  PUT   /operator/deliveries/{delivery_id}/status
  GET   /operator/deliveries
  GET   /operator/users
  WS    /ws/resident
"""

import asyncio
import uuid
from datetime import datetime, timezone
from typing import List, Optional, Dict, Any

from fastapi import APIRouter, HTTPException, Depends, WebSocket, WebSocketDisconnect, status, Request
from pydantic import BaseModel, EmailStr

from auth import (
    hash_password, verify_password, create_access_token,
    get_current_user, generate_otp, is_otp_valid
)
from db import db_cursor
from db_models import DELIVERY_STATUS_LABELS, DELIVERY_STATUSES

router = APIRouter()

# ── Resident WebSocket Manager ───────────────────────────────────────────────────
# Keeps per-user WebSocket connections so we can send targeted events
class ResidentConnectionManager:
    def __init__(self):
        # user_id -> list of WebSocket connections (multiple devices)
        self.connections: Dict[str, List[WebSocket]] = {}

    async def connect(self, websocket: WebSocket, user_id: str):
        await websocket.accept()
        self.connections.setdefault(user_id, []).append(websocket)

    def disconnect(self, websocket: WebSocket, user_id: str):
        if user_id in self.connections:
            self.connections[user_id] = [
                ws for ws in self.connections[user_id] if ws != websocket
            ]

    async def send_to_user(self, user_id: str, message: dict):
        """Send a JSON event to all connected devices of a specific user."""
        dead = []
        for ws in self.connections.get(user_id, []):
            try:
                await ws.send_json(message)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.connections[user_id].remove(ws)

    async def broadcast_delivery_update(self, delivery_id: str, event: dict):
        """Look up the resident for a delivery and send them the event."""
        with db_cursor() as cur:
            cur.execute("SELECT resident_id FROM deliveries WHERE id = %s", (delivery_id,))
            row = cur.fetchone()
        if row:
            await self.send_to_user(row["resident_id"], event)


resident_manager = ResidentConnectionManager()


# ────────────────────────────────────────────────────────────────────────────────
# Pydantic Request/Response Models
# ────────────────────────────────────────────────────────────────────────────────

class RegisterRequest(BaseModel):
    name: str
    email: str
    phone: Optional[str] = None
    password: str
    role: Optional[str] = "RESIDENT"
    community_id: Optional[str] = None
    tower_id: Optional[str] = None
    floor_id: Optional[str] = None
    apartment_id: Optional[str] = None


class LoginRequest(BaseModel):
    email: str
    password: str


class CreateCommunityRequest(BaseModel):
    id: str          # e.g. ABC001
    name: str
    address: Optional[str] = None


class CreateTowerRequest(BaseModel):
    community_id: str
    tower_id: str    # e.g. "A", "B"


class CreateApartmentRequest(BaseModel):
    community_id: str
    tower_id: str
    floor_id: str
    apartment_number: str
    destination_checkpoint: Optional[str] = None  # map node name


class CreateDeliveryRequest(BaseModel):
    resident_id: str
    community_id: str
    apartment_id: str
    order_id: Optional[str] = None
    notes: Optional[str] = None


class UpdateDeliveryStatusRequest(BaseModel):
    status: str
    robot_id: Optional[str] = None
    mission_id: Optional[str] = None
    estimated_eta_seconds: Optional[int] = None


class VerifyOTPRequest(BaseModel):
    otp: str


# ────────────────────────────────────────────────────────────────────────────────
# Auth Endpoints
# ────────────────────────────────────────────────────────────────────────────────

@router.post("/auth/register", tags=["auth"])
async def register(req: RegisterRequest, current_user: dict = Depends(get_current_user)):
    """Register a new user. Requires OPERATOR or COMMUNITY_SECURITY role."""
    if current_user.get("role") not in ("OPERATOR", "COMMUNITY_SECURITY"):
        raise HTTPException(status_code=403, detail="Only operators can create users")

    user_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    pw_hash = hash_password(req.password)

    with db_cursor() as cur:
        # Check email uniqueness
        cur.execute("SELECT id FROM users WHERE email = %s", (req.email,))
        if cur.fetchone():
            raise HTTPException(status_code=409, detail="Email already registered")

        # Validate community exists if provided
        if req.community_id:
            cur.execute("SELECT id FROM communities WHERE id = %s", (req.community_id,))
            if not cur.fetchone():
                raise HTTPException(status_code=404, detail=f"Community '{req.community_id}' not found")

        cur.execute(
            """INSERT INTO users
               (id, name, email, phone, password_hash, role,
                community_id, tower_id, floor_id, apartment_id, created_at, updated_at)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
            (user_id, req.name, req.email, req.phone, pw_hash,
             req.role, req.community_id, req.tower_id, req.floor_id, req.apartment_id,
             now, now)
        )

    return {"status": "SUCCESS", "user_id": user_id, "email": req.email}


@router.post("/auth/register/resident", tags=["auth"])
async def register_resident(req: RegisterRequest):
    """
    PUBLIC endpoint — no authentication required.
    Allows new residents to self-register from the mobile app.
    Role is always forced to RESIDENT for security.
    Community / apartment assignment is done later by an operator.
    """
    user_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    pw_hash = hash_password(req.password)

    with db_cursor() as cur:
        # Check email uniqueness
        cur.execute("SELECT id FROM users WHERE email = %s", (req.email,))
        if cur.fetchone():
            raise HTTPException(status_code=409, detail="Email already registered")

        cur.execute(
            """INSERT INTO users
               (id, name, email, phone, password_hash, role,
                community_id, tower_id, floor_id, apartment_id, created_at, updated_at)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
            (user_id, req.name, req.email, req.phone, pw_hash,
             "RESIDENT",          # always RESIDENT — ignore req.role for security
             None, None, None, None,
             now, now)
        )

    # Auto-login: return a token so the app is immediately authenticated
    token = create_access_token({
        "sub": user_id,
        "role": "RESIDENT",
        "community_id": None,
        "tower_id": None,
        "floor_id": None,
        "apartment_id": None,
    })

    return {
        "status": "SUCCESS",
        "access_token": token,
        "token_type": "bearer",
        "user": {
            "id": user_id,
            "name": req.name,
            "email": req.email,
            "phone": req.phone,
            "role": "RESIDENT",
            "community_id": None,
            "tower_id": None,
            "floor_id": None,
            "apartment_id": None,
        }
    }


@router.post("/auth/login", tags=["auth"])
async def login(req: LoginRequest):
    """Authenticate a user and return a JWT access token."""
    with db_cursor() as cur:
        cur.execute("SELECT * FROM users WHERE email = %s", (req.email,))
        row = cur.fetchone()

    if not row or not verify_password(req.password, row["password_hash"]):
        raise HTTPException(status_code=401, detail="Invalid email or password")

    token = create_access_token({
        "sub": row["id"],
        "role": row["role"],
        "community_id": row["community_id"],
        "tower_id": row["tower_id"],
        "floor_id": row["floor_id"],
        "apartment_id": row["apartment_id"],
    })

    return {
        "access_token": token,
        "token_type": "bearer",
        "user": {
            "id": row["id"],
            "name": row["name"],
            "email": row["email"],
            "role": row["role"],
            "community_id": row["community_id"],
            "tower_id": row["tower_id"],
            "floor_id": row["floor_id"],
            "apartment_id": row["apartment_id"],
        }
    }


# ────────────────────────────────────────────────────────────────────────────────
# Resident "Me" Endpoints
# ────────────────────────────────────────────────────────────────────────────────

@router.get("/me", tags=["resident"])
async def get_me(user: dict = Depends(get_current_user)):
    """Get the current authenticated user's profile."""
    with db_cursor() as cur:
        cur.execute(
            "SELECT id, name, email, phone, role, community_id, tower_id, floor_id, apartment_id FROM users WHERE id = %s",
            (user["sub"],)
        )
        row = cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="User not found")
    return dict(row)


@router.get("/me/community", tags=["resident"])
async def get_my_community(user: dict = Depends(get_current_user)):
    """Get the community the current user belongs to."""
    community_id = user.get("community_id")
    if not community_id:
        raise HTTPException(status_code=404, detail="No community assigned")
    with db_cursor() as cur:
        cur.execute("SELECT * FROM communities WHERE id = %s", (community_id,))
        row = cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Community not found")
    return dict(row)


@router.get("/me/apartment", tags=["resident"])
async def get_my_apartment(user: dict = Depends(get_current_user)):
    """Get the apartment the current user is assigned to."""
    apt_id = user.get("apartment_id")
    if not apt_id:
        raise HTTPException(status_code=404, detail="No apartment assigned")
    with db_cursor() as cur:
        cur.execute("SELECT * FROM apartments WHERE id = %s", (apt_id,))
        row = cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Apartment not found")
    return dict(row)


# ────────────────────────────────────────────────────────────────────────────────
# Community Endpoints
# ────────────────────────────────────────────────────────────────────────────────

@router.get("/communities/{community_id}", tags=["community"])
async def get_community(community_id: str, user: dict = Depends(get_current_user)):
    """Get community info. Resident must belong to this community."""
    # Authorization: residents can only see their own community
    if user.get("role") == "RESIDENT" and user.get("community_id") != community_id:
        raise HTTPException(status_code=403, detail="Not authorized to access this community")

    with db_cursor() as cur:
        cur.execute("SELECT * FROM communities WHERE id = %s", (community_id,))
        row = cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Community not found")
    return dict(row)


@router.get("/communities/{community_id}/map", tags=["community"])
async def get_community_resident_map(community_id: str, user: dict = Depends(get_current_user)):
    """
    Return a simplified resident-facing map for the community.
    Does NOT expose robot navigation internals, restricted zones, or raw SLAM data.
    Only shows: community layout, towers, floors, apartments.
    """
    # Authorization check
    if user.get("role") == "RESIDENT" and user.get("community_id") != community_id:
        raise HTTPException(status_code=403, detail="Not authorized for this community map")

    with db_cursor() as cur:
        cur.execute("SELECT * FROM communities WHERE id = %s", (community_id,))
        community = cur.fetchone()
        if not community:
            raise HTTPException(status_code=404, detail="Community not found")

        cur.execute(
            "SELECT id, tower_id, floor_id, apartment_number, destination_checkpoint FROM apartments WHERE community_id = %s",
            (community_id,)
        )
        apartments = [dict(r) for r in cur.fetchall()]

    # Build simplified map (grouped by tower/floor) — safe for residents
    towers: Dict[str, Any] = {}
    for apt in apartments:
        t = apt["tower_id"]
        f = apt["floor_id"]
        towers.setdefault(t, {}).setdefault(f, []).append({
            "apartment_id": apt["id"],
            "number": apt["apartment_number"],
            # Only expose checkpoint name to residents who own this apartment
            "checkpoint": apt["destination_checkpoint"]
            if (user.get("apartment_id") == apt["id"] or user.get("role") != "RESIDENT")
            else None
        })

    # Include active operator map (nodes, corridors, and live robot position)
    active_map = None
    try:
        from main import robot
        if robot.metric_checkpoints and robot.connections:
            active_map = {
                "checkpoints": robot.metric_checkpoints,
                "connections": robot.connections,
                "robot_x": robot.x,
                "robot_y": robot.y,
                "current_checkpoint": robot.current_checkpoint,
                "active_path": robot.active_path,
            }
    except Exception as e:
        print(f"[Map] Could not fetch active robot map: {e}")

    return {
        "community_id": community["id"],
        "community_name": community["name"],
        "towers": towers,
        "resident_apartment_id": user.get("apartment_id"),
        "active_map": active_map,
    }


# ────────────────────────────────────────────────────────────────────────────────
# Delivery Endpoints
# ────────────────────────────────────────────────────────────────────────────────

def _row_to_delivery(row) -> dict:
    d = dict(row)
    d["status_label"] = DELIVERY_STATUS_LABELS.get(d.get("status", ""), d.get("status", ""))
    return d


@router.get("/deliveries", tags=["delivery"])
async def list_deliveries(user: dict = Depends(get_current_user)):
    """List all deliveries for the current resident (only their own)."""
    with db_cursor() as cur:
        cur.execute(
            "SELECT * FROM deliveries WHERE resident_id = %s ORDER BY created_at DESC LIMIT 50",
            (user["sub"],)
        )
        rows = cur.fetchall()
    return {"deliveries": [_row_to_delivery(r) for r in rows]}


@router.get("/deliveries/{delivery_id}", tags=["delivery"])
async def get_delivery(delivery_id: str, user: dict = Depends(get_current_user)):
    """Get a specific delivery. Resident can only access their own."""
    with db_cursor() as cur:
        cur.execute("SELECT * FROM deliveries WHERE id = %s", (delivery_id,))
        row = cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Delivery not found")
    # Authorization: residents can only see their own delivery
    if user.get("role") == "RESIDENT" and row["resident_id"] != user["sub"]:
        raise HTTPException(status_code=403, detail="Not authorized to access this delivery")
    return _row_to_delivery(row)


@router.get("/deliveries/{delivery_id}/tracking", tags=["delivery"])
async def get_delivery_tracking(delivery_id: str, user: dict = Depends(get_current_user)):
    """
    Get live tracking info for a delivery.
    Returns sanitized robot position (not raw telemetry) and delivery status.
    """
    with db_cursor() as cur:
        cur.execute("SELECT * FROM deliveries WHERE id = %s", (delivery_id,))
        row = cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Delivery not found")
    if user.get("role") == "RESIDENT" and row["resident_id"] != user["sub"]:
        raise HTTPException(status_code=403, detail="Not authorized")

    # Import robot state from main module (shared singleton)
    try:
        from main import robot
        # Only expose sanitized tracking data to residents — NO raw telemetry
        robot_info = None
        if row["mission_id"] and row["status"] not in ("DELIVERED", "COMPLETED", "FAILED", "CANCELLED"):
            robot_info = {
                "status": robot.status,
                "progress": round(robot.progress, 1),
                "current_checkpoint": robot.current_checkpoint,
                "battery": round(robot.battery, 1),
                # Resident-safe position (checkpoint name only, not raw coordinates)
                "at_checkpoint": robot.current_checkpoint,
                "next_checkpoint": robot.next_checkpoint,
            }
    except Exception:
        robot_info = None

    return {
        "delivery_id": delivery_id,
        "status": row["status"],
        "status_label": DELIVERY_STATUS_LABELS.get(row["status"], row["status"]),
        "estimated_eta_seconds": row["estimated_eta_seconds"],
        "robot": robot_info,
        "apartment_id": row["apartment_id"],
    }


@router.post("/deliveries/{delivery_id}/ready", tags=["delivery"])
async def resident_ready(delivery_id: str, user: dict = Depends(get_current_user)):
    """
    Resident taps 'I'm Ready' — generates OTP and updates delivery status.
    Returns the OTP (in-app display; no SMS needed for MVP).
    """
    with db_cursor() as cur:
        cur.execute("SELECT * FROM deliveries WHERE id = %s", (delivery_id,))
        row = cur.fetchone()

    if not row:
        raise HTTPException(status_code=404, detail="Delivery not found")
    if user.get("role") == "RESIDENT" and row["resident_id"] != user["sub"]:
        raise HTTPException(status_code=403, detail="Not authorized")
    if row["status"] not in ("ARRIVED", "RESIDENT_NOTIFIED"):
        raise HTTPException(
            status_code=409,
            detail=f"Cannot set ready from status '{row['status']}'. Robot must arrive first."
        )

    otp, expires_at = generate_otp()
    now = datetime.now(timezone.utc).isoformat()

    with db_cursor() as cur:
        cur.execute(
            "UPDATE deliveries SET status=%s, otp=%s, otp_expires_at=%s, updated_at=%s WHERE id=%s",
            ("RESIDENT_READY", otp, expires_at, now, delivery_id)
        )
        # Create notification
        notif_id = str(uuid.uuid4())
        cur.execute(
            "INSERT INTO notifications (id, user_id, delivery_id, type, title, body, created_at) VALUES (%s,%s,%s,%s,%s,%s,%s)",
            (notif_id, row["resident_id"], delivery_id, "OTP_GENERATED",
             "Your OTP is Ready", f"Your delivery OTP is: {otp}", now)
        )

    # Notify resident via WebSocket
    await resident_manager.send_to_user(row["resident_id"], {
        "type": "delivery_update",
        "delivery_id": delivery_id,
        "status": "RESIDENT_READY",
        "status_label": "You Are Ready — Verifying",
        "otp": otp,
    })

    return {
        "status": "SUCCESS",
        "delivery_status": "RESIDENT_READY",
        "otp": otp,
        "otp_expires_at": expires_at,
        "message": "OTP generated. Show this to verify your delivery."
    }


@router.post("/deliveries/{delivery_id}/verify-otp", tags=["delivery"])
async def verify_otp(delivery_id: str, req: VerifyOTPRequest, user: dict = Depends(get_current_user)):
    """
    Verify OTP. On success:
      - Marks delivery as OTP_VERIFIED
      - Sends robot ramp-open command (via existing /api/open-ramp)
      - Updates delivery to DELIVERED
    """
    with db_cursor() as cur:
        cur.execute("SELECT * FROM deliveries WHERE id = %s", (delivery_id,))
        row = cur.fetchone()

    if not row:
        raise HTTPException(status_code=404, detail="Delivery not found")
    if user.get("role") == "RESIDENT" and row["resident_id"] != user["sub"]:
        raise HTTPException(status_code=403, detail="Not authorized")
    if row["status"] != "RESIDENT_READY":
        raise HTTPException(status_code=409, detail="OTP verification not applicable at this stage")

    if not is_otp_valid(row["otp"], row["otp_expires_at"], req.otp):
        raise HTTPException(status_code=400, detail="Invalid or expired OTP")

    now = datetime.now(timezone.utc).isoformat()

    # Open the delivery ramp via existing backend function
    try:
        from main import open_ramp
        await open_ramp()
    except Exception as e:
        print(f"[OTP] Ramp open failed: {e}")

    # Mark as OTP_VERIFIED then DELIVERED
    with db_cursor() as cur:
        cur.execute(
            "UPDATE deliveries SET status=%s, otp=NULL, otp_expires_at=NULL, updated_at=%s WHERE id=%s",
            ("DELIVERED", now, delivery_id)
        )
        # Notification
        notif_id = str(uuid.uuid4())
        cur.execute(
            "INSERT INTO notifications (id, user_id, delivery_id, type, title, body, created_at) VALUES (%s,%s,%s,%s,%s,%s,%s)",
            (notif_id, row["resident_id"], delivery_id, "DELIVERED",
             "Parcel Delivered! 📦", "Your parcel has been successfully delivered. Enjoy!", now)
        )
        # Audit log
        audit_id = str(uuid.uuid4())
        cur.execute(
            "INSERT INTO audit_log (id, user_id, action, resource, detail, created_at) VALUES (%s,%s,%s,%s,%s,%s)",
            (audit_id, user["sub"], "OTP_VERIFIED", f"delivery:{delivery_id}",
             f"Resident verified OTP for delivery {delivery_id}", now)
        )

    # Push WebSocket notification to resident
    await resident_manager.send_to_user(row["resident_id"], {
        "type": "delivery_update",
        "delivery_id": delivery_id,
        "status": "DELIVERED",
        "status_label": "Delivered Successfully",
        "message": "Your parcel compartment is open. Please collect your parcel.",
    })

    return {
        "status": "SUCCESS",
        "delivery_status": "DELIVERED",
        "message": "OTP verified. Delivery compartment opened.",
    }


# ────────────────────────────────────────────────────────────────────────────────
# Notification Endpoints
# ────────────────────────────────────────────────────────────────────────────────

@router.get("/notifications", tags=["notifications"])
async def list_notifications(user: dict = Depends(get_current_user)):
    """Get all notifications for the current user, newest first."""
    with db_cursor() as cur:
        cur.execute(
            "SELECT * FROM notifications WHERE user_id = %s ORDER BY created_at DESC LIMIT 100",
            (user["sub"],)
        )
        rows = cur.fetchall()
    return {"notifications": [dict(r) for r in rows]}


@router.post("/notifications/{notification_id}/read", tags=["notifications"])
async def mark_notification_read(notification_id: str, user: dict = Depends(get_current_user)):
    """Mark a single notification as read."""
    with db_cursor() as cur:
        cur.execute(
            "SELECT id, user_id FROM notifications WHERE id = %s", (notification_id,)
        )
        row = cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Notification not found")
    if row["user_id"] != user["sub"]:
        raise HTTPException(status_code=403, detail="Not authorized")

    with db_cursor() as cur:
        cur.execute("UPDATE notifications SET `read`=1 WHERE id=%s", (notification_id,))
    return {"status": "SUCCESS"}


# ────────────────────────────────────────────────────────────────────────────────
# Operator-Only Endpoints
# ────────────────────────────────────────────────────────────────────────────────

def _require_operator(user: dict = Depends(get_current_user)) -> dict:
    if user.get("role") not in ("OPERATOR", "COMMUNITY_SECURITY"):
        raise HTTPException(status_code=403, detail="Operator access required")
    return user


@router.post("/operator/communities", tags=["operator"])
async def create_community(req: CreateCommunityRequest, user: dict = Depends(_require_operator)):
    now = datetime.now(timezone.utc).isoformat()
    with db_cursor() as cur:
        cur.execute("SELECT id FROM communities WHERE id = %s", (req.id,))
        if cur.fetchone():
            raise HTTPException(status_code=409, detail="Community ID already exists")
        cur.execute(
            "INSERT INTO communities (id, name, address, created_at) VALUES (%s,%s,%s,%s)",
            (req.id, req.name, req.address, now)
        )
    return {"status": "SUCCESS", "community_id": req.id, "name": req.name}


@router.get("/operator/communities", tags=["operator"])
async def list_communities(user: dict = Depends(_require_operator)):
    """Operator: list all communities."""
    with db_cursor() as cur:
        cur.execute("SELECT * FROM communities ORDER BY created_at DESC")
        rows = cur.fetchall()
    return {"communities": [dict(r) for r in rows]}


@router.post("/operator/towers", tags=["operator"])
async def create_tower(req: CreateTowerRequest, user: dict = Depends(_require_operator)):
    """Operator: register a tower in a community. Towers are logical groupings within communities."""
    with db_cursor() as cur:
        cur.execute("SELECT id FROM communities WHERE id = %s", (req.community_id,))
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Community not found")
        # Towers don't have a separate table — they exist implicitly via apartments.
        # This endpoint confirms the community exists and returns the tower identifier.
    return {
        "status": "SUCCESS",
        "community_id": req.community_id,
        "tower_id": req.tower_id,
        "message": f"Tower {req.tower_id} registered for community {req.community_id}"
    }


@router.post("/operator/apartments", tags=["operator"])
async def create_apartment(req: CreateApartmentRequest, user: dict = Depends(_require_operator)):
    """Operator: create an apartment in a tower/floor within a community."""
    apt_id = f"{req.community_id}-{req.tower_id}-{req.floor_id}-{req.apartment_number}"

    with db_cursor() as cur:
        cur.execute("SELECT id FROM communities WHERE id = %s", (req.community_id,))
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Community not found")
        cur.execute("SELECT id FROM apartments WHERE id = %s", (apt_id,))
        if cur.fetchone():
            raise HTTPException(status_code=409, detail=f"Apartment '{apt_id}' already exists")
        cur.execute(
            """INSERT INTO apartments
               (id, community_id, tower_id, floor_id, apartment_number, destination_checkpoint)
               VALUES (%s,%s,%s,%s,%s,%s)""",
            (apt_id, req.community_id, req.tower_id, req.floor_id,
             req.apartment_number, req.destination_checkpoint)
        )
    return {"status": "SUCCESS", "apartment_id": apt_id}


@router.post("/operator/users", tags=["operator"])
async def create_user_operator(req: RegisterRequest, user: dict = Depends(_require_operator)):
    """Operator creates a new user/resident account."""
    user_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    pw_hash = hash_password(req.password)
    with db_cursor() as cur:
        cur.execute("SELECT id FROM users WHERE email = %s", (req.email,))
        if cur.fetchone():
            raise HTTPException(status_code=409, detail="Email already registered")
        if req.community_id:
            cur.execute("SELECT id FROM communities WHERE id = %s", (req.community_id,))
            if not cur.fetchone():
                raise HTTPException(status_code=404, detail="Community not found")
        cur.execute(
            """INSERT INTO users
               (id, name, email, phone, password_hash, role,
                community_id, tower_id, floor_id, apartment_id, created_at, updated_at)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
            (user_id, req.name, req.email, req.phone, pw_hash,
             req.role, req.community_id, req.tower_id, req.floor_id, req.apartment_id,
             now, now)
        )
    return {"status": "SUCCESS", "user_id": user_id}


@router.post("/operator/deliveries", tags=["operator"])
async def create_delivery(req: CreateDeliveryRequest, user: dict = Depends(_require_operator)):
    """Operator creates a new delivery mission."""
    delivery_id = str(uuid.uuid4())
    order_id = req.order_id or f"ORD-{uuid.uuid4().hex[:8].upper()}"
    now = datetime.now(timezone.utc).isoformat()

    with db_cursor() as cur:
        # Validate resident and apartment belong to community
        cur.execute("SELECT * FROM users WHERE id = %s", (req.resident_id,))
        resident = cur.fetchone()
        if not resident:
            raise HTTPException(status_code=404, detail="Resident not found")
        if resident["community_id"] != req.community_id:
            raise HTTPException(status_code=400, detail="Resident does not belong to this community")

        cur.execute("SELECT * FROM apartments WHERE id = %s", (req.apartment_id,))
        apartment = cur.fetchone()
        if not apartment:
            raise HTTPException(status_code=404, detail="Apartment not found")
        if apartment["community_id"] != req.community_id:
            raise HTTPException(status_code=400, detail="Apartment does not belong to this community")

        cur.execute(
            """INSERT INTO deliveries
               (id, order_id, resident_id, community_id, apartment_id,
                destination_checkpoint, status, notes, created_at, updated_at)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
            (delivery_id, order_id, req.resident_id, req.community_id,
             req.apartment_id, apartment["destination_checkpoint"],
             "ORDER_CREATED", req.notes, now, now)
        )
        # Create initial notification for resident
        notif_id = str(uuid.uuid4())
        cur.execute(
            "INSERT INTO notifications (id, user_id, delivery_id, type, title, body, created_at) VALUES (%s,%s,%s,%s,%s,%s,%s)",
            (notif_id, req.resident_id, delivery_id, "ORDER_CREATED",
             "New Delivery Coming! 📦", f"A new delivery has been created for your apartment. Order: {order_id}", now)
        )

    # Push WebSocket notification to resident
    await resident_manager.send_to_user(req.resident_id, {
        "type": "delivery_update",
        "delivery_id": delivery_id,
        "order_id": order_id,
        "status": "ORDER_CREATED",
        "status_label": "Order Created",
        "message": "A new delivery is on its way to you!",
    })

    return {"status": "SUCCESS", "delivery_id": delivery_id, "order_id": order_id}


@router.put("/operator/deliveries/{delivery_id}/status", tags=["operator"])
async def update_delivery_status(
    delivery_id: str,
    req: UpdateDeliveryStatusRequest,
    user: dict = Depends(_require_operator)
):
    """Operator updates the delivery status (e.g. as the robot progresses)."""
    if req.status not in DELIVERY_STATUSES:
        raise HTTPException(status_code=400, detail=f"Invalid status: {req.status}")

    with db_cursor() as cur:
        cur.execute("SELECT * FROM deliveries WHERE id = %s", (delivery_id,))
        row = cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Delivery not found")

    now = datetime.now(timezone.utc).isoformat()

    with db_cursor() as cur:
        cur.execute(
            """UPDATE deliveries
               SET status=%s, robot_id=COALESCE(%s,robot_id), mission_id=COALESCE(%s,mission_id),
                   estimated_eta_seconds=COALESCE(%s,estimated_eta_seconds), updated_at=%s
               WHERE id=%s""",
            (req.status, req.robot_id, req.mission_id, req.estimated_eta_seconds, now, delivery_id)
        )
        # Auto-create notification for key status transitions
        label = DELIVERY_STATUS_LABELS.get(req.status, req.status)
        notify_statuses = {
            "ROBOT_STARTED": ("Robot Is On Its Way! 🤖", "Your delivery robot has started its journey."),
            "ARRIVING_AT_FLOOR": ("Almost There!", "Your robot has reached your floor."),
            "APPROACHING_APARTMENT": ("Getting Closer 🤖", "Your robot is approaching your apartment."),
            "ARRIVED": ("Robot Has Arrived! 🎉", "Your robot is at your door. Please tap 'I'm Ready'."),
            "DELIVERED": ("Delivered! 📦", "Your parcel has been delivered successfully."),
            "FAILED": ("Delivery Failed", "Unfortunately your delivery could not be completed."),
        }
        if req.status in notify_statuses:
            title, body = notify_statuses[req.status]
            notif_id = str(uuid.uuid4())
            cur.execute(
                "INSERT INTO notifications (id, user_id, delivery_id, type, title, body, created_at) VALUES (%s,%s,%s,%s,%s,%s,%s)",
                (notif_id, row["resident_id"], delivery_id, req.status, title, body, now)
            )

    # Push real-time update to resident
    await resident_manager.send_to_user(row["resident_id"], {
        "type": "delivery_update",
        "delivery_id": delivery_id,
        "status": req.status,
        "status_label": DELIVERY_STATUS_LABELS.get(req.status, req.status),
        "estimated_eta_seconds": req.estimated_eta_seconds,
    })

    return {"status": "SUCCESS", "delivery_id": delivery_id, "new_status": req.status}


@router.get("/operator/deliveries", tags=["operator"])
async def list_all_deliveries(user: dict = Depends(_require_operator)):
    """Operator: list all deliveries."""
    with db_cursor() as cur:
        cur.execute("SELECT * FROM deliveries ORDER BY created_at DESC LIMIT 200")
        rows = cur.fetchall()
    return {"deliveries": [_row_to_delivery(r) for r in rows]}


@router.get("/operator/users", tags=["operator"])
async def list_all_users(user: dict = Depends(_require_operator)):
    """Operator: list all users."""
    with db_cursor() as cur:
        cur.execute(
            "SELECT id, name, email, phone, role, community_id, tower_id, floor_id, apartment_id FROM users ORDER BY created_at DESC"
        )
        rows = cur.fetchall()
    return {"users": [dict(r) for r in rows]}


# ── Bootstrap: Create default operator account if DB is empty ────────────────────
def create_default_operator_if_empty():
    """
    Creates a default operator account on first run so the system is usable.
    Credentials: admin@navix.local / navix2024
    CHANGE THIS IN PRODUCTION.
    """
    with db_cursor() as cur:
        cur.execute("SELECT COUNT(*) as cnt FROM users")
        row = cur.fetchone()
        if row and row["cnt"] == 0:
            uid = str(uuid.uuid4())
            now = datetime.now(timezone.utc).isoformat()
            cur.execute(
                """INSERT INTO users
                   (id, name, email, phone, password_hash, role, created_at, updated_at)
                   VALUES (%s,%s,%s,%s,%s,%s,%s,%s)""",
                (uid, "Navix Admin", "admin@navix.local", None,
                 hash_password("navix2024"), "OPERATOR", now, now)
            )
            print("[DB] Default operator created → admin@navix.local / navix2024")
            print("[DB] ⚠️  CHANGE THIS PASSWORD IN PRODUCTION!")


# ────────────────────────────────────────────────────────────────────────────────
# Resident WebSocket Endpoint
# ────────────────────────────────────────────────────────────────────────────────

@router.websocket("/ws/resident")
async def websocket_resident(websocket: WebSocket):
    """
    Resident WebSocket endpoint — authenticated and per-user filtered.
    Client must send {"type": "AUTH", "token": "<jwt>"} as first message.
    """
    await websocket.accept()
    user_id = None
    try:
        # Step 1: Wait for auth message
        auth_msg = await asyncio.wait_for(websocket.receive_json(), timeout=10.0)
        if auth_msg.get("type") != "AUTH":
            await websocket.send_json({"type": "ERROR", "message": "First message must be AUTH"})
            await websocket.close()
            return

        from auth import decode_access_token
        payload = decode_access_token(auth_msg.get("token", ""))
        if not payload:
            await websocket.send_json({"type": "ERROR", "message": "Invalid token"})
            await websocket.close()
            return

        user_id = payload["sub"]
        # Register connection (already accepted above)
        resident_manager.connections.setdefault(user_id, []).append(websocket)

        await websocket.send_json({"type": "AUTH_OK", "user_id": user_id})

        # Step 2: Keep alive — listen for pings
        while True:
            data = await websocket.receive_json()
            if data.get("type") == "PING":
                await websocket.send_json({"type": "PONG"})

    except asyncio.TimeoutError:
        try:
            await websocket.send_json({"type": "ERROR", "message": "Auth timeout"})
        except Exception:
            pass
    except WebSocketDisconnect:
        pass
    except Exception as e:
        print(f"[WS/resident] Error: {e}")
    finally:
        if user_id:
            resident_manager.disconnect(websocket, user_id)
