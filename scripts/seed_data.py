#!/usr/bin/env python3
"""
Synthetic data generator for the Next-Best-Action engine.

ALL DATA IS FAKE. Companies, people, emails (*.example), tenders, events,
call notes and CRM state are randomly generated. With --simulate-history the
script also fabricates past experiment outcomes using ASSUMED lifts, so the
reporting layer has something to show. Those numbers prove nothing.

Usage:
    pip install psycopg2-binary
    export DATABASE_URL=postgresql://postgres:postgres@localhost:5433/nba
    python scripts/seed_data.py --init --reset --simulate-history
"""
import argparse
import glob
import os
import random
import uuid
from datetime import datetime, timedelta, timezone

try:
    import psycopg2
    from psycopg2.extras import Json, execute_values
except ImportError:  # export_data.py only needs the generators, not a database driver
    psycopg2 = None

    class Json:
        def __init__(self, adapted):
            self.adapted = adapted

NOW = datetime.now(timezone.utc)
rng = random.Random(42)  # deterministic

TRADES = ["Electrical", "HVAC", "Plumbing", "Drywall", "Roofing",
          "Painting", "Flooring", "Concrete", "Facade", "Scaffolding"]
REGIONS = ["Berlin", "Hamburg", "Munich", "Cologne", "Frankfurt", "Stuttgart", "Düsseldorf", "Leipzig"]
REGION_W = [20, 14, 16, 12, 12, 9, 9, 8]
SUB_SIZES, SUB_W = ["1-10", "11-50", "51-200", "201-1000"], [45, 35, 15, 5]
GC_SIZES, GC_W = ["11-50", "51-200", "201-1000", "1000+"], [20, 40, 28, 12]
EMP_RANGE = {"1-10": (1, 10), "11-50": (11, 50), "51-200": (51, 200),
             "201-1000": (201, 1000), "1000+": (1001, 5000)}
REVENUE = {"1-10": "<1M", "11-50": "1-10M", "51-200": "10-50M", "201-1000": "50-250M", "1000+": "250M+"}
SURNAMES = ["Müller", "Schneider", "Weber", "Fischer", "Wagner", "Becker", "Hoffmann", "Koch",
            "Richter", "Klein", "Wolf", "Neumann", "Schwarz", "Zimmermann", "Braun"]
SUFFIXES = ["GmbH", "GmbH & Co. KG", "AG"]
OWNERS = ["Anna K.", "Jonas R.", "Lea M."]
CRM_STAGES = ["lead", "qualified", "opportunity", "customer", "churn_risk"]

CALL_TEMPLATES = [
    ("Caller says they like the tender alerts for {trade} in {region} but did not understand what the paid plan adds. "
     "Asked whether unlimited bids are included.",
     {"intent": "evaluate_paid_plan", "objections": ["pricing_unclear"], "buying_stage": "consideration", "sentiment": "neutral"}),
    ("Small team, only two estimators. Says writing bids takes too long and they skip tenders unless the deadline is generous.",
     {"intent": "reduce_bid_effort", "objections": ["no_time"], "buying_stage": "awareness", "sentiment": "neutral"}),
    ("Very positive call. Won a tender last month through the platform and wants to bring two partner firms. Asked about referral rewards.",
     {"intent": "refer_partners", "objections": [], "buying_stage": "advocacy", "sentiment": "positive"}),
    ("Frustrated: tenders shown are too large for the company. Asked to filter by project value under 150k EUR.",
     {"intent": "better_matching", "objections": ["irrelevant_tenders"], "buying_stage": "consideration", "sentiment": "negative"}),
    ("Evaluating competitors. Needs proof that GCs actually respond to bids. Requests a customer reference in their region.",
     {"intent": "evaluate_competitors", "objections": ["unclear_roi", "competitor_in_use"], "buying_stage": "decision", "sentiment": "neutral"}),
]


def ago(days):
    return NOW - timedelta(days=days)


def new_id():
    return str(uuid.UUID(int=rng.getrandbits(128), version=4))


def age_days(ts):
    return (NOW - ts).total_seconds() / 86400


# ---------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------
def make_users(n_sub, n_gc):
    users = []
    for i in range(n_sub + n_gc):
        role = "subcontractor" if i < n_sub else "gc"
        trade = rng.choice(TRADES)
        size = rng.choices(SUB_SIZES if role == "subcontractor" else GC_SIZES,
                           weights=SUB_W if role == "subcontractor" else GC_W)[0]
        surname = rng.choice(SURNAMES)
        name = (f"{surname} {trade} {rng.choice(SUFFIXES)}" if role == "subcontractor"
                else f"{surname} Bau {rng.choice(SUFFIXES)}")
        users.append(dict(
            id=new_id(), role=role, company_name=name, email=f"kontakt@firma{i}.example",
            trade=trade, region=rng.choices(REGIONS, weights=REGION_W)[0], company_size=size,
            language="de" if rng.random() < 0.8 else "en",
            signup_at=ago(rng.uniform(5, 120)), plan="free", paid_at=None,
            engagement=rng.betavariate(2, 3),  # latent, never stored
        ))
    return users


def make_tenders(gcs):
    tenders = []
    for g in gcs:
        k = rng.choices([0, 1, 2, 3, 4], weights=[10, 35, 25, 20, 10])[0]
        for _ in range(k):
            posted = max(g["signup_at"], ago(rng.uniform(1, 60)))
            deadline = posted + timedelta(days=rng.uniform(12, 35))
            trade = rng.choice(TRADES)
            region = g["region"] if rng.random() < 0.6 else rng.choice(REGIONS)
            tenders.append(dict(
                id=new_id(), gc_user_id=g["id"], title=f"{trade} works, {region} site {rng.randint(100, 999)}",
                trade=trade, region=region, value_eur=round(rng.lognormvariate(11.5, 0.9), -3),
                posted_at=posted, deadline=deadline,
                status="open" if deadline > NOW else rng.choices(["closed", "awarded"], weights=[40, 60])[0],
            ))
    return tenders


def make_events(users, tenders):
    ev = []

    def add(uid, etype, ts, tender_id=None, props=None):
        if ts <= NOW:
            ev.append((uid, etype, tender_id, ts, Json(props or {})))

    gc_by_id = {u["id"]: u for u in users if u["role"] == "gc"}
    for t in tenders:
        add(t["gc_user_id"], "tender_posted", t["posted_at"], t["id"])
    for g in gc_by_id.values():
        for _ in range(int(g["engagement"] * 15 * rng.random())):
            add(g["id"], "login", ago(rng.uniform(0, age_days(g["signup_at"]))))

    subs = [u for u in users if u["role"] == "subcontractor"]
    for s in subs:
        e = s["engagement"]
        for _ in range(int(e * 30 * rng.random())):
            add(s["id"], "login", ago(rng.uniform(0, age_days(s["signup_at"]))))
        submitted = []
        for t in tenders:
            match = (t["trade"] == s["trade"]) * 0.7 + (t["region"] == s["region"]) * 0.2 + 0.03
            if rng.random() > match * (0.15 + 0.7 * e):
                continue
            viewed = max(t["posted_at"], s["signup_at"]) + timedelta(days=rng.uniform(0.2, 6))
            if viewed > NOW:
                continue
            add(s["id"], "tender_viewed", viewed, t["id"])
            if rng.random() < 0.25 + 0.4 * e:
                started = viewed + timedelta(days=rng.uniform(0.1, 4))
                add(s["id"], "bid_started", started, t["id"])
                if rng.random() < 0.6:
                    sub_at = started + timedelta(days=rng.uniform(0.2, 3))
                    if sub_at <= NOW:
                        add(s["id"], "bid_submitted", sub_at, t["id"])
                        submitted.append((sub_at, t))
                        if t["status"] == "awarded" and rng.random() < 0.15:
                            add(s["id"], "bid_won", t["deadline"] + timedelta(days=2), t["id"])
        if submitted and rng.random() < 0.30:
            first = min(x[0] for x in submitted)
            paid_at = first + timedelta(days=rng.uniform(0.5, 10))
            if paid_at <= NOW:
                s["plan"], s["paid_at"] = "paid", paid_at
                add(s["id"], "paid_conversion", paid_at)
    for g in list(gc_by_id.values()):
        if rng.random() < 0.2:
            add(g["id"], "invite_sent", ago(rng.uniform(0, 40)))
    return ev


def make_aux(users):
    enrich, crm, calls, supp = [], [], [], []
    for u in users:
        lo, hi = EMP_RANGE[u["company_size"]]
        fit = round(min(1.0, 0.2 + 0.15 * SUB_SIZES.index(u["company_size"]) + rng.random() * 0.4)
                    if u["company_size"] in SUB_SIZES else rng.uniform(0.5, 1.0), 3)
        enrich.append((u["id"], rng.randint(lo, hi), REVENUE[u["company_size"]], rng.randint(1975, 2021), fit))
        if rng.random() < 0.45:
            stage = rng.choice(CRM_STAGES)
            crm.append((u["id"], rng.choice(OWNERS), stage, stage == "opportunity",
                        round(rng.uniform(1.2, 24), 1) * 1000 if stage in ("customer", "churn_risk", "opportunity") else None,
                        ago(rng.uniform(0, 60)), None))
    for u in rng.sample(users, 15):
        supp.append((u["id"], rng.choice(["unsubscribed", "bounced", "do_not_contact", "in_active_sales_cycle"])))
    for u in rng.sample([x for x in users if x["role"] == "subcontractor"], 60):
        text, extracted = rng.choice(CALL_TEMPLATES)
        calls.append((u["id"], ago(rng.uniform(1, 45)), text.format(trade=u["trade"], region=u["region"]),
                      Json(extracted) if rng.random() < 0.5 else None))  # rest left for the LLM workflow
    return enrich, crm, calls, supp


def simulate_history(cur, users):
    """Fabricate past experiment outcomes with ASSUMED lifts (demo only)."""
    lift = {"holdout": 0.0, "rules": 0.04, "agent": 0.09}
    eng = {u["id"]: u["engagement"] for u in users}
    cur.execute("SELECT id::text, nba_arm(id), nba_variant(id) FROM users WHERE role = 'subcontractor'")
    decisions, conv_events = [], []
    for uid, arm, variant in cur.fetchall():
        if rng.random() > 0.4:
            continue
        at = ago(rng.uniform(8, 28))
        sent = arm != "holdout"
        conf = round(rng.uniform(0.55, 0.95), 3) if arm == "agent" else (1.0 if arm == "rules" else None)
        decisions.append((uid, at, arm, variant, "viewed_no_bid",
                          "send_tender_digest" if sent else "none", "email" if sent else "none",
                          "next_business_morning", ("value_led" if variant == "A" else "urgency_led") if arm == "agent"
                          else ("deadline_reminder" if sent else None),
                          conf, "SIMULATED history" if sent else "Holdout: no touch",
                          "email" if sent else "holdout", sent, Json({"simulated": True}), "seed-sim"))
        if rng.random() < (0.06 + lift[arm]) * (0.6 + 0.8 * eng[uid]):
            conv_events.append((uid, "bid_submitted", None, at + timedelta(days=rng.uniform(0.2, 6)),
                                Json({"simulated_response": True})))
    execute_values(cur, """INSERT INTO decisions (user_id, decided_at, arm, ab_variant, signal_type, action,
        channel, timing, message_angle, confidence, reasoning, routed_to, sent, payload, workflow_version)
        VALUES %s""", decisions)
    execute_values(cur, "INSERT INTO events (user_id, event_type, tender_id, occurred_at, properties) VALUES %s",
                   conv_events)
    return len(decisions), len(conv_events)


# ---------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--init", action="store_true", help="apply sql/*.sql first (DROPS existing tables)")
    ap.add_argument("--reset", action="store_true", help="truncate tables before seeding")
    ap.add_argument("--simulate-history", action="store_true", help="fabricate past experiment outcomes")
    ap.add_argument("--subs", type=int, default=700)
    ap.add_argument("--gcs", type=int, default=150)
    args = ap.parse_args()

    conn = psycopg2.connect(os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@localhost:5433/nba"))
    cur = conn.cursor()
    if args.init:
        sql_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sql")
        for path in sorted(glob.glob(os.path.join(sql_dir, "0[12]_*.sql"))):  # schema only; 03/04 are the no-Python data path
            with open(path) as f:
                cur.execute(f.read())
    elif args.reset:
        cur.execute("TRUNCATE digest_builds, decisions, suppressions, crm_accounts, company_enrichment, "
                    "call_notes, events, tenders, users RESTART IDENTITY CASCADE")

    users = make_users(args.subs, args.gcs)
    tenders = make_tenders([u for u in users if u["role"] == "gc"])
    events = make_events(users, tenders)
    enrich, crm, calls, supp = make_aux(users)

    execute_values(cur, """INSERT INTO users (id, role, company_name, email, trade, region, company_size,
        language, plan, signup_at, paid_at) VALUES %s""",
                   [(u["id"], u["role"], u["company_name"], u["email"], u["trade"], u["region"],
                     u["company_size"], u["language"], u["plan"], u["signup_at"], u["paid_at"]) for u in users])
    execute_values(cur, """INSERT INTO tenders (id, gc_user_id, title, trade, region, value_eur, posted_at,
        deadline, status) VALUES %s""",
                   [(t["id"], t["gc_user_id"], t["title"], t["trade"], t["region"], t["value_eur"],
                     t["posted_at"], t["deadline"], t["status"]) for t in tenders])
    execute_values(cur, "INSERT INTO events (user_id, event_type, tender_id, occurred_at, properties) VALUES %s",
                   events, page_size=5000)
    execute_values(cur, "INSERT INTO company_enrichment (user_id, employee_count, revenue_band, founded_year, "
                        "fit_score) VALUES %s", enrich)
    execute_values(cur, "INSERT INTO crm_accounts (user_id, owner, stage, open_opportunity, arr_eur, "
                        "last_activity_at, notes) VALUES %s", crm)
    execute_values(cur, "INSERT INTO call_notes (user_id, called_at, transcript, extracted) VALUES %s", calls)
    execute_values(cur, "INSERT INTO suppressions (user_id, reason) VALUES %s", supp)

    n_dec = n_conv = 0
    if args.simulate_history:
        n_dec, n_conv = simulate_history(cur, users)
    conn.commit()

    cur.execute("SELECT signal_type, arm, count(*) FROM v_nba_candidates GROUP BY 1, 2 ORDER BY 1, 2")
    print(f"users={len(users)} tenders={len(tenders)} events={len(events)} calls={len(calls)} "
          f"simulated_decisions={n_dec} simulated_conversions={n_conv}")
    print("Live candidates by signal/arm:")
    for row in cur.fetchall():
        print("  ", row)
    conn.close()


if __name__ == "__main__":
    main()
