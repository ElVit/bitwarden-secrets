#!/usr/bin/env bash

# This script traps its own errors, no need for a babysitting set -e.
set +e

# Temp workaround to disable punycode deprecation logging to stderr
# https://github.com/bitwarden/clients/issues/6689
export NODE_OPTIONS="--no-deprecation"

#
# Constants
#
readonly __COLORS_ESCAPE="\033[";
readonly __COLORS_RESET="${__COLORS_ESCAPE}0m"
readonly __COLORS_DEFAULT="${__COLORS_ESCAPE}39m"
readonly __COLORS_BLACK="${__COLORS_ESCAPE}30m"
readonly __COLORS_RED="${__COLORS_ESCAPE}31m"
readonly __COLORS_GREEN="${__COLORS_ESCAPE}32m"
readonly __COLORS_YELLOW="${__COLORS_ESCAPE}33m"
readonly __COLORS_BLUE="${__COLORS_ESCAPE}34m"
readonly __COLORS_MAGENTA="${__COLORS_ESCAPE}35m"
readonly __COLORS_CYAN="${__COLORS_ESCAPE}36m"
readonly __COLORS_LIGHT_GRAY="${__COLORS_ESCAPE}37m"
readonly __COLORS_BG_DEFAULT="${__COLORS_ESCAPE}49m"
readonly __COLORS_BG_BLACK="${__COLORS_ESCAPE}40m"
readonly __COLORS_BG_RED="${__COLORS_ESCAPE}41m"
readonly __COLORS_BG_GREEN="${__COLORS_ESCAPE}42m"
readonly __COLORS_BG_YELLOW="${__COLORS_ESCAPE}43m"
readonly __COLORS_BG_BLUE="${__COLORS_ESCAPE}44m"
readonly __COLORS_BG_MAGENTA="${__COLORS_ESCAPE}45m"
readonly __COLORS_BG_CYAN="${__COLORS_ESCAPE}46m"
readonly __COLORS_BG_WHITE="${__COLORS_ESCAPE}47m"

#
# Script functions
#
log.white()
{
  local message=$*
  echo -e "${message}" >&2
  return 0
}

log.red()
{
  local message=$*
  echo -e "${__COLORS_RED}${message}${__COLORS_RESET}" >&2
  return 0
}

log.green()
{
  local message=$*
  echo -e "${__COLORS_GREEN}${message}${__COLORS_RESET}" >&2
  return 0
}

log.yellow()
{
  local message=$*
  echo -e "${__COLORS_YELLOW}${message}${__COLORS_RESET}" >&2
  return 0
}

login()
{
  log.white "Configuring Bitwarden server..."
  bw config server ${BW_SERVER} &>/dev/null

  log.white "Logging into Bitwarden..."
  SESSION=$(bw login --raw ${BW_USERNAME} ${BW_PASSWORD} &>/dev/null)

  if [ $? -eq 0 ]; then
    log.white "Bitwarden login successful!"
    export BW_SESSION=${SESSION}
  else
    log.red ""
    log.red "Bitwarden login failed. Exiting..."
    exit 1
  fi
}

logout()
{
  # Unset the previously set environment variables
  unset BW_SESSION
  unset BW_ORG_ID

  # Logout and ignore possible errors
  bw logout &>/dev/null
  log.white "Logged out of Bitwarden."
}

login_check()
{
  bw login --check &>/dev/null

  if [ $? -eq 0 ]; then
    log.white "Logged in to Bitwarden"
  else
    log.yellow "Bitwarden login expired. Logging in again..."
    login
  fi
}

set_org_id()
{
  echo "Retrieving organization id..."
  ORG=$(bw get organization "${BW_ORGANIZATION}" | jq -r '.id' 2>/dev/null)

  if [ $? -eq 0 ]; then
    log.white "Retrieved organization id for ${BW_ORGANIZATION}"
    export BW_ORG_ID=${ORG}
  else
    log.red "Could not retrieve Bitwarden organization ${BW_ORGANIZATION}. Exiting..."
    exit 1
  fi
}

generate_secrets()
{
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

    log.white "ROW: ${row_contents}"
  done
}

generate_secret_files()
{
  for row in $(bw list items --organizationid ${BW_ORG_ID} | jq -c '.[] | select(.type == 2) | [.name, (.notes|@base64)]')
  do
    file=$(echo $row | jq -r '.[0]')
    dirname=$(dirname $file)
    basename=$(basename $file)

    mkdir -p ${SECRETS_DIR}/${dirname}
    rm -f ${SECRETS_DIR}/${dirname}/${basename}

    echo ${row} | jq -r '.[1] | @base64d' > "${SECRETS_DIR}/${dirname}/${basename}"
    chmod go-wrx "${SECRETS_DIR}/${dirname}/${basename}"
  done
}

write_field()
{
  secret_name=${1}
  row_contents=${2}
  field_name=${3}
  suffix=${4}

  log.white "Parsing row ${row_contents}"
  field="$(echo ${row_contents} | jq -r ${field_name})"

  if [ "${field}" != "null" ]; then
    log.white "Writing ${secret_name}_${suffix} with ${field}"
    log.white "${secret_name}_${suffix}: '${field}'" >> ${TEMP_SECRETS_FILE}
  fi
}

write_uris()
{
  secret_name=${1}
  row_contents=${2}

  if [ "$(echo ${row_contents} | jq -r '.login.uris | length')" -gt "0" ]; then
    i=1
    for uris in $(echo ${row_contents} | jq -c '.login.uris | .[] | @base64' ); do
      uri=$(echo ${uris} | jq -r '@base64d' |  jq -r '.uri')
      if [ "${uri}" != "null" ]; then
        log.white "Writing ${secret_name}_uri_${i} with ${uri}"
        "${secret_name}_uri_${i}: '${uri}'" >> ${TEMP_SECRETS_FILE}
        ((i=i+1))
      fi
    done
  fi
}

write_custom_fields()
{
  secret_name=${1}
  row_contents=${2}

  if [ "$(echo ${row_contents} | jq -r '.fields | length')" -gt "0" ]; then
    for fields in $(echo ${row_contents} | jq -c '.fields | .[] | @base64'); do
      field_contents=$(echo ${fields} | jq -r '@base64d')
      field_name=$(echo ${field_contents} | jq -r '.name' | tr '?:&,%@-' ' ' | tr '[]{}#*!|> ' '_' | tr -s '_' | tr '[:upper:]' '[:lower:]')
      field_value=$(echo ${field_contents} | jq -r '.value')

      if [ "${field_name}" != "null" ] && [ "${field_value}" != "null" ]; then
        log.white "Writing ${secret_name}_${field_name} with ${field_value}"
        log.white "${secret_name}_${field_name}: '${field_value}'" >> ${TEMP_SECRETS_FILE}
      fi
    done
  fi
}

#
# Global variables
#
if [[ -z "${BW_SERVER}" ]]; then
  log.red "EnvVar 'BW_SERVER' is undefined."
  exit 1
fi
if [[ -z "${BW_USERNAME}" ]]; then
  log.red "EnvVar 'BW_USERNAME' is undefined."
  exit 1
fi
if [[ -z "${BW_PASSWORD}" ]]; then
  log.red "EnvVar 'BW_PASSWORD' is undefined."
  exit 1
fi
if [[ -z "${BW_ORGANIZATION}" ]]; then
  log.red "EnvVar 'BW_ORGANIZATION' is undefined."
  exit 1
fi

REPEAT_ENABLED="${REPEAT_ENABLED:-false}"
REPEAT_INTERVAL="${REPEAT_INTERVAL:-300}"
if [ "$REPEAT_ENABLED" = true ] ; then
  log.white "Repeat enabled with interval ${REPEAT_INTERVAL}."
else
  log.white "Repeat disabled."
fi

SECRETS_FILE="${SECRETS_FILE:-/output/secrets.yaml}"
log.white "Secrets will be saved to ${SECRETS_FILE}."
SECRETS_DIR="${SECRETS_FILE%/*}"
log.white "Ensuring directory $SECRETS_DIR exists."
mkdir -v -p $SECRETS_DIR

TEMP_SECRETS_FILE="/tmp/secrets.yaml"
TEMP_SECRETS_DIR="${TEMP_SECRETS_FILE%/*}"
log.white "Ensuring directory $TEMP_SECRETS_DIR exists."
mkdir -v -p $TEMP_SECRETS_DIR

#
# Start of main loop
#
log.white "Start retrieving your Home Assistant secrets from Bitwarden"
login
set_org_id

while true; do
  num_of_items=$(bw list items --organizationid ${BW_ORG_ID} | jq length)

  if [ ${num_of_items} -gt 0 ]; then
    log.white "Generating ${SECRETS_FILE} file from login entries..."
    generate_secrets
    log.white "Home Assistant secrets generated."

    log.white "Comparing newly generated secrets to ${SECRETS_FILE}..."
    if cmp -s -- "${TEMP_SECRETS_FILE}" "${SECRETS_FILE}"; then
      rm -f ${TEMP_SECRETS_FILE}
      log.white "No secrets changes detected."
    else
      log.white "Changes from Bitwarden detected, replacing ${SECRETS_FILE}..."
      mv -f ${TEMP_SECRETS_FILE} ${SECRETS_FILE}
      chmod go-wrx ${SECRETS_FILE}
    fi

    log.white "Generating secret files from notes..."
    generate_secret_files
    log.white "Secret files created."
  else
    log.red "No secrets found in your organisation!"
    log.red "--------------------------------------"
    log.red "Ensure that you have:"
    log.red "  - At least 1 secret in your organisation ${BW_ORGANIZATION}"
    log.red "  - Bitwarden is started when using the Bitwarden add-on"
    log.red "--------------------------------------"
  fi

  if [ "${REPEAT_ENABLED}" != "true" ]; then
    break
  fi

  log.white "Wait ${REPEAT_INTERVAL} seconds ..."
  sleep "${REPEAT_INTERVAL}"
  login_check

  log.white "Syncing Bitwarden vault..."
  bw sync &>/dev/null
  log.white "Bitwarden vault synced at: $(bw sync --last)"
done

logout
exit 0
