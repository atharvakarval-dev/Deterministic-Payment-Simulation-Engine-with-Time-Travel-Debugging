-- | Domain.Types
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE DuplicateRecordFields #-}
module Domain.Types
  ( TxStatus(..)
  , TxId(..), AccountId(..), Money(..)
  , Transaction(..)
  , SomeTx(..)
  , PaymentMethod(..)
  , FailureMode(..)
  , Event(..)
  , SystemState(..)
  , emptySystemState
  ) where

import Data.Text (Text)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Data.Aeson (ToJSON, FromJSON)

data TxStatus
  = Initiated
  | Authorized
  | Captured
  | Settled
  | Failed

newtype TxId      = TxId      { unTxId      :: Text } deriving stock (Show, Eq, Ord, Generic) deriving anyclass (ToJSON, FromJSON)
newtype AccountId = AccountId { unAccountId :: Text } deriving stock (Show, Eq, Ord, Generic) deriving anyclass (ToJSON, FromJSON)

-- | Money in minor units (paise / cents) — never use floating point for money.
newtype Money = Money { unMoney :: Int }
  deriving stock    (Show, Eq, Ord, Generic)
  deriving newtype  (Num, Enum, Real, Integral)
  deriving anyclass (ToJSON, FromJSON)

data PaymentMethod
  = UPI    { vpa :: Text }
  | Card   { maskedPan :: Text, network :: Text }
  | NEFT   { ifsc :: Text, accountNo :: Text }
  | Wallet { walletProvider :: Text }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

data FailureMode
  = InsufficientFunds
  | NetworkTimeout    { attemptNo :: Int }
  | BankDeclined      { bankCode :: Text }
  | FraudDetected     { ruleId :: Text }
  | DuplicateTransaction
  | InvalidAccount    AccountId
  | SettlementFailed  { batchId :: Text }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | GADT: phantom type enforces valid state transitions at compile time.
data Transaction (s :: TxStatus) where
  TxInitiated  :: { txId      :: TxId
                  , txFrom    :: AccountId
                  , txTo      :: AccountId
                  , txAmount  :: Money
                  , txMethod  :: PaymentMethod
                  , txCreated :: UTCTime
                  } -> Transaction 'Initiated

  TxAuthorized :: { authBase :: Transaction 'Initiated
                  , authCode :: Text
                  , authAt   :: UTCTime
                  } -> Transaction 'Authorized

  TxCaptured   :: { capBase :: Transaction 'Authorized
                  , capAt   :: UTCTime
                  } -> Transaction 'Captured

  TxSettled    :: { setBase       :: Transaction 'Captured
                  , settleBatchId :: Text
                  , settleAt      :: UTCTime
                  } -> Transaction 'Settled

  TxFailed     :: { failBase   :: SomeTx
                  , failReason :: FailureMode
                  , failAt     :: UTCTime
                  } -> Transaction 'Failed

deriving instance Show (Transaction s)

-- | Existential wrapper for heterogeneous collections.
data SomeTx = forall s. SomeTx (Transaction s)
instance Show SomeTx where show (SomeTx t) = show t

-- | Append-only event log entry.
-- FIX: DuplicateRecordFields allows shared field names (evtTxId, evtAt)
-- across constructors without ambiguity errors under GHC 9.4+.
data Event
  = EvtInitiated
      { evtTxId   :: TxId
      , evtFrom   :: AccountId
      , evtTo     :: AccountId
      , evtAmount :: Money
      , evtMethod :: PaymentMethod
      , evtAt     :: UTCTime
      }
  | EvtAuthorized
      { evtTxId :: TxId
      , evtCode :: Text
      , evtAt   :: UTCTime
      }
  | EvtCaptured
      { evtTxId :: TxId
      , evtAt   :: UTCTime
      }
  | EvtSettled
      { evtTxId    :: TxId
      , evtBatchId :: Text
      , evtAt      :: UTCTime
      }
  | EvtFailed
      { evtTxId   :: TxId
      , evtReason :: FailureMode
      , evtAt     :: UTCTime
      }
  | EvtRetried
      { evtTxId    :: TxId
      , evtAttempt :: Int
      , evtAt      :: UTCTime
      }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

data SystemState = SystemState
  { ssTransactions :: Map TxId SomeTx
  , ssBalances     :: Map AccountId Money
  , ssEventCount   :: Int
  } deriving stock (Show)

emptySystemState :: Map AccountId Money -> SystemState
emptySystemState initialBalances = SystemState
  { ssTransactions = Map.empty
  , ssBalances     = initialBalances
  , ssEventCount   = 0
  }
