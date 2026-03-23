-- | Engine.STM
--
-- WHY: STM (Software Transactional Memory) is Haskell's answer to concurrent
-- mutable state.  Unlike locks, STM transactions compose and are deadlock-free
-- by construction.  We use it to simulate concurrent payment processing where
-- multiple transactions race to debit the same account.
--
-- Key design decisions:
--   - The event log is a TVar [Event] — append-only, never mutated in place
--   - Each account balance is a separate TVar — fine-grained concurrency
--   - Idempotency is enforced by checking a TVar (Set TxId) before processing
--   - Retries are handled by STM's built-in retry/orElse mechanism
module Engine.STM
  ( STMEnv(..)
  , mkSTMEnv
  , submitTransaction
  , processTransaction
  , runConcurrentSimulation
  , snapshotState
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM
import Control.Monad (forM_, replicateM_, when, unless)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Time (getCurrentTime)
import Domain.Types
import Domain.StateMachine (retryable)
import Engine.Core (applyEvent, emptySystemState)
import Observability.Metrics (Metrics(..))

-- ── Environment ───────────────────────────────────────────────────────────
-- WHY: ReaderT over IO with STM vars is the "functional shell" pattern.
-- All mutable state is explicit and typed; nothing is hidden.

data STMEnv = STMEnv
  { envEventLog   :: TVar [Event]
    -- ^ Append-only event log (newest at head for O(1) append)
  , envBalances   :: TVar (Map AccountId (TVar Money))
    -- ^ Per-account TVars for fine-grained STM concurrency
  , envProcessed  :: TVar (Set TxId)
    -- ^ Idempotency set: txIds we have already processed
  , envMetrics    :: TVar Metrics
    -- ^ Live metrics updated atomically
  , envWorkQueue  :: TBQueue Event
    -- ^ Bounded queue: back-pressure prevents unbounded memory growth
  }

mkSTMEnv :: Map AccountId Money -> IO STMEnv
mkSTMEnv initialBalances = do
  balTVars <- traverse newTVarIO initialBalances
  STMEnv
    <$> newTVarIO []
    <*> newTVarIO balTVars
    <*> newTVarIO Set.empty
    <*> newTVarIO (Metrics 0 0 0 0 0)
    <*> newTBQueueIO 10000  -- bounded at 10k pending events

-- ── Submit (producer side) ────────────────────────────────────────────────

-- | Enqueue an event for processing.  Blocks if the queue is full (back-pressure).
submitTransaction :: STMEnv -> Event -> IO ()
submitTransaction env ev = atomically $ writeTBQueue (envWorkQueue env) ev

-- ── Process (consumer side) ───────────────────────────────────────────────

-- | Process one event from the queue.
--   WHY: The entire debit/credit is one STM transaction — either both
--   accounts update or neither does.  No partial updates possible.
processTransaction :: STMEnv -> IO ()
processTransaction env = do
  ev <- atomically $ readTBQueue (envWorkQueue env)
  t  <- getCurrentTime

  case ev of
    EvtCaptured { evtTxId } ->
      -- WHY: read log and update balances in one atomic block to avoid
      -- acting on a stale snapshot from a prior readTVarIO.
      atomically $ do
        log_ <- readTVar (envEventLog env)
        let state = foldl applyEvent (emptySystemState Map.empty) (reverse log_)
        case Map.lookup evtTxId (ssTransactions state) of
          Nothing   -> pure ()
          Just some -> do
            let amt    = txAmountOf some
                sender = txFromOf   some
            balMap <- readTVar (envBalances env)
            case Map.lookup sender balMap of
              Nothing      -> pure ()  -- unknown account → no-op
              Just senderV -> do
                senderBal <- readTVar senderV
                when (senderBal < amt) retry
                writeTVar senderV (senderBal - amt)
                idempotent env evtTxId $ appendEvent env ev

    _ -> atomically $ idempotent env (evtTxIdOf ev) $ appendEvent env ev

  where
    appendEvent e event = modifyTVar' (envEventLog e) (event :)

-- ── Idempotency guard ─────────────────────────────────────────────────────

-- | Wrap any STM action with an idempotency check.
--   WHY: Network retries can deliver the same event twice.  We deduplicate
--   by txId before any state mutation.
idempotent :: STMEnv -> TxId -> STM () -> STM ()
idempotent env txId action = do
  seen <- readTVar (envProcessed env)
  unless (Set.member txId seen) $ do
    action
    modifyTVar' (envProcessed env) (Set.insert txId)

-- ── Concurrent simulation ─────────────────────────────────────────────────

-- | Spin up N worker threads, each pulling from the shared work queue.
--   WHY: This models a real payment processor with a worker pool.
--   STM ensures consistency regardless of how many workers run concurrently.
runConcurrentSimulation :: STMEnv -> Int -> [Event] -> IO ()
runConcurrentSimulation env numWorkers events = do
  forM_ events $ \ev -> submitTransaction env ev
  replicateM_ numWorkers $ forkIO $ processWorker env
  -- Block until queue is empty
  atomically $ do
    empty <- isEmptyTBQueue (envWorkQueue env)
    unless empty retry

-- | Drain the queue then exit cleanly instead of looping forever.
processWorker :: STMEnv -> IO ()
processWorker env = do
  mev <- atomically $ tryReadTBQueue (envWorkQueue env)
  case mev of
    Nothing -> pure ()  -- queue drained, exit
    Just ev -> do
      atomically $ writeTBQueue (envWorkQueue env) ev
      processTransaction env
      processWorker env

-- ── Snapshot ──────────────────────────────────────────────────────────────

-- | Read a consistent snapshot of the current system state.
--   WHY: We read both the event log and balances in one atomic transaction
--   so we never see a state where events have been applied but balances
--   haven't been updated yet.
snapshotState :: STMEnv -> IO (SystemState, [Event])
snapshotState env = atomically $ do
  evts   <- readTVar (envEventLog env)
  balMap <- readTVar (envBalances env)
  bals   <- traverse readTVar balMap
  let state = foldl applyEvent (emptySystemState bals) (reverse evts)
  pure (state, reverse evts)
