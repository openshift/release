"""Prevent standalone runtime fixtures from being parsed as registry refs."""

from generate import GENERATOR_DIR


def test_quay_registry_test_commands_have_matching_refs() -> None:
    registry = GENERATOR_DIR.parents[3] / "step-registry" / "quay"
    unregistered = []
    # ci-tools' GetChangedRegistrySteps builds a graph from every registry
    # component, not only files below a directory named tests. A root-level
    # commands file without its ref is therefore just as invalid as a fixture
    # below tests/ and must be rejected before rehearsal selection consumes it.
    for commands in registry.rglob("*-commands.sh"):
        ref = commands.with_name(commands.name.replace("-commands.sh", "-ref.yaml"))
        if not ref.is_file():
            unregistered.append(commands.relative_to(registry).as_posix())
    assert not unregistered, f"unregistered command-style registry fixtures: {unregistered}"
