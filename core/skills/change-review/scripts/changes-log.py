"""直したいことの記録を読む。更新は同じ .lock の下で行う。"""
import argparse
from contextlib import contextmanager
from datetime import datetime
import os
from pathlib import Path
import re
import sys
import tempfile
import time

LOG = Path(os.environ.get('CLAUDE_REVIEW_CHANGES_LOG', str(Path.home() / '.local/state/claude-reports/changes/log.md')))
INTRO = '''# 直したいことの記録

定期実行と会話が見つけた直したいことを、1件ずつ末尾に記録する。
日時と ID の見出しから次の見出しまでを1件とする。
状態は未対応・対応済み（日時と内容）・見送り（日時と理由）とする。
区分は直してよい・要確認（理由）とする。要確認は利用者の会話での承認を受けてから入れる。
'''


def entries(text):
    lines = text.splitlines(keepends=True)
    starts = []
    fence = None
    for i, line in enumerate(lines):
        m = re.match(r'^(`{3,}|~{3,})(.*)$', line)
        if fence:
            if re.match(r'^' + re.escape(fence[0]) + '{' + str(len(fence)) + r',}\s*$', line):
                fence = None
            continue
        if m:
            fence = m[1]
            continue
        m = re.match(r'^## (\d{4}-\d{2}-\d{2} \d{2}:\d{2}) (\S+)\s*$', line)
        if m:
            starts.append((i, m[1], m[2]))
    result = []
    for j, (start, stamp, cid) in enumerate(starts):
        end = starts[j + 1][0] if j + 1 < len(starts) else len(lines)
        fields = {}
        # 差分内の状態・見出しを項目のメタデータとして扱わない。
        for k in range(start + 1, end):
            if re.match(r'^(`{3,}|~{3,})', lines[k]):
                break
            m = re.match(r'^- ([^:]+): (.*)\n?$', lines[k])
            if m and m[1] not in fields:
                fields[m[1]] = (m[2], k)
        result.append((start, end, stamp, cid, fields))
    return lines, result


def read():
    return LOG.read_text(encoding='utf-8') if LOG.exists() else ''


@contextmanager
def locked():
    LOG.parent.mkdir(parents=True, exist_ok=True)
    lock = LOG.parent / '.lock'
    for _ in range(50):
        try:
            lock.mkdir()
            break
        except FileExistsError:
            time.sleep(.1)
    else:
        raise OSError('記録の排他を取れない: ' + str(lock))
    try:
        yield
    finally:
        lock.rmdir()


def save(text):
    fd, name = tempfile.mkstemp(prefix='.log-', dir=str(LOG.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(text)
        os.replace(name, LOG)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def one(value):
    return value.replace('\r', ' ').replace('\n', ' ')


def main():
    cmd = sys.argv[1]
    if cmd in ('count', 'list'):
        _, records = entries(read())
        pending = [r for r in records if r[4].get('状態', ('',))[0] == '未対応']
        if cmd == 'count':
            oldest = min(pending, key=lambda r: (r[2], r[0]))[3] if pending else ''
            needs = sum(r[4].get('区分', ('',))[0].startswith('要確認') for r in pending)
            print('changes\t{}\t{}\t{}'.format(len(pending), needs, oldest))
        else:
            for r in pending:
                print('\t'.join([r[3]] + [r[4].get(k, ('',))[0] for k in ('直したいこと', '対象', '区分')]))
        return 0
    if cmd == 'mark':
        if len(sys.argv) != 5 or sys.argv[3] not in ('done', 'skip') or not one(sys.argv[4]).strip():
            return 2
        with locked():
            lines, records = entries(read())
            for r in records:
                if r[3] == sys.argv[2] and '状態' in r[4]:
                    state = '対応済み' if sys.argv[3] == 'done' else '見送り'
                    lines[r[4]['状態'][1]] = '- 状態: {}（{} {}）\n'.format(state, datetime.now().strftime('%Y-%m-%d %H:%M'), one(sys.argv[4]))
                    save(''.join(lines))
                    return 0
        return 1
    p = argparse.ArgumentParser()
    for arg in ('source', 'title', 'diff-file'):
        p.add_argument('--' + arg, required=True)
    p.add_argument('--target', action='append', required=True)
    for arg in ('reason', 'section-file', 'kind-reason', 'check', 'slug'):
        p.add_argument('--' + arg, default='')
    p.add_argument('--id-prefix', default='会話')
    p.add_argument('--kind', choices=['直してよい', '要確認'])
    a = p.parse_args(sys.argv[2:])
    if not re.fullmatch(r'[A-Za-z0-9_-]+|会話', a.id_prefix) or any(not Path(t).is_absolute() for t in a.target):
        p.error('ID の接頭辞と対象の絶対パスを確認する')
    if not all(one(v).strip() for v in [a.source, a.title, *a.target]):
        p.error('出した元・直したいこと・対象は空にしない')
    diff = Path(a.diff_file).read_text(encoding='utf-8')
    section = Path(a.section_file).read_text(encoding='utf-8') if a.section_file else ''
    # 記録の境界と区別するため、付属の節の見出しは3段目以降にする。
    section = re.sub(r'^## ', '### ', section, flags=re.M)
    fence = '```'
    while re.search(r'^ {0,3}' + fence, diff, flags=re.M):
        fence += '`'
    kind = a.kind or ('要確認' if a.id_prefix == '会話' else '直してよい')
    if a.kind_reason:
        kind = '要確認'
    if kind == '要確認':
        kind += '（' + one(a.kind_reason or '会話で利用者に示して承認を受ける') + '）'
    with locked():
        text = read() or INTRO
        _, records = entries(text)
        now = datetime.now()
        day = now.strftime('%Y-%m-%d')
        n = max([int(r[3].rsplit('-', 1)[-1]) for r in records if r[2].startswith(day) and re.search(r'-\d{2}$', r[3])] or [0]) + 1
        if n > 99:
            raise ValueError('同じ日の連番が99を超える')
        stamp = day if a.id_prefix == '会話' else now.strftime('%Y-%m-%d-%H%M%S')
        cid = '{}-{}-{:02d}'.format(a.id_prefix, stamp, n)
        body = '\n\n## {} {}\n\n'.format(now.strftime('%Y-%m-%d %H:%M'), cid)
        for key, value in [('出した元', a.source), ('状態', '未対応'), ('区分', kind), ('対象', '・'.join('`' + one(t) + '`' for t in a.target)), ('直したいこと', a.title), ('理由', a.reason or '記載なし')]:
            body += '- {}: {}\n'.format(key, one(value))
        if section:
            body += '\n' + section.rstrip() + '\n'
        body += '\n' + fence + 'diff\n' + diff.rstrip('\n') + '\n' + fence + '\n'
        save(text.rstrip('\n') + body)
    print(cid)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError) as e:
        print('ERROR: ' + str(e), file=sys.stderr)
        sys.exit(1)
