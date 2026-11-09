"""UVC representative photos; time proximity plus reference-image validation.

Separate video streams are not hardware synchronized. Acceptance is a heuristic,
not proof of identical frames or species. Keep the original board thumbnail.
"""
import base64
import hashlib
import io
import json
import math
import os
import time
from PIL import Image, ImageStat, UnidentifiedImageError

MAX_DELTA=1.2
MAX_ERROR=.15

def setup(db):
    db.executescript('''
    CREATE TABLE IF NOT EXISTS deleted_photos(key TEXT PRIMARY KEY);
    CREATE TABLE IF NOT EXISTS photo_targets(
      key TEXT PRIMARY KEY, sequence INTEGER NOT NULL, epoch REAL NOT NULL,
      bbox TEXT NOT NULL, reference TEXT NOT NULL, score INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS photos(
      key TEXT PRIMARY KEY, full_image TEXT NOT NULL, crop_image TEXT NOT NULL,
      captured_utc REAL NOT NULL, sample_utc REAL NOT NULL, sequence INTEGER NOT NULL,
      bbox TEXT NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL,
      crop_width INTEGER NOT NULL, crop_height INTEGER NOT NULL,
      error REAL NOT NULL, delta REAL NOT NULL, score INTEGER NOT NULL);
    ''')

def remember(store,p,key,image,image_sequence,image_utc,image_score):
    box=p.get('image_bbox')
    # Old firmware and unknown time must not invent a crop/time association.
    if box is None or not image or image_utc is None:return
    if int(p.get('image_sequence',-1))!=image_sequence:return
    if not isinstance(box,list) or len(box)!=4:raise ValueError('Invalid sample bbox')
    if not all(isinstance(v,(int,float)) and math.isfinite(v) and 0<=v<=1 for v in box):raise ValueError('Invalid sample bbox')
    if box[0]>=box[2] or box[1]>=box[3]:raise ValueError('Empty sample bbox')
    store.db.execute('INSERT OR REPLACE INTO photo_targets VALUES(?,?,?,?,?,?)',
                     (key,image_sequence,image_utc,json.dumps(box),image,image_score))

def targets(store):
    with store.lock:
        rows=store.db.execute('''SELECT t.*,v.boot FROM photo_targets t JOIN visits v ON t.key=v.key
        LEFT JOIN photos p ON t.key=p.key
        WHERE t.epoch>? AND (p.key IS NULL OR t.score>p.score)
        ORDER BY t.epoch DESC LIMIT 32''',(time.time()-20,)).fetchall()
        return {'targets':[dict(r,bbox=json.loads(r['bbox'])) for r in rows],
                'time_tolerance_ms':int(MAX_DELTA*1000),'max_error':MAX_ERROR}

def capture(store,p):
    key=p.get('key');sequence=int(p.get('sequence',-1));stamp=float(p.get('captured_utc',0))
    if not math.isfinite(stamp):raise ValueError('Invalid capture time')
    encoded=p.get('jpeg','')
    if not isinstance(encoded,str) or len(encoded)>2800000:raise ValueError('Photo too large')
    try:raw=base64.b64decode(encoded,validate=True)
    except (ValueError,TypeError) as e:raise ValueError('Invalid JPEG encoding') from e
    try:
        im=Image.open(io.BytesIO(raw))
        if im.format!='JPEG' or im.width<320 or im.height<180 or im.width*im.height>1280*720:
            raise ValueError('Expected JPEG from 320x180 up to 1280x720')
        im.load();im=im.convert('RGB')
    except (UnidentifiedImageError,OSError,Image.DecompressionBombError) as e:
        raise ValueError('Invalid JPEG') from e
    with store.lock,store.db:
        target=store.db.execute('SELECT * FROM photo_targets WHERE key=?',(key,)).fetchone()
        if not target or target['sequence']!=sequence:raise ValueError('Reference changed or unavailable')
        delta=stamp-target['epoch']
        if abs(delta)>MAX_DELTA:raise ValueError('Capture outside time tolerance')
        box=json.loads(target['bbox'])
        bounds=(int(box[0]*im.width),int(box[1]*im.height),int(box[2]*im.width),int(box[3]*im.height))
        crop=im.crop(bounds)
        if min(crop.size)<64:raise ValueError('Bird crop too small for review photo')
        with Image.open(store.images/target['reference']) as reference:
            ref=reference.convert('RGB')
            if max(ImageStat.Stat(ref).stddev)<8:raise ValueError('Reference too uniform to match safely')
            small=crop.resize((24,24),Image.Resampling.NEAREST)
            error=sum(abs(a-b) for a,b in zip(small.tobytes(),ref.tobytes()))/(1728*255)
        if error>MAX_ERROR:raise ValueError('UVC crop does not match board reference')
        old=store.db.execute('SELECT * FROM photos WHERE key=?',(key,)).fetchone()
        if old and (target['score']<old['score'] or (target['score']==old['score'] and error>=old['error'])):
            return {'ok':True,'saved':False,'reason':'Existing representative is better'}
        def save(image):
            buffer=io.BytesIO();image.save(buffer,format='JPEG',quality=92)
            data=buffer.getvalue();name=key+'-'+hashlib.sha256(data).hexdigest()[:16]+'.jpg'
            tmp=store.images/(name+'.tmp');tmp.write_bytes(data);os.replace(tmp,store.images/name)
            return name
        full_name=save(im);crop_name=save(crop)
        store.db.execute('INSERT OR REPLACE INTO photos VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
            (key,full_name,crop_name,stamp,target['epoch'],sequence,target['bbox'],im.width,im.height,
             crop.width,crop.height,error,delta,target['score']))
        return {'ok':True,'saved':True,'error':error,'delta_ms':round(delta*1000),'crop_width':crop.width,'crop_height':crop.height}

def attach(store,rows):
    photos={r['key']:dict(r) for r in store.db.execute('SELECT * FROM photos')}
    deleted={r[0] for r in store.db.execute('SELECT key FROM deleted_photos')}
    for r in rows:
        r['photo_deleted']=r['key'] in deleted
        r['photo']=None if r['photo_deleted'] else photos.get(r['key'])
        if r['photo_deleted']:r['image']=None

def image_names(rows):
    names={r['image'] for r in rows if r.get('image')}
    for r in rows:
        if r.get('photo'):names.update((r['photo']['full_image'],r['photo']['crop_image']))
    return names


def delete(store,p):
    key=p.get('key')
    if not isinstance(key,str):raise ValueError('請指定到訪紀錄')
    with store.lock:
        row=store.db.execute('SELECT key FROM visits WHERE key=?',(key,)).fetchone()
        if not row:raise ValueError('到訪紀錄不存在')
        # A persistent tombstone prevents serial replay or late uploads restoring photos.
        with store.db:
            store.db.execute('INSERT OR IGNORE INTO deleted_photos VALUES(?)',(key,))
            store.db.execute('DELETE FROM photo_targets WHERE key=?',(key,))
            store.db.execute('DELETE FROM photos WHERE key=?',(key,))
            store.db.execute('UPDATE visits SET image=NULL WHERE key=?',(key,))
        # Generated filenames belong exclusively to this visit, including older versions.
        import re
        if not re.fullmatch('[0-9a-f]{64}',key):raise ValueError('Invalid stored key')
        for path in store.images.glob(key+'-*'):
            if path.is_file():path.unlink()
        return {'ok':True,'affected':1}
