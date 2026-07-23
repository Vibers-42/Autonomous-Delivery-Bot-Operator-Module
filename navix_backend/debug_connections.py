import cv2
import numpy as np
import math
from collections import deque

img = cv2.imread('uploads/map.png')
h, w, _ = img.shape
img_gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

is_light_bg = np.mean([img_gray[10, 10], img_gray[10, w - 11], img_gray[h - 11, 10], img_gray[h - 11, w - 11]]) > 127
passable = (img_gray < 200).astype(np.uint8) * 255 if is_light_bg else (img_gray > 100).astype(np.uint8) * 255

# Text blocks (simulate detected text areas from map_analyzer.py)
# Checkpoint 3 text is around x=230 to 350, y=50 to 75
# Checkpoint 2 text is around x=930 to 1050, y=50 to 75
# Checkpoint 1 text is around x=1360 to 1480, y=860 to 880
text_blocks = [
    (230, 50, 120, 25),
    (930, 50, 120, 25),
    (1360, 860, 120, 25)
]

# Erase text blocks
for gx, gy, gw, gh in text_blocks:
    cv2.rectangle(passable, (gx - 5, gy - 5), (gx + gw + 5, gy + gh + 5), 0, -1)

checkpoints = {
    'CHECKPOINT 1': {'x': 1409, 'y': 826},
    'CHECKPOINT 2': {'x': 865, 'y': 61},
    'CHECKPOINT 3': {'x': 156, 'y': 63}
}
checkpoint_radii = {'CHECKPOINT 1': 20, 'CHECKPOINT 2': 20, 'CHECKPOINT 3': 20}

for label, pos in checkpoints.items():
    cv2.circle(passable, (pos["x"], pos["y"]), checkpoint_radii[label] + 5, 255, -1)

# Thicken corridors before downsampling to prevent aliasing
kernel_dilate = cv2.getStructuringElement(cv2.MORPH_RECT, (5, 5))
passable_dilated = cv2.dilate(passable, kernel_dilate, iterations=1)

scale = 8
grid_h = h // scale
grid_w = w // scale
grid = cv2.resize(passable_dilated, (grid_w, grid_h), interpolation=cv2.INTER_NEAREST)

def find_direct_path(n1, n2):
    start_pt = checkpoints[n1]
    end_pt = checkpoints[n2]
    
    sx, sy = start_pt["x"] // scale, start_pt["y"] // scale
    ex, ey = end_pt["x"] // scale, end_pt["y"] // scale
    
    queue = deque([(sx, sy, 0)])
    visited = {(sx, sy)}
    
    end_cells = []
    r_target = int(np.ceil(checkpoint_radii[n2] / scale))
    for dx in range(-r_target, r_target + 1):
        for dy in range(-r_target, r_target + 1):
            end_cells.append((ex + dx, ey + dy))
            
    while queue:
        x, y, d = queue.popleft()
        
        if (x, y) in end_cells:
            return d * scale
            
        for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)]:
            nx, ny = x + dx, y + dy
            if 0 <= nx < grid_w and 0 <= ny < grid_h:
                if grid[ny, nx] > 0 and (nx, ny) not in visited:
                    visited.add((nx, ny))
                    step_cost = np.sqrt(dx*dx + dy*dy)
                    queue.append((nx, ny, d + step_cost))
    return None

print("Scale 8 paths WITH text block erasure:")
print("3 -> 2:", find_direct_path("CHECKPOINT 3", "CHECKPOINT 2"))
print("2 -> 1:", find_direct_path("CHECKPOINT 2", "CHECKPOINT 1"))
print("3 -> 1:", find_direct_path("CHECKPOINT 3", "CHECKPOINT 1"))
