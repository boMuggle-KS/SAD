import zipfile, os

EXCLUDE_DIRS = {'.git', '.claude', 'control-app', '.github', 'webroot'}
files = []
for root, dirs, names in os.walk('.'):
    dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
    for n in names:
        if n.startswith('.') or n.endswith('.zip') or n.endswith('.py'):
            continue
        p = os.path.join(root, n)
        rel = os.path.relpath(p, '.').replace(os.sep, '/')
        files.append(rel)
files.sort()
version = 'unknown'
with open('module.prop', 'r', encoding='utf-8') as mp:
    for line in mp:
        if line.startswith('version='):
            version = line.split('=', 1)[1].strip()
            break
out = f'SAD-v{version}.zip'
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for f in files:
        z.write(f, f)
print(len(files), 'entries written to', out)
for f in files:
    print(f)
