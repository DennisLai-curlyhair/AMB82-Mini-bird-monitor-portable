import json, os, shutil, subprocess, sys, tempfile, time, urllib.request
from pathlib import Path
source=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="Bird Portable ") as tmp:
    root=Path(tmp)/"搬移 測試"
    shutil.copytree(source,root)
    def get(route):
        with urllib.request.urlopen("http://127.0.0.1:8180"+route,timeout=3) as r:return r.read()
    log=open(Path(tmp)/"service.log","wb")
    proc=subprocess.Popen(["powershell.exe","-NoProfile","-ExecutionPolicy","Bypass","-File",str(root/"Launch.ps1"),"-Offline","-NoBrowser","-WebPort","8180"],stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
    try:
        for _ in range(60):
            if proc.poll() is not None:raise RuntimeError((Path(tmp)/"service.log").read_text(errors="replace"))
            try:
                status=json.loads(get("/api/status"));break
            except Exception:time.sleep(.5)
        else:raise RuntimeError("Startup timeout")
        assert status["connected"] is False
        assert b"html" in get("/").lower()
        listing=json.loads(get("/history/api/visits?date=all"))
        expected=json.loads((root/"package-manifest.json").read_text())["snapshot_counts"]["visits"]
        assert listing["stats"]["total"]==expected,listing["stats"]
        assert get("/weights.js")
        duplicate=subprocess.run(["powershell.exe","-NoProfile","-ExecutionPolicy","Bypass","-File",str(root/"Launch.ps1"),"-Offline","-NoBrowser","-WebPort","8180"],capture_output=True,timeout=15,creationflags=subprocess.CREATE_NO_WINDOW)
        assert duplicate.returncode!=0,"Duplicate startup unexpectedly succeeded"
        for name in ("test_archive.py","test_group_gallery.py","test_visit_photos.py"):
            subprocess.run([str(root/"runtime/python.exe"),"-m","unittest","discover","-s",str(root/"tests"),"-p",name],check=True)
        print(json.dumps({"relocated_path":True,"offline_http":True,"visits":expected,"duplicate_blocked":True,"unit_tests":21}))
    finally:
        (root/".stop-request").write_text("stop")
        proc.wait(timeout=20);log.close()
    assert proc.returncode==0
    import socket
    for port in (8180,8182):
        with socket.socket() as s:assert s.connect_ex(("127.0.0.1",port))!=0
    print("Graceful stop released both ports.")
