#!/usr/bin/env python3
"""Exported (defined, global) dynamic symbols of ELF64 .so files, checked against a want-list.
usage: syms.py LIB [LIB...]"""
import struct, sys, json
WANT = {
 "librknnrt": ["rknn_init", "rknn_query", "rknn_inputs_set", "rknn_run", "rknn_outputs_get", "rknn_outputs_release",
               "rknn_create_mem", "rknn_create_mem2", "rknn_create_mem_from_fd", "rknn_create_mem_from_phys", "rknn_set_io_mem",
               "rknn_destroy_mem", "rknn_set_core_mask", "rknn_destroy", "rknn_dup_context", "rknn_mem_sync", "rknn_wait",
               "rknn_set_input_shape", "rknn_set_internal_mem", "rknn_set_weight_mem"],
 "librga": ["importbuffer_fd", "wrapbuffer_handle", "wrapbuffer_handle_t", "improcess", "imcheck", "imcheck_t",
            "imfill_t", "imresize_t", "imcvtcolor_t", "releasebuffer_handle", "querystring", "wrapbuffer_fd_t", "c_RkRgaBlit"],
 "librockchip_mpp": ["mpp_create", "mpp_init", "mpp_destroy", "mpp_buffer_get_fd_with_caller", "mpp_buffer_get_fd",
                     "mpp_packet_init", "mpp_frame_get_buffer", "mpp_frame_get_info_change", "mpp_buffer_group_get",
                     "mpp_frame_get_hor_stride", "mpp_frame_deinit", "mpp_dec_cfg_init"],
}
def syms(path):
    b = open(path, "rb").read()
    shoff, = struct.unpack_from("<Q", b, 0x28); shentsize, shnum = struct.unpack_from("<HH", b, 0x3A)
    secs = [struct.unpack_from("<IIQQQQIIQQ", b, shoff + i * shentsize) for i in range(shnum)]
    out = {}
    for s in secs:
        if s[1] != 11:  # SHT_DYNSYM
            continue
        strtab = secs[s[6]]; off, size, ent = s[4], s[5], s[9]
        for i in range(size // ent):
            name, info, other, shndx, val, sz = struct.unpack_from("<IBBHQQ", b, off + i * ent)
            if shndx == 0 or (info >> 4) not in (1, 2):
                continue
            o = strtab[4] + name; e = b.index(b"\0", o)
            out[b[o:e].decode()] = sz
    return out
for p in sys.argv[1:]:
    s = syms(p)
    key = next((k for k in WANT if k in p), None)
    want = {w: (w in s) for w in WANT.get(key, [])}
    # C++ mangled overloads of the im2d helpers, to show which forms exist
    extra = sorted(n for n in s if any(t in n for t in ("importbuffer_fd", "wrapbuffer_handle", "improcess"))) if key == "librga" else []
    print("JSON:" + json.dumps({"lib": p, "n_exported": len(s), "want": want, "mangled_or_variants": extra,
                                "rknn_all": sorted(n for n in s if n.startswith("rknn_")) if key == "librknnrt" else None}))
