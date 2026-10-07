#!/usr/bin/env python3
"""Read-only import adoption report; explicit apply owns bounded source blocks."""
import hashlib
from pathlib import Path
import re
import uuid
from urllib.parse import quote, urlencode
import paperclip
import paperclip_config as config

BEGIN = '<!-- paperclip-source-status:begin -->'
END = '<!-- paperclip-source-status:end -->'


def source_marker(project, source):
    return '<!-- paperclip-source:' + hashlib.sha256((project+'\n'+source).encode()).hexdigest()[:24] + ' -->'


def source_state(root, source):
    root = Path(root).resolve()
    filename, _, heading = source.partition('#')
    filename = re.sub(r':\d+$', '', filename)
    path = (root/filename).resolve()
    if not path.is_relative_to(root): return {'status':'invalid-source','location':filename}, None
    is_plan = filename.startswith(('docs/plans/', 'plans/'))
    if not path.is_file() and is_plan:
        directory = root/('docs/plans' if filename.startswith('docs/plans/') else 'plans')
        matches = [p for p in directory.rglob(path.name) if 'archive' in '/'.join(p.relative_to(directory).parts[:-1]).lower()]
        if len(matches) == 1: path = matches[0]
        elif len(matches)>1: return {'status':'ambiguous-archive','location':filename}, None
    if not path.is_file(): return {'status':'missing-source','location':filename}, None
    text = path.read_text()
    state = {'status':'needs-triage','location':str(path.relative_to(root))}
    plan_id = None
    if is_plan:
        front = re.match(r'^---\s*\n(.*?)\n---(?:\s|$)',text,re.S)
        status = re.search(r'^status:\s*[\"\']?([\w-]+)',front[1],re.M) if front else None
        identity = re.search(r'^id:\s*(\d+)\s*$',front[1],re.M) if front else None
        state['status'] = status[1].lower() if status else 'unknown-status'
        plan_id = str(int(identity[1])) if identity else None
    elif heading:
        def plain(value): return re.sub(r'[`*~]', '', value).strip()
        normalized = plain(heading)
        state['status'] = 'missing-section'
        for line in text.splitlines():
            title = re.match(r'^#{1,6}\s+(.+)',line)
            checkbox = re.match(r'^\s*[-*]\s+\[([ xX])\]\s+(.+)',line)
            bullet = re.match(r'^\s*[-*]\s+(.+)',line)
            if title and normalized in plain(title[1]):
                state['status']='done' if title[1].strip().startswith('~~') else 'needs-triage';break
            if checkbox and normalized in plain(checkbox[2]):
                state['status']='done' if checkbox[1].lower()=='x' else 'needs-triage';break
            if bullet and normalized in plain(bullet[1]): state['status']='needs-triage';break
    return state, plan_id


def source_block(description):
    if description.count(BEGIN)!=description.count(END) or description.count(BEGIN)>1 or (BEGIN in description and description.index(END)<description.index(BEGIN)):
        raise config.ConfigError('malformed managed source block')
    match=re.search(re.escape(BEGIN)+r'.*?'+re.escape(END),description,flags=re.S)
    return match[0] if match else None


def restore_source_block(description, original):
    """Restore only owned content after the operator verifies a fresh full record."""
    current=source_block(description)
    if original is not None and source_block(original)!=original:
        raise config.ConfigError('invalid original managed source block')
    if current:
        return description.replace(current,original or '',1)
    return description if original is None else description+'\n\n'+original


def managed_description(description, state):
    block = BEGIN+'\nSource status (current checkout): '+state['status']+'\nSource location: '+state['location']+'\n'+END
    if description.count(BEGIN)!=description.count(END) or description.count(BEGIN)>1 or (BEGIN in description and description.index(END)<description.index(BEGIN)):
        raise config.ConfigError('malformed managed source block')
    if BEGIN in description:
        return re.sub(re.escape(BEGIN)+r'.*?'+re.escape(END),lambda _:block,description,flags=re.S)
    return description.rstrip()+'\n\n'+block


def adopt(repo, sources, profile=None, company=None, apply=False, mappings_only=False):
    binding = config.status(repo)
    profile = profile or binding['profile']
    company = company or binding['company_id']
    profiles = config.validate_profiles(config.read_json(config.profile_path()))['profiles']
    if not profile or profile not in profiles or not company:
        raise config.ConfigError('adoption requires explicitly selected profile and company')
    selected = profiles[profile]
    # A large import gets bounded requests but a fresh deadline per project;
    # the ordinary event reporting contract remains 30 seconds per invocation.
    api = paperclip.API(selected['api_base'], selected['auth_file'])
    projects = api.pages('/companies/'+quote(company,safe='')+'/projects')
    manifest = config.read_json(sources)
    report, proposals, grouped = [], [], {}
    for project in manifest['projects']:
        matches = [row for row in projects if row.get('name')==project['name'] and row.get('companyId')==company]
        if len(matches)!=1:
            report.append({'project':project['name'],'result':'project-missing-or-ambiguous'});continue
        remote = matches[0]
        root = Path(project['path']).resolve()
        current = config.status(root)
        if current['mode']=='enabled' and any(current[k]!=v for k,v in [('profile',profile),('company_id',company),('project_id',remote['id'])]):
            report.append({'project':project['name'],'result':'existing-binding-conflict'});continue
        repository_id = current['repository_id'] or str(uuid.uuid4())
        api = paperclip.API(selected['api_base'], selected['auth_file'])
        rows = api.pages('/companies/'+quote(company,safe='')+'/issues?'+urlencode({'projectId':remote['id']}))
        full = [paperclip.full_issue(api,row['id']) for row in rows]
        records, mappings, seen_ids, seen_issues = [], {}, set(), set()
        grouped[str(root)]={'root':root,'profile':profile,'company':company,'project':remote['id'],'repository_id':repository_id,'records':records,'mappings':mappings}
        for task in project['tasks']:
            marker = source_marker(project['name'],task['source'])
            matched = [issue for issue in full if marker in (issue.get('description') or '')]
            if len(matched)!=1:
                report.append({'project':project['name'],'source':task['source'],'result':'source-marker-missing-or-ambiguous'});continue
            issue=matched[0]
            if issue['id'] in seen_issues:
                report.append({'project':project['name'],'source':task['source'],'result':'ambiguous-import-record'});continue
            seen_issues.add(issue['id'])
            if issue.get('companyId')!=company or issue.get('projectId')!=remote['id'] or issue.get('descriptionTruncated'):
                report.append({'project':project['name'],'source':task['source'],'result':'full-record-unavailable'});continue
            state, plan_id = source_state(root,task['source'])
            try: description=managed_description(issue.get('description') or '',state)
            except config.ConfigError:
                report.append({'project':project['name'],'source':task['source'],'result':'malformed-source-block'});continue
            diagnostic = None
            if task['source'].startswith(('docs/plans/', 'plans/')) and not plan_id:
                if not mappings_only:
                    report.append({'project':project['name'],'source':task['source'],'state':state,'result':'native-source-unresolved'});continue
                diagnostic='native-source-unresolved; retained as independent source-only record'
            if plan_id:
                import paperclip_lifecycle
                try:
                    paperclip_lifecycle.identity(root, state['location'])
                except config.ConfigError:
                    diagnostic='native-plan-id-collision; retained as independent source-only record'
                    plan_id=None
                if plan_id in seen_ids:
                    diagnostic='native-plan-id-collision; retained as independent source-only record'
                    plan_id=None
            if plan_id:
                seen_ids.add(plan_id)
                mappings[plan_id]={'issue_id':issue['id'],'status':issue['status'],'updated_at':issue.get('updatedAt'),'sequence':0}
            records.append({'source':task['source'],'marker':marker,'issue_id':issue['id'],'plan_id':plan_id,'state':state,'original_source_block':source_block(issue.get('description') or '')})
            report.append({'project':project['name'],'source':task['source'],'issue_id':issue['id'],'plan_id':plan_id,'state':state,'diagnostic':diagnostic,'result':'verified','refresh':description!=(issue.get('description') or '')})
            proposals.append({'root':root,'profile':profile,'company':company,'project':remote['id'],'repository_id':repository_id,'issue':issue,'description':description,'records':records,'mappings':mappings,'baseline_before':{'status':issue['status'],'updated_at':issue.get('updatedAt')}})
    if not apply: return {'mode':'dry-run','mappings_only':mappings_only,'report':report,'verified':sum(row['result']=='verified' for row in report),'apply_allowed':all(row['result']=='verified' for row in report)}
    if not all(row['result']=='verified' for row in report):
        raise config.ConfigError('adoption has ambiguous or missing mappings; apply refused')
    for proposal in grouped.values():
        existing=paperclip.load_state(config.binding_path(proposal['root']).parent/'events.json')['mappings']
        if any(key in existing and existing[key]['issue_id']!=value['issue_id'] for key,value in proposal['mappings'].items()):
            raise config.ConfigError('existing native mapping conflict; apply refused')
    # Snapshot local rollback material before any mutation. No credentials stored.
    for proposal in grouped.values():
        directory=config.binding_path(proposal['root']).parent
        with config.locked(directory/'adoption.json'):
            target=directory/'adoption-backup.json'
            if not target.exists():
                config.atomic_write(target,{name:config.read_json(directory/name) if (directory/name).exists() else None for name in ('binding.json','events.json','adoption.json')})
    # Persist every remote original before the first PATCH, including partial runs.
    # Retry keeps the first original instead of snapshotting an already refreshed block.
    for proposal in grouped.values():
        directory=config.binding_path(proposal['root']).parent
        with config.locked(directory/'adoption-remote-backup.json'):
            target=directory/'adoption-remote-backup.json'
            originals=config.read_json(target) if target.exists() else {'version':1,'issues':{}}
            # Upgrade earlier snapshots without retaining unrelated human text.
            for row in originals['issues'].values():
                if 'description' in row:
                    row['source_block']=source_block(row.pop('description'))
            for record in proposal['records']:
                block=record['original_source_block']
                if block and (api.token in block or re.search(r'(?i)(bearer\s+\S+|(?:token|password|api[_-]?key)\s*[:=]|-----BEGIN .*PRIVATE KEY)',block)):
                    raise config.ConfigError('managed source block contains credential material; adoption refused')
                originals['issues'].setdefault(record['issue_id'],{'source_block':block,'marker':record['marker']})
            config.atomic_write(target,originals)
    for proposal in proposals:
        api=paperclip.API(selected['api_base'],selected['auth_file'])
        fresh=paperclip.full_issue(api,proposal['issue']['id'])
        if fresh!=proposal['issue']:
            raise config.ConfigError('import changed since parity check; apply stopped, inspect partial source refresh')
        if not mappings_only and proposal['description']!=fresh.get('description'):
            api.request('PATCH','/issues/'+quote(fresh['id'],safe=''),{'description':proposal['description']})
            confirmed=paperclip.full_issue(api,fresh['id'])
            if confirmed.get('description')!=proposal['description']:
                raise config.ConfigError('source refresh readback failed; inspect partial adoption')
            for mapping in proposal['mappings'].values():
                if mapping['issue_id']==fresh['id']: mapping['updated_at']=confirmed.get('updatedAt')
    for proposal in grouped.values():
        root=proposal['root'];directory=config.binding_path(root).parent
        with config.locked(directory/'events.json'):
            state=paperclip.load_state(directory/'events.json')
            for plan_id,mapping in proposal['mappings'].items():
                if plan_id in state['mappings'] and state['mappings'][plan_id]['issue_id']!=mapping['issue_id']:
                    raise config.ConfigError('existing native mapping conflict; adoption stopped')
                # Preserve existing native baseline if present, not a new authority.
                current=state['mappings'].get(plan_id)
                prior=next((item['baseline_before'] for item in proposals if item['root']==root and item['issue']['id']==mapping['issue_id']),None)
                if current and prior and current.get('status')==prior['status'] and current.get('updated_at')==prior['updated_at']:
                    current['updated_at']=mapping['updated_at']
                state['mappings'].setdefault(plan_id,mapping)
            config.atomic_write(directory/'events.json',state)
        config.configure(root,{'version':1,'mode':'enabled','profile':profile,'company_id':company,'project_id':proposal['project'],'repository_id':proposal['repository_id']})
        with config.locked(directory/'adoption.json'):
            config.atomic_write(directory/'adoption.json',{'version':1,'writer':'native-mstack-local-mappings' if mappings_only else 'native-mstack','records':proposal['records']})
    return {'mode':'applied','report':report,'verified':len(report),'projects':len(grouped),'writer':'native-mstack-local-mappings' if mappings_only else 'native-mstack'}
