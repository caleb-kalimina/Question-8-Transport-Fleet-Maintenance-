-- ============================================================================
-- ICT371 Advanced Database
-- Question 8: Transport Fleet Maintenance (50 marks)
-- PostgreSQL Implementation
-- ============================================================================

BEGIN;

DROP VIEW IF EXISTS v_service_due CASCADE;
DROP TABLE IF EXISTS service_alerts CASCADE;
DROP TABLE IF EXISTS trips CASCADE;
DROP TABLE IF EXISTS vehicles CASCADE;

-- ----------------------------------------------------------------------------
-- (a) Database and seed data [6 marks]
-- ----------------------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(20) NOT NULL UNIQUE,
    current_odometer      NUMERIC(10, 1) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(10, 1) NOT NULL CHECK (
        last_service_odometer >= 0 AND last_service_odometer <= current_odometer
    )
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer NUMERIC(10, 1) NOT NULL CHECK (start_odometer >= 0),
    end_odometer   NUMERIC(10, 1) NOT NULL CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(10, 1) NOT NULL CHECK (km_since_service >= 5000),
    flagged_on       DATE NOT NULL
);

-- ----------------------------------------------------------------------------
-- (b) Function: fn_service_due(p_vehicle_id) [6 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr NUMERIC(10, 1);
    v_last NUMERIC(10, 1);
BEGIN
    SELECT current_odometer, last_service_odometer
      INTO v_curr, v_last
      FROM vehicles
     WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_curr - v_last) >= 5000;
END;
$$;

-- ----------------------------------------------------------------------------
-- (c) Procedure: pr_record_trip(p_vehicle_id, p_trip_on, p_start, p_end) [8 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on    DATE,
    p_start      NUMERIC(10, 1),
    p_end        NUMERIC(10, 1)
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_trip_on IS NULL THEN
        RAISE EXCEPTION 'Trip date (p_trip_on) cannot be NULL.';
    END IF;

    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'Invalid odometer range: end_odometer (%) must exceed start_odometer (%).',
            p_end, p_start;
    END IF;

    -- Insert trip only; trigger validates start_odometer and updates vehicle odometer
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- ----------------------------------------------------------------------------
-- (d) Trigger: BEFORE INSERT row trigger on trips [8 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_trips_odometer_sync()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_odo NUMERIC(10, 1);
BEGIN
    SELECT current_odometer INTO v_current_odo
      FROM vehicles
     WHERE vehicle_id = NEW.vehicle_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end_odometer (%) must be greater than start_odometer (%).',
            NEW.end_odometer, NEW.start_odometer;
    END IF;

    IF NEW.start_odometer <> v_current_odo THEN
        RAISE EXCEPTION 'Odometer continuity error: trip start (%) does not match vehicle current odometer (%).',
            NEW.start_odometer, v_current_odo;
    END IF;

    UPDATE vehicles
       SET current_odometer = NEW.end_odometer
     WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_odometer_sync
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trips_odometer_sync();

-- ----------------------------------------------------------------------------
-- (a cont.) Seed 3 vehicles and 6 trips via pr_record_trip
-- ----------------------------------------------------------------------------
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('BAA 4102 ZM', 14200.0, 10000.0), -- 4,200 km since service -> will cross 5,000
    ('BCB 8831 ZM', 25100.0, 24500.0), -- 600 km since service -> stays well under 5,000
    ('BAD 1190 ZM', 54800.0, 50000.0); -- 4,800 km since service -> will cross 5,000

CALL pr_record_trip(1, CURRENT_DATE - 4, 14200.0, 14750.0);
CALL pr_record_trip(1, CURRENT_DATE - 1, 14750.0, 15250.0); -- 5,250 km since service (DUE)
CALL pr_record_trip(2, CURRENT_DATE - 3, 25100.0, 25450.0);
CALL pr_record_trip(2, CURRENT_DATE,     25450.0, 25800.0); -- 1,300 km since service (NOT DUE)
CALL pr_record_trip(3, CURRENT_DATE - 2, 54800.0, 55000.0);
CALL pr_record_trip(3, CURRENT_DATE,     55000.0, 55320.0); -- 5,320 km since service (DUE)

-- ----------------------------------------------------------------------------
-- (e) View: v_service_due [5 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT
    vehicle_id,
    registration,
    (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE fn_service_due(vehicle_id) = TRUE
ORDER BY km_since_service DESC;

SELECT * FROM v_service_due;

-- ----------------------------------------------------------------------------
-- (f) Index & EXPLAIN [5 marks]
-- Justification: A composite B-tree index on (vehicle_id, trip_on) filters to
-- a single vehicle first and immediately performs an ordered range scan across
-- trip_on dates.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_trips_vehicle_trip_on
    ON trips (vehicle_id, trip_on);

EXPLAIN
SELECT trip_id, vehicle_id, trip_on, start_odometer, end_odometer
  FROM trips
 WHERE vehicle_id = 1
   AND trip_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- ----------------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_service_alerts() & pg_cron [6 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    -- Upsert alerts for all vehicles currently due for service
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT
        vehicle_id,
        (current_odometer - last_service_odometer) AS km_since_service,
        CURRENT_DATE
    FROM vehicles
    WHERE (current_odometer - last_service_odometer) >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
        SET km_since_service = EXCLUDED.km_since_service,
            flagged_on       = EXCLUDED.flagged_on;

    -- Remove alerts for vehicles that have been serviced and are no longer due
    DELETE FROM service_alerts sa
     WHERE NOT EXISTS (
         SELECT 1
           FROM vehicles v
          WHERE v.vehicle_id = sa.vehicle_id
            AND (v.current_odometer - v.last_service_odometer) >= 5000
     );
END;
$$;

CALL pr_refresh_service_alerts();

COMMIT;

-- Schedule every Monday at 06:00
SELECT cron.schedule(
    'fleet_weekly_service_alerts',
    '0 6 * * 1',
    $$CALL pr_refresh_service_alerts();$$
);
