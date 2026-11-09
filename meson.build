project(
  'pixie',
  version: '0.1.0',
  meson_version: '>=1.3.0',
  license: 'MIT',
  default_options: ['prefix=/usr'],
)

pixie_dir = get_option('datadir') / 'pixie'

# The command and the helpers a build runs live in share/pixie.
# bin/pixie points at that command. A user install is ~/.local;
# the system install, including Debian, is /usr.
commands = [
  'pixie',
  'pixie-tree.sh',
  'activate-pixie.sh',
  'stage-runtime.sh',
  'meson-wrapper.sh',
  'verify-pixie.sh',
]
foreach name : commands
  install_data(
    'scripts' / name,
    install_dir: pixie_dir,
    install_mode: 'rwxr-xr-x',
  )
endforeach

install_data(
  'scripts' / 'pixie-common.sh',
  install_dir: pixie_dir,
  install_mode: 'rw-r--r--',
)
install_data('data' / 'abi', install_dir: pixie_dir)
install_data('data' / 'build-order.txt', install_dir: pixie_dir)

install_symlink(
  'pixie',
  pointing_to: '..' / 'share' / 'pixie' / 'pixie',
  install_dir: get_option('bindir'),
)
