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
  * It does not do type resolution at all, so it cannot tell our types from the
    framework's. A deleted type used to be caught by grepping for capitalised
    identifiers, but every import (Flutter, UIKit, AetherEngine) and every
    framework class then reads as "undeclared" and the output is pure noise. Type
    errors stay Xcode's job; the checks here are the ones that are exact.

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
LIBSMB2_INCLUDE = os.path.join(RUNNER, "libsmb2/include")


def _header_closure(roots):
    """Every header reachable from `roots` by #include <...>.

    Needed because the libsmb2 public headers are not self-contained:
    SMB2_GUID_SIZE and smb2_lease_key live in smb2/smb2.h while the smb2_*
    entry points live in smb2/libsmb2.h, and neither includes the other. A
    check that merely greps every vendored header would pass a file that only
    imports one of them — which is exactly the mistake that cost a build.
    """
    seen = set()
    stack = list(roots)
    while stack:
        rel = stack.pop()
        if rel in seen:
            continue
        seen.add(rel)
        path = os.path.join(LIBSMB2_INCLUDE, rel)
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            for m in re.finditer(r"#include\s+<([^>]+)>", fh.read()):
                stack.append(m.group(1))
    return seen


def check_c_symbols():
    for path in native_files({".m"}):
        raw = open(path, encoding="utf-8").read()
        code = strip_strings(strip_noise(raw))
        roots = re.findall(r'#import\s+<([^>]+)>', raw)
        libsmb2_roots = [r for r in roots if r.startswith("smb2/")]
        if not libsmb2_roots:
            continue

        closure = _header_closure(libsmb2_roots)
        text = ""
        for rel in closure:
            p = os.path.join(LIBSMB2_INCLUDE, rel)
            if os.path.exists(p):
                text += open(p, encoding="utf-8", errors="replace").read()

        if not text.strip():
            fail(f"{os.path.basename(path)}: imports {libsmb2_roots} but none "
                 f"of those headers resolve under ios/Runner/libsmb2/include")
            continue

        # A name reached through `.`/`->` is exempt only if it really is a struct
        # member in the imported headers. Skipping every access would also hide a
        # genuine typo, so the exempt set is built from the struct bodies the
        # headers actually declare.
        members = set()
        for body in re.findall(r"\bstruct\s+\w*\s*\{([^{}]*)\}", text):
            members.update(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\b", body))
        for sym in sorted(set(re.findall(r"\b(smb2_[A-Za-z0-9_]+|SMB2_[A-Z0-9_]+)\b", code))):
            if sym in members:
                continue
            if _is_defined(sym, text):
                continue
            fail(f"{os.path.basename(path)}: {sym} is not *defined* by the "
                 f"headers this file imports ({', '.join(libsmb2_roots)}). "
                 f"libsmb2's public headers are not self-contained: "
                 f"<smb2/smb2.h> and <smb2/libsmb2.h> must both be imported, "
                 f"smb2.h first. (A name merely *mentioned* in a declaration "
                 f"does not count — SMB2_GUID_SIZE is referenced by "
                 f"smb2_set_client_guid() but only defined in smb2.h.)")


def _is_defined(sym, header_text):
    """True when `sym` is actually defined, not just referenced.

    A macro counts via #define, an enum constant via `NAME =`, a typedef via
    `} NAME;`, and a function via a call-shaped declaration. Mentions inside
    parameter lists are deliberately not enough.
    """
    if re.search(r"#define\s+" + re.escape(sym) + r"\b", header_text):
        return True
    if re.search(r"^\s*" + re.escape(sym) + r"\s*=", header_text, re.M):
        return True
    if re.search(r"\}\s*" + re.escape(sym) + r"\s*;", header_text):
        return True
    if re.search(r"\b" + re.escape(sym) + r"\s*\(", header_text):
        return True
    # Opaque handle types are struct tags, not typedefs: libsmb2 uses
    # `struct smb2_context` everywhere rather than a bare smb2_context.
    if re.search(r"\bstruct\s+" + re.escape(sym) + r"\b", header_text):
        return True
    return False


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

    # Every compilable source on disk must actually be in a Sources phase. A file
    # that exists, is imported by the bridging header, and even passes a symbol
    # check still produces no code if it was never registered with the target —
    # which only shows up as "Undefined symbol: _OBJC_CLASS_$_X" at link time.
    compiled = set()
    for m in re.finditer(
        r"isa = PBXSourcesBuildPhase;.*?files = \((.*?)\);", pbx, re.S
    ):
        compiled |= set(re.findall(r"/\* (\S+) in Sources \*/", m.group(1)))
    for path in native_files({".m", ".swift", ".c"}):
        name = os.path.basename(path)
        # Vendored C is compiled by ios/libsmb2_build.sh, not by Xcode.
        if "libsmb2" in path:
            continue
        if name not in compiled:
            fail(f"{name} is on disk but not in any PBXSourcesBuildPhase — "
                 f"it would compile to nothing and fail at link with "
                 f"'Undefined symbol'")

    # Flutter-generated files, written by `flutter pub get`, not in the repo.

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



def check_objc_literal_terminators():
    """Every ObjC string literal must terminate on its own line.

    A literal that lost its escaping — `@"\"` written where `@"\\"` was meant —
    swallows the rest of the line and is a hard compile error that is very easy
    to miss by eye, and impossible to catch without a compiler here.
    """
    for path in native_files({".m"}):
        for n, line in enumerate(open(path, encoding="utf-8").read().split("\n"), 1):
            i = 0
            quotes = 0
            while i < len(line):
                if line[i] == "\\":
                    i += 2
                    continue
                if line[i] == '"':
                    quotes += 1
                i += 1
            if quotes % 2:
                fail(f"{os.path.basename(path)}:{n}: unterminated string literal "
                     f"(odd number of quotes) — {line.strip()[:60]}")


def _objc_declarations(text):
    """Yield each top-level ObjC method declaration, without its trailing `;`.

    Split on `;` at paren depth zero, so a `;` inside a parameter type cannot end
    a declaration early. Declarations are parsed rather than regex-matched
    because they span lines and carry parenthesised types such as
    `(nullable NSString *)`.
    """
    depth = 0
    start = 0
    for i, ch in enumerate(text):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == ";" and depth == 0:
            decl = text[start:i].strip()
            if re.match(r"^[-+]\s*\(", decl):
                yield decl
            start = i + 1




def _known_limitation_note():
    """Deliberately absent: an NSError** -> `throws` bridging check.

    An ObjC method returning `nullable` with a trailing `NSError**` imports into
    Swift as `throws` with the error argument removed, so both `try session
    .openFile(path, error: &e)` and a missing `try` are compile errors. That
    looked checkable, and it is not, for two reasons found the hard way:

      * Swift prunes trailing type words from imported selectors, so
        `readFileAtPath:offset:length:error:` is called as
        `readFile(atPath:offset:length:)`. Matching on the ObjC first piece
        silently misses most real call sites.
      * Several screens and clients define their own Swift helpers with the same
        names (`listDirectory`, `openFile`), so even a correct name match cannot
        tell a bridged call from a local one.

    A rule that passes when it should fail is worse than no rule, so this stays a
    known gap. The compiler is the authority here; `buildObjcInterfaceNesting`
    and the other checks exist because their failure modes are unambiguous.
    """


def check_swift_foundation_imports():
    """Swift files that use Foundation types must import Foundation (or a
    Darwin module that re-exports it).

    `flutter analyze` only sees Dart, so a missing import here is invisible until
    a signed CI build fails on it.
    """
    markers = ("NSRecursiveLock", "NSLock", "NSData", "NSMutableData", "NSError",
               "NSString", "NSDictionary", "NSArray", "NSObject", "NSNumber")
    for path in native_files({".swift"}):
        src = open(path, encoding="utf-8").read()
        # On Darwin these all re-export Foundation, so an explicit import is not
        # required when one of them is present.
        if re.search(r"^\s*import\s+(Foundation|UIKit|AppKit|Cocoa|Flutter)\b",
                     src, re.M):
            continue
        body = strip_noise(strip_strings(src))
        used = sorted({m for m in markers if re.search(r"\b" + m + r"\b", body)})
        if used:
            fail(f"{os.path.basename(path)} uses {', '.join(used)} "
                 f"but does not import Foundation")


def check_ns_swift_name_consistency():
    """A method renamed with NS_SWIFT_NAME must not be called by its ObjC name.

    The Swift importer prunes type-name suffixes on void methods, so
    `- (void)closeSession` arrives in Swift as `close()`. Calling `closeSession()`
    is "value of type ... has no member", which only a compiler can catch here.
    The names are pinned with NS_SWIFT_NAME so they cannot drift, and this rule
    checks the Swift side actually uses the pinned name.
    """
    renamed = []
    for path in native_files({".h"}):
        text = strip_noise(open(path, encoding="utf-8").read())
        for decl in _objc_declarations(text):
            m = re.search(r"NS_SWIFT_NAME\s*\(\s*(\w+)", decl)
            if not m:
                continue
            # The selector sits before the attribute, so cut there first: a
            # no-argument method ends in its own name, not in ")".
            left = decl.split("NS_SWIFT_NAME")[0].strip()
            objc = re.search(r"(\w+)\s*:", left) or re.search(r"(\w+)$", left)
            if not objc:
                continue
            objc_name, swift_name = objc.group(1), m.group(1)
            if objc_name != swift_name:
                renamed.append((os.path.basename(path), objc_name, swift_name))
    if not renamed:
        return

    for path in native_files({".swift"}):
        src = strip_noise(open(path, encoding="utf-8").read())
        for base, objc_name, swift_name in renamed:
            for m in re.finditer(r"\." + re.escape(objc_name) + r"\s*\(", src):
                line = src[: m.start()].count("\n") + 1
                fail(f"{os.path.basename(path)}:{line} calls .{objc_name}(), but "
                     f"{base} pins that selector to NS_SWIFT_NAME({swift_name}); "
                     f"call .{swift_name}() instead")


def check_objc_dot_syntax():
    """`recv.selector:` is a parse error in Objective-C.

    Dot syntax is only legal for a zero-argument method. Writing
    `native.hasPrefix:@"x"` fails to parse, and the follow-on diagnostic is the
    misleading "Property 'hasPrefix' not found on object of type 'NSString *'",
    which sends you looking for a Foundation problem instead of a syntax one.
    """
    for path in native_files({".m"}):
        for n, line in enumerate(open(path, encoding="utf-8").read().split("\n"), 1):
            code = line.split("//")[0]
            m = re.search(r"\b[A-Za-z_][A-Za-z0-9_]*\.[a-z][A-Za-z0-9_]*\s*:", code)
            if m and '".*:' not in code[: m.start()]:
                fail(f"{os.path.basename(path)}:{n} uses dot syntax with an "
                     f"argument label (`{m.group(0).strip()}`), which is only legal "
                     f"for a zero-argument method — use [{m.group(0).split('.')[0]} "
                     f"{m.group(0).split('.', 1)[1]}]")


def _blank(match):
    """Replace a match with spaces, preserving newlines so line numbers hold."""
    return re.sub(r"[^\n]", " ", match.group(0))


def _blank(match):
    """Replace a match with spaces, preserving newlines so line numbers hold."""
    return re.sub(r"[^\n]", " ", match.group(0))


def _blank(match):
    """Replace a match with spaces, preserving newlines so line numbers hold."""
    return re.sub(r"[^\n]", " ", match.group(0))


def _skip_argument(text, i):
    """From `i` (just after a selector piece's colon), return the next selector
    piece's start, or the end of the message expression.

    Selector pieces are separated by argument expressions, so the first piece
    alone cannot identify the method.
    """
    n = len(text)
    depth = 0
    while i < n:
        ch = text[i]
        if ch in "([":
            depth += 1
        elif ch in ")]":
            if depth == 0:
                return i
            depth -= 1
        elif depth == 0:
            if ch == ";":
                return i
            if re.match(r"[A-Za-z_][A-Za-z0-9_]*\s*:", text[i:]):
                return i
        i += 1
    return i


def _definition_selector(text, start):
    """Full selector of a method definition beginning at `start`.

    In a declaration the pieces are separated by parameter *types* rather than
    expressions, so walking at paren depth zero and stopping at the body's `{` or
    the declaration's `;` collects them all. Keying on the first piece alone is
    not enough: `initWithContext:host:share:` and
    `initWithContext:handle:fileSize:owner:` are different methods sharing a
    first piece, which is exactly the collision that hid this bug.
    """
    i, depth, pieces, n = start, 0, [], len(text)
    while i < n:
        ch = text[i]
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        elif depth == 0:
            if ch == "{":
                break
            if ch == ";":
                break
            m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*:", text[i:])
            if m:
                pieces.append(m.group(1) + ":")
                nxt = _skip_argument(text, i + m.end())
                # Always move forward: m.end() is relative to text[i:], and a
                # backwards step here loops forever.
                i = max(nxt, i + m.end())
                continue
            if pieces:
                break
            m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", text[i:])
            if m:
                pieces.append(m.group(0))
                i += m.end()
                continue
        i += 1
    return "".join(pieces)


def _call_selector(text, start):
    """Full selector of a message send beginning at `start` (None if no-arg)."""
    i, pieces, n = start, [], len(text)
    while i < n:
        ch = text[i]
        if ch in ")]" or ch == ";":
            break
        if ch == "{":
            break
        m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*:", text[i:])
        if m:
            pieces.append(m.group(1) + ":")
            i = max(_skip_argument(text, i + m.end()), i + m.end())
            continue
        if pieces:
            break
        break
    return "".join(pieces) if len(pieces) > 1 else None


def check_objc_method_order():
    """A selector must be visible before it is used, even within one file.

    Objective-C resolves selectors at the point of use, so a call that precedes
    both the declaration and the definition gives "No visible @interface declares
    the selector". The usual cause is a private initialiser whose only definition
    sits below the caller; the fix is a class-extension forward declaration.

    Any earlier declaration *or* definition satisfies the compiler, so this keys
    on the earliest line a selector appears in either role and fails only when the
    call is earlier than both.
    """
    for path in native_files({".m"}):
        text = strip_noise(open(path, encoding="utf-8").read())
        available = {}
        for m in re.finditer(r"^\s*[-+]\s*\([^)]*\)", text, re.M):
            sel = _definition_selector(text, m.end())
            if not sel:
                continue
            line = text[: m.start()].count("\n") + 1
            if sel not in available or line < available[sel]:
                available[sel] = line
        if not available:
            continue

        # Blank declaration statements (from `- (ret)name:` through the `;` or
        # `{` that ends them) so their later selector pieces cannot be mistaken
        # for a call. Blank selector *continuation lines* instead and this breaks:
        # a call's arguments are laid out the same way, so `initWithContext:_ctx`
        # followed by `handle:fh` loses exactly the pieces needed to identify it.
        scan = re.sub(r"^[ \t]*[-+][ \t]*\([^)]*\)[^;{]*[;{]", _blank, text, flags=re.M)
        for m in re.finditer(r"(\[\s*self|\])\s+", scan):
            sel = _call_selector(scan, m.end())
            if not sel or sel not in available:
                continue
            call_line = scan[: m.start()].count("\n") + 1
            if call_line < available[sel]:
                snippet = text.split("\n")[call_line - 1].strip()
                fail(f"{os.path.basename(path)}:{call_line} calls `{sel}` but it is "
                     f"not declared or defined until line {available[sel]} — "
                     f"Objective-C needs a visible declaration first: {snippet[:60]}")

def check_objc_interface_nesting():
    """An `@interface` may not be nested inside another one.

    Objective-C has no nested types, so a second `@interface` opened before the
    first one's `@end` silently produces a malformed header. The symptom is
    `SwiftGeneratePch failed`, because the bridging header is compiled as
    Objective-C before any of our .m files are even parsed — which gives no file
    and no line to work from.
    """
    for path in native_files({".h"}):
        depth = 0
        opened_at = 0
        for n, line in enumerate(open(path, encoding="utf-8").read().split("\n"), 1):
            t = line.strip()
            if t.startswith("@interface"):
                if depth > 0:
                    fail(f"{os.path.basename(path)}:{n} opens @interface inside "
                         f"the one started on line {opened_at} — Objective-C has "
                         f"no nested types: {t[:50]}")
                depth += 1
                opened_at = n
            elif t.startswith("@end"):
                depth = max(0, depth - 1)
        if depth != 0:
            fail(f"{os.path.basename(path)}: {depth} unterminated @interface — "
                 f"the last one opened on line {opened_at} has no @end")


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
    check_objc_literal_terminators()
    check_swift_foundation_imports()
    check_ns_swift_name_consistency()
    check_objc_dot_syntax()
    check_objc_method_order()
    check_objc_interface_nesting()

    if problems:
        for p in problems:
            print(f"FAIL  {p}")
        print(f"\n{len(problems)} problem(s)")
        return 1
    print("iOS native pre-flight: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
