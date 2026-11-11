"""Current common skill and labels for the offline follow-up issue tests."""
import json
import re
import sys
from pathlib import Path

package, destination = map(Path, sys.argv[1:])
folder = package / 'common/skills/squad-handoff'
text = (folder / 'SKILL.md').read_text()
version = (package / 'VERSION').read_text().strip()
description = re.search(r'^description: (.+)$', text, re.M)[1]
files = [dict(id=f'file-{n}', path=str(p.relative_to(folder)), content=p.read_text())
         for n, p in enumerate(sorted(folder.rglob('*')))
         if p.is_file() and p.name != 'SKILL.md']
skill = dict(id='handoff', name='squad-handoff', description=description,
             created_by='actor', content=text, files=files,
             config=dict(origin=dict(type='github', source_url=
                         f'https://github.com/AnD00/multica-squad-kit/tree/{version}/common/skills/squad-handoff')))
db = dict(issues=[], skills=[skill], members=[dict(user_id='actor', name='Owner', role='owner'),
                                            dict(user_id='creator', name='Creator', role='member')],
          labels=[dict(id='ops', name='運用'), dict(id='instructions', name='指示の改善'),
                  dict(id='trial', name='検証'), dict(id='important', name='重要')])
destination.write_text(json.dumps(db, ensure_ascii=False))
