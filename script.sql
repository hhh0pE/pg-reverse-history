CREATE OR REPLACE FUNCTION jsonb_minus ( arg1 jsonb, arg2 jsonb )
RETURNS jsonb
AS $$

  SELECT
    COALESCE(
      json_object_agg(
        key,
        CASE
          -- if the value is an object and the value of the second argument is
          -- not null, we do a recursion
          WHEN jsonb_typeof(value) = 'object' AND arg2 -> key IS NOT NULL
          THEN jsonb_minus(value, arg2 -> key)
          -- for all the other types, we just return the value
          ELSE value
        END
      ),
    '{}'
    )::jsonb
  FROM
    jsonb_each(arg1)
  WHERE
    arg1 -> key <> arg2 -> key
    OR arg2 -> key IS NULL

$$ LANGUAGE SQL;


DROP OPERATOR IF EXISTS - (jsonb, jsonb);
CREATE OPERATOR - (
  LEFTARG = jsonb,
  RIGHTARG = jsonb,
  PROCEDURE = jsonb_minus
);


CREATE SCHEMA IF NOT EXISTS history;
REVOKE ALL ON SCHEMA history FROM public;


CREATE OR REPLACE FUNCTION history.track_reverse() RETURNS TRIGGER
AS $body$
BEGIN
  IF TG_OP = 'INSERT' THEN
    EXECUTE format('INSERT INTO history.%s (row_fk, reverse_diffs) VALUES (%L, null);', tg_table_name::text, NEW.id);
  ELSEIF TG_OP = 'UPDATE' THEN
    EXECUTE format('INSERT INTO history.%s (row_fk, reverse_diffs) VALUES (%L, %L);', tg_table_name::text, NEW.id, to_jsonb(OLD) - to_jsonb(NEW));
  ELSEIF TG_OP = 'DELETE' THEN
    EXECUTE format('INSERT INTO history.%s (row_fk, reverse_diffs) VALUES (%L, %L);', tg_table_name::text, OLD.id, to_jsonb(OLD));
  END IF;
  RETURN NULL;
END;
$body$
language 'plpgsql';

CREATE OR REPLACE FUNCTION history.track_table_reverse(
  target_table regclass
)
RETURNS void AS $body$
BEGIN
    EXECUTE 'DROP TRIGGER IF EXISTS history_trigger ON ' || target_table::TEXT;

    EXECUTE 'CREATE TABLE IF NOT EXISTS history.' || target_table::TEXT ||'(' ||
      'id SERIAL NOT NULL PRIMARY KEY,
      row_fk bigint not null,
      reverse_diffs JSONB,
      update_time TIMESTAMP WITH TIME ZONE) DEFAULT NOW()';

    EXECUTE 'CREATE TRIGGER history_trigger AFTER INSERT OR UPDATE OR DELETE ON '||
            target_table::TEXT||' FOR EACH ROW EXECUTE PROCEDURE history.track_reverse();';

END;
$body$
language 'plpgsql';