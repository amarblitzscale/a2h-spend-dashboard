-- A2H to Live dashboard: master query (BigQuery, Metabase database 3).
-- One row per A2H date x outlier flag x week since go-live. Rows with win = NULL carry only the A2H / live counts
-- (cohorts too young to have a finished W0). The dashboard pools these raw sums itself, so do not pre-aggregate.
--   win      D0_6 = W0, D7_13 = W1, D14_20 = W2, D21_27 = W3 (days since the seller's first Meta spend day)
--   outlier  1 = seller whose W0 spend / platform GMV is under 5%
--   csa      1 = seller whose primary L1 category is clothing-shoes-and-accessories, 0 = everything else (incl. untagged)
-- A seller enters a week only once that week has fully elapsed.
-- No Metabase variables: save as a plain SQL question, then make its public link.
WITH params AS (SELECT DATE '2026-08-01' AS start_date),   -- first A2H date shown on the dashboard
a2h AS (
  SELECT CAST(seller_id AS STRING) AS seller_id, MIN(DATE(completed_at, 'Asia/Kolkata')) AS a2h_date
  FROM `blitzscale-prod-project.nushop.ob_tasks`
  WHERE created_at >= TIMESTAMP('2022-01-01')
    AND type = 'qc_check' AND disposition = 'qc_completed_and_okay' AND completed_at IS NOT NULL
    AND seller_id NOT IN ('6891985a317e68f10ecaffca','697c7e42120fd577706e7c23','68356cde72a04e21d267e053','69de323a317e68f10e91876b','Shopdeck')
  GROUP BY 1
  HAVING MIN(DATE(completed_at, 'Asia/Kolkata')) >= (SELECT start_date FROM params)
),
fbi AS (   -- all Meta insight rows (total + age / platform / adset breakdowns) on or after A2H
  SELECT f.seller_id, DATE(f.spend_date, 'Asia/Kolkata') AS d, f.breakdown_key, f.breakdown_value, f.spend,
         f.impressions, f.clicks, f.actions_purchase AS purchases
  FROM `blitzscale-prod-project.fb_marketings.fb_marketing_insights` f
  JOIN a2h a ON a.seller_id = f.seller_id
  WHERE f.spend_date >= TIMESTAMP('2026-01-01', 'Asia/Kolkata')   -- literal partition filter; keep it earlier than start_date
    AND f.spend > 0
    AND DATE(f.spend_date, 'Asia/Kolkata') >= a.a2h_date
),
live AS (  -- D0 = first day with Meta spend on or after A2H
  SELECT seller_id, MIN(d) AS live_date FROM fbi WHERE breakdown_key IS NULL OR breakdown_key = '' GROUP BY 1
),
wins AS (
  SELECT l.seller_id, l.live_date, w.win, w.s, w.e
  FROM live l, UNNEST([STRUCT('D0_6' AS win, 0 AS s, 6 AS e), ('D7_13', 7, 13), ('D14_20', 14, 20), ('D21_27', 21, 27)]) w
  WHERE DATE_ADD(l.live_date, INTERVAL w.e DAY) < CURRENT_DATE('Asia/Kolkata')
),
lal_adsets AS (  -- ad set is LAL if any included custom audience is a lookalike
  SELECT DISTINCT ad.adset_id
  FROM (SELECT adset_id, ANY_VALUE(targeting HAVING MAX updated_at) AS t
        FROM `blitzscale-prod-project.fb_marketings.adsets`
        WHERE start_time >= TIMESTAMP('2026-01-01') GROUP BY 1) ad,
  UNNEST(REGEXP_EXTRACT_ALL(REGEXP_EXTRACT(TO_JSON_STRING(ad.t), r"'custom_audiences': \[(.*?)\]"), r"'id': '(\d+)'")) aud_id
  JOIN (SELECT DISTINCT id FROM `blitzscale-prod-project.fb_marketings.custom_audiences` WHERE subtype = 'LOOKALIKE') ca ON ca.id = aud_id
),
brk AS (   -- per seller x week: funnel totals and spend splits
  SELECT w.seller_id, w.win,
    SUM(IF(f.breakdown_key IS NULL OR f.breakdown_key = '', f.spend, 0)) AS spend,
    SUM(IF(f.breakdown_key IS NULL OR f.breakdown_key = '', f.impressions, 0)) AS impressions,
    SUM(IF(f.breakdown_key IS NULL OR f.breakdown_key = '', f.clicks, 0)) AS clicks,
    SUM(IF(f.breakdown_key IS NULL OR f.breakdown_key = '', f.purchases, 0)) AS purchases,
    SUM(IF(f.breakdown_key = 'age', f.spend, 0)) AS age_spend,
    SUM(IF(f.breakdown_key = 'age' AND f.breakdown_value IN ('18-24','25-34','35-44'), f.spend, 0)) AS age_18_44,
    SUM(IF(f.breakdown_key = 'publisher_platform', f.spend, 0)) AS plat_spend,
    SUM(IF(f.breakdown_key = 'publisher_platform' AND f.breakdown_value = 'instagram', f.spend, 0)) AS ig_spend,
    SUM(IF(f.breakdown_key = 'adset', f.spend, 0)) AS adset_spend,
    SUM(IF(f.breakdown_key = 'adset' AND la.adset_id IS NULL, f.spend, 0)) AS non_lal_spend
  FROM wins w
  JOIN fbi f ON f.seller_id = w.seller_id AND DATE_DIFF(f.d, w.live_date, DAY) BETWEEN w.s AND w.e
  LEFT JOIN lal_adsets la ON f.breakdown_key = 'adset' AND la.adset_id = f.breakdown_value
  GROUP BY 1, 2
),
vid AS (   -- ad level: video = ad carries a video_id
  SELECT w.seller_id, w.win, SUM(i.spend) AS ad_spend,
    SUM(IF(i.video_id IS NOT NULL AND i.video_id != '', i.spend, 0)) AS video_spend
  FROM wins w
  JOIN `blitzscale-prod-project.fb_marketings.fb_ads_insights` i
    ON i.seller_id = w.seller_id AND DATE_DIFF(DATE(i.date_start), w.live_date, DAY) BETWEEN w.s AND w.e
  WHERE i.date_start >= '2026-01-01'
  GROUP BY 1, 2
),
gmv AS (   -- platform GMV: shipped, non-expired orders
  SELECT w.seller_id, w.win,
    SUM(oi.selling_price*oi.quantity + oi.cod_charge + oi.delivery_fees - oi.total_discount) AS gmv
  FROM wins w
  JOIN `blitzscale-prod-project.nushop.orderitems` oi
    ON CAST(oi.seller_id AS STRING) = w.seller_id
   AND DATE_DIFF(DATE(oi.createdat,'Asia/Kolkata'), w.live_date, DAY) BETWEEN w.s AND w.e
  WHERE oi.createdat >= TIMESTAMP('2026-07-01')   -- keep this at least a month before start_date
    AND oi.seller_last_status NOT IN ('initiated','enqueued','invalid')
    AND oi.awb_no != 'None' AND oi.in_house_status != 'awb_expired'
  GROUP BY 1, 2
),
outl AS (  -- outlier seller: W0 S/GMV under 5%
  SELECT b.seller_id, 1 AS outlier
  FROM brk b JOIN gmv g ON g.seller_id = b.seller_id AND g.win = b.win
  WHERE b.win = 'D0_6' AND g.gmv > 0 AND b.spend / g.gmv * 100 < 5
),
cat AS (   -- seller category (one row per seller)
  SELECT seller_id, IF(primary_category_l1 = 'clothing-shoes-and-accessories', 1, 0) AS csa
  FROM `blitzscale-prod-project.analytics.seller_level_category_mapping_l2`
),
agg AS (   -- raw sums per A2H date x outlier x week
  SELECT a.a2h_date, IFNULL(o.outlier, 0) AS outlier, IFNULL(c.csa, 0) AS csa, w.win,
    COUNT(DISTINCT w.seller_id) AS sellers,
    SUM(b.spend) AS spend, SUM(b.impressions) AS impressions, SUM(b.clicks) AS clicks, SUM(b.purchases) AS purchases,
    SUM(g.gmv) AS gmv,
    SUM(v.video_spend) AS video_spend, SUM(v.ad_spend) AS ad_spend,
    SUM(b.age_18_44) AS age_18_44, SUM(b.age_spend) AS age_spend,
    SUM(b.non_lal_spend) AS non_lal_spend, SUM(b.adset_spend) AS adset_spend,
    SUM(b.ig_spend) AS ig_spend, SUM(b.plat_spend) AS plat_spend
  FROM wins w
  JOIN a2h a USING (seller_id)
  LEFT JOIN outl o ON o.seller_id = w.seller_id
  LEFT JOIN cat c ON c.seller_id = w.seller_id
  LEFT JOIN brk b ON b.seller_id = w.seller_id AND b.win = w.win
  LEFT JOIN vid v ON v.seller_id = w.seller_id AND v.win = w.win
  LEFT JOIN gmv g ON g.seller_id = w.seller_id AND g.win = w.win
  GROUP BY 1, 2, 3, 4
),
base AS (
  SELECT a.a2h_date, IFNULL(o.outlier, 0) AS outlier, IFNULL(c.csa, 0) AS csa, COUNT(*) AS a2h_done, COUNT(l.seller_id) AS live_from_a2h
  FROM a2h a LEFT JOIN live l USING (seller_id) LEFT JOIN outl o USING (seller_id) LEFT JOIN cat c USING (seller_id)
  GROUP BY 1, 2, 3
)
SELECT b.a2h_date, b.outlier, b.csa, b.a2h_done, b.live_from_a2h, g.win, g.sellers, g.spend, g.impressions, g.clicks, g.purchases, g.gmv,
       g.video_spend, g.ad_spend, g.age_18_44, g.age_spend, g.non_lal_spend, g.adset_spend, g.ig_spend, g.plat_spend
FROM base b LEFT JOIN agg g ON g.a2h_date = b.a2h_date AND g.outlier = b.outlier AND g.csa = b.csa
ORDER BY 1 DESC, 2, 3, 6
