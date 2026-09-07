"""
db_models.py — Database Schema Definitions
MySQL table definitions used by the Navix resident/delivery system.
QUERY PLACEHOLDER: use %s  (PyMySQL standard — NOT ? like SQLite)
"""

# ── MySQL Schema (used by init_db in db.py) ────────────────────────────────────
MYSQL_CREATE_TABLES_SQL = [
    """CREATE TABLE IF NOT EXISTS `communities` (
        `id`         VARCHAR(36)  NOT NULL PRIMARY KEY,
        `name`       VARCHAR(255) NOT NULL,
        `address`    TEXT,
        `created_at` VARCHAR(64)  NOT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4""",

    """CREATE TABLE IF NOT EXISTS `apartments` (
        `id`                     VARCHAR(100) NOT NULL PRIMARY KEY,
        `community_id`           VARCHAR(36)  NOT NULL,
        `tower_id`               VARCHAR(50)  NOT NULL,
        `floor_id`               VARCHAR(50)  NOT NULL,
        `apartment_number`       VARCHAR(50)  NOT NULL,
        `destination_checkpoint` VARCHAR(100),
        FOREIGN KEY (`community_id`) REFERENCES `communities`(`id`) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4""",

    """CREATE TABLE IF NOT EXISTS `users` (
        `id`            VARCHAR(36)  NOT NULL PRIMARY KEY,
        `name`          VARCHAR(255) NOT NULL,
        `email`         VARCHAR(255) NOT NULL UNIQUE,
        `phone`         VARCHAR(30),
        `password_hash` VARCHAR(255) NOT NULL,
        `role`          VARCHAR(30)  NOT NULL DEFAULT 'RESIDENT',
        `community_id`  VARCHAR(36),
        `tower_id`      VARCHAR(50),
        `floor_id`      VARCHAR(50),
        `apartment_id`  VARCHAR(100),
        `created_at`    VARCHAR(64)  NOT NULL,
        `updated_at`    VARCHAR(64)  NOT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4""",

    """CREATE TABLE IF NOT EXISTS `deliveries` (
        `id`                     VARCHAR(36)  NOT NULL PRIMARY KEY,
        `order_id`               VARCHAR(36)  NOT NULL UNIQUE,
        `resident_id`            VARCHAR(36)  NOT NULL,
        `community_id`           VARCHAR(36)  NOT NULL,
        `apartment_id`           VARCHAR(100) NOT NULL,
        `destination_checkpoint` VARCHAR(100),
        `status`                 VARCHAR(50)  NOT NULL DEFAULT 'ORDER_CREATED',
        `robot_id`               VARCHAR(100),
        `mission_id`             VARCHAR(100),
        `otp`                    VARCHAR(20),
        `otp_expires_at`         VARCHAR(64),
        `estimated_eta_seconds`  INT,
        `notes`                  TEXT,
        `created_at`             VARCHAR(64)  NOT NULL,
        `updated_at`             VARCHAR(64)  NOT NULL,
        FOREIGN KEY (`resident_id`)  REFERENCES `users`(`id`) ON DELETE RESTRICT,
        FOREIGN KEY (`community_id`) REFERENCES `communities`(`id`) ON DELETE RESTRICT,
        FOREIGN KEY (`apartment_id`) REFERENCES `apartments`(`id`) ON DELETE RESTRICT
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4""",

    """CREATE TABLE IF NOT EXISTS `notifications` (
        `id`          VARCHAR(36)  NOT NULL PRIMARY KEY,
        `user_id`     VARCHAR(36)  NOT NULL,
        `delivery_id` VARCHAR(36),
        `type`        VARCHAR(50)  NOT NULL,
        `title`       VARCHAR(255) NOT NULL,
        `body`        TEXT         NOT NULL,
        `read`        TINYINT(1)   NOT NULL DEFAULT 0,
        `created_at`  VARCHAR(64)  NOT NULL,
        FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4""",

    """CREATE TABLE IF NOT EXISTS `audit_log` (
        `id`         VARCHAR(36)  NOT NULL PRIMARY KEY,
        `user_id`    VARCHAR(36),
        `action`     VARCHAR(100) NOT NULL,
        `resource`   VARCHAR(255),
        `detail`     TEXT,
        `ip_address` VARCHAR(50),
        `created_at` VARCHAR(64)  NOT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4""",
]

# ── Legacy SQLite schema (kept for reference only) ─────────────────────────────
CREATE_TABLES_SQL = [
    # ── Users ───────────────────────────────────────────────────────────────────
    """
    CREATE TABLE IF NOT EXISTS users (
        id              TEXT PRIMARY KEY,
        name            TEXT NOT NULL,
        email           TEXT UNIQUE NOT NULL,
        phone           TEXT,
        password_hash   TEXT NOT NULL,
        role            TEXT NOT NULL DEFAULT 'RESIDENT',
        community_id    TEXT,
        tower_id        TEXT,
        floor_id        TEXT,
        apartment_id    TEXT,
        created_at      TEXT NOT NULL,
        updated_at      TEXT NOT NULL
    )
    """,

    # ── Communities ─────────────────────────────────────────────────────────────
    """
    CREATE TABLE IF NOT EXISTS communities (
        id          TEXT PRIMARY KEY,
        name        TEXT NOT NULL,
        address     TEXT,
        created_at  TEXT NOT NULL
    )
    """,

    # ── Apartments ──────────────────────────────────────────────────────────────
    # Destination ID format: COMMUNITY_ID-TOWER-FLOOR-APT  e.g. ABC001-A-F1-102
    """
    CREATE TABLE IF NOT EXISTS apartments (
        id                      TEXT PRIMARY KEY,
        community_id            TEXT NOT NULL,
        tower_id                TEXT NOT NULL,
        floor_id                TEXT NOT NULL,
        apartment_number        TEXT NOT NULL,
        destination_checkpoint  TEXT,
        FOREIGN KEY (community_id) REFERENCES communities(id)
    )
    """,

    # ── Deliveries ──────────────────────────────────────────────────────────────
    """
    CREATE TABLE IF NOT EXISTS deliveries (
        id                      TEXT PRIMARY KEY,
        order_id                TEXT UNIQUE NOT NULL,
        resident_id             TEXT NOT NULL,
        community_id            TEXT NOT NULL,
        apartment_id            TEXT NOT NULL,
        destination_checkpoint  TEXT,
        status                  TEXT NOT NULL DEFAULT 'ORDER_CREATED',
        robot_id                TEXT,
        mission_id              TEXT,
        otp                     TEXT,
        otp_expires_at          TEXT,
        estimated_eta_seconds   INTEGER,
        notes                   TEXT,
        created_at              TEXT NOT NULL,
        updated_at              TEXT NOT NULL,
        FOREIGN KEY (resident_id)   REFERENCES users(id),
        FOREIGN KEY (community_id)  REFERENCES communities(id),
        FOREIGN KEY (apartment_id)  REFERENCES apartments(id)
    )
    """,

    # ── Notifications ───────────────────────────────────────────────────────────
    """
    CREATE TABLE IF NOT EXISTS notifications (
        id          TEXT PRIMARY KEY,
        user_id     TEXT NOT NULL,
        delivery_id TEXT,
        type        TEXT NOT NULL,
        title       TEXT NOT NULL,
        body        TEXT NOT NULL,
        read        INTEGER NOT NULL DEFAULT 0,
        created_at  TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id)
    )
    """,

    # ── Audit Log ───────────────────────────────────────────────────────────────
    """
    CREATE TABLE IF NOT EXISTS audit_log (
        id          TEXT PRIMARY KEY,
        user_id     TEXT,
        action      TEXT NOT NULL,
        resource    TEXT,
        detail      TEXT,
        ip_address  TEXT,
        created_at  TEXT NOT NULL
    )
    """,
]

# ── Delivery Status Enum ─────────────────────────────────────────────────────────
DELIVERY_STATUSES = [
    "ORDER_CREATED",
    "PARCEL_RECEIVED",
    "PARCEL_VERIFIED",
    "MISSION_CREATED",
    "ROBOT_ASSIGNED",
    "ROBOT_STARTED",
    "EN_ROUTE",
    "ARRIVED_AT_BUILDING",
    "ELEVATOR_TRANSIT",
    "ARRIVED_AT_FLOOR",
    "APPROACHING_APARTMENT",
    "ARRIVED",
    "RESIDENT_NOTIFIED",
    "RESIDENT_READY",
    "OTP_VERIFIED",
    "DELIVERED",
    "RETURNING",
    "COMPLETED",
    "FAILED",
    "CANCELLED",
]

# Human-readable labels for each delivery status
DELIVERY_STATUS_LABELS = {
    "ORDER_CREATED":          "Order Created",
    "PARCEL_RECEIVED":        "Parcel Received at Warehouse",
    "PARCEL_VERIFIED":        "Parcel Verified",
    "MISSION_CREATED":        "Mission Created",
    "ROBOT_ASSIGNED":         "Robot Assigned",
    "ROBOT_STARTED":          "Robot Started",
    "EN_ROUTE":               "On the Way",
    "ARRIVED_AT_BUILDING":    "Arrived at Building",
    "ELEVATOR_TRANSIT":       "In Elevator",
    "ARRIVED_AT_FLOOR":       "Arrived at Your Floor",
    "APPROACHING_APARTMENT":  "Approaching Your Apartment",
    "ARRIVED":                "Robot Has Arrived!",
    "RESIDENT_NOTIFIED":      "You Have Been Notified",
    "RESIDENT_READY":         "You Are Ready — Verifying",
    "OTP_VERIFIED":           "OTP Verified",
    "DELIVERED":              "Delivered Successfully",
    "RETURNING":              "Robot Returning to Base",
    "COMPLETED":              "Delivery Complete",
    "FAILED":                 "Delivery Failed",
    "CANCELLED":              "Delivery Cancelled",
}

# User roles
ROLES = ["RESIDENT", "OPERATOR", "COMMUNITY_SECURITY"]
