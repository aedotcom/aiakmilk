/*
==========================================================================
 PRODUPLAN_TABLE_D (물리 테이블 없이 WITH절로 구성)

 [로직 요약]
 1. PRODUPLAN_TABLE (월별) → 일별 분할 (월 수량 / 해당월 일수)
 2. SHIFT_TABLE 에 없는 데이터 → 그대로 일별 분할
 3. SHIFT_TABLE 에 있는 데이터 → SHIFT_DAYS만큼 날짜 앞당김 적용
    - 원본 날짜 - SHIFT_DAYS = 실제 적용 날짜
    - 예: SHIFT_DAYS=10, 원본 20230111 → 결과 20230101
 4. SHIFT로 인해 말미에 생기는 빈 날짜 구간 처리
    - 예: SHIFT_DAYS=10이면 20230621~20230630 데이터 없음
    - → 직전 마지막 값(20230620)을 복사하여 채움

 [가정 테이블 구조]
  PRODUPLAN_TABLE : FAB, TECH, LOT, DEVICE, YM(YYYYMM), QTY
  SHIFT_TABLE     : FAB, TECH, SHIFT_DAYS
==========================================================================
*/

WITH

/* -----------------------------------------------------------------------
   STEP 1. 월별 데이터를 일별로 전개
   - CROSS JOIN + CONNECT BY LEVEL 로 월 내 각 일자 행 생성
   - DAILY_QTY = QTY / 해당 월 일수
----------------------------------------------------------------------- */
DAILY_BASE AS (
    SELECT
        p.FAB,
        p.TECH,
        p.LOT,
        p.DEVICE,
        p.YM,
        -- 일별 날짜 (YYYYMMDD 형태)
        TO_DATE(p.YM, 'YYYYMM') + (d.LVL - 1)                                  AS PLAN_DT,
        -- 일별 수량
        p.QTY / TO_NUMBER(TO_CHAR(LAST_DAY(TO_DATE(p.YM, 'YYYYMM')), 'DD'))    AS DAILY_QTY
    FROM  PRODUPLAN_TABLE p
    CROSS JOIN (
        SELECT LEVEL AS LVL
        FROM   DUAL
        CONNECT BY LEVEL <= 31          -- 최대 31일 커버
    ) d
    WHERE d.LVL <= TO_NUMBER(TO_CHAR(LAST_DAY(TO_DATE(p.YM, 'YYYYMM')), 'DD'))
),

/* -----------------------------------------------------------------------
   STEP 2. FAB·TECH·LOT·DEVICE 별 전체 날짜 범위
   - SHIFT 적용 후 말미 빈 구간 채울 때 활용
----------------------------------------------------------------------- */
DATE_RANGE AS (
    SELECT
        FAB, TECH, LOT, DEVICE,
        MIN(PLAN_DT) AS RANGE_START,
        MAX(PLAN_DT) AS RANGE_END
    FROM  DAILY_BASE
    GROUP BY FAB, TECH, LOT, DEVICE
),

/* -----------------------------------------------------------------------
   STEP 3. [SHIFT 없음] SHIFT_TABLE 미존재 → 일별 분할 그대로 사용
----------------------------------------------------------------------- */
NO_SHIFT_DATA AS (
    SELECT
        d.FAB, d.TECH, d.LOT, d.DEVICE,
        d.PLAN_DT,
        d.DAILY_QTY
    FROM  DAILY_BASE d
    WHERE NOT EXISTS (
        SELECT 1
        FROM   SHIFT_TABLE s
        WHERE  s.FAB  = d.FAB
          AND  s.TECH = d.TECH
    )
),

/* -----------------------------------------------------------------------
   STEP 4. [SHIFT 있음] SHIFT_DAYS 만큼 날짜 앞당김 적용
   - 원본 날짜 기준: RANGE_START+SHIFT_DAYS 이상인 행만 유지
     (앞당긴 결과가 RANGE_START 이상이 되도록)
   - 결과 날짜 범위: RANGE_START ~ RANGE_END - SHIFT_DAYS
----------------------------------------------------------------------- */
SHIFT_APPLIED AS (
    SELECT
        d.FAB, d.TECH, d.LOT, d.DEVICE,
        d.PLAN_DT - s.SHIFT_DAYS   AS PLAN_DT,     -- SHIFT_DAYS만큼 앞당김
        d.DAILY_QTY,
        s.SHIFT_DAYS,
        dr.RANGE_END
    FROM  DAILY_BASE   d
    JOIN  SHIFT_TABLE  s  ON  s.FAB  = d.FAB
                          AND s.TECH = d.TECH
    JOIN  DATE_RANGE   dr ON  dr.FAB    = d.FAB
                          AND dr.TECH   = d.TECH
                          AND dr.LOT    = d.LOT
                          AND dr.DEVICE = d.DEVICE
    -- 앞당긴 날짜가 RANGE_START 이상인 행만 유지
    WHERE d.PLAN_DT - s.SHIFT_DAYS >= dr.RANGE_START
),

/* -----------------------------------------------------------------------
   STEP 5. SHIFT 후 말미 빈 구간의 마지막 유효값 추출
   - SHIFT 적용 결과의 MAX(PLAN_DT) 행 값 = 채워넣을 기준값
   - 예: SHIFT_DAYS=10 → RANGE_END-10 (=20230620) 값이 기준
----------------------------------------------------------------------- */
LAST_SHIFT_VALUE AS (
    SELECT
        FAB, TECH, LOT, DEVICE,
        DAILY_QTY,
        RANGE_END,
        SHIFT_DAYS
    FROM (
        SELECT
            FAB, TECH, LOT, DEVICE,
            DAILY_QTY,
            RANGE_END,
            SHIFT_DAYS,
            ROW_NUMBER() OVER (
                PARTITION BY FAB, TECH, LOT, DEVICE
                ORDER BY     PLAN_DT DESC
            ) AS RN
        FROM SHIFT_APPLIED
    )
    WHERE RN = 1
),

/* -----------------------------------------------------------------------
   STEP 6. SHIFT로 인해 비어진 말미 구간 날짜 생성 후 마지막 값 복사
   - 빈 구간: (RANGE_END - SHIFT_DAYS + 1) ~ RANGE_END
   - 예: SHIFT_DAYS=10, RANGE_END=20230630
         → 20230621 ~ 20230630 (10일) 을 20230620 값으로 채움
----------------------------------------------------------------------- */
FILL_END_DATES AS (
    SELECT
        l.FAB, l.TECH, l.LOT, l.DEVICE,
        l.RANGE_END - l.SHIFT_DAYS + g.LVL  AS PLAN_DT,   -- 빈 날짜 순차 생성
        l.DAILY_QTY                                         -- 마지막 유효값 복사
    FROM  LAST_SHIFT_VALUE l
    CROSS JOIN (
        SELECT LEVEL AS LVL
        FROM   DUAL
        CONNECT BY LEVEL <= 31      -- SHIFT_DAYS 최대값 커버
    ) g
    WHERE g.LVL <= l.SHIFT_DAYS     -- SHIFT_DAYS 일수만큼만 생성
)

/* -----------------------------------------------------------------------
   FINAL. 세 케이스 UNION ALL
   ① SHIFT 없는 데이터 (원본 일별 분할)
   ② SHIFT 있는 데이터 (날짜 앞당김 적용)
   ③ SHIFT 말미 빈 구간 채움 (마지막 값 복사)
----------------------------------------------------------------------- */
SELECT FAB, TECH, LOT, DEVICE, PLAN_DT, DAILY_QTY FROM NO_SHIFT_DATA
UNION ALL
SELECT FAB, TECH, LOT, DEVICE, PLAN_DT, DAILY_QTY FROM SHIFT_APPLIED
UNION ALL
SELECT FAB, TECH, LOT, DEVICE, PLAN_DT, DAILY_QTY FROM FILL_END_DATES
ORDER BY FAB, TECH, LOT, DEVICE, PLAN_DT
;
