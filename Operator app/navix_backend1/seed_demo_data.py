"""
seed_demo_data.py — Seed script to populate sample communities, apartments, residents, and an active delivery.
Run this script to initialize rich demo data for testing both backend and Android app.
"""
import uuid
from datetime import datetime, timezone
from db import init_db, db_cursor
from auth import hash_password

def seed():
    init_db()
    now = datetime.now(timezone.utc).isoformat()
    
    with db_cursor() as cur:
        # 1. Community
        comm_id = "ABC001"
        cur.execute("SELECT id FROM communities WHERE id = %s", (comm_id,))
        if not cur.fetchone():
            cur.execute(
                "INSERT INTO communities (id, name, address, created_at) VALUES (%s, %s, %s, %s)",
                (comm_id, "Palm Heights Smart Residency", "100 Grand Bay Boulevard", now)
            )
            print(f"[Seed] Community created: {comm_id}")
        
        # 2. Apartments
        apts = [
            ("ABC001-A-F1-101", comm_id, "A", "F1", "101", "Checkpoint_1"),
            ("ABC001-A-F1-102", comm_id, "A", "F1", "102", "Checkpoint_2"),
            ("ABC001-A-F1-103", comm_id, "A", "F1", "103", "Checkpoint_3"),
            ("ABC001-A-F2-201", comm_id, "A", "F2", "201", "Checkpoint_4"),
            ("ABC001-A-F2-202", comm_id, "A", "F2", "202", "Checkpoint_5"),
            ("ABC001-B-F1-101", comm_id, "B", "F1", "101", "Checkpoint_6"),
            ("ABC001-B-F1-102", comm_id, "B", "F1", "102", "Checkpoint_7"),
        ]
        for aid, cid, tid, fid, num, cp in apts:
            cur.execute("SELECT id FROM apartments WHERE id = %s", (aid,))
            if not cur.fetchone():
                cur.execute(
                    """INSERT INTO apartments 
                       (id, community_id, tower_id, floor_id, apartment_number, destination_checkpoint)
                       VALUES (%s, %s, %s, %s, %s, %s)""",
                    (aid, cid, tid, fid, num, cp)
                )
        print(f"[Seed] {len(apts)} apartments verified/created.")

        # 3. Users (Operator + Residents)
        # Operator
        cur.execute("SELECT id FROM users WHERE email = %s", ("admin@navix.local",))
        if not cur.fetchone():
            cur.execute(
                """INSERT INTO users 
                   (id, name, email, phone, password_hash, role, community_id, tower_id, floor_id, apartment_id, created_at, updated_at)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                (str(uuid.uuid4()), "Navix Admin", "admin@navix.local", "+1000000000",
                 hash_password("navix2024"), "OPERATOR", None, None, None, None, now, now)
            )
            print("[Seed] Operator created: admin@navix.local")

        # Resident 1 (Alex Morgan)
        cur.execute("SELECT id FROM users WHERE email = %s", ("resident@navix.local",))
        alex = cur.fetchone()
        if not alex:
            alex_id = str(uuid.uuid4())
            cur.execute(
                """INSERT INTO users 
                   (id, name, email, phone, password_hash, role, community_id, tower_id, floor_id, apartment_id, created_at, updated_at)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                (alex_id, "Alex Morgan", "resident@navix.local", "+1 555-0199",
                 hash_password("navix2024"), "RESIDENT", comm_id, "A", "F1", "ABC001-A-F1-102", now, now)
            )
            print(f"[Seed] Resident created: resident@navix.local (Password: navix2024)")
        else:
            alex_id = alex["id"]

        # Resident 2 (Sarah Connor)
        cur.execute("SELECT id FROM users WHERE email = %s", ("sarah@navix.local",))
        if not cur.fetchone():
            sarah_id = str(uuid.uuid4())
            cur.execute(
                """INSERT INTO users 
                   (id, name, email, phone, password_hash, role, community_id, tower_id, floor_id, apartment_id, created_at, updated_at)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                (sarah_id, "Sarah Connor", "sarah@navix.local", "+1 555-0200",
                 hash_password("navix2024"), "RESIDENT", comm_id, "A", "F2", "ABC001-A-F2-201", now, now)
            )
            print(f"[Seed] Resident created: sarah@navix.local (Password: navix2024)")

        # 4. Sample Deliveries for Alex Morgan
        cur.execute("SELECT id FROM deliveries WHERE order_id = %s", ("ORD-7821",))
        if not cur.fetchone():
            deliv_id = str(uuid.uuid4())
            order_id = "ORD-7821"
            cur.execute(
                """INSERT INTO deliveries
                   (id, order_id, resident_id, community_id, apartment_id, destination_checkpoint,
                    status, estimated_eta_seconds, notes, created_at, updated_at)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                (deliv_id, order_id, alex_id, comm_id, "ABC001-A-F1-102", "Checkpoint_2",
                 "ARRIVED", 0, "Package from Amazon - Express Delivery", now, now)
            )
            # Notification for this delivery
            cur.execute(
                """INSERT INTO notifications (id, user_id, delivery_id, type, title, body, created_at)
                   VALUES (%s, %s, %s, %s, %s, %s, %s)""",
                (str(uuid.uuid4()), alex_id, deliv_id, "ARRIVED",
                 "Robot Has Arrived! 🎉",
                 "Your autonomous delivery robot is waiting outside your apartment. Tap 'I\'m Ready' to receive your parcel.",
                 now)
            )
            print(f"[Seed] Active sample delivery created: {order_id} (Status: ARRIVED)")

        # Past completed delivery
        cur.execute("SELECT id FROM deliveries WHERE order_id = %s", ("ORD-4190",))
        if not cur.fetchone():
            deliv_id_past = str(uuid.uuid4())
            order_id_past = "ORD-4190"
            cur.execute(
                """INSERT INTO deliveries
                   (id, order_id, resident_id, community_id, apartment_id, destination_checkpoint,
                    status, estimated_eta_seconds, notes, created_at, updated_at)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                (deliv_id_past, order_id_past, alex_id, comm_id, "ABC001-A-F1-102", "Checkpoint_2",
                 "DELIVERED", None, "Grocery Delivery - Organic Basket", now, now)
            )
            print(f"[Seed] Past sample delivery created: {order_id_past} (Status: DELIVERED)")

    print("[Seed] Seeding completed successfully!")

if __name__ == "__main__":
    seed()
