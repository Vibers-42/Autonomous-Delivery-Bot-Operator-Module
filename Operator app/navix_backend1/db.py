"""
db.py — MySQL Database Helper
Provides a thread-safe connection factory for the Navix resident/delivery DB.
Uses PyMySQL — install with: pip install pymysql cryptography

IMPORTANT: PyMySQL uses %s as the query placeholder (not ? like SQLite).
All query strings in resident_routes.py already use %s — no changes needed there.
"""
import pymysql
import pymysql.cursors
from contextlib import contextmanager

# ── Connection config ─────────────────────────────────────────────────────────
MYSQL_HOST     = "localhost"
MYSQL_PORT     = 3306
MYSQL_USER     = "root"
MYSQL_PASSWORD = "root"
MYSQL_DB       = "navix_db"


def get_connection() -> pymysql.connections.Connection:
    """Return a new PyMySQL connection with DictCursor as default cursor."""
    return pymysql.connect(
        host=MYSQL_HOST,
        port=MYSQL_PORT,
        user=MYSQL_USER,
        password=MYSQL_PASSWORD,
        database=MYSQL_DB,
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=False,
    )


@contextmanager
def db_cursor():
    """
    Context manager that yields a cursor and auto-commits or rolls back.
    Drop-in replacement for the previous SQLite db_cursor().
    NOTE: Row data is returned as dicts (DictCursor), so dict-style access
    works the same as sqlite3.Row object access.
    """
    conn = get_connection()
    try:
        cursor = conn.cursor()
        yield cursor
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def init_db():
    """
    Create all tables if they do not already exist.
    Called from main.py on startup — safe to call multiple times.
    """
    from db_models import MYSQL_CREATE_TABLES_SQL
    conn = get_connection()
    try:
        cursor = conn.cursor()
        for statement in MYSQL_CREATE_TABLES_SQL:
            cursor.execute(statement)
        conn.commit()
        print(f"[DB] MySQL database '{MYSQL_DB}' initialised at {MYSQL_HOST}:{MYSQL_PORT}")
    finally:
        conn.close()
