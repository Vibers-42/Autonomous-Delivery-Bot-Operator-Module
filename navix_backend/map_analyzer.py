"""
Navix AMR Map Analyzer fallback module.
Provides dynamic checkpoint detection and corridor topology extraction.
"""
import cv2
import numpy as np
import os
import re
import math
from collections import deque

class RobustOCR:
    def __init__(self, thickness=13):
        # Generate templates for letters A-Z and digits 0-9 + 'c', 'm'
        self.char_list = [chr(i) for i in range(ord('A'), ord('Z')+1)] + [str(i) for i in range(10)] + ['c', 'm']
        self.templates = {}
        for char in self.char_list:
            self.templates[char] = self.generate_letter_template(char, thickness=thickness)
            
    def get_tight_char_crop(self, roi_bin, target_size=(20, 20)):
        # roi_bin is binary (0 for text, 255 for background)
        text_mask = cv2.bitwise_not(roi_bin)
        contours, _ = cv2.findContours(text_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        
        if not contours:
            return cv2.resize(roi_bin, target_size)
            
        h, w = roi_bin.shape
        valid_boxes = []
        for c in contours:
            area = cv2.contourArea(c)
            if area > 8:
                x, y, box_w, box_h = cv2.boundingRect(c)
                if box_w < w - 2 and box_h < h - 2:
                    valid_boxes.append((x, y, x + box_w, y + box_h))
                    
        if not valid_boxes:
            c = max(contours, key=cv2.contourArea)
            x, y, box_w, box_h = cv2.boundingRect(c)
            x_min, y_min, x_max, y_max = x, y, x + box_w, y + box_h
        else:
            x_min = min(b[0] for b in valid_boxes)
            y_min = min(b[1] for b in valid_boxes)
            x_max = max(b[2] for b in valid_boxes)
            y_max = max(b[3] for b in valid_boxes)
            
        x_min = max(0, x_min - 1)
        y_min = max(0, y_min - 1)
        x_max = min(w, x_max + 1)
        y_max = min(h, y_max + 1)
        
        char_crop = roi_bin[y_min:y_max, x_min:x_max]
        return cv2.resize(char_crop, target_size)

    def generate_letter_template(self, char, size=100, thickness=13):
        template = np.ones((size, size), dtype=np.uint8) * 255
        font = cv2.FONT_HERSHEY_SIMPLEX
        font_scale = 1.8
        text_size = cv2.getTextSize(char, font, font_scale, thickness)[0]
        text_x = (size - text_size[0]) // 2
        text_y = (size + text_size[1]) // 2
        cv2.putText(template, char, (text_x, text_y), font, font_scale, 0, thickness, cv2.LINE_AA)
        _, template_bin = cv2.threshold(template, 127, 255, cv2.THRESH_BINARY)
        return self.get_tight_char_crop(template_bin)

    def recognize_char(self, roi):
        return self.recognize_char_ncc(roi)

    def recognize_char_ncc(self, roi, allowed_chars=None):
        if len(roi.shape) == 3:
            roi_gray = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
        else:
            roi_gray = roi

        # Normalize/threshold ROI using Otsu
        _, roi_bin = cv2.threshold(roi_gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        
        # Check border pixels to see if background is dark or light
        h, w = roi_bin.shape
        border_pixels = []
        for i in range(h):
            border_pixels.append(roi_bin[i, 0])
            border_pixels.append(roi_bin[i, w-1])
        for j in range(w):
            border_pixels.append(roi_bin[0, j])
            border_pixels.append(roi_bin[h-1, j])
            
        mean_border = np.mean(border_pixels)
        if mean_border < 127:
            # Dark background, light text -> invert so text is black, background is white
            roi_bin = cv2.bitwise_not(roi_bin)
            
        roi_char = self.get_tight_char_crop(roi_bin)
        
        best_match = None
        max_score = -1.0
        
        chars_to_check = allowed_chars if allowed_chars is not None else self.templates.keys()
        for char in chars_to_check:
            if char in self.templates:
                template = self.templates[char]
                # Invert binary images so that text is white (1.0) and background is black (0.0) for NCC template matching
                t_f = (255.0 - roi_char.astype(np.float32)) / 255.0
                temp_f = (255.0 - template.astype(np.float32)) / 255.0
                res = cv2.matchTemplate(t_f, temp_f, cv2.TM_CCOEFF_NORMED)
                score = res[0, 0]
                if score > max_score:
                    max_score = score
                    best_match = char
                    
        return best_match

class MapAnalyzer:
    def __init__(self):
        self.ocr = RobustOCR()

    def p_dist_to_segment(self, px, py, x1, y1, x2, y2):
        # Calculate perpendicular distance from point (px, py) to line segment (x1, y1) - (x2, y2)
        dx = x2 - x1
        dy = y2 - y1
        if dx == 0 and dy == 0:
            return np.sqrt((px - x1)**2 + (py - y1)**2)
            
        t = ((px - x1) * dx + (py - y1) * dy) / (dx*dx + dy*dy)
        t = max(0, min(1, t))
        proj_x = x1 + t * dx
        proj_y = y1 + t * dy
        return np.sqrt((px - proj_x)**2 + (py - proj_y)**2)

    def fit_curve_to_path(self, pixel_path):
        import math
        import numpy as np
        
        if not pixel_path or len(pixel_path) < 2:
            return "straight", [], None, 0.0, 0.0, 0.0
            
        pts = np.array(pixel_path, dtype=np.float32)
        n = len(pts)
        p_start = pts[0]
        p_end = pts[-1]
        
        chord_len = float(np.linalg.norm(p_end - p_start))
        if chord_len < 1.0:
            return "straight", [], None, 0.0, 0.0, 0.0
            
        line_vec = (p_end - p_start) / chord_len
        line_normal = np.array([-line_vec[1], line_vec[0]], dtype=np.float32)
        
        perp_dists = []
        for p in pts:
            v = p - p_start
            d = abs(np.dot(v, line_normal))
            perp_dists.append(d)
            
        max_line_err = max(perp_dists)
        
        # 1. Straight Line Test
        if max_line_err < 12.0:
            heading = float(math.atan2(p_end[1] - p_start[1], p_end[0] - p_start[0]))
            return "straight", [], None, chord_len, heading, 0.0

        # 2. Circular Arc Test
        try:
            A_mat = np.zeros((n, 3), dtype=np.float32)
            B_mat = np.zeros((n, 1), dtype=np.float32)
            for i, p in enumerate(pts):
                A_mat[i, 0] = 2.0 * p[0]
                A_mat[i, 1] = 2.0 * p[1]
                A_mat[i, 2] = 1.0
                B_mat[i, 0] = p[0]**2 + p[1]**2
                
            sol, _, _, _ = np.linalg.lstsq(A_mat, B_mat, rcond=None)
            xc = float(sol[0, 0])
            yc = float(sol[1, 0])
            R = float(math.sqrt(sol[2, 0] + xc**2 + yc**2))
            
            circle_dists = np.sqrt((pts[:, 0] - xc)**2 + (pts[:, 1] - yc)**2)
            mean_circle_err = float(np.mean(np.abs(circle_dists - R)))
            
            if mean_circle_err < 10.0 and R < 4000.0:
                v1 = p_start - np.array([xc, yc])
                v2 = p_end - np.array([xc, yc])
                a1 = math.atan2(v1[1], v1[0])
                a2 = math.atan2(v2[1], v2[0])
                
                adiff = a2 - a1
                if abs(adiff) > math.pi:
                    if adiff > 0:
                        adiff -= 2 * math.pi
                    else:
                        adiff += 2 * math.pi
                
                arc_len = R * abs(adiff)
                heading = float(math.atan2(p_end[1] - p_start[1], p_end[0] - p_start[0]))
                curvature = 1.0 / R
                return "arc", [[xc, yc]], R, arc_len, heading, curvature
        except Exception:
            pass

        # 3. Cubic Bezier Curve Test
        start_seg = max(2, n // 10)
        t_start = (pts[start_seg] - p_start)
        t_start_len = np.linalg.norm(t_start)
        if t_start_len > 0.001:
            t_start /= t_start_len
        else:
            t_start = line_vec
            
        t_end = (p_end - pts[-start_seg - 1])
        t_end_len = np.linalg.norm(t_end)
        if t_end_len > 0.001:
            t_end /= t_end_len
        else:
            t_end = line_vec
            
        k = chord_len / 3.0
        cp1 = p_start + k * t_start
        cp2 = p_end - k * t_end
        
        bezier_pts = []
        for step in range(n):
            t = step / (n - 1)
            bx = (1-t)**3 * p_start[0] + 3*(1-t)**2*t * cp1[0] + 3*(1-t)*t**2 * cp2[0] + t**3 * p_end[0]
            by = (1-t)**3 * p_start[1] + 3*(1-t)**2*t * cp1[1] + 3*(1-t)*t**2 * cp2[1] + t**3 * p_end[1]
            bezier_pts.add([bx, by]) if isinstance(bezier_pts, set) else bezier_pts.append([bx, by])
            
        bezier_pts = np.array(bezier_pts, dtype=np.float32)
        mean_bezier_err = float(np.mean(np.linalg.norm(pts - bezier_pts, axis=1)))
        
        if mean_bezier_err < 18.0:
            bezier_len = 0.0
            for i in range(len(bezier_pts) - 1):
                bezier_len += np.linalg.norm(bezier_pts[i+1] - bezier_pts[i])
                
            heading = float(math.atan2(p_end[1] - p_start[1], p_end[0] - p_start[0]))
            curvature = 2.0 / chord_len
            return "bezier", [[float(cp1[0]), float(cp1[1])], [float(cp2[0]), float(cp2[1])]], None, float(bezier_len), heading, curvature

        # 4. Fallback Cubic Spline Test
        cp_idx = [0, n // 3, (2 * n) // 3, n - 1]
        control_points = [pts[idx].tolist() for idx in cp_idx]
        
        spline_len = 0.0
        for i in range(n - 1):
            spline_len += np.linalg.norm(pts[i+1] - pts[i])
            
        heading = float(math.atan2(p_end[1] - p_start[1], p_end[0] - p_start[0]))
        curvature = 2.0 / chord_len
        return "spline", control_points, None, float(spline_len), heading, curvature

    def prune_skeleton(self, pruned, max_len=8):
        h, w = pruned.shape
        for pass_idx in range(5):
            skel_pts = np.argwhere(pruned > 0)
            skel_pixels = set((x, y) for y, x in skel_pts)
            
            endpoints = []
            for y, x in skel_pts:
                neighborhood = pruned[y-1:y+2, x-1:x+2]
                neighbors = np.count_nonzero(neighborhood) - 1
                if neighbors == 1:
                    endpoints.append((x, y))
                    
            pixels_to_remove = set()
            for ep in endpoints:
                path = [ep]
                visited = set([ep])
                curr = ep
                is_spur = False
                
                for _ in range(max_len):
                    cx, cy = curr
                    nbrs = []
                    for dx in [-1, 0, 1]:
                        for dy in [-1, 0, 1]:
                            if dx == 0 and dy == 0:
                                continue
                            nx, ny = cx + dx, cy + dy
                            if (nx, ny) in skel_pixels and (nx, ny) not in visited:
                                nbrs.append((nx, ny))
                                
                    if not nbrs:
                        break
                        
                    neighborhood = pruned[cy-1:cy+2, cx-1:cx+2]
                    neighbors_count = np.count_nonzero(neighborhood) - 1
                    if neighbors_count >= 3:
                        is_spur = True
                        break
                        
                    next_pt = nbrs[0]
                    path.append(next_pt)
                    visited.add(next_pt)
                    curr = next_pt
                    
                if is_spur:
                    for px, py in path:
                        pixels_to_remove.add((px, py))
                        
            if not pixels_to_remove:
                break
                
            for px, py in pixels_to_remove:
                pruned[py, px] = 0
                
        return pruned

    def trace_skeleton_paths(self, skeleton, keypoints):
        kp_set = set((kp[0], kp[1]) for kp in keypoints)
        kp_indices = { (kp[0], kp[1]): idx for idx, kp in enumerate(keypoints) }
        visited_edges = set()
        connections = []
        skel_pixels = set((x, y) for y, x in np.argwhere(skeleton > 0))
        
        for kp_idx, kp in enumerate(keypoints):
            kx, ky = kp
            neighbors = []
            for dx in [-1, 0, 1]:
                for dy in [-1, 0, 1]:
                    if dx == 0 and dy == 0:
                        continue
                    nx, ny = kx + dx, ky + dy
                    if (nx, ny) in skel_pixels:
                        neighbors.append((nx, ny))
                        
            for start_nbr in neighbors:
                edge_key = (min((kx, ky), start_nbr), max((kx, ky), start_nbr))
                if edge_key in visited_edges:
                    continue
                    
                path = [[kx, ky], [start_nbr[0], start_nbr[1]]]
                visited = set([(kx, ky), start_nbr])
                curr = start_nbr
                reached_kp = None
                
                while True:
                    cx, cy = curr
                    nbrs = []
                    for dx in [-1, 0, 1]:
                        for dy in [-1, 0, 1]:
                            if dx == 0 and dy == 0:
                                continue
                            nx, ny = cx + dx, cy + dy
                            if (nx, ny) in skel_pixels and (nx, ny) not in visited:
                                nbrs.append((nx, ny))
                                
                    found_kp = None
                    for dx in [-1, 0, 1]:
                        for dy in [-1, 0, 1]:
                            if dx == 0 and dy == 0:
                                continue
                            nx, ny = cx + dx, cy + dy
                            if (nx, ny) in kp_set:
                                if (nx, ny) == (kx, ky) and len(path) < 15:
                                    continue
                                found_kp = (nx, ny)
                                break
                        if found_kp:
                            break
                            
                    if found_kp:
                        path.append([found_kp[0], found_kp[1]])
                        reached_kp = found_kp
                        break
                        
                    if not nbrs:
                        break
                        
                    next_pt = nbrs[0]
                    path.append([next_pt[0], next_pt[1]])
                    visited.add(next_pt)
                    
                    step_key = (min(curr, next_pt), max(curr, next_pt))
                    visited_edges.add(step_key)
                    
                    curr = next_pt
                    
                if reached_kp is not None:
                    for k in range(len(path) - 1):
                        p1 = (path[k][0], path[k][1])
                        p2 = (path[k+1][0], path[k+1][1])
                        visited_edges.add((min(p1, p2), max(p1, p2)))
                        
                    connections.append({
                        "from_idx": kp_idx,
                        "to_idx": kp_indices[reached_kp],
                        "pixel_path": path
                    })
                    
        unique_conns = {}
        for c in connections:
            pair = (min(c["from_idx"], c["to_idx"]), max(c["from_idx"], c["to_idx"]))
            if pair not in unique_conns or len(c["pixel_path"]) < len(unique_conns[pair]["pixel_path"]):
                unique_conns[pair] = c
                
        return list(unique_conns.values())

    def ramer_douglas_peucker(self, pts, epsilon):
        if len(pts) < 3:
            return pts
        
        dmax = 0.0
        index = 0
        end = len(pts) - 1
        for i in range(1, end):
            d = self.p_dist_to_segment(pts[i][0], pts[i][1], pts[0][0], pts[0][1], pts[end][0], pts[end][1])
            if d > dmax:
                index = i
                dmax = d
                
        if dmax > epsilon:
            results1 = self.ramer_douglas_peucker(pts[:index+1], epsilon)
            results2 = self.ramer_douglas_peucker(pts[index:], epsilon)
            return results1[:-1] + results2
        else:
            return [pts[0], pts[end]]

    def analyze_map(self, image_path):
        import math
        import re
        from collections import deque
        if not os.path.exists(image_path):
            raise FileNotFoundError(f"Map image not found at: {image_path}")

        img = cv2.imread(image_path)
        h, w, _ = img.shape
        base_dim = max(w, h)
        img_gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

        corners = [
            img_gray[10, 10],
            img_gray[10, w-11],
            img_gray[h-11, 10],
            img_gray[h-11, w-11]
        ]
        is_light_bg = np.mean(corners) > 127

        # 1. Detect all text characters & group them into word blocks
        if is_light_bg:
            _, thresh = cv2.threshold(img_gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
        else:
            _, thresh = cv2.threshold(img_gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)

        text_contours, _ = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

        char_candidates = []
        for c in text_contours:
            x, y, box_w, box_h = cv2.boundingRect(c)
            area = cv2.contourArea(c)
            if 5 < box_w < 100 and 10 < box_h < 100 and area > 10:
                char_candidates.append((x, y, box_w, box_h, c))

        max_dist_h = int(base_dim / 25)
        max_dist_v = int(base_dim / 50)
        text_blocks = []
        used = set()
        for i, box1 in enumerate(char_candidates):
            if i in used: continue
            group = [box1]; used.add(i)
            added = True
            while added:
                added = False
                for j, box2 in enumerate(char_candidates):
                    if j in used: continue
                    x2, y2, w2, h2, _ = box2
                    cx2, cy2 = x2 + w2/2, y2 + h2/2
                    close = False
                    for x1, y1, w1, h1, _ in group:
                        cx1, cy1 = x1 + w1/2, y1 + h1/2
                        if (abs(cx1 - cx2) < max_dist_h and abs(cy1 - cy2) < max_dist_v) or \
                           (abs(cy1 - cy2) < max_dist_h and abs(cx1 - cx2) < max_dist_v):
                            close = True; break
                    if close: group.append(box2); used.add(j); added = True
            x_min = min(b[0] for b in group); y_min = min(b[1] for b in group)
            x_max = max(b[0] + b[2] for b in group); y_max = max(b[1] + b[3] for b in group)
            text_blocks.append((x_min, y_min, x_max - x_min, y_max - y_min, group))

        word_blocks = []
        detected_distances = []
        for gx, gy, gw, gh, group in text_blocks:
            is_vertical = gh > gw * 1.5
            if is_vertical:
                rotated = cv2.rotate(img[max(0, gy-5):min(h, gy+gh+5), max(0, gx-5):min(w, gx+gw+5)], cv2.ROTATE_90_CLOCKWISE)
                rot_gray = cv2.cvtColor(rotated, cv2.COLOR_BGR2GRAY)
                _, rot_thresh = cv2.threshold(rot_gray, 60, 255, cv2.THRESH_BINARY_INV)
                rot_contours, _ = cv2.findContours(rot_thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
                rot_chars = sorted([(cv2.boundingRect(rc)) for rc in rot_contours if 5 < cv2.boundingRect(rc)[2] < 100], key=lambda k: k[0])
                word_chars_p1 = [self.ocr.recognize_char(rotated[ry-2:ry+rh+2, rx-2:rx+rw+2]) for rx, ry, rw, rh in rot_chars]
                word_str_p1 = "".join(word_chars_p1)
            else:
                sorted_chars = sorted(group, key=lambda k: k[0])
                char_rois = [img[cy-2:cy+ch+2, cx-2:cx+cw+2] for cx, cy, cw, ch, _ in sorted_chars]
                word_chars_p1 = [self.ocr.recognize_char(roi) for roi in char_rois]
                word_str_p1 = "".join(word_chars_p1)

            L = len(word_chars_p1)
            if L >= 2 and word_chars_p1[-1].lower() in ['c', 'm']:
                word_chars_p2 = [self.ocr.recognize_char_ncc(char_rois[idx], ['c','m'] if idx>=L-2 else [str(d) for d in range(10)]) for idx in range(L)]
                word_str = "".join(word_chars_p2)
            else: word_str = word_str_p1
            word_blocks.append({"text": word_str, "cx": gx + gw/2, "cy": gy + gh/2, "gx": gx, "gy": gy, "gw": gw, "gh": gh})

            clean_word = re.sub(r'(?i)cm|m$', '', word_str.strip())
            cleaned_str = "".join([{'q':'9','o':'0','O':'0','U':'0','C':'0','i':'1','I':'1','l':'1','L':'1','T':'1','z':'2','Z':'2','s':'5','S':'5','b':'6'}.get(c, c) for c in clean_word if c.isdigit() or c=='.' or c.lower() in 'oq' 'u' 'c' 'i' 'l' 't' 'z' 's' 'b'])
            
            digit_likes = ['o', 'O', 'Q', 'U', 'C', 'i', 'I', 'l', 'L', 'T', 'z', 'Z', 's', 'S', 'b', 'q']
            digit_like_count = sum(1 for c in word_str if c.isdigit() or c == '.' or c.lower() in [dl.lower() for dl in digit_likes])
            if len(word_str) >= 2 and digit_like_count >= 2 and digit_like_count >= len(word_str) - 2:
                try: detected_distances.append({"value": float(cleaned_str), "cx": gx + gw/2, "cy": gy + gh/2, "unit": "cm" if "cm" in word_str.lower() else "m"})
                except ValueError: pass


        def is_distance_label(word_str):
            digit_likes = ['o', 'O', 'Q', 'U', 'C', 'i', 'I', 'l', 'L', 'T', 'z', 'Z', 's', 'S', 'b', 'q']
            digit_like_count = sum(1 for c in word_str if c.isdigit() or c.lower() in [dl.lower() for dl in digit_likes])
            return len(word_str) >= 2 and digit_like_count >= 2 and digit_like_count >= len(word_str) - 2

        # 2. Segment Passable Corridor Mask
        passable = ((img_gray < 130) if is_light_bg else (img_gray > 120)).astype(np.uint8) * 255
        for gx, gy, gw, gh, _ in text_blocks: cv2.rectangle(passable, (gx - 5, gy - 5), (gx + gw + 5, gy + gh + 5), 0, -1)
        passable = cv2.morphologyEx(passable, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (25, 25)))

        # 3. Vectorized Zhang-Suen Skeletonization
        def skeletonize_zhang_suen(binary_img):
            img_bin = (binary_img > 0).astype(np.uint8)
            while True:
                for pass_type in [1, 2]:
                    P2, P3, P4, P5, P6, P7, P8, P9 = [np.roll(np.roll(img_bin, dy, axis=0), dx, axis=1) for dy, dx in [(-1,0),(-1,1),(0,1),(1,1),(1,0),(1,-1),(0,-1),(-1,-1)]]
                    B = P2+P3+P4+P5+P6+P7+P8+P9
                    A = ((P2==0)&(P3==1)).astype(int)+((P3==0)&(P4==1)).astype(int)+((P4==0)&(P5==1)).astype(int)+((P5==0)&(P6==1)).astype(int)+((P6==0)&(P7==1)).astype(int)+((P7==0)&(P8==1)).astype(int)+((P8==0)&(P9==1)).astype(int)+((P9==0)&(P2==1)).astype(int)
                    cond = (B>=2)&(B<=6)&(A==1)&((P2*P4*P6==0) if pass_type==1 else (P2*P4*P8==0))&((P4*P6*P8==0) if pass_type==1 else (P2*P6*P8==0))
                    to_delete = (img_bin==1)&cond
                    if not np.any(to_delete): break
                    img_bin[to_delete] = 0
                else: continue
                break
            return (img_bin * 255).astype(np.uint8)

        pruned_skel = self.prune_skeleton(skeletonize_zhang_suen(passable), max_len=8)
        skel_pts = np.argwhere(pruned_skel > 0)
        
        endpoints = []
        junctions = []
        for y, x in skel_pts:
            if y == 0 or y == h-1 or x == 0 or x == w-1: continue
            neigh = np.count_nonzero(pruned_skel[y-1:y+2, x-1:x+2]) - 1
            if neigh == 1: endpoints.append([int(x), int(y)])
            elif neigh >= 3: junctions.append([int(x), int(y)])

        def cluster_points_grid(pts, cell_size=25.0):
            cells = {}
            for pt in pts:
                cell_key = (int(pt[0]//cell_size), int(pt[1]//cell_size))
                cells.setdefault(cell_key, []).append(pt)
            return [[int(sum(p[0] for p in c)/len(c)), int(sum(p[1] for p in c)/len(c))] for c in cells.values()]

        all_keypoints = []
        for pt in cluster_points_grid(endpoints) + cluster_points_grid(junctions):
            if not any(math.sqrt((pt[0]-kp[0])**2 + (pt[1]-kp[1])**2) < 55.0 for kp in all_keypoints):
                best_idx = np.argmin([math.sqrt((pt[0]-x)**2 + (pt[1]-y)**2) for y, x in skel_pts])
                best_pt = skel_pts[best_idx]
                all_keypoints.append([int(best_pt[1]), int(best_pt[0])])

        # 6. Trace paths & 7. Curve Corner Detection
        raw_conns = self.trace_skeleton_paths(pruned_skel, all_keypoints)

        
        final_checkpoints = list(all_keypoints)
        path_corner_sequences = []
        
        for c in raw_conns:
            pixel_path = c["pixel_path"]
            simplified = self.ramer_douglas_peucker(pixel_path, epsilon=20.0)
            seq_indices = []
            for pt in simplified:
                found_idx = -1
                for idx, cp in enumerate(final_checkpoints):
                    if math.sqrt((pt[0]-cp[0])**2 + (pt[1]-cp[1])**2) < 35.0:
                        found_idx = idx
                        break
                if found_idx == -1:
                    final_checkpoints.append(pt)
                    seq_indices.append(len(final_checkpoints) - 1)
                else:
                    seq_indices.append(found_idx)
            path_corner_sequences.append((seq_indices, pixel_path))



        # Filter out word_blocks that are close to checkpoints to avoid matching circular checkpoint dots as letter 'O'
        filtered_words = []
        for w_item in word_blocks:
            if any(math.sqrt((kp[0]-w_item["cx"])**2 + (kp[1]-w_item["cy"])**2) < 25.0 for kp in final_checkpoints):
                continue
            filtered_words.append(w_item)

        checkpoints, checkpoint_names = {}, {}
        for idx, pt in enumerate(final_checkpoints):
            best_word = min([w for w in filtered_words if not is_distance_label(w["text"])], key=lambda w: math.sqrt((pt[0]-w["cx"])**2 + (pt[1]-w["cy"])**2), default=None)
            final_label = re.sub(r'[^A-Z0-9 ]', '', best_word["text"].upper()) if best_word and math.sqrt((pt[0]-best_word["cx"])**2 + (pt[1]-best_word["cy"])**2) < 80.0 else f"CHECKPOINT {idx + 1}"
            count = 1
            name = final_label
            while name in checkpoints: name = f"{final_label} {count}"; count += 1
            checkpoints[name] = {"x": pt[0], "y": pt[1]}; checkpoint_names[idx] = name

        connections, mapped_ratios = [], []
        for seq, full_path in path_corner_sequences:
            for k in range(len(seq)-1):
                i1, i2 = seq[k], seq[k+1]
                p1, p2 = final_checkpoints[i1], final_checkpoints[i2]
                
                i1_idx = min(range(len(full_path)), key=lambda i: (full_path[i][0]-p1[0])**2 + (full_path[i][1]-p1[1])**2)
                i2_idx = min(range(len(full_path)), key=lambda i: (full_path[i][0]-p2[0])**2 + (full_path[i][1]-p2[1])**2)
                
                if i1_idx <= i2_idx:
                    sub = full_path[i1_idx:i2_idx+1]
                else:
                    sub = full_path[i2_idx:i1_idx+1]
                    sub = sub[::-1]
                
                if len(sub) < 2:
                    sub = [p1, p2]
                    
                c_type, cp, rad, length, head, curv = self.fit_curve_to_path(sub)
                connections.append({"from": checkpoint_names[i1], "to": checkpoint_names[i2], "pixel_distance": length, "distance": length, "pixel_path": sub, "connection_type": c_type, "control_points": cp, "radius": rad, "length": length, "heading": head, "curvature": curv})


        for d in detected_distances:
            best_idx = min(range(len(connections)), key=lambda i: self.p_dist_to_segment(d["cx"], d["cy"], checkpoints[connections[i]["from"]]["x"], checkpoints[connections[i]["from"]]["y"], checkpoints[connections[i]["to"]]["x"], checkpoints[connections[i]["to"]]["y"]), default=-1)
            if best_idx != -1 and self.p_dist_to_segment(d["cx"], d["cy"], checkpoints[connections[best_idx]["from"]]["x"], checkpoints[connections[best_idx]["from"]]["y"], checkpoints[connections[best_idx]["to"]]["x"], checkpoints[connections[best_idx]["to"]]["y"]) < 200.0:
                connections[best_idx]["distance"] = d["value"]; mapped_ratios.append(connections[best_idx]["pixel_distance"]/d["value"])

        return {
            "checkpoints": {n: {"x": p["x"], "y": p["y"], "name": n, "iconType": "general", "color": "#00FFCC"} for n, p in checkpoints.items()},
            "connections": connections,
            "unit": max(set([d["unit"] for d in detected_distances]), key=[d["unit"] for d in detected_distances].count) if detected_distances else ("cm" if np.mean([d["value"] for d in detected_distances] or [0]) > 25 else "m")
        }

