# joenilan.github.io

Home page for joenilan's apps and the signed "joenilan apps" Linux package
repository, served by GitHub Pages at https://joenilan.github.io/.

- `index.html`: the home page.
- `packages/`: dnf (`rpm/`), apt (`deb/`) and pacman (`arch/`) repositories,
  signing key and repository files. Mirrored to
  https://apps.zombie.digital/downloads/packages/ by
  `scripts/mirror-packages.py --env-file <ssh env file>`.
- `scripts/publish-packages.sh`: adds signed `.rpm` and `.deb` packages,
  keeps the newest three versions of each, re-signs the metadata, commits and
  pushes. Needs `createrepo_c` and the signing key
  (fingerprint `E72D6EE9C417012ECE280124E14B87807621D25D`).

```sh
scripts/publish-packages.sh path/to/app-1.2.3-1.fc44.x86_64.rpm path/to/app_1.2.3-1_amd64.deb path/to/app-1.2.3-1-x86_64.pkg.tar.zst
scripts/mirror-packages.py --env-file ~/git/zombie-digital/.env.raspi
```
