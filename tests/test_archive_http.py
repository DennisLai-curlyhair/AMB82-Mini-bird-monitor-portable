"""Real HTTP proxy test, isolated temp data and dedicated ports."""
import json,os,subprocess,sys,tempfile,time,urllib.request,urllib.error,zipfile,io
from pathlib import Path
from test_archive import packet
from test_visit_photos import fixture, body
ROOT=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as temp:
    base=Path(temp);records=base/"records";records.mkdir()
    im,p=fixture();p["epoch"]=packet()["epoch"]
    p['grouping']=dict(score=71.5,threshold=76,samples=5,eligible=True,decision=1,candidate=1,candidate_generation=1,candidate_day=20747)
    record=dict(kind="visit",data=p,received_utc="2026-10-21T01:00:03+00:00")
    (records/"vision-http.jsonl").write_text(json.dumps(record)+"\n",encoding="utf-8")
    flags=getattr(subprocess,"CREATE_NO_WINDOW",0)
    log=(base/"log.txt").open("w")
    processes=[]
    try:
        processes.append(subprocess.Popen([sys.executable,str(ROOT/"archive/server.py"),"--data",str(base/"data"),"--records",str(records),"--port","8092"],stdout=log,stderr=log,creationflags=flags))
        processes.append(subprocess.Popen(["powershell","-NoProfile","-ExecutionPolicy","Bypass","-File",str(ROOT/"Start-Demo.ps1"),"-Simulate","-NoBrowser","-NoArchive","-WebPort","8090"],stdout=log,stderr=log,creationflags=flags))
        def request(path,body=None):
            data=None if body is None else json.dumps(body,ensure_ascii=False).encode("utf-8")
            req=urllib.request.Request("http://localhost:8090/history/"+path,data=data,headers={"Content-Type":"application/json"})
            with urllib.request.urlopen(req,timeout=10) as r:return r.read()
        for _ in range(50):
            try:
                d=json.loads(request("api/visits?date=2026-10-21"))
                if d["visits"]:break
            except (OSError,ValueError):pass
            time.sleep(.2)
        else:raise AssertionError("HTTP startup failed")
        # Browser assets must be tested over HTTP, not only file:// fixtures.
        for asset in ('/app.js','/vision.js','/visit-photos.js','/weights.js','/navigation.js','/history/navigation.js'):
            with urllib.request.urlopen('http://localhost:8090'+asset,timeout=10) as response:
                assert response.status==200
                assert response.headers.get_content_type()=='application/javascript'
                assert len(response.read())>100
        key=d["visits"][0]["key"]
        result=json.loads(request("api/review",dict(action="assign",keys=[key],name="中文手動群組")))
        assert result["ok"]
        d=json.loads(request("api/visits?date=2026-10-21"))
        assert d["visits"][0]["group_label"]=="中文手動群組"
        assert request("images/"+d["visits"][0]["image"]).startswith(b"\x89PNG")
        assert "中文手動群組" in request("api/export?date=2026-10-21").decode("utf-8-sig")
        bundle=zipfile.ZipFile(io.BytesIO(request("api/bundle?date=2026-10-21")))
        assert "visits.csv" in bundle.namelist()
        assert len([n for n in bundle.namelist() if n.startswith("images/")])==1
        assert json.loads(request("api/review",dict(action="exclude",keys=[key])))["ok"]
        assert json.loads(request("api/visits?date=2026-10-21"))["stats"]["valid"]==0
        assert json.loads(request("api/review",dict(action="undo")))["ok"]
        assert json.loads(request("api/visits?date=2026-10-21"))["stats"]["valid"]==1
        # Exercise the same photo endpoint used by the browser through the PS proxy.
        assert 'targets' in json.loads(request('api/photo-targets'))
        photo=body(im,key,p)
        # Valid JPEG plus trailing bytes tests a >1 MB JSON request and server re-encoding.
        import base64
        photo['jpeg']=base64.b64encode(base64.b64decode(photo['jpeg'])+b'\0'*800000).decode()
        assert len(json.dumps(photo))>1000000
        assert json.loads(request('api/photo',photo))['saved']
        data=json.loads(request('api/visits?date=2026-10-21'))['visits'][0]
        assert data['photo']['crop_width']==384
        assert request('images/'+data['photo']['full_image']).startswith(b'\xff\xd8')
        assert 'full_image' in request('api/export?date=2026-10-21').decode('utf-8-sig')
        bundle=zipfile.ZipFile(io.BytesIO(request('api/bundle?date=2026-10-21')))
        assert len([n for n in bundle.namelist() if n.startswith('images/')])==3
        assert '群組相簿' in request('groups').decode('utf-8')
        groups=json.loads(request('api/group-gallery?date=all'))
        assert groups['total_visits']==1
        from urllib.parse import quote
        token=groups['groups'][0]['id']
        album=json.loads(request('api/group-gallery?date=all&group='+quote(token)))
        assert album['visits'][0]['photo']['full_image']==data['photo']['full_image']
        assert album['visits'][0]['grouping']==p['grouping']
        # Restore and then assign to an existing auto group through the real API.
        request('api/review',dict(action='assign',keys=[key],group=None))
        auto=json.loads(request('api/group-gallery?date=all'))['groups'][0]['id']
        request('api/review',dict(action='assign',keys=[key],group=auto))
        assert json.loads(request('api/group-gallery?date=all&group='+quote(auto)))['total']==1
        assert json.loads(request('api/delete-visit',dict(key=key)))['ok']
        remaining=json.loads(request('api/visits?date=all'))
        assert remaining['visits']==[] and remaining['stats']['total']==0
        gallery=json.loads(request('api/group-gallery?date=all'))
        assert gallery['groups']==[] and gallery['dates']==[] and gallery['targets']==[]
        assert json.loads(request('api/delete-visit',dict(key=key)))['affected']==0
        import urllib.error
        try:request('images/'+data['photo']['full_image'])
        except urllib.error.HTTPError as e:assert e.code==404
        else:raise AssertionError('Deleted JPEG remains accessible')
        # Real monitor HTTP routes: no sensor connection must never claim calibration success.
        with urllib.request.urlopen('http://localhost:8090/api/status',timeout=10) as response:
            status=json.load(response)
        assert status['weights'] is None and status['weightStale']
        payload=dict(request_id='1'*32,boot='a'*32,channel=1,action='ZERO',confirm_empty=True)
        req=urllib.request.Request('http://localhost:8090/api/weights/action',data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'})
        try:urllib.request.urlopen(req,timeout=10)
        except urllib.error.HTTPError as e:
            assert e.code==400 and not json.load(e)['ok']
        else:raise AssertionError('Offline calibration incorrectly succeeded')
        req=urllib.request.Request('http://localhost:8090/api/decision',data=b'{"decision":"FEED"}',headers={'Content-Type':'application/json'})
        try:urllib.request.urlopen(req,timeout=10)
        except urllib.error.HTTPError as e:assert e.code==404
        else:raise AssertionError('Feeding endpoint still active')
        print("PASS: real HTTP gallery route, photos, manual/auto assignment, JPEG upload and ZIP")
    finally:
        for p in reversed(processes):
            p.terminate()
            try:p.wait(timeout=5)
            except subprocess.TimeoutExpired:p.kill();p.wait()
        log.close()