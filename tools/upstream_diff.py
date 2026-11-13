#!/usr/bin/env python3
"""What changed upstream between two commits, sorted by what it means for p8p8.

    python3 tools/upstream_diff.py --src <prog8 checkout> [--from COMMIT] [--to REV]

--src   a git checkout of Prog8 (default: the environment variable PROG8_SRC)
--from  the commit p8p8 follows now (default: the one lib/VERSION names)
--to    the commit to look at (default: HEAD of the checkout)
--full  do not shorten the diffs that are shown

Most of what changes upstream does not concern p8p8: its optimizer, its 6502
code generator, the virtual machine, the language server.  This lists the
changed files under the few headings that do, and shows the diff where the
file is small and every line matters (the grammar, the builtin functions, the
command line).  It reads the checkout and changes nothing.

docs/UPSTREAM.md says what to do with what it prints.
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (heading, what detects a change of this kind in p8p8, path prefixes, show the diff?)
AREAS = [
    ("The grammar",
     "make programs, roundtrip and corpus load upstream's examples and tests; new syntax fails there",
     ["parser/src/main/antlr/"], True),
    ("Builtin functions",
     "NOTHING automatic: a new or changed builtin shows only when a program uses it "
     "(src/symtab.p8, typer.p8, checker.p8, irgen.p8)",
     ["codeCore/src/prog8/code/core/BuiltinFunctions.kt",
      "compiler/src/prog8/compiler/BuiltinFunctions.kt"], True),
    ("The command line",
     "NOTHING automatic: compare with the options in src/main.p8, the README and docs/DIFFERENCES.md",
     ["compiler/src/prog8/CompilerMain.kt"], True),
    ("The library",
     "tools/check_overrides.py in the library repository, for the files it replaces; "
     "then the comparison suites",
     ["compiler/res/prog8lib/"], False),
    ("The IR",
     "make vmcmp: p8p8's IR runs in upstream's virtual machine",
     ["intermediate/src/"], False),
    ("Checks, errors and warnings",
     "tools/checkprobe.py; the messages that were added or removed are listed below",
     ["compiler/src/prog8/compiler/astprocessing/", "compilerAst/src/"], False),
    ("Targets and encodings",
     "the target files of the library; tools/gen_enctables.py for the encodings",
     ["codeCore/src/prog8/code/target/"], False),
    ("Examples and compiler tests",
     "python3 setup.py fetches them; make programs, corpus, buildall and the comparison suites use them",
     ["examples/", "compiler/test/"], False),
    ("The documentation",
     "read what changed: it is where a new feature is described",
     ["docs/source/"], False),
]

# changed, and of no concern here beyond the count
QUIET = [
    ("the 6502 code generators", ["codeGenCpu6502/", "codeGenNew6502/"]),
    ("the other code generators", ["codeGenM68k/", "codeGenIntermediate/", "codeGenLlvm/"]),
    ("the optimizer", ["codeOptimizers/"]),
    ("the virtual machine", ["virtualmachine/"]),
    ("the language server and editor files", ["languageServer/", "syntax-files/"]),
]


def git(src, *args):
    result = subprocess.run(["git", "-C", src] + list(args), capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit("git %s failed:\n%s" % (" ".join(args), result.stderr.strip()))
    return result.stdout


def followed_commit():
    """The upstream commit that the library's VERSION file names."""
    path = os.path.join(HERE, "lib", "VERSION")
    try:
        text = open(path).read()
    except OSError:
        return None
    found = re.search(r"\b([0-9a-f]{40})\b", text)
    return found.group(1) if found else None


def overlaid(name):
    """Does the library replace this file of prog8lib with one of its own?"""
    lib = os.path.join(HERE, "lib")
    rest = name[len("compiler/res/prog8lib/"):]
    parts = rest.split("/")
    if len(parts) == 1:
        return os.path.exists(os.path.join(lib, "common", parts[0]))
    return os.path.exists(os.path.join(lib, "targets", parts[0], *parts[1:]))


def shortened(text, full, limit=120):
    lines = text.rstrip("\n").split("\n")
    if full or len(lines) <= limit:
        return lines
    return lines[:limit] + ["... (%d more lines: --full shows them)" % (len(lines) - limit)]


def messages(src, old, new, paths):
    """The error and warning texts that the diff adds and removes."""
    diff = git(src, "diff", "--unified=0", old, new, "--", *paths)
    added, removed = [], []
    for line in diff.split("\n"):
        if line.startswith(("+++", "---")):
            continue
        found = re.search(r'\.(err|warn|info|undefined)\(\s*"((?:[^"\\]|\\.)*)"', line)
        if not found:
            continue
        text = "%s: %s" % (found.group(1), found.group(2))
        if line.startswith("+"):
            added.append(text)
        elif line.startswith("-"):
            removed.append(text)
    # a message that only moved is in both
    return ([m for m in added if m not in removed], [m for m in removed if m not in added])


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--src", default=os.environ.get("PROG8_SRC"))
    parser.add_argument("--from", dest="old", default=None)
    parser.add_argument("--to", dest="new", default="HEAD")
    parser.add_argument("--full", action="store_true")
    args = parser.parse_args()
    if not args.src:
        sys.exit("where is the checkout of Prog8?  --src <directory>, or set PROG8_SRC")
    old = args.old or followed_commit()
    if not old:
        sys.exit("which commit does p8p8 follow?  --from <commit> (lib/VERSION does not say)")
    src = args.src
    old_id = git(src, "rev-parse", "--short=10", old).strip()
    new_id = git(src, "rev-parse", "--short=10", args.new).strip()
    commits = [c for c in git(src, "log", "--oneline", "--no-merges", "%s..%s" % (old, args.new)).split("\n") if c]
    print("Upstream from %s to %s: %d commits" % (old_id, new_id, len(commits)))
    if old_id == new_id or not commits:
        print("nothing to look at")
        return
    status = {}
    for line in git(src, "diff", "--name-status", "--no-renames", old, args.new).split("\n"):
        if line:
            kind, name = line.split("\t", 1)
            status[name] = kind
    seen = set()
    for heading, detector, prefixes, show in AREAS:
        names = sorted(n for n in status if any(n.startswith(p) for p in prefixes))
        seen.update(names)
        print()
        print("== %s: %s" % (heading, "%d files" % len(names) if names else "no change"))
        if not names:
            continue
        print("   (%s)" % detector)
        added = [n for n in names if status[n] == "A"]
        removed = [n for n in names if status[n] == "D"]
        changed = [n for n in names if status[n] not in "AD"]
        if heading == "Examples and compiler tests":
            # only what comes and goes: every file that changed is run anyway
            print("   %d changed" % len(changed))
            changed = []
        for label, group in (("new", added), ("gone", removed), ("changed", changed)):
            for name in group:
                note = ""
                if heading == "The library" and overlaid(name):
                    note = "   <-- the library has its own copy of this file"
                print("   %-8s %s%s" % (label, name, note))
        if show:
            for name in names:
                print()
                for line in shortened(git(src, "diff", "--unified=2", old, args.new, "--", name), args.full):
                    print("   | " + line)
        if heading == "Checks, errors and warnings":
            plus, minus = messages(src, old, args.new, prefixes)
            for text in plus:
                print("   + " + text)
            for text in minus:
                print("   - " + text)
            if not plus and not minus:
                print("   no message was added or removed")
    print()
    print("== Changed, and not p8p8's concern")
    for label, prefixes in QUIET:
        names = [n for n in status if any(n.startswith(p) for p in prefixes)]
        seen.update(names)
        if names:
            print("   %-40s %d files" % (label, len(names)))
    rest = sorted(n for n in status if n not in seen)
    if rest:
        print()
        print("== Everything else: %d files" % len(rest))
        tops = {}
        for name in rest:
            top = name.split("/")[0]
            tops[top] = tops.get(top, 0) + 1
        for top in sorted(tops):
            print("   %-40s %d" % (top, tops[top]))
    print()
    print("== The commits")
    for line in shortened("\n".join(commits), args.full, 60):
        print("   " + line)


if __name__ == "__main__":
    main()
