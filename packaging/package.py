"""Populate a prepared portable runtime directory. Stop the source service first."""
from pathlib import Path
import json, shutil, sqlite3, subprocess, sys, zipfile, tempfile
root=Path(__file__).resolve().parents[1]
out=Path(sys.argv[1]).resolve()
if not (out/'runtime/python.exe').is_file():raise SystemExit('Prepare the verified embedded runtime first')
if (out/'data').exists():raise SystemExit('Destination already contains data; refusing to overwrite')
for name in ('archive','dashboard','firmware'):
    shutil.copytree(root/name,out/name,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
for name in ('Start-Demo.ps1','VERSION','README.md'):
    shutil.copy2(root/name,out/name)
for name in ('Launch.ps1','Start.cmd','Stop.cmd','settings.json','README.html'):
    shutil.copy2(root/'packaging'/name,out/name)
shutil.copytree(root/'records',out/'records',ignore=shutil.ignore_patterns('*.log'))
sys.path.insert(0,str(root/'archive'))
from backup import backup
with tempfile.TemporaryDirectory() as temp:
    z=backup(root/'data',Path(temp)/'data.zip')
    with zipfile.ZipFile(z) as archive:archive.extractall(out/'data')
(out/'firmware-binaries').mkdir()
for name in ('flash_ntz.bin','nn_model.bin'):
    shutil.copy2(root/'build'/name,out/'firmware-binaries'/name)
dev=out/'development';dev.mkdir()
for name in ('Build.ps1','Setup.ps1','Prepare-ModelSD.ps1','birds_2@yolov7-tiny.nb'):
    shutil.copy2(root/name,out/name)
shutil.copytree(root/'tests',out/'tests',ignore=shutil.ignore_patterns('__pycache__','bin','*.exe','*.obj'))
shutil.copytree(root/'packaging',out/'packaging')
commit=subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip()
db=sqlite3.connect(out/'data/visits.sqlite3')
counts={table:db.execute('SELECT COUNT(*) FROM '+table).fetchone()[0] for table in ('visits','photos','groups')}
assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
db.close()
(out/'package-manifest.json').write_text(json.dumps({'source_commit':commit,'version':(root/'VERSION').read_text().strip(),'snapshot_counts':counts,'platform':'Windows x64','independent_data_snapshot':True},ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(counts));print(out)
