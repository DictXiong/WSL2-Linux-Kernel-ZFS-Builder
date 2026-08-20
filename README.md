# WSL2 Linux Kernel + ZFS Builder

A small, source-pinned builder for producing a Microsoft WSL2 kernel with
OpenZFS built into the kernel. The repository contains build automation only;
kernel and ZFS sources are fetched during each build.

## Reproducible inputs

[`versions.env`](versions.env) records both the human-readable ref and the exact
commit for Microsoft WSL2 Linux Kernel and OpenZFS. Builds fetch the immutable
commit directly, so later movement of the WSL maintenance branch does not alter
an existing builder revision.

The initial pins are:

- WSL `linux-msft-wsl-6.18.y` at `14794180686c2fb6307fbe359c359bec765249f3`
- OpenZFS `zfs-2.4.3` at `83020cf8259d057d4cc9102010c05f07ffdfc136`

## GitHub Actions

Run **Build WSL2 Kernel with ZFS** manually from the Actions page. Manual runs
can optionally publish a GitHub release. A push to `main` that changes the
version manifest, build script, or workflow performs a build without publishing
a release.

Build outputs:

- `bzImage`
- `modules.vhdx`, with the module tree directly at the filesystem root
- `modules.vhdx.zip`, a maximum-compression archive used for GitHub releases
- `build-manifest.txt`, recording the exact source commits and kernel release

GitHub Actions stores `modules.vhdx` inside its artifact archive with compression
level 9. GitHub releases upload the precompressed `modules.vhdx.zip` instead of
the much larger raw VHDX; extract it before configuring WSL `kernelModules`.

The VHDX layout is intentionally compatible with WSL's `kernelModules` setting:
its root contains `kernel/`, `modules.dep`, `modules.alias`, and the other module
metadata files. It does not use the newer
`<kernel-release>/modules` artifacts-bundle layout.

## Local build

The build targets an Ubuntu environment and installs its dependencies with
`apt-get`:

```bash
./build.sh
```

Artifacts are written to `output/`. Set `KEEP_BUILD_DIR=1` to retain downloaded
sources and intermediate files for debugging.

## Updating source versions

Update the ref and commit together in `versions.env`. For annotated OpenZFS
tags, pin the peeled commit (`refs/tags/<tag>^{}`), not the tag object itself.

Example checks:

```bash
git ls-remote https://github.com/microsoft/WSL2-Linux-Kernel.git \
  refs/heads/linux-msft-wsl-6.18.y

git ls-remote https://github.com/openzfs/zfs.git \
  refs/tags/zfs-2.4.3 'refs/tags/zfs-2.4.3^{}'
```
