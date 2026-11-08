"""Seeded, independently selectable performance families (semantic tests are separate)."""

import random

from alignment import AlignConfig, EqualityPair

BOUNDARIES = (31, 32, 33, 63, 64, 65, 95, 96, 97, 127, 128, 129, 4097, 65536, 65537)
FAMILIES = ("identical", "one", "two", "two-adjacent", "sparse", "indel", "dna-random", "bytes-random", "equalities",
            "bytes-one", "bytes-two", "bytes-sparse")


def substitute(sequence, positions, alphabet, rng):
    value = bytearray(sequence)
    for position in positions:
        value[position] = rng.choice([c for c in alphabet if c != value[position]])
    return bytes(value)


def family(name, length, count, seed):
    """Return a retained query and three independently generated target batches.

    Low-edit placements rotate through beginning, 32/33, 64, middle and end.
    Identical families necessarily repeat inputs; all other nonempty families
    have three distinct batches, even at count one.
    """
    if name not in FAMILIES or length < 1 or count < 0:
        raise ValueError("Invalid production family")
    rng = random.Random(seed)
    byte_alphabet = name.startswith("bytes-")
    if byte_alphabet and name != "bytes-random":
        name = name.removeprefix("bytes-")
    if name in ("two", "two-adjacent") and length < 2:
        raise ValueError("Two-edit families require length >=2")
    alphabet = bytes(range(256)) if byte_alphabet else b"ACGT"
    query = bytes(rng.choices(alphabet, k=length))
    pairs = (EqualityPair("A", "N"), EqualityPair("N", "C"),
             EqualityPair("N", "A"), EqualityPair("A", "N")) if name == "equalities" else ()
    config = AlignConfig(equalities=pairs)
    placements = tuple(dict.fromkeys(min(length - 1, p) for p in (0, 31, 32, 33, 63, 64, length // 2, length - 1)))
    batches = []
    for batch in range(3):
        targets = []
        for i in range(count):
            p = placements[(i + batch) % len(placements)]
            if name == "identical":
                target = query
            elif name in ("dna-random", "bytes-random"):
                target = bytes(rng.choices(alphabet, k=length))
            elif name == "indel":
                target = (query[:p] + query[p + 1:] if (i + batch) % 2 else
                          query[:p] + bytes([rng.choice(alphabet)]) + query[p:])
            else:
                positions = [p] if name in ("one", "equalities") else (
                    [p, (p + 1) % length] if name == "two-adjacent" else
                    [p, (p + max(1, length // 2)) % length] if name == "two" else
                    rng.sample(range(length), min(length, max(2, length // 50))))
                target = substitute(query, positions, alphabet, rng)
                if name == "equalities":
                    target = target.replace(b"A", b"N")
            targets.append(target)
        batches.append(tuple((query, t, config) for t in targets))
    return query, config, tuple(batches)
