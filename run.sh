#!/usr/bin/env bash

# This script traps it's own errors, no need for a babysitting set -e.
set +e

#
# Global variables
#

if [[ -z "${BW_SERVER}" ]]; then
  echo "BW_SERVER is undefined"
  ecit 1
fi
if [[ -z "${BW_USERNAME}" ]]; then
  echo "BW_USERNAME is undefined"
  ecit 1
fi
if [[ -z "${BW_PASSWORD}" ]]; then
  echo "BW_PASSWORD is undefined"
  ecit 1
fi
if [[ -z "${BW_ORGANIZATION}" ]]; then
  echo "BW_ORGANIZATION is undefined"
  ecit 1
fi
if [[ -z "${SECRETS_FILE}" ]]; then
  echo "SECRETS_FILE is undefined"
  ecit 1
fi

REPEAT_ENABLED="${REPEAT_ENABLED:-false}"
REPEAT_INTERVAL="${REPEAT_INTERVAL:-300}"
if [ "$REPEAT_ENABLED" = true ] ; then
  echo "Repeat enabled with interval ${REPEAT_INTERVAL}."
fi

TEMP_SECRETS_FILE="/tmp/secrets.yaml"

#
# Script functions
#

function login {
    echo "Configuring Bitwarden server..."
    bw config server ${BW_SERVER} &>/dev/null

    echo "Logging into Bitwarden..."
    SESSION=$(bw login --raw ${BW_USERNAME} ${BW_PASSWORD}) &>/dev/null

    if [ $? -eq 0 ]; then
        echo "Bitwarden login succesful!"
        export BW_SESSION=${SESSION}
    else
        echo ""
        echo "Bitwarden login failed. Exiting..."
        exit 1
    fi
}

function logout {
    # Unset the previously set environment variables
    unset BW_SESSION
    unset BW_ORG_ID

    # Logout and ignore possible errors
    bw logout &>/dev/null
    echo "Logged out of Bitwarden."
}

function login_check {
    bw login --check &>/dev/null

    if [ $? -eq 0 ]; then
        echo "Logged in to Bitwarden"
    else
        echo "Bitwarden login expired. Logging in again..."
        login
    fi
}

function set_org_id {
    echo "Retrieving organization id..."
    ORG=$(bw get organization "${BW_ORGANIZATION}" | jq -r '.id') 2>/dev/null

    if [ $? -eq 0 ]; then
        echo "Retrieved organization id for ${BW_ORGANIZATION}"
        export BW_ORG_ID=${ORG}
    else
        echo "Could not retrieve Bitwarden organization ${BW_ORGANIZATION}. Exiting..."
        exit 1
    fi
}

function generate_secrets {
    touch ${TEMP_SECRETS_FILE}

    printf "# Home Assistant secrets file\n" >> ${TEMP_SECRETS_FILE}
    printf "# DO NOT MODIFY -- Managed by Bitwarden Secrets for Home Assistant add-on\n" >> ${TEMP_SECRETS_FILE}

    for row in $(bw list items --organizationid ${BW_ORG_ID} | jq -c '.[] | select(.type == 1) | (.|@base64)'); do
        printf "\n" >> ${TEMP_SECRETS_FILE}

        row_contents=$(echo ${row} | jq -r '@base64d')
        name=$(echo $row_contents | jq -r '.name' | tr '?:&,%@-' ' ' | tr '[]{}#*!|> ' '_' | tr -s '_' | tr '[:upper:]' '[:lower:]')

        write_field "${name}" "${row_contents}" ".login.username" "username"
        write_field "${name}" "${row_contents}" ".login.password" "password"
        write_field "${name}" "${row_contents}" ".notes" "notes"

        write_uris "${name}" "${row_contents}"
        write_custom_fields "${name}" "${row_contents}"

        echo "ROW: ${row_contents}"
    done
}

function generate_secret_files {
    for row in $(bw list items --organizationid ${BW_ORG_ID} | jq -c '.[] | select(.type == 2) | [.name, (.notes|@base64)]')
    do
        file=$(echo $row | jq -r '.[0]')
        dirname=$(dirname $file)
        basename=$(basename $file)

        mkdir -p /config/${dirname}
        rm -f /config/${dirname}/${basename}

        echo ${row} | jq -r '.[1] | @base64d' > "/config/${dirname}/${basename}"
        chmod go-wrx "/config/${dirname}/${basename}"
    done
}

function write_field {
    secret_name=${1}
    row_contents=${2}
    field_name=${3}
    suffix=${4}

    echo "Parsing row ${row_contents}"
    field="$(echo ${row_contents} | jq -r ${field_name})"

    if [ "${field}" != "null" ]; then
        echo "Writing ${secret_name}_${suffix} with ${field}"
        echo "${secret_name}_${suffix}: '${field}'" >> ${TEMP_SECRETS_FILE}
    fi
}

function write_uris {
    secret_name=${1}
    row_contents=${2}

    if [ "$(echo ${row_contents} | jq -r '.login.uris | length')" -gt "0" ]; then
        i=1

        for uris in $(echo ${row_contents} | jq -c '.login.uris | .[] | @base64' ); do
            uri=$(echo ${uris} | jq -r '@base64d' |  jq -r '.uri')

            if [ "${uri}" != "null" ]; then
                echo "Writing ${secret_name}_uri_${i} with ${uri}"
                echo "${secret_name}_uri_${i}: '${uri}'" >> ${TEMP_SECRETS_FILE}

                ((i=i+1))
            fi
        done
    fi
}

function write_custom_fields {
    secret_name=${1}
    row_contents=${2}

    if [ "$(echo ${row_contents} | jq -r '.fields | length')" -gt "0" ]; then
        for fields in $(echo ${row_contents} | jq -c '.fields | .[] | @base64'); do
            field_contents=$(echo ${fields} | jq -r '@base64d')
            field_name=$(echo ${field_contents} | jq -r '.name' | tr '?:&,%@-' ' ' | tr '[]{}#*!|> ' '_' | tr -s '_' | tr '[:upper:]' '[:lower:]')
            field_value=$(echo ${field_contents} | jq -r '.value')

            if [ "${field_name}" != "null" ] && [ "${field_value}" != "null" ]; then
                echo "Writing ${secret_name}_${field_name} with ${field_value}"
                echo "${secret_name}_${field_name}: '${field_value}'" >> ${TEMP_SECRETS_FILE}
            fi
        done
    fi
}

#
# Start of main loop
#

echo "Start retrieving your Home Assistant secrets from Bitwarden"
login
set_org_id

while true; do
    num_of_items=$(bw list items --organizationid ${BW_ORG_ID} | jq length)

    if [ ${num_of_items} -gt 0 ]; then
        echo "Generating ${SECRETS_FILE} file from login entries..."
        generate_secrets
        echo "Home Assistant secrets generated."

        echo "Comparing newly generated secrets to ${SECRETS_FILE}..."
        if cmp -s -- "${TEMP_SECRETS_FILE}" "${SECRETS_FILE}"; then
            rm -f ${TEMP_SECRETS_FILE}
            echo "No secrets changes detected."
        else
            echo "Changes from Bitwarden detected, replacing ${SECRETS_FILE}..."
            mv -f ${TEMP_SECRETS_FILE} ${SECRETS_FILE}
            chmod go-wrx ${SECRETS_FILE}
        fi

        echo "Generating secret files from notes..."
        generate_secret_files
        echo "Secret files created."
    else
        echo "No secrets found in your organisation!"
        echo "--------------------------------------"
        echo "Ensure that you have:"
        echo "  - At least 1 secret in your organisation ${BW_ORGANIZATION}"
        echo "  - Bitwarden is started when using the Bitwarden add-on"
        echo "--------------------------------------"
    fi

    if [ "${REPEAT_ENABLED}" != "true" ]; then
        break
    fi

    sleep "${REPEAT_INTERVAL}"
    login_check

    echo "Syncing Bitwarden vault..."
    bw sync &>/dev/null
    echo "Bitwarden vault synced at: $(bw sync --last)"
done

logout
exit 0
