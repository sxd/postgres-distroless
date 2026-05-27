// docker-bake.hcl — single source of truth for building distroless PostgreSQL images.
//
// Usage:
//   docker buildx bake                                      # build all supported versions/platforms into cache
//   docker buildx bake pg-18 --set pg-18.platform=linux/amd64 --set pg-18.output=type=docker
//   REGISTRY=ghcr.io/me docker buildx bake pg-18 --set pg-18.output=type=registry

postgresVersions = [
  "16.14",
  "17.10",
  "18.4",
]

// PostgreSQL preview versions to build, such as "19beta1" or "19rc1".
// Keep empty until the official tarball and .sha256 exist on ftp.postgresql.org.
postgresPreviewVersions = [
]

// sha256 of https://ftp.postgresql.org/pub/source/v${version}/postgresql-${version}.tar.gz
postgresSha256 = {
  "16.14" = "ca18d43510bbb09a271383e1aa705b05b76bc8e9400f9857178ba8ec54cf461a"
  "17.10" = "e4b43025f32ea3d271be64365d284c8462cffd41d80db0c3df6fc62417a2d9dc"
  "18.4"  = "450aa8f2da06c46f8221916e82ae06b04fb1040f8f00643dbf8b7d663caac0b9"
}

pgVersions = getPgVersions(postgresVersions, postgresPreviewVersions)

variable "DEBIAN_BASE" {
  // Builder + collector base. Trixie ships meson recent enough for PG18 and matches
  // glibc ABI we stage into the scratch final.
  default = "debian:trixie-slim"
}

variable "REGISTRY" {
  default = "localhost"
}

variable "IMAGE_NAME" {
  default = "postgres-distroless"
}

variable "OCI_SOURCE" {
  default = "https://github.com/sxd/postgres-distroless"
}

variable "OCI_REVISION" {
  default = ""
}

variable "MESON_FLAGS" {
  // Flag set is intentionally narrow. Inspired by — not copied from — PGDG's
  // postgresql-18 debian/rules. Anything not strictly needed for a CNPG-managed
  // cluster is disabled. Keep this list reviewable: every entry should have a
  // reason to be here.
  default = join(" ", [
    "-Dssl=openssl",       // TLS for client/replication
    "-Dicu=enabled",       // collations
    "-Dlz4=enabled",       // TOAST / WAL compression
    "-Dzstd=enabled",      // TOAST / WAL compression / pg_basebackup
    "-Dzlib=enabled",      // pg_dump custom format, replication
    "-Dreadline=disabled", // psql line editing — not needed in a server image
    "-Dsystemd=disabled",  // CNPG never runs us under systemd
    "-Dllvm=disabled",     // JIT — large runtime, rare benefit for CNPG workloads
    "-Dnls=disabled",      // gettext catalogs
    "-Dplperl=disabled",
    "-Dplpython=disabled",
    "-Dpltcl=disabled",
    "-Dpam=disabled",
    "-Dldap=disabled",
    "-Dgssapi=disabled",
    "-Dlibxml=disabled",
    "-Dlibxslt=disabled",
    "-Dbsd_auth=disabled",
    "-Dselinux=disabled",
    "-Dtap_tests=disabled",
    "-Duuid=none",
  ])
}

group "default" {
  targets = ["pg"]
}

group "all" {
  targets = ["pg"]
}

target "_common" {
  context    = "."
  dockerfile = "Dockerfile"

  args = {
    DEBIAN_BASE = DEBIAN_BASE
    MESON_FLAGS = MESON_FLAGS
  }

  platforms = ["linux/amd64", "linux/arm64"]

  // Multi-platform is the default. The docker image store cannot load a
  // manifest list, so default to a build-only cache output. Tests that need a
  // local runnable image override to linux/amd64 + type=docker; publication
  // overrides to type=registry.
  output = ["type=cacheonly"]
}

target "pg" {
  matrix = {
    pgVersion = pgVersions
  }

  name     = "pg-${isPreview(pgVersion) ? cleanVersion(pgVersion) : getMajor(pgVersion)}"
  inherits = ["_common"]

  args = {
    PG_VERSION        = pgVersion
    PG_MAJOR          = getMajor(pgVersion)
    PG_TARBALL_SHA256 = postgresSha256[pgVersion]
  }

  labels = {
    "org.opencontainers.image.title"       = IMAGE_NAME
    "org.opencontainers.image.description" = "Distroless PostgreSQL ${getMajor(pgVersion)} image for CloudNativePG"
    "org.opencontainers.image.source"      = OCI_SOURCE
    "org.opencontainers.image.version"     = pgVersion
    "org.opencontainers.image.revision"    = OCI_REVISION
    "org.opencontainers.image.licenses"    = "PostgreSQL"
    "org.opencontainers.image.base.name"   = DEBIAN_BASE
  }

  tags = concat(
    ["${REGISTRY}/${IMAGE_NAME}:${pgVersion}"],
    isPreview(pgVersion) ? [] : ["${REGISTRY}/${IMAGE_NAME}:${getMajor(pgVersion)}"],
  )
}

function cleanVersion {
  params = [version]
  result = replace(replace(version, ".", "_"), "~", "")
}

function isPreview {
  params = [version]
  result = length(regexall("(alpha|beta|rc)[0-9]+$", version)) > 0
}

function getMajor {
  params = [version]
  result = index(regexall("^[0-9]+", version), 0)
}

function isMajorPresent {
  params = [major, versions]
  result = contains([for v in versions : getMajor(v)], major)
}

function getPgVersions {
  params = [stableVersions, previewVersions]
  result = concat(
    stableVersions,
    [
      for v in previewVersions : v
      if !isMajorPresent(getMajor(v), stableVersions)
    ],
  )
}
