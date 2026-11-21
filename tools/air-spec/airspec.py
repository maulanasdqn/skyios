#!/usr/bin/env python3
"""Specialise one function of a disassembled QuartzCore metallib module
(AIR, LLVM 'textual IR' as printed by metal-objdump/llvm-dis) for a set of
function constants, so that air-opt can fold the uber-shader down to the code
one CoreAnimation pipeline actually runs.

usage: airspec.py [-O] module.ll[:function] 'name=value name=value ...' > specialised.ll
  names are the constant names without the fc_ prefix, as CoreAnimation's
  MTLFunctionConstantValues description prints them (blend_function=54 ...);
  constants not listed are 0 when required and undefined when optional (the
  driver log leaves out zero values). -O: also optimise (air-opt -O2).
"""
import os
import re
import subprocess
import sys
import tempfile


def air_opt(src):
    """air-opt -O2, then fold air.any/air.all of constant vectors (opaque to
    LLVM) and run it again until nothing changes"""
    tool = os.path.join(os.path.dirname(subprocess.check_output(['xcrun', '-f', 'metal'], text=True).strip()), 'air-opt')
    for _ in range(4):
        with tempfile.NamedTemporaryFile('w', suffix='.ll', delete=False) as f:
            f.write(src)
        out = subprocess.check_output([tool, '-S', '-O2', f.name, '-o', '-'], text=True)
        os.unlink(f.name)
        folded = re.sub(r'(%\w+) = tail call i1 @air\.any\.v\d+i1\(<\d+ x i1> zeroinitializer\)( #\d+)?',
                        r'\1 = or i1 false, false', out)
        folded = re.sub(r'(%\w+) = tail call i1 @air\.all\.v\d+i1\(<\d+ x i1> <(i1 true(, )?)+>\)( #\d+)?',
                        r'\1 = or i1 true, true', folded)
        if folded == out:
            return out
        src = folded
    return src


def load_module(spec):
    """FILE or FILE:FUNCTION, FILE being a whole-metallib dump with one
    module per function, each headed '0x<offset> -- <function>:'"""
    path, _, fn = spec.partition(':')
    text = open(path).read()
    if not fn:
        return text
    m = re.search(r'^0x[0-9a-f]+ -- %s:\n' % re.escape(fn), text, re.M)
    if not m:
        sys.exit('no function %s in %s' % (fn, path))
    end = re.search(r'^0x[0-9a-f]+ -- [\w.]+:$', text[m.end():], re.M)
    return text[m.end():m.end() + end.start()] if end else text[m.end():]


def main():
    args = sys.argv[1:]
    opt = args[0] == '-O'
    if opt:
        args = args[1:]
    src = load_module(args[0])
    consts = {}
    for kv in args[1].split():
        k, v = kv.split('=')
        # uchar3 constants are logged as 'a,b,c'
        consts[k] = sum(int(x) << 8 * i for i, x in enumerate(v.split(',')))

    # @_Z17fc_blend_function.MTL_FC_INIT_30_h = internal addrspace(2) externally_initialized constant i8 undef, ...
    fc = re.compile(r'^(@_Z\d+fc_(\w+?)\.MTL_FC_INIT_\d+_(\w+)) = internal (unnamed_addr )?addrspace\(2\) '
                    r'externally_initialized constant (i8|<3 x i8>) undef, section "air.fc_initializer", align (\d+)$', re.M)
    defined = {}
    # !{i8 addrspace(2)* @sym, !"bool", !"fc_name", i32 index, i1 optional}
    optional = {m.group(1): m.group(2) == 'true' for m in re.finditer(
        r'^!\d+ = !\{(?:i8|<3 x i8>) addrspace\(2\)\* (@[\w.]+), !"\w+", !"\w+", i32 \d+, i1 (true|false)\}$', src, re.M)}

    def repl(m):
        sym, name, ty = m.group(1), m.group(2), m.group(5)
        v = consts.get(name)
        # the driver log leaves out zero values: a missing required constant
        # is 0, a missing optional one (derived in the shader when undefined)
        # is undefined
        defined[sym] = v is not None or not optional.get(sym, False)
        if ty == 'i8':
            init = str(v or 0)
        else:  # uchar3: value given as a single int a | b << 8 | c << 16
            x = v or 0
            init = '<i8 %d, i8 %d, i8 %d>' % (x & 255, (x >> 8) & 255, (x >> 16) & 255)
        return '%s = internal addrspace(2) constant %s %s, align %s' % (sym, ty, init, m.group(6))

    src = fc.sub(repl, src)
    unknown = set(consts) - {re.match(r'@_Z\d+fc_(\w+?)\.', s).group(1) for s in defined}
    if unknown:
        sys.exit('unknown constants: %s' % ' '.join(sorted(unknown)))

    # air.is_function_constant_defined(@sym) -> true/false
    def isdef(m):
        sym = m.group(2)
        return '%s = or i1 %s, false' % (m.group(1), 'true' if defined.get(sym) else 'false')

    src = re.sub(r'(%\d+) = tail call i1 @air\.is_function_constant_defined\(i8 addrspace\(2\)\* nocapture '
                 r'(?:getelementptr \(<3 x i8>, <3 x i8> addrspace\(2\)\* )?(@[\w.]+)(?:, i64 0, i64 0\))?\) #\d+', isdef, src)
    # helper functions (bicubic sampling ...) inline into the entry point:
    # the GLSL translation handles one function
    src = re.sub(r'^(define internal [^\n]*?\)[^\n{#]*?)(#\d+ )?\{$', r'\1alwaysinline \2{', src, flags=re.M)
    src = re.sub(r'^(attributes #\d+ = \{[^}]*?)\bnoinline\b', r'\1', src, flags=re.M)
    sys.stdout.write(air_opt(src) if opt else src)


main()
