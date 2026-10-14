#!/usr/bin/env python3
"""Private clipboard API. Python standard library only (3.6+)."""
import hmac
import json
import os
import re
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

LIMIT = 50
MAX_IMAGE = 20 * 1024 * 1024
MAX_TEXT = 1024 * 1024
TOKEN = os.environ['CLIPBOARD_TOKEN']
if len(TOKEN) < 32:
    raise RuntimeError('CLIPBOARD_TOKEN must contain at least 32 characters')
RETENTION_DAYS = int(os.environ.get('CLIPBOARD_RETENTION_DAYS', '0'))
DB_PATH = os.environ.get('CLIPBOARD_DB', '/var/lib/mino-clipboard/clipboard.sqlite3')
os.makedirs(os.path.dirname(os.path.abspath(DB_PATH)), exist_ok=True)
lock = threading.Lock()
db = sqlite3.connect(DB_PATH, check_same_thread=False)
db.execute('PRAGMA secure_delete=ON')
db.execute('CREATE TABLE IF NOT EXISTS items (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, kind TEXT NOT NULL, created_at INTEGER NOT NULL, content BLOB NOT NULL)')
db.commit()

def clean():
    if RETENTION_DAYS > 0:
        db.execute('DELETE FROM items WHERE created_at < ?', (int(time.time() * 1000) - RETENTION_DAYS * 86400000,))
    db.execute('DELETE FROM items WHERE seq NOT IN (SELECT seq FROM items ORDER BY seq DESC LIMIT ?)', (LIMIT,))

def metadata(row):
    return dict(id=row[0], kind=row[1], createdAt=row[2], byteCount=len(row[3]), text=row[3].decode('utf-8') if row[1] == 'text' else None)

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def reply(self, status, value, mime='application/json; charset=utf-8'):
        body = value if isinstance(value, bytes) else json.dumps(value, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        if not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + TOKEN):
            self.close_connection = True
            self.reply(401, {'error': '连接密钥不正确'})
            return False
        self.connection.settimeout(30)
        return True

    def item_id(self, content=False):
        match = re.fullmatch(r'/items/([a-f0-9-]{36})' + ('/content' if content else ''), self.path)
        return match.group(1) if match else None

    def do_GET(self):
        if not self.authorized():
            return
        with lock, db:
            clean()
            if self.path == '/items':
                rows = db.execute('SELECT id, kind, created_at, content FROM items ORDER BY seq DESC').fetchall()
                self.reply(200, {'items': [metadata(row) for row in rows], 'limit': LIMIT, 'retentionDays': RETENTION_DAYS})
            elif self.item_id(content=True):
                row = db.execute('SELECT kind, content FROM items WHERE id=?', (self.item_id(content=True),)).fetchone()
                if row:
                    self.reply(200, row[1], 'image/png' if row[0] == 'image' else 'text/plain; charset=utf-8')
                else:
                    self.reply(404, {'error': '记录已被清理，请刷新列表'})
            else:
                self.reply(404, {'error': '接口不存在'})

    def do_PUT(self):
        if not self.authorized():
            return
        item_id = self.item_id()
        mime = self.headers.get('Content-Type', '').split(';')[0]
        if not item_id or mime not in ('text/plain', 'image/png'):
            self.close_connection = True
            self.reply(400, {'error': '只支持文本和 PNG 图片'})
            return
        try:
            size = int(self.headers.get('Content-Length', '-1'))
            if not 0 < size <= (MAX_IMAGE if mime == 'image/png' else MAX_TEXT):
                self.close_connection = True
                self.reply(413, {'error': '文本不能超过 1 MB，图片不能超过 20 MB'})
                return
            content = self.rfile.read(size)
            if len(content) != size:
                raise ValueError('Incomplete body')
            if mime == 'text/plain' and not content.decode('utf-8').strip():
                raise ValueError('Empty text')
            if mime == 'image/png' and not content.startswith(b'\x89PNG\r\n\x1a\n'):
                raise ValueError('Invalid PNG')
        except (ValueError, UnicodeError):
            self.reply(400, {'error': '内容格式不正确'})
            return
        with lock, db:
            db.execute('INSERT OR IGNORE INTO items (id, kind, created_at, content) VALUES (?, ?, ?, ?)',
                       (item_id, 'image' if mime == 'image/png' else 'text', int(time.time() * 1000), content))
            clean()
            row = db.execute('SELECT id, kind, created_at, content FROM items WHERE id=?', (item_id,)).fetchone()
            self.reply(200, metadata(row))

    def do_DELETE(self):
        if not self.authorized():
            return
        item_id = self.item_id()
        if not item_id:
            self.reply(404, {'error': '接口不存在'})
            return
        with lock, db:
            db.execute('DELETE FROM items WHERE id=?', (item_id,))
        self.reply(200, {'deleted': True})

class Server(ThreadingMixIn, HTTPServer):
    daemon_threads = True

def maintenance():
    while True:
        with lock, db:
            clean()
        time.sleep(60)

if __name__ == '__main__':
    threading.Thread(target=maintenance, daemon=True).start()
    Server((os.environ.get('CLIPBOARD_HOST', '127.0.0.1'), int(os.environ.get('CLIPBOARD_PORT', '18081'))), Handler).serve_forever()
