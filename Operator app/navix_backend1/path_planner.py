import heapq

class PathPlanner:
    def __init__(self, checkpoints, connections):
        """
        checkpoints: dict like {"A": {"x": 100, "y": 100}, ...}
        connections: list of dicts like [{"from": "A", "to": "B", "distance": 300.0}, ...]
        """
        self.checkpoints = checkpoints
        self.connections = connections
        self.graph = self._build_adjacency_list()

    def _build_adjacency_list(self):
        graph = {node: {} for node in self.checkpoints}
        for conn in self.connections:
            u, v, dist = conn["from"], conn["to"], conn["distance"]
            graph[u][v] = dist
            graph[v][u] = dist  # Bidirectional path
        return graph

    def find_shortest_path(self, start, end):
        """Finds the shortest path from start to end using Dijkstra's algorithm."""
        if start not in self.graph or end not in self.graph:
            return None

        # Min-priority queue: (distance, current_node, path)
        queue = [(0, start, [start])]
        visited = set()

        while queue:
            (cost, current, path) = heapq.heappop(queue)

            if current in visited:
                continue

            visited.add(current)

            if current == end:
                # Build coordinates list for animation
                # Reconstruct detailed coordinates list using connection paths
                coordinates = []
                for i in range(len(path) - 1):
                    u = path[i]
                    v = path[i+1]
                    # Find connection
                    conn_path = None
                    for conn in self.connections:
                        if conn["from"] == u and conn["to"] == v:
                            conn_path = list(conn["path"])
                            break
                        elif conn["from"] == v and conn["to"] == u:
                            conn_path = list(reversed(conn["path"]))
                            break
                    if conn_path:
                        if i > 0 and coordinates:
                            coordinates.extend(conn_path[1:])
                        else:
                            coordinates.extend(conn_path)
                    else:
                        p1 = self.checkpoints[u]
                        p2 = self.checkpoints[v]
                        if i > 0 and coordinates:
                            coordinates.append([p2["x"], p2["y"]])
                        else:
                            coordinates.extend([[p1["x"], p1["y"]], [p2["x"], p2["y"]]])
                
                # Estimated time is calculated based on travel speed (0.30 m/s)
                est_time = round(cost / 0.30, 1)
                
                return {
                    "path": path,
                    "coordinates": coordinates,
                    "distance": round(cost, 1),
                    "estimated_time": est_time
                }

            for neighbor, weight in self.graph[current].items():
                if neighbor not in visited:
                    heapq.heappush(queue, (cost + weight, neighbor, path + [neighbor]))

        return None

if __name__ == "__main__":
    # Test pathfinding
    checkpoints = {
        "A": {"x": 100, "y": 100},
        "B": {"x": 400, "y": 100},
        "C": {"x": 400, "y": 350},
        "D": {"x": 100, "y": 350},
        "E": {"x": 700, "y": 350},
        "F": {"x": 700, "y": 500}
    }
    connections = [
        {"from": "A", "to": "B", "distance": 300.0},
        {"from": "B", "to": "C", "distance": 250.0},
        {"from": "C", "to": "D", "distance": 300.0},
        {"from": "D", "to": "A", "distance": 250.0},
        {"from": "C", "to": "E", "distance": 300.0},
        {"from": "E", "to": "F", "distance": 150.0}
    ]

    planner = PathPlanner(checkpoints, connections)
    shortest = planner.find_shortest_path("A", "F")
    print("Shortest path from A to F:")
    print(shortest)
