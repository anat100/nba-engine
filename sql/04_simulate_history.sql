-- =====================================================================
-- OPTIONAL: fabricate past experiment outcomes so v_incrementality has data.
-- SIMULATED with ASSUMED lifts (holdout +0, rules +4pp, agent +9pp). Proves nothing.
-- Run once, after 03_seed_data.sql.
-- =====================================================================
SELECT setseed(0.42);

CREATE TEMP TABLE sim AS
SELECT id AS user_id, nba_arm(id) AS arm, nba_variant(id) AS variant,
       now() - (8 + random() * 20) * interval '1 day' AS decided_at,
       random() AS conf_r, random() AS conv_r, random() AS conv_m, random() AS delay_r
FROM users
WHERE role = 'subcontractor' AND random() < 0.4;

INSERT INTO decisions (user_id, decided_at, arm, ab_variant, signal_type, action, channel, timing,
                       message_angle, confidence, reasoning, routed_to, sent, payload, workflow_version)
SELECT user_id, decided_at, arm, variant, 'viewed_no_bid',
       CASE WHEN arm = 'holdout' THEN 'none' ELSE 'send_tender_digest' END,
       CASE WHEN arm = 'holdout' THEN 'none' ELSE 'email' END,
       'next_business_morning',
       CASE WHEN arm = 'agent' THEN (CASE WHEN variant = 'A' THEN 'value_led' ELSE 'urgency_led' END)
            WHEN arm = 'rules' THEN 'deadline_reminder' END,
       CASE WHEN arm = 'agent' THEN round((0.55 + conf_r * 0.4)::numeric, 3)
            WHEN arm = 'rules' THEN 1.0 END,
       CASE WHEN arm = 'holdout' THEN 'Holdout: no touch' ELSE 'SIMULATED history' END,
       CASE WHEN arm = 'holdout' THEN 'holdout' ELSE 'email' END,
       arm <> 'holdout', '{"simulated": true}'::jsonb, 'seed-sim'
FROM sim;

INSERT INTO events (user_id, event_type, occurred_at, properties)
SELECT user_id, 'bid_submitted', decided_at + (0.2 + delay_r * 5.8) * interval '1 day',
       '{"simulated_response": true}'::jsonb
FROM sim
WHERE conv_r < (0.06 + CASE arm WHEN 'holdout' THEN 0 WHEN 'rules' THEN 0.04 ELSE 0.09 END) * (0.6 + 0.8 * conv_m);

DROP TABLE sim;
