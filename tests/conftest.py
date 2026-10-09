"""Compile each native executable once per pytest session."""

import os
import shlex

import pytest
from hypothesis import settings
from hypothesis.database import DirectoryBasedExampleDatabase

from tests.helpers import BEND_BINARY, CPP_BINARY, DP_BINARY, ROOT, execute


# Keep replay, generation and shrinking enabled. Native process startup is not
# a correctness deadline; reduced failures survive between runs in build/.
settings.register_profile(
    "alignment", max_examples=100, deadline=None, print_blob=True,
    database=DirectoryBasedExampleDatabase(ROOT / "build" / "hypothesis"),
)
settings.load_profile(os.environ.get("HYPOTHESIS_PROFILE", "alignment"))


def pytest_addoption(parser):
    parser.addoption(
        "--alignment", action="store_true",
        help="Enable the extended differential global-distance tests",
    )


def pytest_collection_modifyitems(config, items):
    alignment = config.getoption("--alignment")
    for item in items:
        if "alignment" in item.keywords and not alignment:
            item.add_marker(pytest.mark.skip(reason="Enable distance tests with --alignment"))


@pytest.fixture(scope="session")
def bend_tool():
    if os.name == "nt":
        pytest.fail("Bend must run in WSL. Use: python run_tests.py", pytrace=False)
    version = execute(["bend", "version"], timeout=30).stdout.strip()
    expected = (ROOT / ".bend-version").read_text().strip()
    if version != f"bend {expected}":
        pytest.fail(
            f"Expected Bend {expected}, got {version!r}. "
            "Review CLI compatibility before changing .bend-version.", pytrace=False,
        )
    return "bend"


@pytest.fixture(scope="session")
def bend_binary(bend_tool):
    BEND_BINARY.parent.mkdir(parents=True, exist_ok=True)
    # Rebuild once every run, so changes to imported .bend files are never stale.
    execute([bend_tool, ROOT / "main.bend", "-o", BEND_BINARY], timeout=180)
    return BEND_BINARY


@pytest.fixture(scope="session")
def dp_binary(bend_tool):
    DP_BINARY.parent.mkdir(parents=True, exist_ok=True)
    execute([bend_tool, ROOT / "tests" / "distance_dp.bend", "-o", DP_BINARY], timeout=180)
    return DP_BINARY


@pytest.fixture(scope="session")
def myers_probe(bend_tool):
    binary = ROOT / "build" / "myers-probe"
    binary.parent.mkdir(parents=True, exist_ok=True)
    execute([bend_tool, ROOT / "tests" / "myers_probe.bend", "-o", binary], timeout=180)
    return binary


@pytest.fixture(scope="session")
def cpp_binary():
    if os.name == "nt":
        pytest.fail("Native tests must run in WSL. Use: python run_tests.py", pytrace=False)
    source = ROOT / "vendor" / "edlib" / "edlib"
    if not (source / "src" / "edlib.cpp").exists():
        pytest.fail("Missing Edlib. Run: git submodule update --init vendor/edlib", pytrace=False)
    CPP_BINARY.parent.mkdir(parents=True, exist_ok=True)
    execute([
        *shlex.split(os.environ.get("CXX", "g++")), "-std=c++14", "-O2",
        "-I", source / "include", ROOT / "tests" / "edlib_oracle.cpp",
        source / "src" / "edlib.cpp", "-o", CPP_BINARY,
    ], timeout=180)
    return CPP_BINARY
