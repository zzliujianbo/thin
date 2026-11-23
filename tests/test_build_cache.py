import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools import build_cache as cache


class CacheTests(unittest.TestCase):
    def test_watermark_rotation_retains_current_and_evicts_whole_retired_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            base = root / '.zig-cache/test-builds'
            base.mkdir(parents=True)
            g = cache.generation(base, 0)
            for name in ('o', 'h'):
                (g / name).mkdir()
                (g / name / 'fixture').write_bytes(b'x' * 8192)
            size = cache.allocated(g)
            cache.trim(base, g, high=size, low=0)
            self.assertEqual(cache.generations(base), [g])
            cache.trim(base, g, high=size-1, low=0)
            fresh = cache.generations(base)[1]
            self.assertTrue((g / 'h/fixture').exists())
            cache.trim(base, fresh, high=size, low=size//2, unused=lambda p: False)
            self.assertTrue(g.exists())
            with patch.object(cache, 'mounted', return_value=True):
                cache.trim(base, fresh, high=size, low=size//2, unused=lambda p: True)
            self.assertTrue(g.exists())
            cache.trim(base, fresh, high=size, low=size//2, unused=lambda p: True)
            self.assertFalse(g.exists())
            self.assertEqual(cache.generations(base), [fresh])

    def test_parallel_runner_and_explicit_external_cache_skip_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {}, clear=True):
            root = Path(tmp).resolve()
            with patch.object(cache, 'trim') as trim:
                with cache.managed(root) as first:
                    with cache.managed(root) as second:
                        self.assertEqual(first, second)
                    trim.assert_not_called()
                trim.assert_called_once()
            with patch.dict(os.environ, {'ZIG_LOCAL_CACHE_DIR': tmp}):
                with cache.managed(root) as selected:
                    self.assertIsNone(selected)

    def test_unmarked_or_linked_cache_not_deleted(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp).resolve()
            g = cache.generation(base, 0)
            fresh = cache.generation(base, 1)
            (g / cache.MARK).unlink()
            cache.trim(base, fresh, high=1, low=0, unused=lambda p: True)
            self.assertTrue(g.exists())
            (base / 'g00000002').symlink_to(g, target_is_directory=True)
            self.assertFalse(cache.owned(base / 'g00000002'))
