"""
Navix Vision Pipeline — YOLO Object Detection + MiDaS Depth Estimation
Runs inference on each camera frame and generates autonomous robot commands.
"""
import base64
import io
import time
import threading
from typing import Optional

import numpy as np
import cv2


# ─────────────────────────────────────────────────────────────────
# Lazy imports: YOLO and MiDaS are heavy; load once on first use
# ─────────────────────────────────────────────────────────────────
_yolo_model = None
_midas_model = None
_midas_transform = None
_midas_device = None
_models_loaded = False
_model_load_lock = threading.Lock()


def _load_models():
    global _yolo_model, _midas_model, _midas_transform, _midas_device, _models_loaded
    with _model_load_lock:
        if _models_loaded:
            return
        try:
            from ultralytics import YOLO
            print("[VisionPipeline] Loading YOLOv8n model...")
            _yolo_model = YOLO("yolov8n.pt")   # auto-downloads ~6 MB on first run
            print("[VisionPipeline] YOLOv8n loaded OK")
        except Exception as e:
            print(f"[VisionPipeline] YOLO load error: {e}")

        try:
            import torch
            _midas_device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
            print(f"[VisionPipeline] Loading MiDaS on {_midas_device}...")
            _midas_model = torch.hub.load(
                "intel-isl/MiDaS", "MiDaS_small",
                trust_repo="check",
                skip_validation=True,
            )
            _midas_model.to(_midas_device)
            _midas_model.eval()
            midas_transforms = torch.hub.load(
                "intel-isl/MiDaS", "transforms",
                trust_repo="check",
                skip_validation=True,
            )
            _midas_transform = midas_transforms.small_transform
            print("[VisionPipeline] MiDaS loaded OK")
        except Exception as e:
            print(f"[VisionPipeline] MiDaS load error: {e}")

        _models_loaded = True


# ─────────────────────────────────────────────────────────────────
# Constants for autonomous command generation
# ─────────────────────────────────────────────────────────────────
# YOLO class IDs that are treated as obstacles (COCO dataset labels)
OBSTACLE_CLASSES = {
    0: "person", 1: "bicycle", 2: "car", 3: "motorcycle",
    5: "bus", 7: "truck", 13: "bench", 14: "bird",
    15: "cat", 16: "dog", 56: "chair", 57: "couch",
    58: "potted plant", 59: "bed", 60: "dining table",
    62: "tv", 63: "laptop", 64: "mouse", 73: "book",
    75: "vase", 77: "teddy bear",
}

STOP_DISTANCE_M = 0.8        # Stop if obstacle is closer than 0.8 m
SLOW_DISTANCE_M = 1.5        # Slow down if obstacle is within 1.5 m
CENTER_DEADZONE = 0.20       # ±20% of frame width = "center" zone
CONF_THRESHOLD  = 0.45       # Minimum YOLO confidence to act on
FRAME_W = 640
FRAME_H = 480

# MiDaS depth calibration: disparity -> metres (approximate, scene-dependent)
# MiDaS outputs relative inverse depth; we use a simple linear scale factor.
MIDAS_SCALE_FACTOR = 3.5    # tune per environment


# ─────────────────────────────────────────────────────────────────
# Main pipeline entry
# ─────────────────────────────────────────────────────────────────
def analyze_frame(frame_b64: str) -> dict:
    """
    Takes a base-64 encoded JPEG frame, runs YOLO + MiDaS inference,
    and returns detections + an autonomous navigation command.

    Returns:
        {
          "command": "FORWARD" | "STOP" | "TURN_LEFT" | "TURN_RIGHT" | "SLOW",
          "detections": [ {label, confidence, box, distance_m} ],
          "scene_summary": str,
          "fps": float,
        }
    """
    t0 = time.time()
    if not _models_loaded:
        _load_models()

    # ── 1. Decode frame ───────────────────────────────────────────
    try:
        img_bytes = base64.b64decode(frame_b64)
        nparr = np.frombuffer(img_bytes, np.uint8)
        bgr = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
        if bgr is None:
            return _empty_result("FORWARD", "Frame decode failed")
        bgr = cv2.resize(bgr, (FRAME_W, FRAME_H))
    except Exception as e:
        return _empty_result("FORWARD", f"Decode error: {e}")

    detections = []
    depth_map_norm = None

    # ── 2. YOLO Inference ─────────────────────────────────────────
    if _yolo_model is not None:
        try:
            device_str = "cuda" if (_midas_device and _midas_device.type == "cuda") else "cpu"
            results = _yolo_model.predict(
                bgr,
                imgsz=640,
                conf=CONF_THRESHOLD,
                verbose=False,
                device=device_str,
            )
            for r in results:
                for box in r.boxes:
                    cls_id = int(box.cls[0].item())
                    label = r.names.get(cls_id, f"cls{cls_id}")
                    conf  = float(box.conf[0].item())
                    x1, y1, x2, y2 = [int(v) for v in box.xyxy[0].tolist()]
                    cx = (x1 + x2) / 2
                    cy = (y1 + y2) / 2
                    detections.append({
                        "class_id": cls_id,
                        "label": label,
                        "confidence": round(conf, 3),
                        "box": {"x1": x1, "y1": y1, "x2": x2, "y2": y2},
                        "center": {"cx": cx, "cy": cy},
                        "distance_m": None,   # filled in after depth estimation
                        "is_obstacle": cls_id in OBSTACLE_CLASSES,
                    })
        except Exception as e:
            print(f"[VisionPipeline] YOLO error: {e}")

    # ── 3. MiDaS Depth Estimation ─────────────────────────────────
    if _midas_model is not None and _midas_transform is not None:
        try:
            import torch
            rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
            input_batch = _midas_transform(rgb).to(_midas_device)
            with torch.no_grad():
                prediction = _midas_model(input_batch)
                prediction = torch.nn.functional.interpolate(
                    prediction.unsqueeze(1),
                    size=(FRAME_H, FRAME_W),
                    mode="bilinear",
                    align_corners=False,
                ).squeeze()
            depth_raw = prediction.cpu().numpy()
            # Normalise to 0-1 for visualisation
            d_min, d_max = depth_raw.min(), depth_raw.max()
            if d_max > d_min:
                depth_map_norm = (depth_raw - d_min) / (d_max - d_min)
            else:
                depth_map_norm = np.zeros_like(depth_raw)

            # Assign distance estimates to each detection using median depth in bbox
            for det in detections:
                b = det["box"]
                roi = depth_raw[b["y1"]:b["y2"], b["x1"]:b["x2"]]
                if roi.size > 0:
                    # High disparity = close object.  Convert relative to approx metres.
                    # MiDaS gives inverse depth so larger = closer.
                    rel_disp = float(np.median(roi))
                    # Normalise relative to scene max
                    scene_disp = float(depth_raw.max())
                    if scene_disp > 0:
                        # Simple heuristic: scale to approximate metres
                        dist_m = MIDAS_SCALE_FACTOR * (scene_disp / (rel_disp + 1e-6))
                        det["distance_m"] = round(max(0.1, min(dist_m, 20.0)), 2)
        except Exception as e:
            print(f"[VisionPipeline] MiDaS error: {e}")

    # ── 4. Autonomous Command Engine ──────────────────────────────
    command, scene_summary = _decide_command(detections, bgr)

    elapsed = time.time() - t0
    fps = round(1.0 / elapsed, 1) if elapsed > 0 else 0.0

    print(f"[VisionPipeline] cmd={command} | objs={len(detections)} | {elapsed*1000:.0f}ms | {scene_summary}")

    return {
        "command": command,
        "detections": detections,
        "scene_summary": scene_summary,
        "fps": fps,
    }


def _decide_command(detections: list, bgr_frame) -> tuple[str, str]:
    """
    Given detections with estimated distances, decide the best movement command.
    Priority: STOP > TURN_LEFT/RIGHT > SLOW > FORWARD
    """
    frame_cx = FRAME_W / 2

    # Filter to actual obstacle objects with distance data
    obstacles = [
        d for d in detections
        if d.get("is_obstacle") and d.get("distance_m") is not None
    ]
    # Also consider any large bounding box as potential obstacle (even unknown class)
    for d in detections:
        if not d.get("is_obstacle"):
            b = d["box"]
            box_area_ratio = (b["x2"] - b["x1"]) * (b["y2"] - b["y1"]) / (FRAME_W * FRAME_H)
            if box_area_ratio > 0.25 and d.get("distance_m") is not None:
                d["is_obstacle"] = True
                obstacles.append(d)

    if not obstacles:
        # Check central bottom region for close objects (depth-only)
        return "FORWARD", "Path clear — moving forward"

    # Sort by proximity (closer first)
    obstacles.sort(key=lambda d: d.get("distance_m", 99))
    closest = obstacles[0]
    dist = closest["distance_m"]
    label = closest["label"]
    cx = closest["center"]["cx"]

    # Dead stop: too close
    if dist <= STOP_DISTANCE_M:
        # Decide turn direction based on which side the obstacle is on
        if cx < frame_cx * (1 - CENTER_DEADZONE):
            # Obstacle on LEFT → turn RIGHT to avoid
            return "TURN_RIGHT", f"STOP: {label} {dist}m (left) → turning right"
        elif cx > frame_cx * (1 + CENTER_DEADZONE):
            # Obstacle on RIGHT → turn LEFT
            return "TURN_LEFT", f"STOP: {label} {dist}m (right) → turning left"
        else:
            # Obstacle dead center → pick left turn by default
            return "TURN_LEFT", f"STOP: {label} {dist}m (center) → turning left"

    # Slow zone: approaching obstacle
    if dist <= SLOW_DISTANCE_M:
        if cx < frame_cx * (1 - CENTER_DEADZONE):
            return "TURN_RIGHT", f"SLOW: {label} {dist}m on left → bearing right"
        elif cx > frame_cx * (1 + CENTER_DEADZONE):
            return "TURN_LEFT", f"SLOW: {label} {dist}m on right → bearing left"
        else:
            return "SLOW", f"SLOW: {label} {dist}m ahead — slowing"

    return "FORWARD", f"Objects detected but distant ({dist}m) — continuing"


def _empty_result(command: str, reason: str) -> dict:
    return {
        "command": command,
        "detections": [],
        "scene_summary": reason,
        "fps": 0.0,
    }


def preload_models():
    """Call this on startup in a background thread so models are warm before first frame."""
    thread = threading.Thread(target=_load_models, daemon=True)
    thread.start()
    return thread
