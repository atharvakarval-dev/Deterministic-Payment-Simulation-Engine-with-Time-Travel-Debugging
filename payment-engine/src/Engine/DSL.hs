-- | Engine.DSL
--
-- WHY: Tagless Final is chosen over Free Monads because:
--   1. No boilerplate interpreter ADT needed
--   2. Multiple interpreters (pure, logging, STM) via typeclass instances
--   3. GHC can inline and optimise the pure interpreter to zero overhead
--   4. The DSL reads like a payment spec: authorize >> capture >> settle
--
-- The typeclass 'PaymentDSL' is the algebra.  Each interpreter is an instance.
{-# LANGUAGE RankNTypes #-}
module Engine.DSL
  ( -- * The algebra
    PaymentDSL(..)
    -- * Payment flow combinators
  , standardFlow
  , authorizeOnly
  , captureAndSettle
    -- * Pure interpreter
  , PureInterp(..)
  , runPure
    -- * Logging interpreter
  , LoggingInterp(..)
  , runLogging
  ) where

import Control.Monad.State.Strict (StateT, get, put, runStateT)
import Control.Monad.Writer.Strict (WriterT, tell, runWriterT, lift)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)

import Domain.Types
import Observability.Metrics (LogEntry(..), mkLog)
import Engine.Core (applyEvent)

-- ── The algebra ───────────────────────────────────────────────────────────
-- Parameterised over 'm' so we can swap interpreters without changing flows.

class Monad m => PaymentDSL m where
  dslInitiate   :: TxId -> AccountId -> AccountId -> Money -> PaymentMethod -> UTCTime -> m (Either FailureMode ())
  dslAuthorize  :: TxId -> Text -> UTCTime -> m (Either FailureMode ())
  dslCapture    :: TxId -> UTCTime -> m (Either FailureMode ())
  dslSettle     :: TxId -> Text -> UTCTime -> m (Either FailureMode ())
  dslFail       :: TxId -> FailureMode -> UTCTime -> m ()
  dslGetBalance :: AccountId -> m (Maybe Money)

-- ── Payment flow combinators ──────────────────────────────────────────────
-- Flows are monadic programs over the DSL algebra.
-- They compose with (>>) and run unchanged across all interpreters.

-- | The standard 4-step payment lifecycle: initiate → authorize → capture → settle
standardFlow
  :: PaymentDSL m
  => TxId -> AccountId -> AccountId -> Money -> PaymentMethod
  -> Text -> Text                          -- ^ authCode, batchId
  -> UTCTime -> UTCTime -> UTCTime -> UTCTime
  -> m (Either FailureMode ())
standardFlow txId from to amt method authCode batchId t0 t1 t2 t3 = do
  r0 <- dslInitiate txId from to amt method t0
  case r0 of
    Left e  -> pure (Left e)
    Right _ -> do
      r1 <- dslAuthorize txId authCode t1
      case r1 of
        Left e  -> pure (Left e)
        Right _ -> do
          r2 <- dslCapture txId t2
          case r2 of
            Left e  -> pure (Left e)
            Right _ -> dslSettle txId batchId t3

-- | Authorize-only (pre-auth for hotel / car rental).
authorizeOnly
  :: PaymentDSL m
  => TxId -> AccountId -> AccountId -> Money -> PaymentMethod -> Text
  -> UTCTime -> UTCTime
  -> m (Either FailureMode ())
authorizeOnly txId from to amt method authCode t0 t1 = do
  r <- dslInitiate txId from to amt method t0
  case r of
    Left e  -> pure (Left e)
    Right _ -> dslAuthorize txId authCode t1

-- | Capture an already-authorized transaction and settle immediately.
captureAndSettle
  :: PaymentDSL m
  => TxId -> Text -> UTCTime -> UTCTime
  -> m (Either FailureMode ())
captureAndSettle txId batchId t0 t1 = do
  r <- dslCapture txId t0
  case r of
    Left e  -> pure (Left e)
    Right _ -> dslSettle txId batchId t1

-- ── Pure interpreter ──────────────────────────────────────────────────────
-- Accumulates events into a list and threads SystemState through StateT.
-- Zero IO — perfect for unit tests and property tests.

newtype PureInterp a = PureInterp
  { unPure :: StateT (SystemState, [Event]) IO a }
  deriving newtype (Functor, Applicative, Monad)

runPure :: SystemState -> PureInterp a -> IO (a, SystemState, [Event])
runPure initial (PureInterp m) = do
  (a, (s, evts)) <- runStateT m (initial, [])
  pure (a, s, evts)

emitPure :: Event -> PureInterp ()
emitPure ev = PureInterp $ do
  (s, evts) <- get
  put (applyEvent s ev, evts ++ [ev])

instance PaymentDSL PureInterp where
  dslInitiate txId from to amt method t = do
    (s, _) <- PureInterp get
    let bal = Map.findWithDefault 0 from (ssBalances s)
    if bal < amt
      then do
        emitPure (EvtFailed txId InsufficientFunds t)
        pure (Left InsufficientFunds)
      else do
        emitPure (EvtInitiated txId from to amt method t)
        pure (Right ())

  dslAuthorize txId code t = do
    emitPure (EvtAuthorized txId code t)
    pure (Right ())

  dslCapture txId t = do
    emitPure (EvtCaptured txId t)
    pure (Right ())

  dslSettle txId batchId t = do
    emitPure (EvtSettled txId batchId t)
    pure (Right ())

  dslFail txId reason t =
    emitPure (EvtFailed txId reason t)

  dslGetBalance accId = do
    (s, _) <- PureInterp get
    pure (Map.lookup accId (ssBalances s))

-- ── Logging interpreter ───────────────────────────────────────────────────
-- WHY: Wraps any PaymentDSL interpreter with structured logging via WriterT.
-- This is the "decorator" pattern expressed as a monad transformer stack.
-- The base interpreter 'm' is untouched; we just add logging on top.

newtype LoggingInterp m a = LoggingInterp
  { unLogging :: WriterT [LogEntry] m a }
  deriving newtype (Functor, Applicative, Monad)

runLogging :: LoggingInterp m a -> m (a, [LogEntry])
runLogging = runWriterT . unLogging

instance PaymentDSL m => PaymentDSL (LoggingInterp m) where
  dslInitiate txId from to amt method t = LoggingInterp $ do
    tell [mkLog "INITIATE" txId (T.pack $ show (unMoney amt))]
    lift $ dslInitiate txId from to amt method t

  dslAuthorize txId code t = LoggingInterp $ do
    tell [mkLog "AUTHORIZE" txId code]
    lift $ dslAuthorize txId code t

  dslCapture txId t = LoggingInterp $ do
    tell [mkLog "CAPTURE" txId ""]
    lift $ dslCapture txId t

  dslSettle txId batchId t = LoggingInterp $ do
    tell [mkLog "SETTLE" txId batchId]
    lift $ dslSettle txId batchId t

  dslFail txId reason t = LoggingInterp $ do
    tell [mkLog "FAIL" txId (T.pack $ show reason)]
    lift $ dslFail txId reason t

  dslGetBalance accId = LoggingInterp $ lift $ dslGetBalance accId
