"""Report assignments inside a function whose name appears once in that function.

A single appearance means the value is computed and never read. Keyword
arguments, names starting with '_' or a capital, and one-letter loop names are
skipped. This is a review list: a name reused by nesting or string
interpolation can be missed, and a name used only to build a returned tuple
counts as used.
"""
import os
import re

ROOTS = ["StructuralSizer/src", "StructuralSynthesizer/src", "external/Asap/src"]
ASSIGN = re.compile(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?!=)")
SKIP = set("nothing true false end i j k n m x y z a b c d e f t s v w h l r p q u".split())


def functions(lines):
    stack = []
    for i, ln in enumerate(lines):
        m = re.match(r"^(\s*)function\s", ln)
        if m and not ln.lstrip().startswith("#"):
            stack.append([len(m.group(1)), i])
        if stack and re.match(r"^\s*end\s*(#.*)?$", ln):
            ind = len(re.match(r"^(\s*)", ln).group(1))
            if ind == stack[-1][0]:
                start = stack.pop()[1]
                yield start, i


def main():
    n = 0
    for root in ROOTS:
        for dp, _, fs in os.walk(root):
            for f in fs:
                if not f.endswith(".jl"):
                    continue
                path = os.path.join(dp, f)
                lines = open(path, errors="replace").read().splitlines()
                for start, stop in functions(lines):
                    body = lines[start + 1:stop]
                    names = {}
                    for off, ln in enumerate(body):
                        m = ASSIGN.match(ln)
                        if not m or ln.lstrip().startswith("#"):
                            continue
                        name = m.group(2)
                        if name in SKIP or name.startswith("_") or name[:1].isupper():
                            continue
                        names.setdefault(name, start + 2 + off)
                    text = "\n".join(body)
                    for name, line in names.items():
                        if len(re.findall(r"\b" + name + r"\b", text)) == 1:
                            print(f"{path}:{line}  {name}")
                            n += 1
    print(f"total {n}")


if __name__ == "__main__":
    main()
