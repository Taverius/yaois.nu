#!/usr/bin/env nu
use std/formats *

def parser [
  file?: path
  --verbose
  --strip-abi
]: [ nothing -> record ] {
  # Basics
  let $cfg_file: path = (if $file == null { "config.yaml" } else { $file })

  # Wrap print for an easier check to $verbose
  def --wrapped v-print [
    --no-newline (-n)
    ...rest
  ] {
    if ($verbose) {
      if $no_newline {
        print ...$rest -n
      } else {
        print ...$rest
      }
    }
  }

  # Checking config file
  v-print "
# ------------------------------------- #
# Checking config file.                 #
# --------------------------------------#
"
  if not ($cfg_file | path exists) {
    error make { msg: "Config file is missing!", label: { text: "File does not exist", span: (metadata $cfg_file).span } }
  }

  let $cfg_path: path = ($cfg_file | path expand --strict --no-symlink)
  let $cfg: any = (open $cfg_path)
  if ($cfg | typeof) != "record" {
    error make { msg: "Config file is not valid!", label: { text: "Invalid config file", span: (metadata $cfg_file).span } }
  }

  v-print $"Using config file: \'($cfg_path)\'"
  let $cfg_dir: path = ($cfg_path | path dirname)
  v-print $"Relative paths will be relative to: \'($cfg_dir)\'"

  v-print "
# ------------------------------------- #
# Being parsing configuration.          #
# --------------------------------------#
"
  # Creates a record for a configuration parsing error
  def parser-error [
    $message: string
    $name: string
    $value: any
    $span: record
  ] {
    {
      msg: $message,
      label: {
        text: $"in: ($cfg_path)\n($name): \'($value)\' of type \'($value | typeof)\'",
        span: $span
      }
    }
  }

  #
  # Command Parameters
  #
  let $files_dir_container: path = '/host_files'
  let $packages_dir_container: path = '/host_packages'

  mut $make_parameters: list<string> = []
  mut $docker_parameters: list<string> = [ '--rm' '--detach' '--tty' ]
  mut $manifest_parameters: list<string> = []
  mut $image_parameters: list<string> = []

  mut $parallel_jobs: int = 0
  mut $network_custom: bool = false
  mut $network_name: string = ""
  mut $registry_custom: bool = false
  mut $registry_source: string = ""
  mut $named_volume: bool = false
  mut $volume_name: string = ""
  mut $as_user: bool = false
  mut $usergroup: string = ""
  mut $image_tag: string = ""
  mut $sanitized_tag: string = ""
  mut $container_name: string = ""
  mut $image_name: string = ""
  mut $output_dir: string = ""
  mut $do_files: bool = false
  mut $files_dir: string = ""
  mut $do_packages: bool = false
  mut $packages_dir: string = ""
  mut $profile: string = ""
  mut $extra_enabled: bool = false
  mut $extra_name: string = ""
  mut $sign_image: bool = false
  mut $root_partsize: int = 0
  mut $disabled_services: list<string> = []
  mut $packages: list<string> = []

  #
  # Parse config
  #

  # Make Jobs
  if ($cfg.builder.parallel_jobs | typeof) != int {
    error make (parser-error "builder.parallel_jobs is not an integer!" "builder.parallel_jobs" $cfg.builder.parallel_jobs (metadata $cfg).span)
  }
  if $cfg.builder.parallel_jobs > 0 {
    $parallel_jobs = $cfg.builder.parallel_jobs
    $make_parameters = ($make_parameters | append $"--jobs=($parallel_jobs | into string)")
    v-print $"Setting make parallel jobs to: \'($parallel_jobs)\'"
  }

  # Docker Network
  if ($cfg.builder.named_network.enabled | typeof) != bool {
    error make (parser-error "builder.named_network.enabled is not boolean!" "builder.named_network.enabled" $cfg.builder.named_network.enabled (metadata $cfg).span)
  }
  $network_custom = $cfg.builder.named_network.enabled
  if $network_custom {
    if not ( ($cfg.builder.named_network.name | typeof) == string and
             ($cfg.builder.named_network.name | str length) > 0 ) {
      error make (parser-error "builder.named_network.name is not a valid string!" "builder.named_network.name" $cfg.builder.named_network.name (metadata $cfg).span)
    }
    $network_name = $cfg.builder.named_network.name
    let $docker_networks = ^docker network list --format json | from jsonl
    if $network_name in $docker_networks.Name {
      v-print $"Docker network \'($network_name)\' exists."
      v-print $"Using network: \'($network_name)\'"
      $docker_parameters = ($docker_parameters | append $"--network=($network_name)")
    } else {
      error make (parser-error "builder.named_network is not an existing docker network!" "builder.named_network" $cfg.builder.named_network (metadata $cfg).span)
    }
  } else {
    v-print "Using default docker network."
  }

  # Image Registry
  if ($cfg.builder.registry.custom | typeof) != bool {
    error make (parser-error "builder.registry.custom is not boolean!" "builder.registry.custom" $cfg.builder.registry.custom (metadata $cfg).span)
  }
  $registry_custom = $cfg.builder.registry.custom
  if $registry_custom {
    if not ( ($cfg.builder.registry.source | typeof) == string and
             ($cfg.builder.registry.source | str length) > 0 ) {
      error make (parser-error "builder.registry.source is not a valid string!" "builder.registry" $cfg.builder.registry (metadata $cfg).span)
    }
    v-print $"Using image registry: \'($cfg.builder.registry.source)\'"
    if ($cfg.builder.registry.source | str ends-with '/') {
      $image_name = $cfg.builder.registry.source
    } else {
      $image_name = $cfg.builder.registry.source + '/'
    }
  } else {
    v-print "Using default image registry."
  }
  $image_name = $image_name + 'openwrt/imagebuilder:'

  # Image Tag
  if ( ($cfg.builder.tag | typeof) != "string" or
       ($cfg.builder.tag | str length) == 0 ) {
    error make (parser-error "builder.tag is not a valid string!" "builder.tag" $cfg.builder.tag (metadata $cfg).span)
  }
  $image_tag = $cfg.builder.tag
  $sanitized_tag = ($image_tag | str replace --all --regex '[^[:alnum:]_.-]' '_' | str replace --all --regex '[_]+' '_')
  v-print $"Using image tag: \'($image_tag)\' \(sanitized: \'($sanitized_tag)\'\)"
  $image_name = $image_name + $image_tag
  v-print $"Using docker image: \'($image_name)\'"
  $container_name = $"imagebuilder-($sanitized_tag)"
  v-print $"Using container name: \'($container_name)\'"
  $docker_parameters = ($docker_parameters | append $"--name=($container_name)")

  # Docker Volume
  if ($cfg.builder.named_volume | typeof) != "bool" {
    error make (parser-error "builder.named_volume is not boolean!" "builder.named_volume" $cfg.builder.named_volume (metadata $cfg).span)
  }
  $named_volume = $cfg.builder.named_volume
  if $named_volume {
    let $docker_volumes = ^docker volume list --format json | from jsonl
    $volume_name = $"openwrt_($container_name)"
    let $volname = $volume_name
    if $volume_name in $docker_volumes.Name {
      v-print $"Docker volume \'($volume_name)\' exists."
    } else {
      v-print $"Docker volume \'($volume_name)\' does not exist, creating ... " -n
      try {
        ^docker volume create $volume_name o> /dev/null
      } catch {
        error make { msg: $"Could not create docker volume \'($volname)\'!" }
      }
      v-print "Done!"
    }
    $docker_parameters = ($docker_parameters | append $"--volume=($volume_name):/builder")
    v-print $"Using volume: \'($volume_name)\'"
  } else {
    v-print "Using unnamed volume."
  }

  # User
  if ($cfg.builder.as_user | typeof) != "bool" {
    error make (parser-error "builder.as_user is not boolean!" "builder.as_user" $cfg.builder.as_user (metadata $cfg).span)
  }
  $as_user = $cfg.builder.as_user
  if $as_user {
    $usergroup = $"(id -u):(id -g)"
    v-print $"Running as UID:GID \'($usergroup)\'"
    $docker_parameters = ($docker_parameters | append $"--user=($usergroup)")
  }

  # Output directory
  let $output_dir = $cfg_dir + '/' + $cfg.builder.output | path expand --no-symlink
  if not ($output_dir | path exists) {
    error make (parser-error "builder.output is not a valid path!" "builder.output" $cfg.builder.output (metadata $cfg).span)
  }
  v-print $"Using output path: \'($output_dir)\'"
  $docker_parameters = ($docker_parameters | append $"--volume=($output_dir):/builder/bin")

  # Files directory
  if ($cfg.builder.files.enabled | typeof) != "bool" {
    error make (parser-error "builder.files.enabled is not boolean!" "builder.files.enabled" $cfg.builder.files.enabled (metadata $cfg).span)
  }
  $do_files = $cfg.builder.files.enabled
  if $do_files {
    if not ( ($cfg.builder.files.dir | typeof) == string and
             ($cfg_dir + '/' + $cfg.builder.files.dir | path expand --no-symlink | path exists) ) {
      error make (parser-error "builder.files.dir is not a valid path!" "builder.files.dir" $cfg.builder.files.dir (metadata $cfg).span)
    }
    $files_dir = ($cfg_dir + '/' + $cfg.builder.files.dir | path expand --no-symlink)
    v-print $"Using files path: \'($files_dir)\'"
    $docker_parameters = ($docker_parameters | append $"--volume=($files_dir):($files_dir_container):ro")
    $image_parameters = ($image_parameters | append $"FILES=\"($files_dir_container)\"")
  }

  # Packages directory
  if ($cfg.builder.packages.enabled | typeof) != "bool" {
    error make (parser-error "builder.packages.enabled is not boolean!" "builder.packages.enabled" $cfg.builder.packages.enabled (metadata $cfg).span)
  }
  $do_packages = $cfg.builder.packages.enabled
  if $do_packages {
    if not ( ($cfg.builder.packages.dir | typeof) == string and
             ($cfg_dir + '/' + $cfg.builder.packages.dir | path expand --no-symlink | path exists) ) {
      error make (parser-error "builder.packages.dir is not false or a valid path!" "builder.packages.dir" $cfg.builder.packages.dir (metadata $cfg).span)
    }
    $packages_dir = ($cfg_dir + '/' + $cfg.builder.packages.dir | path expand --no-symlink)
    v-print $"Using packages path: \'($packages_dir)\'"
    $docker_parameters = ($docker_parameters | append $"--volume=($packages_dir):($packages_dir_container):ro")
    $manifest_parameters = ($manifest_parameters | append $"PACKAGES=\"($packages_dir_container)\"")
    $image_parameters = ($image_parameters | append $"PACKAGES=\"($packages_dir_container)\"")
  }

  # Profile
  if ( ($cfg.openwrt.profile | typeof) != string or
       ($cfg.openwrt.profile | str length) == 0 ) {
    error make (parser-error "openwrt.profile is not a valid string!" "openwrt.profile" $cfg.openwrt.profile (metadata $cfg).span)
  }
  $profile = $cfg.openwrt.profile
  $manifest_parameters = ($manifest_parameters | append $"PROFILE=($profile)")
  $image_parameters = ($image_parameters | append $"PROFILE=($profile)")

  # Extra Image Name
  if ($cfg.openwrt.extra_name.enabled | typeof) != "bool" {
    error make (parser-error "openwrt.extra_name.enabled is not boolean!" "openwrt.extra_name.enabled" $cfg.openwrt.extra_name.enabled (metadata $cfg).span)
  }
  $extra_enabled = $cfg.openwrt.extra_name.enabled
  if $extra_enabled {
    if not ( ($cfg.openwrt.extra_name.name | typeof) == string and
             ($cfg.openwrt.extra_name.name | str length) > 0 ) {
      error make (parser-error "openwrt.extra_name.name is not false or a valid string!" "openwrt.extra_name.name" $cfg.openwrt.extra_name.name (metadata $cfg).span)
    }
    $extra_name = $cfg.openwrt.extra_name.name
    v-print $"Using extra image name: \'($extra_name)\'"
    $manifest_parameters = ($manifest_parameters | append $"EXTRA_IMAGE_NAME=($extra_name)")
    $image_parameters = ($image_parameters | append $"EXTRA_IMAGE_NAME=($extra_name)")
  }

  # Manifest STRIP_ABI
  if $strip_abi {
    v-print "Will strip ABI information when running 'make manifest'."
    $manifest_parameters = ( $manifest_parameters | append 'STRIP_ABI=1' )
  }

  # Sign images
  if ($cfg.openwrt.sign_image | typeof) != "bool" {
    error make (parser-error "openwrt.sign_image is not boolean!" "openwrt.sign_image" $cfg.openwrt.sign_image (metadata $cfg).span)
  }
  $sign_image = $cfg.openwrt.sign_image
  if $sign_image {
    v-print "Will sign images with a locally-generated key."
    $image_parameters = ( $image_parameters | append 'ADD_LOCAL_KEY=1' )
  }

  # Root Partition Size
  if ($cfg.openwrt.root_partsize | typeof) != int {
    error make (parser-error "openwrt.root_partsize is not an integer!" "openwrt.root_partsize" $cfg.openwrt.root_partsize (metadata $cfg).span)
  }
  $root_partsize = $cfg.openwrt.root_partsize
  if $root_partsize > 0 {
    v-print $"Using root fs size: \'($root_partsize)\'"
    $image_parameters = ($image_parameters | append $"ROOTFS_PARTSIZE=($root_partsize)")
  }

  # Disabled Services
  if (($cfg.openwrt.disabled_services | is-not-empty) and
      ($cfg.openwrt.disabled_services | typeof) != list ) {
    error make (parser-error "openwrt.disabled_services is not null or a list!" "openwrt.disabled_services" $cfg.openwrt.disabled_services (metadata $cfg).span)
  }
  if ($cfg.openwrt.disabled_services | is-not-empty) {
    $disabled_services = $cfg.openwrt.disabled_services
    v-print $"Using disabled services: \'($disabled_services | str join ' ')\'"
    $image_parameters = ($image_parameters | append $"DISABLED_SERVICES=\"($disabled_services | str join ' ')\"")
  }

  # Packages
  if (($cfg.openwrt.packages | is-not-empty) and
      ($cfg.openwrt.packages | typeof) != list ) {
    error make (parser-error "openwrt.packages is not null or a list!" "openwrt.packages" $cfg.openwrt.packages (metadata $cfg).span)
  }
  if ($cfg.openwrt.packages | is-not-empty) {
    $packages = $cfg.openwrt.packages
    v-print $"Using packages: \'($packages | str join ' ')\'"
    $manifest_parameters = ($manifest_parameters | append $"PACKAGES=\"($packages | str join ' ')\"")
    $image_parameters = ($image_parameters | append $"PACKAGES=\"($packages | str join ' ')\"")
  }

  v-print $"
# ------------------------------------- #
# Gathered command parameters.          #
# --------------------------------------#

Docker parameters: \'($docker_parameters | str join ' ')\'

Manifest parameters: \'($manifest_parameters | str join ' ')\'

Image 'make' parameters: \'($make_parameters | str join ' ')\'
Image parameters: \'($image_parameters | str join ' ')\'

# ------------------------------------- #
# Done parsing configuration.           #
# --------------------------------------#
"

  {
    parameters: {
      docker: $docker_parameters
      manifest: $manifest_parameters
      make: $make_parameters
      image: $image_parameters
    }
    container: {
      name: $container_name
      image: $image_name
      tag: $image_tag
      sanitized_tag: $sanitized_tag
      registry: {
        custom: $registry_custom
        source: $registry_source
      }
      network: {
        enabled: $network_custom
        name: $network_name
      }
      user: {
        enabled: $as_user
        usergroup: $usergroup
      }
      mounts: {
        volume: {
          enabled: $named_volume
          name: $volume_name
        }
        output: {
          dir: $output_dir
        }
        files: {
          enabled: $do_files
          dir: $files_dir
        }
        packages: {
          enabled: $do_packages
          dir: $packages_dir
        }
      }
    }
    imagebuilder: {
      profile: $profile
      jobs: $parallel_jobs
      root_size: $root_partsize
      sign_image: $sign_image
      packages: $packages
      disabled_services: $disabled_services
      extra_name: {
        enabled: $extra_enabled
        name: $extra_name
      }
      files: {
        enabled: $do_files
        dir: $files_dir_container
      }
      extra_packages: {
        enabled: $do_packages
        dir: $packages_dir_container
      }
    }
  }
}

def runner [
  task: string
  --output: string
  --package: string
  --verbose
  --log
  --clean
  --strip
]: [record -> nothing] {
  # Convenience
  let $container_name = $in.container.name
  let $image_name = $in.container.image
  let $docker = $in.parameters.docker
  let $manifest = $in.parameters.manifest
  let $make = $in.parameters.make
  let $image = $in.parameters.image
  let $tag = $in.container.sanitized_tag
  let $output_dir = $in.container.mounts.output.dir
  let $do_packages = $in.imagebuilder.extra_packages.enabled
  let $packages_dir = $in.imagebuilder.extra_packages.dir
  let $extra_enabled = $in.imagebuilder.extra_name.enabled
  let $extra_name = $in.imagebuilder.extra_name.name
  let $in_container: closure = {|command: string| ^docker exec $container_name bash -c $"($command)"}
  let $rec = $in

  # Wrap print for an easier check to $verbose
  def --wrapped v-print [
    --no-newline (-n)
    ...rest
  ] {
    if $verbose {
      if $no_newline {
        print ...$rest -n
      } else {
        print ...$rest
      }
    }
  }

  try {
    v-print $"Starting container ($container_name) ... " -n
    ^docker run ...$docker $image_name /bin/bash o> /dev/null
    v-print 'Done!'
  } catch {
    ^docker kill $container_name o+e> /dev/null
    error make { msg: "Something went wrong running the container!" }
  }

  try {
    v-print 'Checking environment for Makefile or setup.sh.'
    do $in_container '[[ -f Makefile ]] || ./setup.sh'
  } catch {
    ^docker kill $container_name o+e> /dev/null
    error make { msg: "Makefile is not present and setup.sh failed?\nSomething is wrong." }
  }

  if $task == 'info' {
    try {
      v-print "Running 'make info'."
      do $in_container 'make info'
    } catch {
      ^docker kill $container_name o+e> /dev/null
      error make { msg: "Error running 'make info'."}
    }
  }

  if $task == 'help' {
    try {
      v-print "Running 'make help'."
      do $in_container 'make help'
    } catch {
      ^docker kill $container_name o+e> /dev/null
      error make { msg: "Error running 'make help'."}
    }
  }

  if $task == 'image' and $clean {
    try {
      v-print "Running 'make clean'."
      do $in_container 'make clean'
    } catch {
      ^docker kill $container_name o+e> /dev/null
      error make { msg: "Error running 'make clean'."}
    }
  }

  if $task in [ 'image', 'manifest', 'depends', 'whatdepends' ] and $do_packages {
    try {
      v-print 'Preparing packages.'
      do $in_container 'rm -fv /builder/packages/*.ipk /builder/packages/*.apk'
      do $in_container $"cp -v ($packages_dir)/* /builder/packages/"
    } catch {
      ^docker kill $container_name o+e> /dev/null
      error make { msg: "Error preparing packages." }
    }
  }

  if $task == 'depends' {
    try {
      v-print "Running 'make package_depends'."
      do $in_container $"make package_depends PACKAGE=($package)"
    } catch {
      ^docker kill $container_name o+e> /dev/null
      error make { msg: "Error running 'make package_depends'."}
    }
  }

  if $task == 'whatdepends' {
    try {
      v-print "Running 'make package_whatdepends'."
      do $in_container $"make package_whatdepends PACKAGE=($package)"
    } catch {
      ^docker kill $container_name o+e> /dev/null
      error make { msg: "Error running 'make package_whatdepends'."}
    }
  }

  if $task == 'manifest' {
    try {
      v-print "Running 'make manifest'."
      do $in_container $"make manifest ($manifest | str join ' ')"
    } catch {
      ^docker kill $container_name o+e> /dev/null
      error make { msg: "Error running 'make manifest'."}
    }
  }

  if $task == 'image' {
    let $date_now: datetime = (date now)
    let $date_file: datetime = ($date_now | format date "%Y-%m-%d-%H-%M-%S")
    let $file_stamp: string = $output_dir + '/' + $"imagebuilder-($tag)(if $extra_enabled { '-' + $extra_name })-($date_file)"

    if $output != null {
      let $build_info: record = {
        build: {
          rfc3339: ($date_now | format date "%+"),
          epoch: ($date_now | format date "%s"),
          clean: $clean
        }
        ...$rec
      }

      let $file_name = $file_stamp + '.' + $output
      v-print $"Saving build info to: \'($file_name)\'"

      match $output {
        'yaml' => {$build_info | to yaml | save -f $file_name},
        'json' => {$build_info | to json | save -f $file_name},
        'toml' => {$build_info | to toml | save -f $file_name},
        'nuon' => {$build_info | to nuon | save -f $file_name},
      }
    }

    try {
      v-print "Running 'make image'."
      if $log {
        do $in_container $"make ($make | str join ' ') image ($image | str join ' ')" o+e>| tee {save -f ($file_stamp + '.log')}
      } else {
        do $in_container $"make ($make | str join ' ') image ($image | str join ' ')" 
      }
    } catch {
      ^docker kill $container_name o+e> /dev/null
      error make { msg: "Error running 'make image'."}
    }
  }

  v-print 'Tasks complete, killing container.'
  ^docker kill $container_name o> /dev/null
}

def typeof []: [ any -> string ] {
  describe --detailed | get type
}

def "main generate-config" [
  --output (-o): string
]: [ nothing -> string ] {
  if $output != null {
    match $output {
      'yaml' => {main generate-config},
      'json' => {main generate-config | from yaml | to json},
      'toml' => {main generate-config | from yaml | to toml},
      'nuon' => {main generate-config | from yaml | to nuon},
      _ => {
        print $"Type '($output)' is not a valid format!"
        main help
        exit 1
      }
    }
  } else {
"# All keys must be present.

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
    - nginx-ssl-util"
  }
}
def "main help" []: [ nothing -> nothing ] {
  print "
yaois.nu
  Yet Another OpenWRT ImageBuilder Script

Usage:
  > yaois.nu make-info
    [-f --file=CONFIG]
    [-q --quiet]
  > yaois.nu make-help
    [-f --file=CONFIG]
    [-q --quiet]
  > yaois.nu make-depends PACKAGE
    [-f --file=CONFIG]
    [-q --quiet]
  > yaois.nu make-whatdepends PACKAGE
    [-f --file=CONFIG]
    [-q --quiet]
  > yaois.nu make-manifest
    [-a --abi]
    [-f --file=CONFIG]
    [-q --quiet]
  > yaois.nu make-image
    [-c --clean]
    [-f --file=CONFIG]
    [-l --log]
    [-o --output=FORMAT]
    [-q --quiet]
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
"
}

def "main check" [
  --file (-f): path
]: [ nothing -> nothing ] {
  parser $file --verbose=true | to yaml | print
}

def "main make-info" [
  --file (-f): path
  --verbose (-v)
]: [ nothing -> nothing ] {
  parser $file --verbose=$verbose | runner 'info' --verbose=$verbose
}

def "main make-help" [
  --file (-f): path
  --verbose (-v)
]: [ nothing -> nothing ] {
  parser $file --verbose=$verbose | runner 'help' --verbose=$verbose
}

def "main make-depends" [
  package: string
  --file (-f): path
  --verbose (-v)
]: [ nothing -> nothing ] {
  parser $file --verbose=$verbose | runner 'depends' --verbose=$verbose --package=$package
}

def "main make-whatdepends" [
  package: string
  --file (-f): path
  --verbose (-v)
]: [ nothing -> nothing ] {
  parser $file --verbose=$verbose | runner 'whatdepends' --verbose=$verbose --package=$package
}

def "main make-manifest" [
  --file (-f): path
  --verbose (-v)
  --abi (-a)
]: [ nothing -> nothing ] {
  parser $file --verbose=$verbose --strip-abi=(not $abi) | runner 'manifest' --verbose=$verbose
}

def "main make-image" [
  --file (-f): path
  --output (-o): string
  --verbose (-v)
  --clean (-c)
  --log (-l)
]: [ nothing -> nothing ] {
  if $output != null and $output not-in [ 'yaml', 'json', 'toml', 'nuon' ] {
    error make { msg: $"($output) is not a valid format for --output=FORMAT!" label: { text: 'Wrong format' span: (metadata $output).span } }
  }
  parser $file --verbose=$verbose | runner 'image' --verbose=$verbose --clean=$clean --log=$log --output=$output
}

def main []: [ nothing -> nothing ] {
  main help
}
