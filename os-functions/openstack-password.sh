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

source /config/os-functions/openstack-datasource.sh

# BIG-IP password settings
readonly OS_CHANGE_PASSWORDS=true

function randomize_base_passwords() {
    admin_password=`< /dev/urandom tr -dc A-Z | head -c10`
    root_password=`< /dev/urandom tr -dc A-Z | head -c10`

    /usr/bin/passwd admin $admin_password >/dev/null 2>&1
    /usr/bin/passwd root $root_password >/dev/null 2>&1

    echo "" >> /dev/kmsg
    echo "" >> /dev/kmsg
    echo "########################################################" >> /dev/kmsg
    echo "#                                                      #" >> /dev/kmsg
    echo "# random root password:           $root_password           #" >> /dev/kmsg
    echo "# random admin password:          $admin_password           #" >> /dev/kmsg
    echo "#                                                      #" >> /dev/kmsg
    echo "########################################################" >> /dev/kmsg
    echo "" >> /dev/kmsg
    echo "" >> /dev/kmsg
    echo "    r: $root_password   a: $admin_password" >> /etc/issue
    echo "" >> /etc/issue
}

function generate_sha512_passwd_hash() {
  salt=$(openssl rand -base64 8)
  echo -n $(perl -e "print crypt(q[$1], \"\\\$6\\\$$salt\\\$\")")
}

function change_passwords() {
    local root_password=$(get_user_data_value {bigip}{root_password})
    local admin_password=$(get_user_data_value {bigip}{admin_password})
    local PW_REGEX='^\$[0-9][A-Za-z]?\$'

    local change_passwords=$OS_CHANGE_PASSWORDS
    [[ $change_passwords == true && \
	$(get_user_data_value {bigip}{change_passwords}) == false ]] && \
	change_passwords=false

    if [[ $change_passwords == true ]]; then
	for creds in root:$root_password admin:$admin_password; do
	    local user=$(cut -d ':' -f1 <<< $creds)
	    local password=$(cut -d ':' -f2 <<< $creds)

	    if [[ $(is_false ${password}) ]]; then
		# Should the password be changed to the UUID of the instance?
		log "No $user password found in user-data, skipping..."
	    else
		if [[ $password =~ $PW_REGEX ]]; then
		    password_hash=$password
		    log "Found hash for salted password, successfully changed $user password..."
		else
		    # Should this be allowed???
		    password_hash=$(generate_sha512_passwd_hash "$password")
		    log "Found plain text password and (against my better judgment) successfully changed $user passw\
ord..."
		fi

		sed -e "/auth user $user/,/}/ s|\(encrypted-password \).*\$|\1\"$password_hash\"|" \
		    -i /config/bigip_user.conf
	    fi
	done

	tmsh load sys config user-only 2>&1 | eval $LOGGER_CMD
    else
	log "Password changes have been disabled, skipping..."
    fi
}

