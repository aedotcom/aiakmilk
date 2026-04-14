/* ================================================================
   PLAN_SUM_TABLE 단일 쿼리 + 동적 SHIFT 버전
   DBMS   : Oracle 12c R1 이상
   ================================================================
   [SHIFT 로직 - 동적 SHIFT_DAYS 처리]

   Oracle LEAD/LAG 의 offset 은 리터럴만 허용 → 컬럼값 직접 불가
   → ROW_NUMBER + 셀프 조인으로 동적 N행 뒤 값 조회

   적용 규칙 (SHIFT_DAYS = N, FAB/TECH/LOT/DEVICE/PG_CD 별 관리):
   ┌────────────────────────────────────────────────────────────┐
   │  DT 는 원본 그대로 유지                                    │
   │  RN 번째 행의 QTY = RN + SHIFT_DAYS 번째 행의 QTY         │
   │  RN + SHIFT_DAYS > TOTAL_ROWS → NULL → 마지막 유효값 채움  │
   └────────────────────────────────────────────────────────────┘

   예시) SHIFT_DAYS = 3, 원본 5행
   ┌────┬────────────┬──────────┬─────┬──────────────────────────┐
   │ RN │ DT         │ 원본 QTY │ 대상│ SHIFT 후 QTY             │
   ├────┼────────────┼──────────┼─────┼──────────────────────────┤
   │  1 │ 2023-01-01 │ 100      │ RN4 │ 400  ← 4번째 행 값       │
   │  2 │ 2023-01-02 │ 200      │ RN5 │ 500  ← 5번째 행 값       │
   │  3 │ 2023-01-03 │ 300      │  -  │ 500  ← 범위초과 → 마지막값│
   │  4 │ 2023-01-04 │ 400      │  -  │ 500  ← 범위초과 → 마지막값│
   │  5 │ 2023-01-05 │ 500      │  -  │ 500  ← 범위초과 → 마지막값│
   └────┴────────────┴──────────┴─────┴──────────────────────────┘

   CTE 흐름:
   ① daily_plan     : PRODUPLAN_TABLE(월별) → 일별 배분
   ② daily_cum      : CUM_QTY 누적합 계산
   ③ adj_ranked     : ADJ_TABLE → PG별 윈도우 경계
   ④ device_dates   : BASE_DT 후보 추출
   ⑤ windows        : WIN_START / WIN_END / WIN_SIZE 산출
   ⑥ cum_both       : END_CUM / PRE_CUM 단일 스캔
   ⑦ plan_base      : PREFIX SUM → 원본 PLAN_SUM_QTY + RN 부여
   ⑧ shift_info     : SHIFT_TABLE 조인 → SHIFT_DAYS 확보
   ⑨ plan_shifted   : 셀프 조인(RN = RN + SHIFT_DAYS) → SHIFTED_RAW
   ⑩ 최종 SELECT    : LAST_VALUE IGNORE NULLS → 마지막값 채움
   ================================================================ */


/* ================================================================
   SHIFT_TABLE DDL
   ================================================================ */
/*
CREATE TABLE SHIFT_TABLE (
    FAB        VARCHAR2(10)  NOT NULL,
    TECH       VARCHAR2(10)  NOT NULL,
    LOT        VARCHAR2(10)  NOT NULL,
    DEVICE     VARCHAR2(50)  NOT NULL,
    PG_CD      VARCHAR2(10)  NOT NULL,
    SHIFT_DAYS NUMBER(5)     NOT NULL DEFAULT 0,
    CONSTRAINT PK_SHIFT PRIMARY KEY (FAB, TECH, LOT, DEVICE, PG_CD)
);
CREATE INDEX IDX_SHIFT_MAIN
    ON SHIFT_TABLE (FAB, TECH, LOT, DEVICE, PG_CD, SHIFT_DAYS)
    COMPRESS 3;
*/


/* ================================================================
   MAIN INSERT 쿼리
   ================================================================ */

INSERT /*+ APPEND PARALLEL(4) */
INTO PLAN_SUM_TABLE (FAB, TECH, LOT, DEVICE, PG_CD, DT, PLAN_SUM_QTY)
WITH

/* ── ① 월별 → 일별 변환 ─────────────────────────────────────────
   CONNECT BY LEVEL 로 해당 월 일수만큼 행 펼침
   일별 배분량 = MONTHLY_QTY / 해당월 일수                         */
daily_plan AS (
    SELECT /*+ NO_MERGE USE_HASH(m) */
           m.FAB,
           m.TECH,
           m.LOT,
           m.DEVICE,
           TRUNC(TO_DATE(TO_CHAR(m.YM), 'YYYYMM'), 'MM')
               + (LEVEL - 1)                               AS DT,
           m.MONTHLY_QTY
           / TO_NUMBER(TO_CHAR(
               LAST_DAY(TO_DATE(TO_CHAR(m.YM), 'YYYYMM')), 'DD'
             ))                                            AS PRODU_PLAN_QTY
    FROM   PRODUPLAN_TABLE m
    WHERE  m.MONTHLY_QTY IS NOT NULL
      AND  m.MONTHLY_QTY <> 0
    CONNECT BY
           LEVEL <= TO_NUMBER(TO_CHAR(
                        LAST_DAY(TO_DATE(TO_CHAR(m.YM), 'YYYYMM')), 'DD'))
           AND PRIOR m.FAB    = m.FAB
           AND PRIOR m.TECH   = m.TECH
           AND PRIOR m.LOT    = m.LOT
           AND PRIOR m.DEVICE = m.DEVICE
           AND PRIOR m.YM     = m.YM
           AND PRIOR SYS_GUID() IS NOT NULL
),

/* ── ② CUM_QTY 누적합 계산 ──────────────────────────────────────
   디바이스별 날짜 오름차순 누적합                                  */
daily_cum AS (
    SELECT /*+ NO_MERGE */
           FAB, TECH, LOT, DEVICE, DT,
           SUM(PRODU_PLAN_QTY) OVER (
               PARTITION BY FAB, TECH, LOT, DEVICE
               ORDER BY DT
               ROWS UNBOUNDED PRECEDING
           )                                               AS CUM_QTY
    FROM   daily_plan
),

/* ── ③ ADJ_TABLE : PG별 윈도우 경계 산출 ───────────────────────
   LEAD 로 다음 스테이지 DAYS_VAL → LOWER_DAYS                     */
adj_ranked AS (
    SELECT /*+ FULL(a) NO_MERGE */
           FAB, TECH, LOT, DEVICE, PG_CD,
           DAYS_VAL,
           NVL(
               LEAD(DAYS_VAL) OVER (
                   PARTITION BY FAB, TECH, LOT, DEVICE
                   ORDER BY DAYS_VAL DESC
               ), 0
           )                                               AS LOWER_DAYS
    FROM   ADJ_TABLE a
),

/* ── ④ BASE_DT 후보 추출 ────────────────────────────────────────
   daily_cum 에서 DISTINCT 로 일자 목록 확보                        */
device_dates AS (
    SELECT /*+ NO_MERGE */
           DISTINCT FAB, TECH, LOT, DEVICE, DT AS BASE_DT
    FROM   daily_cum
),

/* ── ⑤ 윈도우 정의 ─────────────────────────────────────────────
   WIN_START = BASE_DT + LOWER_DAYS
   WIN_END   = BASE_DT + DAYS_VAL - 1
   WIN_SIZE  = DAYS_VAL - LOWER_DAYS                                */
windows AS (
    SELECT /*+ USE_HASH(dd ar) NO_MERGE */
           dd.FAB, dd.TECH, dd.LOT, dd.DEVICE,
           ar.PG_CD,
           dd.BASE_DT,
           dd.BASE_DT + ar.LOWER_DAYS      AS WIN_START,
           dd.BASE_DT + ar.DAYS_VAL - 1   AS WIN_END,
           ar.DAYS_VAL - ar.LOWER_DAYS     AS WIN_SIZE
    FROM   device_dates dd
    JOIN   adj_ranked   ar
        ON  ar.FAB    = dd.FAB
        AND ar.TECH   = dd.TECH
        AND ar.LOT    = dd.LOT
        AND ar.DEVICE = dd.DEVICE
    WHERE  ar.DAYS_VAL > ar.LOWER_DAYS
),

/* ── ⑥ 2점 룩업 통합 : END_CUM / PRE_CUM 단일 스캔 ────────────
   windows × daily_cum 해시조인 후 GROUP BY 로 동시 산출            */
cum_both AS (
    SELECT /*+ USE_HASH(w p) LEADING(w p) NO_MERGE */
           w.FAB, w.TECH, w.LOT, w.DEVICE,
           w.PG_CD, w.BASE_DT, w.WIN_SIZE,
           MAX(CASE WHEN p.DT <= w.WIN_END
                    THEN p.CUM_QTY END)
               KEEP (DENSE_RANK LAST
                     ORDER BY CASE WHEN p.DT <= w.WIN_END
                                   THEN p.DT ELSE NULL END)
                                                           AS END_CUM,
           MAX(CASE WHEN p.DT < w.WIN_START
                    THEN p.CUM_QTY END)
               KEEP (DENSE_RANK LAST
                     ORDER BY CASE WHEN p.DT < w.WIN_START
                                   THEN p.DT ELSE NULL END)
                                                           AS PRE_CUM
    FROM   windows     w
    JOIN   daily_cum   p
        ON  p.FAB    = w.FAB
        AND p.TECH   = w.TECH
        AND p.LOT    = w.LOT
        AND p.DEVICE = w.DEVICE
        AND p.DT    <= w.WIN_END
    GROUP BY
           w.FAB, w.TECH, w.LOT, w.DEVICE,
           w.PG_CD, w.BASE_DT, w.WIN_SIZE
),

/* ── ⑦ 원본 PLAN_SUM_QTY 산출 + RN/TOTAL_ROWS 부여 ────────────
   PREFIX SUM → PLAN_SUM_QTY
   ROW_NUMBER : 파티션(FAB,TECH,LOT,DEVICE,PG_CD) 내 DT 순번
   COUNT(*)   : 파티션 내 전체 행 수 → 마지막값 범위 판단용        */
plan_base AS (
    SELECT /*+ NO_MERGE */
           FAB, TECH, LOT, DEVICE, PG_CD,
           BASE_DT                                         AS DT,
           CASE
               WHEN NVL(END_CUM, 0) = NVL(PRE_CUM, 0) THEN NULL
               ELSE ROUND(
                        (NVL(END_CUM, 0) - NVL(PRE_CUM, 0)) / WIN_SIZE,
                        6
                    )
           END                                             AS PLAN_SUM_QTY,
           -- 파티션 내 날짜 순번 (셀프 조인 키)
           ROW_NUMBER() OVER (
               PARTITION BY FAB, TECH, LOT, DEVICE, PG_CD
               ORDER BY BASE_DT
           )                                               AS RN,
           -- 파티션 내 전체 행 수
           COUNT(*) OVER (
               PARTITION BY FAB, TECH, LOT, DEVICE, PG_CD
           )                                               AS TOTAL_ROWS
    FROM   cum_both
),

/* ── ⑧ SHIFT_DAYS 조인 ──────────────────────────────────────────
   SHIFT_TABLE 에서 FAB/TECH/LOT/DEVICE/PG_CD 별 SHIFT_DAYS 조회
   없는 조합은 NVL(SHIFT_DAYS, 0) → 시프트 없음(원본 유지)         */
shift_info AS (
    SELECT /*+ USE_HASH(b s) NO_MERGE */
           b.FAB, b.TECH, b.LOT, b.DEVICE, b.PG_CD,
           b.DT, b.RN, b.TOTAL_ROWS,
           b.PLAN_SUM_QTY,
           NVL(s.SHIFT_DAYS, 0)                           AS SHIFT_DAYS
    FROM   plan_base   b
    LEFT JOIN SHIFT_TABLE s
        ON  s.FAB    = b.FAB
        AND s.TECH   = b.TECH
        AND s.LOT    = b.LOT
        AND s.DEVICE = b.DEVICE
        AND s.PG_CD  = b.PG_CD
),

/* ── ⑨ 셀프 조인 : 동적 SHIFT 적용 ─────────────────────────────
   핵심 : a.RN + a.SHIFT_DAYS = b.RN 으로 N행 뒤 값 조인
   - 조인 성공(b.RN 존재) : b.PLAN_SUM_QTY → SHIFTED_RAW
   - 조인 실패(범위 초과) : b.PLAN_SUM_QTY IS NULL → 마지막값 채움

   [성능 고려]
   - USE_HASH(a b) : 해시 조인으로 처리
   - LEADING(a)    : shift_info(a)를 빌드 사이드로
   - a, b 모두 shift_info 이므로 동일 CTE 재참조
     → Oracle 은 CTE 를 NO_MERGE 시 한 번만 실체화하므로
        셀프 조인이더라도 plan_base 재계산 없음               */
plan_shifted AS (
    SELECT /*+ USE_HASH(a b) LEADING(a b) NO_MERGE */
           a.FAB, a.TECH, a.LOT, a.DEVICE, a.PG_CD,
           a.DT,
           a.PLAN_SUM_QTY                                  AS ORIG_QTY,
           a.SHIFT_DAYS,
           -- N행 뒤 값 : 조인 성공이면 b의 QTY, 실패(범위초과)이면 NULL
           b.PLAN_SUM_QTY                                  AS SHIFTED_RAW
    FROM   shift_info a
    LEFT JOIN shift_info b
        ON  b.FAB    = a.FAB
        AND b.TECH   = a.TECH
        AND b.LOT    = a.LOT
        AND b.DEVICE = a.DEVICE
        AND b.PG_CD  = a.PG_CD
        AND b.RN     = a.RN + a.SHIFT_DAYS   -- ★ 동적 N행 뒤 매칭
)

/* ── ⑩ 최종 SELECT : LAST_VALUE IGNORE NULLS → 마지막값 채움 ───
   SHIFTED_RAW 가 NULL 인 경우 (= SHIFT 범위 초과한 마지막 N행)
   → LAST_VALUE IGNORE NULLS 로 직전 마지막 유효값 forward fill

   원본 PLAN_SUM_QTY 가 NULL 인 행
   → 윈도우 내 계획 없음이므로 NULL 유지 (ORIG_QTY IS NULL 체크)   */
SELECT /*+ PARALLEL(4) */
       FAB, TECH, LOT, DEVICE, PG_CD, DT,
       CASE
           -- 원본이 NULL 이면 NULL 유지 (계획 없는 구간)
           WHEN ORIG_QTY IS NULL THEN NULL
           -- SHIFT 범위 초과 마지막 N행 → 마지막 유효값 채움
           ELSE
               LAST_VALUE(SHIFTED_RAW IGNORE NULLS) OVER (
                   PARTITION BY FAB, TECH, LOT, DEVICE, PG_CD
                   ORDER BY DT
                   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
               )
       END                                                 AS PLAN_SUM_QTY
FROM   plan_shifted
ORDER BY FAB, TECH, LOT, DEVICE, PG_CD, DT;

COMMIT;


/* ================================================================
   [전체 CTE 흐름 요약]

   PRODUPLAN_TABLE(월별)         ADJ_TABLE      SHIFT_TABLE
          │                          │               │
          ▼ ① daily_plan             ▼ ③ adj_ranked  │
      (월 → 일 펼침)             (LOWER_DAYS)        │
          │                          │               │
          ▼ ② daily_cum              │               │
      (CUM_QTY 누적합)               │               │
          │                          │               │
          ├──DISTINCT──▶ ④ device_dates              │
          │                    │                     │
          │          ③ adj_ranked──┤                 │
          │                    ▼ ⑤ windows           │
          │              (WIN_START/END/SIZE)         │
          │                    │                     │
          └────────────────────┤                     │
                               ▼ ⑥ cum_both          │
                          (END_CUM/PRE_CUM)           │
                               │                     │
                               ▼ ⑦ plan_base         │
                          (PLAN_SUM_QTY + RN)         │
                               │                     │
                               └─────────────────────┤
                                                      ▼ ⑧ shift_info
                                                  (SHIFT_DAYS 조인)
                                                      │
                                              ┌───────┘
                                              │ 셀프 조인
                                              │ b.RN = a.RN + SHIFT_DAYS
                                              ▼ ⑨ plan_shifted
                                          (SHIFTED_RAW)
                                              │
                                              ▼ ⑩ 최종 SELECT
                                      (LAST_VALUE IGNORE NULLS)
                                              │
                                              ▼
                                     INSERT INTO PLAN_SUM_TABLE
   ================================================================ */
