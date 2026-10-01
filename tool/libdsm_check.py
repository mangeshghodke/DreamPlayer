#!/usr/bin/env python3
"""Static pre-flight for the vendored libDSM wrapper.

There is no Xcode on this machine, so every Swift/Objective-C mistake costs a
~14 minute CI cycle. This catches the classes of error that have actually bitten
the port, without a compiler:

  * undefined/unresolved ObjC calls (a renamed or never-restored helper)
  * libDSM symbols or constants that do not exist in the vendored headers
  * argument-count mismatches against the real libDSM declarations
  * the vendored library and headers coming from different upstream builds
  * C-invalid string escapes and Swift syntax leaking into the .m
  * unbalanced braces

Usage: python3 tool/libdsm_check.py [--libdsm DIR]
Exit code 0 = pass, 1 = fail.
"""

import argparse
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Objective-C/C functions the wrapper may call that are not its own helpers and
# not libDSM. Anything else called as a bare identifier is suspicious.
FOUNDATION = {
    # libC
    "inet_pton", "strlen", "strcmp", "memcpy", "memset", "free", "malloc", "abort",
    # NSString / NSArray / NSMutableString / NSMutableArray / NSData
    "stringWithFormat", "stringWithUTF8String", "stringWithString", "string",
    "stringByAppendingString", "stringByReplacingOccurrencesOfString",
    "stringByTrimmingCharactersInSet", "stringByAppendingPathComponent",
    "characterSetWithCharactersInString", "isEqualToString", "hasPrefix",
    "hasSuffix", "lowercaseString", "length", "dataUsingEncoding",
    "stringByAppendingPathExtension", "initWithBytes", "copy", "getCString",
    "appendString", "addObject", "array", "isEqual", "stringValue", "doubleValue",
    "writeToFile", "substringFromIndex", "substringToIndex", "componentsSeparatedByString",
    # BSD sockets, used by the reachability probe
    "socket", "connect", "close", "fcntl", "poll", "htons", "getsockopt", "setsockopt",
    "bind", "send", "recv", "read", "write",
    # NSMutableData
    "dataWithLength", "setLength", "mutableBytes", "length",
    # libDSM statics used locally
    "LibDSMFail", "LibDSMFindPattern", "LibDSMSharePath", "LibDSMFriendlyError",
    "LibDSMMillis", "dispatch_async", "dispatch_get_main_queue",
}

# Declarations the wrapper calls, with the argument count each one takes.
# Kept by hand because the C headers have no machine-readable arity metadata.
EXPECTED_CALLS = {
    "smb_session_new": 0,
    "smb_session_set_creds": 4,
    "smb_session_connect": 4,
    "smb_session_login": 1,
    "smb_session_is_guest": 1,
    "smb_session_destroy": 1,
    "smb_session_get_nt_status": 1,
    "smb_tree_connect": 3,
    "smb_tree_disconnect": 2,
    "smb_share_get_list": 3,
    "smb_share_list_count": 1,
    "smb_share_list_at": 2,
    "smb_share_list_destroy": 1,
    "smb_find": 3,
    "smb_stat_list_count": 1,
    "smb_stat_list_at": 2,
    "smb_stat_fd": 2,
    "smb_stat_list_destroy": 1,
    "smb_stat_name": 1,
    "smb_stat_get": 2,
    "smb_fstat": 3,
    "smb_fopen": 5,
    "smb_fclose": 2,
    "smb_fread": 4,
    "smb_fseek": 4,
}


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
    in_line_comment = False
    in_block_comment = False
    in_string = False
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


def parse_libdsm_api(include_dir):
    """name -> declared arg count, plus the #define'd constant names."""
    functions = {}
    constants = set()
    for path in glob.glob(os.path.join(include_dir, "*.h")):
        src = open(path, encoding="utf-8", errors="replace").read()
        for m in re.finditer(
            r"^\s*[A-Za-z_][\w ]*?\s*\**\s*(smb_\w+)\s*\(([^;{]*?)\)\s*;", src, re.M
        ):
            args = m.group(2).strip()
            functions[m.group(1)] = 0 if args in ("", "void") else len(
                [a for a in args.split(",") if a.strip()]
            )
        constants |= set(re.findall(r"#define\s+((?:SMB|DSM|NT_STATUS)_\w+)", src))
        constants |= set(re.findall(r"^\s+(SMB_\w+)\s*=", src, re.M))
        constants |= set(re.findall(r"\b(smb_\w+)\b", src))
    return functions, constants


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--libdsm", default=os.path.join(ROOT, "ios/Runner/libdsm"))
    args = ap.parse_args()

    wrapper = os.path.join(ROOT, "ios/Runner/LibDSM.m")
    header = os.path.join(ROOT, "ios/Runner/LibDSM.h")
    include = os.path.join(args.libdsm, "bdsm")

    problems = []

    def check(cond, message):
        if not cond:
            problems.append(message)

    for path in (wrapper, header):
        if not os.path.exists(path):
            print(f"FAIL  missing {path}")
            return 1

    code = strip_strings(strip_noise(open(wrapper, encoding="utf-8").read()))

    # 1. Structure
    check(balance(open(wrapper, encoding="utf-8").read()) == 0, "unbalanced braces in LibDSM.m")

    # 2. Every static helper the call sites use must still be defined. A block
    #    replacement once dropped a helper while leaving its call behind.
    defined = set(re.findall(r"^static\s+[\w\s*]*?(\w+)\s*\(", code, re.M))
    called = set(re.findall(r"^static\s+[\w\s*]*?(\w+)\s*\(", code, re.M))
    for name in sorted(called):
        check(name in defined, f"static helper {name}() is used but never defined")
    for m in re.finditer(r"LibDSM\w+\(", code):
        name = m.group(0)[:-1]
        if name not in defined:
            problems.append(f"{name}() called but not defined in LibDSM.m")

    # 3. libDSM surface actually exists in the vendored headers
    api, constants = parse_libdsm_api(include)
    for name, arity in EXPECTED_CALLS.items():
        if name not in api:
            problems.append(f"{name}() not declared in the vendored libDSM headers")
        elif api[name] != arity:
            problems.append(
                f"{name}() declared with {api[name]} args, expected {arity}"
            )
    for name in sorted(set(re.findall(r"\bsmb_\w+\b", code))):
        check(
            name in api or name in constants,
            f"{name} is not declared in the vendored libDSM headers",
        )
    for name in sorted(set(re.findall(r"\b(?:NT_STATUS|DSM|SMB)_\w+\b", code))):
        check(name in constants, f"{name} is not defined in the vendored libDSM headers")

    # 4. Swift must not have leaked into the Objective-C translation unit
    for token in ("SBMLog", "Swift.", "func ", "guard ", "->"):
        check(token not in code, f"{token!r} in LibDSM.m code — not valid Objective-C")

    # 5. C-invalid escapes inside string literals
    valid = set('nrt0abfv"\\\'')
    for m in re.finditer(r'@"((?:[^"\\\n]|\\.)*)"', code):
        lit = m.group(1)
        i = 0
        while i < len(lit):
            if lit[i] == "\\" and i + 1 < len(lit):
                nxt = lit[i + 1]
                if nxt not in valid:
                    problems.append(f"invalid escape \\{nxt} in ObjC string {lit[:48]!r}")
                    break
                i += 2
                continue
            i += 1

    # 6. smb_find needs a wildcard; a concrete path matches one entry, not children
    raw = strip_noise(open(wrapper, encoding="utf-8").read())
    fn = re.search(r"static NSString \*LibDSMFindPattern\(NSString \*path\) \{(.*?)\n\}", raw, re.S)
    check(fn is not None, "LibDSMFindPattern() missing")
    if fn:
        body = fn.group(1)
        check(r'@"\\*"' in body, "LibDSMFindPattern: share root pattern lacks the trailing \\*")
        check(r"\\%@\\*" in body, "LibDSMFindPattern: folder pattern lacks the trailing \\*")

    # 7. Errors must be reported with DSM_* codes, and DSM_ERROR_NT must read the
    #    NT status — otherwise a wrong password is indistinguishable from any
    #    other failure.
    err = re.search(r"static NSString \*LibDSMFriendlyError\(.*?\) \{(.*?)\n\}", code, re.S)
    check(err is not None, "LibDSMFriendlyError() missing")
    if err:
        body = err.group(1)
        check("smb_session_get_nt_status" in body, "DSM_ERROR_NT does not read the NT status")
        check(
            not re.search(r"case\s+-(?:6\d|1[01]\d)\b", body),
            "LibDSMFriendlyError still branches on errno values; libDSM returns DSM_* codes",
        )

    # 8. smb_types.h includes <libtasn1.h>, so it must sit on an -I path
    types = open(os.path.join(include, "smb_types.h"), encoding="utf-8").read()
    if "#include <libtasn1.h>" in types:
        check(
            os.path.exists(os.path.join(args.libdsm, "libtasn1.h")),
            "libtasn1.h must be at the libdsm root for #include <libtasn1.h> to resolve",
        )

    # 9. A class method has no instance ivars. Referring to one is a compile
    #    error ("Instance variable '_session' accessed in class method"), and it
    #    is easy to introduce when a helper's session argument is renamed.
    ivars = set(re.findall(r"^\s*[\w ]*?\*?(_[a-z]\w*)\s*;", code, re.M))
    for m in re.finditer(r"^\+ \([^)]*\)[^{]*\{", code, re.M):
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
        for ref in set(re.findall(r"(?<![A-Za-z0-9_])(_[a-z]\w*)\b", body)):
            if ref in ivars:
                problems.append(
                    f"class method at line {line} touches instance ivar {ref}"
                )

    # 10. Objective-C silently accepts a message send to any selector, so a
    #     misspelled or deleted helper only surfaces as "undeclared identifier"
    #     in CI. Catch calls to bare identifiers that are neither defined here,
    #     nor libDSM, nor a known Foundation/C function.
    known = set(EXPECTED_CALLS) | set(re.findall(r"\bsmb_\w+\b", code))
    known |= set(re.findall(r"^static\s+[\w ]*?(\w+)\s*\(", code, re.M))
    known |= FOUNDATION
    # 11. Argument count at each call site, not just at the declaration. A
    #     dropped argument compiles as a silent type change in C.
    for name in sorted(set(re.findall(r"\bsmb_\w+\s*\(", code))):
        fn = name.split("(")[0]
        if fn not in api or fn not in EXPECTED_CALLS:
            continue
        # name is "fn(" — start scanning just inside the open paren, and treat
        # the case of an empty argument list as zero rather than one.
        start = code.index(name) + len(fn) + 1
        if code[start : start + 1] == ")":
            continue
        depth = 0
        nargs = 1
        i = start
        while i < len(code):
            c = code[i]
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if depth == 0:
                    break
                depth -= 1
            elif c == "," and depth == 0:
                nargs += 1
            i += 1
        if nargs != EXPECTED_CALLS[fn]:
            line = code[: code.index(name)].count("\n") + 1
            problems.append(
                f"{fn}() called with {nargs} argument(s) at line {line}, "
                f"declared for {EXPECTED_CALLS[fn]}"
            )

    keywords = {
        "if", "else", "for", "while", "do", "switch", "case", "return", "break",
        "continue", "goto", "sizeof", "defined", "_Static_assert",
    }
    for callee in sorted(set(re.findall(r"(?<![.\w>])([a-z][A-Za-z0-9_]*)\s*\(", code))):
        if callee in keywords:
            continue
        if callee not in known:
            problems.append(
                f"{callee}(...) is neither a local helper, a libDSM call, nor a known "
                f"Foundation/C function — undeclared identifiers are a build error"
            )

    # 12. Every vendored archive must be wired into the link, in dependency
    #     order. A missing one is a link-time "Undefined symbol", and static
    #     archives must also be ordered: a dependent precedes whatever satisfies
    #     it, otherwise the linker stops scanning before reaching the definition.
    pbx = open(
        os.path.join(ROOT, "ios/Runner.xcodeproj/project.pbxproj"), encoding="utf-8"
    ).read()
    archives = sorted(f for f in os.listdir(args.libdsm) if f.endswith(".a"))

    for name in archives:
        if f"{name} in Frameworks */," not in pbx:
            problems.append(
                f"{name} is vendored but not linked (add it to the Frameworks phase)"
            )

    # libdsm needs libtasn1 + libiconv; libiconv needs libcharset.
    expected_order = ["libdsm.a", "libtasn1.a", "libiconv.a", "libcharset.a"]
    for required in ("libiconv.a", "libcharset.a"):
        if required not in archives:
            problems.append(
                f"{required} is missing — this libdsm build calls "
                f"libiconv_open/libiconv_close/libiconv and locale_charset, which "
                f"only these archives define (-liconv is not a substitute)"
            )

    phase_order = re.findall(r"([\w.]+\.a) in Frameworks \*/,", pbx)
    linked = [n for n in phase_order if n in archives]
    if len(linked) == len(archives) and linked != sorted(linked, key=expected_order.index):
        problems.append(
            f"static archives are linked as {linked}, but a dependent must precede "
            f"its dependency: {sorted(archives, key=expected_order.index)}"
        )

    # 13. Methods whose last parameter is NSError** import into Swift as
    #     throwing under one of Clang's default error conventions
    #     (https://clang.llvm.org/docs/AttributeReference.html, swift_error):
    #       null_result — pointer return, thrown on nil, result non-optional.
    #                    This is keyed off the return being *nullable*; mark it
    #                    nonnull and the convention no longer applies, so the
    #                    method silently stops being throwing and the only
    #                    symptom is "Missing argument for parameter 'error'" at
    #                    the call site — three CI cycles to trace back here.
    #       zero_result — integral return, thrown on 0, imported as Void.
    #     So a pointer-returning NSError** method must be declared nullable,
    #     while a BOOL-returning one is correct as-is.
    header_src = strip_noise(open(header, encoding="utf-8").read())
    for m in re.finditer(
        r"(?m)^([-+])\s*\(([^)]*)\)([^{;]*?error:\(NSError[^)]*\)[^;]*);",
        header_src,
    ):
        kind = m.group(1)
        ret = m.group(2).strip()
        line = header_src[: m.start()].count("\n") + 1
        selector = m.group(3)
        name = re.search(r"(\w+):", selector)
        label = f"{name.group(1) if name else '?'} ({'class' if kind == '+' else 'instance'})"
        returns_pointer = ret.endswith("*") or "instancetype" in ret
        if returns_pointer and "nullable" not in ret:
            problems.append(
                f"LibDSM.h:{line} {label} takes NSError** but returns {ret!r} "
                f"without 'nullable'; Swift will not import it as throwing "
                f"(swift_error null_result requires a nullable pointer return)"
            )
        if "BOOL" in ret:
            # Legitimate, but Swift imports it as Void + throws-on-false, so the
            # call site cannot test the result. Require the header to say so,
            # otherwise the author will write `if try f(...)` and get a build
            # failure pointing at the call site instead of the declaration.
            # Read the raw header: strip_noise() removed the very comment this
            # is looking for.
            raw_header = open(header, encoding="utf-8").read()
            if "zero_result" not in raw_header:
                problems.append(
                    f"LibDSM.h:{line} {label} returns BOOL with NSError**, so Swift "
                    f"imports it as Void + throws-on-false (swift_error zero_result). "
                    f"Document that in the header next to the declaration."
                )

    if problems:
        for p in problems:
            print(f"FAIL  {p}")
        print(f"\n{len(problems)} problem(s)")
        return 1
    print("libDSM pre-flight: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
