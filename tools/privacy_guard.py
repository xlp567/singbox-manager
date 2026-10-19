#!/usr/bin/env python3
"""Fail closed before publishing. Diagnostics contain paths/categories, never values."""
import argparse
import base64
import io
import ipaddress
import json
import pathlib
import re
import sys
import zipfile

V4 = re.compile(r'(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])')
V6 = re.compile(r'(?<![\w:])(?:[0-9a-fA-F]{0,4}:){2,}[0-9a-fA-F:.]*(?![\w:])')
SECRET = re.compile(r'-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,}')
BUNDLE = re.compile(r"<<'SBM_BUNDLE'\n([A-Za-z0-9+/=\s]+)\nSBM_BUNDLE")
DOC_NETS = tuple(ipaddress.ip_network(n) for n in ('192.0.2.0/24','198.51.100.0/24','203.0.113.0/24','2001:db8::/32'))
PUBLIC_HOSTS = ('anthropic.com','github.com','githubusercontent.com','githubassets.com','sagernet.org','sing-box.app','ipify.org','shields.io','json-schema.org','letsencrypt.org','example.com','example.org','example.net','example','invalid','test','localhost')
POLICY_NETWORKS={'224.0.0.0/4','ff00::/8','64:ff9b::/96','64:ff9b:1::/48','2002::/16','2001::/32'}
# Conservative bare-host detection complements structured fields and URLs.
# It deliberately does not treat Python attributes or arbitrary file suffixes
# as domains. Private identifiers remain necessary for uncommon/internal names.
BARE_HOST=re.compile(r'(?<![A-Za-z0-9_.-])(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+(?:com|net|org|io|cloud|me|xyz|cn|dev|app|top|cc|info|online|site|co|uk|de|jp|us|ru)(?![A-Za-z0-9_.-])',re.I)


def scan_text(path, text, private_values=(), depth=0):
    findings = []
    def add(line, category):
        findings.append({'path':path,'line':line,'category':category})
    normalized = re.sub(r'\\+\.', '.', text)
    for number, line in enumerate(normalized.splitlines(), 1):
        if SECRET.search(line): add(number, 'credential')
        for pattern in (V4, V6):
            for match in pattern.finditer(line):
                try: address = ipaddress.ip_address(match[0].rstrip('.'))
                except ValueError: continue
                suffix=re.match(r'/[0-9]{1,3}\b',line[match.end():])
                if suffix and str(address)+suffix[0] in POLICY_NETWORKS:continue
                if not address.is_global or any(address.version == net.version and address in net for net in DOC_NETS): continue
                add(number, 'public-server-address')
        if re.search(r'\bVM[0-9A-F]{8,}\b', line): add(number, 'deployment-hostname')
        if re.search(r'(?:\bssh\b[^\n]*\s-p\s*|\bscp\b[^\n]*\s-P\s*|SSH\s*(?:端口|port)\s*[:：=]?\s*)(?!22\b)[0-9]{2,5}\b', line, re.I):
            add(number, 'literal-ssh-port')
        if re.search(r'''["']ssh[_-]?port["']\s*:\s*(?!22\b)[0-9]{2,5}\b(?=\s*[,}]|\s*$)''', line, re.I):
            add(number, 'literal-ssh-port')
        for host in re.findall(r'''["'](?:server_name|hostname|server|host|target)["']\s*:\s*["']([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)["']''', line):
            if not V4.fullmatch(host) and not any(host == allowed or host.endswith('.'+allowed) for allowed in PUBLIC_HOSTS):
                add(number, 'unreviewed-node-host')
        for host in re.findall(r'https?://([A-Za-z0-9.-]+)', line):
            if not any(host == allowed or host.endswith('.'+allowed) for allowed in PUBLIC_HOSTS):
                try: ipaddress.ip_address(host)
                except ValueError: add(number, 'unreviewed-url-host')
        for match in BARE_HOST.finditer(line):
            host=match[0].lower()
            if line[match.end():].lstrip().startswith('('):continue
            if not any(host==allowed or host.endswith('.'+allowed) for allowed in PUBLIC_HOSTS):
                add(number,'unreviewed-bare-host')
        for value in private_values:
            literal = bool(re.search(r'(?<!\d)'+re.escape(value)+r'(?!\d)',line)) if value.isdigit() else value in line
            encoded = len(value) >= 8 and base64.b64encode(value.encode()).decode() in line
            if value and (literal or encoded):
                add(number, 'private-identifier')
    if re.search(r'^emit_engine\(\) \{\s+base64\b', text, re.M):
        matches = list(BUNDLE.finditer(text))
        if not matches or depth >= 2:
            add(1, 'invalid-embedded-bundle')
        else:
            for match in matches:
                try:
                    raw = base64.b64decode(re.sub(r'\s+', '', match[1]), validate=True)
                    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
                        if sum(item.file_size for item in archive.infolist()) > 8*1024*1024: raise ValueError('oversized')
                        for item in archive.infolist():
                            if item.is_dir(): continue
                            findings.extend(scan_text(path+'::'+item.filename, archive.read(item).decode(), private_values, depth+1))
                except (ValueError, UnicodeError, zipfile.BadZipFile): add(1, 'invalid-embedded-bundle')
    return findings


def check_manifest(files, private_values=()):
    findings = []
    for item in files:
        path = item['path']
        parts = pathlib.PurePosixPath(path).parts
        if not parts or path.startswith('/') or '..' in parts or any(p in parts for p in ('.cache','.git','dist','private','__pycache__')):
            findings.append({'path':path,'line':1,'category':'private-or-invalid-path'})
        if pathlib.PurePosixPath(path).suffix.lower() in ('.gz','.zip','.tar','.key','.pem','.p12'):
            findings.append({'path':path,'line':1,'category':'unreviewed-archive-or-key'})
        findings.extend(scan_text(path, item['content'], private_values))
    return findings


def private_values(root):
    file = root/'.cache/private-identifiers.json'
    if not file.exists(): return []
    values = json.loads(file.read_text())
    if not isinstance(values, list) or not all(isinstance(v,str) and v for v in values): raise ValueError('invalid private identifier list')
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=pathlib.Path)
    args = parser.parse_args()
    files = json.loads(args.manifest.read_text())
    findings = check_manifest(files, private_values(pathlib.Path(__file__).resolve().parents[1]))
    if findings:
        print(json.dumps({'privacy':'FAIL','findings':findings},ensure_ascii=False,indent=2))
        return 1
    print(f'PASS privacy guard: {len(files)} publishable files, including embedded Python bundles')
    return 0


if __name__ == '__main__': sys.exit(main())
