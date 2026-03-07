"""
_patch_prereserved.py
Patches hip_src C/H files for AMD Windows pre-reserved VA support.
"""
import sys
import re as _re


def die(msg):
    print(f"  ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# model-vbar.c
# ---------------------------------------------------------------------------
try:
    c = open('hip_src/model-vbar.c').read()
except FileNotFoundError:
    die('hip_src/model-vbar.c not found')

if 'vbar_externally_reserved' in c:
    print('  model-vbar.c : already patched.')
else:
    c = c.replace(
        '    size_t resident_count;\n\n    ResidentPage residency_map[1];',
        '    size_t resident_count;\n    int vbar_externally_reserved;\n\n    ResidentPage residency_map[1];'
    )
    c = c.replace(
        'void *vbar_allocate(uint64_t size, int device) {',
        'void *vbar_allocate(uint64_t size, int device, uint64_t pre_reserved) {'
    )
    c = c.replace(
        '    log(DEBUG, "%s (start): size=%zuM, device=%d\\n", __func__, size / M, device);',
        '    log(DEBUG, "%s (start): size=%zuM, device=%d pre=%p\\n", __func__, size / M, device, (void*)(uintptr_t)pre_reserved);'
    )
    old_reserve = (
        '    /* FIXME: Do I care about alignment? Does Cuda just look after itself? */\n'
        '    if (!CHECK_CU(cuMemAddressReserve(&mv->vbar, size, 0, 0, 0))) {\n'
        '        log(ERROR, "Could not reseve Virtual Address space for VBAR\\n");\n'
        '        free(mv);\n'
        '        return NULL;\n'
        '    }'
    )
    new_reserve = (
        '    if (pre_reserved) {\n'
        '        mv->vbar = (CUdeviceptr)(uintptr_t)pre_reserved;\n'
        '        mv->vbar_externally_reserved = 1;\n'
        '    } else {\n'
        '        if (!CHECK_CU(cuMemAddressReserve(&mv->vbar, size, 0, 0, 0))) {\n'
        '            log(ERROR, "Could not reseve Virtual Address space for VBAR\\n");\n'
        '            free(mv);\n'
        '            return NULL;\n'
        '        }\n'
        '        mv->vbar_externally_reserved = 0;\n'
        '    }'
    )
    if old_reserve not in c:
        die('model-vbar.c reserve block not found — source may have changed')
    c = c.replace(old_reserve, new_reserve)

    old_free2 = (
        '    for (uint64_t page_nr = 0; page_nr < mv->nr_pages; page_nr++) {\n'
        '        mod1(mv, page_nr, true, true);\n'
        '    }\n'
        '    remove_vbar(mv);\n'
        '    CHECK_CU(cuMemAddressFree(mv->vbar, (size_t)mv->nr_pages * VBAR_PAGE_SIZE));\n'
        '    free(mv);\n'
        '}'
    )
    new_free2 = (
        '    for (uint64_t page_nr = 0; page_nr < mv->nr_pages; page_nr++) {\n'
        '        mod1(mv, page_nr, true, true);\n'
        '    }\n'
        '    remove_vbar(mv);\n'
        '    if (!mv->vbar_externally_reserved) {\n'
        '        CHECK_CU(cuMemAddressFree(mv->vbar, mv->nr_pages * VBAR_PAGE_SIZE));\n'
        '    }\n'
        '    free(mv);\n'
        '}'
    )
    if old_free2 not in c:
        die('model-vbar.c vbar_free block not found — source may have changed')
    c = c.replace(old_free2, new_free2)
    open('hip_src/model-vbar.c', 'w').write(c)
    print('  model-vbar.c : patched OK.')


# ---------------------------------------------------------------------------
# vrambuf.h
# ---------------------------------------------------------------------------
try:
    h = open('hip_src/vrambuf.h').read()
except FileNotFoundError:
    die('hip_src/vrambuf.h not found')

if 'externally_reserved' in h:
    print('  vrambuf.h : already patched.')
else:
    h = h.replace(
        '    int device;\n    struct VramBuffer *next;',
        '    int device;\n    int externally_reserved;\n    struct VramBuffer *next;'
    )
    h = h.replace(
        'void *vrambuf_create(int device, size_t max_size);',
        'void *vrambuf_create(int device, size_t max_size, uint64_t pre_reserved);'
    )
    open('hip_src/vrambuf.h', 'w').write(h)
    print('  vrambuf.h : patched OK.')


# ---------------------------------------------------------------------------
# vrambuf.c
# ---------------------------------------------------------------------------
try:
    c = open('hip_src/vrambuf.c').read()
except FileNotFoundError:
    die('hip_src/vrambuf.c not found')

if 'externally_reserved' in c:
    print('  vrambuf.c : already patched.')
else:
    c = c.replace(
        'void *vrambuf_create(int device, size_t max_size) {',
        'void *vrambuf_create(int device, size_t max_size, uint64_t pre_reserved) {'
    )
    old_res = (
        '    buf->device = device;\n'
        '    buf->max_size = max_size;\n'
        '\n'
        '    if (!CHECK_CU(cuMemAddressReserve(&buf->base_ptr, max_size, 0, 0, 0))) {\n'
        '        log(ERROR, "%s: %d %zuk\\n", __func__, device, max_size / K);\n'
        '        free(buf);\n'
        '        return NULL;\n'
        '    }'
    )
    new_res = (
        '    buf->device = device;\n'
        '    buf->max_size = max_size;\n'
        '    buf->externally_reserved = (pre_reserved != 0);\n'
        '\n'
        '    if (pre_reserved) {\n'
        '        buf->base_ptr = (CUdeviceptr)(uintptr_t)pre_reserved;\n'
        '    } else {\n'
        '        if (!CHECK_CU(cuMemAddressReserve(&buf->base_ptr, max_size, 0, 0, 0))) {\n'
        '            log(ERROR, "%s: %d %zuk\\n", __func__, device, max_size / K);\n'
        '            free(buf);\n'
        '            return NULL;\n'
        '        }\n'
        '    }'
    )
    if old_res not in c:
        die('vrambuf.c reserve block not found — source may have changed')
    c = c.replace(old_res, new_res)
    c = c.replace(
        '    CHECK_CU(cuMemAddressFree(buf->base_ptr, buf->max_size));\n    total_vram_usage',
        '    if (!buf->externally_reserved) {\n        CHECK_CU(cuMemAddressFree(buf->base_ptr, buf->max_size));\n    }\n    total_vram_usage'
    )
    open('hip_src/vrambuf.c', 'w').write(c)
    print('  vrambuf.c : patched OK.')


# ---------------------------------------------------------------------------
# pyt-cu-plug-alloc.c
# ---------------------------------------------------------------------------
try:
    c = open('hip_src/pyt-cu-plug-alloc.c').read()
except FileNotFoundError:
    die('hip_src/pyt-cu-plug-alloc.c not found')

if 'vrambuf_create(device, virt_size, 0)' in c:
    print('  pyt-cu-plug-alloc.c : already patched.')
else:
    c = c.replace('vrambuf_create(device, size)', 'vrambuf_create(device, size, 0)')
    open('hip_src/pyt-cu-plug-alloc.c', 'w').write(c)
    print('  pyt-cu-plug-alloc.c : patched OK.')


# ---------------------------------------------------------------------------
# plat.h -- full CUDA -> HIP translation
# ---------------------------------------------------------------------------
try:
    h = open('hip_src/plat.h').read()
except FileNotFoundError:
    die('hip_src/plat.h not found')

if '#include <hip/hip_runtime.h>' in h:
    print('  plat.h : already patched.')
else:
    def wb(old, new, s):
        return _re.sub(r'\b' + _re.escape(old) + r'\b', new, s)

    h = h.replace('#include <cuda.h>', '#include <hip/hip_runtime.h>')
    h = h.replace('#include <cuda_runtime.h>', '#include <hip/hip_runtime.h>')
    h = wb('CUdevice',                     'hipDevice_t', h)
    h = wb('CUdeviceptr',                  'hipDeviceptr_t', h)
    h = wb('CUresult',                     'hipError_t', h)
    h = wb('CUmemGenericAllocationHandle', 'hipMemGenericAllocationHandle_t', h)
    h = wb('CUmemAllocationProp',          'hipMemAllocationProp', h)
    h = wb('CUmemAccessDesc',              'hipMemAccessDesc', h)
    h = wb('CUstream',                     'hipStream_t', h)
    h = wb('CUDA_SUCCESS',                 'hipSuccess', h)
    h = wb('CUDA_ERROR_OUT_OF_MEMORY',     'hipErrorOutOfMemory', h)
    h = wb('CU_MEM_ALLOCATION_TYPE_PINNED',     'hipMemAllocationTypePinned', h)
    h = wb('CU_MEM_LOCATION_TYPE_DEVICE',       'hipMemLocationTypeDevice', h)
    h = wb('CU_MEM_ACCESS_FLAGS_PROT_READWRITE','hipMemAccessFlagsProtReadWrite', h)
    h = _re.sub(
        r'cuGetErrorString\(([^,]+),\s*&(\w+)\s*\)',
        r'((\2 = hipGetErrorString(\1)) == NULL ? hipErrorUnknown : hipSuccess)',
        h
    )
    h = wb('cuGetErrorString',   'hipGetErrorString', h)
    h = wb('cuMemCreate',        'hipMemCreate', h)
    h = wb('cuMemSetAccess',     'hipMemSetAccess', h)
    h = wb('cuMemMap',           'hipMemMap', h)
    h = wb('cuMemUnmap',         'hipMemUnmap', h)
    h = wb('cuMemRelease',       'hipMemRelease', h)
    h = wb('cuMemAddressReserve','hipMemAddressReserve', h)
    h = wb('cuMemAddressFree',   'hipMemAddressFree', h)
    h = wb('cuDeviceGet',        'hipDeviceGet', h)
    h = wb('cuDeviceTotalMem',   'hipDeviceTotalMem', h)
    h = wb('cuDeviceGetName',    'hipDeviceGetName', h)
    h = wb('cuMemGetInfo',       'hipMemGetInfo', h)
    h = wb('cuCtxSynchronize',   'hipDeviceSynchronize', h)
    h = wb('cuCtxGetDevice',     'hipGetDevice', h)
    h = h.replace('hipGetDevice(&', 'hipGetDevice((int*)&')
    h = wb('cuMemAllocAsync',    'hipMallocAsync', h)
    h = wb('cuMemFreeAsync',     'hipFreeAsync', h)
    h = h.replace('typedef struct CUstream_st *hipStream_t;\n', '')
    open('hip_src/plat.h', 'w', encoding='utf-8').write(h)
    print('  plat.h : patched OK.')
