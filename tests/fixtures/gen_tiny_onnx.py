#!/usr/bin/env python3
"""Regenerate tests/fixtures/tiny.onnx — the smallest useful model for the
nncase kmodel round-trip test (t4): one Conv + one Relu on a 1x3x8x8 input.

Conv (not just Relu) so the compile exercises real weight handling, while the
file stays a few KB. Run inside any env with `pip install onnx numpy`:

    python3 tests/fixtures/gen_tiny_onnx.py tests/fixtures/tiny.onnx
"""
import sys

import numpy as np
import onnx
from onnx import TensorProto, helper


def build():
    x = helper.make_tensor_value_info("x", TensorProto.FLOAT, [1, 3, 8, 8])
    y = helper.make_tensor_value_info("y", TensorProto.FLOAT, [1, 4, 8, 8])
    # Deterministic weights: no RNG so regeneration is byte-stable.
    w_data = (np.arange(4 * 3 * 3 * 3, dtype=np.float32) % 7 - 3) / 10.0
    w = helper.make_tensor("w", TensorProto.FLOAT, [4, 3, 3, 3], w_data.tobytes(), raw=True)
    conv = helper.make_node("Conv", ["x", "w"], ["c"], pads=[1, 1, 1, 1])
    relu = helper.make_node("Relu", ["c"], ["y"])
    graph = helper.make_graph([conv, relu], "tiny", [x], [y], initializer=[w])
    model = helper.make_model(
        graph, opset_imports=[helper.make_opsetid("", 13)], producer_name="k230-builder-tests"
    )
    model.ir_version = 7
    onnx.checker.check_model(model)
    return model


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "tiny.onnx"
    onnx.save(build(), out)
    print(f"wrote {out}")
