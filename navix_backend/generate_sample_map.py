import cv2
import numpy as np
import os

def create_sample_map(output_path):
    # Create a black background (walls)
    # 800 width, 600 height, 3 channels for RGB styling
    height, width = 600, 800
    img = np.zeros((height, width, 3), dtype=np.uint8)

    # Define paths (corridors) as white lines
    # Corridors: A(100, 100), B(400, 100), C(400, 350), D(100, 350), E(700, 350), F(700, 500)
    # Define connections
    paths = [
        ((100, 100), (400, 100)), # A -> B
        ((400, 100), (400, 350)), # B -> C
        ((400, 350), (100, 350)), # C -> D
        ((100, 350), (100, 100)), # D -> A
        ((400, 350), (700, 350)), # C -> E
        ((700, 350), (700, 500))  # E -> F
    ]

    # Draw the corridors (white paths, thickness 30 to make it realistic for AMR)
    for start, end in paths:
        cv2.line(img, start, end, (255, 255, 255), 32)

    # Draw the corridors slightly smaller to keep the clean path lines visible
    for start, end in paths:
        cv2.line(img, start, end, (240, 240, 240), 28)

    # Define checkpoints
    checkpoints = {
        'A': (100, 100),
        'B': (400, 100),
        'C': (400, 350),
        'D': (100, 350),
        'E': (700, 350),
        'F': (700, 500)
    }

    # Draw checkpoints: white circle with blue border, and a black letter inside
    for label, pos in checkpoints.items():
        # Outer blue ring for high-tech aesthetic
        cv2.circle(img, pos, 24, (200, 120, 0), -1)  # BGR: blueish
        # White inner circle
        cv2.circle(img, pos, 20, (255, 255, 255), -1)
        # Black label inside
        font = cv2.FONT_HERSHEY_SIMPLEX
        font_scale = 0.6
        thickness = 2
        # Get text size to center it
        text_size = cv2.getTextSize(label, font, font_scale, thickness)[0]
        text_x = pos[0] - text_size[0] // 2
        text_y = pos[1] + text_size[1] // 2
        cv2.putText(img, label, (text_x, text_y), font, font_scale, (0, 0, 0), thickness, cv2.LINE_AA)

    # Add some warehouse details / mock obstacles (black rectangles in non-path areas)
    # Obstacle 1
    cv2.rectangle(img, (200, 180), (300, 280), (10, 10, 10), -1)
    cv2.rectangle(img, (200, 180), (300, 280), (50, 50, 50), 2)
    # Obstacle 2
    cv2.rectangle(img, (500, 150), (600, 280), (10, 10, 10), -1)
    cv2.rectangle(img, (500, 150), (600, 280), (50, 50, 50), 2)
    # Obstacle 3
    cv2.rectangle(img, (250, 420), (550, 480), (10, 10, 10), -1)
    cv2.rectangle(img, (250, 420), (550, 480), (50, 50, 50), 2)

    # Save the generated map
    dirname = os.path.dirname(output_path)
    if dirname:
        os.makedirs(dirname, exist_ok=True)
    cv2.imwrite(output_path, img)
    print(f"Sample map successfully generated at: {output_path}")

if __name__ == "__main__":
    create_sample_map("sample_map.png")
