#!/usr/bin/env bash
# Demostración en vivo: lanza ataques reales contra el sistema en ejecución
# y verifica que cada control de seguridad los detiene.
#
#   Uso (desde la carpeta hotdog-infra, con el sistema arriba):
#     bash scripts/security-checks.sh
#
# La prueba de fuerza bruta va al final: después de correrla hay que esperar
# cerca de un minuto para poder iniciar sesión otra vez desde esta máquina.
set -uo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
set -a; source .env; set +a

BASE="https://localhost:${HTTPS_PORT}"
CSRF=(-H "X-Requested-With: XMLHttpRequest")
JSON=(-H "Content-Type: application/json")
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0

check() { # check "descripción" "obtenido" "esperado"
    if [[ "$2" == "$3" ]]; then
        printf '  \033[32mOK\033[0m     %s\n' "$1"; passed=$((passed + 1))
    else
        printf '  \033[31mFALLA\033[0m  %s (se obtuvo «%s», se esperaba «%s»)\n' "$1" "$2" "$3"
        failed=$((failed + 1))
    fi
}

contains() { # contains "descripción" "texto" "fragmento"
    if grep -qi -- "$3" <<<"$2"; then check "$1" si si; else check "$1" "no aparece: $3" si; fi
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

status() { curl -sk -o /dev/null -w '%{http_code}' "$@"; }

login() { # login usuario contraseña archivo_de_cookies
    curl -sk -o /dev/null -w '%{http_code}' -c "$3" "${CSRF[@]}" "${JSON[@]}" \
        -d "{\"username\":\"$1\",\"password\":\"$2\"}" "$BASE/api/auth/login"
}

# ------------------------------------------------------------------------------
section "1. Transporte cifrado y cabeceras del gateway"
check "HTTP redirige a HTTPS" "$(status "http://localhost:${HTTP_PORT}/")" 301
headers="$(curl -skI "$BASE/")"
contains "HSTS activo" "$headers" "strict-transport-security"
contains "Content-Security-Policy sin 'unsafe-inline'" "$headers" "script-src 'self'; style-src 'self'"
contains "Anti-clickjacking (X-Frame-Options: DENY)" "$headers" "x-frame-options: DENY"
contains "X-Content-Type-Options: nosniff" "$headers" "nosniff"
if grep -qiE '^server: nginx/[0-9]' <<<"$headers"; then
    check "El servidor no revela su versión" "la revela" "oculta"
else
    check "El servidor no revela su versión" oculta oculta
fi

# ------------------------------------------------------------------------------
section "2. Sin sesión no hay datos"
for path in /api/products /api/orders /api/users /api/auth/me /api/auth/audit; do
    check "GET $path sin sesión -> 401" "$(status "$BASE$path")" 401
done

# ------------------------------------------------------------------------------
section "3. Inicio de sesión y cookie de sesión"
check "Login del administrador" "$(login "$ADMIN_USERNAME" "$ADMIN_PASSWORD" "$WORK/admin")" 200
check "Login del cajero" "$(login "$DEMO_CASHIER_USERNAME" "$DEMO_CASHIER_PASSWORD" "$WORK/cashier")" 200
cookie="$(curl -sk -D - -o /dev/null "${CSRF[@]}" "${JSON[@]}" \
    -d "{\"username\":\"$DEMO_CASHIER_USERNAME\",\"password\":\"$DEMO_CASHIER_PASSWORD\"}" \
    "$BASE/api/auth/login" | grep -i '^set-cookie')"
contains "Cookie HttpOnly (JavaScript no puede leerla)" "$cookie" "HttpOnly"
contains "Cookie Secure (solo viaja por HTTPS)" "$cookie" "Secure"
contains "Cookie SameSite=Strict (anti-CSRF)" "$cookie" "SameSite=strict"
body="$(curl -sk "${CSRF[@]}" "${JSON[@]}" -d '{"username":"admin'"'"' OR 1=1 --","password":"x"}' "$BASE/api/auth/login")"
contains "Inyección SQL en el login: solo credenciales inválidas" "$body" "incorrectos"

# ------------------------------------------------------------------------------
section "4. Control de acceso por rol (verificado en cada servicio)"
new_product='{"name":"Perro Pirata","description":"No deberia existir","price":100}'
check "Cajero NO puede crear productos -> 403" \
    "$(status -b "$WORK/cashier" "${CSRF[@]}" "${JSON[@]}" -d "$new_product" "$BASE/api/products")" 403
check "Cajero NO puede ver usuarios -> 403" "$(status -b "$WORK/cashier" "$BASE/api/users")" 403
check "Cajero NO puede ver la auditoría -> 403" "$(status -b "$WORK/cashier" "$BASE/api/orders/audit")" 403
check "Cajero SÍ puede ver el menú -> 200" "$(status -b "$WORK/cashier" "$BASE/api/products")" 200
check "Admin SÍ puede ver usuarios -> 200" "$(status -b "$WORK/admin" "$BASE/api/users")" 200

# ------------------------------------------------------------------------------
section "5. Tokens falsificados"
b64() { printf '%s' "$1" | base64 | tr -d '=\n' | tr '+/' '-_'; }
claims='{"sub":"00000000-0000-0000-0000-000000000001","username":"admin","role":"admin","iss":"hotdog-auth","aud":"hotdog-api","iat":1700000000,"exp":4102444800}'
unsigned="$(b64 '{"alg":"none","typ":"JWT"}').$(b64 "$claims")."
check "Token sin firma (alg: none) -> 401" \
    "$(status -H "Authorization: Bearer $unsigned" "$BASE/api/products")" 401
real="$(awk '$6 == "access_token" {print $7}' "$WORK/cashier")"
IFS=. read -r head _ sig <<<"$real"
check "Token de cajero alterado para decir admin -> 401" \
    "$(status -H "Authorization: Bearer $head.$(b64 "$claims").$sig" "$BASE/api/users")" 401

# ------------------------------------------------------------------------------
section "6. Validación de entradas y lógica de negocio"
check "Venta sin cabecera anti-CSRF -> 403" \
    "$(status -b "$WORK/cashier" "${JSON[@]}" -d '{"items":[]}' "$BASE/api/orders")" 403
check "Id malicioso en la URL -> 422" \
    "$(status -b "$WORK/cashier" "$BASE/api/products/1%20OR%201=1")" 422
product_id="$(curl -sk -b "$WORK/cashier" "$BASE/api/products?only_available=true" \
    | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)"
check "Cliente NO puede imponer el precio -> 422" \
    "$(status -b "$WORK/cashier" "${CSRF[@]}" "${JSON[@]}" \
        -d "{\"items\":[{\"product_id\":\"$product_id\",\"quantity\":1,\"unit_price\":1}]}" "$BASE/api/orders")" 422
check "Cantidad negativa -> 422" \
    "$(status -b "$WORK/cashier" "${CSRF[@]}" "${JSON[@]}" \
        -d "{\"items\":[{\"product_id\":\"$product_id\",\"quantity\":-5}]}" "$BASE/api/orders")" 422
check "Cuerpo gigante (200 KB) rechazado por el gateway -> 413" \
    "$(head -c 200000 /dev/zero | tr '\0' 'a' | status -b "$WORK/cashier" "${CSRF[@]}" "${JSON[@]}" \
        --data-binary @- "$BASE/api/orders")" 413

# ------------------------------------------------------------------------------
section "7. Superficie expuesta"
check "/health interno no se publica -> 404" "$(status "$BASE/api/health")" 404
check "/docs no se publica" "$(curl -sk "$BASE/docs" | grep -ci swagger)" 0
if curl -s -m 2 -o /dev/null http://localhost:8000/health; then exposed=si; else exposed=no; fi
check "Los servicios no publican puertos en la máquina" "$exposed" no
if curl -s -m 2 -o /dev/null telnet://localhost:5432 </dev/null; then exposed=si; else exposed=no; fi
check "Las bases de datos no publican puertos en la máquina" "$exposed" no

# ------------------------------------------------------------------------------
section "8. Contenedores endurecidos"
for service in auth-service products-service orders-service frontend gateway; do
    uid="$(docker compose exec -T "$service" id -u 2>/dev/null | tr -d '\r')"
    if [[ "$uid" != "0" && -n "$uid" ]]; then result="sin root"; else result="root"; fi
    check "$service corre sin root (uid $uid)" "$result" "sin root"
done
if docker compose exec -T products-service touch /app/intruso.txt 2>/dev/null; then fs=escribible; else fs="solo lectura"; fi
check "Sistema de archivos de solo lectura" "$fs" "solo lectura"
if docker compose exec -T orders-service test -e /run/secrets/jwt_private_key; then key=presente; else key=ausente; fi
check "orders-service NO tiene la llave privada de firma" "$key" ausente

# ------------------------------------------------------------------------------
section "9. Segmentación de red y mínimo privilegio en la base"
probe='import socket,sys
try:
    socket.create_connection((sys.argv[1], 5432), 2); print("alcanzable")
except OSError:
    print("inalcanzable")'
check "orders-service NO alcanza la base de productos" \
    "$(docker compose exec -T orders-service python -c "$probe" db-products | tr -d '\r')" inalcanzable
check "orders-service NO alcanza la base de usuarios" \
    "$(docker compose exec -T orders-service python -c "$probe" db-auth | tr -d '\r')" inalcanzable
check "orders-service SÍ alcanza su propia base" \
    "$(docker compose exec -T orders-service python -c "$probe" db-orders | tr -d '\r')" alcanzable
sql() { docker compose exec -T db-products psql -U products_app -d products -tAc "$1" 2>&1; }
contains "El rol de la app NO puede borrar tablas" "$(sql 'DROP TABLE products')" "must be owner"
contains "El rol de la app NO puede borrar la auditoría" "$(sql 'DELETE FROM audit_log')" "permission denied"
contains "El rol de la app NO puede alterar la auditoría" "$(sql "UPDATE audit_log SET actor = 'nadie'")" "permission denied"

# ------------------------------------------------------------------------------
section "10. Fuerza bruta contra el login (límite de peticiones)"
blocked=0
for _ in $(seq 1 25); do
    code="$(login "fantasma" "clave-incorrecta-1" /dev/null)"
    [[ "$code" == "429" ]] && blocked=$((blocked + 1))
done
if ((blocked > 0)); then result="frenado"; else result="sin freno"; fi
check "25 intentos seguidos: el gateway frenó $blocked con 429" "$result" "frenado"

printf '\n\033[1mResultado: %d controles verificados, %d fallas.\033[0m\n' "$passed" "$failed"
exit "$((failed > 0))"
