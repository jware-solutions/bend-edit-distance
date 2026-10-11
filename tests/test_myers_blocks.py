"""Inspect production masks, carries, columns and padding against scalar cells."""

from hypothesis import example, given, settings, strategies as st
import pytest

from tests.helpers import execute

pytestmark = pytest.mark.alignment
WORD = 32


def probe_rows(binary, mode, *sequences, threads=1):
    result = execute([binary, "--threads", str(threads), "--", mode, *sequences])
    assert result.stderr == ""
    return [line.split(",") for line in result.stdout.splitlines() if line]


MASK_QUERIES = ["".join(chr(i + 1) for i in range(length)) for length in range(33)] + [
    "aA" * 16, "A" * 32, "\x7f" * 33,
    "".join(chr(i) for i in range(1, 128)), ("AcG\x7f" * 65)[:257],
]


@pytest.mark.parametrize("query", MASK_QUERIES, ids=lambda q: f"length-{len(q)}-{q[:2]!r}")
def test_equality_masks_and_lookup(myers_probe, query):
    rows = probe_rows(myers_probe, "masks", query)
    count = max(1, (len(query) + WORD - 1) // WORD)
    assert len(rows) == count * 256
    seen = set()
    for tag, block, code, direct, lookup in rows:
        assert tag == "M"
        block, code, direct, lookup = map(int, (block, code, direct, lookup))
        assert 0 <= block < count and 0 <= code < 256
        assert (block, code) not in seen
        seen.add((block, code))
        word = query[block * WORD:(block + 1) * WORD]
        expected = sum(1 << bit for bit in range(WORD)
                       if bit >= len(word) or ord(word[bit]) == code)
        assert direct == lookup == expected, (query, block, code, direct, lookup, expected)


def scalar_columns(query, target, mode="NW"):
    """Scalar columns with explicit top boundaries and wildcard padding."""
    size = ((len(query) + WORD - 1) // WORD) * WORD
    padded = list(query) + [None] * (size - len(query))
    previous = list(range(size + 1))
    yield previous
    for column, symbol in enumerate(target, 1):
        current = [0 if mode == "HW" else column]
        for row, query_symbol in enumerate(padded, 1):
            cost = int(query_symbol is not None and query_symbol != symbol)
            current.append(min(previous[row] + 1, current[-1] + 1,
                               previous[row - 1] + cost))
        yield current
        previous = current


def assert_trace(binary, query, target, *, threads=1, mode="NW"):
    rows = probe_rows(binary, "trace-mode", mode, query, target, threads=threads)
    columns = list(scalar_columns(query, target, mode))
    count = (len(query) + WORD - 1) // WORD
    assert len(rows) == count * (1 + 2 * len(target))
    seen = set()
    carries = set()
    for tag, column, block, pv, mv, score, *extra in rows:
        column, block, pv, mv, score = map(int, (column, block, pv, mv, score))
        assert tag in ("A", "B")
        assert 0 <= column <= len(target) and 0 <= block < count
        assert (tag, column, block) not in seen
        seen.add((tag, column, block))
        assert pv & mv == 0
        current = columns[column]
        start, end = block * WORD, (block + 1) * WORD
        differences = [current[row] - current[row - 1] for row in range(start + 1, end + 1)]
        expected_pv = sum(1 << bit for bit, diff in enumerate(differences) if diff == 1)
        expected_mv = sum(1 << bit for bit, diff in enumerate(differences) if diff == -1)
        assert (pv, mv, score) == (expected_pv, expected_mv, current[end]), (
            query, target, tag, column, block, (pv, mv, score),
            (expected_pv, expected_mv, current[end]),
        )
        if tag == "B":
            assert column > 0 and len(extra) == 2 + WORD
            hp, hn, *decoded = map(int, extra)
            expected_carry = current[end] - columns[column - 1][end]
            assert (hp, hn) == (int(expected_carry == 1), int(expected_carry == -1))
            if block + 1 < count:
                carries.add(hp - hn)
            # Production get_block_cell_value at every offset, even positions
            # in the final word that the end-to-end distance never reads.
            assert decoded == [current[end - padding] for padding in range(WORD)]
        else:
            assert not extra
    return carries


@pytest.mark.parametrize("length", range(1, 33))
def test_single_word_transitions_and_every_padding_offset(myers_probe, length):
    query = ("AcG\x7f" * 8)[:length]
    assert_trace(myers_probe, query, query + "T" + query[::-1])


@pytest.mark.parametrize("length", [33, 63, 64, 65, 95, 96, 97, 127, 128, 129, 257])
@pytest.mark.parametrize("threads", [1, 2])
def test_multiblock_transitions(myers_probe, length, threads):
    query = ("ACgt" * 65)[:length]
    assert_trace(myers_probe, query, query[1:] + "N" * 5 + query[:3], threads=threads)


def test_all_carry_signs_reach_later_blocks(myers_probe):
    assert assert_trace(myers_probe, "A" * 65, "T" * 20 + "A" * 100 + "T" * 40) == {-1, 0, 1}


@pytest.mark.parametrize("mode", ["SHW", "HW"])
@pytest.mark.parametrize("length", [1, 31, 32, 33, 63, 64, 65, 95, 96, 97, 129])
def test_directional_columns_and_padding(myers_probe, mode, length):
    query = ("ACgt" * 33)[:length]
    assert_trace(myers_probe, query, "T" * 35 + query + "N" * 4 + query, mode=mode)


@settings(max_examples=40)
@given(query=st.text("ACGacg", min_size=1, max_size=97),
       target=st.text("ACGacg", max_size=100))
@example(query="A" * 32 + "C", target="A" * 33)
@example(query="A" * 65, target="C" * 65)
def test_reachable_block_states_with_shrinking(myers_probe, query, target):
    assert_trace(myers_probe, query, target)
