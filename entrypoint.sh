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
readonly __COLORS_RED="${__COLORS_ESCAPE}31m"
readonly __COLORS_GREEN="${__COLORS_ESCAPE}32m"
readonly __COLORS_YELLOW="${__COLORS_ESCAPE}33m"
readonly __COLORS_BLUE="${__COLORS_ESCAPE}34m"

#
# Script functions
#
log.white()
{
  local message=$*
  echo -e "${__COLORS_DEFAULT}${message}${__COLORS_RESET}" >&2
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

log.blue()
{
  local message=$*
  echo -e "${__COLORS_BLUE}${message}${__COLORS_RESET}" >&2
  return 0
}

bw.login()
{
  log.white "Configuring bitwarden server ..."
  bw config server ${BW_SERVER} &>/dev/null

  log.white "Logging into bitwarden ..."
  SESSION=$(bw login --raw ${BW_USERNAME} ${BW_PASSWORD}) &>/dev/null

  if [ $? -eq 0 ]; then
    log.white "Bitwarden login successful!"
    export BW_SESSION=${SESSION}
  else
    echo ""
    log.red "Bitwarden login failed. Exiting ..."
    exit 1
  fi
}

bw.logout()
{
  # Unset the previously set environment variables
  unset BW_SESSION
  unset BW_ORG_ID

  # Logout and ignore possible errors
  bw logout &>/dev/null
  log.white "Logged out of bitwarden."
}

bw.login_check()
{
  bw login --check &>/dev/null

  if [ $? -eq 0 ]; then
    log.white "Logged in to bitwarden."
  else
    log.yellow "Bitwarden login expired. Logging in again ..."
    bw.login
  fi
}

bw.set_org_id()
{
  log.white "Retrieving organization id ..."
  ORG=$(bw get organization "${BW_ORGANIZATION}" | jq -r '.id') 2>/dev/null

  if [ $? -eq 0 ]; then
    log.white "Retrieved organization id for '${BW_ORGANIZATION}'"
    export BW_ORG_ID=${ORG}
  else
    log.red "Could not retrieve bitwarden organization ${BW_ORGANIZATION}. Exiting ..."
    exit 1
  fi
}

bw.generate_secrets()
{
  touch ${TEMP_SECRETS_FILE}
  echo "# bitwarden secrets file" >> ${TEMP_SECRETS_FILE}
  echo "# DO NOT MODIFY -- managed by bitwarden-secrets docker container" >> ${TEMP_SECRETS_FILE}

  for row in $(bw list items --organizationid ${BW_ORG_ID} | jq -c '.[] | select(.type == 1) | (.|@base64)'); do
    if [[ -z "${row}" ]]; then
      continue
    fi
    printf "\n" >> ${TEMP_SECRETS_FILE}
    row_contents=$(echo ${row} | jq -r '@base64d')
    name=$(echo $row_contents | jq -r '.name' | tr '?:&,%@-' ' ' | tr '[]{}#*!|> ' '_' | tr -s '_' | tr '[:upper:]' '[:lower:]')

    bw.write_field "${name}" "${row_contents}" ".login.username" "username"
    bw.write_field "${name}" "${row_contents}" ".login.password" "password"
    bw.write_field "${name}" "${row_contents}" ".notes" "notes"
    bw.write_uris "${name}" "${row_contents}"
    bw.write_custom_fields "${name}" "${row_contents}"
    #log.blue "ROW: ${row_contents}"
  done
}

bw.generate_secret_files()
{
  for row in $(bw list items --organizationid ${BW_ORG_ID} | jq -c '.[] | select(.type == 2) | [.name, (.notes|@base64)]'); do
    file=$(echo $row | jq -r '.[0]')
    dirname=$(dirname $file)
    basename=$(basename $file)

    mkdir -p ${SECRETS_DIR}/${dirname}
    rm -f ${SECRETS_DIR}/${dirname}/${basename}
    echo ${row} | jq -r '.[1] | @base64d' > "${SECRETS_DIR}/${dirname}/${basename}"
    chmod go-wrx "${SECRETS_DIR}/${dirname}/${basename}"
  done
}

bw.write_field()
{
  secret_name=${1}
  row_contents=${2}
  field_name=${3}
  suffix=${4}

  #log.blue "Parsing row ${row_contents}"
  field="$(echo ${row_contents} | jq -r ${field_name})"
  if [ "${field}" != "null" ]; then
    #log.blue "Writing ${secret_name}_${suffix} with ${field}"
    echo "${secret_name}_${suffix}: '${field}'" >> ${TEMP_SECRETS_FILE}
  fi
}

bw.write_uris()
{
  secret_name=${1}
  row_contents=${2}

  if [ "$(echo ${row_contents} | jq -r '.login.uris | length')" -gt "0" ]; then
    i=1
    for uris in $(echo ${row_contents} | jq -c '.login.uris | .[] | @base64' ); do
      uri=$(echo ${uris} | jq -r '@base64d' |  jq -r '.uri')
      if [ "${uri}" != "null" ]; then
        #log.blue "Writing ${secret_name}_uri_${i} with ${uri}"
        echo "${secret_name}_uri_${i}: '${uri}'" >> ${TEMP_SECRETS_FILE}
        ((i=i+1))
      fi
    done
  fi
}

bw.write_custom_fields()
{
  secret_name=${1}
  row_contents=${2}

  if [ "$(echo ${row_contents} | jq -r '.fields | length')" -gt "0" ]; then
    for fields in $(echo ${row_contents} | jq -c '.fields | .[] | @base64'); do
      field_contents=$(echo ${fields} | jq -r '@base64d')
      field_name=$(echo ${field_contents} | jq -r '.name' | tr '?:&,%@-' ' ' | tr '[]{}#*!|> ' '_' | tr -s '_' | tr '[:upper:]' '[:lower:]')
      field_value=$(echo ${field_contents} | jq -r '.value')
      if [ "${field_name}" != "null" ] && [ "${field_value}" != "null" ]; then
        #log.blue "Writing ${secret_name}_${field_name} with ${field_value}"
        echo "${secret_name}_${field_name}: '${field_value}'" >> ${TEMP_SECRETS_FILE}
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

REPEAT_ENABLED="${REPEAT_ENABLED:-true}"
REPEAT_INTERVAL="${REPEAT_INTERVAL:-600}"
if [ "$REPEAT_ENABLED" = true ] ; then
  log.white "Repeat enabled with interval ${REPEAT_INTERVAL}."
else
  log.white "Repeat disabled."
fi

SECRETS_FILE="${SECRETS_FILE:-/output/secrets.yaml}"
log.yellow "Secrets will be saved to ${SECRETS_FILE}."
SECRETS_DIR=$(dirname "$SECRETS_FILE")
log.white "Ensuring directory $SECRETS_DIR exists."
mkdir -v -p $SECRETS_DIR

TEMP_SECRETS_FILE="/tmp/secrets.yaml"
TEMP_SECRETS_DIR=$(dirname "$TEMP_SECRETS_FILE")
log.white "Ensuring directory $TEMP_SECRETS_DIR exists."
mkdir -v -p $TEMP_SECRETS_DIR

#
# Start of main loop
#
log.white "Start retrieving your secrets from bitwarden ..."
bw.login
bw.set_org_id

while true; do
  num_of_items=$(bw list items --organizationid ${BW_ORG_ID} | jq length)

  if [ ${num_of_items} -gt 0 ]; then
    log.white "Generating ${SECRETS_FILE} file from login entries ..."
    bw.generate_secrets
    log.white "Secrets file generated."

    log.white "Comparing newly generated secrets to ${SECRETS_FILE} ..."
    if cmp -s -- "${TEMP_SECRETS_FILE}" "${SECRETS_FILE}"; then
      rm -f ${TEMP_SECRETS_FILE}
      log.white "No secrets changes detected."
    else
      log.yellow "Changes from bitwarden detected, replacing ${SECRETS_FILE} ..."
      mv -f ${TEMP_SECRETS_FILE} ${SECRETS_FILE}
      chmod go-wrx ${SECRETS_FILE}
    fi

    log.white "Generating secret files from notes ..."
    bw.generate_secret_files
    log.white "Secrets files created."
  else
    log.red "No secrets found in your organisation!"
    log.red "--------------------------------------"
    log.red "Ensure that you have:"
    log.red "  - At least 1 secret in your organisation ${BW_ORGANIZATION}"
    log.red "  - Bitwarden is started when using the bitwarden-secrets docker container"
    log.red "--------------------------------------"
  fi

  if [ "${REPEAT_ENABLED}" != "true" ]; then
    break
  fi

  log.white "Wait ${REPEAT_INTERVAL} seconds ..."
  sleep "${REPEAT_INTERVAL}"
  bw.login_check

  log.white "Syncing bitwarden vault..."
  bw sync &>/dev/null
  log.white "Bitwarden vault synced at: $(bw sync --last)"
done

bw.logout
exit 0
