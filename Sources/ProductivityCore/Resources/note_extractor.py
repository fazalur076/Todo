#!/usr/bin/env python3
import sqlite3
import gzip
import os
import subprocess
import json
import re
import sys

def get_notes_tasks(target_title="TASKS — TODAY"):
    db_path = os.path.expanduser('~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite')
    if not os.path.exists(db_path):
        return []
    try:
        conn = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True)
        cur = conn.cursor()
        title_param = f"%{target_title}%"
        cur.execute('''
            SELECT ZDATA 
            FROM ZICNOTEDATA 
            JOIN ZICCLOUDSYNCINGOBJECT n ON ZICNOTEDATA.ZNOTE = n.Z_PK 
            LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON n.ZFOLDER = f.Z_PK 
            WHERE (n.ZTITLE1 LIKE ? OR n.ZTITLE1 LIKE "%TASKS — TODAY%" OR n.ZTITLE1 LIKE "%TASKS - TODAY%")
              AND n.ZMARKEDFORDELETION = 0 
              AND (f.ZTITLE2 IS NULL OR f.ZTITLE2 != 'Recently Deleted')
            ORDER BY 
              CASE 
                WHEN n.ZTITLE1 LIKE ? THEN 1 
                WHEN n.ZTITLE1 LIKE "%TASKS — TODAY%" THEN 2 
                ELSE 3 
              END ASC,
              COALESCE(n.ZMODIFICATIONDATE, 0) DESC,
              n.Z_PK DESC 
            LIMIT 1
        ''', (title_param, title_param))
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

        # Dynamic division mappings passed via CLI arg (or fallback to defaults)
        known_divisions = {
            'WORK': 'work',
            'PERSONAL': 'personal',
            'FREELANCE': 'freelance'
        }
        if len(sys.argv) > 1:
            try:
                user_divs = json.loads(sys.argv[1])
                for k, v in user_divs.items():
                    known_divisions[str(k).strip().upper()] = str(v).strip()
            except Exception:
                pass

        results = []
        current_ws = 'work'
        reserved_headers = {'TASKS', 'TODAY', 'NO ACTIVE TASKS'}.union(known_divisions.keys())
        seen_titles = set()

        for line, start, end in lines_with_pos:
            clean = line.strip()
            if not clean:
                continue

            # Strip all list/checklist/bullet/emoji prefixes first to inspect the true content
            clean_title = clean.lstrip('✓☑○◯⚪️◐•*-[ ] \t').strip()
            if not clean_title:
                continue

            u = clean_title.upper()
            matched_ws = None
            if u in known_divisions:
                matched_ws = known_divisions[u]
            else:
                for k, v in known_divisions.items():
                    if u == f"{k}:" or u == f"{k} TASKS":
                        matched_ws = v
                        break

            if matched_ws:
                current_ws = matched_ws
                continue

            if target_title.upper() in u or 'TASKS — TODAY' in u or 'TASKS - TODAY' in u or u in reserved_headers or 'UPDATED ' in u:
                continue
            if u.startswith('NO ACTIVE'):
                continue

            for k, v in known_divisions.items():
                prefix = f"[{k.lower()}]"
                if clean_title.lower().startswith(prefix):
                    current_ws = v
                    clean_title = clean_title[len(prefix):].strip()
                    break

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
    target_title = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2].strip() else "TASKS — TODAY"
    tasks = get_notes_tasks(target_title)
    print(json.dumps(tasks))
