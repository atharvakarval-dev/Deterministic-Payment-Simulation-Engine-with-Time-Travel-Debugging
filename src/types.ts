export type AccountId = string;
export type TxId = string;
export type Money = number;

export type TxState = 'Initiated' | 'Authorized' | 'Captured' | 'Settled' | 'Failed';
export type FailureReason =
  | 'InsufficientFunds'
  | 'NetworkTimeout'
  | 'FraudDetected'
  | 'Timeout'
  | 'BankDeclined'
  | 'DuplicateTransaction'
  | 'InvalidAccount'
  | 'SettlementFailed';

// 1. Domain Modeling: Events as Discriminated Unions (ADTs)
// Mirrors the Haskell Event ADT in Domain/Types.hs exactly.
export type Event =
  | { type: 'EvtInitiated'; txId: TxId; from: AccountId; to: AccountId; amount: Money; timestamp: number }
  | { type: 'EvtAuthorized'; txId: TxId; timestamp: number }
  | { type: 'EvtCaptured'; txId: TxId; timestamp: number }
  | { type: 'EvtSettled'; txId: TxId; batchId: string; timestamp: number }
  | { type: 'EvtFailed'; txId: TxId; reason: FailureReason; timestamp: number }
  | { type: 'EvtRetried'; txId: TxId; attempt: number; timestamp: number };

export interface TransactionDetails {
  id: TxId;
  from: AccountId;
  to: AccountId;
  amount: Money;
  state: TxState;
  failureReason?: FailureReason;
  createdAt: number;
  updatedAt: number;
  initiatedAt?: number;
  authorizedAt?: number;
  capturedAt?: number;
  settledAt?: number;
  failedAt?: number;
  retryCount?: number;
  batchId?: string;
}

// Source of events: local in-browser simulation or Haskell backend
export type EngineSource = 'local' | 'haskell';

export interface SimulateParams {
  users: number;
  txns: number;
  workers: number;
  seed: number;
  fraud: number;
  timeout: number;
}

export type ScenarioName = 'race' | 'fraud' | 'timeout';

// 2. System State: The materialized view of the event log
export interface SystemState {
  balances: Record<AccountId, Money>;
  transactions: Record<TxId, TransactionDetails>;
}
