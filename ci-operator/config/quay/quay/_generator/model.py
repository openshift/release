"""Dataclasses for Quay CI matrix cells.

A `matrix.yaml` expands as: each `quay[]` release (identified by `branch`,
e.g. `redhat-3.18`) × each `jobs[]` entry × `clouds` × `ocp` → one `Cell`.
The Quay version is derived from the branch suffix.

`image_source` is carried for forward compatibility; templates do not use it
yet.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

YamlMap = dict[str, Any]

STORAGE_BY_CLOUD = {
    "aws": "s3",
    "gcp": "gcs",
    "azure": "blob",
    "libvirt": "s3",
}
# Storage values a cloud accepts beyond its STORAGE_BY_CLOUD default.
EXTRA_STORAGE_BY_CLOUD: dict[str, set[str]] = {
    "aws": {"odf"},
}
DEPLOY_REF_BY_CLOUD = {
    "aws": "quay-deploy-aws-s3",
    "gcp": "quay-deploy-gcp-gcs",
    "azure": "quay-deploy-azure-blob",
    "libvirt": "quay-deploy-aws-s3",
}
DEPLOY_REF_BY_STORAGE = {
    "odf": "quay-deploy-odf",
}
# Cloud-managed databases for database: true jobs. libvirt has no entry:
# expand rejects database: true for clouds missing from this map.
DATABASE_BY_CLOUD = {
    "aws": "rds",
    "gcp": "sql",
    "azure": "postgres",
}
DATABASE_PROVISION_REF_BY_CLOUD = {
    "aws": "quay-database-intg-aws-rds",
    "gcp": "quay-database-intg-gcp-sql",
    "azure": "quay-database-intg-azure-postgres",
}
DATABASE_DEPROVISION_REF_BY_CLOUD = {
    "aws": "quay-database-intg-aws-rds-deprovision",
    "gcp": "quay-database-intg-gcp-sql-deprovision",
    "azure": "quay-database-intg-azure-postgres-deprovision",
}
# No rhel-9-release-golang-1.25-openshift-<ocp> build root tag exists for older OCP (e.g. 4.14).
# The build root only builds the Playwright runner image, so older clusters reuse it.
BUILD_ROOT_OCP_FLOOR = "4.22"


@dataclass(frozen=True)
class Cell:
    org: str
    repo: str
    branch: str
    quay_version: str | None
    ocp_version: str
    cloud: str
    test: str
    cron: str | None
    source: str | None
    arch: str = "amd64"
    image_source: str = "build"
    env: dict[str, Any] = field(default_factory=dict)
    as_name: str | None = None
    kind: str = "periodic"
    layout: str = "variant"
    always_run: bool | None = None
    optional: bool | None = None
    run_if_changed: str | None = None
    skip_if_only_changed: str | None = None
    fips: bool = False
    storage_override: str | None = None
    database: bool = False

    @property
    def quay_version_dashed(self) -> str:
        if self.quay_version is None:
            raise ValueError("quay_version_dashed requires quay_version to be set")
        return self.quay_version.replace(".", "-")

    @property
    def ocp_version_dashed(self) -> str:
        return self.ocp_version.replace(".", "-")

    @property
    def ocp_version_nodot(self) -> str:
        return self.ocp_version.replace(".", "")

    @property
    def build_root_ocp_version(self) -> str:
        def key(version: str) -> tuple[int, ...]:
            return tuple(int(part) for part in version.split("."))

        return max(self.ocp_version, BUILD_ROOT_OCP_FLOOR, key=key)

    @property
    def storage(self) -> str:
        if self.storage_override is not None:
            return self.storage_override
        try:
            return STORAGE_BY_CLOUD[self.cloud]
        except KeyError as exc:
            raise ValueError(f"unsupported cloud {self.cloud!r}") from exc

    @property
    def deploy_ref(self) -> str:
        if self.storage_override in DEPLOY_REF_BY_STORAGE:
            return DEPLOY_REF_BY_STORAGE[self.storage_override]
        try:
            return DEPLOY_REF_BY_CLOUD[self.cloud]
        except KeyError as exc:
            raise ValueError(f"unsupported cloud {self.cloud!r}") from exc

    @property
    def database_kind(self) -> str | None:
        if not self.database:
            return None
        try:
            return DATABASE_BY_CLOUD[self.cloud]
        except KeyError as exc:
            raise ValueError(f"database not supported for cloud {self.cloud!r}") from exc

    @property
    def database_provision_ref(self) -> str | None:
        if not self.database:
            return None
        try:
            return DATABASE_PROVISION_REF_BY_CLOUD[self.cloud]
        except KeyError as exc:
            raise ValueError(f"database not supported for cloud {self.cloud!r}") from exc

    @property
    def database_deprovision_ref(self) -> str | None:
        if not self.database:
            return None
        try:
            return DATABASE_DEPROVISION_REF_BY_CLOUD[self.cloud]
        except KeyError as exc:
            raise ValueError(f"database not supported for cloud {self.cloud!r}") from exc

    @property
    def operator_channel(self) -> str:
        return f"stable-{self.quay_version}"

    @property
    def index_image_repo(self) -> str:
        # ART publishes every Quay FBC to a single shared, public repo; the
        # per-release/per-OCP build is selected by index_image_tag, not the repo.
        return "quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc"

    @property
    def index_image_tag(self) -> str:
        # ART floating-tag convention: <group>__v<ocp_version>__<component_name>.
        # The floating tag (no trailing __g<sha> commit suffix) always points at
        # the latest successful build for that release/OCP pair.
        if self.quay_version is None:
            raise ValueError("index_image_tag requires quay_version to be set")
        return f"quay-{self.quay_version}__v{self.ocp_version}__quay-rhel9-operator"

    @property
    def variant(self) -> str:
        cloud = self.cloud if self.arch == "amd64" else f"{self.cloud}-{self.arch}"
        return f"{cloud}-ocp{self.ocp_version_nodot}-{self.test}"

    @property
    def test_as(self) -> str:
        # No arch suffix: a non-amd64 arch is already in the variant, which
        # Prow puts ahead of `as` in the job name. database: true inserts the
        # cloud DB kind (rds/sql/postgres) before source; fips still suffixes.
        # Filename/variant are unchanged, so sibling rows share one file.
        parts = [self.cloud, self.storage]
        if self.database:
            kind = self.database_kind
            if kind is None:
                raise ValueError(f"database not supported for cloud {self.cloud!r}")
            parts.append(kind)
        if self.kind == "periodic":
            parts.append(str(self.source))
        base = "-".join(parts)
        return f"{base}-fips" if self.fips else base

    @property
    def filename(self) -> str:
        if self.layout == "base":
            if self.arch == "amd64":
                return f"{self.org}-{self.repo}-{self.branch}.yaml"
            return f"{self.org}-{self.repo}-{self.branch}__{self.arch}.yaml"
        return f"{self.org}-{self.repo}-{self.branch}__{self.variant}.yaml"

    def context(self) -> dict[str, Any]:
        ctx: dict[str, Any] = {
            "org": self.org,
            "repo": self.repo,
            "branch": self.branch,
            "ocp_version": self.ocp_version,
            "ocp_version_dashed": self.ocp_version_dashed,
            "ocp_version_nodot": self.ocp_version_nodot,
            "build_root_ocp_version": self.build_root_ocp_version,
            "cloud": self.cloud,
            "storage": self.storage,
            "test": self.test,
            "cron": self.cron,
            "source": self.source,
            "arch": self.arch,
            "image_source": self.image_source,
            "variant": self.variant,
            "test_as": self.test_as,
            "deploy_ref": self.deploy_ref,
            "database": self.database,
            "database_kind": self.database_kind,
            "database_provision_ref": self.database_provision_ref,
            "database_deprovision_ref": self.database_deprovision_ref,
            "kind": self.kind,
            "layout": self.layout,
            "fips": self.fips,
        }
        if self.quay_version is not None:
            ctx["quay_version"] = self.quay_version
            ctx["quay_version_dashed"] = self.quay_version_dashed
            ctx["operator_channel"] = self.operator_channel
            ctx["index_image_repo"] = self.index_image_repo
            ctx["index_image_tag"] = self.index_image_tag
        return ctx
