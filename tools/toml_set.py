#!/usr/bin/env python3
"""Cambia valores en un archivo TOML conservando comentarios y formato.

Uso:  toml_set.py ARCHIVO 'JSON'      (o  ... | toml_set.py ARCHIVO -  para leer el JSON de stdin)
  JSON = {"<seccion>": {"CLAVE": valor, ...}, ...}
  - seccion "" = claves de primer nivel (antes de la primera [seccion]).
  - seccion "*" = la clave se sustituye en CUALQUIER sección donde exista.
  - valor: bool, número, texto o lista de textos.
Sólo se sustituye el valor de claves que YA existen (descomentadas) en esa sección.
Si una clave no existe, se avisa por stderr y el código de salida es 3 (salvo --lenient).
No imprime los valores (pueden ser secretos), sólo los nombres de las claves.
"""
import json
import re
import sys

SECTION_RE = re.compile(r"^\s*\[([^\[\]]+)\]\s*$")
KEY_RE = re.compile(r"^(\s*)([A-Za-z0-9_.\-]+)(\s*=\s*)(.*?)\s*$")


def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def fmt(old_rhs, value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    quote = '"""' if old_rhs.startswith('"""') else '"'
    if isinstance(value, list):
        return "[" + ", ".join(quote + esc(str(v)) + quote for v in value) + "]"
    return quote + esc(str(value)) + quote


def main():
    args = [a for a in sys.argv[1:] if a != "--lenient"]
    lenient = "--lenient" in sys.argv
    if len(args) != 2:
        sys.exit(__doc__)
    path = args[0]
    spec = json.loads(sys.stdin.read() if args[1] == "-" else args[1])   # "-" = JSON por stdin (evita secretos en argv)
    pending = {(s, k) for s, kv in spec.items() for k in kv}
    out, section = [], ""
    with open(path) as fh:
        lines = fh.read().splitlines()
    for raw in lines:
        stripped = raw.lstrip()
        if not stripped.startswith("#"):
            m = SECTION_RE.match(raw)
            if m:
                section = m.group(1).strip()
                out.append(raw)
                continue
            m = KEY_RE.match(raw)
            if m:
                key = m.group(2)
                for sec_name in (section, "*"):
                    if sec_name in spec and key in spec[sec_name]:
                        raw = m.group(1) + key + m.group(3) + fmt(m.group(4), spec[sec_name][key])
                        pending.discard((sec_name, key))
                        break
        out.append(raw)
    with open(path, "w") as fh:
        fh.write("\n".join(out) + "\n")
    if pending:
        for s, k in sorted(pending):
            print("AVISO: clave no encontrada en %s: [%s] %s" % (path, s or "<raíz>", k), file=sys.stderr)
        if not lenient:
            sys.exit(3)


if __name__ == "__main__":
    main()
