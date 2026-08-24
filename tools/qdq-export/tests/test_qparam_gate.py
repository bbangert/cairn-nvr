"""The qparam gate against hand-built QDQ graphs — each failure class
that shipped (or nearly shipped) as a real export defect gets a graph
that must stay unshippable."""
import io

import numpy as np
import onnx
import pytest
from onnx import TensorProto, helper, numpy_helper

from qparam_gate import GateFailure, check


def build(tmp_path, q_scale, zp_dtype=np.uint16, dq_scale=None, dq_zp=None,
          head_op="Sigmoid"):
    """<head_op> -> Q -> DQ -> output, the minimal score branch."""
    dq_scale = q_scale if dq_scale is None else dq_scale
    inits = [
        numpy_helper.from_array(np.asarray(q_scale, np.float32), "q_scale"),
        numpy_helper.from_array(np.zeros_like(np.asarray(q_scale), zp_dtype), "q_zp"),
        numpy_helper.from_array(np.asarray(dq_scale, np.float32), "dq_scale"),
        numpy_helper.from_array(
            np.asarray(0 if dq_zp is None else dq_zp, zp_dtype), "dq_zp"
        ),
    ]
    nodes = [
        helper.make_node(head_op, ["x"], ["s"], name="head"),
        helper.make_node("QuantizeLinear", ["s", "q_scale", "q_zp"], ["q"]),
        helper.make_node("DequantizeLinear", ["q", "dq_scale", "dq_zp"], ["y"]),
    ]
    graph = helper.make_graph(
        nodes, "g",
        [helper.make_tensor_value_info("x", TensorProto.FLOAT, [1, 80, 100])],
        [helper.make_tensor_value_info("y", TensorProto.FLOAT, [1, 80, 100])],
        inits,
    )
    model = helper.make_model(
        graph, opset_imports=[helper.make_opsetid("", 21)], ir_version=10
    )
    path = str(tmp_path / "m.onnx")
    onnx.save(model, path)
    return path


PINNED_A16 = 1.0 / 65536


def test_pinned_sigmoid_passes(tmp_path):
    report = check(build(tmp_path, PINNED_A16), out=io.StringIO())
    assert len(report["scores"]) == 1


def test_per_axis_activation_qparams_fail(tmp_path):
    # Grading element zero of a per-axis parameter would vouch for every
    # class on the strength of the first one.
    path = build(tmp_path, np.full(80, PINNED_A16, np.float32))
    with pytest.raises(GateFailure, match="per-tensor required"):
        check(path, out=io.StringIO())


def test_non_finite_qparams_fail(tmp_path):
    # NaN fails open through every </>/abs comparison in the gate.
    path = build(tmp_path, np.float32("nan"))
    with pytest.raises(GateFailure, match="non-finite qparams"):
        check(path, out=io.StringIO())


def test_baked_ceiling_fails(tmp_path):
    # Defect 1: a Sigmoid whose representable maximum is a hard clip.
    path = build(tmp_path, 0.13 / 255, zp_dtype=np.uint8)
    with pytest.raises(GateFailure, match="ceiling"):
        check(path, out=io.StringIO())


def test_q_dq_scale_disagreement_fails(tmp_path):
    # Defect 2: the EP honors one scale, the graph's DQ another.
    path = build(tmp_path, PINNED_A16, dq_scale=2.0 / 65536)
    with pytest.raises(GateFailure, match="!= DQ scale"):
        check(path, out=io.StringIO())


def test_dq_zero_point_disagreement_fails(tmp_path):
    path = build(tmp_path, PINNED_A16, dq_zp=3)
    with pytest.raises(GateFailure, match="DQ zp/type"):
        check(path, out=io.StringIO())


def test_unpinned_but_self_consistent_scale_fails(tmp_path):
    # The file agreeing with itself is not the file agreeing with the
    # hardware: the QNN EP rewrites Sigmoid output qparams at build.
    path = build(tmp_path, 1.6e-5)
    with pytest.raises(GateFailure, match="not the pinned"):
        check(path, out=io.StringIO())


def test_unrecognized_head_fails(tmp_path):
    # A gate that cannot see the thing it guards must not report success.
    path = build(tmp_path, PINNED_A16, head_op="Relu")
    with pytest.raises(GateFailure, match="no class-score Sigmoid"):
        check(path, out=io.StringIO())
