-- =====================================================================
-- Patch: tender digest builds + liquidity performance (run after 01_schema.sql)
-- =====================================================================
CREATE TABLE IF NOT EXISTS digest_builds (
    id             uuid PRIMARY KEY,
    user_id        uuid NOT NULL REFERENCES users(id),
    built_at       timestamptz NOT NULL DEFAULT now(),
    subject        text,
    tender_ids     uuid[] NOT NULL,
    match_scores   jsonb,                    -- [{tender_id, score, reasons}] at send time
    copy_source    text NOT NULL CHECK (copy_source IN ('llm', 'fallback')),
    ab_variant     text,
    message_angle  text
);
CREATE INDEX IF NOT EXISTS digest_builds_user_idx ON digest_builds (user_id, built_at DESC);

-- Per digest: did the recipient engage with the tenders we recommended (7-day window)?
-- Product links carry utm_content=<digest_id>; here we join on tender_id for simplicity.
CREATE OR REPLACE VIEW v_digest_performance AS
SELECT d.id AS digest_id, d.user_id, d.built_at, d.copy_source, d.ab_variant, d.message_angle,
       cardinality(d.tender_ids) AS n_tenders,
       count(DISTINCT e.tender_id) FILTER (WHERE e.event_type = 'tender_viewed')  AS matched_viewed,
       count(DISTINCT e.tender_id) FILTER (WHERE e.event_type = 'bid_started')    AS matched_started,
       count(DISTINCT e.tender_id) FILTER (WHERE e.event_type = 'bid_submitted')  AS matched_submitted
FROM digest_builds d
LEFT JOIN events e
       ON e.user_id = d.user_id
      AND e.tender_id = ANY (d.tender_ids)
      AND e.occurred_at >  d.built_at
      AND e.occurred_at <= d.built_at + interval '7 days'
GROUP BY d.id;

-- Liquidity read-out per message variant (directional; the causal read stays v_incrementality vs holdout)
CREATE OR REPLACE VIEW v_digest_variant_summary AS
SELECT ab_variant, message_angle, count(*) AS digests,
       round(avg((matched_viewed > 0)::int)::numeric, 3)    AS view_rate,
       round(avg((matched_started > 0)::int)::numeric, 3)   AS bid_start_rate,
       round(avg((matched_submitted > 0)::int)::numeric, 3) AS bid_submit_rate
FROM v_digest_performance
WHERE built_at < now() - interval '7 days'
GROUP BY ab_variant, message_angle
ORDER BY ab_variant, message_angle;
