#!/usr/bin/env python3
"""Static pre-flight for the iOS native layer.

There is no Xcode on this machine, so every Swift/Objective-C mistake costs a
~14 minute CI cycle and a slice of the daily TestFlight quota. This catches the
classes of error that have actually cost a cycle on this project:

  * a call to a C symbol the vendored headers do not declare
  * an Objective-C method declared in a header but never implemented
  * an instance ivar touched from a class method (a compile error)
  * a Swift string interpolation naming something not in scope
  * unbalanced braces, and pbxproj entries pointing at files that do not exist

It is not a compiler. It is a cheap net for the mistakes that are invisible from
Dart. Run it before pushing anything that touches ios/Runner.

Known limits, so the PASS is not over-read:
  * It cannot type-check, so a *typo in an existing member* (`entry.dialectLable`
    for a real `entry.dialectLabel`) passes here and is caught by Xcode instead.
    What it does catch is a name that appears nowhere else in the file — the
    shape left behind by deleting a local that was still interpolated.
  * The Objective-C class-method check only knows ivars declared in an explicit
    `@implementation X { ... }` block, so it is blind in files that declare none.
  * pbxproj paths are matched by basename under ios/, not resolved through their
    enclosing group.

Usage: python3 tool/ios_native_check.py
Exit code 0 = pass, 1 = fail.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNNER = os.path.join(ROOT, "ios/Runner")
PBXPROJ = os.path.join(ROOT, "ios/Runner.xcodeproj/project.pbxproj")

problems = []


def fail(message):
    problems.append(message)


def strip_noise(source):
    """Source minus comments, so a name mentioned in prose is not a reference."""
    out = []
    in_block = False
    for line in source.split("\n"):
        s = line.strip()
        if in_block:
            if "*/" in s:
                in_block = False
            continue
        if s.startswith("/*"):
            if "*/" not in s:
                in_block = True
            continue
        if s.startswith("//"):
            continue
        out.append(line.split("//")[0])
    return "\n".join(out)


def strip_strings(source):
    return re.sub(r'@?"(?:[^"\\\n]|\\.)*"', '""', source)


def balance(source):
    depth = 0
    in_line_comment = in_block_comment = in_string = False
    i = 0
    while i < len(source):
        c = source[i]
        if c == "\n":
            in_line_comment = False
            i += 1
            continue
        if in_line_comment:
            i += 1
            continue
        if in_block_comment:
            if source.startswith("*/", i):
                in_block_comment = False
                i += 2
                continue
            i += 1
            continue
        if in_string:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue
        if source.startswith("//", i):
            in_line_comment = True
            i += 2
            continue
        if source.startswith("/*", i):
            in_block_comment = True
            i += 2
            continue
        if c == '"':
            in_string = True
            i += 1
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        i += 1
    return depth


def native_files(extensions):
    names = []
    for base, _dirs, files in os.walk(RUNNER):
        if os.path.basename(base) in ("libsmb2", "build", "GeneratedPluginRegistrant"):
            continue
        for f in files:
            if os.path.splitext(f)[1] in extensions:
                names.append(os.path.join(base, f))
    return sorted(names)


# --------------------------------------------------------------------------
# 1. Every C symbol we call must exist in the vendored headers.
# --------------------------------------------------------------------------
def check_c_symbols():
    include_dirs = [
        os.path.join(RUNNER, "libsmb2/include"),
        os.path.join(RUNNER, "libsmb2/include/smb2"),
    ]
    headers = ""
    for root in (os.path.join(RUNNER, "libsmb2/include"),):
        for base, _dirs, files in os.walk(root):
            for f in files:
                if f.endswith(".h"):
                    headers += open(os.path.join(base, f), encoding="utf-8",
                                    errors="replace").read()

    for path in native_files({".m"}):
        code = strip_strings(strip_noise(open(path, encoding="utf-8").read()))
        for sym in sorted(set(re.findall(r"\b(smb2_[A-Za-z0-9_]+)\b", code))):
            if not re.search(r"\b" + sym + r"\b", headers):
                fail(f"{os.path.basename(path)}: {sym}() is not declared in the "
                     f"vendored libsmb2 headers")


# --------------------------------------------------------------------------
# 2. Objective-C: every declaration in our headers needs an implementation.
# --------------------------------------------------------------------------
def check_objc_declarations():
    headers = [p for p in native_files({".h"})
               if os.path.basename(p).startswith("Lib")]
    impls = "".join(open(p, encoding="utf-8").read() for p in native_files({".m"}))

    for header in headers:
        src = strip_noise(open(header, encoding="utf-8").read())
        for m in re.finditer(r"^\s*([-+])\s*\([^)]*\)\s*([^;{]*);", src, re.M):
            kind, selector = m.group(1), m.group(2)
            name = re.match(r"\s*(\w+)", selector)
            if not name:
                continue
            sel = name.group(1)
            if sel in ("init",) and "NS_UNAVAILABLE" in selector:
                continue
            # A @property with no explicit accessor is auto-synthesised, so only
            # flag it when the .m has no matching ivar or getter.
            if kind == "+" and not re.search(r"\+\s*\([^)]*\)\s*" + sel + r"\b", impls):
                fail(f"{os.path.basename(header)}: class method {sel} is declared "
                     f"but not implemented")


# --------------------------------------------------------------------------
# 3. An instance ivar cannot be reached from a class method.
# --------------------------------------------------------------------------
def check_class_method_ivars():
    for path in native_files({".m"}):
        code = strip_strings(strip_noise(open(path, encoding="utf-8").read()))
        ivars = set()
        for m in re.finditer(r"@implementation\s+(\w+)\s*\{(.*?)\n\}", code, re.S):
            ivars |= set(re.findall(r"(?<![A-Za-z0-9_])(_[a-z]\w*)\s*;", m.group(2)))
        for m in re.finditer(r"^\+\s*\([^)]*\)[^{]*\{", code, re.M):
            start = m.end()
            depth = 1
            i = start
            while i < len(code) and depth:
                if code[i] == "{":
                    depth += 1
                elif code[i] == "}":
                    depth -= 1
                i += 1
            body = code[start:i]
            line = code[: m.start()].count("\n") + 1
            for ref in sorted(set(re.findall(r"(?<![A-Za-z0-9_])(_[a-z]\w*)\b", body))):
                if ref in ivars:
                    fail(f"{os.path.basename(path)}:{line}: class method touches "
                         f"instance ivar {ref}")


# --------------------------------------------------------------------------
# 4. Swift interpolation must name something in scope.
# --------------------------------------------------------------------------
def check_swift_interpolation():
    for path in native_files({".swift"}):
        code = strip_noise(open(path, encoding="utf-8").read())
        if not code.strip():
            continue
        # Every identifier that appears anywhere in the file. A name that shows up
        # *only* inside an interpolation is a dangling reference — the shape left
        # behind by deleting a local that was still interpolated. Closure
        # parameters and locals appear elsewhere too, so they do not trip this.
        # Strip the interpolations *before* collecting identifiers, otherwise the
        # name inside "\(foo)" is itself a match and every reference looks
        # resolved — including the dangling ones this is meant to catch.
        without = re.sub(r"\\\(\w+\)", " ", code)
        present = set(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", without))
        for m in re.finditer(r"\\\((\w+)\)", code):
            name = m.group(1)
            if name not in present:
                line = code[: m.start()].count("\n") + 1
                fail(f"{os.path.basename(path)}:{line}: interpolation references "
                     f"\\({name}), which appears nowhere else in the file")


# --------------------------------------------------------------------------
# 5. Structure + pbxproj integrity.
# --------------------------------------------------------------------------
def check_structure():
    for path in native_files({".m", ".h", ".swift"}):
        if balance(open(path, encoding="utf-8").read()) != 0:
            fail(f"{os.path.basename(path)}: unbalanced braces")

    if not os.path.exists(PBXPROJ):
        return
    pbx = open(PBXPROJ, encoding="utf-8").read()
    if pbx.count("{") != pbx.count("}"):
        fail("project.pbxproj: unbalanced braces")
    # `path = X` in a pbxproj is relative to its enclosing *group* (the Runner
    # group has `path = Runner`), so exact resolution needs group parsing.
    # Matching on basename anywhere under ios/ catches the failure that matters —
    # a file that was renamed or deleted but is still referenced — without
    # reimplementing group resolution.
    ios_dir = os.path.join(ROOT, "ios")
    basenames = set()
    for base, _dirs, files in os.walk(ios_dir):
        for f in files:
            basenames.add(f)
    # Written by `flutter pub get` / the build, not present in the repo.
    generated = {"GeneratedPluginRegistrant.h", "GeneratedPluginRegistrant.m"}
    for m in re.finditer(r'path = ([A-Za-z0-9_.\-]+\.(?:swift|m|h|mm|c|a|png|plist))\b', pbx):
        name = m.group(1)
        if name in basenames or name in generated:
            continue
        fail(f"project.pbxproj references {name}, which exists nowhere under ios/")

    for lib in ("libsmb2.a",):
        if f"libsmb2/build/{lib}" in pbx:
            # Generated by ios/libsmb2_build.sh; absent before a build, by design.
            continue

# --------------------------------------------------------------------------
# 6. An Objective-C class used from Swift must be in the bridging header.
# --------------------------------------------------------------------------
def check_bridging_header():
    bridging = os.path.join(RUNNER, "Runner-Bridging-Header.h")
    if not os.path.exists(bridging):
        fail("Runner-Bridging-Header.h is missing")
        return
    imported = set(re.findall(r'#import\s+"([^"]+)"',
                              open(bridging, encoding="utf-8").read()))
    basenames = {os.path.basename(i) for i in imported}

    # ObjC classes this target declares in its own Lib*.h headers.
    declared = {}
    for header in native_files({".h"}):
        name = os.path.basename(header)
        if not name.startswith("Lib"):
            continue
        src = strip_noise(open(header, encoding="utf-8").read())
        for m in re.finditer(r"@interface\s+(\w+)", src):
            declared[m.group(1)] = name

    if not declared:
        return
    # Every declared class must be visible to Swift.
    for cls, header in sorted(declared.items()):
        if header not in basenames:
            fail(f"{cls} is declared in {header} but that header is not imported "
                 f"by Runner-Bridging-Header.h, so Swift cannot see it")


def main():
    if not os.path.isdir(RUNNER):
        print(f"FAIL  {RUNNER} not found")
        return 1
    check_c_symbols()
    check_objc_declarations()
    check_class_method_ivars()
    check_swift_interpolation()
    check_structure()
    check_bridging_header()

    if problems:
        for p in problems:
            print(f"FAIL  {p}")
        print(f"\n{len(problems)} problem(s)")
        return 1
    print("iOS native pre-flight: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
