"""Update application/firmware only; never copy source data over a portable installation."""
from pathlib import Path
import hashlib,json,shutil,sqlite3,subprocess,sys,zipfile
from datetime import datetime,timezone
root=Path(__file__).resolve().parents[1];out=Path(sys.argv[1]).resolve()
if out==root or not (out/'package-manifest.json').is_file() or not (out/'runtime/python.exe').is_file():
    raise SystemExit('Not an existing standalone portable folder')
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def protected():
    files=[out/'settings.json']
    for directory in ('data','records'):
        files.extend(p for p in (out/directory).rglob('*') if p.is_file())
    return {str(p.relative_to(out)):digest(p) for p in files if p.is_file()}
before=protected();mapping={}
for folder in ('dashboard','firmware','packaging','tests'):
    for source in (root/folder).rglob('*'):
        rel=source.relative_to(root)
        if source.is_file() and not any(part in ('bin','__pycache__') for part in rel.parts):mapping[rel]=source
for name in ('Start-Demo.ps1','VERSION','README.md'):mapping[Path(name)]=root/name
mapping[Path('README.html')]=root/'packaging/README.html'
for name in ('flash_ntz.bin','nn_model.bin'):mapping[Path('firmware-binaries')/name]=root/'build'/name
stamp=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
backup=root/'backups'/('portable-before-015-'+stamp+'.zip');backup.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(backup,'x',zipfile.ZIP_DEFLATED) as z:
    for rel in list(mapping)+[Path('package-manifest.json'),Path('development/source-history.bundle')]:
        if (out/rel).is_file():z.write(out/rel,str(rel))
for rel,source in mapping.items():
    (out/rel).parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,out/rel)
m=json.loads((out/'package-manifest.json').read_text(encoding='utf-8'))
m['previous_source_commit']=m.get('source_commit');m['source_commit']=subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip()
m['version']=(root/'VERSION').read_text().strip();m['updated_utc']=stamp;m['firmware_upload_required']=True
m['firmware_sha256']={p.name:digest(p) for p in (out/'firmware-binaries').glob('*.bin')}
m['validation']=json.loads((root/'experiments/phase2/robust-weight-validation-20261030.json').read_text())
assert protected()==before,'Protected user data changed during update'
m['update_preserved_user_files']=len(before)
(out/'package-manifest.json').write_text(json.dumps(m,ensure_ascii=False,indent=2),encoding='utf-8')
subprocess.run(['git','-C',str(root),'bundle','create',str(out/'development/source-history.bundle'),'--all'],check=True)
for rel,source in mapping.items():assert digest(source)==digest(out/rel),str(rel)
print(json.dumps({'updated_files':len(mapping),'protected_files_unchanged':len(before),'backup':str(backup),'version':m['version']},ensure_ascii=False))
