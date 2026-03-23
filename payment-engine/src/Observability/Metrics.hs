-- | Observability.Metrics
--
-- WHY: Observability is a first-class concern in production systems.
-- All metrics and logs are pure values — no global mutable state, no
-- unsafePerformIO.  They are accumulated in the monad and flushed at the edge.
module Observability.Metrics
  ( -- * Structured log entries
    LogEntry(..)
  , mkLog
  , renderLog
    -- * Metrics
  , Metrics(..)
  , emptyMetrics
  , recordLatency
  , recordFailure
  , recordSuccess
    -- * Report
  , printReport
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time (UTCTime, diffUTCTime)
import GHC.Generics (Generic)
import Data.Aeson (ToJSON)

import Domain.Types (TxId(..), FailureMode(..))

-- ── Structured log entry ──────────────────────────────────────────────────
-- WHY: Structured logs (key-value pairs) are machine-parseable.
-- In production these would be emitted as JSON to a log aggregator.

data LogEntry = LogEntry
  { leTimestamp :: UTCTime
  , leLevel     :: Text
  , leOperation :: Text
  , leTxId      :: TxId
  , leDetail    :: Text
  } deriving stock (Show, Generic)
    deriving anyclass (ToJSON)

mkLog :: Text -> TxId -> Text -> LogEntry
mkLog op txId detail = LogEntry
  { leTimestamp = error "timestamp injected at IO boundary"
  -- WHY: We don't call getCurrentTime here because this function is pure.
  -- The timestamp is filled in by the IO shell before writing.
  , leLevel     = "INFO"
  , leOperation = op
  , leTxId      = txId
  , leDetail    = detail
  }

renderLog :: LogEntry -> Text
renderLog LogEntry{..} =
  "[" <> leLevel <> "] " <> leOperation
  <> " txId=" <> unTxId leTxId
  <> " " <> leDetail

-- ── Metrics ───────────────────────────────────────────────────────────────

data Metrics = Metrics
  { mTotalTxns      :: !Int
  , mSucceeded      :: !Int
  , mFailed         :: !Int
  , mTotalLatencyMs :: !Double  -- ^ sum of latencies for avg calculation
  , mMaxLatencyMs   :: !Double
  } deriving stock (Show, Generic)
    deriving anyclass (ToJSON)

emptyMetrics :: Metrics
emptyMetrics = Metrics 0 0 0 0.0 0.0

recordLatency :: Double -> Metrics -> Metrics
recordLatency ms m = m
  { mTotalTxns      = mTotalTxns m + 1
  , mTotalLatencyMs = mTotalLatencyMs m + ms
  , mMaxLatencyMs   = max (mMaxLatencyMs m) ms
  }

recordFailure :: Metrics -> Metrics
recordFailure m = m { mFailed = mFailed m + 1 }

recordSuccess :: Metrics -> Metrics
recordSuccess m = m { mSucceeded = mSucceeded m + 1 }

avgLatency :: Metrics -> Double
avgLatency m
  | mTotalTxns m == 0 = 0
  | otherwise         = mTotalLatencyMs m / fromIntegral (mTotalTxns m)

failureRate :: Metrics -> Double
failureRate m
  | mTotalTxns m == 0 = 0
  | otherwise         = fromIntegral (mFailed m) / fromIntegral (mTotalTxns m) * 100

-- ── Human-readable report ─────────────────────────────────────────────────

printReport :: Metrics -> Int -> IO ()
printReport m eventCount = do
  TIO.putStrLn ""
  TIO.putStrLn "╔══════════════════════════════════════════╗"
  TIO.putStrLn "║     Payment Engine — Simulation Report   ║"
  TIO.putStrLn "╠══════════════════════════════════════════╣"
  TIO.putStrLn $ "║  Events processed : " <> pad 21 (T.pack $ show eventCount)    <> " ║"
  TIO.putStrLn $ "║  Total txns       : " <> pad 21 (T.pack $ show (mTotalTxns m)) <> " ║"
  TIO.putStrLn $ "║  Succeeded        : " <> pad 21 (T.pack $ show (mSucceeded m)) <> " ║"
  TIO.putStrLn $ "║  Failed           : " <> pad 21 (T.pack $ show (mFailed m))    <> " ║"
  TIO.putStrLn $ "║  Failure rate     : " <> pad 19 (fmt2 (failureRate m) <> " %") <> " ║"
  TIO.putStrLn $ "║  Avg latency      : " <> pad 18 (fmt2 (avgLatency m) <> " ms") <> " ║"
  TIO.putStrLn $ "║  Max latency      : " <> pad 18 (fmt2 (mMaxLatencyMs m) <> " ms") <> " ║"
  TIO.putStrLn "╚══════════════════════════════════════════╝"
  where
    pad n t = t <> T.replicate (n - T.length t) " "
    fmt2 d  = T.pack $ show (fromIntegral (round (d * 100) :: Int) / 100.0 :: Double)
