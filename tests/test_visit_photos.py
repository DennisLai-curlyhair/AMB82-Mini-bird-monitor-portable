import base64,io,json,sys,tempfile,time,unittest,zipfile
from pathlib import Path
from PIL import Image,ImageDraw
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'archive'))
from server import Store
import visit_photos
from backup import backup
from test_archive import packet

def fixture():
    im=Image.new('RGB',(640,360),'#9cab97');d=ImageDraw.Draw(im)
    for y in range(72,288,18):
        for x in range(128,512,24):d.rectangle((x,y,x+23,y+17),fill=('#c24b15' if (x//24+y//18)%2 else '#26333a'))
    crop=im.crop((128,72,512,288)).resize((24,24),Image.Resampling.NEAREST)
    p=packet(epoch=int(time.time()),ended=False);p['thumb']=crop.tobytes().hex();p['image_bbox']=[.2,.2,.8,.8]
    return im,p

def body(im,key,p,delta=0):
    b=io.BytesIO();im.save(b,format='JPEG',quality=95)
    return dict(key=key,sequence=p['image_sequence'],captured_utc=p['epoch']-2+delta,jpeg=base64.b64encode(b.getvalue()).decode())

class PhotoTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.store=Store(self.temp.name)
        self.im,self.p=fixture()
        with self.store.db:self.store.ingest(self.p,'2026-10-22T06:00:00+00:00')
        self.key=self.store.db.execute('SELECT key FROM visits').fetchone()[0]
    def tearDown(self):self.store.close();self.temp.cleanup()
    def test_delete_visit_recounts_and_survives_restart_replay(self):
        from group_gallery import gallery
        visit_photos.capture(self.store,body(self.im,self.key,self.p))
        with self.store.db:self.store.ingest(dict(self.p,id=2),'2026-10-22T06:00:00+00:00')
        self.store.review(dict(action='assign',keys=[self.key],name='false detection'))
        self.assertEqual(len(gallery(self.store,'all')['groups']),2)
        with self.assertRaises(ValueError):self.store.delete_visit({'key':'f'*64})
        self.assertEqual(self.store.delete_visit({'key':self.key})['affected'],1)
        self.assertEqual(self.store.delete_visit({'key':self.key})['affected'],0)
        self.assertEqual(list(self.store.images.glob(self.key+'-*')),[])
        self.assertEqual(self.store.listing('all')['stats']['total'],1)
        groups=gallery(self.store,'all')
        self.assertEqual(len(groups['groups']),1)
        self.assertEqual(groups['groups'][0]['count'],1)
        self.assertNotIn('false detection',[g['name'] for g in groups['targets']])
        self.store.review({'action':'undo'})
        self.store.close();self.store=Store(self.temp.name)
        with self.store.db:self.store.ingest(self.p,'2026-10-22T06:00:01+00:00')
        self.assertEqual(self.store.listing('all')['stats']['total'],1)
        with self.assertRaises(ValueError):visit_photos.capture(self.store,body(self.im,self.key,self.p))
        remaining=self.store.listing('all')['visits'][0]
        self.assertEqual(remaining['track'],2)
        self.store.delete_visit({'key':remaining['key']})
        groups=gallery(self.store,'all')
        self.assertEqual((groups['dates'],groups['groups'],groups['targets']),([],[],[]))
        self.assertEqual(self.store.listing('all')['stats']['total'],0)

    def test_delete_photos_preserves_visit_and_blocks_replay(self):
        visit_photos.capture(self.store,body(self.im,self.key,self.p))
        with self.store.db:self.store.ingest(dict(self.p,id=2),'2026-10-22T06:00:00+00:00')
        self.store.review(dict(action='assign',keys=[self.key],name='keep group'))
        before=next(r for r in self.store.listing('all')['visits'] if r['key']==self.key)
        with self.assertRaises(ValueError):visit_photos.delete(self.store,{'key':'missing'})
        visit_photos.delete(self.store,{'key':self.key})
        visit_photos.delete(self.store,{'key':self.key})
        self.assertEqual(list(self.store.images.glob(self.key+'-*')),[])
        self.store.close();self.store=Store(self.temp.name)
        with self.store.db:self.store.ingest(self.p,'2026-10-22T06:00:01+00:00')
        rows=self.store.listing('all')['visits'];after=next(r for r in rows if r['key']==self.key)
        for field in ['first_utc','auto_group','manual_group']:self.assertEqual(before[field],after[field])
        self.assertTrue(after['photo_deleted']);self.assertIsNone(after['image']);self.assertIsNone(after['photo'])
        self.assertTrue(next(r for r in rows if r['key']!=self.key)['image'])
        with self.assertRaises(ValueError):visit_photos.capture(self.store,body(self.im,self.key,self.p))
        self.assertEqual(list(self.store.images.glob(self.key+'-*')),[])

    def test_capture_persistence_replay_backup(self):
        target=visit_photos.targets(self.store)['targets'][0];self.assertEqual(target['boot'],self.p['boot'])
        result=visit_photos.capture(self.store,body(self.im,self.key,self.p));self.assertTrue(result['saved'])
        self.assertEqual((result['crop_width'],result['crop_height']),(384,216))
        self.store.review(dict(action='assign',keys=[self.key],name='人工鳥種'))
        with self.store.db:self.store.ingest(self.p,'2026-10-22T06:00:01+00:00')
        self.assertEqual(len(visit_photos.targets(self.store)['targets']),0)
        row=dict(self.store.db.execute('SELECT * FROM visits').fetchone());visit_photos.attach(self.store,[row])
        self.assertIsNotNone(row['manual_group']);self.assertIsNotNone(row['photo'])
        names=visit_photos.image_names([row]);self.assertEqual(len(names),3)
        out=backup(self.temp.name,Path(self.temp.name)/'backup.zip')
        with zipfile.ZipFile(out) as z:self.assertTrue(all('images/'+n in z.namelist() for n in names))
        self.store.close();self.store=Store(self.temp.name)
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM photos').fetchone()[0],1)
    def test_reject_wrong_time_reference_and_background(self):
        for data in (body(self.im,self.key,self.p,2),body(self.im,'bad',self.p),
                     body(Image.new('RGB',(640,360),'white'),self.key,self.p)):
            with self.assertRaises(ValueError):visit_photos.capture(self.store,data)
        data=body(self.im,self.key,self.p);data['sequence']+=1
        with self.assertRaises(ValueError):visit_photos.capture(self.store,data)
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM photos').fetchone()[0],0)
    def test_reject_small_corrupt_and_invalid_bbox(self):
        data=body(self.im,self.key,self.p);data['jpeg']='not base64'
        with self.assertRaises(ValueError):visit_photos.capture(self.store,data)
        self.store.db.execute('UPDATE photo_targets SET bbox=?',(json.dumps([.2,.2,.21,.21]),));self.store.db.commit()
        with self.assertRaises(ValueError):visit_photos.capture(self.store,body(self.im,self.key,self.p))
        for box in ([0,0,2,1],[0,0,0,0],[float('nan'),0,1,1]):
            with self.assertRaises(ValueError):visit_photos.remember(self.store,dict(self.p,image_bbox=box),self.key,'x',6,time.time(),90)
    def test_old_firmware_and_unknown_time(self):
        self.store.db.execute('DELETE FROM photo_targets')
        p=dict(self.p);p.pop('image_bbox')
        with self.store.db:self.store.ingest(p,'2026-10-22T06:00:00+00:00')
        self.assertEqual(visit_photos.targets(self.store)['targets'],[])
        p=dict(self.p,id=2,epoch=0)
        with self.store.db:self.store.ingest(p,'2026-10-22T06:00:00+00:00')
        self.assertEqual(visit_photos.targets(self.store)['targets'],[])

if __name__=='__main__':unittest.main()
