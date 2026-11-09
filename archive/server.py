"""Local visit archive. Python 3.10+; Pillow validates and crops UVC photos."""
import group_gallery
import visit_photos
import argparse
import csv
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import struct
import threading
import time
import uuid
import zlib
import zipfile
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

TZ = timezone(timedelta(hours=8))
SCHEMA = """
CREATE TABLE IF NOT EXISTS deleted_visits(key TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS visits(
 key TEXT PRIMARY KEY, device TEXT NOT NULL, boot TEXT NOT NULL, track INTEGER NOT NULL,
 first_ms INTEGER NOT NULL, last_ms INTEGER NOT NULL, first_utc REAL, last_utc REAL,
 received_utc TEXT NOT NULL, ended INTEGER NOT NULL, peak INTEGER NOT NULL,
 threshold INTEGER NOT NULL, auto_group TEXT, manual_group TEXT,
 excluded INTEGER NOT NULL DEFAULT 0, reason TEXT NOT NULL DEFAULT '',
 image TEXT, image_score INTEGER NOT NULL DEFAULT 0, image_utc REAL,
 image_sequence INTEGER, missing TEXT, evictions INTEGER NOT NULL DEFAULT 0,
 UNIQUE(device,boot,track));
CREATE TABLE IF NOT EXISTS groups(id TEXT PRIMARY KEY,name TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS edits(
 id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, action TEXT NOT NULL,
 before_json TEXT NOT NULL, after_json TEXT NOT NULL, undone INTEGER NOT NULL DEFAULT 0, undone_at TEXT);
CREATE TABLE IF NOT EXISTS cursors(path TEXT PRIMARY KEY, offset INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS diagnostics(at TEXT NOT NULL,message TEXT NOT NULL);
"""

def utcnow():
    return datetime.now(timezone.utc).isoformat()

def png(rgb, side):
    def chunk(kind, data):
        return struct.pack(">I",len(data))+kind+data+struct.pack(">I",zlib.crc32(kind+data)&0xffffffff)
    raw=b"".join(b"\0"+rgb[y*side*3:(y+1)*side*3] for y in range(side))
    return b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",struct.pack(">IIBBBBB",side,side,8,2,0,0,0))+chunk(b"IDAT",zlib.compress(raw))+chunk(b"IEND",b"")

def sample_epoch(packet, ms):
    epoch=int(packet.get("epoch",0))
    if not epoch:
        return None
    delta=(int(packet["ms"])-int(ms)) & 0xffffffff
    # Raw uint32 milliseconds cannot date samples older than one wrap.
    if delta>0x7fffffff:
        return None
    return epoch-delta/1000

class Store:
    def __init__(self, root, device="amb82-mini-1"):
        self.root=Path(root);self.root.mkdir(parents=True,exist_ok=True)
        self.images=self.root/"images";self.images.mkdir(exist_ok=True)
        self.lock=threading.RLock()
        self.db=sqlite3.connect(self.root/"visits.sqlite3",check_same_thread=False)
        self.db.row_factory=sqlite3.Row
        self.db.executescript(SCHEMA)
        visit_photos.setup(self.db)
        if "grouping_json" not in {r[1] for r in self.db.execute("PRAGMA table_info(visits)")}:
            self.db.execute("ALTER TABLE visits ADD COLUMN grouping_json TEXT")
        if "undone_at" not in {r[1] for r in self.db.execute("PRAGMA table_info(edits)")}:
            self.db.execute("ALTER TABLE edits ADD COLUMN undone_at TEXT")
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.commit()
        self.device=device
        self.last_error=None
        self.last_ingest=None

    def ingest(self,p,received):
        """Called inside a transaction. Never overwrites human review fields."""
        if not re.fullmatch(r"[0-9a-f]{32}",str(p.get("boot",""))):
            raise ValueError("Invalid or missing board boot ID")
        track=int(p["id"])
        if not 0<track<=0xffffffff:
            raise ValueError("Invalid track ID")
        first,last=int(p["first_ms"]),int(p["last_ms"])
        if not 0<=first<=0xffffffff or not 0<=last<=0xffffffff:
            raise ValueError("Invalid millisecond timestamp")
        key=hashlib.sha256(f"{self.device}:{p['boot']}:{track}".encode()).hexdigest()
        if self.db.execute("SELECT 1 FROM deleted_visits WHERE key=?",(key,)).fetchone():return
        old=self.db.execute("SELECT * FROM visits WHERE key=?",(key,)).fetchone()
        # Reject older replay after newer last_seen; same-frame image can still arrive late.
        old_last=old["last_ms"] if old else last
        if old and ((last-old_last)&0xffffffff)>0x7fffffff:
            return
        first_utc=sample_epoch(p,first)
        last_utc=sample_epoch(p,last)
        auto=None
        if int(p.get("generation",0)):
            auto=f"{p['boot']}:{int(p.get('group_day',0))}:{int(p['generation'])}"
        image=old["image"] if old else None
        image_score=old["image_score"] if old else 0
        image_utc=old["image_utc"] if old else None
        image_sequence=old["image_sequence"] if old else None
        thumb=None if self.db.execute("SELECT 1 FROM deleted_photos WHERE key=?",(key,)).fetchone() else p.get("thumb")
        if thumb is not None:
            if int(p.get("width",0))!=24 or not re.fullmatch(r"[0-9a-fA-F]{3456}",thumb):
                raise ValueError("Invalid visit image")
            score=int(p.get("image_score",0))
            if not image or score>image_score:
                raw=bytes.fromhex(thumb)
                name=key+"-"+hashlib.sha256(raw).hexdigest()[:16]+".png"
                tmp=self.images/(name+".tmp")
                tmp.write_bytes(png(raw,24));os.replace(tmp,self.images/name)
                image=name;image_score=score
                image_utc=sample_epoch(p,int(p["image_ms"]))
                image_sequence=int(p["image_sequence"])
            elif image_utc is None:
                image_utc=sample_epoch(p,int(p["image_ms"]))
        ended=bool(p.get("ended")) or bool(old and old["ended"])
        missing=None if image else ("無有效同影格樣本" if ended else "等待影像／尚無有效樣本")
        values=(key,self.device,p["boot"],track,first,last,first_utc,last_utc,received,int(ended),
                int(p.get("peak",0)),int(p.get("threshold",0)),auto,image,image_score,image_utc,
                image_sequence,missing,int(p.get("evictions",0)))
        self.db.execute("""
        INSERT INTO visits(key,device,boot,track,first_ms,last_ms,first_utc,last_utc,received_utc,ended,
        peak,threshold,auto_group,image,image_score,image_utc,image_sequence,missing,evictions)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(key) DO UPDATE SET
        last_ms=excluded.last_ms,first_utc=COALESCE(visits.first_utc,excluded.first_utc),
        last_utc=COALESCE(excluded.last_utc,visits.last_utc),received_utc=excluded.received_utc,
        ended=MAX(visits.ended,excluded.ended),peak=MAX(visits.peak,excluded.peak),
        auto_group=COALESCE(excluded.auto_group,visits.auto_group),image=excluded.image,
        image_score=excluded.image_score,image_utc=excluded.image_utc,
        image_sequence=excluded.image_sequence,missing=excluded.missing,evictions=excluded.evictions
        """,values)
        if isinstance(p.get('grouping'),dict):
            g=p['grouping'];score=g.get('score');threshold=g.get('threshold')
            if not isinstance(threshold,(int,float)) or not math.isfinite(threshold) or not 0<=threshold<=100:
                raise ValueError('Invalid grouping threshold')
            if score is not None and (not isinstance(score,(int,float)) or not math.isfinite(score) or not 0<=score<=100):
                raise ValueError('Invalid grouping score')
            self.db.execute('UPDATE visits SET grouping_json=? WHERE key=?',(json.dumps(g),key))
        visit_photos.remember(self,p,key,image,image_sequence,image_utc,image_score)
        self.last_ingest=received

    def tail(self, records):
        with self.lock:
            for path in sorted(Path(records).glob("vision-*.jsonl")):
                # Stable identity survives copying the entire project to another PC.
                key="records/"+path.name
                row=self.db.execute("SELECT offset FROM cursors WHERE path=?",(key,)).fetchone()
                if row is None:
                    legacy=[r for r in self.db.execute("SELECT path,offset FROM cursors")
                            if r[0].replace("\\","/").rsplit("/",1)[-1]==path.name]
                    if len(legacy)==1:
                        row=(legacy[0][1],)
                        with self.db:
                            self.db.execute("DELETE FROM cursors WHERE path=?",(legacy[0][0],))
                            self.db.execute("INSERT OR REPLACE INTO cursors VALUES(?,?)",(key,row[0]))
                offset=row[0] if row else 0
                if path.stat().st_size<offset:offset=0
                with path.open("rb") as f:
                    f.seek(offset)
                    while True:
                        line=f.readline()
                        if not line or not line.endswith(b"\n"):break
                        try:
                            record=json.loads(line.decode("utf-8-sig"))
                            with self.db:
                                if record.get("kind")=="visit":
                                    self.ingest(record["data"],record["received_utc"])
                                self.db.execute("INSERT OR REPLACE INTO cursors VALUES(?,?)",(key,f.tell()))
                        except (ValueError,KeyError,TypeError) as exc:
                            self.last_error=str(exc)
                            with self.db:
                                self.db.execute("INSERT INTO diagnostics VALUES(?,?)",(utcnow(),f"{path.name}: {exc}"))
                                self.db.execute("INSERT OR REPLACE INTO cursors VALUES(?,?)",(key,f.tell()))

    def listing(self,date,window=False,offset=0,limit=100,group=""):
        if date!="all":datetime.strptime(date,"%Y-%m-%d")
        with self.lock:
            names={r["id"]:r["name"] for r in self.db.execute("SELECT * FROM groups WHERE id IN (SELECT manual_group FROM visits)")}
            result=[]
            for row in self.db.execute("SELECT * FROM visits ORDER BY COALESCE(first_utc,0),key"):
                r=dict(row)
                r['grouping']=json.loads(r.pop('grouping_json') or 'null')
                stamp=datetime.fromtimestamp(r["first_utc"],TZ) if r["first_utc"] is not None else datetime.fromisoformat(r["received_utc"]).astimezone(TZ)
                if date!="all" and stamp.date().isoformat()!=date:continue
                if window and (r["first_utc"] is None or not 8<=stamp.hour<17):continue
                r["group_label"]=names.get(r["manual_group"]) if r["manual_group"] else ("自動 "+r["auto_group"][-10:] if r["auto_group"] else "未分群")
                r["local_time"]=stamp.isoformat()
                r["time_uncertain"]=r["first_utc"] is None
                r["duration_ms"]=(r["last_ms"]-r["first_ms"])&0xffffffff
                age=(datetime.now(timezone.utc)-datetime.fromisoformat(r["received_utc"])).total_seconds()
                r["end_status"]="已離開" if r["ended"] else ("結束時間未確認／斷線或未再回傳" if age>60 else "尚未收到離開確認")
                if group and r["manual_group"]!=group:continue
                result.append(r)
            result.sort(key=lambda r:(r["local_time"],r["key"]),reverse=True)
            visit_photos.attach(self,result)
            stats={"total":len(result),"excluded":sum(r["excluded"] for r in result),
                   "valid":sum(not r["excluded"] for r in result),"missing_images":sum(not r["image"] for r in result),
                   "uncertain_time":sum(r["time_uncertain"] for r in result)}
            return {"visits":result[offset:offset+limit],"stats":stats,"groups":[{"id":k,"name":v} for k,v in names.items()],
                    "offset":offset,"limit":limit,"last_ingest":self.last_ingest,"last_error":self.last_error,
                    "max_evictions":max((r["evictions"] for r in result),default=0)}

    def delete_visit(self, request):
        key=request.get('key')
        if not isinstance(key,str) or not re.fullmatch('[0-9a-f]{64}',key):
            raise ValueError('到訪識別碼無效')
        with self.lock:
            row=self.db.execute('SELECT key FROM visits WHERE key=?',(key,)).fetchone()
            deleted=self.db.execute('SELECT key FROM deleted_visits WHERE key=?',(key,)).fetchone()
            if not row and not deleted:raise ValueError('到訪紀錄不存在')
            with self.db:
                self.db.execute('INSERT OR IGNORE INTO deleted_visits VALUES(?)',(key,))
                self.db.execute('DELETE FROM photo_targets WHERE key=?',(key,))
                self.db.execute('DELETE FROM photos WHERE key=?',(key,))
                self.db.execute('DELETE FROM visits WHERE key=?',(key,))
                self.db.execute('DELETE FROM deleted_photos WHERE key=?',(key,))
            for path in self.images.glob(key+'-*'):
                if path.is_file():path.unlink()
            return {'ok':True,'affected':int(row is not None)}

    def review(self, request):
        action=request.get("action")
        with self.lock, self.db:
            before=[];after=[]
            if action=="undo":
                edit=self.db.execute("SELECT * FROM edits WHERE undone=0 ORDER BY id DESC LIMIT 1").fetchone()
                if not edit:raise ValueError("沒有可撤銷的操作")
                for item in json.loads(edit["before_json"]):
                    self.db.execute("UPDATE visits SET manual_group=?,excluded=?,reason=? WHERE key=?",
                                    (item["manual_group"],item["excluded"],item["reason"],item["key"]))
                self.db.execute("UPDATE edits SET undone=1,undone_at=? WHERE id=?",(utcnow(),edit["id"]))
                return {"ok":True,"undone":edit["id"]}
            if action not in ("assign","exclude","restore","merge"):
                raise ValueError("不支援的操作")
            keys=request.get("keys",[])
            if action=="merge":
                sources=request.get("sources",[])
                if not isinstance(sources,list) or not 1<=len(sources)<=100:raise ValueError("請選來源群組")
                keys=[r[0] for r in self.db.execute("SELECT key FROM visits WHERE manual_group IN ("+",".join("?" for _ in sources)+")",sources)]
            if not isinstance(keys,list) or not 1<=len(keys)<=10000:raise ValueError("請選擇到訪紀錄")
            keys=list(dict.fromkeys(keys))
            target=request.get("group")
            if action in ("assign","merge"):
                name=str(request.get("name","")).strip()
                if name:
                    if len(name)>80:raise ValueError("群組名稱過長")
                    target=uuid.uuid4().hex
                    self.db.execute("INSERT INTO groups VALUES(?,?)",(target,name))
                elif target and isinstance(target,str) and target.startswith('auto:'):
                    auto=target[5:]
                    if not self.db.execute('SELECT 1 FROM visits WHERE auto_group=?',(auto,)).fetchone():
                        raise ValueError('找不到目標自動群')
                    self.db.execute('INSERT OR IGNORE INTO groups VALUES(?,?)',(target,group_gallery.auto_name(auto)))
                elif target and not self.db.execute("SELECT 1 FROM groups WHERE id=?",(target,)).fetchone():
                    raise ValueError("找不到目標群組")
                # null target restores the original automatic assignment.
            reason=str(request.get("reason",""))[:500]
            for key in keys:
                row=self.db.execute("SELECT key,manual_group,excluded,reason FROM visits WHERE key=?",(key,)).fetchone()
                if not row:raise ValueError("到訪資料不存在")
                b=dict(row);a=dict(b)
                if action in ("assign","merge"):a["manual_group"]=target
                else:a["excluded"]=int(action=="exclude");a["reason"]=reason
                before.append(b);after.append(a)
                self.db.execute("UPDATE visits SET manual_group=?,excluded=?,reason=? WHERE key=?",
                                (a["manual_group"],a["excluded"],a["reason"],key))
            cur=self.db.execute("INSERT INTO edits(at,action,before_json,after_json) VALUES(?,?,?,?)",
                                (utcnow(),action,json.dumps(before),json.dumps(after)))
            return {"ok":True,"edit":cur.lastrowid,"affected":len(keys)}

    def close(self):
        self.db.close()

def serve(args):
    store=Store(args.data,args.device)
    stop=threading.Event()
    def worker():
        while not stop.is_set():
            try:store.tail(args.records)
            except Exception as exc:store.last_error=str(exc)
            stop.wait(1)
    threading.Thread(target=worker,daemon=True).start()
    class Handler(BaseHTTPRequestHandler):
        def send(self,status,data,ctype="application/json; charset=utf-8"):
            if not isinstance(data,bytes):data=json.dumps(data,ensure_ascii=False).encode()
            self.send_response(status);self.send_header("Content-Type",ctype)
            self.send_header("Content-Length",str(len(data)));self.send_header("Cache-Control","no-store")
            self.send_header("X-Content-Type-Options","nosniff");self.end_headers();self.wfile.write(data)
        def do_GET(self):
            try:
                url=urlsplit(self.path);path=url.path.removeprefix("/history");q=parse_qs(url.query)
                if path in ("","/","/index.html"):
                    return self.send(200,(Path(__file__).parent/"index.html").read_bytes(),"text/html; charset=utf-8")
                if path=='/navigation.js':
                    return self.send(200,(Path(__file__).parent.parent/'dashboard/navigation.js').read_bytes(),'application/javascript; charset=utf-8')
                if path in ('/groups','/groups/'):
                    return self.send(200,(Path(__file__).parent/'group-gallery.html').read_bytes(),'text/html; charset=utf-8')
                if path=='/api/group-gallery':
                    return self.send(200,group_gallery.gallery(store,q.get('date',[datetime.now(TZ).date().isoformat()])[0],
                        q.get('window',['0'])[0]=='1',q.get('excluded',['0'])[0]=='1',q.get('group',[''])[0],
                        max(0,int(q.get('offset',['0'])[0])),min(100,max(1,int(q.get('limit',['48'])[0])))))
                if path=="/health":
                    return self.send(200,{"ok":True,"service":"bird-visit-archive","last_ingest":store.last_ingest,"last_error":store.last_error})
                if path.startswith("/images/"):
                    name=path.split("/")[-1]
                    if not re.fullmatch(r"[0-9a-f]{64}-[0-9a-f]{16}\.(?:png|jpg)",name):raise ValueError("圖片名稱無效")
                    target=store.images/name
                    if not target.exists():return self.send(404,{"error":"圖片不存在"})
                    return self.send(200,target.read_bytes(),"image/jpeg" if name.endswith(".jpg") else "image/png")
                if path=="/api/photo-targets":return self.send(200,visit_photos.targets(store))
                if path=="/api/audit":
                    with store.lock:
                        rows=[dict(r) for r in store.db.execute("SELECT * FROM edits ORDER BY id DESC LIMIT 100")]
                    return self.send(200,{"edits":rows})
                if path in ("/api/visits","/api/export","/api/bundle"):
                    date=q.get("date",[datetime.now(TZ).date().isoformat()])[0]
                    offset=max(0,int(q.get("offset",["0"])[0]));limit=min(500,max(1,int(q.get("limit",["100"])[0])))
                    data=store.listing(date,q.get("window",["0"])[0]=="1",offset,limit,q.get("group",[""])[0])
                    if path in ("/api/export","/api/bundle"):
                        data=store.listing(date,q.get("window",["0"])[0]=="1",0,1000000,q.get("group",[""])[0])
                        output=io.StringIO();writer=csv.writer(output)
                        fields=["key","local_time","time_uncertain","duration_ms","end_status","peak","threshold","group_label","excluded","reason","image","full_image","crop_image","capture_time","match_error"]
                        writer.writerow(fields)
                        for r in data["visits"]:
                            photo=r.get('photo') or {}
                            r.update(full_image=photo.get('full_image',''),crop_image=photo.get('crop_image',''),
                                     capture_time=photo.get('captured_utc',''),match_error=photo.get('error',''))
                            vals=[r.get(k,"") for k in fields]
                            vals=[("'"+v if isinstance(v,str) and v[:1] in ("=","+","-","@") else v) for v in vals]
                            writer.writerow(vals)
                        csv_bytes=output.getvalue().encode("utf-8-sig")
                        if path=="/api/bundle":
                            bundle=io.BytesIO()
                            with zipfile.ZipFile(bundle,"w",zipfile.ZIP_DEFLATED) as z:
                                z.writestr("visits.csv",csv_bytes)
                                z.writestr("metadata.json",json.dumps({"date":date,"stats":data["stats"],"visits":data["visits"]},ensure_ascii=False,indent=2))
                                for name in visit_photos.image_names(data["visits"]):
                                    if (store.images/name).exists():z.write(store.images/name,"images/"+name)
                            return self.send(200,bundle.getvalue(),"application/zip")
                        return self.send(200,csv_bytes,"text/csv; charset=utf-8")
                    return self.send(200,data)
                return self.send(404,{"error":"Not found"})
            except (ValueError,KeyError,TypeError) as exc:self.send(400,{"error":str(exc)})
            except Exception as exc:self.send(500,{"error":str(exc)})
        def do_POST(self):
            # Same-origin form/json operations only; no CORS.
            origin=self.headers.get("Origin")
            if origin and urlsplit(origin).netloc!=self.headers.get("Host"):
                return self.send(403,{"error":"Origin mismatch"})
            try:
                path=urlsplit(self.path).path.removeprefix("/history")
                if path not in ("/api/review","/api/photo","/api/delete-photo","/api/delete-visit"):
                    return self.send(404,{"error":"Not found"})
                size=int(self.headers.get("Content-Length",0))
                if not 0<size<=(4000000 if path=="/api/photo" else 1000000):raise ValueError("Request too large")
                payload=json.loads(self.rfile.read(size))
                if path=="/api/delete-visit":result=store.delete_visit(payload)
                elif path=="/api/delete-photo":result=visit_photos.delete(store,payload)
                elif path=="/api/photo":result=visit_photos.capture(store,payload)
                else:result=store.review(payload)
                self.send(200,result)
            except (ValueError,KeyError,TypeError) as exc:self.send(400,{"error":str(exc)})
            except Exception as exc:self.send(500,{"error":str(exc)})
        def log_message(self,*args):pass
    server=ThreadingHTTPServer(("127.0.0.1",args.port),Handler)
    try:server.serve_forever()
    finally:stop.set();server.server_close()

if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--data",required=True);parser.add_argument("--records",required=True)
    parser.add_argument("--port",type=int,default=8082);parser.add_argument("--device",default="amb82-mini-1")
    serve(parser.parse_args())