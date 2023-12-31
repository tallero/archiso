#!/usr/bin/env bash
#
# This script is run within a virtual environment to build the available archiso profiles and their available build
# modes and create checksum files for the resulting images.
# The script needs to be run as root and assumes $PWD to be the root of the repository.
#
# Dependencies:
# * all archiso dependencies
# * coreutils
# * gnupg
# * openssl
# * zsync
#
# $1: profile
# $2: buildmode

set -euo pipefail
shopt -s extglob

readonly orig_pwd="${PWD}"
readonly output="${orig_pwd}/output"
readonly tmpdir_base="${orig_pwd}/tmp"
readonly profile="${1}"
readonly buildmode="${2}"
readonly install_dir="arch"

tmpdir=""
tmpdir="$(mktemp --dry-run --directory --tmpdir="${tmpdir_base}")"
gnupg_homedir=""
codesigning_dir=""
codesigning_cert=""
codesigning_key=""
pgp_key_id=""
pgp_sender=""

signature_info() {
  sig_country="DE"
  sig_state="Berlin"
  sig_city="Berlin"
  sig_org="Arch Linux"
  sig_unit="Release Engineering"
  sig_domain="archlinux.org"
  sig_email="arch-releng@lists.${sig_domain}"
  sig_comment="Ephemeral Signing Key"
}

# Section start display function
# $1: section name
# $2: section title
print_section_start() {
  # gitlab collapsible sections start:
  # https://docs.gitlab.com/ee/ci/jobs/#custom-collapsible-sections
  local _section="${1}"
  local _title="${2}"
  printf "\e[0Ksection_start:%(%s)T:%s\r\e[0K%s\n" '-1' "${_section}" "${_title}"
}

# Section end display function
# $1: section name
print_section_end() {
  # gitlab collapsible sections end:
  # https://docs.gitlab.com/ee/ci/jobs/#custom-collapsible-sections
  local _section
  _section="${1}"
  printf "\e[0Ksection_end:%(%s)T:%s\r\e[0K\n" '-1' "${_section}"
}

# Cleans up temporary directories
cleanup() {
  print_section_start "cleanup" "Cleaning up temporary directory"

  if [ -n "${tmpdir_base:-}" ]; then
    rm -fr "${tmpdir_base}"
  fi

  print_section_end "cleanup"
}

# Creates checksums for files
# $@: files
create_checksums() {
  local _file_path _file_name _current_pwd
  _current_pwd="${PWD}"

  print_section_start "checksums" "Creating checksums"

  for _file_path in "$@"; do
    cd "$(dirname "${_file_path}")"
    _file_name="$(basename "${_file_path}")"
    b2sum "${_file_name}" > "${_file_name}.b2"
    md5sum "${_file_name}" > "${_file_name}.md5"
    sha1sum "${_file_name}" > "${_file_name}.sha1"
    sha256sum "${_file_name}" > "${_file_name}.sha256"
    sha512sum "${_file_name}" > "${_file_name}.sha512"
    ls -lah "${_file_name}."{b2,md5,sha{1,256,512}}
    cat "${_file_name}."{b2,md5,sha{1,256,512}}
  done
  cd "${_current_pwd}"

  print_section_end "checksums"
}

# Creates zsync control files for files
# $@: files
create_zsync_delta() {
  local _file

  print_section_start "zsync_delta" "Creating zsync delta"

  for _file in "$@"; do
    if [[ "${buildmode}" == "bootstrap" ]]; then
      # zsyncmake fails on 'too long between blocks' with default block size on bootstrap image
      zsyncmake -v -b 512 -C -u "${_file##*/}" -o "${_file}".zsync "${_file}"
    else
      zsyncmake -v -C -u "${_file##*/}" -o "${_file}".zsync "${_file}"
    fi
  done

  print_section_end "zsync_delta"
}

# Creates metrics
create_metrics() {
  local _metrics="${output}/metrics.txt"
  print_section_start "metrics" "Creating metrics"

  {
    # create metrics based on buildmode
    case "${buildmode}" in
      iso)
        printf 'image_size_mebibytes{image="%s"} %s\n' \
          "${profile}" \
          "$(du -m -- "${output}/"*.iso | cut -f1)"
        printf 'package_count{image="%s"} %s\n' \
          "${profile}" \
          "$(sort -u -- "${tmpdir}/iso/"*/pkglist.*.txt | wc -l)"
        if [[ -e "${tmpdir}/efiboot.img" ]]; then
          printf 'eltorito_efi_image_size_mebibytes{image="%s"} %s\n' \
            "${profile}" \
            "$(du -m -- "${tmpdir}/efiboot.img" | cut -f1)"
        fi
        # shellcheck disable=SC2046
        # shellcheck disable=SC2183
        printf 'initramfs_size_mebibytes{image="%s",initramfs="%s"} %s\n' \
          $(du -m -- "${tmpdir}/iso/"*/boot/**/initramfs*.img | \
            awk -v profile="${profile}" \
            'function basename(file) {
              sub(".*/", "", file)
              return file
            }
            { print profile, basename($2), $1 }'
          )
        ;;
      netboot)
        printf 'netboot_size_mebibytes{image="%s"} %s\n' \
          "${profile}" \
          "$(du -m -- "${output}/${install_dir}/" | tail -n1 | cut -f1)"
        printf 'netboot_package_count{image="%s"} %s\n' \
          "${profile}" \
          "$(sort -u -- "${tmpdir}/iso/"*/pkglist.*.txt | wc -l)"
        ;;
      bootstrap)
        printf 'bootstrap_size_mebibytes{image="%s"} %s\n' \
          "${profile}" \
          "$(du -m -- "${output}/"*.tar*(.gz|.xz|.zst) | cut -f1)"
        printf 'bootstrap_package_count{image="%s"} %s\n' \
          "${profile}" \
          "$(sort -u -- "${tmpdir}/"*/bootstrap/root.*/pkglist.*.txt | wc -l)"
        ;;
    esac
  } > "${_metrics}"
  ls -lah "${_metrics}"
  cat "${_metrics}"

  print_section_end "metrics"
}

# Create ephemeral signing keys
create_ephemeral_keys() {
  local _gen_key
  local _gen_key_options=('ephemeral') _gpg_options=() _openssl_options=()
  _gen_key="$(pwd)/.gitlab/ci/gen_key.sh"
  [ -e "${_gen_key}" ] || \
    _gen_key="mkarchisogenkey"
  print_section_start "ephemeral_pgp_key" "Creating ephemeral PGP key"
  local gnupg_homedir="${tmpdir}/.gnupg"
  signature_info
  _gpg_options+=("${gnupg_homedir}"
                 "${sig_email}"
                 "${sig_unit}"
                 "${sig_comment}")
  "${_gen_key}" "${_gen_key_options[@]}" 'pgp' "${_gpg_options[@]}"
  print_section_end "ephemeral_pgp_key"
  print_section_start "ephemeral_codesigning_key" "Creating ephemeral codesigning key"
  codesigning_dir="${tmpdir}/.codesigning/"
  _openssl_options+=("${codesigning_dir}"
                     "${sig_country}"
                     "${sig_state}"
                     "${sig_city}"
                     "${sig_org}"
                     "${sig_unit}"
                     "${sig_domain}")
  "${_gen_key}" "${_gen_key_options[@]}" 'openssl' "${_openssl_options[@]}"
  print_section_end "ephemeral_codesigning_key"
}

setup_repo() {
  local _awk_split_cmd \
	_build_repo \
	_build_repo_cmds=() \
	_build_repo_options=() \
	_build_repo_cmd \
	_ci_bin \
	_conflict \
	_conflicts=() \
	_conflicts_line \
	_gen_pacman_conf \
        _gitlab="https://gitlab.archlinux.org" \
	_home \
        _packages=() \
	_packages_extra \
	_pacman_conf \
	_pacman_opts=() \
	_pkg \
	_repo \
        _server="/tmp/archiso-profiles/${profile}" \
        _setup_repo_msg="Setup ${profile} ${buildmode} additional packages" \
	_setup_user \
	_src \
	_src_profile \
        _user="user" \
        _ur \
        _ur_ns="tallero"
  _build_repo_options=(
    'src'
    'packages.extra'
    "${_server}"
  )
  _awk_split_cmd='{split($0,pkgs," "); for (pkg in pkgs) { print pkgs[pkg] } }'
  _home="/home/${_user}"
  _profile="${_home}/${profile}"
  _pacman_conf="${_profile}/pacman.conf"
  _pacman_opts+=(--config "${_pacman_conf}")
  _src="$(pwd)"
  _ci_bin="${_src}/.gitlab/ci"
  _ur="${_ci_bin}/ur"
  _src_profile="${_src}/configs/${profile}"
  _packages_extra="${_src_profile}/packages.extra"
  git clone "${_gitlab}/${_ur_ns}/ur" "${_ur}"
  _build_repo="${_ur}/ur/build_repo.sh"
  _setup_user="${_ur}/ur/setup_user.sh"
  _gen_pacman_conf="${_ur}/ur/set_custom_repo.sh"
  [ -e "${_build_repo}" ] || \
    _build_repo="mkarchisorepo"
  [ -e "${_gen_pacman_conf}" ] || \
    _gen_pacman_conf="mkarchisosetrepo"
  [ -e "${_setup_user}" ] || \
    _setup_user="mkarchisorepobuilder"
  _build_repo_cmds=(
    "cd ${_profile}"
    "${_build_repo} ${_build_repo_options[*]}")
  _build_repo_cmd="$(IFS=";" ; \
                     echo "${_build_repo_cmds[*]}")"
  print_section_start "setup_repo" "${_setup_repo_msg}"
  [ -e "${_packages_extra}" ] && \
    #shellcheck disable=SC1090
    source "${_packages_extra}"
  if [[ "${_packages[*]}" != "" ]] ; then
    "${_setup_user}" "${_user}"
    cp -r "${_src_profile}" \
	  "${_home}"
    chown -R "${_user}:${_user}" \
	     "${_profile}"
    chmod 700 "${_profile}"
    echo "${_build_repo_cmd}"
    su user -c "${_build_repo_cmd}"
    "${_gen_pacman_conf}" "${profile}" \
                          "${_server}" \
      		          "${_src_profile}/pacman.conf" \
      		          "${_pacman_conf}"
    pacman "${_pacman_opts[@]}" -Sy
    for _pkg in "${_packages[@]}"; do
      echo "Removing conflicts for ${_pkg}"
      _conflicts_line="$(pacman "${_pacman_opts[@]}" \
	                        -Si "${_pkg}" \
	                   | grep Conflicts)"
      _conflicts=(
        $(echo ${_conflicts_line##*:} | \
	    awk "${_awk_split_cmd}"))
      for _conflict in "${_conflicts[@]}"; do
	echo "Removing '${_conflict}'"
        pacman -Rdd "${_conflict}" \
		--noconfirm || true
      done
    done
    echo "Installing ${_packages[@]}"
    pacman "${_pacman_opts[@]}" \
	    -Sdd "${_packages[@]}" \
	    --noconfirm
  fi
  print_section_end "setup_repo"
}

run_mkarchiso() {
  local _mkarchiso="./archiso/mkarchiso"
  local _archiso_options=()
  mkdir -p "${output}/" "${tmpdir}/"
  create_ephemeral_keys
  setup_repo
  _archiso_options+=(
    '-D' "${install_dir}" 
    '-c' "${codesigning_cert} ${codesigning_key}"
    '-g' "${pgp_key_id}"
    '-G' "${pgp_sender}"
    '-o' "${output}/"
    '-w' "${tmpdir}/"
    '-v')
  [ "${buildmode}" != "iso" ] && \
    _archiso_options+=('-m' "${buildmode}")
  print_section_start "mkarchiso" "Running mkarchiso"
  [ -e "${_mkarchiso}" ] || \
    _mkarchiso="mkarchiso"
  GNUPGHOME="${gnupg_homedir}" \
    "${_mkarchiso}" "${_archiso_options[@]}" \
                    "configs/${profile}"
  print_section_end "mkarchiso"
  [[ "${buildmode}" =~ "iso" ]] && \
    create_zsync_delta "${output}/"*.iso && \
    create_checksums "${output}/"*.iso
  [[ "${buildmode}" == "bootstrap" ]] && \
    create_zsync_delta "${output}/"*.tar*(.gz|.xz|.zst) && \
    create_checksums "${output}/"*.tar*(.gz|.xz|.zst)
  create_metrics
  print_section_start "ownership" "Setting ownership on output"
  [[ -n "${SUDO_UID:-}" ]] && \
  [[ -n "${SUDO_GID:-}" ]] && \
    chown -Rv "${SUDO_UID}:${SUDO_GID}" -- "${output}"
  print_section_end "ownership"
}

trap cleanup EXIT

run_mkarchiso

# vim:set sw=4 sts=-1 et:
