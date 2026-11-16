import numpy as np
import onnx
import pytest
from onnx import TensorProto as T, helper as h, numpy_helper as nh

import onnx_edit


def split_head():
    # cls is a graph output AND feeds the ReduceSum, like the split heads
    nodes = [
        h.make_node("Conv", ["x", "w"], ["box_raw"], name="boxconv"),
        h.make_node("Sigmoid", ["box_raw"], ["cls_raw"], name="sig"),
        h.make_node("ReduceSum", ["cls_raw"], ["sum_raw"], name="sum", keepdims=1, axes=[1]),
    ]
    vi = lambda n, c: h.make_tensor_value_info(n, T.FLOAT, [1, c, 4, 4])
    g = h.make_graph(nodes, "g", [vi("x", 3)], [vi("box_raw", 2), vi("cls_raw", 2), vi("sum_raw", 1)],
                     [nh.from_array(np.ones((2, 3, 1, 1), np.float32), "w")])
    return h.make_model(g, opset_imports=[h.make_opsetid("", 12)])


def test_rename_updates_producer_and_consumers():
    m = onnx_edit.rename_outputs(split_head(), ["box0", "cls0", "sum0"])
    onnx.checker.check_model(m)
    assert [o.name for o in m.graph.output] == ["box0", "cls0", "sum0"]
    by_name = {n.name: n for n in m.graph.node}
    assert list(by_name["boxconv"].output) == ["box0"]
    assert list(by_name["sig"].input) == ["box0"]
    assert list(by_name["sig"].output) == ["cls0"]
    assert list(by_name["sum"].input) == ["cls0"]


def test_rename_rejects_wrong_count_and_existing_name():
    with pytest.raises(ValueError):
        onnx_edit.rename_outputs(split_head(), ["a", "b"])
    with pytest.raises(ValueError):
        onnx_edit.rename_outputs(split_head(), ["box0", "cls0", "x"])
    with pytest.raises(ValueError):
        onnx_edit.rename_outputs(split_head(), ["box0", "cls0", "w"])


def test_set_input_size_recomputes_output_shape():
    c = 5
    nodes = [
        h.make_node("Conv", ["images", "w"], ["y"], name="conv"),
        h.make_node("Reshape", ["y", "shape"], ["output"], name="rs"),
    ]
    g = h.make_graph(
        nodes, "g",
        [h.make_tensor_value_info("images", T.FLOAT, [1, 3, 8, 8])],
        [h.make_tensor_value_info("output", T.FLOAT, [1, c, 64])],
        [nh.from_array(np.ones((c, 3, 1, 1), np.float32), "w"),
         nh.from_array(np.array([1, c, -1], np.int64), "shape")],
        value_info=[h.make_tensor_value_info("y", T.FLOAT, [1, c, 8, 8])],
    )
    m = h.make_model(g, opset_imports=[h.make_opsetid("", 12)])
    m = onnx_edit.set_input_size(m, 12, 20)
    # direct, because the onnxruntime half below is skipped where it is not installed
    assert [d.dim_value for d in m.graph.input[0].type.tensor_type.shape.dim] == [1, 3, 12, 20]
    dims = [d.dim_value for d in m.graph.output[0].type.tensor_type.shape.dim]
    assert dims == [1, c, 12 * 20]
    ort = pytest.importorskip("onnxruntime")
    s = ort.InferenceSession(m.SerializeToString(), providers=["CPUExecutionProvider"])
    out = s.run(None, {"images": np.zeros((1, 3, 12, 20), np.float32)})[0]
    assert out.shape == (1, c, 240)


def internal_chain():
    nodes = [h.make_node("Conv", ["images", "w"], ["y"], name="conv"), h.make_node("Relu", ["y"], ["output"], name="r")]
    g = h.make_graph(nodes, "g", [h.make_tensor_value_info("images", T.FLOAT, [1, 3, 8, 8])],
                     [h.make_tensor_value_info("output", T.FLOAT, [1, 5, 8, 8])],
                     [nh.from_array(np.ones((5, 3, 1, 1), np.float32), "w")])
    return h.make_model(g, opset_imports=[h.make_opsetid("", 12)])


def test_rename_rejects_internal_tensor_name():
    with pytest.raises(ValueError):
        onnx_edit.rename_outputs(internal_chain(), ["y"])


def test_rename_renames_value_info():
    m = internal_chain()
    m.graph.value_info.append(h.make_tensor_value_info("output", T.FLOAT, [1, 5, 8, 8]))
    assert [v.name for v in onnx_edit.rename_outputs(m, ["o2"]).graph.value_info] == ["o2"]
