import json
import os
import subprocess
import sys

import numpy as np
import onnx
import pytest
from onnx import TensorProto, helper, numpy_helper

from u8_io_surgery import entry_surgery, exit_surgery, quantize_codes

TOOL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARTIFACT = os.path.join(TOOL_DIR, "out-20260820", "artifacts", "yolox_s-qdq-a8.onnx")


def qdq_model(entry_scale=0.5, entry_zp=10, stem=None, entry_paths=None):
    """Minimal QDQ graph: [stem ->] Q -> DQ -> Relu -> Q -> DQ -> output.

    `stem` inserts a Slice between input and entry Q; `entry_paths` builds
    two Slice->Q paths with the given per-path qparams to model a
    focus-style fan-out.
    """
    inits = [
        numpy_helper.from_array(np.float32(entry_scale), "in_s"),
        numpy_helper.from_array(np.uint8(entry_zp), "in_zp"),
        numpy_helper.from_array(np.float32(0.25), "out_s"),
        numpy_helper.from_array(np.uint8(3), "out_zp"),
        numpy_helper.from_array(np.array([0], dtype=np.int64), "starts"),
        numpy_helper.from_array(np.array([2], dtype=np.int64), "ends"),
        numpy_helper.from_array(np.array([2], dtype=np.int64), "axes"),
    ]
    nodes = []
    if entry_paths is not None:
        (s_a, zp_a), (s_b, zp_b) = entry_paths
        inits += [
            numpy_helper.from_array(np.float32(s_a), "a_s"),
            numpy_helper.from_array(np.uint8(zp_a), "a_zp"),
            numpy_helper.from_array(np.float32(s_b), "b_s"),
            numpy_helper.from_array(np.uint8(zp_b), "b_zp"),
        ]
        nodes += [
            helper.make_node("Slice", ["x", "starts", "ends", "axes"], ["sa"], name="slice_a"),
            helper.make_node("Slice", ["x", "starts", "ends", "axes"], ["sb"], name="slice_b"),
            helper.make_node("QuantizeLinear", ["sa", "a_s", "a_zp"], ["qa"], name="q_a"),
            helper.make_node("QuantizeLinear", ["sb", "b_s", "b_zp"], ["qb"], name="q_b"),
            helper.make_node("DequantizeLinear", ["qa", "a_s", "a_zp"], ["da"], name="dq_a"),
            helper.make_node("DequantizeLinear", ["qb", "b_s", "b_zp"], ["db"], name="dq_b"),
            helper.make_node("Concat", ["da", "db"], ["relu_in"], name="cat", axis=2),
        ]
    elif stem:
        nodes += [
            helper.make_node("Slice", ["x", "starts", "ends", "axes"], ["stem_out"], name="stem"),
            helper.make_node("QuantizeLinear", ["stem_out", "in_s", "in_zp"], ["q0"], name="entry_q"),
            helper.make_node("DequantizeLinear", ["q0", "in_s", "in_zp"], ["relu_in"], name="entry_dq"),
        ]
    else:
        nodes += [
            helper.make_node("QuantizeLinear", ["x", "in_s", "in_zp"], ["q0"], name="entry_q"),
            helper.make_node("DequantizeLinear", ["q0", "in_s", "in_zp"], ["relu_in"], name="entry_dq"),
        ]
    nodes += [
        helper.make_node("Relu", ["relu_in"], ["relu_out"], name="relu"),
        helper.make_node("QuantizeLinear", ["relu_out", "out_s", "out_zp"], ["q1"], name="exit_q"),
        helper.make_node("DequantizeLinear", ["q1", "out_s", "out_zp"], ["y"], name="exit_dq"),
    ]
    out_shape = [1, 1, 1, 2] if stem else [1, 1, 2, 2]
    graph = helper.make_graph(
        nodes,
        "t",
        [helper.make_tensor_value_info("x", TensorProto.FLOAT, [1, 1, 2, 2])],
        [helper.make_tensor_value_info("y", TensorProto.FLOAT, out_shape)],
        inits,
    )
    return helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)])


def test_entry_surgery_direct_q():
    m = qdq_model()
    qp = entry_surgery(m.graph)
    assert qp == {"name": "x", "scale": 0.5, "zero_point": 10}
    assert m.graph.input[0].type.tensor_type.elem_type == TensorProto.UINT8
    ops = [n.op_type for n in m.graph.node]
    # The entry Q is gone; the internal pair (entry DQ / exit Q-DQ) survives.
    assert ops == ["DequantizeLinear", "Relu", "QuantizeLinear", "DequantizeLinear"]
    assert m.graph.node[0].input[0] == "x"
    onnx.checker.check_model(m)


def test_entry_surgery_traverses_stem_and_retypes_it():
    m = qdq_model(stem=True)
    vi = helper.make_tensor_value_info("stem_out", TensorProto.FLOAT, [1, 1, 1, 2])
    m.graph.value_info.append(vi)
    entry_surgery(m.graph)
    kinds = {v.name: v.type.tensor_type.elem_type for v in m.graph.value_info}
    assert kinds["stem_out"] == TensorProto.UINT8
    # The stem Slice now feeds the entry DQ directly, in uint8.
    dq = next(n for n in m.graph.node if n.name == "entry_dq")
    assert dq.input[0] == "stem_out"
    onnx.checker.check_model(m)


def test_entry_surgery_rejects_disagreeing_paths():
    m = qdq_model(entry_paths=[(1.0, 0), (0.5, 0)])
    with pytest.raises(SystemExit):
        entry_surgery(m.graph)


def test_entry_surgery_accepts_agreeing_fanout():
    m = qdq_model(entry_paths=[(1.0, 0), (1.0, 0)])
    qp = entry_surgery(m.graph)
    assert qp == {"name": "x", "scale": 1.0, "zero_point": 0}
    onnx.checker.check_model(m)


def test_entry_surgery_rejects_opaque_op():
    m = qdq_model()
    # A compute op between input and Q means the stem cannot carry codes.
    m.graph.node.insert(0, helper.make_node("Relu", ["x"], ["rx"], name="pre"))
    m.graph.node[1].input[0] = "rx"
    with pytest.raises(SystemExit):
        entry_surgery(m.graph)


def test_entry_surgery_rejects_per_axis_qparams():
    m = qdq_model()
    per_axis = numpy_helper.from_array(np.array([0.5, 0.25], dtype=np.float32), "in_s")
    m.graph.initializer[0].CopyFrom(per_axis)
    with pytest.raises(SystemExit):
        entry_surgery(m.graph)


def test_surgery_rejects_non_finite_positive_scale():
    # A zero or NaN edge scale would divide to garbage in quantize and ship
    # a sidecar the Rust loader refuses — same rule, enforced at export.
    for bad in (0.0, float("nan")):
        m = qdq_model(entry_scale=bad)
        with pytest.raises(SystemExit):
            entry_surgery(m.graph)


def test_exit_surgery_renames_code_tensor_to_output():
    m = qdq_model()
    qp = exit_surgery(m.graph)
    assert qp == {"y": {"scale": 0.25, "zero_point": 3}}
    out = m.graph.output[0]
    assert out.type.tensor_type.elem_type == TensorProto.UINT8
    # Host-side lookup by name survives: the exit Q now produces "y".
    exit_q = next(n for n in m.graph.node if n.name == "exit_q")
    assert list(exit_q.output) == ["y"]
    assert all(n.op_type != "DequantizeLinear" or n.name != "exit_dq" for n in m.graph.node)
    onnx.checker.check_model(m)


def test_exit_surgery_catches_an_unnamed_extra_consumer():
    # ONNX node names are optional: an UNNAMED node consuming the quantized
    # code tensor must still block the rewrite (identity compare, not name).
    m = qdq_model()
    exit_dq = next(n for n in m.graph.node if n.name == "exit_dq")
    exit_dq.name = ""
    m.graph.node.append(helper.make_node("Identity", ["q1"], ["leak"]))
    with pytest.raises(SystemExit):
        exit_surgery(m.graph)


def test_exit_surgery_rejects_non_dq_output():
    m = qdq_model()
    m.graph.node.remove(next(n for n in m.graph.node if n.name == "exit_dq"))
    relu_q = next(n for n in m.graph.node if n.name == "exit_q")
    relu_q.output[0] = "y"
    with pytest.raises(SystemExit):
        exit_surgery(m.graph)


def test_quantize_codes_round_half_even_and_saturate():
    # ONNX QuantizeLinear rounds half to even, then saturates: the Rust
    # packer mirrors exactly this arithmetic, so pin it here.
    v = np.array([0.5, 1.5, 2.5, -100.0, 1000.0], dtype=np.float32)
    codes = quantize_codes(v, 1.0, 0)
    assert codes.tolist() == [0, 2, 2, 0, 255]
    codes = quantize_codes(np.array([114.0], dtype=np.float32), 0.5, 3)
    assert codes.tolist() == [231]


@pytest.mark.skipif(not os.path.exists(ARTIFACT), reason="yolox_s-a8 artifact not present")
def test_real_artifact_end_to_end(tmp_path):
    # The full tool run on the real rung, --verify included: CPU-EP must
    # produce bit-identical results once the sidecar formulas are applied.
    out = tmp_path / "yolox_s-qdq-a8-u8io.onnx"
    subprocess.run(
        [sys.executable, os.path.join(TOOL_DIR, "u8_io_surgery.py"),
         ARTIFACT, str(out), "--mode", "both", "--verify"],
        check=True, cwd=TOOL_DIR,
    )
    sidecar = json.loads((tmp_path / "yolox_s-qdq-a8-u8io.onnx.qparams.json").read_text())
    assert sidecar["input"] == {"name": "images", "scale": 1.0, "zero_point": 0}
    assert list(sidecar["outputs"]) == ["output"]
    assert sidecar["outputs"]["output"]["zero_point"] == 102
