-- | Engine.Core
--
-- WHY: This is the "functional core" of the architecture.
-- 'applyEvent' and 'replay' are 100% pure — no IO, no STM, no exceptions.
-- This makes them trivially testable and formally reasoned about.
--
-- The key insight: SystemState = fold applyEvent emptyState eventLog
-- Time-travel is just slicing the event log before folding.
module Engine.Core
  ( applyEvent
  , replay
  , replayUntil
  , totalBalance
  , conservationCheck
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Domain.Types
import Domain.StateMachine

-- ── Core reducer ──────────────────────────────────────────────────────────
-- WHY: A single pure function that takes (state, event) -> state is the
-- simplest possible design.  It composes, it's testable, it's replayable.

applyEvent :: SystemState -> Event -> SystemState
applyEvent s ev = s { ssEventCount = ssEventCount s + 1
                    , ssTransactions = nextTxs
                    , ssBalances     = nextBals
                    }
  where
    txs  = ssTransactions s
    bals = ssBalances s

    (nextTxs, nextBals) = case ev of

      -- ── Initiate ──────────────────────────────────────────────────────
      EvtInitiated { evtTxId, evtFrom, evtTo, evtAmount, evtMethod, evtAt } ->
        -- Idempotent: if we've seen this txId before, ignore.
        case Map.lookup evtTxId txs of
          Just _  -> (txs, bals)
          Nothing ->
            let tx = TxInitiated evtTxId evtFrom evtTo evtAmount evtMethod evtAt
            in  (Map.insert evtTxId (SomeTx tx) txs, bals)

      -- ── Authorize ─────────────────────────────────────────────────────
      EvtAuthorized { evtTxId, evtCode, evtAt } ->
        case Map.lookup evtTxId txs of
          Just (SomeTx tx@TxInitiated{}) ->
            let tx' = authorize tx evtCode evtAt
            in  (Map.insert evtTxId (SomeTx tx') txs, bals)
          _ -> (txs, bals)   -- idempotent / wrong state → no-op

      -- ── Capture ───────────────────────────────────────────────────────
      -- WHY: Money moves ONLY here.  Authorization just reserves; capture
      -- is the actual debit.  This mirrors real payment rails.
      EvtCaptured { evtTxId, evtAt } ->
        case Map.lookup evtTxId txs of
          Just (SomeTx tx@TxAuthorized{}) ->
            let tx'    = capture tx evtAt
                amt    = txAmount (authBase tx)
                sender = txFrom   (authBase tx)
                recvr  = txTo     (authBase tx)
                bals'  = Map.adjust (subtract amt) sender
                       $ Map.adjust (+ amt)        recvr bals
            in  (Map.insert evtTxId (SomeTx tx') txs, bals')
          _ -> (txs, bals)

      -- ── Settle ────────────────────────────────────────────────────────
      EvtSettled { evtTxId, evtBatchId, evtAt } ->
        case Map.lookup evtTxId txs of
          Just (SomeTx tx@TxCaptured{}) ->
            let tx' = settle tx evtBatchId evtAt
            in  (Map.insert evtTxId (SomeTx tx') txs, bals)
          _ -> (txs, bals)

      -- ── Fail ──────────────────────────────────────────────────────────
      EvtFailed { evtTxId, evtReason, evtAt } ->
        case Map.lookup evtTxId txs of
          Just some@(SomeTx tx) ->
            -- Only fail if not already in a terminal state
            case tx of
              TxSettled{} -> (txs, bals)
              TxFailed{}  -> (txs, bals)  -- idempotent
              TxCaptured{} ->
                -- Captured funds must be reversed (refund)
                let amt    = txAmountOf some
                    sender = txFromOf some
                    recvr  = txToOf some
                    tx'    = failTx some evtReason evtAt
                    -- NOTE: in a real system a capture reversal is a separate
                    -- event (EvtRefunded).  We keep it simple here.
                    bals'  = Map.adjust (+ amt)        sender
                           $ Map.adjust (subtract amt) recvr bals
                in  (Map.insert evtTxId (SomeTx tx') txs, bals')
              _ ->
                let tx' = failTx some evtReason evtAt
                in  (Map.insert evtTxId (SomeTx tx') txs, bals)
          Nothing -> (txs, bals)

      -- ── Retry marker ──────────────────────────────────────────────────
      -- WHY: We record retries as events so the log is complete.
      -- The actual re-initiation comes as a subsequent EvtInitiated.
      EvtRetried {} -> (txs, bals)

-- ── Time-travel ───────────────────────────────────────────────────────────

-- | Replay the entire event log from scratch.
--   O(n) in the number of events — acceptable for debugging; production
--   systems would snapshot periodically.
replay :: [Event] -> Map AccountId Money -> SystemState
replay events initial = foldl applyEvent (emptySystemState initial) events

-- | Replay only up to (and including) the nth event (0-indexed).
--   This is the core of time-travel debugging.
replayUntil :: Int -> [Event] -> Map AccountId Money -> SystemState
replayUntil n events = replay (take (n + 1) events)

-- ── Conservation invariant ────────────────────────────────────────────────
-- WHY: Money must be conserved.  The total balance across all accounts must
-- equal the sum of initial balances.  This is a global invariant we can
-- check after every event or in property tests.

totalBalance :: SystemState -> Money
totalBalance = sum . Map.elems . ssBalances

conservationCheck :: Map AccountId Money -> SystemState -> Bool
conservationCheck initial state =
  totalBalance state == sum (Map.elems initial)
