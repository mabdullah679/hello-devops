# Sourced by the other scripts. Resolves URL / token without ever printing the token.
export AWS_REGION="${AWS_REGION:-ap-southeast-2}"
NAME_PREFIX="${NAME_PREFIX:-pf-hello-devops}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${URL:-}" ]]; then
  URL="$(terraform -chdir="$ROOT/infra" output -raw url 2>/dev/null || true)"
fi
if [[ -z "$URL" ]]; then
  echo "No URL: set URL=http://<alb-dns> or run from a checkout whose infra/ has state access." >&2
  exit 1
fi

admin_token() {
  aws ssm get-parameter --name "/${NAME_PREFIX}/admin-token" --with-decryption \
    --query Parameter.Value --output text
}

# set_chaos break|recover
set_chaos() {
  local code
  code="$(curl -s -o /tmp/chaos.out -w '%{http_code}' -X POST "$URL/admin/chaos" \
    -H "Authorization: Bearer $(admin_token)" -H 'Content-Type: application/json' \
    -d "{\"state\":\"$1\"}")"
  echo "POST /admin/chaos {state:$1} -> HTTP $code $(cat /tmp/chaos.out)"
  rm -f /tmp/chaos.out
  [[ "$code" == 200 ]]
}

probe() {
  echo "URL: $URL"
  for p in /healthz /readyz; do
    echo "GET $p -> HTTP $(curl -s -o /dev/null -w '%{http_code}' -m 5 "$URL$p")"
  done
}
