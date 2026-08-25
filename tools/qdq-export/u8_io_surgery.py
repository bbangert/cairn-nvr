#!/usr/bin/env python3
"""Convert a float-IO QDQ artifact to uint8 graph IO by edge surgery.

A QDQ export carries float32 graph IO with QuantizeLinear at the entry
and DequantizeLinear at the exit; the QNN EP then leaves those edge ops
to the CPU EP (its `offload_graph_io_quantization` default), and the
float<->uint8 conversion passes are the entire remaining latency gap to
Qualcomm's published numbers (their 13.4ms yolox_s vs our 21.8ms is
their `--quantize_io` variant, not a better graph). This tool produces
that variant from OUR artifact: it removes the edge Q/DQ nodes,
redeclares the graph IO as uint8, and emits the removed nodes' exact
scale/zero_point as a sidecar (`<out>.qparams.json`) for the host to
apply — quantize on pack, dequantize on extract.

No exporter API produces this shape; manual graph editing is the
standard route. Two structural facts make it safe here:

- **Entry Q may sit behind data-movement ops.** YOLOX's focus stem
  slices the input into four quadrants before quantizing each, so the
  walk from the graph input traverses single-data-input, dtype-agnostic
  ops (Slice/Transpose/Reshape/Identity) and requires every path to end
  in QuantizeLinear nodes with one identical per-tensor qparam set.
  Those ops then legally operate on uint8 codes — element selection
  commutes with a per-tensor affine. Concat is deliberately NOT
  traversed: a concat can merge a non-input float path, and retyping
  through it would corrupt that branch.
- **The interior stays intact.** Only the edge nodes are removed; every
  internal Q/DQ pair the QNN EP fuses on survives unchanged, so the
  compiled graph body is the same one the float-IO artifact runs.

The host-side contract this creates: input codes are
`saturate(round_half_even(value / scale) + zero_point)` (the removed
QuantizeLinear's own arithmetic, ONNX spec), and output floats are
`(code - zero_point) * scale`. `--verify` proves the contract on the
spot: both models run under CPU-EP on a deterministic synthetic frame
and must produce bit-identical results once the host applies those two
formulas — the interior graphs are the same, so anything short of exact
equality means the surgery (not the artifact) is wrong.

Usage:
  u8_io_surgery.py <qdq-float-io.onnx> <out.onnx>
                   [--mode input|output|both] [--verify]

Guards: refuses DynamicQuantizeLinear anywhere (runtime qparams cannot
move to a sidecar), default-domain opset < 13, per-axis or non-uint8
edge qparams, and any graph output not produced by DequantizeLinear.
"""

import argparse
import hashlib
import json
import sys

import numpy as np
import onnx
from onnx import TensorProto, numpy_helper

# Single-data-input ops that pass uint8 codes through unchanged; the
# entry walk may cross these between the graph input and QuantizeLinear.
TRANSPARENT_OPS = {"Slice", "Transpose", "Reshape", "Identity", "Squeeze", "Unsqueeze"}


def fail(msg):
    print(f"u8_io_surgery: {msg}", file=sys.stderr)
    sys.exit(1)


def scalar_qparams(graph, scale_name, zp_name, where):
    inits = {i.name: i for i in graph.initializer}
    if scale_name not in inits or zp_name not in inits:
        fail(f"{where}: qparams are not initializers (graph-computed qparams unsupported)")
    scale = numpy_helper.to_array(inits[scale_name])
    zp = numpy_helper.to_array(inits[zp_name])
    if scale.size != 1 or zp.size != 1:
        fail(f"{where}: per-axis qparams (scale n={scale.size}) cannot become graph-IO metadata")
    if zp.dtype != np.uint8:
        fail(f"{where}: zero_point dtype {zp.dtype} is not uint8")
    scale = float(scale.reshape(()))
    # Same rule as the Rust loader: a zero/NaN/inf scale would divide to
    # garbage in quantize and ship a sidecar the host refuses anyway.
    if not np.isfinite(scale) or scale <= 0.0:
        fail(f"{where}: scale {scale} is not finite-positive")
    return scale, int(zp.reshape(()))


def entry_surgery(graph):
    """Remove the entry QuantizeLinear set; return its shared qparams."""
    if len(graph.input) != 1:
        fail(f"expected exactly one graph input, found {len(graph.input)}")
    inp = graph.input[0]
    if inp.type.tensor_type.elem_type != TensorProto.FLOAT:
        fail(f"input {inp.name} is not float32 — already converted?")

    consumers = {}
    for n in graph.node:
        for t in n.input:
            consumers.setdefault(t, []).append(n)

    # Walk from the input across transparent ops; leaves must be Q nodes.
    traversed, q_nodes, frontier, seen = [], [], [inp.name], set()
    while frontier:
        t = frontier.pop()
        if t in seen:
            continue
        seen.add(t)
        for n in consumers.get(t, []):
            if n.op_type == "QuantizeLinear":
                q_nodes.append(n)
            elif n.op_type in TRANSPARENT_OPS:
                traversed.extend(n.output)
                frontier.extend(n.output)
            else:
                fail(
                    f"op {n.op_type} ({n.name}) between input and QuantizeLinear "
                    f"is not dtype-transparent — cannot retype the stem to uint8"
                )
    if not q_nodes:
        fail("no QuantizeLinear reachable from the graph input")

    qparams = {scalar_qparams(graph, n.input[1], n.input[2], f"entry Q {n.name}") for n in q_nodes}
    if len(qparams) != 1:
        fail(f"entry QuantizeLinear qparams disagree across paths: {sorted(qparams)}")
    scale, zp = qparams.pop()

    # Rewire each Q's consumers onto its (now uint8) source tensor.
    dead_outputs = set()
    for q in q_nodes:
        dead_outputs.add(q.output[0])
        for n in graph.node:
            for i, t in enumerate(n.input):
                if t == q.output[0]:
                    n.input[i] = q.input[0]
    for q in q_nodes:
        graph.node.remove(q)

    inp.type.tensor_type.elem_type = TensorProto.UINT8
    retype = set(traversed)
    keep = []
    for vi in graph.value_info:
        if vi.name in dead_outputs:
            continue
        if vi.name in retype:
            vi.type.tensor_type.elem_type = TensorProto.UINT8
        keep.append(vi)
    del graph.value_info[:]
    graph.value_info.extend(keep)
    return {"name": inp.name, "scale": scale, "zero_point": zp}


def exit_surgery(graph):
    """Remove every exit DequantizeLinear; return per-output qparams."""
    producers = {o: n for n in graph.node for o in n.output}
    consumers = {}
    for n in graph.node:
        for t in n.input:
            consumers.setdefault(t, []).append(n)

    outputs = {}
    for out in graph.output:
        dq = producers.get(out.name)
        if dq is None or dq.op_type != "DequantizeLinear":
            fail(f"output {out.name} is not produced by DequantizeLinear (got {dq.op_type if dq else 'nothing'})")
        code_tensor = dq.input[0]
        others = [n.name for n in consumers.get(code_tensor, []) if n.name != dq.name]
        if others:
            fail(
                f"quantized tensor {code_tensor} has consumers besides the exit DQ: "
                + ", ".join(others)
            )
        scale, zp = scalar_qparams(graph, dq.input[1], dq.input[2], f"exit DQ {dq.name}")

        # The code tensor takes over the output's name so host-side
        # output lookup by name is unchanged.
        producer = producers.get(code_tensor)
        if producer is None:
            fail(f"quantized tensor {code_tensor} has no producing node")
        for i, t in enumerate(producer.output):
            if t == code_tensor:
                producer.output[i] = out.name
        graph.node.remove(dq)
        out.type.tensor_type.elem_type = TensorProto.UINT8
        outputs[out.name] = {"scale": scale, "zero_point": zp}

        keep = [vi for vi in graph.value_info if vi.name != code_tensor]
        del graph.value_info[:]
        graph.value_info.extend(keep)
    return outputs


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def quantize_codes(values, scale, zero_point):
    return np.clip(np.rint(values / scale) + zero_point, 0, 255).astype(np.uint8)


def synthetic_frame(shape):
    # Deterministic full-range pattern: every uint8 code appears, plus
    # spatial structure so conv outputs are not degenerate.
    n = int(np.prod(shape))
    return (np.arange(n, dtype=np.int64) * 7919 % 256).astype(np.float32).reshape(shape)


def verify(float_path, u8_path, sidecar):
    import onnxruntime as ort_rt

    f_sess = ort_rt.InferenceSession(float_path, providers=["CPUExecutionProvider"])
    u_sess = ort_rt.InferenceSession(u8_path, providers=["CPUExecutionProvider"])
    f_in = f_sess.get_inputs()[0]
    frame = synthetic_frame([d if isinstance(d, int) else 1 for d in f_in.shape])

    if sidecar["input"] is not None:
        codes = quantize_codes(frame, sidecar["input"]["scale"], sidecar["input"]["zero_point"])
        u8_feed = {f_in.name: codes}
    else:
        u8_feed = {f_in.name: frame}

    f_outs = f_sess.run(None, {f_in.name: frame})
    u_outs = u_sess.run(None, u8_feed)
    for meta, f_out, u_out in zip(f_sess.get_outputs(), f_outs, u_outs):
        qp = sidecar["outputs"].get(meta.name)
        got = (u_out.astype(np.float32) - qp["zero_point"]) * qp["scale"] if qp else u_out
        if not np.array_equal(f_out, got):
            diff = np.abs(f_out - got)
            fail(
                f"verify: output {meta.name} not bit-identical "
                f"(max diff {diff.max()}, {np.count_nonzero(diff)} of {diff.size} elements)"
            )
    print(f"verify: {len(f_outs)} output(s) bit-identical under CPU-EP")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("model")
    ap.add_argument("out")
    ap.add_argument("--mode", choices=["input", "output", "both"], default="both")
    ap.add_argument("--verify", action="store_true")
    args = ap.parse_args()

    model = onnx.load(args.model)
    default_opset = next((o.version for o in model.opset_import if o.domain == ""), None)
    if default_opset is None or default_opset < 13:
        fail(f"default-domain opset {default_opset} < 13")
    if any(n.op_type == "DynamicQuantizeLinear" for n in model.graph.node):
        fail("model uses DynamicQuantizeLinear — runtime qparams cannot become a sidecar")

    sidecar = {
        "spec": "cairn.u8io.qparams",
        "version": 1,
        "mode": args.mode,
        "source": args.model.rsplit("/", 1)[-1],
        "source_sha256": sha256_file(args.model),
        "input": None,
        "outputs": {},
    }
    if args.mode in ("input", "both"):
        sidecar["input"] = entry_surgery(model.graph)
    if args.mode in ("output", "both"):
        sidecar["outputs"] = exit_surgery(model.graph)

    onnx.checker.check_model(model)
    onnx.save(model, args.out)
    sidecar_path = f"{args.out}.qparams.json"
    with open(sidecar_path, "w") as f:
        json.dump(sidecar, f, indent=2)
        f.write("\n")
    print(f"wrote {args.out} + {sidecar_path}")

    if args.verify:
        verify(args.model, args.out, sidecar)


if __name__ == "__main__":
    main()
