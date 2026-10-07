-- =====================================================================
-- Next-Best-Action engine: Postgres schema
-- Synthetic demo for a two-sided construction marketplace.
-- Re-runnable: drops and recreates everything in the public schema objects below.
-- =====================================================================

DROP TABLE IF EXISTS digest_builds, decisions, suppressions, crm_accounts, company_enrichment,
                     call_notes, events, tenders, users CASCADE;

-- ---------------------------------------------------------------------
-- Core entities
-- ---------------------------------------------------------------------
CREATE TABLE users (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    role          text NOT NULL CHECK (role IN ('subcontractor', 'gc')),
    company_name  text NOT NULL,
    email         text NOT NULL UNIQUE,
    trade         text,                       -- subcontractor trade / GC main trade
    region        text,
    company_size  text,                       -- '1-10','11-50','51-200','201-1000','1000+'
    language      text NOT NULL DEFAULT 'de' CHECK (language IN ('de', 'en')),
    plan          text NOT NULL DEFAULT 'free' CHECK (plan IN ('free', 'paid')),
    signup_at     timestamptz NOT NULL,
    paid_at       timestamptz
);

CREATE TABLE tenders (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    gc_user_id   uuid NOT NULL REFERENCES users(id),
    title        text NOT NULL,
    trade        text NOT NULL,
    region       text NOT NULL,
    value_eur    numeric(12,2) NOT NULL,
    posted_at    timestamptz NOT NULL,
    deadline     timestamptz NOT NULL,
    status       text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed', 'awarded'))
);
CREATE INDEX tenders_open_idx ON tenders (status, deadline) WHERE status = 'open';

CREATE TABLE events (
    id           bigserial PRIMARY KEY,
    user_id      uuid NOT NULL REFERENCES users(id),
    event_type   text NOT NULL CHECK (event_type IN (
                    'login', 'tender_posted', 'tender_viewed', 'bid_started',
                    'bid_submitted', 'bid_won', 'invite_sent', 'paid_conversion')),
    tender_id    uuid REFERENCES tenders(id),
    occurred_at  timestamptz NOT NULL,
    properties   jsonb NOT NULL DEFAULT '{}'
);
CREATE INDEX events_user_time_idx ON events (user_id, occurred_at DESC);
CREATE INDEX events_type_time_idx ON events (event_type, occurred_at DESC);

CREATE TABLE call_notes (
    id          bigserial PRIMARY KEY,
    user_id     uuid NOT NULL REFERENCES users(id),
    called_at   timestamptz NOT NULL,
    transcript  text NOT NULL,
    extracted   jsonb        -- filled by the call-insights workflow (LLM): intent, objections, buying_stage, sentiment
);

-- Mocked Apollo-style firmographics
CREATE TABLE company_enrichment (
    user_id         uuid PRIMARY KEY REFERENCES users(id),
    employee_count  int,
    revenue_band    text,
    founded_year    int,
    fit_score       numeric(4,3),     -- 0..1 firmographic ICP fit
    source          text NOT NULL DEFAULT 'mock_apollo',
    enriched_at     timestamptz NOT NULL DEFAULT now()
);

-- Mirror of Salesforce/HubSpot account state (what a "CRM lookup" tool would see)
CREATE TABLE crm_accounts (
    user_id           uuid PRIMARY KEY REFERENCES users(id),
    owner             text,
    stage             text CHECK (stage IN ('lead', 'qualified', 'opportunity', 'customer', 'churn_risk')),
    open_opportunity  boolean NOT NULL DEFAULT false,
    arr_eur           numeric(12,2),
    last_activity_at  timestamptz,
    notes             text
);

CREATE TABLE suppressions (
    user_id     uuid PRIMARY KEY REFERENCES users(id),
    reason      text NOT NULL,       -- unsubscribed, bounced, do_not_contact, in_active_sales_cycle
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Decision log: every decision incl. holdout, with reasoning (audit trail)
-- ---------------------------------------------------------------------
CREATE TABLE decisions (
    id               bigserial PRIMARY KEY,
    user_id          uuid NOT NULL REFERENCES users(id),
    decided_at       timestamptz NOT NULL DEFAULT now(),
    arm              text NOT NULL CHECK (arm IN ('holdout', 'rules', 'agent')),
    ab_variant       text CHECK (ab_variant IN ('A', 'B')),
    signal_type      text,
    action           text,
    channel          text,
    timing           text,
    message_angle    text,
    confidence       numeric(4,3),
    reasoning        text,
    routed_to        text,           -- email | in_app | human | none | holdout
    sent             boolean NOT NULL DEFAULT false,
    payload          jsonb NOT NULL DEFAULT '{}',
    workflow_version text
);
CREATE INDEX decisions_user_idx ON decisions (user_id, decided_at DESC);

-- ---------------------------------------------------------------------
-- Experiment assignment: deterministic, stateless, reproducible in SQL or JS
--   10% holdout (no agent/rules-driven touches), 30% static rules, 60% agent
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION nba_arm(uid uuid) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN b < 10 THEN 'holdout'
                WHEN b < 40 THEN 'rules'
                ELSE 'agent' END
    FROM (SELECT (hashtextextended(uid::text, 0) & 2147483647) % 100 AS b) s
$$;

-- Independent hash (different seed) so the message-angle A/B is orthogonal to the arm
CREATE OR REPLACE FUNCTION nba_variant(uid uuid) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN (hashtextextended(uid::text, 1) & 1) = 0 THEN 'A' ELSE 'B' END
$$;

-- ---------------------------------------------------------------------
-- Marketplace liquidity matcher: rank open tenders for a subcontractor
--   score = 0.45 trade (hard filter) + 0.25 region + 0.15 urgency + 0.15 past bid behaviour
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION match_tenders(p_user uuid, p_limit int DEFAULT 3)
RETURNS TABLE (
    tender_id uuid, title text, trade text, region text,
    value_eur numeric, deadline timestamptz, score numeric, reasons jsonb
)
LANGUAGE sql STABLE AS $$
    WITH u AS (SELECT * FROM users WHERE id = p_user),
    past AS (
        SELECT t.trade, count(*) AS n
        FROM events e JOIN tenders t ON t.id = e.tender_id
        WHERE e.user_id = p_user AND e.event_type IN ('bid_started', 'bid_submitted')
        GROUP BY t.trade
    ),
    scored AS (
        SELECT t.id AS tid, t.title AS ttitle, t.trade AS ttrade, t.region AS tregion,
               t.value_eur AS tvalue, t.deadline AS tdeadline,
               (t.trade = u.trade)   AS trade_match,
               (t.region = u.region) AS region_match,
               extract(epoch FROM t.deadline - now()) / 86400 AS days_left,
               coalesce(p.n, 0) AS past_bids
        FROM tenders t
        CROSS JOIN u
        LEFT JOIN past p ON p.trade = t.trade
        WHERE t.status = 'open'
          AND t.deadline > now() + interval '1 day'
          AND NOT EXISTS (
              SELECT 1 FROM events e
              WHERE e.user_id = p_user AND e.tender_id = t.id
                AND e.event_type IN ('bid_started', 'bid_submitted'))
    )
    SELECT tid, ttitle, ttrade, tregion, tvalue, tdeadline,
           round((0.45 * trade_match::int
                + 0.25 * region_match::int
                + CASE WHEN days_left BETWEEN 2 AND 10 THEN 0.15 ELSE 0.05 END
                + 0.15 * least(past_bids, 3) / 3.0)::numeric, 3) AS score,
           jsonb_build_object('trade_match', trade_match, 'region_match', region_match,
                              'days_left', round(days_left::numeric, 1),
                              'past_bids_in_trade', past_bids) AS reasons
    FROM scored
    WHERE trade_match
    ORDER BY 7 DESC, tdeadline ASC
    LIMIT p_limit
$$;

-- ---------------------------------------------------------------------
-- Candidate view: behavioural signals + guardrails (suppression, frequency cap)
-- This is what the n8n workflow polls.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_nba_candidates AS
WITH signals AS (
    -- 1) Subcontractor viewed a still-open tender 3-10 days ago and never started a bid
    SELECT e.user_id, 'viewed_no_bid'::text AS signal_type, 1 AS priority,
           jsonb_build_object('tender_id', e.tender_id, 'viewed_at', e.occurred_at) AS signal_detail
    FROM events e
    JOIN tenders t ON t.id = e.tender_id AND t.status = 'open' AND t.deadline > now()
    WHERE e.event_type = 'tender_viewed'
      AND e.occurred_at BETWEEN now() - interval '10 days' AND now() - interval '3 days'
      AND NOT EXISTS (
          SELECT 1 FROM events b
          WHERE b.user_id = e.user_id AND b.tender_id = e.tender_id
            AND b.event_type IN ('bid_started', 'bid_submitted'))
    UNION ALL
    -- 2) GC posted exactly one tender more than 7 days ago and never a second
    SELECT u.id, 'gc_single_tender', 2,
           jsonb_build_object('tender_id', (array_agg(t.id))[1], 'posted_at', max(t.posted_at))
    FROM users u JOIN tenders t ON t.gc_user_id = u.id
    WHERE u.role = 'gc'
    GROUP BY u.id
    HAVING count(*) = 1 AND max(t.posted_at) < now() - interval '7 days'
    UNION ALL
    -- 3) Free subcontractor with no activity for 14+ days
    SELECT u.id, 'idle_14d', 3,
           jsonb_build_object('last_event_at', max(e.occurred_at))
    FROM users u LEFT JOIN events e ON e.user_id = u.id
    WHERE u.role = 'subcontractor' AND u.plan = 'free'
      AND u.signup_at < now() - interval '14 days'
    GROUP BY u.id
    HAVING coalesce(max(e.occurred_at), u.signup_at) < now() - interval '14 days'
),
best AS (   -- one signal per user: highest priority, most recent
    SELECT DISTINCT ON (user_id) *
    FROM signals
    ORDER BY user_id, priority, (signal_detail ->> 'viewed_at') DESC NULLS LAST
)
SELECT
    u.id AS user_id, u.email, u.role, u.language, u.company_name,
    b.signal_type, b.signal_detail,
    nba_arm(u.id)     AS arm,
    nba_variant(u.id) AS ab_variant,
    (u.company_size IN ('201-1000', '1000+')) AS is_high_value,
    jsonb_build_object(
        'role', u.role, 'trade', u.trade, 'region', u.region,
        'company_size', u.company_size, 'language', u.language, 'plan', u.plan,
        'days_since_signup', extract(day FROM now() - u.signup_at)::int,
        'fit_score', ce.fit_score
    ) AS profile,
    coalesce((
        SELECT jsonb_agg(jsonb_build_object('type', r.event_type, 'at', r.occurred_at,
                                            'tender_id', r.tender_id) ORDER BY r.occurred_at DESC)
        FROM (SELECT * FROM events ev
              WHERE ev.user_id = u.id AND ev.occurred_at > now() - interval '14 days'
              ORDER BY ev.occurred_at DESC LIMIT 10) r
    ), '[]'::jsonb) AS recent_events,
    (SELECT cn.extracted FROM call_notes cn
     WHERE cn.user_id = u.id AND cn.extracted IS NOT NULL
     ORDER BY cn.called_at DESC LIMIT 1) AS call_insights
FROM best b
JOIN users u ON u.id = b.user_id
LEFT JOIN company_enrichment ce ON ce.user_id = u.id
WHERE NOT EXISTS (SELECT 1 FROM suppressions s WHERE s.user_id = u.id)                                  -- suppression
  AND NOT EXISTS (SELECT 1 FROM decisions d WHERE d.user_id = u.id
                  AND d.decided_at > now() - interval '3 days')                                         -- cooldown
  AND (SELECT count(*) FROM decisions d WHERE d.user_id = u.id AND d.sent
       AND d.decided_at > now() - interval '14 days') < 2                                               -- frequency cap
ORDER BY b.priority, u.signup_at DESC;

-- ---------------------------------------------------------------------
-- Incrementality: first decision per user, conversion = bid_submitted or
-- paid_conversion within 7 days after that decision. Lift is vs. holdout.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_incrementality AS
WITH first_dec AS (
    SELECT DISTINCT ON (user_id) user_id, arm, decided_at
    FROM decisions
    ORDER BY user_id, decided_at
),
conv AS (
    SELECT f.arm, f.user_id,
           EXISTS (SELECT 1 FROM events e
                   WHERE e.user_id = f.user_id
                     AND e.event_type IN ('bid_submitted', 'paid_conversion')
                     AND e.occurred_at >  f.decided_at
                     AND e.occurred_at <= f.decided_at + interval '7 days') AS converted
    FROM first_dec f
    WHERE f.decided_at < now() - interval '7 days'      -- only fully matured windows
),
holdout AS (SELECT avg(converted::int) AS cvr FROM conv WHERE arm = 'holdout')
SELECT c.arm,
       count(*)                                   AS users,
       sum(c.converted::int)                      AS conversions,
       round(avg(c.converted::int)::numeric, 4)   AS cvr,
       round((avg(c.converted::int) - h.cvr)::numeric, 4) AS abs_lift_vs_holdout,
       round(((avg(c.converted::int) - h.cvr) / nullif(h.cvr, 0))::numeric, 3) AS rel_lift_vs_holdout
FROM conv c CROSS JOIN holdout h
GROUP BY c.arm, h.cvr
ORDER BY c.arm;
