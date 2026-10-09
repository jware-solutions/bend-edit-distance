"""Regenerate the checked-in corpus using a version-independent xorshift32 PRNG."""

import json
from pathlib import Path

SEED = 20261009
STATE = SEED


def sequence(length, alphabet="ACGT"):
    global STATE
    out = []
    for _ in range(length):
        STATE ^= (STATE << 13) & 0xffffffff
        STATE ^= STATE >> 17
        STATE ^= (STATE << 5) & 0xffffffff
        STATE &= 0xffffffff
        out.append(alphabet[STATE % len(alphabet)])
    return "".join(out)


def distance(query, target):
    row = list(range(len(query) + 1))
    for i, symbol in enumerate(target, 1):
        next_row = [i]
        for j, other in enumerate(query, 1):
            next_row.append(min(row[j] + 1, next_row[-1] + 1,
                                row[j - 1] + (symbol != other)))
        row = next_row
    return row[-1]


def corpus():
    global STATE
    STATE = SEED
    pairs = [("empty", "", ""), ("empty-target", "ACGT", ""),
             ("example", "kitten", "sitting")]
    for size in (31, 32, 33, 63, 64, 65):
        query = sequence(size)
        pairs.append((f"boundary-{size}", query, query[:-1] + ("A" if query[-1] != "A" else "C")))
    query = sequence(512)
    similar = "".join("ACGT"[("ACGT".index(c) + 1) % 4] if i % 20 == 0 else c
                      for i, c in enumerate(query))
    pairs.extend([
        ("dna-similar-512", query, similar),
        ("dna-random-512", sequence(512), sequence(512)),
        ("motif-512", "ACGT" * 128, "CGTA" * 128),
        ("ascii-random-1024", sequence(1024, "".join(map(chr, range(1, 128)))),
         sequence(1024, "".join(map(chr, range(1, 128))))),
        ("dna-random-4096", sequence(4096), sequence(4096)),
        ("unequal", "ACG", "ACGT" * 1024),
        ("unequal-reversed", "ACGT" * 1024, "ACG"),
    ])
    return {"schema": 1, "seed": SEED, "generator": "xorshift32; modulo alphabet length",
            "contract": "NW, unit costs, non-NUL ASCII, <=4096, unlimited distance",
            "cases": [{"name": n, "query": q, "target": t, "distance": distance(q, t)}
                      for n, q, t in pairs]}


if __name__ == "__main__":
    Path(__file__).with_name("corpus.json").write_text(
        json.dumps(corpus(), indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
