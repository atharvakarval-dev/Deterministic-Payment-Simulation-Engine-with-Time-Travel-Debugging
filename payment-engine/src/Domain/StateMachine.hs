-- | Domain.StateMachine
--
-- WHY: The state machine is the heart of correctness.  Every transition is a
-- pure function.  The type signatures make illegal transitions impossible:
-- 'authorize' only accepts a 'Transaction Initiated', so you can never
-- accidentally authorize an already-failed transaction.
module Domain.StateMachine
  ( authorize
  , capture
  , settle
  , failTx
  , retryable
  , txIdOf
  , txAmountOf
  , txFromOf
  ) where

import Data.Text (Text)
import Data.Time (UTCTime)

import Domain.Types

-- ── Pure state transitions ─────────────────────────────────────────────────
-- Each function is total and referentially transparent.
-- The GADT phantom types enforce the precondition at compile time.

-- | Reserve funds.  Only valid from 'Initiated'.
authorize :: Transaction 'Initiated -> Text -> UTCTime -> Transaction 'Authorized
authorize tx code t = TxAuthorized { authBase = tx, authCode = code, authAt = t }

-- | Move funds.  Only valid from 'Authorized'.
capture :: Transaction 'Authorized -> UTCTime -> Transaction 'Captured
capture tx t = TxCaptured { capBase = tx, capAt = t }

-- | Final settlement.  Only valid from 'Captured'.
settle :: Transaction 'Captured -> Text -> UTCTime -> Transaction 'Settled
settle tx batchId t = TxSettled { setBase = tx, settleBatchId = batchId, settleAt = t }

-- | Fail from any state.  Uses the existential 'SomeTx' so any status works.
failTx :: SomeTx -> FailureMode -> UTCTime -> Transaction 'Failed
failTx base reason t = TxFailed { failBase = base, failReason = reason, failAt = t }

-- | A failed transaction is retryable only for transient failures and only
--   if it hasn't exceeded the attempt limit.
--   WHY: Idempotency + retry logic belongs in the domain, not scattered in IO.
retryable :: Transaction 'Failed -> Bool
retryable TxFailed { failReason = NetworkTimeout n } = n < 3
retryable _                                          = False

-- ── Accessors that work across statuses ───────────────────────────────────

txIdOf :: SomeTx -> TxId
txIdOf (SomeTx (TxInitiated  { txId }))    = txId
txIdOf (SomeTx (TxAuthorized { authBase })) = txId authBase
txIdOf (SomeTx (TxCaptured   { capBase }))  = txId (authBase capBase)
txIdOf (SomeTx (TxSettled    { setBase }))  = txId (authBase (capBase setBase))
txIdOf (SomeTx (TxFailed     { failBase })) = txIdOf failBase

txAmountOf :: SomeTx -> Money
txAmountOf (SomeTx (TxInitiated  { txAmount }))   = txAmount
txAmountOf (SomeTx (TxAuthorized { authBase }))    = txAmount authBase
txAmountOf (SomeTx (TxCaptured   { capBase }))     = txAmount (authBase capBase)
txAmountOf (SomeTx (TxSettled    { setBase }))     = txAmount (authBase (capBase setBase))
txAmountOf (SomeTx (TxFailed     { failBase }))    = txAmountOf failBase

txFromOf :: SomeTx -> AccountId
txFromOf (SomeTx (TxInitiated  { txFrom }))    = txFrom
txFromOf (SomeTx (TxAuthorized { authBase }))  = txFrom authBase
txFromOf (SomeTx (TxCaptured   { capBase }))   = txFrom (authBase capBase)
txFromOf (SomeTx (TxSettled    { setBase }))   = txFrom (authBase (capBase setBase))
txFromOf (SomeTx (TxFailed     { failBase }))  = txFromOf failBase
