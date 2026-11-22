"""Check that docs' links to line ranges of .tf files still point at what they name.

A link like [`StudioNeverWrites`](../modules/temperwork/main.tf#L273-L287)
passes when the linked lines contain the link's text (backticks dropped, or
its first word for prose like "`studio` policy document"). Run from the
repository root.
"""
import pathlib
import re
import sys

LINK = re.compile(r'\[([^\]]+)\]\(([^)#\s]+\.tf)#L(\d+)(?:-L(\d+))?\)')
bad = 0
for doc in pathlib.Path('.').rglob('*.md'):
    if '.terraform' in doc.parts:
        continue
    for text, target, start, end in LINK.findall(doc.read_text()):
        path = (doc.parent / target).resolve()
        lines = path.read_text().splitlines()[int(start) - 1:int(end or start)]
        name = re.findall(r'`([^`]+)`', text)
        want = name[0] if name else text.split()[0]
        if not any(want in line for line in lines):
            print(f'{doc}: [{text}] -> {target}#L{start}-L{end or start} no longer contains {want!r}')
            bad += 1
sys.exit(1 if bad else 0)
