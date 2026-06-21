-- Sanidade: confirma que transactions é hypertable, a dimensão temporal e o
-- número de chunks (esperado ~365 com chunk de 1 dia em 12 meses).
SELECT hypertable_name, num_dimensions
FROM timescaledb_information.hypertables
WHERE hypertable_name = 'transactions';

SELECT dimension_number, column_name, time_interval
FROM timescaledb_information.dimensions
WHERE hypertable_name = 'transactions';

SELECT count(*) AS chunks
FROM timescaledb_information.chunks
WHERE hypertable_name = 'transactions';
