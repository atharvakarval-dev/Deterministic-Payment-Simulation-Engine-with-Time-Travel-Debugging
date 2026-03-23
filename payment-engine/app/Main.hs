-- | Main — CLI entry point (the imperative shell)
--
-- Two output modes controlled by the --json flag:
--   default  : human-readable report to stdout (terminal use)
--   --json   : one JSON Event per line to stdout (consumed by server.ts SSE bridge)
--
-- The bridge server (server.ts) always passes --json, so every event is
-- forwarded to the React frontend as an SSE message.
module Main (main) where

import Control.Concurrent (threadDelay)
import Data.Aeson (encode)
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time (getCurrentTime)
import Options.Applicative
import System.IO (hSetBuffering, stdout, BufferMode(..))

import Domain.Types
import Engine.Core (replay, replayUntil, conservationCheck, totalBalance)
import Engine.STM (mkSTMEnv, runConcurrentSimulation, snapshotState)
import Observability.Metrics (Metrics(..), emptyMetrics, recordFailure, recordSuccess, printReport)
import Simulation.Generator

-- ── CLI ───────────────────────────────────────────────────────────────────

data Cmd
  = CmdSimulate SimulateOpts
  | CmdReplay   ReplayOpts
  | CmdScenario ScenarioOpts

data SimulateOpts = SimulateOpts
  { simUsers    :: Int
  , simTxns     :: Int
  , simWorkers  :: Int
  , simSeed     :: Int
  , simFraud    :: Double
  , simTimeout  :: Double
  , simJson     :: Bool
  }

data ReplayOpts = ReplayOpts
  { replayUntilN :: Int
  , replaySeed   :: Int
  , replayTxns   :: Int
  , replayJson   :: Bool
  }

data ScenarioOpts = ScenarioOpts
  { scenarioName :: Text
  , scenarioJson :: Bool
  }

jsonFlag :: Parser Bool
jsonFlag = switch (long "json" <> help "Emit one JSON Event per line (for SSE bridge)")

simulateParser :: Parser Cmd
simulateParser = fmap CmdSimulate $ SimulateOpts
  <$> option auto (long "users"   <> short 'u' <> value 100  <> metavar "N" <> help "Number of users")
  <*> option auto (long "txns"    <> short 't' <> value 1000 <> metavar "N" <> help "Number of transactions")
  <*> option auto (long "workers" <> short 'w' <> value 4    <> metavar "N" <> help "STM worker threads")
  <*> option auto (long "seed"    <> short 's' <> value 42   <> metavar "N" <> help "RNG seed")
  <*> option auto (long "fraud"                <> value 0.05 <> metavar "F" <> help "Fraud rate 0.0-1.0")
  <*> option auto (long "timeout"              <> value 0.03 <> metavar "F" <> help "Timeout rate 0.0-1.0")
  <*> jsonFlag

replayParser :: Parser Cmd
replayParser = fmap CmdReplay $ ReplayOpts
  <$> option auto (long "until" <> metavar "N"    <> help "Replay up to event N")
  <*> option auto (long "seed"  <> value 42        <> metavar "N" <> help "RNG seed")
  <*> option auto (long "txns"  <> value 1000      <> metavar "N" <> help "Total events to generate")
  <*> jsonFlag

scenarioParser :: Parser Cmd
scenarioParser = fmap CmdScenario $ ScenarioOpts
  <$> strOption (long "name" <> metavar "SCENARIO" <> help "race | fraud | timeout")
  <*> jsonFlag

cmdParser :: Parser Cmd
cmdParser = subparser
  ( command "simulate" (info simulateParser (progDesc "Run concurrent payment simulation"))
 <> command "replay"   (info replayParser   (progDesc "Time-travel: replay events up to index N"))
 <> command "scenario" (info scenarioParser (progDesc "Run a named adversarial scenario"))
  )

-- ── JSON event emitter ────────────────────────────────────────────────────
-- WHY: The bridge server reads stdout line-by-line and forwards each JSON
-- object as an SSE message to the React frontend.

emitEvents :: Bool -> [Event] -> IO ()
emitEvents True  evts = mapM_ (BL.putStrLn . encode) evts
emitEvents False _    = pure ()

-- ── Initial balances ──────────────────────────────────────────────────────

mkInitialBalances :: Int -> Map AccountId Money
mkInitialBalances numUsers = Map.fromList $
  [ (AccountId $ "usr_"   <> T.pack (show i), Money 100000) | i <- [0 .. numUsers - 1] ]
  ++ [ (AccountId $ "merch_" <> T.pack (show i), Money 0)   | i <- [0 .. 9] ]

-- ── Handlers ──────────────────────────────────────────────────────────────

runSimulate :: SimulateOpts -> IO ()
runSimulate opts = do
  baseTime <- getCurrentTime
  let cfg = defaultConfig
        { cfgNumUsers    = simUsers opts
        , cfgNumTxns     = simTxns opts
        , cfgSeed        = simSeed opts
        , cfgFraudRate   = simFraud opts
        , cfgTimeoutRate = simTimeout opts
        }
      events  = generateEvents cfg baseTime
      initial = mkInitialBalances (simUsers opts)

  -- Always emit events first so the SSE stream starts immediately
  emitEvents (simJson opts) events

  let finalState = replay events initial
  let conserved  = conservationCheck initial finalState

  if simJson opts
    then pure ()  -- stats go to stderr so they don't corrupt the JSON stream
    else do
      TIO.putStrLn $ "\n  Conservation check : " <> if conserved then "✓ PASS" else "✗ FAIL"
      env <- mkSTMEnv initial
      runConcurrentSimulation env (simWorkers opts) events
      threadDelay 500000
      (_, processedEvts) <- snapshotState env
      let m = computeMetrics processedEvts
      printReport m (length processedEvts)
      TIO.putStrLn $ "\n  Final total balance : " <> T.pack (show (unMoney (totalBalance finalState) `div` 100))

runReplay :: ReplayOpts -> IO ()
runReplay opts = do
  baseTime <- getCurrentTime
  let cfg     = defaultConfig { cfgSeed = replaySeed opts, cfgNumTxns = replayTxns opts }
      events  = generateEvents cfg baseTime
      initial = mkInitialBalances 100
      n       = replayUntilN opts
      sliced  = take (n + 1) events
      state   = replay sliced initial

  emitEvents (replayJson opts) sliced

  if replayJson opts
    then pure ()
    else do
      TIO.putStrLn $ "\n  Transactions : " <> T.pack (show (Map.size (ssTransactions state)))
      TIO.putStrLn $ "  Total balance: " <> T.pack (show (unMoney (totalBalance state)))
      TIO.putStrLn $ "  Events applied: " <> T.pack (show (ssEventCount state))

runScenario :: ScenarioOpts -> IO ()
runScenario opts = do
  baseTime <- getCurrentTime
  let initial = Map.fromList
        [ (AccountId "alice", Money 50000)
        , (AccountId "bob",   Money 50000)
        , (AccountId "merch", Money 0)
        ]
      events = case scenarioName opts of
        "race"    -> generateRaceCondition (AccountId "alice") (AccountId "merch") (Money 50000) baseTime
        "fraud"   -> generateFraudScenario (AccountId "alice") (AccountId "merch") baseTime
        "timeout" -> generateTimeoutScenario (TxId "tx_timeout") (AccountId "alice") (AccountId "merch") (Money 1000) baseTime
        other     -> error $ "Unknown scenario: " <> T.unpack other

  emitEvents (scenarioJson opts) events

  if scenarioJson opts
    then pure ()
    else do
      let state = replay events initial
      TIO.putStrLn $ "  Events   : " <> T.pack (show (length events))
      TIO.putStrLn $ "  Txns     : " <> T.pack (show (Map.size (ssTransactions state)))

-- ── Metrics ───────────────────────────────────────────────────────────────

computeMetrics :: [Event] -> Metrics
computeMetrics = foldl step emptyMetrics
  where
    step m EvtCaptured{} = recordSuccess m
    step m EvtFailed{}   = recordFailure m
    step m _             = m

-- ── Entry point ───────────────────────────────────────────────────────────

main :: IO ()
main = do
  -- Line-buffer stdout so JSON lines reach the bridge server immediately
  hSetBuffering stdout LineBuffering
  cmd <- execParser $ info (cmdParser <**> helper)
    ( fullDesc
   <> progDesc "Deterministic Payment Simulation Engine"
   <> header   "payment-engine — time-travel debugging for distributed payments"
    )
  case cmd of
    CmdSimulate opts -> runSimulate opts
    CmdReplay   opts -> runReplay   opts
    CmdScenario opts -> runScenario opts
