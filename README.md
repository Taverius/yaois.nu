# Yet Another OpenWRT ImageBuilder Script

> There are many like it, but this one is mine.

## What.

Its a script that runs the OpenWRT ImageBuilder Docker Images according to a configuration file it is given.

## Another one? But why!

I couldn't find one that did exactly what I wanted and was portable in the ways I wanted.

YAOIS - I realized the name afterwards, I'm keeping it, it makes me gigl - does what I need in the sense that:

* The only dependencies are `docker` and `nushell`, and `nushell` is everywhere `cargo` is.
* It can be configured with YAML and JSON and TOML.
* It can save its own state along with the image build log as YAML or JSON or TOML.
* Using `--verbose` or the `check` subcommand outputs excessive information about what it's doing.
* Well-documented example configuration contained within the script, accessed with `generate-config` subcommand.
* Single file.
* Not bash or POSIX shell. We're not in the 1970s, and we're driving docker here anyway.
* Not `jq` or `yq`. Great tools but making complex scripts with them is painful.

## How.

`> yaois.nu help`
```help
yaois.nu
  Yet Another OpenWRT ImageBuilder Script

Usage:
  > yaois.nu make-info
    [-f --file=CONFIG]
    [-v --verbose]
  > yaois.nu make-help
    [-f --file=CONFIG]
    [-v --verbose]
  > yaois.nu make-depends PACKAGE
    [-f --file=CONFIG]
    [-v --verbose]
  > yaois.nu make-whatdepends PACKAGE
    [-f --file=CONFIG]
    [-v --verbose]
  > yaois.nu make-manifest
    [-a --abi]
    [-f --file=CONFIG]
    [-v --verbose]
  > yaois.nu make-image
    [-c --clean]
    [-f --file=CONFIG]
    [-l --log]
    [-o --output=FORMAT]
    [-v --verbose]
  > yaois.nu check
    [-f --file=CONFIG]
  > yaois.nu generate-config
    [-o --output=FORMAT]
  > yaois.nu help

  Run an imagebuilder docker image according to [Configuration].

Commands:
- 'make-(info|help|manifest|image)'

  Run `make <command>` inside the container.

- 'make-depends' PACKAGE

  Run 'make package_depends PACKAGE="[PACKAGE]"' inside the container.

- 'make-whatdepends' PACKAGE

  Run 'make package_whatdepends PACKAGE="[PACKAGE]"' inside the container.

- 'check'

  Check configuration file for validity. Implies --verbose.

- 'generate-config'

  Output example configuration file.

- 'help'

  Display this message.

Options:
  -a --abi(=true|false)
      Keep ABI information when running `make manifest`
  -c --clean(=true|false)
      Run `make clean` before a `make image`
  -f --file=CONFIG
      Specify a configuration file to use, otherwise will check
      for ./config.yaml in $PWD
  -l --log(=true|false)
      Saves the output of 'make image' to a the output directory as
      imagebuilder-<tag>(-extra_name)-<iso-date>.log
  -o --output=(yaml|json|toml|nuon)
      For 'make-image':
      Saves the full configuration used to build the image to the output
      directory as imagebuilder-<tag>(-extra_name)-<date-time>.[FORMAT]
      For 'generate-config':
      Output example configuration as [FORMAT] instead of yaml
      Comments are lost in formats other than yaml
  -v --verbose(=true|false)
      Print information message about configuration parsing and so on

Configuration:
  Accepts a configuration file in any format nushell can read that supports
  the required types. Currently: yaml, json, toml, nuon.
```

## Configuration?

`> yaois.nu generate-config`
```yaml
# All keys must be present.

builder:
  parallel_jobs: 4
    # How many parallel jobs for the image building step.
    # '0' to disable and use the imagebuilder's defaults.
  registry:
    custom: false
      # 'true' to use a nonstandard registry.
      # 'false' to use docker.io.
    source:
      # 'ghcr.io' or 'quay.io'.
  tag: x86-64-24.10.0
    # The part after ':' on the image registry.
    # See:
    # https://hub.docker.com/r/openwrt/imagebuilder/tags
    # https://github.com/openwrt/docker/pkgs/container/imagebuilder/versions
    # https://quay.io/repository/openwrt/imagebuilder?tab=tags
  custom_network:
    enabled: true
      # 'false' to use the default network.
    name: my_awesome_network
      # [string] name of existing custom network to use, will be checked for
      # existence but not created if missing.
  named_volume: false
    # 'false' to use unnamed volume.
    # 'true' to create a named volume based on image name and (sanitized) tag.
    # Named volume will be created if missing. Will not be removed when done.
    # Can be useful when working with snapshots.
  as_user: true
    # 'false' to run as default user of the docker image.
    # 'true' to run as the user calling the script.
  output: ./output
    # Where the imagebuilder will output files. Required. Will be mounted as
    # /builder/bin in the container.
  files:
    enabled: true
      # 'false' to disable.
    dir: ./files
      # Where to find files from an extracted backup. Will be mounted as
      # /host-files in the container.
  packages:
    enabled: true
      # 'false' to disable.
    dir: ./packages
      # Where to find extra out-of-tree packages. Will be mounted as
      # /host-packages in the container.

    # Relative paths are relative to the configuration file, however be aware
    # links are checked but not traversed for this purpose.

# Check the imagebuilder docs for these, also:
# 'yaois.nu make-help'
openwrt:
  profile: generic
    # 'yaois.nu make-info' to get valid profiles for your arch.
  extra_name:
    enabled: true
      # 'false' to disable.
    name: qemu
      # The string to pass as EXTRA_NAME to be added to the image name.
  root_partsize: 1024
    # 0 to use defaults
  sign_image: false
    # 'true' to sign images with a locally-generated key.
  disabled_services:
    # remove all list entries to disable.
    - uhttpd
    - sysntpd
  packages:
    # remove all list entries to disable.
    - -logd
    - syslog-ng
    - -dnsmasq
    - qemu-ga
    - dnsmasq-full
    - chrony-nts
    - luci-ssl-nginx
    - nginx-ssl-util
```

## Status?

Feature-complete?

Other than fixing any bugs, anything more complex then what's already here would only be sane if doing it via a go or rust or other executable. As it is, the script is something like 50% input validation by volume.

Anyway, it does what I want.

## License?

Idk, MIT I guess?

### Special thanks

The nushell discord for putting up with my inane late-night questions about basic things.
