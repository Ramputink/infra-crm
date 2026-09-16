-- ============================================================================
-- 002 · Segmentación de leads
-- ============================================================================
--
-- Clasifica cada lead en un embudo y deduce su idioma de comunicación.
--
-- POR QUÉ COMO FUNCIONES SQL Y NO COMO CÓDIGO EN EL WORKFLOW
-- ----------------------------------------------------------
-- La misma lógica ya existe en `Automatismos/Mailing/segmentacion.py`. Copiarla
-- a un nodo Code de n8n habría creado una segunda versión que se desincroniza
-- en cuanto alguien toque una: un lead clasificado de una forma por el script
-- de Python y de otra por el workflow es un fallo silencioso y muy caro de ver.
--
-- Aquí vive la versión canónica del lado de la base. El workflow WF-04 solo la
-- llama. Las listas de países están copiadas literalmente de segmentacion.py.
--
-- IDEMPOTENTE: se puede ejecutar varias veces sin romper nada.
--
--     psql -U <usuario> -d <base> -f migrations/002_segmentacion.sql
--
-- ============================================================================

BEGIN;

-- --- Columnas nuevas --------------------------------------------------------

ALTER TABLE leads ADD COLUMN IF NOT EXISTS embudo TEXT;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS idioma_comunicacion TEXT;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS segmentado_at TIMESTAMPTZ;

COMMENT ON COLUMN leads.embudo IS
  'nl = solo newsletter (nacido en España) · h500 = homologación 500 € · '
  'c100 = consulta 100 € · qual = cola de cualificación, falta el tipo de producto';
COMMENT ON COLUMN leads.idioma_comunicacion IS
  'Idioma deducido para las plantillas: Español, Inglés, Ruso, Italiano o Francés';

-- Un embudo fuera de la lista es un error de programación, no un dato.
ALTER TABLE leads DROP CONSTRAINT IF EXISTS leads_embudo_valido;
ALTER TABLE leads ADD CONSTRAINT leads_embudo_valido
  CHECK (embudo IS NULL OR embudo IN ('nl','h500','c100','qual'));

-- WF-04 busca siempre por "sin segmentar".
CREATE INDEX IF NOT EXISTS leads_sin_segmentar_idx
  ON leads (segmentado_at) WHERE segmentado_at IS NULL;

-- --- Normalización ----------------------------------------------------------
-- Equivalente de `sin_acentos()`: mayúsculas sin diacríticos, tolerante a NULL
-- y a los 'nan' / 'none' que deja pandas al exportar.

CREATE OR REPLACE FUNCTION sfe_sin_acentos(valor TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN valor IS NULL THEN ''
    WHEN lower(btrim(valor)) IN ('nan','none','nat','null') THEN ''
    ELSE upper(btrim(translate(
      valor,
      'áàäâãéèëêíìïîóòöôõúùüûñçÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇ',
      'aaaaaeeeeiiiiooooouuuuncAAAAAEEEEIIIIOOOOOUUUUNC'
    )))
  END;
$$;

-- --- ¿Nacido en España? -----------------------------------------------------
-- Estos leads NO entran en la secuencia comercial: ya tienen el título español
-- y no hay nada que homologar. Solo newsletter.

CREATE OR REPLACE FUNCTION sfe_nacido_en_espana(pais TEXT)
RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT sfe_sin_acentos(pais) = ANY (ARRAY[
    'ES','ESP','ESPAGNE','ESPANA','ESPANNA','ISPANIYA',
    'SPAGNA','SPAIN','SPANIEN','ИСПАНИЯ'
  ]);
$$;

-- --- Embudo -----------------------------------------------------------------

CREATE OR REPLACE FUNCTION sfe_clasificar_embudo(tipo_producto TEXT, pais TEXT)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
  tp TEXT;
BEGIN
  -- El país manda sobre el producto: nacer en España descarta la homologación
  -- sea cual sea el programa contratado.
  IF sfe_nacido_en_espana(pais) THEN
    RETURN 'nl';
  END IF;

  tp := sfe_sin_acentos(tipo_producto);

  -- Sin tipo de producto no se puede decidir. A la cola de cualificación, no
  -- al descarte: en los ficheros reales son 67 leads, y tirarlos por un campo
  -- vacío del export sería tirar dinero.
  IF tp = '' THEN
    RETURN 'qual';
  END IF;

  IF tp IN ('GRADO','CFGS') THEN
    RETURN 'h500';
  END IF;

  IF tp = 'POSTGRADO' OR tp LIKE '%MASTER%' THEN
    RETURN 'c100';
  END IF;

  RETURN 'qual';
END;
$$;

-- --- Idioma -----------------------------------------------------------------

CREATE OR REPLACE FUNCTION sfe_inferir_idioma(idioma_declarado TEXT, pais TEXT)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
  decl TEXT;
  p    TEXT;
BEGIN
  -- 1) Lo declarado, si se reconoce.
  decl := sfe_sin_acentos(idioma_declarado);
  CASE
    WHEN decl IN ('ES','ESPANOL','SPANISH','CASTELLANO')      THEN RETURN 'Español';
    WHEN decl IN ('EN','INGLES','ENGLISH')                    THEN RETURN 'Inglés';
    WHEN decl IN ('RU','RUSO','RUSSIAN','РУССКИЙ')            THEN RETURN 'Ruso';
    WHEN decl IN ('IT','ITALIANO','ITALIAN')                  THEN RETURN 'Italiano';
    WHEN decl IN ('FR','FRANCES','FRANCAIS','FRENCH')         THEN RETURN 'Francés';
    ELSE NULL;
  END CASE;

  -- 2) El idioma típico del país de nacimiento.
  p := sfe_sin_acentos(pais);
  CASE
    WHEN p IN ('RUSIA','RUSSIA','UCRANIA','UKRAINE','BIELORRUSIA','KAZAJISTAN',
               'KAZAKHSTAN','UZBEKISTAN','KIRGUISTAN','TAYIKISTAN','TURKMENISTAN',
               'ARMENIA','AZERBAIYAN','GEORGIA','MOLDAVIA','LETONIA','LITUANIA',
               'ESTONIA')                                     THEN RETURN 'Ruso';
    WHEN p IN ('ITALIA','ITALY')                              THEN RETURN 'Italiano';
    WHEN p IN ('FRANCIA','FRANCE','BELGICA','MARRUECOS','ARGELIA','SENEGAL',
               'CAMERUN','COSTA DE MARFIL')                   THEN RETURN 'Francés';
    -- Brasil y Portugal a español: se entienden, y no hay plantilla en portugués.
    WHEN p IN ('BRASIL','BRAZIL','PORTUGAL')                  THEN RETURN 'Español';
    ELSE NULL;
  END CASE;

  -- 3) LatAm → español.
  IF p = ANY (ARRAY[
    'ARGENTINA','BOLIVIA','CHILE','COLOMBIA','COSTA RICA','CUBA','ECUADOR',
    'EL SALVADOR','ESPANA','GUATEMALA','HONDURAS','MEXICO','NICARAGUA','PANAMA',
    'PARAGUAY','PERU','PUERTO RICO','REPUBLICA DOMINICANA','URUGUAY','VENEZUELA'
  ]) THEN
    RETURN 'Español';
  END IF;

  -- 4) Inglés como último recurso: nunca se deja un lead sin plantilla.
  RETURN 'Inglés';
END;
$$;

-- --- Autocomprobación --------------------------------------------------------
--
-- `upper()` depende de la configuración regional de la base. En una base
-- creada con `--locale=C` o POSIX, upper() NO toca el cirílico: 'Испания' no
-- se convierte en 'ИСПАНИЯ', el alias no casa, y un lead nacido en España que
-- declara el país en ruso entraría en el embudo comercial en vez de quedarse
-- solo en la newsletter. Es decir: se le vendería una homologación que no
-- necesita.
--
-- Detectado al probar esta migración contra una base con locale C. Falla en
-- voz alta aquí antes que en silencio con leads reales.

DO $$
DECLARE
  locale_actual TEXT;
BEGIN
  -- `current_setting('lc_collate')` ya no existe como parametro en PostgreSQL
  -- 17; la collation de la base se consulta en pg_database.
  SELECT datcollate INTO locale_actual
  FROM pg_database WHERE datname = current_database();

  IF sfe_sin_acentos('Испания') <> 'ИСПАНИЯ' THEN
    RAISE EXCEPTION
      'Esta base no pone en mayusculas el cirilico (collation actual: %). '
      'Los alias en ruso no funcionarian y los leads rusos nacidos en Espana '
      'entrarian en el embudo comercial en vez de quedarse en la newsletter. '
      'Recrea la base con una locale UTF-8.',
      COALESCE(locale_actual, 'desconocida');
  END IF;

  IF sfe_sin_acentos('España') <> 'ESPANA' THEN
    RAISE EXCEPTION 'La eliminacion de diacriticos no funciona en esta base.';
  END IF;

  -- Los cuatro embudos, con un caso representativo de cada uno.
  IF sfe_clasificar_embudo('GRADO', 'España')     <> 'nl'   THEN RAISE EXCEPTION 'embudo nl'; END IF;
  IF sfe_clasificar_embudo('GRADO', 'Colombia')   <> 'h500' THEN RAISE EXCEPTION 'embudo h500'; END IF;
  IF sfe_clasificar_embudo('POSTGRADO','Perú')    <> 'c100' THEN RAISE EXCEPTION 'embudo c100'; END IF;
  IF sfe_clasificar_embudo(NULL, 'Colombia')      <> 'qual' THEN RAISE EXCEPTION 'embudo qual'; END IF;

  RAISE NOTICE 'Segmentacion: autocomprobacion superada.';
END;
$$;

COMMIT;
