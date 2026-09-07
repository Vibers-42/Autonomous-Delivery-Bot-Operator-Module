import asyncio
import httpx
import json

async def test_planning():
    print("Testing stable timer-based navigation and Gemini route insights...")
    
    # 1. Start backend client
    async with httpx.AsyncClient(base_url="http://127.0.0.1:8000", timeout=30.0) as client:
        # Load factory_layout_1 map
        with open("uploads/maps/factory_layout_1.json", "r") as f:
            map_data = json.load(f)
            
        print("Selecting map 'Factory Layout 1'...")
        resp = await client.post("/api/select-map", json=map_data)
        print("Select Map response status:", resp.status_code)
        assert resp.status_code == 200, f"Map selection failed: {resp.text}"
        print("Map selected successfully.")
        
        # Plan path from A to E (intermediate checkpoints B, C, D)
        print("Planning path from A to E...")
        plan_req = {
            "start": "A",
            "end": "E",
            "intermediates": ["B", "C"]
        }
        resp = await client.post("/api/plan-path", json=plan_req)
        print("Plan Path response status:", resp.status_code)
        assert resp.status_code == 200, f"Path planning failed: {resp.text}"
        
        data = resp.json()
        print("\n--- Route Planning Results ---")
        print("Status:", data.get("status"))
        print("Calculated Path (Dijkstra):", data.get("path"))
        print("Total Distance:", data.get("distance"), "meters")
        print("Estimated Time (Gemini):", data.get("estimated_time"), "seconds")
        print("Turns Count:", data.get("turns_count"))
        print("\n--- Route Insights ---")
        print(data.get("route_insights"))
        print("\n--- Delivery Intelligence & Safety ---")
        print(data.get("delivery_intelligence"))

if __name__ == "__main__":
    asyncio.run(test_planning())
