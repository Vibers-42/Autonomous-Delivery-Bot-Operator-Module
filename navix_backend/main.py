"""
Navix AI AMR Backend Server.
Coordinates robot navigation and simulation over FastAPI and WebSockets.
"""
import asyncio
import os
import json
import math
from typing import List, Dict, Any, Optional
import httpx
from fastapi import FastAPI, UploadFile, File, Form, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from pydantic import BaseModel
from contextlib import asynccontextmanager


from map_analyzer import MapAnalyzer
from path_planner import PathPlanner

# Optional Google Gemini Vision API Fallback
try:
    import google.generativeai as genai
    import PIL.Image
    GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "AIzaSyBmPlrLcbKRf7kmHw8BMnoNCxi5VnE83Zo")
    if GEMINI_API_KEY:
        genai.configure(api_key=GEMINI_API_KEY)
    GEMINI_AVAILABLE = True
except Exception as _ge:
    print(f"[Gemini] Google Generative AI not available: {_ge}")
    genai = None
    GEMINI_AVAILABLE = False

# Vision Pipeline (YOLO + MiDaS)
try:
    import vision_pipeline
    VISION_AVAILABLE = True
except ImportError as _ve:
    print(f"[VisionPipeline] Not available: {_ve}")
    VISION_AVAILABLE = False

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup code
    # Automatically generate sample map in uploads folder so it is served statically
    try:
        from generate_sample_map import create_sample_map
        create_sample_map(os.path.join(UPLOAD_DIR, "sample_map.png"))
        print("Auto-generated sample map in uploads directory.")
    except Exception as e:
        print("Failed to auto-generate sample map:", e)

    # Auto-load existing uploaded map from disk to prevent state loss on backend restart
    map_path = os.path.join(UPLOAD_DIR, "map.png")
    if os.path.exists(map_path):
        try:
            print("Auto-loading existing uploaded map on startup...")
            process_and_load_map(map_path)
            print("Map pre-loaded successfully on startup!")
        except Exception as e:
            print("Failed to auto-load map on startup:", e)

    # Start the main simulation broadcast loop (10 Hz)
    asyncio.create_task(robot_simulation_loop())
    # Start the ESP32 health-check background loop (every 5 s)
    asyncio.create_task(esp32_health_check_loop())
    print(f"ESP32 health-check started — targeting http://{robot.esp32_ip}/status every 5s")

    # Preload YOLO + MiDaS in background so they're warm on first frame
    if VISION_AVAILABLE:
        vision_pipeline.preload_models()
        print("[VisionPipeline] Model preload started in background thread")

    yield
    
    # Shutdown code
    global esp32_client
    if esp32_client is not None:
        await esp32_client.aclose()
        print("Closed persistent ESP32 HTTP client.")

app = FastAPI(title="Navix AI AMR Backend", version="1.0.0", lifespan=lifespan)

# Enable CORS for Flutter app (running on web, desktop, or mobile)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Ensure upload and static directories exist
UPLOAD_DIR = "uploads"
os.makedirs(UPLOAD_DIR, exist_ok=True)
MAPS_DIR = os.path.join(UPLOAD_DIR, "maps")
os.makedirs(MAPS_DIR, exist_ok=True)
app.mount("/static", StaticFiles(directory=UPLOAD_DIR), name="static")

# Mount Navix Flutter Web App static build directory if available
WEB_APP_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "navix_app", "build", "web"))
if os.path.exists(WEB_APP_DIR):
    app.mount("/app", StaticFiles(directory=WEB_APP_DIR, html=True), name="navix_web_app")

# Calibration Constants
TURN_SPEED = 150              # PWM speed for turning
CRUISE_SPEED = 255            # LOCKED constant cruise speed for dead-reckoning timing
SPEED_M_S = 0.18              # Calibrated physical speed (meters per second)
SPEED_CM_S = 18.0             # Calibrated physical speed (centimeters per second)

# Calibrated turn timings (in seconds)
TURN_DURATIONS = {
    "LEFT_90": 1.67,
    "RIGHT_90": 1.67
}

# Shared Simulation Statecd 
class RobotState:
    def __init__(self):
        # ESP32 connection — starts as False; gets updated by health-check loop
        self.esp32_connected = False
        self.esp32_ip = "192.168.4.1"   # Updated by /api/set-esp32-ip
        self.status = "IDLE"  # IDLE, MOVING, PAUSED, STOPPED
        self.mode = "auto"    # auto, manual
        self.speed = 255      # 0 - 255 — always starts at full CRUISE_SPEED
        
        # Position and Orientation
        self.x = 100.0
        self.y = 100.0
        self.heading = 0.0    # in radians
        
        # Navigation/Mission info
        self.current_checkpoint = "A"
        self.next_checkpoint = ""
        self.active_path = []
        self.path_coords = []
        self.current_target_index = 0
        self.progress = 0.0
        self.command = "STOP"
        
        # Auto mode action sequence variables
        self.auto_actions = []
        self.current_action_idx = 0
        self.action_start_time = 0.0
        
        # Telemetry info
        self.last_api_response = "INIT SUCCESS"
        self.total_distance = 0.0
        self.traveled_distance = 0.0
        self.route_insights = ""
        self.delivery_intelligence = ""
        
        self.last_command_sent_time = 0.0
        self.obstacle_detected = False
        self.last_status_poll_time = 0.0
        self.last_turn_sent_time = 0.0
        self.paused_by_obstacle = False

        # Obstacle avoidance state machine variables
        self.obstacle_state = "NORMAL"  # NORMAL, WAITING, BYPASSING
        self.obstacle_wait_start = 0.0
        self.paused_action_remaining_duration = 0.0
        self.bypass_actions = []
        self.current_bypass_action_idx = 0
        self.bypass_action_start_time = 0.0
        self.last_bypass_command_sent_time = 0.0
        self.bypass_command = "STOP"
        
        # Intelligent Obstacle Avoidance settings and live status variables
        self.obstacle_avoidance_enabled = True
        self.avoidance_angle = 5.0
        self.clearance_distance = 40.0         # in cm
        self.verification_distance = 15.0      # in cm
        self.max_avoidance_angle = 45.0        # in degrees
        self.obstacle_avoidance_status = "NORMAL"
        self.current_avoidance_angle = 0.0
        self.original_heading = 0.0
        self.clearance_remaining = 0.0
        self.event_log = ""
        self.esp32_direction = "STOP"
        self.avoidance_forward_start_time = 0.0
        self.avoidance_verify_start_time = 0.0
        self.avoidance_direction = "LEFT"
        self.avoidance_backup_start_time = 0.0
        
        self.esp32_turn_active = False
        self.gyro_turn_seen_active = False  # True once turn_active flips True after a turn command
        
        # Delivery Ramp state
        self.ramp_status = "CLOSED"  # OPEN, CLOSED
        self.delivery_complete = False
        self.ramp_deployed = False

        # Raw sensors and simulated readings
        self.gyro_z = 0
        self.pwm_left = 0
        self.pwm_right = 0
        self.battery = 12.2
        self.distance = 999
        self.yaw = 0.0
        self.target_yaw = 0.0
        self.yaw_error = 0.0
        self.pid_output = 0.0

        # LDE (Local Decision Engine) live telemetry
        self.lde_state = "IDLE"    # From ESP32 heartbeat: MOVING, LDE_ASSESS, LDE_TURN, LDE_BYPASS, etc.
        self.lde_attempts = 0       # Current avoidance attempt count
        self.esp32_mode = "auto"    # Real mode as reported by ESP32 /status ("mission", "auto", etc.)

        # Free Roam state machine
        self.free_roam_active = False
        self.free_roam_state = "IDLE"          # IDLE, MOVING, BACKING, TURNING
        self.free_roam_backup_start = 0.0
        self.free_roam_turn_start = 0.0
        self.free_roam_turn_direction = "LEFT"
        self.free_roam_turn_duration = 1.5     # seconds to turn before resuming forward

        # Pure Pursuit Settings (Disabled / Removed)
        self.pure_pursuit_enabled = False
        self.look_ahead_distance = 0.25         # default 25 cm
        self.max_steering_correction = 30.0    # default 30 degrees
        self.trajectory_resolution = 0.05      # default 5 cm (0.05 m)
        self.curve_resolution = 30             # default 30 control points
        
        # Pure Pursuit Live Telemetry
        self.look_ahead_point = {"x": 0.0, "y": 0.0}
        self.desired_heading = 0.0
        self.heading_error = 0.0
        self.cross_track_error = 0.0
        self.trajectory_progress = 0.0
        self.curve_radius = 999.0
        self.pure_pursuit_status = "INACTIVE"  # INACTIVE, RUNNING, PAUSED
        self.initial_heading = 0.0
        self.last_nav_update_time = 0.0
        self.trajectory_points = []

        # Grid graph
        self.checkpoints = {}
        self.metric_checkpoints = {}
        self.connections = []
        self.detected_unit = "m"

        # VisionStream Phone Sensor Hub Telemetry
        self.phone_connected = False
        self.camera_frame = ""
        self.gps = {"lat": 0.0, "lon": 0.0, "speed": 0.0, "heading": 0.0, "altitude": 0.0, "accuracy": 0.0}
        self.imu = {"ax": 0.0, "ay": 0.0, "az": 9.81, "gx": 0.0, "gy": 0.0, "gz": 0.0, "mx": 0.0, "my": 0.0, "mz": 0.0, "roll": 0.0, "pitch": 0.0, "yaw": 0.0}
        self.phone_battery = {"level": 100, "charging": False, "temperature": 25.0}
        self.phone_status = {"wifi_signal": -50, "avail_mem_mb": 2048, "storage_free_gb": 16.0}

        # Vision Pipeline (YOLO + MiDaS) state
        self.vision_auto_mode = True          # Fully autonomous: AI drives the bot
        self.vision_enabled = True            # Master vision on/off switch
        self.vision_detections = []           # Latest YOLO detections list
        self.vision_command = "FORWARD"       # Latest AI-generated command
        self.vision_scene_summary = ""        # Human-readable scene description
        self.vision_fps = 0.0                 # Pipeline throughput
        self._vision_processing = False       # Frame processing semaphore

robot = RobotState()

# WebSocket clients
class ConnectionManager:
    def __init__(self):
        self.active_connections: List[WebSocket] = []

    async def connect(self, websocket: WebSocket):
        await websocket.accept()
        self.active_connections.append(websocket)

    def disconnect(self, websocket: WebSocket):
        self.active_connections.remove(websocket)

    async def broadcast(self, message: dict):
        for connection in self.active_connections:
            try:
                await connection.send_json(message)
            except Exception:
                # Connection might be closed
                pass

manager = ConnectionManager()

# Global persistent HTTP client and lock for serializing communication with ESP32
esp32_client: Optional[httpx.AsyncClient] = None
esp32_lock = asyncio.Lock()

async def get_esp32_client() -> httpx.AsyncClient:
    global esp32_client
    if esp32_client is None or esp32_client.is_closed:
        esp32_client = httpx.AsyncClient(
            timeout=httpx.Timeout(1.0, connect=0.5, read=1.0),
            limits=httpx.Limits(max_keepalive_connections=5, max_connections=10)
        )
    return esp32_client

# Asynchronous helper to forward command/status parameters to the real ESP32
async def send_esp32_command(endpoint: str, params: dict = None) -> bool:
    url = f"http://{robot.esp32_ip}{endpoint}"
    client = await get_esp32_client()
    
    # Increase read/overall timeout for /start endpoint to allow calibration settling
    timeout_val = 10.0 if endpoint == "/start" else 1.0
    timeout = httpx.Timeout(timeout_val, connect=0.5, read=timeout_val)
    
    # Try sending with retries and locking to prevent concurrent request overlap on ESP32
    async with esp32_lock:
        for attempt in range(3):
            try:
                resp = await client.get(url, params=params, timeout=timeout)
                if resp.status_code == 200:
                    print(f"Successfully sent command to ESP32 (attempt {attempt+1}): {url} {params or ''}")
                    robot.esp32_connected = True
                    return True
                else:
                    print(f"ESP32 returned status {resp.status_code} for {url} (attempt {attempt+1})")
            except Exception as e:
                print(f"Failed to send command to ESP32 (attempt {attempt+1}): {e}")
            await asyncio.sleep(0.05) # Brief gap before retry
            
        # If we reach here, communication failed after 3 attempts
        robot.esp32_connected = False
        return False


# Pre-calculate sequence of directions & durations based on physical distance (cm)
def generate_auto_mission_actions():
    actions = []
    path = robot.active_path
    if not path or len(path) < 2:
        return actions
        
    current_heading = None
    
    # Enforce constant travel speed of SPEED_M_S for precise distance timing
    # CRUISE_SPEED=150 must remain locked for the whole mission
    speed_cm_s = SPEED_CM_S
        
    for i in range(len(path) - 1):
        node_from = path[i]
        node_to = path[i+1]
        
        # Find connection detailed path and its defined real distance
        conn_path = None
        real_conn_dist = None
        for conn in robot.connections:
            if conn["from"] == node_from and conn["to"] == node_to:
                conn_path = list(conn["path"]) if "path" in conn else None
                real_conn_dist = conn.get("distance")
                break
            elif conn["from"] == node_to and conn["to"] == node_from:
                conn_path = list(reversed(conn["path"])) if "path" in conn else None
                real_conn_dist = conn.get("distance")
                break
                
        if not conn_path:
            # Fallback to straight line
            p1 = robot.metric_checkpoints[node_from]
            p2 = robot.metric_checkpoints[node_to]
            conn_path = [[p1["x"], p1["y"]], [p2["x"], p2["y"]]]
            
        if real_conn_dist is None:
            # Fallback to coordinate-based distance
            p1 = robot.metric_checkpoints[node_from]
            p2 = robot.metric_checkpoints[node_to]
            real_conn_dist = math.sqrt((p2["x"] - p1["x"])**2 + (p2["y"] - p1["y"])**2)

        # Compute total coordinate path length to distribute real distance proportionally
        total_coord_len = 0.0
        for k in range(len(conn_path) - 1):
            p_a = conn_path[k]
            p_b = conn_path[k+1]
            total_coord_len += math.sqrt((p_b[0] - p_a[0])**2 + (p_b[1] - p_a[1])**2)

        # Loop through each sub-segment of the connection path
        for j in range(len(conn_path) - 1):
            pt1 = conn_path[j]
            pt2 = conn_path[j+1]
            
            dx = pt2[0] - pt1[0]
            dy = pt2[1] - pt1[1]
            heading = math.atan2(dy, dx)
            segment_dist = math.sqrt(dx*dx + dy*dy)
            
            # Avoid empty or extremely tiny segments
            if segment_dist < 0.01:
                continue
                
            # Distribute real distance proportionally among coordinate segments
            if total_coord_len > 0.01:
                real_segment_dist = real_conn_dist * (segment_dist / total_coord_len)
            else:
                real_segment_dist = segment_dist
                
            # Handle turnings
            if current_heading is not None:
                diff = (heading - current_heading + math.pi) % (2 * math.pi) - math.pi
                if abs(diff) > 0.087:  # More than ~5 degrees turn
                    turn_dir = "LEFT" if diff < 0 else "RIGHT"
                    raw_angle_deg = abs(math.degrees(diff))
                    # Snap to nearest 90° multiple (90, 180, 270)
                    # so the gyro-PID turn controller always does clean right-angle turns
                    snapped_angle = round(raw_angle_deg / 90.0) * 90
                    snapped_angle = max(90, min(270, snapped_angle))
                    
                    # Execute one 90° command per 90° of total turn
                    num_turns = snapped_angle // 90
                    for _ in range(num_turns):
                        actions.append({
                            "command": turn_dir,
                            "duration": TURN_DURATIONS["LEFT_90"],
                            "target_heading": heading,
                            "angle": 90,
                            "node": node_from if j == 0 else ""
                        })
                        actions.append({
                            "command": "STOP",
                            "duration": 0.4,
                            "node": ""
                        })
            
            current_heading = heading
            
            # Go FORWARD segment — convert real_segment_dist (metres) → cm, then divide by cm/s
            forward_duration = (real_segment_dist * 100.0) / speed_cm_s
            actions.append({
                "command": "FORWARD",
                "duration": forward_duration,
                "heading": heading,
                "start_pos": {"x": pt1[0], "y": pt1[1]},
                "end_pos": {"x": pt2[0], "y": pt2[1]},
                "node": node_to if j == len(conn_path) - 2 else ""
            })
            
        # Briefly pause at checkpoint
        actions.append({
            "command": "STOP",
            "duration": 0.6,
            "node": node_to
        })
        
    return actions

def calculate_local_route_metrics(path: List[str]) -> tuple:
    """Calculates turns count, total distance, and estimated duration based entirely on local metrics."""
    if not path or len(path) < 2:
        return 0, 0.0, 0.0
        
    turns_count = 0
    total_dist = 0.0
    current_heading = None
    
    for i in range(len(path) - 1):
        node_from = path[i]
        node_to = path[i+1]
        
        # Find connection detailed path and its defined real distance
        conn_path = None
        real_conn_dist = None
        for conn in robot.connections:
            if conn["from"] == node_from and conn["to"] == node_to:
                conn_path = list(conn["path"]) if "path" in conn else None
                real_conn_dist = conn.get("distance")
                break
            elif conn["from"] == node_to and conn["to"] == node_from:
                conn_path = list(reversed(conn["path"])) if "path" in conn else None
                real_conn_dist = conn.get("distance")
                break
                
        if not conn_path:
            # Fallback to straight line
            p1 = robot.metric_checkpoints[node_from]
            p2 = robot.metric_checkpoints[node_to]
            conn_path = [[p1["x"], p1["y"]], [p2["x"], p2["y"]]]
            
        if real_conn_dist is None:
            # Fallback to coordinate-based distance
            p1 = robot.metric_checkpoints[node_from]
            p2 = robot.metric_checkpoints[node_to]
            real_conn_dist = math.sqrt((p2["x"] - p1["x"])**2 + (p2["y"] - p1["y"])**2)
            
        total_dist += real_conn_dist
        
        # Compute total coordinate path length to distribute real distance proportionally
        total_coord_len = 0.0
        for k in range(len(conn_path) - 1):
            p_a = conn_path[k]
            p_b = conn_path[k+1]
            total_coord_len += math.sqrt((p_b[0] - p_a[0])**2 + (p_b[1] - p_a[1])**2)
            
        # Loop through each sub-segment of the connection path
        for j in range(len(conn_path) - 1):
            pt1 = conn_path[j]
            pt2 = conn_path[j+1]
            
            dx = pt2[0] - pt1[0]
            dy = pt2[1] - pt1[1]
            heading = math.atan2(dy, dx)
            segment_dist = math.sqrt(dx*dx + dy*dy)
            
            if segment_dist < 0.01:
                continue
                
            # Handle turnings
            if current_heading is not None:
                diff = (heading - current_heading + math.pi) % (2 * math.pi) - math.pi
                if abs(diff) > 0.15:
                    turn_angle_deg = round(math.degrees(abs(diff)))
                    turns_count += 2 if turn_angle_deg > 135 else 1
            
            current_heading = heading
            
    # Calculate estimated duration (straight lines + turns)
    travel_time = total_dist / SPEED_M_S
    turn_time = turns_count * TURN_DURATIONS["LEFT_90"] # using 90 deg turn as average
    estimated_duration = travel_time + turn_time
    
    return turns_count, total_dist, estimated_duration

async def run_gemini_analysis_async(start: str, end: str, full_path: List[str], total_distance: float, final_duration: float, turns_count: int):
    try:
        model = genai.GenerativeModel(
            model_name="gemini-2.5-flash",
            generation_config={"response_mime_type": "application/json"}
        )
        
        prompt = f"""
        You are the mission control AI for the Navix Autonomous Mobile Robot.
        We have planned a route using local Dijkstra pathfinding from checkpoint '{start}' to checkpoint '{end}'.
        
        Dijkstra Calculated Path:
        {json.dumps(full_path)}
        
        Map Checkpoint Coordinates:
        {json.dumps(robot.metric_checkpoints, indent=2)}
        
        Map Connections & Distances:
        {json.dumps([{"from": c["from"], "to": c["to"], "distance": c["distance"]} for c in robot.connections], indent=2)}
        
        Robot Speed: {SPEED_M_S} m/s
        Calibrated turn timings:
        - 90-degree turns (LEFT/RIGHT): 1.25 seconds
        - 180-degree U-turn: 2.50 seconds
        
        Analyze the path and map structure to compute:
        1. Number of turns required.
        2. Total travel distance (sum of connection distances along the path).
        3. Estimated mission duration (time to travel the total distance at {SPEED_M_S} m/s, plus turn durations).
        4. Route insights (e.g. corridor layouts, complexity, turn safety).
        5. Delivery intelligence (e.g. safe speed advice, battery consumption forecast, or potential traffic/congestion hotspots).
        
        Return your response strictly in the following JSON format:
        {{
            "turns_count": int,
            "total_distance": float,
            "estimated_duration": float,
            "route_insights": "string describing insights and layout highlights",
            "delivery_intelligence": "string describing battery forecast, safety rules, and operational advice"
        }}
        """
        response = await asyncio.to_thread(model.generate_content, prompt)
        gemini_data = json.loads(response.text)
        
        robot.route_insights = gemini_data.get("route_insights", "Dijkstra routing analysis complete.")
        robot.delivery_intelligence = gemini_data.get("delivery_intelligence", "Ready for launch.")
        print("Gemini async route analysis completed successfully.")
        
    except Exception as e:
        print(f"Gemini async route analysis failed: {e}")
        robot.route_insights = "Direct path calculated by local Dijkstra solver."
        robot.delivery_intelligence = f"Ready for launch at speed {SPEED_M_S} m/s."

# ─── ESP32 Health-Check Loop ──────────────────────────────────────────────────
# Runs every 5 s. Uses a fresh short-lived client per ping to avoid stale
# keep-alive connections on the ESP32 AP WiFi network.
async def esp32_health_check_loop():
    while True:
        try:
            # Only run health check if not actively navigating (which polls at 2Hz)
            if robot.status != "MOVING":
                url = f"http://{robot.esp32_ip}/status"
                # Use a fresh client each time to avoid keep-alive stall on ESP32 AP WiFi
                async with httpx.AsyncClient(timeout=httpx.Timeout(2.0, connect=1.0)) as ping_client:
                    resp = await ping_client.get(url)
                    robot.esp32_connected = resp.status_code == 200
                    if robot.esp32_connected:
                        robot.last_api_response = f"ESP32 PING OK (HTTP {resp.status_code})"
                        try:
                            data = resp.json()
                            robot.distance = data.get("distance", 999)
                            robot.gyro_z = data.get("gyro_z", 0)
                            robot.pwm_left = data.get("pwm_left", 0)
                            robot.pwm_right = data.get("pwm_right", 0)
                            robot.battery = data.get("battery", 12.2)
                            robot.yaw = data.get("yaw", 0.0)
                            robot.target_yaw = data.get("target_yaw", 0.0)
                            robot.yaw_error = data.get("yaw_error", 0.0)
                            robot.pid_output = data.get("pid_output", 0.0)
                            robot.lde_state = data.get("lde_state", robot.lde_state)
                            robot.lde_attempts = data.get("lde_attempts", robot.lde_attempts)
                            robot.esp32_mode = data.get("mode", robot.mode)
                        except Exception:
                            pass  # Non-JSON response is still a valid ping

        except Exception:
            # Any error (timeout, refused, no-route) → offline
            robot.esp32_connected = False
            robot.last_api_response = "ESP32 UNREACHABLE — PING FAILED"
        await asyncio.sleep(5)  # Check every 5 seconds

# Background simulation task
async def robot_simulation_loop():
    import random
    while True:
        try:
            await asyncio.sleep(0.1) # 10Hz simulation update
            
            if robot.free_roam_active and robot.status == "MOVING":
                await update_free_roam_navigation()
            elif robot.mode == "auto" and robot.status == "MOVING":
                await update_auto_navigation()
            elif robot.mode == "manual" and robot.status == "MOVING":
                await update_manual_navigation()
                
            if not robot.esp32_connected:
                # 1. Simulate battery slowly dropping over time
                robot.battery -= 0.0001
                if robot.battery < 9.5:
                    robot.battery = 12.2
                robot.battery += random.uniform(-0.005, 0.005)

                # 2. Simulate PWM values based on active command and status
                if robot.status == "MOVING":
                    speed_val = robot.speed
                    if robot.command == "FORWARD":
                        robot.pwm_left = speed_val
                        robot.pwm_right = speed_val
                    elif robot.command == "BACKWARD":
                        robot.pwm_left = speed_val
                        robot.pwm_right = speed_val
                    elif robot.command == "LEFT":
                        robot.pwm_left = 255
                        robot.pwm_right = 255
                    elif robot.command == "RIGHT":
                        robot.pwm_left = 255
                        robot.pwm_right = 255
                    else:
                        robot.pwm_left = 0
                        robot.pwm_right = 0
                else:
                    robot.pwm_left = 0
                    robot.pwm_right = 0

                # 3. Simulate gyro_z (Z-axis rate) based on active command
                if robot.status == "MOVING":
                    if robot.command == "LEFT":
                        robot.gyro_z = -7070 + random.randint(-150, 150)
                    elif robot.command == "RIGHT":
                        robot.gyro_z = 7070 + random.randint(-150, 150)
                    else:
                        robot.gyro_z = random.randint(-8, 8)
                else:
                    robot.gyro_z = random.randint(-2, 2)

                # 4. Simulate distance readings (ultrasonic front sonar)
                if robot.obstacle_avoidance_enabled:
                    if robot.obstacle_avoidance_status == "NORMAL":
                        if robot.status == "MOVING" and robot.command == "FORWARD":
                            # Only decrease distance when genuinely moving forward
                            robot.distance = max(21, robot.distance - 3)
                            robot.obstacle_detected = False  # No obstacles in simulation by default
                        else:
                            # During STOP/TURN pauses, reset sonar so it never falsely triggers
                            robot.distance = 999
                            robot.obstacle_detected = False
                    elif robot.obstacle_avoidance_status == "ROTATING":
                        if robot.current_avoidance_angle < 10.0:
                            robot.distance = 15
                            robot.obstacle_detected = True
                        else:
                            robot.distance = 150
                            robot.obstacle_detected = False
                    elif robot.obstacle_avoidance_status in ["CLEARANCE", "VERIFYING", "RETURNING", "RECOVER_BACKING"]:
                        robot.distance = 150
                        robot.obstacle_detected = False
                    elif robot.obstacle_avoidance_status == "STOPPING":
                        robot.distance = 20
                        robot.obstacle_detected = True
                else:
                    # Obstacle avoidance disabled: safe sonar during STOP actions
                    if robot.status == "MOVING" and robot.command == "FORWARD":
                        robot.distance = max(21, robot.distance - 2)
                        if robot.distance <= 20:
                            robot.distance = 999  # Reset to safe once triggered
                    else:
                        # Restore safe distance during STOP/TURN pauses
                        robot.distance = 999
                    robot.obstacle_detected = False  # Never trigger in no-avoidance sim

                # Simulate turn completion for offline mode
                if robot.obstacle_avoidance_enabled and robot.esp32_turn_active:
                    if not hasattr(robot, "sim_turn_start_time") or robot.sim_turn_start_time == 0:
                        robot.sim_turn_start_time = asyncio.get_event_loop().time()
                        robot.esp32_direction = "LEFT" if robot.obstacle_avoidance_status == "ROTATING" else "RIGHT"
                        robot.gyro_turn_seen_active = True
                    elif asyncio.get_event_loop().time() - robot.sim_turn_start_time >= 0.8:
                        robot.sim_turn_start_time = 0
                        robot.esp32_direction = "STOP"
                        robot.esp32_turn_active = False
                        robot.gyro_turn_seen_active = False
                        if robot.obstacle_avoidance_status == "ROTATING":
                            robot.yaw -= robot.avoidance_angle
                        elif robot.obstacle_avoidance_status == "RETURNING":
                            robot.yaw = robot.original_heading

                # 5. Simulate PID feedback metrics when offline
                if robot.status == "MOVING":
                    robot.yaw = round(math.degrees(robot.heading), 1)
                    if robot.command == "FORWARD":
                        robot.target_yaw = robot.yaw
                        robot.yaw_error = round(random.uniform(-0.8, 0.8), 1)
                        robot.pid_output = round(-4.5 * robot.yaw_error, 1)
                    elif robot.command in ["LEFT", "RIGHT"]:
                        robot.target_yaw = round(math.degrees(robot.heading), 1)
                        robot.yaw_error = round(random.uniform(-2.0, 2.0), 1)
                        robot.pid_output = round(4.5 * robot.yaw_error, 1)
                    else:
                        robot.target_yaw = 0.0
                        robot.yaw_error = 0.0
                        robot.pid_output = 0.0
                else:
                    robot.yaw = round(math.degrees(robot.heading), 1)
                    robot.target_yaw = 0.0
                    robot.yaw_error = 0.0
                    robot.pid_output = 0.0

            # Broadcast telemetry to all connected clients
            telemetry = get_telemetry_payload()
            await manager.broadcast(telemetry)
            
        except Exception as e:
            print(f"Error in simulation loop: {e}")

async def poll_esp32_status_during_mission():
    url = f"http://{robot.esp32_ip}/status"
    client = await get_esp32_client()
    try:
        async with esp32_lock:
            resp = await client.get(url, timeout=0.5)
            if resp.status_code == 200:
                data = resp.json()
                dist = data.get("distance", 999)
                robot.esp32_connected = True
                
                # Update raw telemetry fields
                robot.distance = dist
                robot.gyro_z = data.get("gyro_z", 0)
                robot.pwm_left = data.get("pwm_left", 0)
                robot.pwm_right = data.get("pwm_right", 0)
                robot.battery = data.get("battery", 12.2)
                robot.yaw = data.get("yaw", 0.0)
                robot.target_yaw = data.get("target_yaw", 0.0)
                robot.yaw_error = data.get("yaw_error", 0.0)
                robot.pid_output = data.get("pid_output", 0.0)
                robot.esp32_direction = data.get("direction", "STOP")

                # Sync LDE telemetry from ESP32 heartbeat
                robot.lde_state    = data.get("lde_state", "IDLE")
                robot.lde_attempts = data.get("lde_attempts", 0)
                robot.esp32_mode   = data.get("mode", robot.mode)

                # If ESP32 is in mission mode, trust its direction for command display
                # (overrides timer-based simulation so operator sees real robot state)
                if robot.esp32_mode == "mission":
                    robot.command = data.get("direction", robot.command)

                # Manage closed loop turn status when online with robust time watchdogs
                if robot.esp32_turn_active:
                    now = asyncio.get_event_loop().time()
                    time_since_turn_sent = now - getattr(robot, "last_turn_sent_time", 0.0)
                    
                    if robot.esp32_direction in ["LEFT", "RIGHT"]:
                        robot.gyro_turn_seen_active = True
                    
                    # Failsafe 1: If the ESP32 is reporting STOP, and at least 0.4s has elapsed since turn was sent, turn is complete!
                    if robot.esp32_direction == "STOP" and time_since_turn_sent >= 0.4:
                        robot.esp32_turn_active = False
                        robot.gyro_turn_seen_active = False
                    # Failsafe 2: Hard timeout of 16.0 s — matches ESP32 TURN_TIMEOUT_MS (14 s) + margin
                    elif time_since_turn_sent > 16.0:
                        robot.esp32_turn_active = False
                        robot.gyro_turn_seen_active = False
                
                # Check for obstacle override (e.g. distance <= 20cm)
                if dist <= 20:
                    robot.obstacle_detected = True
                else:
                    robot.obstacle_detected = False
                
                # Freeze reading if in middle of obstacle bypass to avoid 999 cm jumps
                if robot.obstacle_avoidance_status == "NORMAL" or dist < 990:
                    robot.distance = dist
            else:
                robot.esp32_connected = False
    except Exception as e:
        robot.esp32_connected = False
        print(f"Status poll failed: {e}")

async def open_ramp() -> bool:
    success = await send_esp32_command("/command", {"ramp": "open"})
    if success:
        robot.ramp_status = "OPEN"
        robot.ramp_deployed = True
    return success

async def close_ramp() -> bool:
    success = await send_esp32_command("/command", {"ramp": "close"})
    if success:
        robot.ramp_status = "CLOSED"
        robot.ramp_deployed = False
    return success

async def run_gemini_recovery_async(now_str: str):
    try:
        model = genai.GenerativeModel(
            model_name="gemini-2.5-flash",
            generation_config={"response_mime_type": "application/json"}
        )
        
        prompt = f"""
        You are the mission control AI for the Navix Autonomous Mobile Robot.
        The robot is currently executing an autonomous mission but got stuck in a corner/wall.
        
        Current State:
        - Checkpoint Graph Layout: {json.dumps(robot.metric_checkpoints)}
        - Last known checkpoint: {robot.current_checkpoint}
        - Next target checkpoint: {robot.next_checkpoint}
        - Obstacle Avoidance Direction Attempted: LEFT
        - Result: Blocked, exceeded limit of {robot.max_avoidance_angle} degrees.
        
        Action Taken:
        - The robot is backing up for 1.5 seconds to gain clearance and will retry the bypass by turning RIGHT.
        
        Generate:
        1. A safety status update.
        2. A recovery advice tip.
        
        Return your response strictly in the following JSON format:
        {{
            "safety_update": "string describing safety status",
            "recovery_tip": "string providing short advice for right side retry / recovery"
        }}
        """
        response = await asyncio.to_thread(model.generate_content, prompt)
        gemini_data = json.loads(response.text)
        
        tip = gemini_data.get("recovery_tip", "Gain clearance and proceed right.")
        robot.event_log += f"[{now_str}] Gemini Recovery Advisory: {tip}\n"
    except Exception as e:
        print(f"Gemini recovery analysis failed: {e}")

async def update_auto_navigation():
    now = asyncio.get_event_loop().time()
    
    # 1. Poll ESP32 status every 0.2 s during missions (5 Hz) for tighter real-time sync.
    # During active avoidance, poll even faster at 10 Hz (0.1 s).
    if robot.obstacle_avoidance_enabled and robot.obstacle_avoidance_status != "NORMAL":
        poll_interval = 0.1   # 10 Hz during active avoidance
    else:
        poll_interval = 0.2   # 5 Hz baseline during normal mission drive
    if now - robot.last_status_poll_time >= poll_interval:
        robot.last_status_poll_time = now
        asyncio.create_task(poll_esp32_status_during_mission())
        
    if robot.pure_pursuit_enabled:
        if not robot.trajectory_points:
            robot.status = "STOPPED"
            robot.command = "STOP"
            robot.progress = 100.0
            robot.trajectory_progress = 100.0
            robot.pure_pursuit_status = "INACTIVE"
            asyncio.create_task(send_esp32_command("/command", {"direction": "STOP"}))
            return
        # Mock action for obstacle avoidance state machine
        action = {"command": "FORWARD", "duration": 9999.0}
        cmd = "FORWARD"
        is_turn = False
    else:
        if not robot.auto_actions or robot.current_action_idx >= len(robot.auto_actions):
            robot.status = "STOPPED"
            robot.command = "STOP"
            robot.progress = 100.0
            robot.obstacle_state = "NORMAL"
            robot.obstacle_avoidance_status = "NORMAL"
            robot.paused_by_obstacle = False
            robot.obstacle_detected = False
            asyncio.create_task(send_esp32_command("/command", {"direction": "STOP"}))
            return
        action = robot.auto_actions[robot.current_action_idx]
        cmd = action["command"]
        is_turn = cmd in ["LEFT", "RIGHT"]

    import time
    now_str = time.strftime("%H:%M:%S")
    speed_m_s = (robot.speed / float(CRUISE_SPEED)) * SPEED_M_S if CRUISE_SPEED else SPEED_M_S
    speed_cm_s = speed_m_s * 100.0

    # 2. Obstacle avoidance / wait state machine logic
    if robot.obstacle_avoidance_enabled:
        if robot.obstacle_avoidance_status == "NORMAL":
            if robot.obstacle_detected and cmd == "FORWARD":
                print("[Obstacle Avoidance] Step 1: Obstacle detected! Stopping.")
                robot.obstacle_avoidance_status = "STOPPING"
                robot.pure_pursuit_status = "PAUSED"
                robot.original_heading = robot.yaw
                robot.avoidance_direction = "LEFT"
                robot.current_avoidance_angle = 5.0  # Initial turn is 5 degrees
                robot.command = "STOP"
                robot.event_log += f"[{now_str}] Obstacle detected. Storing heading {robot.original_heading:.1f}° and pausing Pure Pursuit. Initializing 5° bypass turn.\n"
                asyncio.create_task(send_esp32_command("/command", {"direction": "STOP"}))
                elapsed = now - robot.action_start_time
                robot.paused_action_remaining_duration = max(0.1, action["duration"] - elapsed)
                robot.avoidance_wait_start = now
                return
        
        elif robot.obstacle_avoidance_status == "STOPPING":
            if now - robot.avoidance_wait_start >= 0.5:
                if robot.current_avoidance_angle > robot.max_avoidance_angle:
                    if robot.avoidance_direction == "LEFT":
                        robot.avoidance_direction = "RIGHT"
                        robot.current_avoidance_angle = 5.0
                        robot.avoidance_wait_start = now
                        robot.event_log += f"[{now_str}] Left bypass limit exceeded ({robot.max_avoidance_angle}°). Retrying right-side with 5° turn.\n"
                        return
                    else:
                        print(f"[Obstacle Avoidance] FAILED: Both left and right bypass exceeded limit.")
                        robot.obstacle_avoidance_status = "FAILED"
                        robot.status = "PAUSED"
                        robot.command = "STOP"
                        robot.event_log += f"[{now_str}] ERROR: Avoidance failed in both directions. Robot stuck.\n"
                        asyncio.create_task(send_esp32_command("/command", {"direction": "STOP"}))
                        return
                
                robot.obstacle_avoidance_status = "ROTATING"
                robot.esp32_turn_active = True
                robot.gyro_turn_seen_active = False
                robot.last_turn_sent_time = now
                robot.event_log += f"[{now_str}] Executing bypass turn: rotating {robot.avoidance_direction.lower()} by {robot.current_avoidance_angle}°.\n"
                asyncio.create_task(send_esp32_command("/command", {
                    "direction": robot.avoidance_direction, 
                    "angle": robot.current_avoidance_angle, 
                    "speed": TURN_SPEED
                }))
            return

        elif robot.obstacle_avoidance_status == "ROTATING":
            if not robot.esp32_turn_active:
                if not hasattr(robot, "avoidance_settle_start_time") or robot.avoidance_settle_start_time == 0:
                    robot.avoidance_settle_start_time = now
                    return
                
                if now - robot.avoidance_settle_start_time >= 0.3:
                    robot.avoidance_settle_start_time = 0
                    
                    # Continue the journey (drive forward) after the turn
                    clearance_dur = robot.clearance_distance / speed_cm_s
                    robot.clearance_remaining = robot.clearance_distance
                    robot.avoidance_forward_start_time = now
                    robot.obstacle_avoidance_status = "CLEARANCE"
                    robot.command = "FORWARD"
                    robot.event_log += f"[{now_str}] Bypass turn completed. Continuing journey straight for clearance ({robot.clearance_distance} cm).\n"
                    asyncio.create_task(send_esp32_command("/command", {
                        "direction": "FORWARD", 
                        "speed": robot.speed, 
                        "duration": int(clearance_dur * 1000)
                    }))
            return

        elif robot.obstacle_avoidance_status == "CLEARANCE":
            # If obstacle is detected while driving forward, we must "come back" (reverse) and turn to 10° (and then 15°, 20°...)
            if robot.obstacle_detected:
                print(f"[Obstacle Avoidance] Obstacle encountered at {robot.current_avoidance_angle}°. Backing up to retry with wider angle.")
                robot.obstacle_avoidance_status = "RECOVER_BACKING"
                robot.command = "BACKWARD"
                robot.avoidance_backup_start_time = now
                
                # Increment the avoidance angle for the next attempt (e.g. 5° -> 10° -> 15° -> 20°...)
                old_angle = robot.current_avoidance_angle
                robot.current_avoidance_angle += 5.0
                
                backup_dur = 1.5
                robot.event_log += f"[{now_str}] Obstacle hit at {old_angle}°. Backing up for {backup_dur}s to try {robot.current_avoidance_angle}° turn.\n"
                asyncio.create_task(send_esp32_command("/command", {
                    "direction": "BACKWARD", 
                    "speed": robot.speed, 
                    "duration": int(backup_dur * 1000)
                }))
                asyncio.create_task(run_gemini_recovery_async(now_str))
                return

            elapsed_f = now - robot.avoidance_forward_start_time
            clearance_dur = robot.clearance_distance / speed_cm_s
            dist_traveled = min(robot.clearance_distance, elapsed_f * speed_m_s * 100.0)
            robot.clearance_remaining = max(0.0, robot.clearance_distance - dist_traveled)
            
            if elapsed_f >= clearance_dur:
                # Obstacle is successfully passed! Rotate back to original heading ("re route to its original state")
                robot.obstacle_avoidance_status = "RETURNING"
                robot.esp32_turn_active = True
                robot.gyro_turn_seen_active = False
                robot.last_turn_sent_time = now
                return_dir = "RIGHT" if robot.avoidance_direction == "LEFT" else "LEFT"
                robot.event_log += f"[{now_str}] Obstacle passed. Rotating {return_dir.lower()} back to original heading by {robot.current_avoidance_angle}°.\n"
                asyncio.create_task(send_esp32_command("/command", {
                    "direction": return_dir, 
                    "angle": robot.current_avoidance_angle, 
                    "speed": TURN_SPEED
                }))
            return

        elif robot.obstacle_avoidance_status == "RECOVER_BACKING":
            elapsed_back = now - robot.avoidance_backup_start_time
            backup_dur = 1.5
            if elapsed_back >= backup_dur:
                robot.obstacle_avoidance_status = "STOPPING"
                robot.command = "STOP"
                robot.avoidance_wait_start = now
                robot.event_log += f"[{now_str}] Backup completed. Stopping to execute wider bypass turn.\n"
                asyncio.create_task(send_esp32_command("/command", {"direction": "STOP"}))
            return

        elif robot.obstacle_avoidance_status == "RETURNING":
            if not robot.esp32_turn_active:
                if not hasattr(robot, "avoidance_return_settle_time") or robot.avoidance_return_settle_time == 0:
                    robot.avoidance_return_settle_time = now
                    return
                
                if now - robot.avoidance_return_settle_time >= 0.3:
                    robot.avoidance_return_settle_time = 0
                    verify_dur = robot.verification_distance / speed_cm_s
                    robot.avoidance_verify_start_time = now
                    robot.obstacle_avoidance_status = "VERIFYING"
                    robot.command = "FORWARD"
                    robot.event_log += f"[{now_str}] Re-routing complete. Driving straight to verify path ({robot.verification_distance} cm).\n"
                    asyncio.create_task(send_esp32_command("/command", {
                        "direction": "FORWARD", 
                        "speed": robot.speed, 
                        "duration": int(verify_dur * 1000)
                    }))
            return

        elif robot.obstacle_avoidance_status == "VERIFYING":
            if robot.obstacle_detected:
                print("[Obstacle Avoidance] Blocked during verification! Backing up and restarting avoidance.")
                robot.obstacle_avoidance_status = "RECOVER_BACKING"
                robot.command = "BACKWARD"
                robot.avoidance_backup_start_time = now
                robot.current_avoidance_angle += 5.0
                backup_dur = 1.5
                robot.event_log += f"[{now_str}] Obstacle hit during verification. Backing up {backup_dur}s to retry {robot.current_avoidance_angle}°.\n"
                asyncio.create_task(send_esp32_command("/command", {
                    "direction": "BACKWARD", 
                    "speed": robot.speed, 
                    "duration": int(backup_dur * 1000)
                }))
                return
            
            elapsed_v = now - robot.avoidance_verify_start_time
            verify_dur = robot.verification_distance / speed_cm_s
            if elapsed_v >= verify_dur:
                robot.obstacle_avoidance_status = "NORMAL"
                if robot.pure_pursuit_enabled:
                    robot.pure_pursuit_status = "RUNNING"
                    # Find closest trajectory point
                    min_d = float('inf')
                    closest_idx = 0
                    for idx, pt in enumerate(robot.trajectory_points):
                        d = math.sqrt((pt["x"] - robot.x)**2 + (pt["y"] - robot.y)**2)
                        if d < min_d:
                            min_d = d
                            closest_idx = idx
                    robot.current_target_index = closest_idx
                    robot.last_nav_update_time = now
                    robot.command = "STOP" # Force send command next cycle
                    robot.event_log += f"[{now_str}] Path clear. Re-routing successful. Resuming Pure Pursuit from trajectory point {closest_idx}.\n"
                    robot.last_api_response = "BYPASS COMPLETED - RESUMING PURE PURSUIT"
                else:
                    action["duration"] = robot.paused_action_remaining_duration
                    robot.action_start_time = now
                    robot.command = "STOP"
                    robot.event_log += f"[{now_str}] Path clear. Re-routing successful. Resuming original route.\n"
                    robot.last_api_response = "BYPASS COMPLETED - RESUMING"
                return
            return
        
        elif robot.obstacle_avoidance_status == "FAILED":
            robot.last_api_response = "OBSTACLE TOO LARGE - MANUAL ASSISTANCE REQUIRED"
            return
    else:
        # Run original WAITING state machine
        if robot.obstacle_state == "NORMAL":
            if robot.obstacle_detected:
                print("OBSTACLE DETECTED! Stopping and waiting until clear...")
                robot.obstacle_state = "WAITING"
                robot.pure_pursuit_status = "PAUSED"
                robot.obstacle_wait_start = now
                elapsed = now - robot.action_start_time
                robot.paused_action_remaining_duration = max(0.1, action["duration"] - elapsed)
                robot.command = "STOP"
                asyncio.create_task(send_esp32_command("/command", {"direction": "STOP"}))
                robot.last_api_response = "OBSTACLE DETECTED - WAITING"
                return
                
        elif robot.obstacle_state == "WAITING":
            if not robot.obstacle_detected:
                print("Obstacle cleared. Resuming path...")
                robot.obstacle_state = "NORMAL"
                if robot.pure_pursuit_enabled:
                    robot.pure_pursuit_status = "RUNNING"
                    robot.last_nav_update_time = now
                    robot.command = "STOP" # Force send command next cycle
                    robot.last_api_response = "OBSTACLE CLEARED - RESUMING PURE PURSUIT"
                else:
                    action["duration"] = robot.paused_action_remaining_duration
                    robot.action_start_time = now
                    robot.command = "STOP"
                    robot.last_api_response = "OBSTACLE CLEARED - RESUMING"
                return
            else:
                robot.last_api_response = "OBSTACLE DETECTED - WAITING FOR CLEAR"
                return

    # Normal navigation loop (only when obstacle_state == "NORMAL" and no obstacle detected)
    if robot.pure_pursuit_enabled:
        # 1. Update position estimation (Dead Reckoning)
        dt = now - robot.last_nav_update_time
        robot.last_nav_update_time = now
        if dt > 0.5:
            dt = 0.1
            
        # Heading estimation
        if robot.esp32_connected:
            # Sync heading from ESP32 yaw
            robot.heading = robot.initial_heading + math.radians(robot.yaw)
        else:
            # In simulation, update heading based on desired heading (first-order lag to simulate turn rate)
            heading_diff = robot.desired_heading - robot.heading
            heading_diff = (heading_diff + math.pi) % (2 * math.pi) - math.pi
            # Max turn rate: e.g. 1.0 rad/s
            max_turn = 1.0 * dt
            heading_diff = max(-max_turn, min(max_turn, heading_diff))
            robot.heading += heading_diff
            robot.yaw = math.degrees(robot.heading - robot.initial_heading)
            
        # Update coordinates (x, y) if moving forward (in meters)
        if robot.status == "MOVING" and robot.command == "FORWARD":
            robot.x += speed_m_s * dt * math.cos(robot.heading)
            robot.y += speed_m_s * dt * math.sin(robot.heading)
            
        # 2. Find closest trajectory point
        min_d = float('inf')
        closest_idx = robot.current_target_index
        for idx in range(robot.current_target_index, len(robot.trajectory_points)):
            pt = robot.trajectory_points[idx]
            d = math.sqrt((pt["x"] - robot.x)**2 + (pt["y"] - robot.y)**2)
            if d < min_d:
                min_d = d
                closest_idx = idx
        robot.current_target_index = closest_idx
        robot.cross_track_error = min_d
        
        # Telemetry progress
        if len(robot.trajectory_points) > 1:
            robot.trajectory_progress = (closest_idx / (len(robot.trajectory_points) - 1)) * 100.0
            robot.progress = robot.trajectory_progress
            
        # 3. Check for destination reached
        dist_to_destination = math.sqrt((robot.trajectory_points[-1]["x"] - robot.x)**2 + (robot.trajectory_points[-1]["y"] - robot.y)**2)
        if closest_idx >= len(robot.trajectory_points) - 2 or dist_to_destination < 0.05:
            # Mission completed!
            robot.status = "STOPPED"
            robot.command = "STOP"
            robot.progress = 100.0
            robot.trajectory_progress = 100.0
            robot.pure_pursuit_status = "INACTIVE"
            asyncio.create_task(send_esp32_command("/command", {"direction": "STOP"}))
            
            # Auto deploy delivery ramp sequence (180 deg, wait 7 seconds, then close)
            async def run_delivery_sequence():
                print("[DELIVERY] Destination reached. Deploying ramp.")
                await open_ramp()
                robot.delivery_complete = True
                await asyncio.sleep(7.0)
                print("[DELIVERY] Auto-closing ramp door.")
                await close_ramp()
            asyncio.create_task(run_delivery_sequence())
            return

        # 4. Find Look Ahead Point
        look_ahead_idx = closest_idx
        look_ahead_dist = robot.look_ahead_distance
        for idx in range(closest_idx, len(robot.trajectory_points)):
            pt = robot.trajectory_points[idx]
            d = math.sqrt((pt["x"] - robot.x)**2 + (pt["y"] - robot.y)**2)
            if d >= look_ahead_dist:
                look_ahead_idx = idx
                break
            look_ahead_idx = idx
            
        look_ahead_pt = robot.trajectory_points[look_ahead_idx]
        robot.look_ahead_point = {"x": round(look_ahead_pt["x"], 2), "y": round(look_ahead_pt["y"], 2)}
        
        # 5. Compute desired heading & heading error
        dx = look_ahead_pt["x"] - robot.x
        dy = look_ahead_pt["y"] - robot.y
        robot.desired_heading = math.atan2(dy, dx)
        
        heading_error = robot.desired_heading - robot.heading
        # Normalize to [-pi, pi]
        heading_error = (heading_error + math.pi) % (2 * math.pi) - math.pi
        
        # Limit heading error to maximum steering correction
        max_steer_rad = math.radians(robot.max_steering_correction)
        heading_error = max(-max_steer_rad, min(max_steer_rad, heading_error))
        robot.heading_error = heading_error
        
        # 6. Calculate curve radius
        curvature = 2.0 * math.sin(heading_error) / look_ahead_dist if look_ahead_dist else 0.0
        if abs(curvature) > 0.001:
            robot.curve_radius = 1.0 / curvature
        else:
            robot.curve_radius = 999.0
            
        # 7. Steer the robot toward the target heading
        target_yaw = math.degrees(robot.desired_heading - robot.initial_heading)
        robot.target_yaw = target_yaw
        robot.yaw_error = math.degrees(heading_error)
        robot.command = "FORWARD"
        robot.pure_pursuit_status = "RUNNING"
        
        # Send steering command to ESP32 (rate-limit calls or send on target yaw change)
        time_since_last_send = now - robot.last_command_sent_time
        if time_since_last_send >= 0.1:  # Update steering at 10 Hz
            robot.last_command_sent_time = now
            params = {
                "direction": "FORWARD",
                "yaw": round(target_yaw, 1),
                "speed": robot.speed
            }
            if robot.esp32_connected:
                asyncio.create_task(send_esp32_command("/command", params))
                
        # Update checkpoint tracking for screen display
        for cp_name, cp_coords in robot.metric_checkpoints.items():
            dist_to_cp = math.sqrt((cp_coords["x"] - robot.x)**2 + (cp_coords["y"] - robot.y)**2)
            if dist_to_cp < 0.3:  # Within 30cm of a checkpoint
                robot.current_checkpoint = cp_name
                
        # Find next checkpoint in active path
        if robot.active_path:
            try:
                curr_idx = robot.active_path.index(robot.current_checkpoint)
                if curr_idx + 1 < len(robot.active_path):
                    robot.next_checkpoint = robot.active_path[curr_idx + 1]
                else:
                    robot.next_checkpoint = ""
            except ValueError:
                pass
                
        return

    elapsed = now - robot.action_start_time

    # ── Determine completion ───────────────────────────────────────────────────────
    if is_turn:
        # A turn is done only AFTER the command has been dispatched AND the ESP32 signals STOP.
        # Guard: if esp32_turn_active was never armed (command not yet sent), not done.
        # Safety fallback: 18 s hard cap to prevent mission lockup.
        turn_was_sent = robot.command == cmd  # True once we sent the turn this cycle or earlier
        action_done = turn_was_sent and (not robot.esp32_turn_active) and elapsed >= 0.5
    else:
        action_done = elapsed >= action["duration"]

    if action_done:
        robot.current_action_idx += 1
        robot.action_start_time = now
        robot.esp32_turn_active = False  # reset guard for next action
        if robot.current_action_idx >= len(robot.auto_actions):
            # Mission completed!
            robot.status = "STOPPED"
            robot.command = "STOP"
            robot.progress = 100.0
            robot.next_checkpoint = ""
            robot.last_api_response = "MISSION COMPLETED"
            robot.paused_by_obstacle = False
            robot.obstacle_detected = False
            asyncio.create_task(send_esp32_command("/command", {"direction": "STOP"}))
            
            # Auto deploy delivery ramp sequence (180 deg, wait 7 seconds, then close)
            async def run_delivery_sequence():
                print("[DELIVERY] Destination reached. Deploying ramp.")
                await open_ramp()
                robot.delivery_complete = True
                await asyncio.sleep(7.0)
                print("[DELIVERY] Auto-closing ramp door.")
                await close_ramp()
            asyncio.create_task(run_delivery_sequence())
            return
        action = robot.auto_actions[robot.current_action_idx]
        cmd = action["command"]
        is_turn = cmd in ["LEFT", "RIGHT"]
        
    force_send = False
    
    if robot.last_api_response.startswith("OBSTACLE CLEARED") or robot.last_api_response.startswith("BYPASS COMPLETED"):
        force_send = True
        robot.last_api_response = "RESUMING"

    time_since_last_send = now - robot.last_command_sent_time
    if robot.command != cmd or force_send or (cmd != "STOP" and not is_turn and time_since_last_send >= 0.8):
        robot.command = cmd
        robot.last_command_sent_time = now
        
        params = {"direction": cmd}
        if cmd != "STOP":
            if is_turn:
                # TURN: send angle + target_heading so ESP32 gyro PID governs completion.
                # Do NOT send duration — that would engage the auto-timer instead of PID.
                params["speed"] = TURN_SPEED
                if "angle" in action:
                    params["angle"] = action["angle"]
                if "target_heading" in action:
                    params["target_heading"] = round(math.degrees(action["target_heading"]), 1)
                # Arm the gyro-done watchdog
                robot.esp32_turn_active = True
                robot.gyro_turn_seen_active = False
                robot.last_turn_sent_time = now
            else:
                # FORWARD / BACKWARD: send timed duration and speed
                remaining_dur = action["duration"] - elapsed
                if remaining_dur < 0.1:
                    remaining_dur = 0.1
                params["duration"] = int(remaining_dur * 1000)
                params["speed"] = robot.speed
                # Pass target heading so ESP32 PID holds the correct heading while driving straight
                if "heading" in action:
                    params["target_heading"] = round(math.degrees(action["heading"]), 1)
            
        asyncio.create_task(send_esp32_command("/command", params))
        if is_turn:
            print(f"[TURN] Dispatched gyro-PID {cmd} angle={params.get('angle', 90)}°")
        
    if action.get("node"):
        robot.current_checkpoint = action["node"]
    if robot.active_path:
        try:
            curr_idx = robot.active_path.index(robot.current_checkpoint)
            if curr_idx + 1 < len(robot.active_path):
                robot.next_checkpoint = robot.active_path[curr_idx + 1]
            else:
                robot.next_checkpoint = ""
        except ValueError:
            pass
            
    # Position interpolation on screen
    # When ESP32 is connected and running in mission mode, freeze the timer-based
    # animation — real position is only updated by status polls (prevents operator
    # dot running ahead of the physical robot).
    if robot.pure_pursuit_enabled:
        pass
    elif robot.esp32_connected and robot.esp32_mode == "mission":
        # Heading-only update so the dot orientation stays correct
        if robot.lde_state in ("LDE_TURN", "LDE_TURN_BACK"):
            pass  # Leave heading as-is while bot is physically turning
        # Skip position interpolation — do nothing.
    elif robot.obstacle_avoidance_status == "NORMAL":
        if cmd == "FORWARD" and "start_pos" in action and "end_pos" in action and action.get("duration", 0) > 0:
            t_ratio = min(1.0, elapsed / action["duration"])
            x1 = action["start_pos"]["x"]
            y1 = action["start_pos"]["y"]
            x2 = action["end_pos"]["x"]
            y2 = action["end_pos"]["y"]
            robot.x = x1 + t_ratio * (x2 - x1)
            robot.y = y1 + t_ratio * (y2 - y1)
            robot.heading = action["heading"]
        elif cmd in ["LEFT", "RIGHT"]:
            robot.heading = action["target_heading"]
    else:
        # Update coordinates and heading during active bypass phases
        if robot.obstacle_avoidance_status == "ROTATING":
            if robot.avoidance_direction == "LEFT":
                robot.heading = action["heading"] - math.radians(robot.current_avoidance_angle)
            else:
                robot.heading = action["heading"] + math.radians(robot.current_avoidance_angle)
        elif robot.obstacle_avoidance_status == "CLEARANCE":
            dt = 0.1
            if robot.avoidance_direction == "LEFT":
                robot.heading = action["heading"] - math.radians(robot.current_avoidance_angle)
            else:
                robot.heading = action["heading"] + math.radians(robot.current_avoidance_angle)
            dx = math.cos(robot.heading) * speed_m_s * dt
            dy = math.sin(robot.heading) * speed_m_s * dt
            robot.x += dx
            robot.y += dy
        elif robot.obstacle_avoidance_status == "RECOVER_BACKING":
            dt = 0.1
            # Move backward relative to the heading before backup started
            dx = -math.cos(robot.heading) * speed_m_s * dt
            dy = -math.sin(robot.heading) * speed_m_s * dt
            robot.x += dx
            robot.y += dy
        elif robot.obstacle_avoidance_status == "RETURNING":
            robot.heading = action["heading"]
        elif robot.obstacle_avoidance_status == "VERIFYING":
            dt = 0.1
            robot.heading = action["heading"]
            dx = math.cos(robot.heading) * speed_m_s * dt
            dy = math.sin(robot.heading) * speed_m_s * dt
            robot.x += dx
            robot.y += dy
        
    robot.progress = min(99.9, (robot.current_action_idx / len(robot.auto_actions)) * 100.0)

async def update_manual_navigation():
    # In manual mode, we move in the direction of the command
    speed_factor = (robot.speed / 255.0) * 3.0
    
    if robot.command == "FORWARD":
        robot.y -= speed_factor  # Up in screen coords
        robot.heading = -math.pi / 2
    elif robot.command == "BACKWARD":
        robot.y += speed_factor  # Down in screen coords
        robot.heading = math.pi / 2
    elif robot.command == "LEFT":
        robot.x -= speed_factor
        robot.heading = math.pi
    elif robot.command == "RIGHT":
        robot.x += speed_factor
        robot.heading = 0.0


async def update_free_roam_navigation():
    """Free Roam obstacle-reactive wandering state machine.
    
    States:
      MOVING  — driving forward continuously
      BACKING — reversing for 1.5 s after obstacle detected
      TURNING — random left/right turn for 1.5 s to find a clear path
    """
    import random
    import time
    now = asyncio.get_event_loop().time()
    now_str = time.strftime("%H:%M:%S")
    speed_m_s = (robot.speed / float(CRUISE_SPEED)) * SPEED_M_S if CRUISE_SPEED else SPEED_M_S

    # ── Poll ESP32 status at 5 Hz during free roam ─────────────────────────
    if now - robot.last_status_poll_time >= 0.2:
        robot.last_status_poll_time = now
        asyncio.create_task(poll_esp32_status_during_mission())

    # ─── State machine ──────────────────────────────────────────────────────
    if robot.free_roam_state == "MOVING":
        # Check for obstacle
        if robot.distance <= 20:
            print("[Free Roam] Obstacle detected! Backing up...")
            robot.free_roam_state = "BACKING"
            robot.free_roam_backup_start = now
            robot.command = "BACKWARD"
            robot.event_log += f"[{now_str}] FREE ROAM: Obstacle detected at {robot.distance:.0f} cm. Reversing.\n"
            asyncio.create_task(send_esp32_command("/command", {
                "direction": "BACKWARD",
                "speed": robot.speed,
                "duration": 1500
            }))
        else:
            # Keep going forward — re-send every 1 s so ESP32 timer doesn't expire
            if now - robot.last_command_sent_time >= 1.0:
                robot.last_command_sent_time = now
                robot.command = "FORWARD"
                asyncio.create_task(send_esp32_command("/command", {
                    "direction": "FORWARD",
                    "speed": robot.speed,
                    "duration": 2000   # 2 s rolling window — re-sent every 1 s
                }))
            # Update simulated position
            dt = 0.1
            robot.x += math.cos(robot.heading) * speed_m_s * dt
            robot.y += math.sin(robot.heading) * speed_m_s * dt

    elif robot.free_roam_state == "BACKING":
        # Update simulated position (backward)
        dt = 0.1
        robot.x -= math.cos(robot.heading) * speed_m_s * dt
        robot.y -= math.sin(robot.heading) * speed_m_s * dt

        if now - robot.free_roam_backup_start >= 1.5:
            # Backup complete — choose a random turn direction
            robot.free_roam_turn_direction = random.choice(["LEFT", "RIGHT"])
            robot.free_roam_state = "TURNING"
            robot.free_roam_turn_start = now
            robot.command = robot.free_roam_turn_direction
            robot.event_log += f"[{now_str}] FREE ROAM: Backup complete. Turning {robot.free_roam_turn_direction}.\n"
            asyncio.create_task(send_esp32_command("/command", {
                "direction": robot.free_roam_turn_direction,
                "speed": TURN_SPEED,
                "duration": int(robot.free_roam_turn_duration * 1000)
            }))

    elif robot.free_roam_state == "TURNING":
        # Update simulated heading
        if robot.free_roam_turn_direction == "LEFT":
            robot.heading -= 0.1
        else:
            robot.heading += 0.1

        if now - robot.free_roam_turn_start >= robot.free_roam_turn_duration:
            # Turn complete — resume moving forward
            robot.free_roam_state = "MOVING"
            robot.command = "FORWARD"
            robot.last_command_sent_time = 0.0  # Force send on next tick
            robot.event_log += f"[{now_str}] FREE ROAM: Turn complete. Resuming forward.\n"

    else:
        # IDLE — shouldn't happen when active; reset to MOVING
        robot.free_roam_state = "MOVING"
        robot.command = "FORWARD"
        robot.last_command_sent_time = 0.0
        


def get_telemetry_payload():
    return {
        "esp32_connected": robot.esp32_connected,
        "robot_status": robot.status,
        "mode": robot.mode,
        "esp32_mode": robot.esp32_mode,
        "current_checkpoint": robot.current_checkpoint,
        "next_checkpoint": robot.next_checkpoint,
        "command": robot.command,
        "speed": robot.speed,
        "progress": round(robot.progress, 1),
        "x": round(robot.x, 2),
        "y": round(robot.y, 2),
        "heading": round(robot.heading, 3),
        "api_status": "SUCCESS" if robot.esp32_connected else "ERROR",
        "last_api_response": robot.last_api_response,
        "total_distance": round(robot.total_distance, 2),
        "active_path": robot.active_path,
        "route_insights": robot.route_insights,
        "delivery_intelligence": robot.delivery_intelligence,
        "delivery_complete": robot.delivery_complete,
        "lde_state": robot.lde_state,
        "lde_attempts": robot.lde_attempts,
        "ramp_deployed": robot.ramp_deployed,
        "ramp_status": robot.ramp_status,
        "gyro_z": robot.gyro_z,
        "pwm_left": robot.pwm_left,
        "pwm_right": robot.pwm_right,
        "battery": round(robot.battery, 2),
        "distance": robot.distance,
        "yaw": round(robot.yaw, 1),
        "target_yaw": round(robot.target_yaw, 1),
        "yaw_error": round(robot.yaw_error, 1),
        "pid_output": round(robot.pid_output, 1),
        "obstacle_avoidance_enabled": robot.obstacle_avoidance_enabled,
        "avoidance_angle": robot.avoidance_angle,
        "clearance_distance": robot.clearance_distance,
        "verification_distance": robot.verification_distance,
        "max_avoidance_angle": robot.max_avoidance_angle,
        "obstacle_avoidance_status": robot.obstacle_avoidance_status,
        "current_avoidance_angle": robot.current_avoidance_angle,
        "original_heading": round(robot.original_heading, 3),
        "clearance_remaining": round(robot.clearance_remaining, 1),
        "event_log": robot.event_log,
        # Pure Pursuit Config
        "pure_pursuit_enabled": robot.pure_pursuit_enabled,
        "look_ahead_distance": robot.look_ahead_distance,
        "max_steering_correction": robot.max_steering_correction,
        "trajectory_resolution": robot.trajectory_resolution,
        "curve_resolution": robot.curve_resolution,
        # Pure Pursuit Live Telemetry
        "look_ahead_point": robot.look_ahead_point,
        "desired_heading": round(robot.desired_heading, 3),
        "heading_error": round(robot.heading_error, 3),
        "cross_track_error": round(robot.cross_track_error, 3),
        "trajectory_progress": round(robot.trajectory_progress, 1),
        "curve_radius": round(robot.curve_radius, 2),
        "pure_pursuit_status": robot.pure_pursuit_status,
        # Free Roam telemetry
        "free_roam_active": robot.free_roam_active,
        "free_roam_state": robot.free_roam_state,
        # VisionStream Phone Sensor Hub Telemetry
        "phone_connected": getattr(robot, "phone_connected", False),
        "camera_frame": getattr(robot, "camera_frame", ""),
        "gps": getattr(robot, "gps", {"lat": 0.0, "lon": 0.0, "speed": 0.0, "heading": 0.0, "altitude": 0.0, "accuracy": 0.0}),
        "imu": getattr(robot, "imu", {"ax": 0.0, "ay": 0.0, "az": 9.81, "gx": 0.0, "gy": 0.0, "gz": 0.0, "mx": 0.0, "my": 0.0, "mz": 0.0, "roll": 0.0, "pitch": 0.0, "yaw": 0.0}),
        "phone_battery": getattr(robot, "phone_battery", {"level": 100, "charging": False, "temperature": 25.0}),
        "phone_status": getattr(robot, "phone_status", {"wifi_signal": -50, "avail_mem_mb": 2048, "storage_free_gb": 16.0}),
        # Vision AI pipeline telemetry
        "vision_command": getattr(robot, "vision_command", "FORWARD"),
        "vision_scene_summary": getattr(robot, "vision_scene_summary", ""),
        "vision_fps": getattr(robot, "vision_fps", 0.0),
        "vision_enabled": getattr(robot, "vision_enabled", False),
        "vision_auto_mode": getattr(robot, "vision_auto_mode", False),
        "vision_detections": getattr(robot, "vision_detections", []),
    }

# API Endpoints
class PathPlanningRequest(BaseModel):
    start: str
    end: str
    intermediates: Optional[List[str]] = []

def process_and_load_map(file_location: str) -> dict:
    graph = None
    
    # 1. Try local MapAnalyzer first for pixel-perfect precision and offline robustness
    try:
        print("Analyzing map using local MapAnalyzer...")
        analyzer = MapAnalyzer()
        local_graph = analyzer.analyze_map(file_location)
        if local_graph and len(local_graph.get("checkpoints", {})) >= 2:
            graph = local_graph
            print("Local MapAnalyzer successfully analyzed the map with pixel-perfect coordinates!")
        else:
            print("Local MapAnalyzer found insufficient checkpoints (< 2). Will try Gemini...")
    except Exception as local_err:
        print(f"Local MapAnalyzer failed: {local_err}. Trying Gemini...")
        
    # 2. Fallback to Google Gemini Vision API if local analyzer failed or returned empty graph
    if graph is None:
        if not GEMINI_AVAILABLE or genai is None:
            raise Exception("Local MapAnalyzer failed and Google Gemini API is not available.")
        is_invalid_map = False
        invalid_map_reason = ""
        try:
            print("Analyzing map using Google Gemini Vision API fallback...")
            img = PIL.Image.open(file_location)
            width, height = img.size
            
            model = genai.GenerativeModel(
                model_name="gemini-2.5-flash",
                generation_config={"response_mime_type": "application/json"}
            )
            
            prompt = f"""
            Analyze this image. The dimensions of the image are {width} width x {height} height.
            First, determine if this image is a floor plan, navigation map, occupancy grid, or layout map that represents a physical space with paths and checkpoints.
            If the image is NOT a map or layout (for example, if it is a photo of a person, an animal, a landscape, a text document, a generic product logo, or any random non-map image), you MUST return:
            {{
                "is_map": false,
                "message": "The uploaded image does not appear to be a valid navigation map or floor plan. Please upload a map layout image."
            }}
            
            If the image IS a valid navigation map, floor plan, or layout, return:
            {{
                "is_map": true,
                "checkpoints": [
                    {{"id": "CHECKPOINT_LABEL", "x": x_coord_normalized, "y": y_coord_normalized}},
                    ...
                ],
                "connections": {{
                    "NODE_1": ["NODE_2"],
                    ...
                }},
                "distances": [
                    {{"from": "NODE_1", "to": "NODE_2", "distance": distance_numeric_value_in_original_units}},
                    ...
                ]
            }}
            
            Detailed rules for map analysis:
            1. Detect all checkpoints/waypoints (typically represented as circular nodes, markers, colored dots, or labeled labels like A, B, C, or 1, 2, 3). Find their exact center coordinates (x, y) normalized to a 1000x1000 grid (where 0 is top-left and 1000 is bottom-right relative to the {width}x{height} image dimensions).
            2. Detect direct connections (navigable corridors, paths, or lines) between these checkpoints.
            3. Look for any explicit distance/length labels written in text near the paths (e.g., numbers followed by 'cm', 'm', 'ft', or plain digits). Map these distances to the correct connection segments.
            
            Ensure x and y are precise coordinates normalized to the 1000x1000 grid (0 to 1000 range).
            Ensure connections are mutual (undirected graph).
            Do not include any units in the distance numbers, just the float or integer value. Ensure all distances in the distances list are in meters (e.g., convert '270 cm' to 2.7, '3.8m' to 3.8, etc.).
            """
            
            response = model.generate_content([prompt, img])
            gemini_data = json.loads(response.text)
            
            if not gemini_data.get("is_map", True):
                is_invalid_map = True
                invalid_map_reason = gemini_data.get("message", "Uploaded image is not a valid map.")
                print(f"Gemini rejected image: {invalid_map_reason}")
            else:
                # Format checkpoints (scale from 1000x1000 normalized grid to actual image pixels)
                checkpoints_dict = {}
                for cp in gemini_data.get("checkpoints", []):
                    x_scaled = (float(cp["x"]) / 1000.0) * width
                    y_scaled = (float(cp["y"]) / 1000.0) * height
                    checkpoints_dict[cp["id"]] = {"x": x_scaled, "y": y_scaled}
                    
                connections_list = []
                mapped_ratios = []
                
                # Format connections and map distances
                for start_node, neighbors in gemini_data.get("connections", {}).items():
                    for end_node in neighbors:
                        # Avoid duplicate undirected connections
                        if any((c["from"] == start_node and c["to"] == end_node) or (c["from"] == end_node and c["to"] == start_node) for c in connections_list):
                            continue
                        if start_node not in checkpoints_dict or end_node not in checkpoints_dict:
                            continue
                            
                        dist = None
                        for d in gemini_data.get("distances", []):
                            if (d["from"] == start_node and d["to"] == end_node) or (d["from"] == end_node and d["to"] == start_node):
                                dist = d["distance"]
                                break
                                
                        p1 = checkpoints_dict[start_node]
                        p2 = checkpoints_dict[end_node]
                        pixel_dist = math.sqrt((p2["x"] - p1["x"])**2 + (p2["y"] - p1["y"])**2)
                        
                        if dist is not None:
                            connections_list.append({
                                "from": start_node,
                                "to": end_node,
                                "distance": round(float(dist), 1)
                            })
                            mapped_ratios.append(pixel_dist / dist)
                        else:
                            connections_list.append({
                                "from": start_node,
                                "to": end_node,
                                "pixel_distance": pixel_dist
                            })
                            
                # Apply average scale ratio for connections without explicit labels
                avg_ratio = sum(mapped_ratios) / len(mapped_ratios) if mapped_ratios else 2.45
                for conn in connections_list:
                    if "pixel_distance" in conn:
                        conn["distance"] = round(conn["pixel_distance"] / avg_ratio, 1)
                        del conn["pixel_distance"]
                        
                graph = {
                    "checkpoints": checkpoints_dict,
                    "connections": connections_list
                }
                print("Google Gemini Vision API map analysis completed successfully!")
                
        except Exception as e:
            print(f"Gemini API analysis failed: {str(e)}.")
            
        if is_invalid_map:
            raise HTTPException(status_code=400, detail=invalid_map_reason)
            
        if graph is None:
            raise HTTPException(status_code=500, detail="Both local MapAnalyzer and Gemini API failed to parse the map.")
            
    def normalize_to_meters(val):
        if val > 100:
            return round(val / 100.0, 3)
        elif val > 10:
            return round(val / 10.0, 3)
        else:
            return round(val, 3)

    # 2. Compute pixels_per_meter ratio using actual path lengths
    ratios = []
    for conn in graph["connections"]:
        from_node = conn["from"]
        to_node = conn["to"]
        if from_node in graph["checkpoints"] and to_node in graph["checkpoints"]:
            p1 = graph["checkpoints"][from_node]
            p2 = graph["checkpoints"][to_node]
            
            # Sum up actual segments along the path to get real path length in pixels
            path_len = 0.0
            if "pixel_path" in conn and conn["pixel_path"]:
                path_pts = conn["pixel_path"]
                for idx in range(len(path_pts) - 1):
                    p_a = path_pts[idx]
                    p_b = path_pts[idx + 1]
                    path_len += math.sqrt((p_b[0] - p_a[0])**2 + (p_b[1] - p_a[1])**2)
            else:
                path_len = math.sqrt((p2["x"] - p1["x"])**2 + (p2["y"] - p1["y"])**2)
                
            dist = conn["distance"]
            dist = normalize_to_meters(dist)
            conn["distance"] = dist
            
            if dist > 0.01:
                ratios.append(path_len / dist)

    if ratios:
        pixels_per_meter = sum(ratios) / len(ratios)
    else:
        pixels_per_cm = 20.0

    # 3. Convert connections to meters and scale their pixel paths
    connections_in_m = []
    for conn in graph["connections"]:
        dist = conn["distance"]
        dist = normalize_to_meters(dist)
            
        # Scale pixel_path to meters
        metric_path = []
        if "pixel_path" in conn and conn["pixel_path"]:
            for pt in conn["pixel_path"]:
                metric_path.append([
                    round(pt[0] / pixels_per_meter, 3),
                    round(pt[1] / pixels_per_meter, 3)
                ])
        else:
            # Fallback to straight line
            p1 = graph["checkpoints"][conn["from"]]
            p2 = graph["checkpoints"][conn["to"]]
            metric_path = [
                [round(p1["x"] / pixels_per_meter, 3), round(p1["y"] / pixels_per_meter, 3)],
                [round(p2["x"] / pixels_per_meter, 3), round(p2["y"] / pixels_per_meter, 3)]
            ]
            
        metric_cp = []
        for pt in conn.get("control_points", []):
            metric_cp.append([
                round(pt[0] / pixels_per_meter, 3),
                round(pt[1] / pixels_per_meter, 3)
            ])
            
        r_px = conn.get("radius")
        radius_m = round(r_px / pixels_per_meter, 3) if r_px is not None else None
        
        len_px = conn.get("length")
        length_m = round(len_px / pixels_per_meter, 3) if len_px is not None else dist
        
        curv_px = conn.get("curvature", 0.0)
        curvature_m = round(curv_px * pixels_per_meter, 5)
            
        connections_in_m.append({
            "from": conn["from"],
            "to": conn["to"],
            "distance": dist,
            "path": metric_path,
            "connection_type": conn.get("connection_type", "orthogonal"),
            "control_points": metric_cp,
            "radius": radius_m,
            "length": length_m,
            "heading": conn.get("heading", 0.0),
            "curvature": curvature_m
        })

    # 4. Compute metric checkpoints
    metric_checkpoints = {}
    for k, pos in graph["checkpoints"].items():
        metric_checkpoints[k] = {
            "x": round(pos["x"] / pixels_per_meter, 3),
            "y": round(pos["y"] / pixels_per_meter, 3)
        }

    # Save to robot state
    robot.checkpoints = graph["checkpoints"] # pixel coords (Layer 1)
    robot.metric_checkpoints = metric_checkpoints # metric coords (Layer 2)
    robot.connections = connections_in_m # connections in meters (Layer 2)
    robot.detected_unit = "m"  # Designer maps are always in meters

    # Set starting coordinate to first checkpoint if available (in meters)
    if robot.checkpoints:
        first_key = list(robot.checkpoints.keys())[0]
        robot.current_checkpoint = first_key
        robot.x = robot.metric_checkpoints[first_key]["x"]
        robot.y = robot.metric_checkpoints[first_key]["y"]
        
    return {
        "status": "SUCCESS",
        "message": "Map processed successfully",
        "checkpoints": robot.checkpoints,
        "metric_checkpoints": robot.metric_checkpoints,
        "connections": robot.connections,
        "detected_unit": "m",  # All metric coords are in meters
        "image_url": "/static/map.png"
    }

@app.post("/api/upload-map")
async def upload_map(file: UploadFile = File(...)):
    # Save the file
    file_location = os.path.join(UPLOAD_DIR, "map.png")
    contents = await file.read()
    with open(file_location, "wb+") as file_object:
        file_object.write(contents)
        
    return process_and_load_map(file_location)

class SaveMapRequest(BaseModel):
    map_name: str
    checkpoints: Dict[str, Any]
    connections: List[Dict[str, Any]]
    unit: Optional[str] = "meters"

class SelectMapRequest(BaseModel):
    map_name: str
    checkpoints: Dict[str, Any]
    connections: List[Dict[str, Any]]
    unit: Optional[str] = "meters"

@app.get("/api/maps")
def get_maps():
    """List all saved custom maps."""
    map_list = []
    for file in os.listdir(MAPS_DIR):
        if file.endswith(".json"):
            path = os.path.join(MAPS_DIR, file)
            try:
                with open(path, "r") as f:
                    data = json.load(f)
                map_list.append({
                    "name": data.get("map_name", file[:-5]),
                    "file_name": file,
                    "checkpoints_count": len(data.get("checkpoints", {})),
                    "connections_count": len(data.get("connections", [])),
                    "unit": data.get("unit", "meters")
                })
            except Exception as e:
                print(f"Error loading map metadata from {file}: {e}")
    return {"maps": map_list}

@app.get("/api/maps/{file_name}")
def get_map_detail(file_name: str):
    """Retrieve full map JSON data."""
    path = os.path.join(MAPS_DIR, file_name)
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="Map file not found")
    try:
        with open(path, "r") as f:
            data = json.load(f)
        return data
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to read map file: {str(e)}")

@app.post("/api/maps")
def save_map(req: SaveMapRequest):
    """Save or overwrite a map JSON file."""
    # Convert name to a valid slug file name
    slug = "".join([c if c.isalnum() or c in ['-', '_'] else '_' for c in req.map_name.lower().strip()])
    file_name = f"{slug}.json"
    path = os.path.join(MAPS_DIR, file_name)
    
    map_data = {
        "map_name": req.map_name,
        "unit": req.unit,
        "checkpoints": req.checkpoints,
        "connections": req.connections
    }
    
    try:
        with open(path, "w") as f:
            json.dump(map_data, f, indent=2)
        print(f"Saved custom map: {req.map_name} to {file_name}")
        return {"status": "SUCCESS", "file_name": file_name, "map_name": req.map_name}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to save map: {str(e)}")

@app.delete("/api/maps/{file_name}")
def delete_map(file_name: str):
    """Delete a saved custom map."""
    path = os.path.join(MAPS_DIR, file_name)
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="Map file not found")
    try:
        os.remove(path)
        print(f"Deleted custom map file: {file_name}")
        return {"status": "SUCCESS"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to delete map: {str(e)}")

@app.post("/api/select-map")
def select_map_active(req: SelectMapRequest):
    """Select a custom map as the active console map."""
    try:
        # 1. Populate checkpoints and metric_checkpoints
        # For custom maps, the coordinates provided are already in meters.
        metric_checkpoints = {}
        pixel_checkpoints = {}
        
        # Map designer uses 100 px per meter (1 grid block = 1.0 m = 100 px)
        pixels_per_m = 100.0
        
        for name, cp in req.checkpoints.items():
            x_m = float(cp["x"])
            y_m = float(cp["y"])
            metric_checkpoints[name] = {"x": x_m, "y": y_m}
            pixel_checkpoints[name] = {"x": x_m * pixels_per_m, "y": y_m * pixels_per_m}

        # 2. Populate connections
        connections_in_m = []
        for conn in req.connections:
            # Scale coordinates along path to meters
            path = conn.get("path")
            if not path:
                # Fallback to straight line
                from_node = conn["from"]
                to_node = conn["to"]
                p1 = metric_checkpoints[from_node]
                p2 = metric_checkpoints[to_node]
                path = [[p1["x"], p1["y"]], [p2["x"], p2["y"]]]
            
            connections_in_m.append({
                "from": conn["from"],
                "to": conn["to"],
                "distance": float(conn["distance"]),
                "path": path,
                "connection_type": conn.get("connection_type", "orthogonal"),
                "control_points": conn.get("control_points", []),
                "radius": conn.get("radius"),
                "length": conn.get("length", float(conn["distance"])),
                "heading": conn.get("heading", 0.0),
                "curvature": conn.get("curvature", 0.0)
            })
            
        # 3. Save to active robot state
        robot.checkpoints = pixel_checkpoints
        robot.metric_checkpoints = metric_checkpoints
        robot.connections = connections_in_m
        robot.detected_unit = "m"  # Designer maps use meters
        
        # Set starting coordinate to first checkpoint if available
        if robot.checkpoints:
            first_key = list(robot.checkpoints.keys())[0]
            robot.current_checkpoint = first_key
            robot.x = robot.metric_checkpoints[first_key]["x"]
            robot.y = robot.metric_checkpoints[first_key]["y"]
            robot.heading = 0.0
            
        robot.status = "IDLE"
        robot.command = "STOP"
        robot.progress = 0.0
        robot.active_path = []
        robot.auto_actions = []
        
        print(f"Selected active custom map: {req.map_name}")
        return {
            "status": "SUCCESS",
            "message": "Custom map selected successfully",
            "checkpoints": robot.checkpoints,
            "metric_checkpoints": robot.metric_checkpoints,
            "connections": robot.connections,
            "detected_unit": "m"  # All metric coords are in meters
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to select map: {str(e)}")

@app.post("/api/plan-path")
async def plan_path(req: PathPlanningRequest):
    if not robot.metric_checkpoints or not robot.connections:
        raise HTTPException(status_code=400, detail="No map loaded. Please upload a map first.")
        
    planner = PathPlanner(robot.metric_checkpoints, robot.connections)
    
    # Build checkpoint sequence: start -> intermediates -> end
    visit_sequence = [req.start]
    if req.intermediates:
        visit_sequence.extend(req.intermediates)
    visit_sequence.append(req.end)
    
    full_path = []
    full_coordinates = []
    total_distance = 0.0
    
    for i in range(len(visit_sequence) - 1):
        segment_start = visit_sequence[i]
        segment_end = visit_sequence[i+1]
        
        if segment_start == segment_end:
            continue
            
        result = planner.find_shortest_path(segment_start, segment_end)
        if result is None:
            raise HTTPException(status_code=404, detail=f"No path found between {segment_start} and {segment_end}")
            
        if not full_path:
            full_path.extend(result["path"])
        else:
            full_path.extend(result["path"][1:])
            
        if not full_coordinates:
            full_coordinates.extend(result["coordinates"])
        else:
            full_coordinates.extend(result["coordinates"][1:])
            
        total_distance += result["distance"]
        
    # 3. Calculate local route metrics immediately
    turns_count, final_distance, final_duration = calculate_local_route_metrics(full_path)

    # Load into robot state
    robot.active_path = full_path
    robot.path_coords = full_coordinates
    robot.total_distance = final_distance
    robot.current_target_index = 0
    robot.next_checkpoint = full_path[0] if len(full_path) > 0 else ""
    robot.progress = 0.0
    robot.status = "PAUSED" # Wait for start command
    robot.route_insights = "Analyzing route..."
    robot.delivery_intelligence = "Calculating safety recommendations..."
    
    # Initialize robot position to start node immediately upon planning (in meters)
    if robot.active_path:
        start_node = robot.active_path[0]
        if start_node in robot.metric_checkpoints:
            robot.x = robot.metric_checkpoints[start_node]["x"]
            robot.y = robot.metric_checkpoints[start_node]["y"]
            robot.current_checkpoint = start_node
            
    # 4. Trigger Gemini analysis asynchronously in the background
    asyncio.create_task(run_gemini_analysis_async(req.start, req.end, full_path, final_distance, final_duration, turns_count))
            
    return {
        "status": "SUCCESS",
        "path": full_path,
        "coordinates": full_coordinates,
        "distance": round(final_distance, 1),
        "estimated_time": round(final_duration, 1),
        "turns_count": turns_count,
        "route_insights": robot.route_insights,
        "delivery_intelligence": robot.delivery_intelligence
    }

class RobotPositionRequest(BaseModel):
    checkpoint: str

@app.post("/api/set-robot-position")
async def set_robot_position(req: RobotPositionRequest):
    if req.checkpoint not in robot.checkpoints:
        raise HTTPException(status_code=400, detail="Checkpoint not found in current map")
    
    robot.current_checkpoint = req.checkpoint
    robot.x = robot.metric_checkpoints[req.checkpoint]["x"]
    robot.y = robot.metric_checkpoints[req.checkpoint]["y"]
    robot.progress = 0.0
    robot.status = "IDLE"
    robot.next_checkpoint = ""
    return {"status": "OK", "x": robot.x, "y": robot.y}

class AvoidanceSettingsRequest(BaseModel):
    enabled: bool
    avoidance_angle: float
    clearance_distance: float
    verification_distance: float
    max_avoidance_angle: float

@app.post("/api/update-avoidance-settings")
async def update_avoidance_settings(req: AvoidanceSettingsRequest):
    robot.obstacle_avoidance_enabled = req.enabled
    robot.avoidance_angle = req.avoidance_angle
    robot.clearance_distance = req.clearance_distance
    robot.verification_distance = req.verification_distance
    robot.max_avoidance_angle = req.max_avoidance_angle
    
    import time
    now_str = time.strftime("%H:%M:%S")
    robot.event_log += f"[{now_str}] Avoidance settings updated: enabled={req.enabled}, angle={req.avoidance_angle}°, clearance={req.clearance_distance}cm, verify={req.verification_distance}cm, max={req.max_avoidance_angle}°\n"
    
    return {"status": "SUCCESS", "message": "Obstacle avoidance settings updated successfully"}

@app.get("/start")
async def start_robot():
    if robot.mode == "auto" and not robot.active_path:
        robot.last_api_response = "GET /start FAILED - NO ACTIVE PATH"
        raise HTTPException(status_code=400, detail="Cannot start autonomous mode without an active planned path.")
    
    robot.speed = CRUISE_SPEED  # Initialize speed to maximum (255) for auto navigation
    robot.status = "STARTING"  # NOT "MOVING" yet — prevents nav loop from sending commands
    robot.obstacle_state = "NORMAL"
    robot.delivery_complete = False
    robot.ramp_deployed = False
    asyncio.create_task(close_ramp())
    
    if robot.mode == "auto":
        robot.pure_pursuit_status = "INACTIVE"
        robot.auto_actions = generate_auto_mission_actions()
        robot.current_action_idx = 0
        robot.action_start_time = asyncio.get_event_loop().time()
        # Initialize robot position to start node
        if robot.active_path:
            start_node = robot.active_path[0]
            robot.x = robot.metric_checkpoints[start_node]["x"]
            robot.y = robot.metric_checkpoints[start_node]["y"]
            robot.current_checkpoint = start_node
            
    # Forward mode, speed, and start to ESP32
    async def start_sequence():
        # Step 1: Stop any in-progress movement
        await send_esp32_command("/stop")
        await asyncio.sleep(0.2)
        # Step 2: Set mode
        await send_esp32_command("/mode", {"type": robot.mode})
        # Step 3: Lock constant cruise speed
        await send_esp32_command("/speed", {"value": CRUISE_SPEED})
        await asyncio.sleep(0.1)
        # Step 4: Begin mission
        await send_esp32_command("/start")
        print("Mission start sequence complete. Setting status to MOVING now.")
        robot.action_start_time = asyncio.get_event_loop().time()  # Reset timer so first action starts fresh
        robot.status = "MOVING"
    asyncio.create_task(start_sequence())
    
    robot.last_api_response = "GET /start OK - INITIALIZING ESP32"
    return {"status": "OK", "message": "Robot start sequence initiated"}

@app.get("/stop")
async def stop_robot():
    robot.status = "STOPPED"
    robot.command = "STOP"
    robot.obstacle_state = "NORMAL"
    robot.paused_by_obstacle = False
    robot.obstacle_detected = False
    
    # Forward stop to ESP32
    asyncio.create_task(send_esp32_command("/stop"))
    
    robot.last_api_response = "GET /stop OK - EMERGENCY STOP/ABORT"
    return {"status": "OK", "message": "Robot stopped immediately"}

@app.get("/speed")
async def set_speed(value: int):
    if value < 0 or value > 255:
        robot.last_api_response = "GET /speed FAILED - VALUE OUT OF RANGE"
        raise HTTPException(status_code=400, detail="Speed must be between 0 and 255")
        
    old_speed = robot.speed
    robot.speed = value
    
    # Scale remaining and future action durations if in middle of auto mission
    if robot.status == "MOVING" and robot.mode == "auto" and robot.auto_actions:
        old_speed_m_s = (old_speed / float(CRUISE_SPEED)) * SPEED_M_S if CRUISE_SPEED else SPEED_M_S
        new_speed_m_s = (value / float(CRUISE_SPEED)) * SPEED_M_S if CRUISE_SPEED else SPEED_M_S
        if old_speed_m_s >= 0.01 and new_speed_m_s >= 0.01:
            ratio = old_speed_m_s / new_speed_m_s
            now = asyncio.get_event_loop().time()
            
            # 1. Scale active action remaining duration
            if robot.current_action_idx < len(robot.auto_actions):
                elapsed = now - robot.action_start_time
                current_action = robot.auto_actions[robot.current_action_idx]
                if current_action["command"] == "FORWARD":
                    remaining = current_action["duration"] - elapsed
                    if remaining > 0:
                        new_remaining = remaining * ratio
                        current_action["duration"] = elapsed + new_remaining
                        print(f"Dynamically scaled active action duration from {elapsed + remaining:.2f}s to {elapsed + new_remaining:.2f}s")
            
            # 2. Scale all future FORWARD actions
            for idx in range(robot.current_action_idx + 1, len(robot.auto_actions)):
                act = robot.auto_actions[idx]
                if act["command"] == "FORWARD":
                    old_dur = act["duration"]
                    act["duration"] = old_dur * ratio
                    print(f"Dynamically scaled future action {idx} duration from {old_dur:.2f}s to {act['duration']:.2f}s")
    
    # Forward speed to ESP32
    asyncio.create_task(send_esp32_command("/speed", {"value": value}))
    
    robot.last_api_response = f"GET /speed?value={value} OK"
    return {"status": "OK", "speed": value}

# Manual command endpoint (used by joystick)
@app.get("/command")
async def set_command(direction: str):
    allowed = ["FORWARD", "BACKWARD", "LEFT", "RIGHT", "STOP"]
    if direction not in allowed:
        robot.last_api_response = f"GET /command FAILED - INVALID CMD {direction}"
        raise HTTPException(status_code=400, detail="Invalid direction command")
        
    robot.command = direction
    if direction != "STOP":
        robot.status = "MOVING"
    else:
        robot.status = "STOPPED"
        
    # Forward command to ESP32
    asyncio.create_task(send_esp32_command("/command", {"direction": direction}))
    
    robot.last_api_response = f"GET /command?direction={direction} OK"
    return {"status": "OK", "command": direction}

@app.get("/api/open-ramp")
async def api_open_ramp():
    success = await open_ramp()
    if success:
        return {"status": "SUCCESS"}
    else:
        raise HTTPException(status_code=500, detail="Failed to communicate with ESP32 to open ramp")

@app.get("/api/close-ramp")
async def api_close_ramp():
    success = await close_ramp()
    if success:
        return {"status": "SUCCESS"}
    else:
        raise HTTPException(status_code=500, detail="Failed to communicate with ESP32 to close ramp")

@app.get("/mode")
async def set_mode(type: str):
    if type not in ["auto", "manual"]:
        raise HTTPException(status_code=400, detail="Invalid mode. Must be 'auto' or 'manual'")
        
    # Stop free roam if active when switching modes
    if robot.free_roam_active:
        robot.free_roam_active = False
        robot.free_roam_state = "IDLE"

    robot.mode = type
    robot.status = "STOPPED"
    robot.command = "STOP"
    robot.paused_by_obstacle = False
    robot.obstacle_detected = False
    
    # Forward mode and stop to ESP32 sequentially
    async def mode_sequence():
        await send_esp32_command("/mode", {"type": type})
        await send_esp32_command("/command", {"direction": "STOP"})
    asyncio.create_task(mode_sequence())
    
    robot.last_api_response = f"GET /mode?type={type} OK"
    return {"status": "OK", "mode": type}


# ─── Free Roam Endpoints ──────────────────────────────────────────────────────

@app.get("/api/free-roam/start")
async def start_free_roam():
    """Activate Free Roam autonomous wandering mode.
    
    The robot moves forward continuously and reacts to obstacles:
    obstacle detected → back up → random left/right turn → resume forward.
    No map or waypoints are required.
    """
    import time
    now_str = time.strftime("%H:%M:%S")

    # Stop any active auto mission first
    if robot.status == "MOVING" and robot.mode == "auto" and robot.active_path:
        robot.status = "STOPPED"
        robot.command = "STOP"
        asyncio.create_task(send_esp32_command("/command", {"direction": "STOP"}))
        await asyncio.sleep(0.3)

    # Switch ESP32 to manual mode so it accepts raw direction commands
    await send_esp32_command("/mode", {"type": "manual"})
    await asyncio.sleep(0.1)

    # Set speed
    await send_esp32_command("/speed", {"value": CRUISE_SPEED})
    robot.speed = CRUISE_SPEED

    # Activate free roam
    robot.free_roam_active = True
    robot.free_roam_state = "MOVING"
    robot.free_roam_backup_start = 0.0
    robot.free_roam_turn_start = 0.0
    robot.last_command_sent_time = 0.0
    robot.status = "MOVING"
    robot.command = "FORWARD"
    robot.last_status_poll_time = 0.0
    robot.event_log += f"[{now_str}] FREE ROAM: Mode activated. Robot wandering autonomously.\n"

    # Send initial forward command
    asyncio.create_task(send_esp32_command("/command", {
        "direction": "FORWARD",
        "speed": CRUISE_SPEED,
        "duration": 2000
    }))

    robot.last_api_response = "FREE ROAM ACTIVATED"
    return {"status": "SUCCESS", "message": "Free Roam mode activated. Robot is wandering.", "free_roam_state": robot.free_roam_state}


@app.get("/api/free-roam/stop")
async def stop_free_roam():
    """Deactivate Free Roam mode and stop the robot."""
    import time
    now_str = time.strftime("%H:%M:%S")

    robot.free_roam_active = False
    robot.free_roam_state = "IDLE"
    robot.status = "STOPPED"
    robot.command = "STOP"
    robot.event_log += f"[{now_str}] FREE ROAM: Mode deactivated. Robot stopped.\n"

    asyncio.create_task(send_esp32_command("/command", {"direction": "STOP"}))

    robot.last_api_response = "FREE ROAM STOPPED"
    return {"status": "SUCCESS", "message": "Free Roam mode deactivated."}

@app.get("/status")
async def get_status():
    return get_telemetry_payload()

@app.get("/api/reset-mission")
async def reset_mission():
    robot.active_path = []
    robot.path_coords = []
    robot.total_distance = 0.0
    robot.current_target_index = 0
    robot.next_checkpoint = ""
    robot.progress = 0.0
    robot.status = "IDLE"
    robot.command = "STOP"
    robot.delivery_complete = False
    robot.ramp_deployed = False
    robot.ramp_status = "CLOSED"
    robot.route_insights = ""
    robot.delivery_intelligence = ""
    
    # Reset obstacle avoidance state machine variables
    robot.obstacle_state = "NORMAL"
    robot.paused_by_obstacle = False
    robot.obstacle_detected = False
    
    # Forward stop and close ramp commands to ESP32
    asyncio.create_task(send_esp32_command("/stop"))
    asyncio.create_task(close_ramp())
    
    robot.last_api_response = "GET /api/reset-mission OK"
    return {"status": "SUCCESS", "message": "Mission reset successfully"}




# ─── ESP32 Connectivity Endpoints ────────────────────────────────────────────

class Esp32IpRequest(BaseModel):
    ip: str

@app.post("/api/set-esp32-ip")
async def set_esp32_ip(req: Esp32IpRequest):
    """Update the ESP32 IP address that the health-check loop targets."""
    robot.esp32_ip = req.ip.strip()
    return {"status": "OK", "esp32_ip": robot.esp32_ip}

@app.get("/api/ping-esp32")
async def ping_esp32():
    """On-demand ESP32 reachability check. Returns connected=True/False."""
    url = f"http://{robot.esp32_ip}/status"
    client = await get_esp32_client()
    try:
        async with esp32_lock:
            resp = await client.get(url, timeout=2.0)
            robot.esp32_connected = resp.status_code == 200
            robot.last_api_response = f"PING OK — HTTP {resp.status_code}"
            return {"connected": True, "ip": robot.esp32_ip, "http_status": resp.status_code}
    except Exception as e:
        robot.esp32_connected = False
        robot.last_api_response = f"PING FAILED: {str(e)}"
        return {"connected": False, "ip": robot.esp32_ip, "error": str(e)}

# ─── Live Motor Calibration Relay ────────────────────────────────────────────
# Relays bias values to the ESP32 /calibrate endpoint and stores locally.
# Also accessible from the Flutter Operator Portal.
@app.get("/api/calibrate")
async def calibrate_motors(right: float = None, left: float = None):
    params = {}
    if right is not None:
        right = max(0.50, min(1.00, right))
        params["right"] = right
        robot.right_motor_bias = right
    if left is not None:
        left = max(0.50, min(1.00, left))
        params["left"] = left
        robot.left_motor_bias = left

    if not params:
        # Return current values only
        return {
            "status": "OK",
            "left_bias": getattr(robot, "left_motor_bias", 1.0),
            "right_bias": getattr(robot, "right_motor_bias", 0.93),
            "esp32_updated": False
        }

    esp32_ok = await send_esp32_command("/calibrate", params)
    robot.last_api_response = f"CALIBRATE left={getattr(robot,'left_motor_bias',1.0):.3f} right={getattr(robot,'right_motor_bias',0.93):.3f}"
    print(f"[CALIBRATE] Sent to ESP32: {params} | ESP32 ACK: {esp32_ok}")
    return {
        "status": "OK",
        "left_bias": getattr(robot, "left_motor_bias", 1.0),
        "right_bias": getattr(robot, "right_motor_bias", 0.93),
        "esp32_updated": esp32_ok
    }

# WebSockets Telemetry Handler
@app.websocket("/ws/telemetry")
async def websocket_telemetry(websocket: WebSocket):
    await manager.connect(websocket)
    try:
        # Send initial state
        await websocket.send_json(get_telemetry_payload())
        while True:
            # Keep connection open. The background loop broadcasts updates.
            # We can also receive commands from the client if needed.
            data = await websocket.receive_text()
            # Simple ping/pong or override check
            msg = json.loads(data)
            if msg.get("type") == "PING":
                await websocket.send_json({"type": "PONG"})
    except WebSocketDisconnect:
        manager.disconnect(websocket)
    except Exception as e:
        print(f"WebSocket error: {e}")
        manager.disconnect(websocket)

# WebSockets Inbound Sensor Stream Receiver for VisionStream Phone App
@app.websocket("/ws/robot-stream")
async def websocket_robot_stream(websocket: WebSocket):
    await websocket.accept()
    robot.phone_connected = True
    print("[VisionStream] Hardware Sensor Hub Phone Connected!")
    try:
        # Tell phone to immediately start camera frame streaming
        await websocket.send_json({"action": "START_CAMERA"})
    except Exception:
        pass
    try:
        while True:
            data_text = await websocket.receive_text()
            try:
                data = json.loads(data_text)
                msg_type = data.get("type")
                if msg_type == "sensor":
                    if "gps" in data:
                        robot.gps = data["gps"]
                    if "imu" in data:
                        robot.imu = data["imu"]
                        if "yaw" in data["imu"]:
                            robot.yaw = data["imu"]["yaw"]
                    if "battery" in data:
                        robot.phone_battery = data["battery"]
                    if "status" in data:
                        robot.phone_status = data["status"]
                elif msg_type == "image":
                    frame_b64 = data.get("frame", "")
                    robot.camera_frame = frame_b64
                    # Broadcast raw frame instantly to all dashboard clients
                    # This is separate from the 10Hz telemetry loop to avoid lag.
                    if frame_b64:
                        await manager.broadcast({
                            "type": "frame_update",
                            "frame": frame_b64,
                            "timestamp": data.get("timestamp", 0),
                            "width": data.get("width", 640),
                            "height": data.get("height", 480),
                        })
                    # Run vision pipeline asynchronously if enabled and not already processing
                    if (VISION_AVAILABLE and robot.vision_enabled
                            and frame_b64 and not robot._vision_processing):
                        robot._vision_processing = True
                        asyncio.create_task(_process_vision_frame(frame_b64))
                elif msg_type == "pong":
                    pass
            except Exception:
                pass
    except WebSocketDisconnect:
        print("[VisionStream] Hardware Sensor Hub Phone Disconnected.")
        robot.phone_connected = False
    except Exception as e:
        print(f"[VisionStream] Stream error: {e}")
        robot.phone_connected = False

# ─────────────────────────────────────────────────────────────────────────────
# Vision Pipeline Integration
# ─────────────────────────────────────────────────────────────────────────────
async def _process_vision_frame(frame_b64: str):
    """Runs YOLO+MiDaS in a thread pool, stores results, sends ESP32 command."""
    try:
        result = await asyncio.to_thread(vision_pipeline.analyze_frame, frame_b64)
        robot.vision_detections = result.get("detections", [])
        robot.vision_command = result.get("command", "FORWARD")
        robot.vision_scene_summary = result.get("scene_summary", "")
        robot.vision_fps = result.get("fps", 0.0)

        # ── Autonomous Mode: send command to ESP32 ────────────────
        if robot.vision_auto_mode and robot.esp32_connected:
            cmd = robot.vision_command
            esp32_cmd_map = {
                "FORWARD":    "FORWARD",
                "STOP":       "STOP",
                "SLOW":       "SLOW",
                "TURN_LEFT":  "LEFT",
                "TURN_RIGHT": "RIGHT",
            }
            esp32_cmd = esp32_cmd_map.get(cmd, "STOP")
            try:
                global esp32_client
                if esp32_client is None:
                    import httpx
                    esp32_client = httpx.AsyncClient(timeout=1.0)
                await esp32_client.get(
                    f"http://{robot.esp32_ip}/cmd",
                    params={"cmd": esp32_cmd},
                )
            except Exception as _ce:
                pass  # ESP32 unreachable; ignore silently

        # ── Broadcast detections to Navix dashboard via telemetry WS ──
        vision_update = {
            "type": "vision_update",
            "command": robot.vision_command,
            "detections": robot.vision_detections,
            "scene_summary": robot.vision_scene_summary,
            "fps": robot.vision_fps,
        }
        await manager.broadcast(json.dumps(vision_update))
    except Exception as e:
        print(f"[VisionPipeline] Frame processing error: {e}")
    finally:
        robot._vision_processing = False


@app.post("/api/vision/toggle")
async def toggle_vision(enabled: Optional[bool] = None, auto_mode: Optional[bool] = None):
    """Enable/disable vision pipeline or autonomous mode."""
    if enabled is not None:
        robot.vision_enabled = enabled
    if auto_mode is not None:
        robot.vision_auto_mode = auto_mode
    return {
        "vision_enabled": robot.vision_enabled,
        "vision_auto_mode": robot.vision_auto_mode,
        "models_loaded": VISION_AVAILABLE and vision_pipeline._models_loaded if VISION_AVAILABLE else False,
    }


@app.get("/api/vision/status")
async def vision_status():
    """Return latest vision pipeline results."""
    return {
        "vision_enabled": robot.vision_enabled,
        "vision_auto_mode": robot.vision_auto_mode,
        "command": robot.vision_command,
        "scene_summary": robot.vision_scene_summary,
        "fps": robot.vision_fps,
        "detections": robot.vision_detections,
        "phone_connected": robot.phone_connected,
        "models_loaded": VISION_AVAILABLE and vision_pipeline._models_loaded if VISION_AVAILABLE else False,
    }


@app.get("/")
async def serve_root():
    index_path = os.path.join(WEB_APP_DIR, "index.html")
    if os.path.exists(index_path):
        return FileResponse(index_path)
    return {"message": "Navix AI AMR Backend Server is running."}

if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8000))
    uvicorn.run("main:app", host="0.0.0.0", port=port)
