# Sourced by the other scripts. Resolves URL / token without ever printing the token.
export AWS_REGION="${AWS_REGION:-ap-southeast-2}"
NAME_PREFIX="${NAME_PREFIX:-pf-hello-devops}"

# Needs only the AWS CLI (no terraform): the ALB and target group are found by name.
if [[ -z "${URL:-}" ]]; then
  DNS="$(aws elbv2 describe-load-balancers --names "${NAME_PREFIX}-alb" \
    --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || true)"
  [[ -n "$DNS" && "$DNS" != None ]] && URL="http://$DNS"
fi
if [[ -z "${URL:-}" ]]; then
  echo "No URL: stack not deployed, or set URL=http://<alb-dns>." >&2
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
