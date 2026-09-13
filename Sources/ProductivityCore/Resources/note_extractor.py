#!/usr/bin/env python3
import sqlite3
import gzip
import os
import subprocess
import json
import re
import sys

def get_notes_tasks():
    db_path = os.path.expanduser('~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite')
    if not os.path.exists(db_path):
        return []
    try:
        conn = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True)
        cur = conn.cursor()
        cur.execute('''
            SELECT ZDATA 
            FROM ZICNOTEDATA 
            JOIN ZICCLOUDSYNCINGOBJECT n ON ZICNOTEDATA.ZNOTE = n.Z_PK 
            LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON n.ZFOLDER = f.Z_PK 
            WHERE (n.ZTITLE1 LIKE "%TASKS — TODAY%" OR n.ZTITLE1 LIKE "%TASKS - TODAY%" OR n.ZTITLE1 LIKE "%TASKS TODAY%")
              AND n.ZMARKEDFORDELETION = 0 
              AND (f.ZTITLE2 IS NULL OR f.ZTITLE2 != 'Recently Deleted')
            ORDER BY 
              CASE 
                WHEN n.ZTITLE1 LIKE "%TASKS — TODAY%" THEN 1 
                WHEN n.ZTITLE1 LIKE "%TASKS - TODAY%" THEN 2 
                ELSE 3 
              END ASC,
              COALESCE(n.ZMODIFICATIONDATE, 0) DESC,
              n.Z_PK DESC 
            LIMIT 1
        ''')
        row = cur.fetchone()
        if not row or not row[0]:
            return []

        data = gzip.decompress(row[0]) if row[0].startswith(b'\x1f\x8b') else row[0]
        
        # Use protoc to decode protobuf raw data
        process = subprocess.Popen(['protoc', '--decode_raw'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, _ = process.communicate(data)
        out_str = out.decode('latin1', 'ignore')

        # Find the text payload in field 2 of Note
        text = ""
        for line in out_str.split('\n'):
            if line.strip().startswith('2: "') and len(line) > 10:
                text = line.split('2: "', 1)[1].rsplit('"', 1)[0]
                break

        clean_text = text.encode('latin1').decode('unicode_escape', 'ignore').encode('latin1').decode('utf-8', 'ignore')

        # Extract attribute runs with character offsets
        raw_p_blocks = out_str.split('\n    5 {')
        runs = []
        curr_offset = 0
        for b in raw_p_blocks[1:]:
            m_len = re.search(r'^\s*1:\s*(\d+)', b)
            p_len = int(m_len.group(1)) if m_len else 0
            is_checklist = '1: 103' in b
            m_chk = re.search(r'5\s*\{[^}]*2:\s*(\d+)', b)
            checked = (m_chk.group(1) == '1') if m_chk else False
            struck = bool(re.search(r'\b7:\s*1\b', b))
            runs.append({
                'start': curr_offset,
                'end': curr_offset + p_len,
                'len': p_len,
                'checklist': is_checklist,
                'checked': checked,
                'struck': struck
            })
            curr_offset += p_len

        # Split clean_text by real newlines (never slice words by protobuf attribute runs!)
        lines_with_pos = []
        pos = 0
        for raw_l in clean_text.replace('\r', '\n').replace('\u2028', '\n').split('\n'):
            line_len = len(raw_l)
            lines_with_pos.append((raw_l, pos, pos + line_len))
            pos += line_len + 1  # +1 for newline

        results = []
        current_ws = 'work'
        reserved_headers = {'WORK', 'PERSONAL', 'TASKS', 'TODAY', 'NO ACTIVE TASKS'}
        seen_titles = set()

        for line, start, end in lines_with_pos:
            clean = line.strip()
            if not clean:
                continue

            # Strip all list/checklist/bullet/emoji prefixes first to inspect the true content
            clean_title = clean.lstrip('✓☑○◯⚪️•*-[ ] \t').strip()
            if not clean_title:
                continue

            u = clean_title.upper()
            if u == 'WORK' or u.startswith('WORK:') or u == 'WORK TASKS':
                current_ws = 'work'
                continue
            if u == 'PERSONAL' or u.startswith('PERSONAL:') or u == 'PERSONAL TASKS':
                current_ws = 'personal'
                continue
            if 'TASKS — TODAY' in u or 'TASKS - TODAY' in u or u in reserved_headers or 'UPDATED ' in u:
                continue
            if u.startswith('NO ACTIVE'):
                continue

            if clean_title.lower().startswith('[work]'):
                current_ws = 'work'
                clean_title = clean_title[6:].strip()
            elif clean_title.lower().startswith('[personal]'):
                current_ws = 'personal'
                clean_title = clean_title[10:].strip()

            clean_title = clean_title.strip()
            if not clean_title or clean_title.upper() in reserved_headers:
                continue

            dedup_key = f"{current_ws}::{clean_title.lower()}"
            if dedup_key in seen_titles:
                continue
            seen_titles.add(dedup_key)

            # Check overlapping attribute runs for this line
            line_is_checked = False
            line_is_struck = False
            for r in runs:
                if max(start, r['start']) < min(end, r['end']):
                    if r['checked']:
                        line_is_checked = True
                    if r['struck']:
                        line_is_struck = True

            is_completed = line_is_checked or line_is_struck or clean.startswith('✓') or clean.startswith('☑') or clean.startswith('[x]') or clean.startswith('[X]')

            results.append({
                'title': clean_title,
                'workspace': current_ws,
                'completed': is_completed
            })

        return results
    except Exception as e:
        return []

if __name__ == '__main__':
    tasks = get_notes_tasks()
    print(json.dumps(tasks))
