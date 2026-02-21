# Worker Architecture — Workflow 1 (Importar Excel)

## Overview

Workflow 1 "Importar Excel" implementa un pipeline completo de ingestión, normalización, persistencia y encolado de leads a partir de archivos Excel subidos mediante formulario.

Este workflow cumple el patrón:

Event-Driven ETL + Async Worker Dispatch

Responsabilidad principal:
- Recibir Excel
- Detectar duplicados
- Registrar batch
- Normalizar y validar datos
- Upsert en CRM
- Registrar auditoría por fila
- Calcular métricas del lote
- Encolar leads para envío de emails
- Disparar worker asíncrono

---

## Flujo General

Form Trigger
→ SHA256
→ Verificar duplicado
→ Registrar batch
→ Parsear Excel
→ Normalizar datos
→ Validar registros
→ Limpiar emails vacíos
→ Upsert leads
→ Log import_rows
→ Actualizar métricas batch
→ Encolar leads (email_status = queued)
→ Execute Workflow (ColdEmailSender)
→ Form Completion

---

## 1. Entrada

Nodo: On form submission

Recibe:
- excel_file (binario)
- batch_description

Response mode: lastNode

Actúa como entrypoint HTTP del sistema.

---

## 2. Control de Duplicados

Se calcula SHA256 del archivo.

Se ejecuta:

SELECT EXISTS (
  SELECT 1
  FROM import_batches
  WHERE file_hash = $1
) AS is_duplicate;

Si es duplicado:
→ Se detiene el flujo
→ Se muestra mensaje al usuario

---

## 3. Registro del Batch

Inserta en import_batches:

- filename
- file_hash
- status = 'processing'
- imported_by

Devuelve batch_id.

Esto garantiza:
- Idempotencia
- Trazabilidad
- Control de estado

---

## 4. Parsing y Normalización

Se convierte Excel → JSON.

Transformaciones aplicadas:

- Separación inteligente nombre/apellidos
- Validación de email por regex
- Limpieza y normalización de teléfono
- Detección categoría (grado / master / curso)
- Detección campus
- Conversión fecha Excel serial → ISO
- Inserción import_batch_id
- Preservación raw_data como JSONB

Resultado: Modelo CRM consistente independientemente del formato original.

---

## 5. Validación

Se añaden:

- validation_errors
- status: ok | error

Se eliminan registros sin email válido.

Esto previene contaminación del CRM.

---

## 6. Persistencia CRM

Tabla: leads

Operación: Upsert por email.

Campos actualizados:
- Datos personales
- Académicos
- Comerciales
- import_batch_id
- raw_data

Garantiza:
- Idempotencia
- Actualización automática de registros existentes

---

## 7. Logging de Auditoría

Tabla: import_rows

Se registra por cada fila:
- batch_id
- row_number
- raw_data
- lead_email
- status
- error_message

Permite:
- Auditoría completa
- Reprocesamiento futuro
- Debug detallado

---

## 8. Finalización del Batch

Se actualiza import_batches:

- status = completed
- row_count
- success_count
- error_count
- completed_at

Devuelve métricas finales.

---

## 9. Encolado para Worker

Se ejecuta:

UPDATE leads
SET email_status = 'queued'
WHERE import_batch_id = $1
  AND email_valid = true
  AND last_email_sent_at IS NULL
  AND email_status IN ('new','queued');

Esto desacopla ingestión de envío.

Workflow 1 nunca envía emails.
Solo encola trabajo.

---

## 10. Disparo del Worker

Execute Workflow → ColdEmailSender

Modo asíncrono.

El worker consume:

WHERE email_status = 'queued'

Arquitectura desacoplada y escalable.

---

## Estados de Sistema

import_batches.status:
- processing
- completed

import_rows.status:
- ok
- error

leads.email_status:
- new
- queued
- sending
- sent

---

## Garantías Arquitectónicas

Idempotencia:
- Hash SHA256
- Upsert por email
- No reprocesa archivos duplicados

Escalabilidad:
- Worker separado
- Sistema basado en cola

Observabilidad:
- Logging por fila
- Métricas por batch
- raw_data persistido

Seguridad:
- Validación estricta de email
- Filtro de datos inválidos
- No pérdida de información original

---

## Patrón Arquitectónico Implementado

Event-Driven Batch Processing
+ Async Queue Worker Pattern
+ ETL Normalization Layer
+ Idempotent CRM Upsert

---

Este workflow está preparado para producción y soporta múltiples cargas consecutivas sin colapsar el sistema de envío de emails.
