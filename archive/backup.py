"""Consistent SQLite + referenced-image backup while the recorder is running."""
import argparse
import json
from pathlib import Path
import sqlite3
import tempfile
import zipfile

def backup(data, destination):
    root=Path(data);output=Path(destination)
    if output.exists():raise FileExistsError("Backup destination already exists")
    if not (root/"visits.sqlite3").exists():raise FileNotFoundError("No archive database")
    output.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory() as temp:
        snapshot=Path(temp)/"visits.sqlite3"
        source=sqlite3.connect((root/"visits.sqlite3").as_uri()+"?mode=ro",uri=True)
        target=sqlite3.connect(snapshot)
        try:
            source.backup(target)
            images={r[0] for r in target.execute("SELECT DISTINCT image FROM visits WHERE image IS NOT NULL")}
            if target.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='photos'").fetchone():
                for full,crop in target.execute("SELECT full_image,crop_image FROM photos"):images.update((full,crop))
        finally:target.close();source.close()
        missing=[]
        with zipfile.ZipFile(output,"x",zipfile.ZIP_DEFLATED) as z:
            z.write(snapshot,"visits.sqlite3")
            for name in images:
                image=root/"images"/name
                if image.exists():z.write(image,"images/"+name)
                else:missing.append(name)
            z.writestr("backup-info.json",json.dumps({"missing_images":missing},indent=2))
    return output

if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("--data",required=True);p.add_argument("--output",required=True)
    a=p.parse_args();print(backup(Path(a.data).resolve(),Path(a.output).resolve()))