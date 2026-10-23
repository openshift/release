import pathlib
import unittest

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]
REPOSITORY = "openshift/external-dns-operator"
LABEL = "allow-automatic-merge"
BLOCKERS = {
    "backports/unvalidated-commits",
    "do-not-merge",
    "do-not-merge/hold",
    "do-not-merge/invalid-owners-file",
    "do-not-merge/work-in-progress",
    "jira/invalid-bug",
}


class ExternalDNSTideTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        base = ROOT / "core-services/prow/02_config"
        cls.config = yaml.safe_load(
            (base / "openshift/external-dns-operator/_prowconfig.yaml").read_text()
        )
        cls.global_config = yaml.safe_load((base / "_config.yaml").read_text())
        cls.queries = cls.config["tide"]["queries"]
        cls.automatic = [query for query in cls.queries if LABEL in query["labels"]]

    def test_exact_automatic_policy(self):
        self.assertEqual(len(self.automatic), 1)
        self.assertEqual(self.automatic[0], {
            "author": "red-hat-konflux[bot]",
            "includedBranches": ["main"],
            "labels": [LABEL],
            "missingLabels": sorted(BLOCKERS),
            "repos": [REPOSITORY],
        })

    def test_policy_membership_model(self):
        query = self.automatic[0]

        def matches(author="red-hat-konflux[bot]", branch="main",
                    repository=REPOSITORY, labels=frozenset({LABEL})):
            return (author == query["author"]
                    and branch in query["includedBranches"]
                    and repository in query["repos"]
                    and set(query["labels"]).issubset(labels)
                    and not set(query["missingLabels"]).intersection(labels))

        self.assertTrue(matches())
        for author in ["human", "renovate[bot]", "red-hat-konflux-kflux-prd-rh03[bot]"]:
            with self.subTest(author=author):
                self.assertFalse(matches(author=author))
        for branch in ["release-1.1", "release-1.2", "master", "main-other"]:
            with self.subTest(branch=branch):
                self.assertFalse(matches(branch=branch))
        self.assertFalse(matches(repository="openshift/other"))
        self.assertFalse(matches(labels=frozenset()))
        for blocker in BLOCKERS:
            with self.subTest(blocker=blocker):
                self.assertFalse(matches(labels={LABEL, blocker}))

    def test_manual_paths_and_ci_are_preserved(self):
        manual = [query for query in self.queries if LABEL not in query["labels"]]
        self.assertEqual(len(manual), 3)
        self.assertEqual([set(query["labels"]) for query in manual], [
            {"approved", "lgtm", "docs-approved", "px-approved", "qe-approved"},
            {"approved", "lgtm", "jira/valid-bug"},
            {"approved", "lgtm", "jira/valid-reference"},
        ])
        for query in manual:
            self.assertEqual(query["repos"], [REPOSITORY])
            self.assertTrue((BLOCKERS - {"do-not-merge"}).issubset(query["missingLabels"]))
        self.assertEqual(manual[0]["excludedBranches"], manual[1]["excludedBranches"])
        self.assertTrue({"release-4.23", "release-5.0", "openshift-4.23"}.issubset(
            manual[0]["excludedBranches"]))
        self.assertNotIn("main", manual[0]["excludedBranches"])
        self.assertNotIn("excludedBranches", manual[2])
        self.assertEqual(set(self.config), {"tide"})
        self.assertEqual(set(self.config["tide"]), {"queries"})
        tide = self.global_config["tide"]
        self.assertTrue(tide["context_options"]["from-branch-protection"])
        self.assertEqual(tide["blocker_label"], "tide/merge-blocker")
        contexts = tide["context_options"].get("orgs", {}).get("openshift", {})
        self.assertNotIn("skip-unknown-contexts", contexts)
        self.assertNotIn("skip-unknown-contexts", contexts.get("repos", {}).get("external-dns-operator", {}))


if __name__ == "__main__":
    unittest.main()
