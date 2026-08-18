#!/usr/bin/env bash
# sso-sync: mirrors Keycloak realm group membership into local Nexus users.
# Runs as a CronJob (see templates/cronjob-sso-sync.yaml).
#
# Model: the rutauth capability authenticates Nexus by userId only (the
# Gap-Auth header emitted by oauth2-proxy carries the Keycloak user email).
# Authorisation comes from LOCAL Nexus roles, so this script keeps local users
# and their roles aligned with group membership. It never touches passwords:
# machine accounts are created by the config Job with Vault-backed passwords,
# human accounts get a random unusable local password (SSO login only).
set -euo pipefail

NEXUS_HOST="${NEXUS_HOST:-http://localhost:8081}"
NEXUS_USER="${NEXUS_USER:-admin}"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak-http.keycloak.svc.cluster.local:80}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-platform}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
GROUP_ROLES="${GROUP_ROLES:-}"
PROTECTED_USERS="${PROTECTED_USERS:-admin,anonymous}"

log() { echo "[sso-sync] $*"; }
die() { log "FATAL: $*"; exit 1; }

[[ -n "${NEXUS_PASSWORD:-}" ]] || die "NEXUS_PASSWORD not set"
[[ -n "${KEYCLOAK_ADMIN_PASSWORD:-}" ]] || die "KEYCLOAK_ADMIN_PASSWORD not set"
[[ -n "${GROUP_ROLES}" ]] || die "GROUP_ROLES not set (expected 'group1:role1;group2:role2')"

NEXUS_REST="${NEXUS_HOST}/service/rest/v1"

# --- wait for Nexus -------------------------------------------------------
log "waiting for Nexus at ${NEXUS_HOST}"
code="000"
for _ in $(seq 1 40); do
  code="$(curl -s -o /dev/null -w "%{http_code}" "${NEXUS_HOST}/service/rest/v1/status" || true)"
  [[ "${code}" == "200" ]] && break
  sleep 15
done
[[ "${code}" == "200" ]] || die "Nexus not reachable at ${NEXUS_HOST}"

# --- Keycloak admin token (password grant on master realm) ----------------
code="000"
for _ in $(seq 1 10); do
  code="$(curl -sS --max-time 15 -o /tmp/kc-token.json -w "%{http_code}" \
    -d "grant_type=password&client_id=admin-cli&username=${KEYCLOAK_ADMIN_USER}&password=${KEYCLOAK_ADMIN_PASSWORD}" \
    "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" 2>/dev/null || true)"
  [[ "${code}" == "200" ]] && break
  log "Keycloak auth failed (http ${code}), retrying in 30s"
  sleep 30
done
[[ "${code}" == "200" ]] || die "cannot authenticate to Keycloak at ${KEYCLOAK_URL}"
KC_TOKEN="$(jq -r '.access_token // empty' /tmp/kc-token.json)"
rm -f /tmp/kc-token.json
[[ -n "${KC_TOKEN}" ]] || die "no access_token in Keycloak response"
log "Keycloak admin token acquired"

kc() { curl -sS --max-time 30 -H "Authorization: Bearer ${KC_TOKEN}" "$@"; }
nexus() { curl -sS --max-time 30 -u "${NEXUS_USER}:${NEXUS_PASSWORD}" "$@"; }

# --- collect group membership ---------------------------------------------
groups_json="$(kc "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/groups")" \
  || die "cannot list groups of realm '${KEYCLOAK_REALM}'"

declare -A MEMBER_ROLES=()
declare -A MEMBER_NAMES=()
scanned=0

while IFS= read -r entry; do
  [[ -z "${entry}" ]] && continue
  group_name="${entry%%:*}"
  role_name="${entry#*:}"
  gid="$(jq -r --arg n "${group_name}" '.[] | select(.name == $n) | .id' <<<"${groups_json}" | head -n1)"
  if [[ -z "${gid:-}" || "${gid}" == "null" ]]; then
    log "WARNING: group '${group_name}' not found in realm '${KEYCLOAK_REALM}' - role '${role_name}' not applied"
    continue
  fi
  members_json="$(kc "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/groups/${gid}/members?max=500")" \
    || die "cannot list members of group '${group_name}'"
  while IFS= read -r member; do
    scanned=$((scanned + 1))
    email="$(jq -r '.email // empty' <<<"${member}")"
    enabled="$(jq -r '.enabled // false' <<<"${member}")"
    username="$(jq -r '.username // empty' <<<"${member}")"
    if [[ -z "${email}" ]]; then
      log "WARNING: user '${username:-?}' in group '${group_name}' has no email address - skipped"
      continue
    fi
    if [[ "${enabled}" != "true" ]]; then
      log "user '${email}' is disabled in Keycloak - skipped"
      continue
    fi
    name="$(jq -r '[(.firstName // ""), (.lastName // "")] | join(" ") | gsub(" +"; " ") | gsub("^ | $"; "")' <<<"${member}")"
    MEMBER_NAMES["${email}"]="${name:-${email%%@*}}"
    current="${MEMBER_ROLES[${email}]:-}"
    case " ${current} " in
      *" ${role_name} "*) ;;
      *) MEMBER_ROLES["${email}"]="${current:+${current} }${role_name}" ;;
    esac
  done < <(jq -c '.[]' <<<"${members_json}")
  log "group '${group_name}' -> role '${role_name}' processed"
done

# --- existing local users ---------------------------------------------------
declare -A NEXUS_USERS=()
page=0
while :; do
  users_json="$(nexus "${NEXUS_REST}/security/users?pageSize=1000&startIndex=${page}")" \
    || die "cannot list local Nexus users"
  count="$(jq 'length' <<<"${users_json}")"
  [[ "${count}" -gt 0 ]] || break
  while IFS= read -r uid; do
    NEXUS_USERS["${uid}"]=1
  done < <(jq -r '.[].userId' <<<"${users_json}")
  [[ "${count}" -lt 1000 ]] && break
  page=$((page + 1000))
done
log "local users: ${#NEXUS_USERS[@]}; mapped group members: ${#MEMBER_ROLES[@]} (scanned ${scanned})"

# --- upsert mapped members ---------------------------------------------------
created=0
updated=0
for email in "${!MEMBER_ROLES[@]}"; do
  roles_json="$(tr ' ' '\n' <<<"${MEMBER_ROLES[${email}]}" | jq -R . | jq -c 'sort')"
  name="${MEMBER_NAMES[${email}]}"
  first="${name%% *}"
  last="${name#* }"
  [[ "${last}" == "${name}" ]] && last=""
  payload="$(jq -c -n \
    --arg userId "${email}" \
    --arg firstName "${first}" \
    --arg lastName "${last}" \
    --arg email "${email}" \
    --argjson roles "${roles_json}" \
    '{userId:$userId,firstName:$firstName,lastName:$lastName,emailAddress:$email,source:"default",status:"active",roles:$roles,externalRoles:[]}')"
  enc_email="$(jq -rn --arg s "${email}" '$s | @uri')"
  if [[ -n "${NEXUS_USERS[${email}]:-}" ]]; then
    code="$(curl -sS --max-time 30 -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' \
      -u "${NEXUS_USER}:${NEXUS_PASSWORD}" -d "${payload}" "${NEXUS_REST}/security/users/${enc_email}")"
    [[ "${code}" == "204" ]] || die "cannot update user '${email}' (http ${code})"
    updated=$((updated + 1))
    log "updated '${email}' roles=${roles_json}"
  else
    password="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    create_payload="$(jq -c --arg password "${password}" '. + {password:$password,setEmailVerified:true}' <<<"${payload}")"
    code="$(curl -sS --max-time 30 -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' \
      -u "${NEXUS_USER}:${NEXUS_PASSWORD}" -d "${create_payload}" "${NEXUS_REST}/security/users")"
    [[ "${code}" == "200" ]] || die "cannot create user '${email}' (http ${code})"
    created=$((created + 1))
    log "created '${email}' roles=${roles_json} (random local password - SSO login only)"
  fi
done

# --- prune stale local users --------------------------------------------------
# A local user is pruned when it is neither a mapped group member nor protected.
# Protected users keep their account and their last assigned roles.
pruned=0
skipped=0
protected_list="$(tr ',' ' ' <<<"${PROTECTED_USERS}")"
for uid in "${!NEXUS_USERS[@]}"; do
  [[ -n "${MEMBER_ROLES[${uid}]:-}" ]] && continue
  is_protected=0
  for p in ${protected_list}; do
    if [[ "${uid}" == "${p}" ]]; then
      is_protected=1
      break
    fi
  done
  if [[ "${is_protected}" -eq 1 ]]; then
    skipped=$((skipped + 1))
    continue
  fi
  enc_uid="$(jq -rn --arg s "${uid}" '$s | @uri')"
  code="$(curl -sS --max-time 30 -o /dev/null -w "%{http_code}" -X DELETE \
    -u "${NEXUS_USER}:${NEXUS_PASSWORD}" "${NEXUS_REST}/security/users/${enc_uid}")"
  if [[ "${code}" == "200" || "${code}" == "204" ]]; then
    pruned=$((pruned + 1))
    log "pruned '${uid}' (no longer in any mapped Keycloak group)"
  else
    log "WARNING: could not prune '${uid}' (http ${code})"
  fi
done

log "sso-sync complete: scanned=${scanned} created=${created} updated=${updated} pruned=${pruned} protected-skipped=${skipped}"
