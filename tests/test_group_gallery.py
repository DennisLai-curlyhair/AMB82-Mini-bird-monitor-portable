import unittest,tempfile,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'archive'))
from server import Store
from group_gallery import gallery,identity
from test_archive import packet

class GalleryTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.s=Store(self.tmp.name)
  with self.s.db:
   self.s.ingest(packet(),'2026-10-21T01:00:03+00:00')
   self.s.ingest(dict(packet(2),generation=2),'2026-10-21T01:00:03+00:00')
   self.s.ingest(dict(packet(3),generation=0),'2026-10-21T01:00:03+00:00')
  self.rows=sorted(self.s.listing('all')['visits'],key=lambda r:r['track'])
 def tearDown(self):self.s.close();self.tmp.cleanup()
 def test_move_between_auto_groups_and_undo(self):
  target=identity(self.rows[1]);source=identity(self.rows[0]);key=self.rows[0]['key']
  self.assertEqual(len(gallery(self.s,'all')['groups']),3)
  self.s.review(dict(action='assign',keys=[key],group=target))
  result=gallery(self.s,'all',group=target)
  self.assertEqual(result['total'],2)
  moved=next(r for r in result['visits'] if r['key']==key)
  self.assertEqual(moved['auto_group'],self.rows[0]['auto_group'])
  self.assertEqual(gallery(self.s,'all',group=source)['total'],0)
  self.s.review(dict(action='undo'))
  self.assertEqual(gallery(self.s,'all',group=source)['total'],1)
 def test_manual_unassigned_filters_pages_and_restore(self):
  keys=[r['key'] for r in self.rows]
  self.s.review(dict(action='assign',keys=keys[:2],name='同種鳥'))
  d=gallery(self.s,'all');group=next(g['id'] for g in d['groups'] if g['name']=='同種鳥')
  page=gallery(self.s,'all',group=group,offset=1,limit=1)
  self.assertEqual((page['total'],len(page['visits'])),(2,1))
  self.s.review(dict(action='exclude',keys=[keys[0]]))
  self.assertEqual(gallery(self.s,'all',group=group)['total'],1)
  self.assertEqual(gallery(self.s,'all',excluded=True,group=group)['total'],2)
  self.s.review(dict(action='assign',keys=[keys[1]],group=None))
  self.assertEqual(gallery(self.s,'2026-10-22')['total_visits'],0)
  self.assertEqual(gallery(self.s,'all',group='unassigned')['total'],1)
 def test_unassigned_first_then_recent_groups_and_visits(self):
  base=packet()['epoch']
  with self.s.db:
   self.s.ingest(dict(packet(4,epoch=base+120),generation=2),'2026-10-21T01:02:03+00:00')
   self.s.ingest(packet(5,epoch=base+60),'2026-10-21T01:01:03+00:00')
  result=gallery(self.s,'2026-10-21')
  self.assertEqual([g['id'] for g in result['groups']],['unassigned',identity(self.rows[1]),identity(self.rows[0])])
  visits=gallery(self.s,'2026-10-21',group=identity(self.rows[1]))['visits']
  self.assertEqual([r['track'] for r in visits],[4,2])
 def test_date_hierarchy(self):
  p=dict(packet(4),epoch=packet()['epoch']+86400,group_day=20748)
  with self.s.db:self.s.ingest(p,'2026-10-22T01:00:03+00:00')
  result=gallery(self.s,'2026-10-22')
  self.assertEqual(result['total_visits'],1)
  self.assertEqual(result['dates'],[{'date':'2026-10-22','visits':1},{'date':'2026-10-21','visits':3}])
  self.assertEqual(gallery(self.s,'2026-10-21')['total_visits'],3)
 def test_boot_identity_and_bad_target_rollback(self):
  with self.s.db:self.s.ingest(packet(boot='b'*32),'2026-10-21T01:00:03+00:00')
  self.assertEqual(len(gallery(self.s,'all')['groups']),4)
  before=list(self.s.db.execute('SELECT * FROM groups'))
  with self.assertRaises(ValueError):self.s.review(dict(action='assign',keys=[self.rows[0]['key']],group='auto:fake'))
  self.assertEqual(list(self.s.db.execute('SELECT * FROM groups')),before)
  with self.assertRaises(ValueError):self.s.review(dict(action='assign',keys=['missing'],group=identity(self.rows[0])))
  self.assertEqual(list(self.s.db.execute('SELECT * FROM groups')),before)

if __name__=='__main__':unittest.main()
