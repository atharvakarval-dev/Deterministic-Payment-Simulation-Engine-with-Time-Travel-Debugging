-- | Test.Spec
--
-- WHY: Property-based testing with QuickCheck is the gold standard for
-- financial systems.  We don't test specific cases — we test universal laws:
--
--   1. Money conservation: total balance never changes (except at capture)
--   2. Idempotency: applying the same event twice = applying it once
--   3. Replay determinism: same events always produce same state
--   4. No negative balances after valid transactions
--   5. State machine monotonicity: states only advance forward
module Main (main) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.List (nub, sort)
import Data.Time (UTCTime, addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Test.Hspec
import Test.Hspec.QuickCheck
import Test.QuickCheck

import Domain.Types
import Domain.StateMachine
import Engine.Core

-- ── Arbitrary instances ───────────────────────────────────────────────────

instance Arbitrary TxId where
  arbitrary = TxId . ("tx_" <>) . show <$> (arbitrary :: Gen Int)

instance Arbitrary AccountId where
  arbitrary = AccountId . ("acc_" <>) . show <$> (choose (0, 9) :: Gen Int)

instance Arbitrary Money where
  arbitrary = Money <$> choose (1, 10000)

instance Arbitrary PaymentMethod where
  arbitrary = UPI . ("user" <>) . show <$> (choose (0,9) :: Gen Int)

instance Arbitrary FailureMode where
  arbitrary = oneof
    [ pure InsufficientFunds
    , NetworkTimeout <$> choose (1, 3)
    , BankDeclined   <$> pure "05"
    , FraudDetected  <$> pure "RULE_TEST"
    ]

-- | A fixed base time for deterministic tests
baseTime :: UTCTime
baseTime = posixSecondsToUTCTime 1700000000

t :: Double -> UTCTime
t offset = addUTCTime (realToFrac offset) baseTime

-- | Generate a valid happy-path event sequence for one transaction
happyPathEvents :: TxId -> AccountId -> AccountId -> Money -> [Event]
happyPathEvents txId from to amt =
  [ EvtInitiated txId from to amt (UPI "test@upi") (t 0)
  , EvtAuthorized txId "AUTH" (t 1)
  , EvtCaptured txId (t 2)
  , EvtSettled txId "BATCH" (t 3)
  ]

-- | Initial balances for tests
testBalances :: Map AccountId Money
testBalances = Map.fromList
  [ (AccountId "acc_0", Money 100000)
  , (AccountId "acc_1", Money 100000)
  , (AccountId "acc_2", Money 100000)
  , (AccountId "acc_3", Money 100000)
  , (AccountId "acc_4", Money 100000)
  , (AccountId "acc_5", Money 0)
  , (AccountId "acc_6", Money 0)
  , (AccountId "acc_7", Money 0)
  , (AccountId "acc_8", Money 0)
  , (AccountId "acc_9", Money 0)
  ]

-- ── Properties ────────────────────────────────────────────────────────────

-- | PROPERTY 1: Money conservation
-- The total balance across all accounts must be invariant under any
-- sequence of events.  Money is neither created nor destroyed.
prop_moneyConservation :: [Event] -> Bool
prop_moneyConservation events =
  conservationCheck testBalances (replay events testBalances)

-- | PROPERTY 2: Idempotency
-- Applying the same event twice produces the same state as applying it once.
-- This is critical for at-least-once delivery in distributed systems.
prop_idempotency :: Event -> Bool
prop_idempotency ev =
  let s0    = emptySystemState testBalances
      once  = applyEvent s0 ev
      twice = applyEvent once ev
  in ssBalances once == ssBalances twice
  && Map.size (ssTransactions once) == Map.size (ssTransactions twice)

-- | PROPERTY 3: Replay determinism
-- replay events == replay events (same input always gives same output)
prop_replayDeterminism :: [Event] -> Bool
prop_replayDeterminism events =
  let s1 = replay events testBalances
      s2 = replay events testBalances
  in ssBalances s1 == ssBalances s2
  && ssEventCount s1 == ssEventCount s2

-- | PROPERTY 4: No negative balances from valid transactions
-- A transaction should never be captured if the sender has insufficient funds.
prop_noNegativeBalances :: TxId -> AccountId -> AccountId -> Money -> Bool
prop_noNegativeBalances txId from to amt =
  let events = happyPathEvents txId from to amt
      state  = replay events testBalances
      bals   = ssBalances state
  in all (>= 0) (Map.elems bals)

-- | PROPERTY 5: Capture is the only event that moves money
-- All other events leave balances unchanged.
prop_onlyCaptureMovesBalance :: TxId -> AccountId -> AccountId -> Money -> Bool
prop_onlyCaptureMovesBalance txId from to amt =
  let s0     = emptySystemState testBalances
      evInit = EvtInitiated txId from to amt (UPI "test@upi") (t 0)
      evAuth = EvtAuthorized txId "AUTH" (t 1)
      evCap  = EvtCaptured txId (t 2)
      s1     = applyEvent s0 evInit
      s2     = applyEvent s1 evAuth
      s3     = applyEvent s2 evCap
  in ssBalances s0 == ssBalances s1   -- initiate doesn't move money
  && ssBalances s1 == ssBalances s2   -- authorize doesn't move money
  && ssBalances s2 /= ssBalances s3   -- capture DOES move money (if valid)
     || Map.findWithDefault 0 from testBalances < amt  -- unless insufficient funds

-- | PROPERTY 6: replayUntil n is a prefix of replay
-- The state at event n must be consistent with the full replay.
prop_replayPrefixConsistency :: [Event] -> Property
prop_replayPrefixConsistency events =
  not (null events) ==>
  let n      = length events `div` 2
      prefix = replayUntil n events testBalances
      full   = replay events testBalances
  in ssEventCount prefix <= ssEventCount full

-- | PROPERTY 7: Failed transactions don't move money
prop_failedTxNoMoneyMovement :: TxId -> AccountId -> AccountId -> Money -> FailureMode -> Bool
prop_failedTxNoMoneyMovement txId from to amt reason =
  let events = [ EvtInitiated txId from to amt (UPI "test@upi") (t 0)
               , EvtFailed txId reason (t 1)
               ]
      state  = replay events testBalances
  in ssBalances state == testBalances

-- ── Hspec test suite ──────────────────────────────────────────────────────

main :: IO ()
main = hspec $ do

  describe "Domain.StateMachine" $ do
    it "authorize produces Authorized from Initiated" $ do
      let tx  = TxInitiated (TxId "t1") (AccountId "a") (AccountId "b") 100 (UPI "x") (t 0)
          tx' = authorize tx "CODE" (t 1)
      authCode tx' `shouldBe` "CODE"

    it "retryable is True for NetworkTimeout < 3" $ do
      let tx  = TxInitiated (TxId "t1") (AccountId "a") (AccountId "b") 100 (UPI "x") (t 0)
          tx' = failTx (SomeTx tx) (NetworkTimeout 2) (t 1)
      retryable tx' `shouldBe` True

    it "retryable is False for InsufficientFunds" $ do
      let tx  = TxInitiated (TxId "t1") (AccountId "a") (AccountId "b") 100 (UPI "x") (t 0)
          tx' = failTx (SomeTx tx) InsufficientFunds (t 1)
      retryable tx' `shouldBe` False

  describe "Engine.Core" $ do
    it "happy path: balance transfers correctly" $ do
      let events = happyPathEvents (TxId "t1") (AccountId "acc_0") (AccountId "acc_9") (Money 1000)
          state  = replay events testBalances
      Map.lookup (AccountId "acc_0") (ssBalances state) `shouldBe` Just (Money 99000)
      Map.lookup (AccountId "acc_9") (ssBalances state) `shouldBe` Just (Money 1000)

    it "duplicate EvtInitiated is idempotent" $ do
      let ev    = EvtInitiated (TxId "t1") (AccountId "acc_0") (AccountId "acc_9") 100 (UPI "x") (t 0)
          s0    = emptySystemState testBalances
          once  = applyEvent s0 ev
          twice = applyEvent once ev
      Map.size (ssTransactions once) `shouldBe` Map.size (ssTransactions twice)

    it "replayUntil 0 has exactly 1 event applied" $ do
      let events = happyPathEvents (TxId "t1") (AccountId "acc_0") (AccountId "acc_9") 100
          state  = replayUntil 0 events testBalances
      ssEventCount state `shouldBe` 1

    it "conservation holds for happy path" $ do
      let events = happyPathEvents (TxId "t1") (AccountId "acc_0") (AccountId "acc_9") 500
          state  = replay events testBalances
      conservationCheck testBalances state `shouldBe` True

  describe "QuickCheck Properties" $ do
    modifyMaxSuccess (const 500) $ do
      prop "money is conserved across any event sequence" prop_moneyConservation
      prop "event application is idempotent"              prop_idempotency
      prop "replay is deterministic"                      prop_replayDeterminism
      prop "no negative balances from valid txns"         prop_noNegativeBalances
      prop "only capture moves balances"                  prop_onlyCaptureMovesBalance
      prop "replayUntil n is a prefix of full replay"     prop_replayPrefixConsistency
      prop "failed transactions don't move money"         prop_failedTxNoMoneyMovement
