# hotdog-infra

Infraestructura de **PerroCaliente Express**: orquesta los 8 contenedores del
sistema, configura el gateway nginx y genera los secretos.

Documentación general: [hotdog-docs](https://github.com/SeguridadInfromacion/hotdog-docs).

## Ponerlo a andar

Requisito único: [Docker](https://www.docker.com/products/docker-desktop/).

**1. Clona todos los repositorios en una misma carpeta**

```bash
mkdir hotdog-system && cd hotdog-system
for repo in infra database auth-service products-service orders-service frontend docs; do
  git clone https://github.com/SeguridadInfromacion/hotdog-$repo.git
done
cd hotdog-infra
```

**2. Genera llaves, certificado y contraseñas** (una sola vez)

```bash
docker compose -f docker-compose.setup.yml run --rm setup
```

Crea `secrets/` y `.env` con valores aleatorios. Ninguno se sube a git.

**3. Levanta el sistema**

```bash
docker compose up -d --build
```

**4. Abre** <https://localhost:8443>

El certificado es autofirmado: el navegador mostrará una advertencia que hay que
aceptar. Los usuarios iniciales (`admin` y `cajero`) y sus contraseñas están en `.env`.

Si el puerto 8443 u 8080 está ocupado, cambia `HTTPS_PORT` o `HTTP_PORT` en `.env`.

En Docker Desktop (Windows y macOS) el gateway no ve la IP real de cada cliente,
sino la de la red virtual de Docker: el límite de peticiones y la IP de la
auditoría son compartidos por todos. En un servidor Linux se ve la IP real.

## Verificar la seguridad en vivo

```bash
bash scripts/security-checks.sh
```

Lanza 61 ataques y verificaciones contra el sistema en ejecución: tokens
falsificados, inyección SQL, escalamiento de rol, fuerza bruta, aislamiento de
red, privilegios de la base y más.

## Qué hay aquí

| Ruta | Para qué |
|---|---|
| `docker-compose.yml` | Los 8 contenedores, 9 redes, endurecimiento y secretos |
| `docker-compose.setup.yml` + `setup/` | Generador de llaves JWT, certificado TLS y contraseñas |
| `gateway/templates/default.conf.template` | nginx: HTTPS, cabeceras, límites y enrutamiento |
| `scripts/security-checks.sh` | Pruebas de seguridad en vivo |
| `.env.example` | Variables que usa el sistema |

## Decisiones de seguridad

- **Una sola puerta.** Solo el gateway publica puertos, y por defecto solo en `127.0.0.1`.
- **Una red por pareja.** Dos contenedores comparten red solo si necesitan hablarse (gateway con cada servicio, cada servicio con su base, ventas con productos). Todas son internas menos la del gateway. Las redes del gateway usan las subredes fijas `172.30.1.0/29` a `172.30.3.0/29`; si chocan con otra red de tu máquina, cámbialas en `docker-compose.yml` junto con `FORWARDED_ALLOW_IPS`.
- **Solo se abre con el nombre esperado.** El gateway atiende `localhost` y `127.0.0.1` (variable `SERVER_NAME`); con otra cabecera `Host` corta la conexión. Para abrirlo desde otra máquina hay que agregar su nombre o IP a `SERVER_NAME`, poner `BIND_ADDRESS=0.0.0.0` y generar un certificado para ese nombre.
- **Contenedores endurecidos.** Sin root, disco de solo lectura, sin capacidades de Linux, sin escalamiento de privilegios, con límites de memoria y procesos.
- **Llaves asimétricas.** Solo `auth-service` monta la llave privada; los demás reciben únicamente la pública.
- **Sin secretos en git.** Se generan al azar en cada instalación.

## Comandos útiles

```bash
docker compose ps                      # estado de los contenedores
docker compose logs -f auth-service    # logs de un servicio
docker compose down                    # apagar (conserva los datos)
docker compose down -v                 # apagar y borrar las bases
```
