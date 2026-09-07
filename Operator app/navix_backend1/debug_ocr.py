import cv2
import numpy as np
from map_analyzer import MapAnalyzer

def debug():
    analyzer = MapAnalyzer()
    img = cv2.imread("sample_map.png")
    img_gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    _, thresh = cv2.threshold(img_gray, 200, 255, cv2.THRESH_BINARY)
    contours, _ = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    
    print(f"Found {len(contours)} total contours")
    for i, c in enumerate(contours):
        area = cv2.contourArea(c)
        perimeter = cv2.arcLength(c, True)
        if perimeter == 0:
            continue
        circularity = 4 * np.pi * area / (perimeter * perimeter)
        if 300 < area < 3000 and circularity > 0.75:
            M = cv2.moments(c)
            cx = int(M["m10"] / M["m00"])
            cy = int(M["m01"] / M["m00"])
            
            # Use smaller radius (11) to exclude the blue ring (radius 20)
            r = 11
            roi = img_gray[cy-r:cy+r, cx-r:cx+r]
            _, roi_bin = cv2.threshold(roi, 127, 255, cv2.THRESH_BINARY)
            roi_char = analyzer.get_tight_char_crop(roi_bin)
            
            print(f"\nNode at ({cx}, {cy}): area={area:.1f}, circularity={circularity:.2f}")
            scores = {}
            for letter in ['A', 'B', 'C', 'D', 'E', 'F']:
                template = analyzer.generate_letter_template(letter)
                diff = cv2.absdiff(roi_char, template)
                scores[letter] = np.sum(diff)
            
            sorted_scores = sorted(scores.items(), key=lambda x: x[1])
            print(f"  Matching scores: {sorted_scores}")
            print(f"  Best Match: {sorted_scores[0][0]}")

if __name__ == "__main__":
    debug()
