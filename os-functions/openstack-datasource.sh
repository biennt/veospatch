#!/bin/bash

# Copyright 2015-2016 F5 Networks Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

OS_CONFIG_DIR="/config"
OS_USER_DATA_TMP_FILE="$OS_CONFIG_DIR/openstack-user-data.json"
OS_META_DATA_TMP_FILE="$OS_CONFIG_DIR/openstack-meta-data.json"
OS_USER_DATA_LOCAL_FILE="/config/user-data.json"

OS_USER_DATA_RETRIES=20
OS_USER_DATA_RETRY_INTERVAL=10
OS_USER_DATA_RETRY_MAX_TIME=300

OS_USER_DATA_CLEANUP=true
OS_META_DATA_CLEANUP=true

# Logging settings
LOGGER_TAG="openstack-init"
LOGGER_CMD="logger -t $LOGGER_TAG"

# insert tag and log
function log() {
  echo "$1" | eval "$LOGGER_CMD"
}

# Convert to upper case
function upcase() {
  echo "$1" | tr '[a-z]' '[A-Z]'
}

function is_false() {
    val=$1

    # val is uninitialized
    if [[ ! -n $val ]]; then
        echo 0
        return 0
    fi
    # val is set to 'NONE'
    if [[ $(upcase $val) == 'NONE' ]]; then
        echo 0
        return 0
    fi
    # val is set to 'FALSE'
    if [[ $(upcase $val) == 'FALSE' ]]; then
        echo 0
        return 0
    fi
    # val is equal to '0'
    if [[ $(upcase $val) == '0' ]]; then
        echo 0
        return 0
    fi
}

function get_json_value() {
  echo -n $(perl -MJSON -ne "\$value = decode_json(\$_)->$1; \
    \$value =~ s/([^a-zA-Z0-9])/\$1/g; print \$value" $2)
}

function get_user_data_value() {
  echo -n $(get_json_value $1 $OS_USER_DATA_TMP_FILE)
}

function get_user_data_system_cmds() {
  echo -n $(perl -MJSON -ne "print join(';;', \
  @{decode_json(\$_)->{bigip}{system_cmds}})" $OS_USER_DATA_TMP_FILE)
}

function get_user_data_firstboot_cmds() {
  echo -n $(perl -MJSON -ne "print join(';;', \
  @{decode_json(\$_)->{bigip}{firstboot_cmds}})" $OS_USER_DATA_TMP_FILE)
}

function get_user_data_network_routes() {
  echo -n $(perl -MJSON -ne "\$data = decode_json(\$_); \
  foreach \$route (@{\$data->{'bigip'}->{'network'}->{'routes'}}) { \
    print \$route->{'destination'}.\";\".\$route->{'gateway'}.\"|\"; \
  }" $OS_USER_DATA_TMP_FILE)
}

function get_dhcp_server_address() {
    echo -n $(awk '/dhcp-server-identifier/ { print $3 }' \
	/var/lib/dhclient/dhclient.leases | tail -1 | tr -d ';')
}

# cleanup user-data, disable for debug purposes
function cleanup_user_data() {
	[[ $OS_USER_DATA_CLEANUP == true ]] && rm -f $OS_USER_DATA_TMP_FILE
	[[ $OS_META_DATA_CLEANUP == true ]] && rm -f $OS_META_DATA_TMP_FILE
}

# Check if the URL is available
# arg1: url of metadata service to test
# return:
# 0 -- success
#
function test_metadata_service() {
    local retries=${OS_USER_DATA_RETRIES}
    local url=$1
    local retval=1

    while (( retries > 0 ))
    do
	response_code=$(curl -s --head --output /dev/null -w "%{http_code}\n" $url)
	if [[ ${response_code} == "200" ]]; then
	    retval=0
	    break;
	fi
	sleep 1
	(( retries-- ))
    done
    return ${retval}
}

# Get the URL of a meta data service that provides user data
# using the default EC2 datasouce:http://169.254.169.254/latest/user_data
# If that fails, try the dhcp server as a possible srouce.
# args -- none
# return:
# url of user_data -- success
# "" --failure
function get_metadata_service_url() {

    # EC2 datasource location
    local metadata_url="http://169.254.169.254"

    test_metadata_service "${metadata_url}/latest/meta-data"
    if [[ $? != 0 ]]; then
	dhcp_server_address=$(get_dhcp_server_address)
	log "Metadata server at ${metadata_url} is not available, trying ${dhcp_server_address} instead..."
	metadata_url="http://${dhcp_server_address}"
	test_metadata_service "${metadata_url}/latest/meta-data"
	if [[ $? != 0 ]]; then
	    log "Could not locate a viable metadata server, setting default policy..."
	    metadata_url=""
	fi
    fi

    echo $metadata_url
}

# Retrieve the user data from the metadata service using the passed in URL; otherwise
# try to find the the metadata service at well-known IP's
# args -- url of metadata service
# return:
# 0 -- success
# 1 -- failure
function get_metadata_service_userdata() {
    if [[ $1 == "" ]]; then
	metadata_url=$(get_metadata_service_url)
    else
	metadata_url=$1
    fi

    log "Retrieving user-data from $metadata_url..."
    # Use max-time 10 because it should respond within a second or two
    # and we don't want to waste all of our retry time waiting.
    curl -s -f --retry $OS_USER_DATA_RETRIES --retry-delay \
	$OS_USER_DATA_RETRY_INTERVAL --retry-max-time $OS_USER_DATA_RETRY_MAX_TIME \
	-m 10 \
	-o $OS_USER_DATA_TMP_FILE "${metadata_url}/latest/user-data"

    if [[ $? == 0 ]]; then
	# remove newlines and repeated whitespace from JSON to appease Perl JSON module
	user_data=$(cat $OS_USER_DATA_TMP_FILE)
	echo "$user_data" | tr -d '\n' | tr -d '\r' | tr -s ' ' > $OS_USER_DATA_TMP_FILE

	chmod 0600 $OS_USER_DATA_TMP_FILE
	log "Successfully retrieved user-data from instance metadata service..."
    else
	log "Could not retrieve user-data after $OS_USER_DATA_RETRIES attempts, trying local policy..."
	return 1
    fi

    return 0
}

# Get the user data from a local find in the config directory
# args:
# return:
# 0 -- success
# 1 -- failure
function get_local_userdata() {
    if [[ -f $OS_USER_DATA_LOCAL_FILE ]]; then

	log "Found locally installed $OS_USER_DATA_LOCAL_FILE. Using local file for user data."

	# remove newlines and repeated whitespace from JSON to appease Perl JSON module
	cat $OS_USER_DATA_LOCAL_FILE | tr -d '\n' | tr -d '\r' | tr -s ' ' \
	    > $OS_USER_DATA_TMP_FILE
	chmod 0600 $OS_USER_DATA_TMP_FILE
	return 0
    fi
    return 1
}

# This logic is taken from clound init.  To find a config drive:
# 1. Try the device with label "config-2", this should be sufficient.
# 2. If no device with config-2 label is found:
#    a) try all iso9660 type block devices in reverse order
#    b) try all vfat type block devices in reverse order
#    c) try /dev/hdd if it exists as a block device
# 3. For each device, make sure that it is not a disk partition.  The
#    device should only be an unpartitioned disk.
function get_candidate_config_drives() {
    populate_cache=$(blkid /dev/hd* /dev/sr*)
    config2_dev=$(blkid -t LABEL="config-2" -o device)
    iso9660_devs=$(blkid -t TYPE="iso9660" -o device | sort -r)
    vfat_devs=$(blkid -t TYPE="vfat" -o device | sort -r)

    # If /dev/hdd exists, add it as a possible config drive too.
    ide_dev=""
    if [[ -b /dev/hdd ]]; then
	ide_dev="/dev/hdd"
    fi

    devs_bytype=""
    for dev in "$iso9660_devs $vfat_devs $ide_dev"
    do
	# If this device is a partion skip it
	sfdisk -lq ${dev} >/dev/null 2>&1
	if [[ $? == 0 ]]; then
	    # Append to the list since this is not a partition of a blk device
	    devs_bytype=${devs_bytype:+$devs_bytype }$dev
	fi
    done

    if [[ ${config2_dev} != "" ]]; then
	candidate_devs=$(tr ' ' '\n' <<<"${config2_dev} ${devs_bytype}" | uniq)
    else
	candidate_devs=$(tr ' ' '\n' <<<"${devs_bytype}" | uniq)
    fi

    echo $candidate_devs
}

# Retrieve the user data from the config drive if present.  First, look for
# a block device with label "config-2".  If not available, just try the default
# "/dev/hdd".
# return:
# 0 -- success
# 1 -- failure
function get_config_drive_data() {

    local OS_CONFIG_DRIVE_MOUNT_POINT="/config/OPENSTACK_CONFIG_DRIVE"
    local OS_CONFIG_DRIVE_META_DATA_FILE="/openstack/latest/meta_data.json"
    local OS_CONFIG_DRIVE_USER_DATA_FILE="/openstack/latest/user_data"

    log "Retrieving user-data from config drive..."
    local config_drive=""

    mkdir -p ${OS_CONFIG_DRIVE_MOUNT_POINT}

    # For each device in the config drive candidates list, look for the "openstack" directory.
    local config_drives=$(get_candidate_config_drives)
    for dev in ${config_drives}
    do
	log "Trying ${dev} as a config drive"
	mount -o ro ${dev} ${OS_CONFIG_DRIVE_MOUNT_POINT} 2>&1 | $LOGGER_CMD
	if [[ $? == 0 ]]; then
	    # Mount succeeded, check for openstack directory
	    if [[ -d ${OS_CONFIG_DRIVE_MOUNT_POINT}/openstack ]]; then
		# Found the config drive, break from loop
		config_drive=${dev}
		break
	    else
		# No openstack directory found unmount.
		umount ${OS_CONFIG_DRIVE_MOUNT_POINT}
	    fi
	fi
    done

    # If we found OpenStack config drive copy the data to temp.
    if [[ ${config_drive} != "" ]]; then
	log "Found openstack config drive $config_drive"
	if [[ -f ${OS_CONFIG_DRIVE_MOUNT_POINT}${OS_CONFIG_DRIVE_META_DATA_FILE} ]]; then

            /bin/cp -f ${OS_CONFIG_DRIVE_MOUNT_POINT}${OS_CONFIG_DRIVE_META_DATA_FILE} $OS_META_DATA_TMP_FILE

	    # remove newlines and repeated whitespace from JSON to appease Perl JSON module
            meta_data=$(cat $OS_META_DATA_TMP_FILE)
            echo "$meta_data" | tr -d '\n' | tr -d '\r' | tr -s ' ' > $OS_META_DATA_TMP_FILE
            chmod 0600 $OS_META_DATA_TMP_FILE
        fi
        if [[ -f ${OS_CONFIG_DRIVE_MOUNT_POINT}${OS_CONFIG_DRIVE_USER_DATA_FILE} ]]; then

            /bin/cp -f ${OS_CONFIG_DRIVE_MOUNT_POINT}${OS_CONFIG_DRIVE_USER_DATA_FILE} $OS_USER_DATA_TMP_FILE

            # remove newlines and repeated whitespace from JSON to appease Perl JSON module
            user_data=$(cat $OS_USER_DATA_TMP_FILE)
            echo "$user_data" | tr -d '\n' | tr -d '\r' | tr -s ' ' > $OS_USER_DATA_TMP_FILE
            chmod 0600 $OS_USER_DATA_TMP_FILE
        fi

	# We are done, clean up and return success.
        umount $OS_CONFIG_DRIVE_MOUNT_POINT
	if [[ $? != 0 ]]; then
	    log "ERROR: failed to unmount config drive on $OS_CONFIG_DRIVE_MOUNT_POINT"
	fi

        rmdir $OS_CONFIG_DRIVE_MOUNT_POINT 2>&1 | $LOGGER_CMD
        return 0
    else
	log "No config drive found"
	rmdir $OS_CONFIG_DRIVE_MOUNT_POINT 2>&1 | $LOGGER_CMD
	return 1
    fi
}

# Try to find user data from all data sources.  If successful, return
# 0, else return 1.
function get_user_data() {
    # Create the config directory
    mkdir -p $OS_CONFIG_DIR

    # Just remove any previous files
    rm -f $OS_META_DATA_TMP_FILE
    rm -f $OS_USER_DATA_TMP_FILE

    # If there is user data in the /config directory, use that.
    get_local_userdata
    if [[ $? == 0 ]]; then
	return 0
    fi

    # Next, attempt to retrieve user data from config drive
    get_config_drive_data
    if [[ $? == 0 ]]; then
	return 0
    fi

    # Next, look for user data from the OpenStack metadata service
    get_metadata_service_userdata
    if [[ $? == 0 ]]; then
	return 0
    fi

    return 1
}

function execute_system_cmd() {
    local system_cmds=$(get_user_data_system_cmds)
    [[ ${ssh_key_inject} == true &&
	    $(get_user_data_value {bigip}{continue_on_system_cmd_failure}) == false ]] &&
    continue_on_system_cmd_failure=false
    OIFS=$IFS
    IFS=';;'
    local running_properly=true
    for system_cmd in ${system_cmds}; do
	if [[ -n $system_cmd ]]; then
	    if [[ $running_properly == true ]]; then
		log "Executing system command: $system_cmd..."
		if eval "$system_cmd 2>&1 | sed -e  '/^$/d' -e 's/^/  /' | $LOGGER_CMD"; then
		    log "$system_cmd exited properly..."
		else
		    log "$system_cmd did not exit properly..."
                    if [[ $continue_on_system_cmd_failure == false ]]; then
			running_properly=false
                    fi
		fi
	    else
		log "skipping the execution of $system_cmd due to command failure"
	    fi
	fi
    done
    IFS=$OIFS
}

function execute_firstboot_cmd() {
    firstboot_cmds=$(get_user_data_firstboot_cmds)
    [[ $ssh_key_inject == true &&
	    $(get_user_data_value {bigip}{continue_on_firstboot_cmd_failure}) == false ]] &&
    continue_on_firstboot_cmd_failure=false
    OIFS=$IFS
    IFS=';;'
    running_properly=true
    for firstboot_cmd in $firstboot_cmds; do
	if [[ -n $firstboot_cmd ]]; then
	    if [[ $running_properly == true ]]; then
		log "Executing system command: $firstboot_cmd..."
		if eval "$firstboot_cmd 2>&1 | sed -e  '/^$/d' -e 's/^/  /' | $LOGGER_CMD"; then
		    log "$firstboot_cmd exited properly..."
		else
		    log "$firstboot_cmd did not exit properly..."
		    if [[ $continue_on_firstboot_cmd_failure == false ]]; then
			running_properly=false
		    fi
		fi
	    else
		log "skipping the execution of $firstboot_cmd due to command failure"
	    fi
	fi
    done
    IFS=$OIFS
}

function test() {
	$(get_config_drive_data)
	if [[ $? == 0 ]]; then
		echo "Found config drive"
	fi

	$(get_metadata_service_userdata)
	if [[ $? == 0 ]]; then
		echo "Found metadata from ec2 datasource"
	fi

	$(get_local_userdata)
	if [[ $? == 1 ]]; then
		echo "Found local user data: $OS_USER_DATA_LOCAL_FILE"
	else
		echo "Local user data $OS_USER_DATA_LOCAL_FILE not found"
	fi

	get_user_data
	if [[ $? == 0 ]]; then
		echo "Successfully called get_user_data"
	else
		echo "CAll to get_user_data failed"
	fi

	inject_openssh_key
	if [[ $? == 0 ]]; then
		echo "inject ssh key ... success."
	fi
}

