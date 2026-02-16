# 🚀 Infraestructura Automatización CRM — n8n + PostgreSQL + Docker + VPS

## 📌 Descripción General

Esta infraestructura implementa un entorno de producción para automatización de CRM orientado a:

- ingestión de leads desde Excel
- normalización de datos
- segmentación automática de alumnos
- almacenamiento centralizado
- generación de comunicaciones automatizadas
- email marketing
- workflows con n8n
- backups y recuperación completa del sistema

La arquitectura está diseñada para ser:

- reproducible
- portable
- segura
- versionada
- restaurable en minutos
- escalable

---

# 🏗️ Arquitectura del Sistema

## Stack principal

- **Servidor**: VPS Ubuntu 24.04 (Hostinger KVM)
- **Contenedores**: Docker + Docker Compose
- **Orquestación workflows**: n8n
- **Base de datos**: PostgreSQL
- **Reverse proxy + SSL**: Caddy
- **Firewall**: UFW
- **Backups**: cron + scripts bash
- **Versionado**: Git
- **Dominio**: n8n.spaceforedu.com

---

## Diagrama conceptual

Internet
↓
Caddy (HTTPS + SSL)
↓
n8n container
↓
PostgreSQL container
↓
Volúmenes persistentes


---

# 📁 Estructura de directorios del servidor

opt/
├── automatizacion_crm/
│ ├── compose/
│ │ ├── docker-compose.yml
│ │ └── Caddyfile
│ ├── volumes/
│ │ ├── postgres/
│ │ └── n8n/
│ └── secrets/
│ └── .env
│
├── backups/
│ ├── backup_postgres.sh
│ └── backup_full_system.sh
│
├── system_backups/
│ └── automatizacion_crm_YYYY-MM-DD.tar.gz


---

# 🔐 Seguridad implementada

## SSH Hardening

- usuario root deshabilitado
- login por password restringido
- acceso mediante usuario `deploy`
- autenticación por clave SSH

Configuración aplicada:

PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes

---

## Firewall UFW

Reglas activas:

22/tcp → SSH
80/tcp → HTTP
443/tcp → HTTPS


Política por defecto:

deny incoming
allow outgoing

---

## SSL automático

- Caddy genera certificados automáticamente (Let's Encrypt)
- renovación automática
- redirección HTTP → HTTPS

---

# 🐳 Docker Stack

## Servicios desplegados

### PostgreSQL
- almacenamiento persistente
- base de datos de n8n
- volumen Docker

### n8n
- editor de workflows
- automatización procesos
- conexión a PostgreSQL
- accesible vía dominio público

### Caddy
- reverse proxy
- SSL automático
- gestión TLS

---

## Arrancar infraestructura

cd /opt/automatizacion_crm/compose
docker compose up -d

---

## Ver estado

docker compose ps

---

##Ver logs

docker compose logs -f


---

# 🧠 Variables de entorno (.env)

Archivo:

/opt/automatizacion_crm/secrets/.env

Contiene:

- credenciales PostgreSQL
- dominio
- claves internas n8n
- timezone
- encryption keys

⚠️ Nunca versionar este archivo.

---

# 💾 Sistema de Backups

Se implementan dos niveles de backup.

---

## 1️⃣ Backup de Base de Datos PostgreSQL

### Script


/opt/backups/backup_postgres.sh



### Función

- dump SQL de PostgreSQL
- backup diario automático
- ejecutado por cron

### Ejecución manual

/opt/backups/backup_postgres.sh


---

### Cron job

0 3 * * * /opt/backups/backup_postgres.sh >> /var/log/backup_postgres.log 2>&1


Ejecuta diariamente a las 03:00.

---

## 2️⃣ Backup Completo del Sistema

### Script

/opt/backups/backup_full_system.sh


### Qué respalda

- configuración docker
- volúmenes postgres
- datos n8n
- workflows
- scripts
- configuración sistema

### Funcionamiento

1. detiene contenedores
2. comprime `/opt/automatizacion_crm`
3. reinicia servicios
4. elimina backups con más de 90 días

---

### Cron job

30 3 * * * /opt/backups/backup_full_system.sh >> /var/log/backup_full.log 2>&1

---

## Política de retención

90 días(~3 meses)

---

# 🔄 Restauración del sistema

## Restaurar en nuevo VPS

Instalar Docker:

apt install docker-ce docker-compose-plugin -y

Extraer Backup:tar -xzf automatizacion_crm_YYYY-MM-DD.tar.gz -C /

Arrancar stack:

cd /opt/automatizacion_crm/compose
docker compose up -d

Sistema restaurado completamente.

---

# ⏱️ Cron Jobs activos

Ver:

crontab -l
Tareas activas:

- 03:00 → backup PostgreSQL
- 03:30 → backup completo sistema

---

# 🌐 Dominio y DNS

n8n.spaceforedu.com → IP VPS

SSL gestionado automáticamente por Caddy.

---

# 🧪 Verificación del sistema

## n8n accesible

https://n8n.spaceforedu.com

---

## PostgreSQL funcionando

docker ps

---

## SSL activo

https válido sin warnings del navegador

---

# 📦 Versionado de Infraestructura (Git)

Este repositorio contiene únicamente:

- docker-compose
- scripts
- documentación
- configuración

No incluye:

secrets/
volumes/
backups/
datos clientes

---

## Inicializar repo

git init
git add .
git commit -m "infraestructura inicial"


---

# 🧱 Principios de diseño

## Infraestructura como código
Servidor reproducible desde Git.

## Separación datos / configuración
- configuración versionada
- datos fuera del repo

## Recuperación rápida
Backup completo restaurable.

## Seguridad por defecto
Firewall + SSH hardened.

---

# 📊 Uso previsto (CRM Automation)

Este entorno soportará:

- ingestión automática Excel
- normalización headers variables
- limpieza datos leads
- segmentación alumnos
- base datos central
- generación borradores con IA
- automatización email marketing

---

# 🛣️ Roadmap del Proyecto

## Completado

- VPS producción
- Docker stack
- SSL automático
- seguridad SSH
- firewall
- PostgreSQL persistente
- backup DB
- backup sistema
- versionado infraestructura

---

## Pendiente

- pipeline ingestión Excel
- normalización automática headers
- base CRM unificada
- generación borradores con IA
- monitoring servidor
- backup remoto cloud

---

# 🛠️ Troubleshooting

## Ver contenedores

docker ps

##Reiniciar stack

docker compose restart

## Logs n8n

docker compose logs n8n

## Logs Caddy

docker compose logs caddy

---

# ⚠️ Buenas prácticas operativas

- probar backups regularmente
- verificar restauración periódica
- no versionar secrets
- monitorizar espacio disco
- actualizar sistema periódicamente

---

# 👤 Usuario del sistema

Usuario operativo:

deploy

Permisos:

- sudo
- docker
- gestión infraestructura

---

# 📜 Licencia

Uso interno empresarial.

---

# 🚀 Estado del Proyecto

Infraestructura lista para producción y expansión.

