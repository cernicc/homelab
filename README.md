# homelab

Personal homelab infrastructure.

## Ignition

The `ignition/alfred.bu` file is the Butane source for provisioning the `alfred` machine. Whenever it is changed, recompile the ignition file and commit both:

```bash
make ignition
```

To install uCore on a new machine:

```bash
sudo coreos-installer install --ignition-url https://github.com/cernicc/homelab/raw/main/ignition/alfred.ign /dev/sdX
```
