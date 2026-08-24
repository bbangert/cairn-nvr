#!/usr/bin/env python3
"""Post-export QDQ qparam audit: does the graph say what the HTP will do?

The defect this exists to make unshippable: a detector's class-score
Sigmoid quantized to a *representable maximum* below 1.0. Sigmoid's range
is (0, 1) by construction, so a Q/DQ pair whose ceiling — `(qmax - zp) *
scale` — reads 0.13 is not a resolution choice, it is a hard clip on
every confident detection, and no label histogram can see it (the labels
are still there, just capped). Mean-of-per-frame-extremes calibration
produced exactly that on three shipped rungs; `check()` fails the export
instead.

Two further checks ride along because both were live defects and both are
one graph walk away:

- Q/DQ scale agreement per tensor. The QNN EP rewrites 16-bit Sigmoid
  output qparams to `1/65536` inside the EP at graph-build time while the
  graph's own DequantizeLinear keeps whatever was calibrated. When the
  two disagree the HTP multiplies every score by the calibrated maximum,
  invisibly and only on the HTP. Equal scales on both sides is the file
  agreeing with the hardware.
- FP32 islands. `Sub`/`Div` sit in the middle of a `dist2bbox` head, and
  ORT's default op registry does not quantize them — they become FP32
  regions that force QNN partition boundaries where scores are formed.

Import `check` from the exporter, or run it standalone:
  qparam_gate.py <model-qdq.onnx> [--min-ceiling 0.95]
"""
import argparse
import os
import sys

import numpy as np
import onnx
from onnx import numpy_helper

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from finite import all_finite_or_none  # noqa: E402

# Ops that move or regroup a tensor without changing its values. A Sigmoid
# whose output reaches a graph output through only these is a score
# branch: the head concatenates its sigmoids straight into the output
# tensor. A SiLU's internal sigmoid never qualifies — it passes through
# `Mul`, which is not here.
PASSTHROUGH = frozenset(
    {
        "QuantizeLinear",
        "DequantizeLinear",
        "Concat",
        "Reshape",
        "Transpose",
        "Slice",
        "Split",
        "Squeeze",
        "Unsqueeze",
        "Identity",
        "Cast",
    }
)

# Representable maxima below this are a baked ceiling, not a rounding
# choice. A correctly calibrated score sigmoid lands at ~0.98 (true
# MinMax over frames that contain the class) or at 0.99998 (the QNN
# 16-bit Sigmoid override, 65535/65536).
#
# The check means something different at each activation width, and both
# meanings are wanted. At a16 the qparams come from the EP's fixed
# override, so the ceiling reads 0.99998 whenever the file agrees with
# the hardware and something is wrong whenever it does not. At a8 there
# is no override — the ceiling is the true calibrated maximum — so this
# is a test of the CALIBRATION SET: it fails when no frame drove that
# score branch near saturation, which is the same thing as saying the set
# does not contain a confident example of the class at that FPN level. A
# w8a8 gate failure is therefore a finding about the frames, not
# necessarily about the recipe, and the fix is more representative
# frames (or a deliberate per-tensor override, `get_qnn_qdq_config(
# init_overrides=...)`, since a sigmoid's (0, 1) range is known a priori
# and need not be measured at all).
DEFAULT_MIN_CEILING = 0.95

QMAX = {
    onnx.TensorProto.UINT8: 255,
    onnx.TensorProto.INT8: 127,
    onnx.TensorProto.UINT16: 65535,
    onnx.TensorProto.INT16: 32767,
}

# The QNN EP rewrites Sigmoid output qparams to these canonical values at
# session build. Internal Q/DQ agreement is not enough: a calibrated
# (unpinned) scale agrees with itself in the file and still disagrees with
# the hardware — HTP-only, invisibly. A score sigmoid must carry the pin.
PINNED_SIGMOID = {
    onnx.TensorProto.UINT16: 1.0 / 65536,
    onnx.TensorProto.UINT8: 1.0 / 256,
}


class GateFailure(Exception):
    """The export is unshippable. Raised rather than sys.exit so the
    exporter can delete the artifact it just wrote."""


def _initializers(graph):
    return {i.name: numpy_helper.to_array(i) for i in graph.initializer}


def _shapes(model):
    """Tensor name -> spatial dims, best effort. Shape inference is not
    guaranteed across every quantized graph, so callers treat a miss as
    'unknown level', never as an error."""
    try:
        inferred = onnx.shape_inference.infer_shapes(model, strict_mode=False)
    except Exception:
        return {}
    out = {}
    for vi in list(inferred.graph.value_info) + list(inferred.graph.output):
        dims = [
            d.dim_value if d.HasField("dim_value") and d.dim_value > 0 else None
            for d in vi.type.tensor_type.shape.dim
        ]
        out[vi.name] = dims
    return out


def _reaches_output(start, consumers, outputs, memo):
    """Does `start` reach a graph output through PASSTHROUGH ops only?"""
    if start in memo:
        return memo[start]
    # Provisional False breaks cycles; ONNX graphs are acyclic, so this
    # only guards against a malformed model rather than a real loop.
    memo[start] = False
    if start in outputs:
        memo[start] = True
        return True
    for node in consumers.get(start, ()):
        if node.op_type not in PASSTHROUGH:
            continue
        if any(_reaches_output(o, consumers, outputs, memo) for o in node.output):
            memo[start] = True
            return True
    return memo[start]


def _q_of(tensor, consumers):
    for node in consumers.get(tensor, ()):
        if node.op_type == "QuantizeLinear":
            return node
    return None


def _qparams(node, inits):
    """(scale, zero_point, elem_type, n_scale_elems) of a Q/DQ node, or
    None if either is a runtime value rather than an initializer.
    scale/zero_point are element zero; callers grading correctness must
    check n_scale_elems — reducing a per-axis parameter to its first
    element would grade one class and vouch for all of them."""
    if len(node.input) < 2 or node.input[1] not in inits:
        return None
    scale_arr = np.asarray(inits[node.input[1]]).reshape(-1)
    scale = float(scale_arr[0])
    zp_arr = inits.get(node.input[2]) if len(node.input) > 2 else None
    if zp_arr is None:
        return scale, 0, onnx.TensorProto.UINT8, scale_arr.size
    zp = int(np.asarray(zp_arr).reshape(-1)[0])
    elem = onnx.helper.np_dtype_to_tensor_dtype(np.asarray(zp_arr).dtype)
    return scale, zp, elem, scale_arr.size


def _index(graph):
    consumers, producers = {}, {}
    for node in graph.node:
        for i in node.input:
            consumers.setdefault(i, []).append(node)
        for o in node.output:
            producers[o] = node
    return consumers, producers


def score_sigmoids(graph):
    """The Sigmoid nodes whose output lands in a graph output tensor.

    Works on an FP32 graph and on a quantized one — the reachability walk
    tolerates the Q/DQ pairs rather than requiring them — because the
    exporter needs these names *before* quantizing (to override their
    qparams) and the gate needs them after (to check what was written).
    """
    consumers, _ = _index(graph)
    outputs = {o.name for o in graph.output}
    memo = {}
    return [
        n
        for n in graph.node
        if n.op_type == "Sigmoid"
        and _reaches_output(n.output[0], consumers, outputs, memo)
    ]


def score_sigmoid_tensors(model_path):
    return [n.output[0] for n in score_sigmoids(onnx.load(model_path).graph)]


def audit(model_path):
    """Everything the gate and the operator summary need, in one walk."""
    model = onnx.load(model_path)
    graph = model.graph
    inits = _initializers(graph)
    shapes = _shapes(model)
    outputs = {o.name for o in graph.output}
    consumers, producers = _index(graph)

    memo = {}
    scores = []
    for node in score_sigmoids(graph):
        tensor = node.output[0]
        q = _q_of(tensor, consumers)
        entry = {
            "node": node.name or tensor,
            "tensor": tensor,
            "dims": shapes.get(tensor),
            "scale": None,
            "zero_point": None,
            "elem_type": None,
            "ceiling": None,
            "dq_scale": None,
        }
        if q is not None:
            qp = _qparams(q, inits)
            if qp is not None:
                scale, zp, elem, n = qp
                entry.update(
                    scale=scale,
                    zero_point=zp,
                    elem_type=elem,
                    scale_elems=n,
                    ceiling=(QMAX.get(elem, 255) - zp) * scale,
                )
            # The matching DQ reads the same scale initializer in a
            # well-formed ORT QDQ graph. Reading it separately is the
            # point: a divergence here is the EP-vs-graph mismatch.
            for dq in consumers.get(q.output[0], ()):
                if dq.op_type == "DequantizeLinear":
                    dqp = _qparams(dq, inits)
                    if dqp is not None:
                        entry["dq_scale"] = dqp[0]
                        entry["dq_zero_point"] = dqp[1]
                        entry["dq_elem_type"] = dqp[2]
                        entry["dq_scale_elems"] = dqp[3]
                    break
        scores.append(entry)

    return {
        "scores": scores,
        "islands": _fp32_islands(graph, consumers, producers),
        "op_census": _census(graph),
        "head_concats": _head_concats(graph, consumers, producers, inits, outputs, memo),
    }


def _fp32_islands(graph, consumers, producers):
    """Connected FP32 regions — nodes the EP cannot fuse into quantized
    kernels.

    A node executes quantized only when its whole DQ -> op -> Q bracket
    is present: every produced input arrives via DequantizeLinear and
    every consumer is a QuantizeLinear. One-sided adjacency is NOT
    participation — in DQ -> A -> B -> Q both A and B run FP32, and the
    lone bracketed node is the only shape that fuses. Cast is excluded
    by `get_qnn_qdq_config` on purpose (it moves types, it does not
    compute). Each region is one entry: on QNN it is a partition
    boundary with a CPU round trip.
    """

    def fused(node):
        prod = [producers[i] for i in node.input if i and i in producers]
        cons = [c for o in node.output for c in consumers.get(o, ())]
        return (
            bool(prod)
            and all(p.op_type == "DequantizeLinear" for p in prod)
            and bool(cons)
            and all(c.op_type == "QuantizeLinear" for c in cons)
        )

    skip = ("QuantizeLinear", "DequantizeLinear", "Cast")
    floats = [n for n in graph.node if n.op_type not in skip and not fused(n)]
    index = {id(n): k for k, n in enumerate(floats)}
    parent = list(range(len(floats)))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    by_out = {o: n for n in floats for o in n.output}
    for n in floats:
        for i in n.input:
            p = by_out.get(i)
            if p is not None:
                a, b = find(index[id(n)]), find(index[id(p)])
                if a != b:
                    parent[a] = b
    regions = {}
    for n in floats:
        regions.setdefault(find(index[id(n)]), []).append(n)
    out = []
    for nodes in regions.values():
        ops = {}
        for n in nodes:
            ops[n.op_type] = ops.get(n.op_type, 0) + 1
        label = "+".join(f"{k} x{v}" for k, v in sorted(ops.items()))
        out.append((label, nodes[0].name or nodes[0].output[0]))
    return out


def _census(graph):
    census = {}
    for node in graph.node:
        census[node.op_type] = census.get(node.op_type, 0) + 1
    return dict(sorted(census.items(), key=lambda kv: -kv[1]))


def _head_concats(graph, consumers, producers, inits, outputs, memo):
    """Input vs output scales of the Concats that join boxes to scores.

    Concat is not in ORT's QDQ registry, so its inputs and its output are
    calibrated independently and the widest input range wins. The bbox
    branch is ~10-40x wider than a 0..1 score branch, so at 8-bit
    activations the whole score range can collapse into ~50 of 255 codes.
    Informational, not a gate: it is the number to reach for when a w8a8
    rung reads degraded, and the lever is a per-tensor override rather
    than a wider activation type.
    """
    rows = []
    for node in graph.node:
        if node.op_type != "Concat":
            continue
        if not any(_reaches_output(o, consumers, outputs, memo) for o in node.output):
            continue
        ins = []
        for i in node.input:
            p = producers.get(i)
            if p is not None and p.op_type == "DequantizeLinear":
                qp = _qparams(p, inits)
                if qp:
                    ins.append(qp[0])
        outs = None
        for c in consumers.get(node.output[0], ()):
            if c.op_type == "QuantizeLinear":
                qp = _qparams(c, inits)
                if qp:
                    outs = qp[0]
                break
        if ins and outs:
            rows.append((node.name or node.output[0], ins, outs))
    return rows


def _stride_label(dims, input_size):
    """A readable name for which part of the head a sigmoid covers.

    The two families label differently and conflating them misreads the
    summary. A yolox head sigmoids each FPN level separately, so its
    output is [1, C, H, W] and H gives the stride — three levels, three
    ceilings, and the broken artifacts differed per level. A yolov8/
    yolo26 raw head concatenates the levels before the sigmoid, so there
    is exactly ONE score sigmoid of shape [1, 80, A] covering all of
    them; reading its dims as spatial would print a confident "s8" for a
    tensor that has no stride.
    """
    if not dims or not input_size:
        return "?"
    if len(dims) == 4 and dims[2] and dims[3] and dims[2] == dims[3]:
        return f"s{input_size // dims[2]} {dims[3]}x{dims[2]}"
    if len(dims) == 3 and dims[1] and dims[2]:
        return f"all-levels {dims[1]}x{dims[2]}"
    return "?"


def summarize(report, input_size=None, out=sys.stdout):
    scores = report["scores"]
    print("  qparam summary — class-score sigmoids:", file=out)
    if not scores:
        print("    (none found)", file=out)
    for e in scores:
        elem = onnx.TensorProto.DataType.Name(e["elem_type"]) if e["elem_type"] else "?"
        ceiling = f"{e['ceiling']:.5f}" if e["ceiling"] is not None else "?"
        scale = f"{e['scale']:.6e}" if e["scale"] is not None else "?"
        mismatch = (
            ""
            if e["dq_scale"] is None or e["scale"] is None
            or abs(e["dq_scale"] - e["scale"]) <= 1e-12
            else f"  !! DQ scale {e['dq_scale']:.6e} != Q scale"
        )
        print(
            f"    {_stride_label(e['dims'], input_size):>12}  {elem:<6} "
            f"scale={scale} zp={e['zero_point']} ceiling={ceiling}"
            f"  [{e['node']}]{mismatch}",
            file=out,
        )
    islands = report["islands"]
    if islands:
        print(
            "  FP32 regions (outside the quantized domain): "
            + "; ".join(label for label, _ in sorted(islands)),
            file=out,
        )
    else:
        print("  FP32 islands: none", file=out)
    for name, ins, outs in report["head_concats"]:
        widen = outs / min(ins) if min(ins) > 0 else float("inf")
        # Codes left for the 0..1 score range after the Concat's own
        # scale is applied. This is the number that decides whether a
        # width is usable, and it is not the sigmoid's ceiling: a score
        # branch can carry a perfect 0.996 ceiling and still be requan-
        # tized to nothing one node later. Two families, same recipe:
        # yolox boxes are stride-relative so its output keeps ~10 000
        # codes, while a yolov8/yolo26 dist2bbox head emits boxes in
        # PIXELS (0..640) and drags the shared output scale up with them,
        # leaving ~90 codes at 16-bit — and ~0 at 8-bit, which is a
        # sufficient explanation for w8a8 being unusable on that family
        # while yolox tolerates it.
        codes = 1.0 / outs if outs > 0 else float("inf")
        warn = "  <-- WARNING: scores have no usable resolution" if codes < 8 else ""
        print(
            f"  head Concat {name}: in={[f'{s:.3e}' for s in ins]} "
            f"out={outs:.3e} ({widen:.1f}x the narrowest input; "
            f"{codes:.0f} codes across 0..1){warn}",
            file=out,
        )


def check(model_path, min_ceiling=DEFAULT_MIN_CEILING, input_size=None, out=sys.stdout):
    """Audit, print the operator summary, and raise on an unshippable graph."""
    report = audit(model_path)
    summarize(report, input_size=input_size, out=out)

    scores = report["scores"]
    if not scores:
        # Every family this pipeline handles (yolox, yolov8/yolo26 raw
        # heads) sigmoids its class scores into the output tensor. Finding
        # none means the walk did not recognise the head, and a gate that
        # cannot see the thing it guards must not report success.
        raise GateFailure(
            f"{model_path}: no class-score Sigmoid reaches a graph output — "
            "the qparam gate could not locate the head, so it cannot vouch "
            "for this artifact"
        )

    bad = []
    for e in scores:
        if e["ceiling"] is None:
            bad.append(f"{e['node']}: no Q/DQ qparams on the sigmoid output")
        elif not all_finite_or_none(e["scale"], e["dq_scale"], e["ceiling"]):
            # NaN fails open through every </>/abs comparison below.
            bad.append(
                f"{e['node']}: non-finite qparams (scale {e['scale']}, "
                f"DQ {e['dq_scale']}, ceiling {e['ceiling']})"
            )
        elif e.get("scale_elems", 1) != 1 or e.get("dq_scale_elems", 1) != 1:
            # Activation Q/DQ must be per-tensor. Grading element zero of
            # a per-axis parameter would vouch for every class on the
            # strength of the first one.
            bad.append(
                f"{e['node']}: non-scalar activation qparams "
                f"(Q {e.get('scale_elems', 1)} / DQ {e.get('dq_scale_elems', 1)} "
                "elements) — per-tensor required"
            )
        elif e["ceiling"] < min_ceiling:
            bad.append(
                f"{e['node']} ({_stride_label(e['dims'], input_size)}): "
                f"ceiling {e['ceiling']:.4f} < {min_ceiling}"
            )
        elif e["dq_scale"] is None:
            # A Q with no located DQ is not "agreement": it is the agreement
            # check never having run — either a malformed graph or a walker
            # miss, and both must fail rather than let this gate vouch for
            # the exact defect class (Q/DQ disagreement) it exists to block.
            bad.append(f"{e['node']}: Q has no matching DQ — scale agreement unverifiable")
        elif abs(e["dq_scale"] - e["scale"]) > 1e-12:
            bad.append(
                f"{e['node']}: Q scale {e['scale']:.6e} != DQ scale "
                f"{e['dq_scale']:.6e}"
            )
        elif (
            e.get("dq_zero_point") != e["zero_point"]
            or e.get("dq_elem_type") != e["elem_type"]
        ):
            # Scale agreement alone is not pair agreement: a DQ with the
            # same scale but a nonzero zero point (or another dtype)
            # offsets every dequantized score.
            bad.append(
                f"{e['node']}: DQ zp/type ({e.get('dq_zero_point')}/"
                f"{e.get('dq_elem_type')}) disagree with Q "
                f"({e['zero_point']}/{e['elem_type']})"
            )
        elif e["elem_type"] not in PINNED_SIGMOID:
            bad.append(
                f"{e['node']}: score sigmoid quantized to elem_type "
                f"{e['elem_type']} — no known EP pin to check against"
            )
        elif (
            abs(e["scale"] - PINNED_SIGMOID[e["elem_type"]]) > 1e-12
            or e["zero_point"] != 0
        ):
            bad.append(
                f"{e['node']}: scale {e['scale']:.6e} zp {e['zero_point']} is "
                f"not the pinned {PINNED_SIGMOID[e['elem_type']]:.6e}/0 the "
                "QNN EP writes at session build — the file agrees with "
                "itself but not with the hardware"
            )
    if bad:
        raise GateFailure(
            f"{model_path}: score-sigmoid qparam gate FAILED\n    "
            + "\n    ".join(bad)
        )
    print(
        f"  gate PASS: {len(scores)} score sigmoids, "
        f"min ceiling {min(e['ceiling'] for e in scores):.5f} >= {min_ceiling}",
        file=out,
    )
    return report


def main():
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("model")
    ap.add_argument("--min-ceiling", type=float, default=DEFAULT_MIN_CEILING)
    ap.add_argument(
        "--input-size",
        type=int,
        default=None,
        help="Model input side, to label sigmoids by FPN stride",
    )
    args = ap.parse_args()
    try:
        check(args.model, args.min_ceiling, args.input_size)
    except GateFailure as e:
        print(f"FAIL: {e}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
