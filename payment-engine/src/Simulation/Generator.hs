-- | Simulation.Generator
--
-- WHY: The generator is the only place where randomness enters the system.
-- It lives at the IO boundary.  The core engine never sees IO.
-- By separating generation from processing we can:
--   1. Replay any simulation by seeding the same RNG
--   2. Generate adversarial scenarios (fraud, timeouts) deterministically
--   3. Feed the same event stream to both the STM engine and the pure replay
module Simulation.Generator
  ( SimConfig(..)
  , defaultConfig
  , generateEvents
  , generateFraudScenario
  , generateTimeoutScenario
  , generateRaceCondition
  ) where

import Data.List (mapAccumL)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, addUTCTime)
import System.Random (StdGen, mkStdGen, randomR, split)

import Domain.Types

-- ── Configuration ─────────────────────────────────────────────────────────

data SimConfig = SimConfig
  { cfgNumUsers       :: Int
  , cfgNumMerchants   :: Int
  , cfgNumTxns        :: Int
  , cfgSeed           :: Int      -- ^ RNG seed for reproducibility
  , cfgFraudRate      :: Double   -- ^ 0.0–1.0
  , cfgTimeoutRate    :: Double
  , cfgNetworkJitter  :: Double   -- ^ max latency variance in seconds
  } deriving stock (Show)

defaultConfig :: SimConfig
defaultConfig = SimConfig
  { cfgNumUsers      = 100
  , cfgNumMerchants  = 10
  , cfgNumTxns       = 1000
  , cfgSeed          = 42
  , cfgFraudRate     = 0.05
  , cfgTimeoutRate   = 0.03
  , cfgNetworkJitter = 2.0
  }

-- ── Account generation ────────────────────────────────────────────────────

mkUserId :: Int -> AccountId
mkUserId n = AccountId $ "usr_" <> T.pack (show n)

mkMerchantId :: Int -> AccountId
mkMerchantId n = AccountId $ "merch_" <> T.pack (show n)

mkTxId :: Int -> TxId
mkTxId n = TxId $ "tx_" <> T.pack (show n)

-- ── Event generation ──────────────────────────────────────────────────────
-- WHY: We generate a complete, realistic event stream including:
--   - Normal happy-path transactions
--   - Fraud scenarios (large amounts, velocity checks)
--   - Network timeouts with retries
--   - Race conditions (same account, concurrent debits)

generateEvents :: SimConfig -> UTCTime -> [Event]
generateEvents cfg baseTime =
  let gen0 = mkStdGen (cfgSeed cfg)
      (_, eventLists) = mapAccumL (\g i ->
                          let (currentGen, nextGen) = split g
                          in (nextGen, generateTxEvents cfg baseTime currentGen i)
                        ) gen0 [0 .. cfgNumTxns cfg - 1]
  in concat eventLists

generateTxEvents :: SimConfig -> UTCTime -> StdGen -> Int -> [Event]
generateTxEvents cfg baseTime gen i =
  let
    (fromIdx, g1) = randomR (0, cfgNumUsers cfg - 1)     gen
    (toIdx,   g2) = randomR (0, cfgNumMerchants cfg - 1) g1
    (amtRaw,  g3) = randomR (100, 50000 :: Int)          g2  -- 1.00 to 500.00
    (jitter,  g4) = randomR (0.0, cfgNetworkJitter cfg)  g3
    (isFraud, g5) = randomR (0.0, 1.0 :: Double)         g4
    (isTimeout,_) = randomR (0.0, 1.0 :: Double)         g5

    txId   = mkTxId i
    from   = mkUserId fromIdx
    to     = mkMerchantId toIdx
    amt    = Money amtRaw
    method = UPI { vpa = "user" <> T.pack (show fromIdx) <> "@upi" }
    t0     = addUTCTime (fromIntegral i * 0.1 + jitter) baseTime
    t1     = addUTCTime 0.5  t0
    t2     = addUTCTime 0.3  t1
    t3     = addUTCTime 1.0  t2

    initEv = EvtInitiated txId from to amt method t0

  in if isFraud < cfgFraudRate cfg
     then -- Fraud scenario: large amount triggers fraud rule
       [ initEv
       , EvtFailed txId (FraudDetected "RULE_HIGH_VALUE") t1
       ]
     else if isTimeout < cfgTimeoutRate cfg
     then -- Timeout + retry scenario
       [ initEv
       , EvtFailed txId (NetworkTimeout 1) t1
       , EvtRetried txId 1 t1
       , EvtInitiated txId from to amt method (addUTCTime 5.0 t1)  -- retry
       , EvtAuthorized txId "AUTH_RETRY" (addUTCTime 5.5 t1)
       , EvtCaptured txId (addUTCTime 6.0 t1)
       , EvtSettled txId "BATCH_RETRY" (addUTCTime 7.0 t1)
       ]
     else -- Happy path
       [ initEv
       , EvtAuthorized txId ("AUTH_" <> T.pack (show i)) t1
       , EvtCaptured txId t2
       , EvtSettled txId ("BATCH_" <> T.pack (show (i `div` 100))) t3
       ]

-- ── Adversarial scenarios ─────────────────────────────────────────────────

-- | Generate a scenario where one account tries to spend more than its balance
--   across concurrent transactions — tests STM consistency.
generateRaceCondition :: AccountId -> AccountId -> Money -> UTCTime -> [Event]
generateRaceCondition from to balance t =
  -- Two transactions that together exceed the balance
  let half = balance `div` 2 + 1
  in [ EvtInitiated (TxId "race_tx_1") from to half (UPI "race@upi") t
     , EvtInitiated (TxId "race_tx_2") from to half (UPI "race@upi") t
     , EvtAuthorized (TxId "race_tx_1") "AUTH_R1" (addUTCTime 0.1 t)
     , EvtAuthorized (TxId "race_tx_2") "AUTH_R2" (addUTCTime 0.1 t)
     , EvtCaptured   (TxId "race_tx_1") (addUTCTime 0.2 t)
     , EvtCaptured   (TxId "race_tx_2") (addUTCTime 0.2 t)  -- STM will retry this
     ]

-- | Fraud scenario: rapid-fire transactions from one account.
generateFraudScenario :: AccountId -> AccountId -> UTCTime -> [Event]
generateFraudScenario from to t =
  concatMap (\i ->
    let txId = TxId $ "fraud_tx_" <> T.pack (show i)
        ti   = addUTCTime (fromIntegral i * 0.01) t
    in [ EvtInitiated txId from to 100 (UPI "fraud@upi") ti
       , EvtFailed txId (FraudDetected "RULE_VELOCITY") (addUTCTime 0.001 ti)
       ]
  ) [1..10 :: Int]

-- | Timeout scenario with exponential backoff retries.
generateTimeoutScenario :: TxId -> AccountId -> AccountId -> Money -> UTCTime -> [Event]
generateTimeoutScenario txId from to amt t =
  [ EvtInitiated txId from to amt (UPI "timeout@upi") t
  , EvtFailed txId (NetworkTimeout 1) (addUTCTime 30 t)
  , EvtRetried txId 1 (addUTCTime 30 t)
  , EvtInitiated txId from to amt (UPI "timeout@upi") (addUTCTime 31 t)
  , EvtFailed txId (NetworkTimeout 2) (addUTCTime 61 t)
  , EvtRetried txId 2 (addUTCTime 61 t)
  , EvtInitiated txId from to amt (UPI "timeout@upi") (addUTCTime 63 t)
  , EvtAuthorized txId "AUTH_FINAL" (addUTCTime 63.5 t)
  , EvtCaptured txId (addUTCTime 64 t)
  , EvtSettled txId "BATCH_FINAL" (addUTCTime 65 t)
  ]
