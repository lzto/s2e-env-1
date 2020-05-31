#!/bin/bash
#
# This file was automatically generated by s2e-env at {{ creation_time }}
#
# This bootstrap script is used to control the execution of the target program
# in an S2E guest VM.
#
# When you run launch-s2e.sh, the guest VM calls s2eget to fetch and execute
# this bootstrap script. This bootstrap script and the S2E config file
# determine how the target program is analyzed.
#

set -x

{% if project_type == 'windows' %}
cd /c/s2e
{% endif %}

mkdir -p guest-tools32
TARGET_TOOLS32_ROOT=guest-tools32

{% if image_arch=='x86_64' %}
mkdir -p guest-tools64
TARGET_TOOLS64_ROOT=guest-tools64
{% endif %}

{% if image_arch=='x86_64' %}
# 64-bit tools take priority on 64-bit architectures
TARGET_TOOLS_ROOT=${TARGET_TOOLS64_ROOT}
{% else %}
TARGET_TOOLS_ROOT=${TARGET_TOOLS32_ROOT}
{% endif %}


# To save the hassle of rebuilding guest images every time you update S2E's guest tools,
# the first thing that we do is get the latest versions of the guest tools.
function update_common_tools {
    local OUR_S2EGET

    OUR_S2EGET=${S2EGET}

    # First, download the common tools
    {% if project_type == 'windows' %}
    # Windows does not allow s2eget.exe to overwrite itself, so we need a workaround.
    if echo ${COMMON_TOOLS} | grep -q s2eget; then
      OUR_S2EGET=${S2EGET}_old.exe
      mv ${S2EGET} ${OUR_S2EGET}
    fi
    {% endif %}

    for TOOL in ${COMMON_TOOLS}; do
        ${OUR_S2EGET} ${TARGET_TOOLS_ROOT}/${TOOL}
        chmod +x ${TOOL}
    done
}

function update_target_tools {
    for TOOL in $(target_tools); do
        ${S2EGET} ${TOOL} ${TOOL}
        chmod +x ${TOOL}
    done
}

function prepare_target {
    # Make sure that the target is executable
    chmod +x "$1"
}

{% if use_symb_input_file %}
# This prepares the symbolic file inputs.
# This function takes as input an optional seed file name.
# If the seed file is present, the commands makes the seed symbolic.
# Otherwise, it creates an empty file.
#
# Symbolic files must be stored in a ram disk, as only memory (and cpu)
# is capable of holding symbolic data.
#
# This function prints the path to the symbolic file on stdout.
function prepare_inputs {
    local SEED_FILE
    local SYMB_FILE

    # This can be empty if there are no seed files
    SEED_FILE="$1"

    # Check whether the target has custom handling
    # of seed files.
    if [ $(make_seeds_symbolic) -eq 0 ]; then
        echo ${SEED_FILE}
        return
    fi

    {% if project_type == 'windows' %}
    SYMB_FILE="x:\\input"
    {% else %}
    SYMB_FILE="/tmp/input"
    {% endif %}

    if [ "x$SEED_FILE" = "x" ]; then
        # Create a symbolic file of size 256 bytes.
        # Note: you can customize this commands according to your needs.
        # You could, e.g., use non-zero input, different sizes, etc.
        {% if project_type == 'windows' %}
        /c/Python27/python.exe -c "fp = open(\"${SYMB_FILE}\", 'wb'); fp.write('x'*256)"
        {% else %}
        truncate -s 256 ${SYMB_FILE}
        {% endif %}

        if [ $? -ne 0 ]; then
            ${S2ECMD} kill 1 "Failed to create symbolic file"
            exit 1
        fi
    else
        ${S2EGET} ${SEED_FILE} >/dev/null
        if [ ! -f ${SEED_FILE} ]; then
            ${S2ECMD} kill 1 "Could not fetch seed file ${SEED_FILE} from the host"
        fi

        EXTENSION="${SEED_FILE##*.}"
        if [ "x${EXTENSION}" != "x" ]; then
            # Preserving the seed extension may be important for some programs
            # (e.g., Office, Acrobat...).
            SYMB_FILE=${SYMB_FILE}.${EXTENSION}
        fi

        {% if project_type == 'windows' %}
        run_cmd "copy ${SEED_FILE} ${SYMB_FILE}" > /dev/null
        {% else %}
        cp ${SEED_FILE} ${SYMB_FILE}
        {% endif %}

        ${S2EGET} ${SEED_FILE}.symranges >/dev/null
    fi

    # Make the file symbolic
    if [ -f "${SEED_FILE}.symranges" ]; then
       export S2E_SYMFILE_RANGES="${SEED_FILE}.symranges"
    fi

    {% if enable_pov_generation %}
    # It is important to have one symbolic variable by byte to make PoV generation work.
    # One-byte variables simplify input mapping in the Recipe plugin.
    ${S2ECMD} symbfile 1 ${SYMB_FILE} >/dev/null
    {% else %}
    # The symbolic file will be split into symbolic variables of up to 4k bytes each.
    ${S2ECMD} symbfile 4096 ${SYMB_FILE} >/dev/null
    {% endif %}
    echo ${SYMB_FILE}
}
{% endif %}

# This function executes the target program given in arguments.
#
# There are two versions of this function:
#    - without seed support
#    - with seed support (-s argument when creating projects with s2e_env)
function execute {
    local TARGET
    local SEED_FILE
    local SYMB_FILE

    TARGET=$1

    prepare_target "${TARGET}"

    {% if use_seeds %}
    # In seed mode, state 0 runs in an infinite loop trying to fetch and
    # schedule new seeds. It works in conjunction with the SeedSearcher plugin.
    # The plugin schedules state 0 only when seeds are available.

    # Enable seeds and wait until a seed file is available. If you are not
    # using seeds then this loop will not affect symbolic execution - it will
    # simply never be scheduled.
    ${S2ECMD} seedsearcher_enable
    while true; do
        SEED_FILE=$(${S2ECMD} get_seed_file)

        if [ $? -eq 1 ]; then
            # Avoid flooding the log with messages if we are the only runnable
            # state in the S2E instance
            sleep 1
            continue
        fi

        break
    done

    if [ -n "${SEED_FILE}" ]; then
        SYMB_FILE="$(prepare_inputs ${SEED_FILE})"
        execute_target "${TARGET}" "${SYMB_FILE}"
    else
        # If there are no seeds available, execute the seedless instance.
        # The SeedSearcher only schedules the seedless instance once.
        #
        echo "Starting seedless execution"

        # NOTE: If you do not want to use seedless execution, comment out
        # the following line.
        execute_target "${TARGET}"
    fi

    {% else %}
    {% if use_symb_input_file %}
    SYMB_FILE="$(prepare_inputs)"
    {% endif %}
    execute_target "${TARGET}" "${SYMB_FILE}"
    {% endif %}
}

###############################################################################
# This section contains target-specific code

{% include '%s' % target_bootstrap_template %}

###############################################################################


update_common_tools
update_target_tools

{% if project_type != 'windows' %}

# Don't print crashes in the syslog. This prevents unnecessary forking in the
# kernel
sudo sysctl -w debug.exception-trace=0

# Prevent core dumps from being created. This prevents unnecessary forking in
# the kernel
ulimit -c 0

# Ensure that /tmp is mounted in memory (if you built the image using s2e-env
# then this should already be the case. But better to be safe than sorry!)
if ! mount | grep "/tmp type tmpfs"; then
    sudo mount -t tmpfs -osize=10m tmpfs /tmp
fi

# Need to disable swap, otherwise there will be forced concretization if the
# system swaps out symbolic data to disk.
sudo swapoff -a

{% endif %}

target_init

# Download the target file to analyze
{% for tf in target.names -%}
${S2EGET} "{{ tf }}"
{% endfor %}

{% if target %}
# Run the analysis

{% if target.translated_path %}
  execute '{{ target.translated_path }}'
{% else %}
  {% if project_type == 'windows' %}
    execute '{{ target.name }}'
  {% else %}
    execute './{{ target.name }}'
  {% endif %}
{% endif %}

{% else %}
##### NO TARGET HAS BEEN SPECIFIED DURING PROJECT CREATION #####
##### Please fetch and execute the target files manually   #####
{% endif %}
