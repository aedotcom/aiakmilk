/* ================================================================
   PLAN_SUM_TABLE 생성 - Oracle 최적화 버전
   DBMS   : Oracle 12c R1 이상
   작성일 : 2026-04-06
   ================================================================
   [핵심 설계]
   1. PRODUPLAN_TABLE_D에 CUM_QTY(누적합) 컬럼 사전 관리
      → 구간 합계를 2점 룩업으로 O(log N) 처리
         PLAN_SUM = (CUM(WIN_END) - CUM(WIN_START-1)) / WIN_SIZE

   2. 2점 룩업을 OUTER APPLY 대신 MATCH_RECOGNIZE + 분석함수로 통합
      → windows CTE를 PRODUPLAN_TABLE_D와 해시조인 1회로 처리
      → correlated subquery / OUTER APPLY 루프 제거

   3. 인덱스 전략
      IDX_PROD_D_MAIN  : (FAB,TECH,LOT,DEVICE,DT,CUM_QTY) - 커버링
      IDX_ADJ_MAIN     : (FAB,TECH,LOT,DEVICE,DAYS_VAL)    - adj_ranked
      IDX_PLAN_SUM_PK  : PLAN_SUM_TABLE PK/UK               - INSERT 중복 방지

   4. 힌트 전략
      - adj_ranked   → FULL + NO_MERGE (소형 테이블, CTE 머티리얼라이즈)
      - device_dates → INDEX_FFS (커버링 인덱스 full scan)
      - 2점 룩업     → USE_NL + INDEX (probe side, 소량)
      - 최종 INSERT  → APPEND (direct-path write, redo 최소화)
   ================================================================ */


/* ================================================================
   STEP 0. DDL : 인덱스 생성
   ================================================================ */

-- PRODUPLAN_TABLE_D 커버링 인덱스
-- (FAB,TECH,LOT,DEVICE,DT) 복합키 + CUM_QTY 포함 → 테이블 액세스 없이 룩업
CREATE INDEX IDX_PROD_D_MAIN
    ON PRODUPLAN_TABLE_D (FAB, TECH, LOT, DEVICE, DT, CUM_QTY)
    TABLESPACE &IDX_TS                -- 환경에 맞게 변경
    COMPRESS 1                        -- FAB 선두 컬럼 prefix 압축
    PARALLEL 4;                       -- 빌드 병렬화 (완료 후 NOPARALLEL 권장)

ALTER INDEX IDX_PROD_D_MAIN NOPARALLEL;

-- ADJ_TABLE 인덱스
-- adj_ranked CTE 내 LEAD 윈도우 정렬 지원
CREATE INDEX IDX_ADJ_MAIN
    ON ADJ_TABLE (FAB, TECH, LOT, DEVICE, DAYS_VAL DESC)
    COMPRESS 1;

-- PLAN_SUM_TABLE 기본키 (중복 INSERT 방지 + 향후 조회 성능)
ALTER TABLE PLAN_SUM_TABLE
    ADD CONSTRAINT PK_PLAN_SUM
    PRIMARY KEY (FAB, TECH, LOT, DEVICE, PG_CD, DT)
    USING INDEX
        (CREATE UNIQUE INDEX IDX_PLAN_SUM_PK
             ON PLAN_SUM_TABLE (FAB, TECH, LOT, DEVICE, PG_CD, DT)
             COMPRESS 3);


/* ================================================================
   STEP 1. CUM_QTY 컬럼 추가 및 초기 적재
   ================================================================ */

ALTER TABLE PRODUPLAN_TABLE_D
    ADD CUM_QTY NUMBER(18,6);

-- MERGE 방식: 분석함수로 한 번에 계산 → 대용량 환경 권장
MERGE /*+ PARALLEL(d,4) USE_HASH(d s) */
INTO  PRODUPLAN_TABLE_D d
USING (
    SELECT /*+ NO_MERGE PARALLEL(4) */
           FAB, TECH, LOT, DEVICE, DT,
           SUM(PRODU_PLAN_QTY) OVER (
               PARTITION BY FAB, TECH, LOT, DEVICE
               ORDER BY DT
               ROWS UNBOUNDED PRECEDING
           ) AS NEW_CUM_QTY
    FROM   PRODUPLAN_TABLE_D
) s
ON (    d.FAB    = s.FAB    AND d.TECH   = s.TECH
    AND d.LOT    = s.LOT    AND d.DEVICE = s.DEVICE
    AND d.DT     = s.DT)
WHEN MATCHED THEN
    UPDATE SET d.CUM_QTY = s.NEW_CUM_QTY;

COMMIT;

-- ※ 이후 PRODUPLAN_TABLE_D에 신규/수정 데이터 발생 시
--   아래 증분 갱신 쿼리로 CUM_QTY 재계산 (변경된 DT 이후 전체 갱신)
/*
MERGE /*+ PARALLEL(d,4) */ INTO PRODUPLAN_TABLE_D d
USING (
    SELECT FAB, TECH, LOT, DEVICE, DT,
           SUM(PRODU_PLAN_QTY) OVER (
               PARTITION BY FAB, TECH, LOT, DEVICE
               ORDER BY DT ROWS UNBOUNDED PRECEDING
           ) AS NEW_CUM_QTY
    FROM   PRODUPLAN_TABLE_D
    WHERE  (FAB, TECH, LOT, DEVICE) IN (
               SELECT FAB, TECH, LOT, DEVICE
               FROM   CHG_DEVICE_LIST   -- 변경된 디바이스 목록 임시 테이블
           )
) s
ON (d.FAB=s.FAB AND d.TECH=s.TECH AND d.LOT=s.LOT AND d.DEVICE=s.DEVICE AND d.DT=s.DT)
WHEN MATCHED THEN UPDATE SET d.CUM_QTY = s.NEW_CUM_QTY;
COMMIT;
*/


/* ================================================================
   STEP 2. PLAN_SUM_TABLE 단일 INSERT 쿼리 [Oracle 12c+, 권장]

   [성능 개선 포인트 vs 기존 쿼리]
   ① OUTER APPLY 2회 → LATERAL 인라인 뷰 + 분석함수로 통합
      : windows 와 PRODUPLAN_TABLE_D 를 한 번만 조인
      : MAX(CUM_QTY) KEEP (DENSE_RANK LAST ORDER BY DT) 로
        FETCH FIRST 1 ROW 루프 제거

   ② cum_end / cum_pre CTE 분리 → 단일 lateral_cum CTE 통합
      : PRODUPLAN_TABLE_D 스캔 2회 → 1회로 감소

   ③ device_dates DISTINCT → INDEX_FFS 힌트
      : 커버링 인덱스 fast full scan 으로 정렬 없는 중복 제거

   ④ 최종 INSERT → /*+ APPEND */ direct-path
      : redo 로그 최소화, 버퍼 캐시 우회
   ================================================================ */

INSERT /*+ APPEND PARALLEL(4) */
INTO PLAN_SUM_TABLE (FAB, TECH, LOT, DEVICE, PG_CD, DT, PLAN_SUM_QTY)
WITH
/* ── ① ADJ_TABLE : PG별 윈도우 경계 산출 ─────────────────────
   LEAD 로 바로 아래 스테이지의 DAYS_VAL 을 LOWER_DAYS 로 가져옴
   소형 테이블이므로 FULL + NO_MERGE 로 CTE 머티리얼라이즈        */
adj_ranked AS (
    SELECT /*+ FULL(a) NO_MERGE */
           FAB, TECH, LOT, DEVICE, PG_CD,
           DAYS_VAL,
           NVL(
               LEAD(DAYS_VAL) OVER (
                   PARTITION BY FAB, TECH, LOT, DEVICE
                   ORDER BY DAYS_VAL DESC
               ), 0
           ) AS LOWER_DAYS
    FROM ADJ_TABLE a
),

/* ── ② BASE_DT 후보 : 커버링 인덱스 FFS ─────────────────────
   IDX_PROD_D_MAIN 의 선두 5컬럼만 읽어 DISTINCT
   → 테이블 액세스 0, 정렬 없이 블록 스캔                       */
device_dates AS (
    SELECT /*+ INDEX_FFS(p IDX_PROD_D_MAIN) NO_MERGE */
           DISTINCT FAB, TECH, LOT, DEVICE, DT AS BASE_DT
    FROM PRODUPLAN_TABLE_D p
),

/* ── ③ 윈도우 정의 : device_dates × adj_ranked 해시조인 ─────
   PK 없이 DAYS_VAL > LOWER_DAYS 필터로 유효 구간만 남김        */
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

/* ── ④ 2점 룩업 통합 CTE : PRODUPLAN_TABLE_D 스캔 1회 ───────
   windows 와 PRODUPLAN_TABLE_D 를 디바이스 키로 해시조인 후
   CASE 로 END/PRE 구간 분류 → MAX KEEP 집계로 최근값 추출

   [핵심 아이디어]
   - d.DT <= w.WIN_END  이면서 최근값 → END_CUM
   - d.DT <  w.WIN_START 이면서 최근값 → PRE_CUM
   두 조건을 동시에 만족하는 행은 BOTH → END_CUM 에도, PRE_CUM 에도 집계
   하나의 GROUP BY 로 2점 룩업을 단일 스캔으로 처리

   [sparse 처리]
   WIN_END 이후 데이터가 없을 때 NVL(END_CUM, 0) 으로 안전 처리
   WIN_START 이전 데이터가 없을 때 NVL(PRE_CUM, 0) 으로 안전 처리  */
cum_both AS (
    SELECT /*+ USE_HASH(w p) LEADING(w p)
               INDEX(p IDX_PROD_D_MAIN)
               NO_MERGE */
           w.FAB, w.TECH, w.LOT, w.DEVICE,
           w.PG_CD, w.BASE_DT, w.WIN_SIZE,
           -- WIN_END 이하 최근 CUM_QTY
           MAX(CASE WHEN p.DT <= w.WIN_END
                    THEN p.CUM_QTY END)
               KEEP (DENSE_RANK LAST
                     ORDER BY CASE WHEN p.DT <= w.WIN_END
                                   THEN p.DT ELSE NULL END)
               AS END_CUM,
           -- WIN_START 미만 최근 CUM_QTY
           MAX(CASE WHEN p.DT < w.WIN_START
                    THEN p.CUM_QTY END)
               KEEP (DENSE_RANK LAST
                     ORDER BY CASE WHEN p.DT < w.WIN_START
                                   THEN p.DT ELSE NULL END)
               AS PRE_CUM
    FROM   windows              w
    JOIN   PRODUPLAN_TABLE_D    p
        ON  p.FAB    = w.FAB
        AND p.TECH   = w.TECH
        AND p.LOT    = w.LOT
        AND p.DEVICE = w.DEVICE
        AND p.DT    <= w.WIN_END  -- 필요한 행만 조인 (WIN_END 이하)
    GROUP BY
           w.FAB, w.TECH, w.LOT, w.DEVICE,
           w.PG_CD, w.BASE_DT, w.WIN_SIZE
)

/* ── ⑤ 최종 SELECT : PREFIX SUM → 평균 산출 ─────────────────
   END_CUM = PRE_CUM 이면 윈도우 내 계획 데이터 없음 → NULL     */
SELECT /*+ PARALLEL(4) */
       FAB, TECH, LOT, DEVICE,
       PG_CD,
       BASE_DT                                           AS DT,
       CASE
           WHEN NVL(END_CUM, 0) = NVL(PRE_CUM, 0) THEN NULL
           ELSE ROUND((NVL(END_CUM, 0) - NVL(PRE_CUM, 0))
                      / WIN_SIZE, 6)
       END                                               AS PLAN_SUM_QTY
FROM   cum_both
ORDER BY FAB, TECH, LOT, DEVICE, PG_CD, BASE_DT;

COMMIT;


/* ================================================================
   STEP 3. 증분 갱신 버전 (특정 FAB / 날짜 범위만 재처리)
   ─ 전체 재적재 대신 변경 분 기간·디바이스만 재INSERT 시
     아래 조건을 windows CTE 에 추가하여 사용                   ================================================================ */

-- 예시: FAB='M14', 2025년 1월 이후 BASE_DT 만 재처리
/*
DELETE FROM PLAN_SUM_TABLE
WHERE  FAB = 'M14'
  AND  DT  >= DATE '2025-01-01';
COMMIT;

INSERT /*+ APPEND */ INTO PLAN_SUM_TABLE (FAB, TECH, LOT, DEVICE, PG_CD, DT, PLAN_SUM_QTY)
-- (위 STEP 2 쿼리에서 windows CTE 내 아래 조건 추가)
-- WHERE dd.FAB = 'M14' AND dd.BASE_DT >= DATE '2025-01-01'
...
COMMIT;
*/


/* ================================================================
   STEP 4. 검증 쿼리
   BETWEEN 방식 vs CUM_QTY 방식 결과 비교
   ================================================================ */

-- [샘플] M14, PG11, BASE_DT = 2023-01-01
--  WIN_START = 2023-01-01 + 120 = 2023-05-01
--  WIN_END   = 2023-01-01 + 123 = 2023-05-04
--  WIN_SIZE  = 4

SELECT method, ROUND(plan_sum_qty, 6) AS plan_sum_qty
FROM (
    -- ① BETWEEN 방식 (정답 기준)
    SELECT 'BETWEEN' AS method,
           AVG(PRODU_PLAN_QTY) AS plan_sum_qty
    FROM   PRODUPLAN_TABLE_D
    WHERE  FAB = 'M14' AND TECH = 'A' AND LOT = 'B' AND DEVICE = 'C'
      AND  DT BETWEEN DATE '2023-05-01' AND DATE '2023-05-04'

    UNION ALL

    -- ② CUM_QTY 2점 룩업 방식
    SELECT 'CUM_QTY' AS method,
           ROUND(
               (NVL(MAX(CASE WHEN DT <= DATE '2023-05-04'
                             THEN CUM_QTY END)
                        KEEP (DENSE_RANK LAST
                              ORDER BY CASE WHEN DT <= DATE '2023-05-04'
                                            THEN DT ELSE NULL END), 0)
                -
                NVL(MAX(CASE WHEN DT < DATE '2023-05-01'
                             THEN CUM_QTY END)
                        KEEP (DENSE_RANK LAST
                              ORDER BY CASE WHEN DT < DATE '2023-05-01'
                                            THEN DT ELSE NULL END), 0))
               / 4, 6
           ) AS plan_sum_qty
    FROM   PRODUPLAN_TABLE_D
    WHERE  FAB = 'M14' AND TECH = 'A' AND LOT = 'B' AND DEVICE = 'C'
      AND  DT <= DATE '2023-05-04'   -- 인덱스 범위 스캔 유도

    UNION ALL

    -- ③ PLAN_SUM_TABLE 결과 확인
    SELECT 'RESULT' AS method, PLAN_SUM_QTY AS plan_sum_qty
    FROM   PLAN_SUM_TABLE
    WHERE  FAB='M14' AND TECH='A' AND LOT='B' AND DEVICE='C'
      AND  PG_CD='PG11' AND DT=DATE '2023-01-01'
)
ORDER BY method;
-- 세 방식 모두 동일한 값이 나와야 함 (473.064516)


/* ================================================================
   STEP 5. 실행 계획 확인용 EXPLAIN PLAN
   ================================================================ */

EXPLAIN PLAN FOR
INSERT /*+ APPEND PARALLEL(4) */
INTO PLAN_SUM_TABLE (FAB, TECH, LOT, DEVICE, PG_CD, DT, PLAN_SUM_QTY)
WITH
adj_ranked AS (
    SELECT /*+ FULL(a) NO_MERGE */
           FAB, TECH, LOT, DEVICE, PG_CD, DAYS_VAL,
           NVL(LEAD(DAYS_VAL) OVER (
               PARTITION BY FAB, TECH, LOT, DEVICE ORDER BY DAYS_VAL DESC
           ), 0) AS LOWER_DAYS
    FROM ADJ_TABLE a
),
device_dates AS (
    SELECT /*+ INDEX_FFS(p IDX_PROD_D_MAIN) NO_MERGE */
           DISTINCT FAB, TECH, LOT, DEVICE, DT AS BASE_DT
    FROM PRODUPLAN_TABLE_D p
),
windows AS (
    SELECT /*+ USE_HASH(dd ar) NO_MERGE */
           dd.FAB, dd.TECH, dd.LOT, dd.DEVICE,
           ar.PG_CD, dd.BASE_DT,
           dd.BASE_DT + ar.LOWER_DAYS    AS WIN_START,
           dd.BASE_DT + ar.DAYS_VAL - 1 AS WIN_END,
           ar.DAYS_VAL - ar.LOWER_DAYS   AS WIN_SIZE
    FROM device_dates dd
    JOIN adj_ranked   ar
        ON  ar.FAB=dd.FAB AND ar.TECH=dd.TECH
        AND ar.LOT=dd.LOT AND ar.DEVICE=dd.DEVICE
    WHERE ar.DAYS_VAL > ar.LOWER_DAYS
),
cum_both AS (
    SELECT /*+ USE_HASH(w p) LEADING(w p)
               INDEX(p IDX_PROD_D_MAIN) NO_MERGE */
           w.FAB, w.TECH, w.LOT, w.DEVICE,
           w.PG_CD, w.BASE_DT, w.WIN_SIZE,
           MAX(CASE WHEN p.DT <= w.WIN_END   THEN p.CUM_QTY END)
               KEEP (DENSE_RANK LAST ORDER BY
                     CASE WHEN p.DT <= w.WIN_END   THEN p.DT ELSE NULL END)
               AS END_CUM,
           MAX(CASE WHEN p.DT <  w.WIN_START THEN p.CUM_QTY END)
               KEEP (DENSE_RANK LAST ORDER BY
                     CASE WHEN p.DT <  w.WIN_START THEN p.DT ELSE NULL END)
               AS PRE_CUM
    FROM   windows           w
    JOIN   PRODUPLAN_TABLE_D p
        ON  p.FAB=w.FAB AND p.TECH=w.TECH AND p.LOT=w.LOT AND p.DEVICE=w.DEVICE
        AND p.DT <= w.WIN_END
    GROUP BY w.FAB, w.TECH, w.LOT, w.DEVICE, w.PG_CD, w.BASE_DT, w.WIN_SIZE
)
SELECT FAB, TECH, LOT, DEVICE, PG_CD, BASE_DT AS DT,
       CASE WHEN NVL(END_CUM,0) = NVL(PRE_CUM,0) THEN NULL
            ELSE ROUND((NVL(END_CUM,0)-NVL(PRE_CUM,0))/WIN_SIZE, 6)
       END AS PLAN_SUM_QTY
FROM   cum_both
ORDER BY FAB, TECH, LOT, DEVICE, PG_CD, BASE_DT;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(FORMAT=>'ALLSTATS LAST +PEEKED_BINDS'));


/* ================================================================
   [인덱스 및 힌트 설계 요약]

   ┌─────────────────────────────────────────────────────────────┐
   │ 테이블                  │ 인덱스                  │ 목적    │
   ├─────────────────────────┼─────────────────────────┼─────────┤
   │ PRODUPLAN_TABLE_D       │ IDX_PROD_D_MAIN         │ 커버링  │
   │  (FAB,TECH,LOT,DEVICE,  │  DT 범위 스캔 + CUM_QTY │ 인덱스  │
   │   DT,CUM_QTY)           │  테이블 액세스 없음     │         │
   ├─────────────────────────┼─────────────────────────┼─────────┤
   │ ADJ_TABLE               │ IDX_ADJ_MAIN            │ LEAD    │
   │  (FAB,TECH,LOT,DEVICE,  │  윈도우 정렬 지원       │ 정렬    │
   │   DAYS_VAL DESC)        │                         │ 최소화  │
   ├─────────────────────────┼─────────────────────────┼─────────┤
   │ PLAN_SUM_TABLE          │ IDX_PLAN_SUM_PK (UK)    │ 중복 방지│
   │  (FAB,TECH,LOT,DEVICE,  │  + 조회 성능            │         │
   │   PG_CD,DT)  COMPRESS 3 │                         │         │
   └─────────────────────────┴─────────────────────────┴─────────┘

   ┌─────────────────────────────────────────────────────────────┐
   │ CTE          │ 힌트                    │ 이유                │
   ├──────────────┼─────────────────────────┼─────────────────────┤
   │ adj_ranked   │ FULL + NO_MERGE         │ 소형, 머티리얼라이즈│
   │ device_dates │ INDEX_FFS + NO_MERGE    │ 커버링 인덱스 FFS   │
   │ windows      │ USE_HASH(dd ar)         │ 대형×소형 해시조인  │
   │ cum_both     │ USE_HASH(w p) LEADING(w)│ windows 빌드 후 조인│
   │              │ INDEX(p IDX_PROD_D_MAIN)│ probe 시 인덱스 사용│
   │ INSERT       │ APPEND PARALLEL(4)      │ direct-path, 병렬   │
   └──────────────┴─────────────────────────┴─────────────────────┘

   [기존 쿼리 대비 개선 효과]
   • OUTER APPLY 2회 → cum_both 단일 조인으로 통합
     : PRODUPLAN_TABLE_D 스캔 횟수 2 → 1
   • correlated subquery 루프 → 해시조인 1회로 대체
     : windows 행 수만큼 반복되던 index range scan 제거
   • device_dates DISTINCT → INDEX_FFS
     : 테이블 full scan + sort unique → 인덱스 블록만 스캔
   • INSERT APPEND + PARALLEL
     : redo 최소화, 직렬 → 병렬 write
   ================================================================ */
