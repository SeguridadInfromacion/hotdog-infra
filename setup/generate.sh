#!/bin/sh
# Genera todo lo secreto del sistema: llaves JWT, certificado TLS y contraseñas.
# Nada de esto se sube al repositorio (ver .gitignore).
# Es idempotente: no sobrescribe lo que ya existe.
set -eu

cd /work
mkdir -p secrets

random_hex() { openssl rand -hex "$1"; }

# Cada par se genera completo: si falta una de las dos mitades, se rehace.
if [ ! -f secrets/jwt_private.pem ] || [ ! -f secrets/jwt_public.pem ]; then
    echo "-> Generando par de llaves RSA para firmar los JWT"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
        -out secrets/jwt_private.pem 2>/dev/null
    openssl pkey -in secrets/jwt_private.pem -pubout -out secrets/jwt_public.pem
fi

if [ ! -f secrets/tls_cert.pem ] || [ ! -f secrets/tls_key.pem ]; then
    echo "-> Generando certificado TLS autofirmado para localhost"
    openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -keyout secrets/tls_key.pem -out secrets/tls_cert.pem \
        -subj "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "extendedKeyUsage=serverAuth" 2>/dev/null
fi

# Cada llave privada solo la lee el usuario sin privilegios del contenedor que la usa.
# (En Windows los permisos del montaje los maneja Docker Desktop y esto no aplica.)
chmod 644 secrets/jwt_public.pem secrets/tls_cert.pem
chown 10001 secrets/jwt_private.pem 2>/dev/null && chmod 400 secrets/jwt_private.pem || true
chown 101 secrets/tls_key.pem 2>/dev/null && chmod 400 secrets/tls_key.pem || true

if [ ! -f .env ]; then
    echo "-> Generando .env con contraseñas aleatorias"
    cat > .env <<EOF
# Generado por setup/generate.sh. NO subir a git.
BIND_ADDRESS=127.0.0.1
HTTPS_PORT=8443
HTTP_PORT=8080
# Nombres con los que se puede abrir el sitio; cualquier otro se rechaza.
SERVER_NAME="localhost 127.0.0.1"

AUTH_DB_ROOT_PASSWORD=$(random_hex 24)
AUTH_DB_PASSWORD=$(random_hex 24)
PRODUCTS_DB_ROOT_PASSWORD=$(random_hex 24)
PRODUCTS_DB_PASSWORD=$(random_hex 24)
ORDERS_DB_ROOT_PASSWORD=$(random_hex 24)
ORDERS_DB_PASSWORD=$(random_hex 24)

# Usuarios iniciales (se crean solo si la base de usuarios está vacía).
ADMIN_USERNAME=admin
ADMIN_PASSWORD=Perro-$(random_hex 6)
DEMO_CASHIER_USERNAME=cajero
DEMO_CASHIER_PASSWORD=Salsa-$(random_hex 6)
EOF
fi

echo "Listo. Las credenciales iniciales están en el archivo .env"
