-- =====================================================================
-- ICT371 Advanced Database | Student No: 202407871
-- QUESTION 4: Clinic Appointment Scheduling  (50 marks)
-- Run with:  psql -d yourdb -f ICT371_202407871_Q4_Clinic.sql
-- Objects live in schema q4_clinic; the script can be re-run safely.
-- =====================================================================
DROP SCHEMA IF EXISTS q4_clinic CASCADE;
CREATE SCHEMA q4_clinic;
SET search_path TO q4_clinic, public;

-- ---------------------------------------------------------------------
-- (a) DATABASE AND SEED DATA [6]
-- ---------------------------------------------------------------------
CREATE TABLE patients (
    patient_id  SERIAL       PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id  SERIAL       PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id   SERIAL      PRIMARY KEY,
    patient_id       INTEGER     NOT NULL REFERENCES patients(patient_id),
    doctor_id        INTEGER     NOT NULL REFERENCES doctors(doctor_id),
    appointment_day  DATE        NOT NULL,
    slot_time        TIME        NOT NULL,
    status           VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT chk_slot   CHECK (slot_time IN ('09:00', '10:00', '11:00', '12:00')),
    CONSTRAINT chk_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

-- Safety net against race conditions: two non-cancelled appointments can
-- never share doctor+day+slot (the trigger in (d) gives the friendly message).
CREATE UNIQUE INDEX uq_active_slot
    ON appointments (doctor_id, appointment_day, slot_time)
    WHERE status <> 'CANCELLED';

CREATE TABLE clinic_summary (
    summary_date    DATE    PRIMARY KEY,
    booked_count    INTEGER NOT NULL,
    attended_count  INTEGER NOT NULL,
    cancelled_count INTEGER NOT NULL
);

INSERT INTO patients (full_name) VALUES ('Mercy Lungu'), ('Joseph Kalaba'), ('Ruth Mumba');
INSERT INTO doctors  (full_name) VALUES ('Dr. Simwanza'), ('Dr. Chileshe'), ('Dr. Banda');

-- Six appointments, none clashing (a cancelled slot may be re-used)
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE,     '09:00', 'BOOKED'),
    (2, 1, CURRENT_DATE,     '10:00', 'BOOKED'),
    (3, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
    (1, 2, CURRENT_DATE - 1, '11:00', 'ATTENDED'),
    (2, 3, CURRENT_DATE - 1, '09:00', 'CANCELLED'),
    (3, 1, CURRENT_DATE + 1, '12:00', 'BOOKED');

-- ---------------------------------------------------------------------
-- (b) FUNCTION fn_daily_load [6]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    -- COUNT(*) returns 0 (not NULL) when there are no rows
    RETURN (SELECT COUNT(*)::INTEGER
            FROM   appointments
            WHERE  doctor_id = p_doctor_id
              AND  appointment_day = p_day
              AND  status <> 'CANCELLED');
END;
$$;

-- ---------------------------------------------------------------------
-- (c) PROCEDURE pr_book_appointment [8]
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INTEGER, p_doctor_id INTEGER,
                                                p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past (or NULL)', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN ('09:00'::TIME, '10:00'::TIME, '11:00'::TIME, '12:00'::TIME) THEN
        RAISE EXCEPTION 'Unsupported slot %: use 09:00, 10:00, 11:00 or 12:00', p_slot;
    END IF;

    -- The BEFORE INSERT trigger will reject a clash with another active appointment
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- ---------------------------------------------------------------------
-- (d) TRIGGER BEFORE INSERT OR UPDATE [8]
-- On UPDATE the row being changed is excluded from the clash search,
-- otherwise every update would "clash with itself".
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_prevent_clash()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (
            SELECT 1
            FROM   appointments a
            WHERE  a.doctor_id       = NEW.doctor_id
              AND  a.appointment_day = NEW.appointment_day
              AND  a.slot_time       = NEW.slot_time
              AND  a.status         <> 'CANCELLED'
              AND  (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)
        ) THEN
            RAISE EXCEPTION 'Clash: doctor % already has an appointment on % at %',
                            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_no_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_prevent_clash();

-- ---------------------------------------------------------------------
-- (e) VIEW v_today_appointments [5]
-- Only names and slot are exposed (no patient_id, no other patient data).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.appointment_id,
       p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM   appointments a
JOIN   patients p ON p.patient_id = a.patient_id
JOIN   doctors  d ON d.doctor_id  = a.doctor_id
WHERE  a.appointment_day = CURRENT_DATE
  AND  a.status = 'BOOKED';

-- ---------------------------------------------------------------------
-- (f) NON-UNIQUE INDEX [5]
-- "Show me day X for doctor Y": both columns are equality filters, so a
-- composite B-tree (appointment_day, doctor_id) finds them directly.
-- Non-unique because one doctor has several appointments on a day.
-- ---------------------------------------------------------------------
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;

-- ---------------------------------------------------------------------
-- (g) SCHEDULED JOB [6]
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day must not be NULL';
    END IF;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM   appointments
    WHERE  appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
        SET booked_count    = EXCLUDED.booked_count,
            attended_count  = EXCLUDED.attended_count,
            cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule('q4_refresh_clinic_summary', '0 1 * * *',
                     $$CALL q4_clinic.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);

SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q4_refresh_clinic_summary';
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;

-- =====================================================================
-- TESTS / EVIDENCE
-- =====================================================================
\echo '--- (a) Data ---'
SELECT * FROM appointments ORDER BY appointment_id;

\echo '--- (b) Function ---'
SELECT fn_daily_load(1, CURRENT_DATE) AS doctor1_today;          -- 2
SELECT fn_daily_load(3, CURRENT_DATE - 1) AS cancelled_not_counted; -- 0
SELECT fn_daily_load(1, CURRENT_DATE + 30) AS no_bookings;       -- 0
DO $$ BEGIN PERFORM fn_daily_load(999, CURRENT_DATE);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (unknown doctor): %', SQLERRM; END $$;

\echo '--- (c) Procedure ---'
CALL pr_book_appointment(3, 1, CURRENT_DATE, '11:00');           -- valid
DO $$ BEGIN CALL pr_book_appointment(99, 1, CURRENT_DATE, '11:00');
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (patient): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 99, CURRENT_DATE, '11:00');
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (doctor): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 2, CURRENT_DATE - 1, '10:00');
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (past date): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 2, CURRENT_DATE, '13:00');
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (bad slot): %', SQLERRM; END $$;

\echo '--- (d) Trigger: clash on INSERT, clash on UPDATE, self-update allowed ---'
DO $$ BEGIN CALL pr_book_appointment(2, 1, CURRENT_DATE, '09:00');  -- doctor 1 already has 09:00 today
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (insert clash): %', SQLERRM; END $$;
DO $$ BEGIN UPDATE appointments SET slot_time = '09:00' WHERE appointment_id = 2;  -- moves onto appt 1
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (update clash): %', SQLERRM; END $$;
UPDATE appointments SET status = 'BOOKED' WHERE appointment_id = 1;  -- allowed: excludes itself
-- A cancelled slot can be booked again:
CALL pr_book_appointment(1, 3, CURRENT_DATE + 1, '09:00');

\echo '--- (e) View ---'
SELECT * FROM v_today_appointments ORDER BY slot_time;

\echo '--- (f) EXPLAIN ---'
SET enable_seqscan = off;
EXPLAIN SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
RESET enable_seqscan;

\echo '--- (g) Run twice: summary replaced, not duplicated ---'
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);                -- booked 0, attended 1, cancelled 1
SELECT * FROM clinic_summary;
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
SELECT * FROM clinic_summary;
