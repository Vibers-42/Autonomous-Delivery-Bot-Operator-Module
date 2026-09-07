"""
migrate_to_mysql.py — Run ONCE to set up MySQL and migrate SQLite data.
Usage:  python migrate_to_mysql.py
"""
import pymysql
import sqlite3
import os, sys

MYSQL_HOST     = "localhost"
MYSQL_PORT     = 3306
MYSQL_USER     = "root"
MYSQL_PASSWORD = "root"
MYSQL_DB       = "navix_db"
SQLITE_PATH    = os.path.join(os.path.dirname(__file__), "navix_resident.db")

MYSQL_TABLES = [
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
        `read_flag`   TINYINT(1)   NOT NULL DEFAULT 0,
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

def create_db_and_tables():
    print(f"[1/3] Connecting to MySQL {MYSQL_HOST}:{MYSQL_PORT} as {MYSQL_USER} ...")
    conn = pymysql.connect(host=MYSQL_HOST, port=MYSQL_PORT,
                           user=MYSQL_USER, password=MYSQL_PASSWORD, charset="utf8mb4")
    cur = conn.cursor()
    cur.execute(f"CREATE DATABASE IF NOT EXISTS `{MYSQL_DB}` "
                f"CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
    conn.select_db(MYSQL_DB)
    print(f"      Database '{MYSQL_DB}' ready.")
    print("[2/3] Creating tables ...")
    for sql in MYSQL_TABLES:
        cur.execute(sql)
    conn.commit()
    conn.close()
    print("      Tables created: communities, apartments, users, deliveries, notifications, audit_log")

def migrate_sqlite():
    if not os.path.exists(SQLITE_PATH):
        print("[3/3] No SQLite file found — skipping data migration.")
        return
    print(f"[3/3] Migrating data from: {SQLITE_PATH}")
    sc = sqlite3.connect(SQLITE_PATH)
    sc.row_factory = sqlite3.Row
    mc = pymysql.connect(host=MYSQL_HOST, port=MYSQL_PORT,
                         user=MYSQL_USER, password=MYSQL_PASSWORD,
                         database=MYSQL_DB, charset="utf8mb4", autocommit=False)
    mc_cur = mc.cursor()

    # FK-safe migration order
    plan = [
        ("communities", "id,name,address,created_at"),
        ("apartments",  "id,community_id,tower_id,floor_id,apartment_number,destination_checkpoint"),
        ("users",       "id,name,email,phone,password_hash,role,community_id,tower_id,floor_id,apartment_id,created_at,updated_at"),
        ("deliveries",  "id,order_id,resident_id,community_id,apartment_id,destination_checkpoint,status,robot_id,mission_id,otp,otp_expires_at,estimated_eta_seconds,notes,created_at,updated_at"),
        ("audit_log",   "id,user_id,action,resource,detail,ip_address,created_at"),
    ]

    total = 0
    for table, cols_str in plan:
        check = sc.execute(f"SELECT name FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone()
        if not check:
            print(f"      [skip] '{table}' not in SQLite")
            continue
        rows = sc.execute(f"SELECT {cols_str} FROM {table}").fetchall()
        if not rows:
            print(f"      [empty] {table}: 0 rows")
            continue
        cols  = [c.strip() for c in cols_str.split(",")]
        ph    = ",".join(["%s"] * len(cols))
        bcols = ",".join([f"`{c}`" for c in cols])
        mc_cur.executemany(f"INSERT IGNORE INTO `{table}` ({bcols}) VALUES ({ph})", [tuple(r) for r in rows])
        print(f"      {table}: {len(rows)} rows migrated")
        total += len(rows)

    # Notifications — handle column rename read -> read_flag
    ncheck = sc.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='notifications'").fetchone()
    if ncheck:
        nrows = sc.execute("SELECT id,user_id,delivery_id,type,title,body,created_at FROM notifications").fetchall()
        if nrows:
            mc_cur.executemany(
                "INSERT IGNORE INTO `notifications` "
                "(id,user_id,delivery_id,type,title,body,read_flag,created_at) VALUES (%s,%s,%s,%s,%s,%s,0,%s)",
                [tuple(r) for r in nrows])
            print(f"      notifications: {len(nrows)} rows migrated")
            total += len(nrows)

    mc.commit()
    mc.close()
    sc.close()
    print(f"      Total rows migrated: {total}")

if __name__ == "__main__":
    try:
        create_db_and_tables()
        migrate_sqlite()
        print(f"\n✅  MySQL database '{MYSQL_DB}' is ready on {MYSQL_HOST}:{MYSQL_PORT}")
    except pymysql.Error as e:
        print(f"\n❌  MySQL Error [{e.args[0]}]: {e.args[1]}")
        sys.exit(1)
