"""Seeded, independently selectable performance families (semantic tests are separate)."""

import random

from alignment import AlignConfig, EqualityPair, Mode, Task

# "Three" counts diagonal mismatches, not the independently checked edit optimum.
CERTIFICATE_FAMILIES = ("two-begin", "two-boundary", "two-middle", "two-end", "two-mixed",
                        "three-early", "three-middle", "three-late", "three-tail", "short-shift")

BOUNDARIES = (31, 32, 33, 63, 64, 65, 95, 96, 97, 127, 128, 129, 4097, 65536, 65537)
PREPARATION_FAMILIES = ("prep-one", "prep-small", "prep-dna", "prep-bytes", "prep-irrelevant",
                        "prep-sparse", "prep-star", "prep-chain", "prep-duplicates",
                        "prep-reflexive", "prep-dense", "prep-max-pairs", "prep-byte-duplicates",
                        "prep-unique-15", "prep-unique-16", "prep-unique-17")

RESTORATION_FAMILIES = ("restore-small", "restore-16", "restore-17", "restore-general", "restore-skew",
                        "restore-validation", "hw-unique", "hw-several", "hw-many", "hw-prefix", "hw-fixed",
                        "cigar-homogeneous", "cigar-alternating", "hw-one-path")

FAMILIES = (*PREPARATION_FAMILIES, *RESTORATION_FAMILIES, "identical", "bytes-identical", "one", "two", "two-adjacent", "sparse", "indel", "dna-random", "bytes-random", "equalities",
            "bytes-one", "bytes-two", "bytes-sparse", "rotation", "burst", "dense-prefix", "dense-suffix",
            "dna-10pct", "dna-25pct", "dna-50pct", *CERTIFICATE_FAMILIES)


def substitute(sequence, positions, alphabet, rng):
    value = bytearray(sequence)
    for position in positions:
        value[position] = rng.choice([c for c in alphabet if c != value[position]])
    return bytes(value)


def orientation_family(name, query_length, target_length, count, seed):
    """Fixed public query, three target groups, with explicit input dimensions.

    Shared-prefix families keep their edits in the common interval. Extra
    symbols are real input, including their construction/traversal costs.
    Reverse dimensions are separate requests, never a timed oracle selector.
    """
    if name in (*PREPARATION_FAMILIES, *RESTORATION_FAMILIES) or name not in FAMILIES:
        raise ValueError("Orientation requires an alignment family")
    if min(query_length, target_length, count) < 0:
        raise ValueError("Negative orientation dimension")
    common = min(query_length, target_length)
    alphabet = bytes(range(256)) if name.startswith("bytes-") else b"ACGT"
    rng = random.Random(seed ^ 0x8A41)
    if common:
        query, config, batches = family(name, common, count, seed)
    else:
        query, config = b"", AlignConfig()
        batches = tuple(tuple((b"", b"", config) for _ in range(count)) for _ in range(3))
    query += bytes(rng.choices(alphabet, k=query_length - common))
    batches = tuple(tuple((query, t + bytes(rng.choices(alphabet, k=target_length - common)), c)
                          for _, t, c in batch) for batch in batches)
    if any(len(t) != target_length for batch in batches for _, t, _ in batch):
        raise ValueError("Orientation family must preserve target length")
    return query, config, batches


def family(name, length, count, seed):
    """Return a retained query and three independently generated target batches.

    Low-edit placements rotate through beginning, 32/33, 64, middle and end.
    Identical families necessarily repeat inputs; all other nonempty families
    have three distinct batches, even at count one.
    """
    if name not in FAMILIES or length < 1 or count < 0:
        raise ValueError("Invalid production family")
    if name == "hw-one-path":
        rng = random.Random(seed)
        query = bytes(rng.choices(b"ACGT", k=length))
        config = AlignConfig(Mode.HW, Task.PATH)
        batches = tuple(tuple((query, query if i % 2 == 0 else
            query[:-1] + bytes([b"ZYX"[group]]), config) for i in range(count)) for group in range(3))
        return query, config, batches
    if name in PREPARATION_FAMILIES:
        return preparation_family(name, length, count, seed)
    if name in RESTORATION_FAMILIES:
        return restoration_family(name, length, count, seed)
    rng = random.Random(seed)
    byte_alphabet = name.startswith("bytes-")
    if byte_alphabet and name != "bytes-random":
        name = name.removeprefix("bytes-")
    if name in ("two", "two-adjacent") and length < 2:
        raise ValueError("Two-edit families require length >=2")
    if name in CERTIFICATE_FAMILIES and length < 129:
        raise ValueError("Certificate placement families require length >=129")
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
            if name in CERTIFICATE_FAMILIES:
                positions = {
                    "two-begin": (0, 1), "two-boundary": (32, 33),
                    "two-middle": (length // 2, length // 2 + 1),
                    "two-end": (length - 2, length - 1), "two-mixed": (0, 32),
                    "three-early": (0, 1, 2),
                    "three-middle": (0, 1, length // 2),
                    "three-late": (0, 1, 32),
                    "three-tail": (32, 63, 64),
                }
                if name == "short-shift":
                    # One insertion/deletion pair, many diagonal mismatches.
                    target = query[1:] + bytes([[c for c in alphabet if c != query[-1]][(i + batch) % 3]])
                else:
                    target = bytearray(substitute(query, positions[name], alphabet, rng))
                    first = positions[name][0]
                    target[first] = [c for c in alphabet if c != query[first]][(i + batch) % 3]
                    target = bytes(target)
            elif name == "identical":
                target = query
            elif name in ("dna-random", "bytes-random"):
                target = bytes(rng.choices(alphabet, k=length))
            elif name == "rotation":
                shift = min(length - 1, 33 + 17 * (i + batch))
                target = query[shift:] + query[:shift]
            elif name == "burst":
                # Dense local edits followed by a long equal suffix mislead
                # policies based solely on an early failed narrow attempt.
                target = substitute(query, range(min(length, 96 + i + batch)), alphabet, rng)
            elif name in ("dense-prefix", "dense-suffix"):
                n = max(1, length // 4)
                changed = bytes(rng.choices(alphabet, k=n))
                target = changed + query[n:] if name == "dense-prefix" else query[:-n] + changed
            elif name.startswith("dna-") and name.endswith("pct"):
                percent = int(name[4:-3])
                target = substitute(query, rng.sample(range(length), max(1, length * percent // 100)), alphabet, rng)
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


def restoration_family(name, length, count, seed):
    """Bounded restoration regimes; nonzero HW ties exercise reverse recovery.

    Three target groups vary consumed intervals or unrelated prefixes. The
    repeated islands in a single HW target deliberately create ordered ties.
    Their endpoint counts and actual distances are oracle results, not labels.
    """
    rng = random.Random(seed)
    query = bytes(rng.choices(b"ACGT", k=length))
    pairs = ()
    if name == "restore-validation":
        query = (b"AN\0\xffC" * ((length + 4) // 5))[:length]
        pairs = tuple(EqualityPair(a, b) for a, b in [(65, 78), (78, 65)] * 128 + [(78, 67), (0, 255)])
    if name.startswith("hw-"):
        query = b"A" * length
    if name.startswith("cigar-"):
        query = b"A" * length
    config = AlignConfig(Mode.HW if name.startswith("hw-") else Mode.NW, Task.PATH, equalities=pairs)
    batches = []
    for group in range(3):
        jobs = []
        for i in range(count):
            if name.startswith("hw-"):
                copies = {"hw-several": 3, "hw-many": 16}.get(name, 1)
                island = query if name == "hw-fixed" else b"A" * max(1, length - 1)
                if name in ("hw-unique", "hw-prefix") and length > 2:
                    island = query[:length // 2] + b"B" + query[length // 2 + 1:]
                prefix = b"Z" * ((length * 8 if name == "hw-prefix" else 1) + group + i)
                target = prefix + (island + b"ZZ") * copies
            elif name == "cigar-homogeneous":
                target = query + b"A" * (group + i + 1)
            elif name == "cigar-alternating":
                target = (b"AC" * ((length + 1) // 2))[:length] + b"C" * group
            elif name == "restore-skew":
                target = bytes(rng.choices(b"ACGT", k=max(1, length // 16)))
            elif name in ("restore-16", "restore-17"):
                target = query + bytes([88 + (group + i) % 3]) * int(name[8:])
            elif name == "restore-validation":
                target = query.replace(b"A", b"N").replace(b"\0", b"\xff") + b"Z" * (group + 1)
            else:
                edits = {"restore-small": 3, "restore-16": 16, "restore-17": 17}.get(name, max(18, length // 3))
                target = substitute(query, rng.sample(range(length), min(length, edits)), b"ACGT", rng)
            jobs.append((query, target, config))
        batches.append(tuple(jobs))
    return query, config, tuple(batches)


def preparation_family(name, length, count, seed):
    """Literal alphabets and DIRECT graphs; retained pair order is intentional."""
    rng = random.Random(seed)
    alphabet = {"prep-one": b"A", "prep-small": b"AB", "prep-dna": b"ACGT",
                "prep-bytes": bytes(range(256)), "prep-sparse": b"ACGT",
                "prep-dense": bytes(range(256)), "prep-byte-duplicates": bytes(range(256))}.get(name, b"A")
    # Cycle first so even short all-byte cases have a known literal alphabet.
    query = (alphabet * ((length + len(alphabet) - 1) // len(alphabet)))[:length]
    graph = {
        "prep-irrelevant": [(a, b) for a in range(128, 256) for b in range(a + 1, 256)],
        "prep-sparse": [(65, 78), (78, 67), (0, 255)],
        "prep-star": [(65, b) for b in range(256) if b != 65],
        "prep-chain": list(zip(range(256), range(1, 256))),
        "prep-duplicates": [(65, 78), (78, 65)] * 2048,
        "prep-reflexive": [(65, 65)] * 4096,
        "prep-dense": [(a, b) for a in range(256) for b in range(a + 1, 256)],
        "prep-max-pairs": [(65, 78), (78, 65)] * 32768,
        "prep-byte-duplicates": [(65, 78), (78, 65)] * 2048,
        **{f"prep-unique-{n}": [(65, b) for b in range(n)] for n in (15, 16, 17)},
    }.get(name, [])
    pairs = tuple(EqualityPair(a, b) for a, b in graph)
    config = AlignConfig(equalities=pairs)
    batches = []
    for batch in range(3):
        jobs = []
        for i in range(count):
            # Choose a byte that cannot directly match at this literal position.
            p = (rng.randrange(length) + i + batch) % length
            literal = query[p]
            neighbors = {literal} | {b for a, b in graph if a == literal} | {a for a, b in graph if b == literal}
            missing = [c for c in range(256) if c not in neighbors]
            target = bytearray(query)
            if missing:
                target[p] = missing[(i + batch) % len(missing)]
            else:
                # Universal direct star/dense rows have no substitution mismatch.
                target.append((i + batch) % 256)
            jobs.append((query, bytes(target), config))
        batches.append(tuple(jobs))
    return query, config, tuple(batches)
