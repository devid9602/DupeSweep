import os
import shutil

import pytest

from dupesweep.engine import Cache, ScanEngine
from dupesweep.matcher import Settings


@pytest.fixture(scope="session")
def library(tmp_path_factory):
    """Generated scenario library (built once per test run)."""
    from tests.make_testset import build
    root = str(tmp_path_factory.mktemp("lib"))
    build(root, 12)
    return root


@pytest.fixture(scope="session")
def scan(library, tmp_path_factory):
    cache_path = str(tmp_path_factory.mktemp("cache") / "cache.sqlite")
    cache = Cache(cache_path)
    report = ScanEngine(Settings(), cache).run([(os.path.join(library, "library"), True)])
    cache.commit()
    return report, cache_path


@pytest.fixture
def work_copy(library, tmp_path):
    """A private copy of the library that tests may modify."""
    dst = tmp_path / "Photos"
    shutil.copytree(os.path.join(library, "library"), dst)
    return str(dst)
