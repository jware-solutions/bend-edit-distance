"""Compile each native executable once per pytest session."""

import os
import shlex

import pytest
from hypothesis import settings
from hypothesis.database import DirectoryBasedExampleDatabase

from scripts.proof_kernel import require_kernel
from tests.helpers import BEND_BINARY, CPP_BINARY, DP_BINARY, ROOT, execute
from transport import close_workers
from bend_runtime import configure_toolchain


@pytest.fixture(scope="session", autouse=True)
def worker_lifetime():
    configure_toolchain(ROOT)
    close_workers()
    yield
    close_workers()


# Keep replay, generation and shrinking enabled. Alignment cost is not a
# correctness deadline; reduced failures survive between runs in build/.
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
    parser.addoption(
        "--verdict", action="store_true",
        help="Also verify proofs with the Lean-backed BendTT kernel",
    )
    parser.addoption(
        "--gpu-device", action="store_true",
        help="Require a CUDA build and genuine device execution; unavailable hardware fails",
    )


def pytest_collection_modifyitems(config, items):
    alignment = config.getoption("--alignment")
    for item in items:
        if "alignment" in item.keywords and not alignment:
            item.add_marker(pytest.mark.skip(reason="Enable distance tests with --alignment"))
        if "kernel" in item.keywords and not config.getoption("--verdict"):
            item.add_marker(pytest.mark.skip(reason="Enable kernel proofs with --verdict"))
        if "gpu" in item.keywords and not config.getoption("--gpu-device"):
            item.add_marker(pytest.mark.skip(reason="Require CUDA hardware with --gpu-device"))


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
def proof_kernel():
    try:
        kernel = require_kernel(ROOT)
    except RuntimeError as error:
        pytest.fail(str(error), pytrace=False)
    # Direct pytest invocations use the same checked kernel as run_tests.py.
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("BENDTT", str(kernel))
        yield kernel


@pytest.fixture(scope="session")
def bend_binary(bend_tool):
    BEND_BINARY.parent.mkdir(parents=True, exist_ok=True)
    # Rebuild once every run, so changes to imported .bend files are never stale.
    execute([bend_tool, ROOT / "worker.bend", "-o", BEND_BINARY], timeout=180)
    return BEND_BINARY


@pytest.fixture(scope="session")
def batch_probe(bend_tool):
    binary = ROOT / "build" / "batch-probe"
    binary.parent.mkdir(parents=True, exist_ok=True)
    execute([bend_tool, ROOT / "tests" / "batch_probe.bend", "-o", binary], timeout=180)
    return binary


@pytest.fixture(scope="session")
def gpu_binary(bend_tool):
    binary = ROOT / "build" / "gpu-batch"
    binary.parent.mkdir(parents=True, exist_ok=True)
    execute([bend_tool, ROOT / "gpu_batch.bend", "-o", binary], timeout=180)
    return binary


@pytest.fixture(scope="session")
def gpu_device_probe(bend_tool):
    from benchmarks.gpu_runner import build_probe, require_gpu_build
    # This fixture is requested only by explicitly enabled GPU tests. Missing
    # CUDA, build errors and unsupported devices FAIL instead of being skipped.
    binary = build_probe(cuda_enabled=True)
    require_gpu_build(binary)
    return binary


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
def reconstruction_probe(bend_tool):
    binary = ROOT / "build" / "reconstruction-probe"
    binary.parent.mkdir(parents=True, exist_ok=True)
    execute([bend_tool, ROOT / "tests" / "reconstruction_probe.bend", "-o", binary], timeout=180)
    return binary


@pytest.fixture(scope="session")
def cigar_probe(bend_tool):
    binary = ROOT / "build" / "cigar-probe"
    binary.parent.mkdir(parents=True, exist_ok=True)
    execute([bend_tool, ROOT / "tests" / "cigar_probe.bend", "-o", binary], timeout=180)
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
