"""Converte o GLB do rebocador em uma malha compacta para o Flutter.

O aplicativo desenha esta malha diretamente no Canvas, sem WebView. A redução
por agrupamento espacial preserva o formato geral e deixa a telemetria fluida
mesmo em celulares modestos.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
from pathlib import Path


COMPONENT_FORMATS = {
    5123: ("H", 2),
    5125: ("I", 4),
}


def read_glb(path: Path) -> tuple[dict, bytes]:
    contents = path.read_bytes()
    magic, version, total_length = struct.unpack_from("<4sII", contents)
    if magic != b"glTF" or version != 2 or total_length != len(contents):
        raise ValueError("GLB inválido ou incompatível")

    json_length, json_type = struct.unpack_from("<I4s", contents, 12)
    if json_type != b"JSON":
        raise ValueError("Primeiro bloco do GLB não é JSON")
    json_start = 20
    document = json.loads(contents[json_start : json_start + json_length])

    binary_header = json_start + json_length
    binary_length, binary_type = struct.unpack_from("<I4s", contents, binary_header)
    if binary_type != b"BIN\x00":
        raise ValueError("Segundo bloco do GLB não é BIN")
    binary_start = binary_header + 8
    return document, contents[binary_start : binary_start + binary_length]


def accessor_bytes(document: dict, binary: bytes, accessor_index: int) -> tuple[dict, memoryview]:
    accessor = document["accessors"][accessor_index]
    view = document["bufferViews"][accessor["bufferView"]]
    offset = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    length = view["byteLength"] - accessor.get("byteOffset", 0)
    return accessor, memoryview(binary)[offset : offset + length]


def load_geometry(path: Path) -> tuple[list[tuple[float, float, float]], list[tuple[int, int, int]]]:
    document, binary = read_glb(path)
    primitive = document["meshes"][0]["primitives"][0]

    positions_accessor, positions_data = accessor_bytes(
        document,
        binary,
        primitive["attributes"]["POSITION"],
    )
    if positions_accessor["componentType"] != 5126 or positions_accessor["type"] != "VEC3":
        raise ValueError("Accessor POSITION incompatível")
    positions = [
        struct.unpack_from("<fff", positions_data, index * 12)
        for index in range(positions_accessor["count"])
    ]

    indices_accessor, indices_data = accessor_bytes(document, binary, primitive["indices"])
    component_type = indices_accessor["componentType"]
    if component_type not in COMPONENT_FORMATS or indices_accessor["type"] != "SCALAR":
        raise ValueError("Accessor de índices incompatível")
    index_format, index_size = COMPONENT_FORMATS[component_type]
    index_count = indices_accessor["count"]
    if index_count % 3:
        raise ValueError("Quantidade de índices não forma triângulos")
    indices = struct.unpack_from(f"<{index_count}{index_format}", indices_data)
    triangles = [
        (indices[offset], indices[offset + 1], indices[offset + 2])
        for offset in range(0, index_count, 3)
    ]
    return positions, triangles


def simplify(
    positions: list[tuple[float, float, float]],
    triangles: list[tuple[int, int, int]],
    resolution: int,
) -> tuple[list[tuple[float, float, float]], list[tuple[int, int, int]]]:
    minimum = [min(point[axis] for point in positions) for axis in range(3)]
    maximum = [max(point[axis] for point in positions) for axis in range(3)]
    extent = [maximum[axis] - minimum[axis] for axis in range(3)]

    clusters: dict[tuple[int, int, int], list[float]] = {}
    vertex_keys: list[tuple[int, int, int]] = []
    for point in positions:
        key = tuple(
            min(
                resolution - 1,
                math.floor((point[axis] - minimum[axis]) / extent[axis] * resolution),
            )
            for axis in range(3)
        )
        vertex_keys.append(key)
        bucket = clusters.setdefault(key, [0.0, 0.0, 0.0, 0.0])
        bucket[0] += point[0]
        bucket[1] += point[1]
        bucket[2] += point[2]
        bucket[3] += 1

    key_to_index: dict[tuple[int, int, int], int] = {}
    reduced_positions: list[tuple[float, float, float]] = []
    for key in sorted(clusters):
        bucket = clusters[key]
        key_to_index[key] = len(reduced_positions)
        reduced_positions.append(
            (bucket[0] / bucket[3], bucket[1] / bucket[3], bucket[2] / bucket[3])
        )

    remap = [key_to_index[key] for key in vertex_keys]
    reduced_triangles: list[tuple[int, int, int]] = []
    seen: set[tuple[int, int, int]] = set()
    for triangle in triangles:
        mapped = (remap[triangle[0]], remap[triangle[1]], remap[triangle[2]])
        if len(set(mapped)) != 3:
            continue
        identity = tuple(sorted(mapped))
        if identity in seen:
            continue
        seen.add(identity)
        reduced_triangles.append(mapped)

    return reduced_positions, reduced_triangles


def write_mesh(
    path: Path,
    positions: list[tuple[float, float, float]],
    triangles: list[tuple[int, int, int]],
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as destination:
        destination.write(struct.pack("<4sIII", b"M3D1", 1, len(positions), len(triangles)))
        for position in positions:
            destination.write(struct.pack("<fff", *position))
        for triangle in triangles:
            destination.write(struct.pack("<III", *triangle))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--resolution", type=int, default=100)
    args = parser.parse_args()

    positions, triangles = load_geometry(args.source)
    reduced_positions, reduced_triangles = simplify(
        positions,
        triangles,
        args.resolution,
    )
    write_mesh(args.destination, reduced_positions, reduced_triangles)
    print(
        f"{len(positions)} vértices/{len(triangles)} triângulos -> "
        f"{len(reduced_positions)} vértices/{len(reduced_triangles)} triângulos"
    )


if __name__ == "__main__":
    main()
