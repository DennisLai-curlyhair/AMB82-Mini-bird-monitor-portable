"""Group-centric archive view; effective membership preserves automatic evidence."""
from datetime import datetime, timezone

def identity(row):
    manual=row.get('manual_group')
    if manual:return manual if manual.startswith('auto:') else 'manual:'+manual
    return 'auto:'+row['auto_group'] if row.get('auto_group') else 'unassigned'

def auto_name(value):
    parts=value.split(':')
    date=datetime.fromtimestamp(int(parts[-2])*86400,timezone.utc).strftime('%Y-%m-%d')
    return '自動群 '+parts[-1]+' · '+date+' · 批次 '+parts[0][:8]

def gallery(store,date,window=False,excluded=False,group='',offset=0,limit=48):
    with store.lock:
        if date!='all':datetime.strptime(date,'%Y-%m-%d')
        data=store.listing('all',window,0,1000000)
        names={g['id']:g['name'] for g in data['groups']}
        rows=[r for r in data['visits'] if excluded or not r['excluded']]
        counts={}
        for r in rows:
            day=r['local_time'][:10];counts[day]=counts.get(day,0)+1
        dates=[dict(date=d,visits=counts[d]) for d in sorted(counts,reverse=True)]
        if date!='all':rows=[r for r in rows if r['local_time'][:10]==date]
        rows.sort(key=lambda r:(r['local_time'],r['key']))
        buckets={}
        for r in rows:
            token=identity(r)
            if token not in buckets:
                name=(names.get(token) or auto_name(token[5:])) if token.startswith('auto:') else (names.get(token[7:],'人工群') if token.startswith('manual:') else '未分群')
                buckets[token]=dict(id=token,name=name,count=0,excluded=0,photo_count=0,first=r['local_time'],last=r['local_time'],preview=None)
            b=buckets[token];b['count']+=1;b['excluded']+=int(bool(r['excluded']));b['photo_count']+=int(bool(r.get('photo')));b['last']=r['local_time']
            preview=r['photo']['crop_image'] if r.get('photo') else r.get('image')
            if preview and (not b['preview'] or r.get('photo')):b['preview']=preview
        summaries=sorted(buckets.values(),key=lambda b:(b['id']=='unassigned',b['last']),reverse=True)
        options={b['id']:b['name'] for b in summaries if b['id']!='unassigned'}
        for g in data['groups']:
            token=g['id'] if g['id'].startswith('auto:') else 'manual:'+g['id']
            options[token]=g['name']
        visits=[r for r in rows if identity(r)==group] if group else []
        visits.reverse()
        return dict(dates=dates,groups=summaries,targets=[dict(id=k,name=v) for k,v in options.items()],
                    visits=visits[offset:offset+limit],total=len(visits),offset=offset,limit=limit,
                    total_visits=len(rows),last_error=data['last_error'])
