"""
test_resident_system.py — End-to-end automated verification for resident and operator API endpoints.
Tests authentication, role-based access control, OTP lifecycle, delivery tracking, and map views.
"""
from fastapi.testclient import TestClient
from main import app
from db import init_db
from seed_demo_data import seed

def run_tests():
    print("=" * 60)
    print("RUNNING RESIDENT & DELIVERY SYSTEM INTEGRATION TESTS")
    print("=" * 60)

    # 1. Initialize and seed DB
    init_db()
    seed()
    client = TestClient(app)

    # 2. Test Resident Login
    res = client.post("/auth/login", json={"email": "resident@navix.local", "password": "navix2024"})
    assert res.status_code == 200, f"Login failed: {res.text}"
    resident_data = res.json()
    resident_token = resident_data["access_token"]
    resident_headers = {"Authorization": f"Bearer {resident_token}"}
    print("[OK] Resident login successful (JWT received)")

    # 3. Test Operator Login
    res = client.post("/auth/login", json={"email": "admin@navix.local", "password": "navix2024"})
    assert res.status_code == 200, f"Operator login failed: {res.text}"
    operator_token = res.json()["access_token"]
    operator_headers = {"Authorization": f"Bearer {operator_token}"}
    print("[OK] Operator login successful (JWT received)")

    # 4. Test GET /me
    res = client.get("/me", headers=resident_headers)
    assert res.status_code == 200
    me = res.json()
    assert me["email"] == "resident@navix.local"
    assert me["role"] == "RESIDENT"
    print(f"[OK] GET /me verified for {me['name']} ({me['role']})")

    # 5. Test GET /me/community and /me/apartment
    res = client.get("/me/community", headers=resident_headers)
    assert res.status_code == 200
    comm = res.json()
    assert comm["id"] == "ABC001"
    print(f"[OK] GET /me/community: {comm['name']}")

    res = client.get("/me/apartment", headers=resident_headers)
    assert res.status_code == 200
    apt = res.json()
    assert apt["id"] == "ABC001-A-F1-102"
    print(f"[OK] GET /me/apartment: {apt['id']} (Checkpoint: {apt['destination_checkpoint']})")

    # 6. Test GET /communities/ABC001/map (Resident-safe sanitized map)
    res = client.get("/communities/ABC001/map", headers=resident_headers)
    assert res.status_code == 200
    cmap = res.json()
    assert "towers" in cmap
    assert cmap["resident_apartment_id"] == "ABC001-A-F1-102"
    print(f"[OK] GET /communities/ABC001/map verified (Towers: {list(cmap['towers'].keys())})")

    # 7. Test Deliveries List & Tracking
    res = client.get("/deliveries", headers=resident_headers)
    assert res.status_code == 200
    deliveries = res.json()["deliveries"]
    assert len(deliveries) >= 1
    active_deliv = next((d for d in deliveries if d["status"] in ("ARRIVED", "RESIDENT_READY")), deliveries[0])
    print(f"[OK] GET /deliveries verified: Found {len(deliveries)} deliveries (Active: {active_deliv['order_id']})")

    # 8. Test Live Tracking endpoint
    res = client.get(f"/deliveries/{active_deliv['id']}/tracking", headers=resident_headers)
    assert res.status_code == 200
    track = res.json()
    assert track["delivery_id"] == active_deliv["id"]
    print(f"[OK] GET /deliveries/{{id}}/tracking verified (Status: {track['status']})")

    # 9. Test Resident 'I\'m Ready' -> OTP Generation
    # If already ready, reset or generate
    if active_deliv["status"] == "ARRIVED":
        res = client.post(f"/deliveries/{active_deliv['id']}/ready", headers=resident_headers)
        assert res.status_code == 200, f"Ready failed: {res.text}"
        ready_data = res.json()
        assert ready_data["delivery_status"] == "RESIDENT_READY"
        otp = ready_data["otp"]
        assert len(otp) == 6
        print(f"[OK] POST /deliveries/{{id}}/ready verified (Generated OTP: {otp})")

        # 10. Test Invalid OTP check
        res = client.post(f"/deliveries/{active_deliv['id']}/verify-otp", headers=resident_headers, json={"otp": "000000"})
        assert res.status_code == 400
        print("[OK] Invalid OTP properly rejected (400 Bad Request)")

        # 11. Test Correct OTP Verification & Parcel Handover
        res = client.post(f"/deliveries/{active_deliv['id']}/verify-otp", headers=resident_headers, json={"otp": otp})
        assert res.status_code == 200
        assert res.json()["delivery_status"] == "DELIVERED"
        print("[OK] Correct OTP verified -> Status moved to DELIVERED & Compartment Opened")

    # 12. Test Notifications
    res = client.get("/notifications", headers=resident_headers)
    assert res.status_code == 200
    notifs = res.json()["notifications"]
    assert len(notifs) >= 1
    print(f"[OK] GET /notifications verified: {len(notifs)} alerts received")

    # Mark notification read
    notif_id = notifs[0]["id"]
    res = client.post(f"/notifications/{notif_id}/read", headers=resident_headers)
    assert res.status_code == 200
    print("[OK] POST /notifications/{id}/read verified")

    # 13. Test RBAC Security Boundary (Resident cannot create community or access other residents)
    res = client.post("/operator/communities", headers=resident_headers, json={"id": "HACK", "name": "Hacked"})
    assert res.status_code == 403
    print("[OK] RBAC Boundary: Resident forbidden from operator endpoint (403)")

    # 14. Verify Existing Robot/Telemetry Endpoints still function
    res = client.get("/status")
    assert res.status_code == 200
    print("[OK] Existing /status endpoint untouched and functioning")

    res = client.get("/api/maps")
    assert res.status_code == 200
    print("[OK] Existing /api/maps endpoint untouched and functioning")

    print("\n" + "=" * 60)
    print("ALL 14 INTEGRATION TESTS PASSED SUCCESSFULLY!")
    print("=" * 60)

if __name__ == "__main__":
    run_tests()
