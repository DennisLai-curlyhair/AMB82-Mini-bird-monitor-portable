import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import sys
import zipfile
from datetime import datetime, timezone

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"archive"))
from server import Store, png

def packet(track=1,boot="a"*32,ended=True,epoch=None):
    if epoch is None:epoch=int(datetime(2026,10,21,1,0,3,tzinfo=timezone.utc).timestamp())
    return dict(boot=boot,id=track,ms=3000,epoch=epoch,first_ms=0,last_ms=2500,
                ended=ended,peak=90,threshold=60,group=1,group_day=20747,generation=1,
                image_ms=1000,image_sequence=6,image_score=90,evictions=0,width=24,thumb="ff0000"*576)
class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.store=Store(self.temp.name)
    def tearDown(self):
        self.store.close();self.temp.cleanup()
    def put(self,p):
        with self.store.db:self.store.ingest(p,"2026-10-21T01:00:03+00:00")
    def data(self,window=False):
        return self.store.listing("2026-10-21",window)
    def test_cursor_survives_legacy_path_and_relocation(self):
        import shutil
        logs=Path(self.temp.name)/"old records";logs.mkdir()
        f=logs/"vision-20261029.jsonl"
        line=json.dumps({"kind":"visit","data":packet(),"received_utc":"2026-10-21T01:00:03+00:00"})+"\n"
        f.write_text(line,encoding="utf-8")
        with self.store.db:
            self.store.db.execute("INSERT INTO cursors VALUES(?,?)",("C:\\old\\records\\"+f.name,f.stat().st_size))
        # Existing cursor must prevent reimport even though this fixture has no visits.
        self.store.tail(logs)
        self.assertEqual(self.data()["stats"]["total"],0)
        moved=logs.parent/"new location";shutil.copytree(logs,moved)
        self.store.tail(moved)
        self.assertEqual(self.data()["stats"]["total"],0)
        with (moved/f.name).open("a",encoding="utf-8") as out:out.write(line)
        self.store.tail(moved)
        self.assertEqual(self.data()["stats"]["total"],1)

    def test_newest_first_before_pagination(self):
        base=packet()["epoch"]
        for track,delta in [(1,0),(2,120),(3,60)]:
            self.put(packet(track,epoch=base+delta))
        self.assertEqual([r["track"] for r in self.data()["visits"]],[2,3,1])
        self.assertEqual(self.store.listing("all",offset=1,limit=1)["visits"][0]["track"],3)
        with self.store.db:
            self.store.ingest(packet(4,epoch=0),"2026-10-21T02:00:00+00:00")
        self.assertEqual(self.data()["visits"][0]["track"],4)
    def test_grouping_snapshot_persists_without_fabricating_legacy_scores(self):
        self.put(packet())
        self.assertIsNone(self.data()['visits'][0]['grouping'])
        detail=dict(samples=5,eligible=True,decision=3,threshold=76,score=70.5,candidate=2,candidate_generation=9,candidate_day=20747)
        self.put(dict(packet(),grouping=detail))
        self.store.close();self.store=Store(self.temp.name)
        self.put(packet())
        self.assertEqual(self.data()['visits'][0]['grouping'],detail)
        with self.assertRaises(ValueError):self.put(dict(packet(),grouping=dict(detail,score=101)))
        self.assertEqual(self.data()['visits'][0]['grouping'],detail)
    def test_idempotent_restart_and_identity(self):
        p=packet();self.put(p);self.put(p)
        r=self.data()["visits"][0]
        self.assertEqual(self.data()["stats"]["total"],1)
        self.assertEqual((self.store.images/r["image"]).read_bytes()[:8],b"\x89PNG\r\n\x1a\n")
        self.store.close();self.store=Store(self.temp.name);self.put(p)
        self.put(packet(boot="b"*32))
        self.assertEqual(self.data()["stats"]["total"],2)
        self.assertEqual(self.data(True)["stats"]["valid"],2)
    def test_human_review_replay_undo_and_rollback(self):
        self.put(packet());self.put(packet(2))
        keys=[r["key"] for r in self.data()["visits"]]
        self.store.review(dict(action="assign",keys=keys,name="白頭翁"))
        group=self.data()["groups"][0]["id"]
        self.put(packet())
        self.assertTrue(all(r["manual_group"]==group for r in self.data()["visits"]))
        self.store.review(dict(action="exclude",keys=[keys[0]],reason="不是鳥"))
        self.assertEqual(self.data()["stats"]["valid"],1)
        self.store.review(dict(action="undo"));self.assertEqual(self.data()["stats"]["valid"],2)
        self.store.review(dict(action="assign",keys=[keys[0]],name="拆出測試"))
        other=next(g["id"] for g in self.data()["groups"] if g["id"]!=group)
        self.store.review(dict(action="merge",sources=[other],group=group))
        self.assertTrue(all(r["manual_group"]==group for r in self.data()["visits"]))
        self.store.review(dict(action="undo"))
        self.assertEqual(sum(r["manual_group"]==other for r in self.data()["visits"]),1)
        with self.assertRaises(ValueError):self.store.review(dict(action="assign",keys=["missing"],name="不應殘留"))
        self.assertNotIn("不應殘留",[g["name"] for g in self.data()["groups"]])
        self.store.review(dict(action="exclude",keys=keys))
        self.store.review(dict(action="restore",keys=keys))
        self.assertEqual(self.data()["stats"]["valid"],2)
    def test_window_unknown_clock_and_missing_photo(self):
        p=packet();p["epoch"]=int(datetime(2026,10,21,0,0,3,tzinfo=timezone.utc).timestamp())
        self.put(p)
        p=packet(2);p["epoch"]=int(datetime(2026,10,21,9,0,3,tzinfo=timezone.utc).timestamp());self.put(p)
        p=packet(3,epoch=0);p["thumb"]=None;self.put(p)
        self.assertEqual(self.data()["stats"]["total"],3)
        self.assertEqual(self.data(True)["stats"]["total"],1)
        self.assertEqual(self.data()["stats"]["missing_images"],1)
        self.assertEqual(self.data()["stats"]["uncertain_time"],1)
        self.put(packet(3))
        self.assertEqual(self.data()["stats"]["uncertain_time"],0)
        self.assertEqual(self.data()["stats"]["missing_images"],0)
    def test_stale_replay_does_not_regress(self):
        self.put(packet())
        p=packet(ended=False);p["last_ms"]=1000;self.put(p)
        r=self.data()["visits"][0]
        self.assertTrue(r["ended"]);self.assertEqual(r["last_ms"],2500)
    def test_tailer_partial_line_duplicate_and_resume(self):
        records=Path(self.temp.name)/"records";records.mkdir()
        path=records/"vision-test.jsonl"
        record=json.dumps(dict(kind="visit",data=packet(),received_utc="2026-10-21T01:00:03+00:00"))
        path.write_text(record,encoding="utf-8")
        self.store.tail(records);self.assertEqual(self.data()["stats"]["total"],0)
        with path.open("a",encoding="utf-8") as f:f.write("\n"+record+"\n")
        self.store.tail(records);self.store.tail(records)
        self.assertEqual(self.data()["stats"]["total"],1)
        self.store.close();self.store=Store(self.temp.name);self.store.tail(records)
        self.assertEqual(self.data()["stats"]["total"],1)
    def test_consistent_backup(self):
        from backup import backup
        self.put(packet())
        path=backup(Path(self.temp.name).resolve(),Path(self.temp.name)/"backup.zip")
        with zipfile.ZipFile(path) as z:
            self.assertIn("visits.sqlite3",z.namelist())
            self.assertEqual(len([n for n in z.namelist() if n.startswith("images/")]),1)
        with self.assertRaises(FileExistsError):backup(Path(self.temp.name).resolve(),path)
    def test_image_not_shared_between_visits(self):
        self.put(packet())
        p=packet(2);p["thumb"]="0000ff"*576;self.put(p)
        rows=self.data()["visits"]
        self.assertNotEqual(rows[0]["image"],rows[1]["image"])
        self.assertNotEqual((self.store.images/rows[0]["image"]).read_bytes(),(self.store.images/rows[1]["image"]).read_bytes())

if __name__=="__main__":unittest.main()