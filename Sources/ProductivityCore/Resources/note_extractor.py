#!/usr/bin/env python3
import sqlite3
import gzip
import os
import subprocess
import json
import sys

def get_notes_tasks():
    db_path = os.path.expanduser('~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite')
    if not os.path.exists(db_path):
        return []
    try:
        conn = sqlite3.connect(db_path)
        cur = conn.cursor()
        cur.execute('''
            SELECT ZDATA 
            FROM ZICNOTEDATA 
            JOIN ZICCLOUDSYNCINGOBJECT n ON ZICNOTEDATA.ZNOTE = n.Z_PK 
            LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON n.ZFOLDER = f.Z_PK 
            WHERE n.ZTITLE1 LIKE "%TASKS — TODAY%" 
              AND n.ZMARKEDFORDELETION = 0 
              AND (f.ZTITLE2 IS NULL OR f.ZTITLE2 != 'Recently Deleted')
            ORDER BY n.ZMODIFICATIONDATE DESC 
            LIMIT 1
        ''')
        row = cur.fetchone()
        if not row or not row[0]:
            return []

        data = gzip.decompress(row[0])
        p = subprocess.Popen(['protoc', '--decode_raw'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, _ = p.communicate(data)
        out_str = out.decode('latin1', 'ignore')

        # Extract text from protobuf field 3.2
        text = ''
        for line in out_str.split('\n'):
            if line.strip().startswith('2: "') and len(line) > 10:
                text = line.split('2: "', 1)[1].rsplit('"', 1)[0]
                break

        clean_text = text.encode('latin1').decode('unicode_escape', 'ignore').encode('latin1').decode('utf-8', 'ignore')
        raw_lines = clean_text.replace('\r', '\n').replace('\u2028', '\n').split('\n')

        # Check styles for native checklist items (1: 103) and checked state (subfield 5 has 2: 1)
        import re
        raw_blocks = re.split(r'\n    5 \{', out_str)
        checklist_blocks = []
        for b in raw_blocks[1:]:
            if '1: 103' in b:
                is_checked = bool(re.search(r'5\s*\{[^}]*2:\s*1', b))
                checklist_blocks.append(is_checked)

        results = []
        current_ws = 'work'
        chk_idx = 0
        for l in raw_lines:
            line = l.strip()
            if not line:
                continue
            u = line.upper()
            if u == 'WORK':
                current_ws = 'work'
                continue
            if u == 'PERSONAL':
                current_ws = 'personal'
                continue
            if 'TASKS' in u or 'TODAY' in u or 'NO ACTIVE TASKS' in u or 'UPDATED ' in u:
                continue

            block_checked = False
            if chk_idx < len(checklist_blocks):
                block_checked = checklist_blocks[chk_idx]
                chk_idx += 1

            is_checked = block_checked or line.startswith('✓') or line.startswith('☑') or line.startswith('[x]') or line.startswith('[X]')
            title = line.lstrip('✓☑○◯⚪️•*-[ ] ').strip()
            if title.lower().startswith('[work]'):
                current_ws = 'work'
                title = title[6:].strip()
            elif title.lower().startswith('[personal]'):
                current_ws = 'personal'
                title = title[10:].strip()

            if title:
                results.append({
                    'title': title,
                    'workspace': current_ws,
                    'completed': is_checked
                })

        return results
    except Exception as e:
        return []

if __name__ == '__main__':
    tasks = get_notes_tasks()
    print(json.dumps(tasks))
