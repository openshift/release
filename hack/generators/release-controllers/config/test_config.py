import pathlib
import tempfile
import unittest

from config import Config


class ReleaseDiscoveryTests(unittest.TestCase):
    @staticmethod
    def prepare_checkout(directory, versions):
        root = pathlib.Path(directory)
        root.joinpath('core-services/release-controller/_releases').mkdir(parents=True, exist_ok=True)
        jobs_path = root.joinpath('ci-operator/jobs/openshift/release')
        jobs_path.mkdir(parents=True, exist_ok=True)
        for version in versions:
            jobs_path.joinpath(f'openshift-release-release-{version}-periodics.yaml').touch()
        return jobs_path

    def test_retains_legacy_resources_without_periodics(self):
        expected = sorted(['4.6', '4.7', '4.8', '4.9', '4.10', '4.11', '4.23', '5.0', '5.1'])
        with tempfile.TemporaryDirectory() as directory:
            self.prepare_checkout(directory, ())
            self.assertEqual(Config(directory).releases, expected)
            self.prepare_checkout(directory, ('4.6', '4.7', '4.8', '4.9', '4.10', '4.11'))
            self.assertEqual(Config(directory).releases, expected)

    def test_preserves_dynamic_discovery_and_scos_releases(self):
        with tempfile.TemporaryDirectory() as directory:
            jobs_path = self.prepare_checkout(directory, ('4.12', '4.24', '5.2'))
            jobs_path.joinpath('unrelated-release-4.25-periodics.yaml').touch()
            config = Config(directory)
            self.assertEqual(config.releases, sorted([
                '4.6', '4.7', '4.8', '4.9', '4.10', '4.11', '4.12', '4.23', '4.24', '5.0', '5.1', '5.2'
            ]))
            self.assertEqual(config.scos_releases, ['scos-4.12', 'scos-4.23', 'scos-4.24'])


if __name__ == '__main__':
    unittest.main()
